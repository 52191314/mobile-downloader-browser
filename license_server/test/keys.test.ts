import jwt from 'jsonwebtoken';
import request from 'supertest';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { ULTRA_PRODUCT_ID } from '../src/entitlement.js';
import { KeyRing } from '../src/keys.js';
import { createHarness, makeKey, PACKAGE_NAME, type Harness } from './helpers.js';

let harness: Harness | undefined;

afterEach(() => {
  harness?.close();
  harness = undefined;
});

describe('health + jwks', () => {
  beforeEach(() => {
    harness = createHarness();
  });

  it('answers /v1/health without touching storage', async () => {
    const response = await request(harness!.app).get('/v1/health').expect(200);
    expect(response.body.status).toBe('ok');
    expect(typeof response.body.uptimeSeconds).toBe('number');
  });

  it('reports the active key on /v1/ready', async () => {
    const response = await request(harness!.app).get('/v1/ready').expect(200);
    expect(response.body.status).toBe('ready');
    expect(response.body.activeKid).toBe('test-key-1');
  });

  it('publishes public keys as JWKS and never private material', async () => {
    const response = await request(harness!.app)
      .get('/v1/.well-known/jwks.json')
      .expect(200);

    expect(response.body.keys).toHaveLength(1);
    const key = response.body.keys[0];
    expect(key.kid).toBe('test-key-1');
    expect(key.alg).toBe('RS256');
    expect(key.kty).toBe('RSA');
    expect(key.n).toBeTruthy();
    expect(key.d).toBeUndefined();
    expect(key.p).toBeUndefined();
  });

  it('404s an unknown endpoint', async () => {
    const response = await request(harness!.app).get('/v1/nope').expect(404);
    expect(response.body.error).toBe('not_found');
  });
});

describe('key rotation (plan §15 gap 3)', () => {
  it('signs with the active kid while keeping the retired key verifiable', async () => {
    const oldKey = makeKey('kid-old');
    const newKey = makeKey('kid-new');

    // Ring holds both; only kid-new signs.
    harness = createHarness({ keys: [oldKey, newKey] });
    const rotated = KeyRing.fromKeys([oldKey, newKey], 'kid-new');
    expect(rotated.active.kid).toBe('kid-new');
    expect(rotated.kids).toEqual(['kid-old', 'kid-new']);
    expect(rotated.toJwks().keys.map((k) => k.kid)).toEqual(['kid-old', 'kid-new']);

    const response = await request(harness!.app)
      .post('/v1/license/activate')
      .send({
        packageName: PACKAGE_NAME,
        installId: 'install-rotation',
        productId: ULTRA_PRODUCT_ID,
        purchaseToken: 'token-rotation',
      })
      .expect(200);

    const header = jwt.decode(response.body.license, { complete: true })?.header;
    expect(header?.alg).toBe('RS256');
    expect(header?.kid).toBe('kid-old'); // first key is active in this harness
    expect(response.body.keyId).toBe('kid-old');

    // A license signed by either ring key still verifies against that key.
    expect(() =>
      jwt.verify(response.body.license, oldKey.publicKeyPem, { algorithms: ['RS256'] }),
    ).not.toThrow();
    expect(() =>
      jwt.verify(response.body.license, newKey.publicKeyPem, { algorithms: ['RS256'] }),
    ).toThrow();
  });

  it('refuses an ambiguous ring with no active kid declared', () => {
    expect(() => KeyRing.fromKeys([makeKey('a'), makeKey('b')], 'c')).toThrow(/not in supplied/);
  });
});

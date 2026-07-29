import request from 'supertest';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { PRO_PRODUCT_ID, ULTRA_PRODUCT_ID } from '../src/entitlement.js';
import { createHarness, PACKAGE_NAME, type Harness } from './helpers.js';

let harness: Harness;

beforeEach(() => {
  // verifyCacheTtlMs: 0 => every refresh re-asks Google about linked tokens.
  harness = createHarness({ verifyCacheTtlMs: 0 });
});

afterEach(() => {
  harness.close();
});

function activate(installId: string, productId: string, purchaseToken: string) {
  return request(harness.app)
    .post('/v1/license/activate')
    .send({ packageName: PACKAGE_NAME, installId, productId, purchaseToken });
}

describe('POST /v1/license/refresh', () => {
  it('re-issues a license from the tokens already linked to the install', async () => {
    await activate('install-refresh-1', ULTRA_PRODUCT_ID, 'token-r1').expect(200);

    const response = await request(harness.app)
      .post('/v1/license/refresh')
      .send({ packageName: PACKAGE_NAME, installId: 'install-refresh-1' })
      .expect(200);

    expect(response.body.tier).toBe('ultra');
    expect(harness.issuer.verify(response.body.license).sub).toBe('install-refresh-1');
  });

  it('drops to free once the purchase stops verifying (refund)', async () => {
    const installId = 'install-refresh-2';
    await activate(installId, PRO_PRODUCT_ID, 'token-r2').expect(200);

    // Simulate Google reporting the purchase as canceled on the next check.
    const original = harness.verifier.verify.bind(harness.verifier);
    harness.verifier.verify = async (input) => {
      const result = await original(input);
      return { ...result, purchaseState: 1, owned: false };
    };

    const response = await request(harness.app)
      .post('/v1/license/refresh')
      .send({ packageName: PACKAGE_NAME, installId })
      .expect(403);

    expect(response.body.error).toBe('entitlement_revoked');
  });

  it('404s for an install with nothing on record', async () => {
    const response = await request(harness.app)
      .post('/v1/license/refresh')
      .send({ packageName: PACKAGE_NAME, installId: 'install-never-seen' })
      .expect(404);

    expect(response.body.error).toBe('unknown_install');
  });

  it('accepts a fresh purchases[] snapshot on refresh', async () => {
    const installId = 'install-refresh-3';
    await activate(installId, PRO_PRODUCT_ID, 'token-r3').expect(200);

    const response = await request(harness.app)
      .post('/v1/license/refresh')
      .send({
        packageName: PACKAGE_NAME,
        installId,
        purchases: [{ productId: ULTRA_PRODUCT_ID, purchaseToken: 'token-r3-ultra' }],
      })
      .expect(200);

    expect(response.body.tier).toBe('ultra');
    expect(response.body.products).toEqual([PRO_PRODUCT_ID, ULTRA_PRODUCT_ID]);
  });
});

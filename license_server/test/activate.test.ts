import request from 'supertest';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
  PRO_PRODUCT_ID,
  ULTRA_PRODUCT_ID,
  ULTRA_UPGRADE_PRODUCT_ID,
} from '../src/entitlement.js';
import { createHarness, AUDIENCE, ISSUER, PACKAGE_NAME, type Harness } from './helpers.js';

let harness: Harness;

beforeEach(() => {
  harness = createHarness();
});

afterEach(() => {
  harness.close();
});

describe('POST /v1/license/activate', () => {
  it('issues an ultra license for a verified ultra purchase', async () => {
    const response = await request(harness.app)
      .post('/v1/license/activate')
      .send({
        packageName: PACKAGE_NAME,
        installId: 'install-aaaaaaaa',
        productId: ULTRA_PRODUCT_ID,
        purchaseToken: 'token-ultra-1',
      })
      .expect(200);

    expect(response.body.tier).toBe('ultra');
    expect(response.body.products).toEqual([ULTRA_PRODUCT_ID]);
    expect(response.body.keyId).toBe('test-key-1');

    const claims = harness.issuer.verify(response.body.license);
    expect(claims.sub).toBe('install-aaaaaaaa');
    expect(claims.tier).toBe('ultra');
    expect(claims.iss).toBe(ISSUER);
    expect(claims.aud).toBe(AUDIENCE);
    expect(claims.pkg).toBe(PACKAGE_NAME);
    expect(claims.exp).toBeGreaterThan(claims.iat);
  });

  it('accepts a full purchases[] snapshot and resolves pro + upgrade to ultra', async () => {
    const response = await request(harness.app)
      .post('/v1/license/activate')
      .send({
        packageName: PACKAGE_NAME,
        installId: 'install-bbbbbbbb',
        purchases: [
          { productId: PRO_PRODUCT_ID, purchaseToken: 'token-pro-1' },
          { productId: ULTRA_UPGRADE_PRODUCT_ID, purchaseToken: 'token-upgrade-1' },
        ],
      })
      .expect(200);

    expect(response.body.tier).toBe('ultra');
    expect(response.body.products).toEqual([PRO_PRODUCT_ID, ULTRA_UPGRADE_PRODUCT_ID]);
  });

  it('combines a new upgrade token with a previously activated pro purchase', async () => {
    const installId = 'install-cccccccc';

    const first = await request(harness.app)
      .post('/v1/license/activate')
      .send({
        packageName: PACKAGE_NAME,
        installId,
        productId: PRO_PRODUCT_ID,
        purchaseToken: 'token-pro-2',
      })
      .expect(200);
    expect(first.body.tier).toBe('pro');

    // Plan §15 gap 2: activating only the upgrade SKU must still see the
    // earlier pro purchase and resolve the union, not the single token.
    const second = await request(harness.app)
      .post('/v1/license/activate')
      .send({
        packageName: PACKAGE_NAME,
        installId,
        productId: ULTRA_UPGRADE_PRODUCT_ID,
        purchaseToken: 'token-upgrade-2',
      })
      .expect(200);

    expect(second.body.tier).toBe('ultra');
    expect(second.body.products).toEqual([PRO_PRODUCT_ID, ULTRA_UPGRADE_PRODUCT_ID]);
  });

  it('re-issues for a new installId on the same purchase token (reinstall / new device)', async () => {
    const body = {
      packageName: PACKAGE_NAME,
      productId: ULTRA_PRODUCT_ID,
      purchaseToken: 'token-ultra-shared',
    };

    const first = await request(harness.app)
      .post('/v1/license/activate')
      .send({ ...body, installId: 'install-old-device' })
      .expect(200);

    // Plan §15 gap 1: a token is not claimed by the first install that used it.
    const second = await request(harness.app)
      .post('/v1/license/activate')
      .send({ ...body, installId: 'install-new-device' })
      .expect(200);

    expect(first.body.tier).toBe('ultra');
    expect(second.body.tier).toBe('ultra');
    expect(harness.issuer.verify(second.body.license).sub).toBe('install-new-device');
    expect(harness.store.countInstallsForToken('token-ultra-shared')).toBe(2);
  });

  it('rejects a purchase Google reports as canceled', async () => {
    const response = await request(harness.app)
      .post('/v1/license/activate')
      .send({
        packageName: PACKAGE_NAME,
        installId: 'install-dddddddd',
        productId: PRO_PRODUCT_ID,
        purchaseToken: 'canceled:token-1',
      })
      .expect(403);

    expect(response.body.error).toBe('no_valid_purchase');
  });

  it('does not entitle a pending purchase', async () => {
    const response = await request(harness.app)
      .post('/v1/license/activate')
      .send({
        packageName: PACKAGE_NAME,
        installId: 'install-eeeeeeee',
        productId: PRO_PRODUCT_ID,
        purchaseToken: 'pending:token-1',
      })
      .expect(403);

    expect(response.body.error).toBe('no_valid_purchase');
  });

  it('rejects a package name outside the allowlist without calling Google', async () => {
    const response = await request(harness.app)
      .post('/v1/license/activate')
      .send({
        packageName: 'com.attacker.clone',
        installId: 'install-ffffffff',
        productId: PRO_PRODUCT_ID,
        purchaseToken: 'token-pro-3',
      })
      .expect(403);

    expect(response.body.error).toBe('package_not_allowed');
    expect(harness.verifier.calls).toHaveLength(0);
  });

  it('rejects an unknown productId without calling Google', async () => {
    const response = await request(harness.app)
      .post('/v1/license/activate')
      .send({
        packageName: PACKAGE_NAME,
        installId: 'install-gggggggg',
        productId: 'aurora_free_lunch',
        purchaseToken: 'token-not-a-real-sku',
      })
      .expect(400);

    expect(response.body.error).toBe('unknown_product');
    expect(harness.verifier.calls).toHaveLength(0);
  });

  it('rejects a body with neither purchases[] nor purchaseToken+productId', async () => {
    const response = await request(harness.app)
      .post('/v1/license/activate')
      .send({ packageName: PACKAGE_NAME, installId: 'install-hhhhhhhh' })
      .expect(400);

    expect(response.body.error).toBe('invalid_request');
  });

  it('rejects unknown fields in the body', async () => {
    const response = await request(harness.app)
      .post('/v1/license/activate')
      .send({
        packageName: PACKAGE_NAME,
        installId: 'install-iiiiiiii',
        productId: PRO_PRODUCT_ID,
        purchaseToken: 'token-pro-4',
        tier: 'ultra',
      })
      .expect(400);

    expect(response.body.error).toBe('invalid_request');
  });
});

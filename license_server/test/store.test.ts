import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { tokenFingerprint, tokenHash } from '../src/logger.js';
import { LicenseStore } from '../src/store.js';

let store: LicenseStore;

beforeEach(() => {
  store = new LicenseStore(':memory:');
});

afterEach(() => {
  store.close();
});

describe('LicenseStore', () => {
  it('preserves first_seen_at across re-verification', () => {
    const first = new Date('2026-07-01T00:00:00Z');
    const later = new Date('2026-07-10T00:00:00Z');

    store.upsertPurchase({
      purchaseToken: 'tok-1',
      productId: 'aurora_pro_unlock',
      packageName: 'com.personal.aurora_downloader',
      orderId: 'GPA.1',
      purchaseState: 0,
      owned: true,
      verifiedAt: first,
    });
    const updated = store.upsertPurchase({
      purchaseToken: 'tok-1',
      productId: 'aurora_pro_unlock',
      packageName: 'com.personal.aurora_downloader',
      orderId: 'GPA.1',
      purchaseState: 0,
      owned: true,
      verifiedAt: later,
    });

    expect(updated.firstSeenAt).toBe(first.toISOString());
    expect(updated.lastVerifiedAt).toBe(later.toISOString());
    expect(updated.revokedAt).toBeNull();
  });

  it('stamps revoked_at when a purchase stops being owned, and clears it if it returns', () => {
    const base = {
      purchaseToken: 'tok-2',
      productId: 'aurora_ultra_unlock',
      packageName: 'com.personal.aurora_downloader',
      orderId: null,
    };

    store.upsertPurchase({ ...base, purchaseState: 0, owned: true, verifiedAt: new Date() });
    const revoked = store.upsertPurchase({
      ...base,
      purchaseState: 1,
      owned: false,
      verifiedAt: new Date(),
    });
    expect(revoked.revokedAt).not.toBeNull();

    const restored = store.upsertPurchase({
      ...base,
      purchaseState: 0,
      owned: true,
      verifiedAt: new Date(),
    });
    expect(restored.revokedAt).toBeNull();
  });

  it('links one purchase to many installs idempotently', () => {
    store.upsertPurchase({
      purchaseToken: 'tok-3',
      productId: 'aurora_pro_unlock',
      packageName: 'com.personal.aurora_downloader',
      orderId: null,
      purchaseState: 0,
      owned: true,
      verifiedAt: new Date(),
    });

    store.linkInstall('install-a', 'tok-3', new Date());
    store.linkInstall('install-a', 'tok-3', new Date());
    store.linkInstall('install-b', 'tok-3', new Date());

    expect(store.countInstallsForToken('tok-3')).toBe(2);
    expect(store.listPurchasesForInstall('install-a')).toHaveLength(1);
    expect(store.listPurchasesForInstall('install-c')).toHaveLength(0);
  });

  it('prunes only licenses that already expired', () => {
    store.recordIssuedLicense({
      jti: 'dead',
      installId: 'i1',
      tier: 'pro',
      issuedAt: '2026-01-01T00:00:00.000Z',
      expiresAt: '2026-02-01T00:00:00.000Z',
    });
    store.recordIssuedLicense({
      jti: 'live',
      installId: 'i1',
      tier: 'pro',
      issuedAt: '2026-07-01T00:00:00.000Z',
      expiresAt: '2099-01-01T00:00:00.000Z',
    });

    expect(store.pruneExpiredLicenses(new Date('2026-07-25T00:00:00Z'))).toBe(1);
    expect(store.stats().licenses).toBe(1);
  });
});

describe('token redaction', () => {
  it('fingerprints are short, stable and not the raw token', () => {
    const token = 'a-very-secret-purchase-token';
    const fp = tokenFingerprint(token);
    expect(fp).toHaveLength(12);
    expect(fp).toBe(tokenFingerprint(token));
    expect(token).not.toContain(fp);
    expect(tokenHash(token).startsWith(fp)).toBe(true);
  });
});

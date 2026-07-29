import {
  isKnownProductId,
  isUpgradeWithoutBase,
  maxTierForOwned,
  type Tier,
} from './entitlement.js';
import { ApiError, ErrorCodes } from './errors.js';
import type { IssuedLicense, LicenseIssuer } from './licenseIssuer.js';
import { log, tokenFingerprint } from './logger.js';
import type { PurchaseVerifier } from './playVerifier.js';
import type { LicenseStore, PurchaseRecord } from './store.js';

export interface PurchaseInput {
  productId: string;
  purchaseToken: string;
}

export interface ResolveInput {
  packageName: string;
  installId: string;
  /** Tokens the client just read from BillingClient. May be empty on refresh. */
  purchases: PurchaseInput[];
  now?: Date;
}

export interface ResolvedEntitlement {
  tier: Tier;
  products: string[];
  license: IssuedLicense;
}

export interface LicenseServiceOptions {
  allowedPackageNames: string[];
  /** How stale a stored verification may be before we re-ask Google. */
  verifyCacheTtlMs: number;
}

/**
 * Turns a set of Play purchase tokens into a signed license.
 *
 * Two rules drive the whole flow:
 *
 * 1. Entitlement is computed from the *union* of everything this install has
 *    ever proven it owns — the tokens submitted now plus the ones already
 *    linked to the installId. Submitting only `aurora_ultra_upgrade` must still
 *    resolve to ultra alongside the earlier `aurora_pro_unlock` (plan §15 gap 2).
 * 2. A token is never "claimed" by one install. Re-activating the same token
 *    from a new installId is the supported reinstall / new-device path
 *    (plan §15 gap 1).
 */
export class LicenseService {
  constructor(
    private readonly store: LicenseStore,
    private readonly verifier: PurchaseVerifier,
    private readonly issuer: LicenseIssuer,
    private readonly options: LicenseServiceOptions,
  ) {}

  /**
   * Verify + issue. Throws ApiError(403) when nothing valid is owned, so the
   * caller can distinguish "drop to free" from a transient server fault.
   */
  async resolve(input: ResolveInput): Promise<ResolvedEntitlement> {
    const now = input.now ?? new Date();
    this.assertPackageAllowed(input.packageName);

    const submitted = dedupeByToken(input.purchases);
    for (const purchase of submitted) {
      if (!isKnownProductId(purchase.productId)) {
        throw ApiError.badRequest(
          ErrorCodes.unknownProduct,
          `Unknown productId "${purchase.productId}"`,
        );
      }
    }

    // 1. Freshly verify everything the client just sent.
    const verifiedNow = new Set<string>();
    for (const purchase of submitted) {
      await this.verifyAndStore(purchase, input.packageName, input.installId, now);
      verifiedNow.add(purchase.purchaseToken);
    }

    // 2. Fold in previously linked purchases, re-verifying stale ones so a
    //    refunded older purchase cannot keep propping up the tier.
    const linked = this.store.listPurchasesForInstall(input.installId);
    for (const record of linked) {
      if (verifiedNow.has(record.purchaseToken)) continue;
      if (!this.isStale(record, now)) continue;
      await this.verifyAndStore(
        { productId: record.productId, purchaseToken: record.purchaseToken },
        record.packageName,
        input.installId,
        now,
      );
    }

    // 3. Recompute from storage — this is the authoritative owned set.
    const owned = this.store
      .listPurchasesForInstall(input.installId)
      .filter((record) => record.owned && record.revokedAt === null)
      .filter((record) => input.packageName === record.packageName)
      .map((record) => record.productId);

    const products = [...new Set(owned)].sort();
    const tier = maxTierForOwned(products);

    if (tier === 'free') {
      log.info('no valid purchase', {
        installId: input.installId,
        submitted: submitted.length,
        linked: linked.length,
      });
      throw ApiError.forbidden(
        linked.length > 0 ? ErrorCodes.entitlementRevoked : ErrorCodes.noValidPurchase,
        'No active purchase found for this install',
      );
    }

    if (isUpgradeWithoutBase(products)) {
      // Legitimate after a refund of the base SKU; the client's tier math
      // grants ultra here too, so we log rather than diverge from it.
      log.warn('upgrade SKU owned without base pro purchase', {
        installId: input.installId,
        products,
      });
    }

    const license = this.issuer.issue({
      installId: input.installId,
      packageName: input.packageName,
      tier,
      products,
      now,
    });

    this.store.recordIssuedLicense({
      jti: license.jti,
      installId: input.installId,
      tier: license.tier,
      issuedAt: license.issuedAt.toISOString(),
      expiresAt: license.expiresAt.toISOString(),
    });

    log.info('license issued', {
      installId: input.installId,
      tier,
      products,
      jti: license.jti,
      kid: license.kid,
      expiresAt: license.expiresAt.toISOString(),
    });

    return { tier, products, license };
  }

  /**
   * Refresh path: no new tokens required, but the install must already be
   * known — otherwise the client has nothing to refresh and should activate.
   */
  async refresh(input: ResolveInput): Promise<ResolvedEntitlement> {
    this.assertPackageAllowed(input.packageName);
    const known = this.store.listPurchasesForInstall(input.installId);
    if (known.length === 0 && input.purchases.length === 0) {
      throw new ApiError(
        404,
        ErrorCodes.unknownInstall,
        'No purchases on record for this install; call /v1/license/activate',
      );
    }
    // Refresh always re-asks Google, regardless of cache age.
    return this.resolve({ ...input, purchases: input.purchases, now: input.now });
  }

  private assertPackageAllowed(packageName: string): void {
    if (!this.options.allowedPackageNames.includes(packageName)) {
      log.warn('rejected package', { packageName });
      throw ApiError.forbidden(
        ErrorCodes.packageNotAllowed,
        `packageName "${packageName}" is not served by this license host`,
      );
    }
  }

  private isStale(record: PurchaseRecord, now: Date): boolean {
    const age = now.getTime() - new Date(record.lastVerifiedAt).getTime();
    return age >= this.options.verifyCacheTtlMs;
  }

  private async verifyAndStore(
    purchase: PurchaseInput,
    packageName: string,
    installId: string,
    now: Date,
  ): Promise<void> {
    const result = await this.verifier.verify({
      packageName,
      productId: purchase.productId,
      purchaseToken: purchase.purchaseToken,
    });

    this.store.upsertPurchase({
      purchaseToken: purchase.purchaseToken,
      productId: purchase.productId,
      packageName,
      orderId: result.orderId,
      purchaseState: result.purchaseState,
      owned: result.owned,
      verifiedAt: now,
    });

    // Only link real purchases — an invalid token should not leave a trail
    // that a later refresh would keep re-verifying.
    if (result.owned) {
      const before = this.store.countInstallsForToken(purchase.purchaseToken);
      this.store.linkInstall(installId, purchase.purchaseToken, now);
      const after = this.store.countInstallsForToken(purchase.purchaseToken);
      if (after > before && after > 1) {
        // Expected on reinstall / new device. Sharp growth is the signal that
        // one purchase is being passed around; alert on it if it ever matters.
        log.info('purchase linked to additional install', {
          token: tokenFingerprint(purchase.purchaseToken),
          productId: purchase.productId,
          installCount: after,
        });
      }
    }
  }
}

function dedupeByToken(purchases: PurchaseInput[]): PurchaseInput[] {
  const seen = new Map<string, PurchaseInput>();
  for (const purchase of purchases) {
    seen.set(`${purchase.productId}:${purchase.purchaseToken}`, purchase);
  }
  return [...seen.values()];
}

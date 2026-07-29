/**
 * Tier math — a direct mirror of `lib/premium/pro_entitlement.dart`.
 *
 * The client and the server MUST agree on how a set of owned product IDs maps
 * to a tier. If these two drift, a user sees one tier in the UI and a different
 * one in their license JWT. Any change here needs the matching Dart change.
 */

export type Tier = 'free' | 'pro' | 'ultra';

export const PRO_PRODUCT_ID = 'aurora_pro_unlock';
export const ULTRA_PRODUCT_ID = 'aurora_ultra_unlock';
export const ULTRA_UPGRADE_PRODUCT_ID = 'aurora_ultra_upgrade';

export const ALL_PRODUCT_IDS: readonly string[] = [
  PRO_PRODUCT_ID,
  ULTRA_PRODUCT_ID,
  ULTRA_UPGRADE_PRODUCT_ID,
];

const TIER_RANK: Record<Tier, number> = { free: 0, pro: 1, ultra: 2 };

export function isKnownProductId(id: string): boolean {
  return ALL_PRODUCT_IDS.includes(id);
}

/** Tier a single product grants, or null when the product is unknown. */
export function tierForProductId(id: string): Tier | null {
  switch (id) {
    case PRO_PRODUCT_ID:
      return 'pro';
    case ULTRA_PRODUCT_ID:
    case ULTRA_UPGRADE_PRODUCT_ID:
      return 'ultra';
    default:
      return null;
  }
}

/**
 * Highest tier across a set of owned products.
 *
 * Plan §15 gap 2: entitlement is computed from the *whole* owned set, never
 * from the single token being activated — `aurora_ultra_upgrade` only exists
 * as a follow-on to `aurora_pro_unlock`.
 */
export function maxTierForOwned(owned: Iterable<string>): Tier {
  let max: Tier = 'free';
  for (const id of owned) {
    const t = tierForProductId(id);
    if (t && TIER_RANK[t] > TIER_RANK[max]) max = t;
  }
  return max;
}

export function tierAtLeast(tier: Tier, min: Tier): boolean {
  return TIER_RANK[tier] >= TIER_RANK[min];
}

/**
 * True when the upgrade SKU is owned without its base Pro purchase.
 *
 * Not an error — Play can legitimately return this after a refund of the base
 * product — but it is worth logging, and it mirrors the "upgrade-only
 * arbitrage" note in ProEntitlement.applyOwnedProducts.
 */
export function isUpgradeWithoutBase(owned: Iterable<string>): boolean {
  const set = new Set(owned);
  return set.has(ULTRA_UPGRADE_PRODUCT_ID) && !set.has(PRO_PRODUCT_ID);
}

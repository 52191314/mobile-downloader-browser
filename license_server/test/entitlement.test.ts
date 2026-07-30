import { describe, expect, it } from 'vitest';
import {
  isKnownProductId,
  isUpgradeWithoutBase,
  maxTierForOwned,
  PRO_PRODUCT_ID,
  tierForProductId,
  ULTRA_PRODUCT_ID,
  ULTRA_UPGRADE_PRODUCT_ID,
} from '../src/entitlement.js';

describe('entitlement tier math (mirror of pro_entitlement.dart)', () => {
  it('maps each SKU to the same tier the client does', () => {
    expect(tierForProductId(PRO_PRODUCT_ID)).toBe('pro');
    expect(tierForProductId(ULTRA_PRODUCT_ID)).toBe('ultra');
    expect(tierForProductId(ULTRA_UPGRADE_PRODUCT_ID)).toBe('ultra');
    expect(tierForProductId('some_other_sku')).toBeNull();
  });

  it('returns free for an empty owned set', () => {
    expect(maxTierForOwned([])).toBe('free');
  });

  it('ignores unknown products when computing the max', () => {
    expect(maxTierForOwned(['not_a_real_sku'])).toBe('free');
    expect(maxTierForOwned(['not_a_real_sku', PRO_PRODUCT_ID])).toBe('pro');
  });

  it('takes the highest tier across the owned set', () => {
    expect(maxTierForOwned([PRO_PRODUCT_ID])).toBe('pro');
    expect(maxTierForOwned([PRO_PRODUCT_ID, ULTRA_UPGRADE_PRODUCT_ID])).toBe('ultra');
    expect(maxTierForOwned([ULTRA_PRODUCT_ID, PRO_PRODUCT_ID])).toBe('ultra');
  });

  it('flags an upgrade SKU held without its base purchase', () => {
    expect(isUpgradeWithoutBase([ULTRA_UPGRADE_PRODUCT_ID])).toBe(true);
    expect(isUpgradeWithoutBase([PRO_PRODUCT_ID, ULTRA_UPGRADE_PRODUCT_ID])).toBe(false);
    expect(isUpgradeWithoutBase([ULTRA_PRODUCT_ID])).toBe(false);
  });

  it('only recognises the three Aurora SKUs', () => {
    expect(isKnownProductId(PRO_PRODUCT_ID)).toBe(true);
    expect(isKnownProductId('aurora_pro_unlock_v2')).toBe(false);
  });
});

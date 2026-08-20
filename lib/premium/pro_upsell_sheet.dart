import 'package:flutter/material.dart';

import '../analytics/aurora_analytics_service.dart';
import '../theme/aurora_palette.dart';
import '../theme/aurora_tokens.dart';
import 'build_channel.dart';
import 'play_billing_service.dart';
import 'pro_entitlement.dart';
import 'pro_features.dart';

/// Optional billing handle so the upsell sheet can start a purchase on Play.
/// Set once from app shell after [PlayBillingService] is created.
PlayBillingService? proUpsellBilling;

/// Optional entitlement handle so the upsell sheet can read the caller's
/// current tier. Set once from app shell. Falls back to [EntitlementTier.free]
/// if unset.
ProEntitlement? proUpsellEntitlement;

/// Shows the two-tier upsell bottom sheet for a blocked [feature].
///
/// Behavior by caller tier (see plan frequency table):
/// - free hitting a Pro feature → Pro + Ultra CTAs (preferred Pro).
/// - free hitting an Ultra feature → Ultra-focused, Pro shown as stepping stone.
/// - pro hitting an Ultra feature → Ultra-only upsell (upgrade or full CTA).
///
/// Every gated control should call this instead of silently failing:
/// ```dart
/// if (!ProFeatures.allows(feature, tier)) {
///   showProUpsell(context, feature);
///   return;
/// }
/// ```
Future<void> showProUpsell(
  BuildContext context,
  ProFeature feature, {
  EntitlementTier? userTier,
}) {
  final tier = userTier ?? proUpsellEntitlement?.tier ?? EntitlementTier.free;
  final featureName = ProFeatures.displayName(feature);
  final minTier = ProFeatures.minimumTier[feature]!;

  AuroraAnalyticsService.instance.logUpsellViewed(
    trigger: feature.name,
    currentTier: tier.name,
  );

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) {
      final palette = AuroraPalette.of(ctx);
      final billing = proUpsellBilling;

      // What the user needs to buy to clear this gate.
      final needsUltra = minTier == EntitlementTier.ultra;
      final showProCta = !tier.isAtLeastPro;
      final showUltraCta = !tier.isUltra;

      // Pro CTA: buy Pro (only meaningful if the user is free).
      // Ultra CTA: upgrade if Pro owner (and upgrade SKU live), else full Ultra.
      final ultraUpgradeAvailable =
          billing?.showUltraUpgrade ?? false;
      final ultraFullAvailable = billing?.showUltraFull ?? false;

      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: palette.textTertiary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 20),
              Icon(
                Icons.auto_awesome,
                size: 40,
                color: palette.accentFrost,
              ),
              const SizedBox(height: 12),
              Text(
                needsUltra ? 'Aurora Ultra' : 'Aurora Pro',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: palette.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '"$featureName" is a ${ProFeatures.tierBadge(feature)} feature.',
                style: TextStyle(
                  fontSize: 14,
                  color: palette.textSecondary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              _buildBenefitsList(palette, needsUltra),
              const SizedBox(height: 24),
              if (showProCta)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () async {
                      Navigator.of(ctx).pop();
                      if (!BuildChannel.isPlay || billing == null) return;
                      AuroraAnalyticsService.instance.logPurchaseInitiated(
                        productId: 'aurora_pro',
                        targetTier: 'pro',
                      );
                      await billing.buyPro();
                    },
                    icon: const Icon(Icons.shopping_cart_outlined, size: 18),
                    label: Text(
                      BuildChannel.isPlay
                          ? (billing?.localizedProPrice != null
                              ? 'Get Aurora Pro — ${billing!.localizedProPrice}'
                              : 'Get Aurora Pro')
                          : 'Available on Google Play',
                    ),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      textStyle: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              if (showProCta && showUltraCta) const SizedBox(height: 10),
              if (showUltraCta)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: ultraUpgradeAvailable || ultraFullAvailable
                        ? () async {
                            Navigator.of(ctx).pop();
                            if (!BuildChannel.isPlay || billing == null) return;
                            if (ultraUpgradeAvailable) {
                              AuroraAnalyticsService.instance.logPurchaseInitiated(
                                productId: 'aurora_ultra_upgrade',
                                targetTier: 'ultra',
                              );
                              await billing.buyUltraUpgrade();
                            } else {
                              AuroraAnalyticsService.instance.logPurchaseInitiated(
                                productId: 'aurora_ultra',
                                targetTier: 'ultra',
                              );
                              await billing.buyUltra();
                            }
                          }
                        : null,
                    icon: const Icon(Icons.star_outlined, size: 18),
                    label: Text(
                      ultraUpgradeAvailable
                          ? (billing?.localizedUltraUpgradePrice != null
                              ? 'Upgrade to Ultra — ${billing!.localizedUltraUpgradePrice}'
                              : 'Upgrade to Ultra')
                          : (billing?.localizedUltraPrice != null
                              ? 'Get Aurora Ultra — ${billing!.localizedUltraPrice}'
                              : 'Get Aurora Ultra'),
                    ),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      textStyle: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              if (BuildChannel.isPlay)
                TextButton(
                  onPressed: () async {
                    Navigator.of(ctx).pop();
                    await billing?.restorePurchases();
                  },
                  child: Text(
                    'Restore purchases',
                    style: TextStyle(
                      color: palette.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(
                  'Not now',
                  style: TextStyle(
                    color: palette.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Resolves the current entitlement tier for callers that don't pass it
/// explicitly (kept simple: reads the global debug-aware tier via the
/// billing service's entitlement when available).
Widget _buildBenefitsList(AColors palette, bool ultra) {
  final benefits = ultra
      ? [
          (Icons.star_outlined, 'Everything in Pro\n+ Ultra'),
          (Icons.speed, '64 concurrent\n64 chunks'),
          (Icons.movie_outlined, 'FFmpeg media\nsuite'),
          (Icons.folder_open_outlined, 'Folder watcher\nAutomation API'),
          (Icons.lock_outline, 'Vault sync\nUltra extras'),
          (Icons.auto_awesome, 'Server-grade\nengine'),
        ]
      : [
          (Icons.star_rounded, 'Favorite videos\n+ LAN Send to PC'),
          (Icons.speed, '16 concurrent\n32 chunks (Turbo)'),
          (Icons.shield_outlined, 'Private vault\nAuto-backup'),
          (Icons.group_work_outlined, 'Unlimited tab\ngroups & colors'),
          (Icons.filter_alt_outlined, 'Extra filter lists\n& tracker pack'),
          (Icons.auto_awesome, 'Batch capture\n& series grab'),
        ];

  return Column(
    children: [
      for (int row = 0; row < benefits.length; row += 3)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              for (int i = row; i < row + 3 && i < benefits.length; i++)
                Expanded(
                  child: Column(
                    children: [
                      Icon(
                        benefits[i].$1,
                        size: 22,
                        color: palette.accentFrost,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        benefits[i].$2,
                        style: TextStyle(
                          fontSize: 11,
                          color: palette.textSecondary,
                          height: 1.3,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              for (int fill = row + (3 - (row % 3));
                  fill < row + 3 &&
                      fill <
                          benefits.length +
                              (3 - (benefits.length % 3)) % 3;
                  fill++)
                const Expanded(child: SizedBox.shrink()),
            ],
          ),
        ),
    ],
  );
}

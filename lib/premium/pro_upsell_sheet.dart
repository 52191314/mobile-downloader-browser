import 'package:flutter/material.dart';

import '../theme/aurora_palette.dart';
import '../theme/aurora_tokens.dart';
import 'pro_features.dart';

/// Shows the Pro upsell bottom sheet for a blocked feature.
///
/// Every gated control should call this instead of silently failing:
/// ```dart
/// if (!ProFeatures.allows(feature, isPro)) {
///   showProUpsell(context, feature);
///   return;
/// }
/// ```
///
/// The sheet lists:
/// 1. The blocked feature name
/// 2. A short benefits list
/// 3. A "Not now" dismiss (and later a Get Pro button via P0.4)
Future<void> showProUpsell(BuildContext context, ProFeature feature) {
  final featureName = ProFeatures.displayName(feature);

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) {
      final palette = AuroraPalette.of(ctx);

      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Drag handle
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: palette.textTertiary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 20),

              // Pro icon
              Icon(
                Icons.auto_awesome,
                size: 40,
                color: palette.accentFrost,
              ),
              const SizedBox(height: 12),

              // Title
              Text(
                'Aurora Pro',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: palette.textPrimary,
                ),
              ),
              const SizedBox(height: 4),

              // Subtitle — what's blocked
              Text(
                '"$featureName" is a Pro feature.',
                style: TextStyle(
                  fontSize: 14,
                  color: palette.textSecondary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),

              // Benefits list
              _buildBenefitsList(palette),
              const SizedBox(height: 24),

              // CTA button (placeholder until P0.4)
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    // TODO(P0.4): launch Play Billing purchase flow.
                  },
                  icon: const Icon(Icons.shopping_cart_outlined, size: 18),
                  label: const Text('Get Aurora Pro'),
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

              // Dismiss
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

/// Renders the Pro benefits summary (3-column grid of icons + labels).
Widget _buildBenefitsList(AColors palette) {
  final benefits = [
    (Icons.filter_alt_outlined, 'All filter lists\n+ tracker pack'),
    (Icons.swap_horiz, '16 concurrent\n32 chunks'),
    (Icons.cloud_sync_outlined, 'Drive sync\nAuto-backup'),
    (Icons.group_work_outlined, 'Unlimited tab\ngroups & colors'),
    (Icons.tab_outlined, 'Per-site profiles\n& UA maps'),
    (Icons.auto_awesome, 'Download rules\n& schedules'),
  ];

  return Column(
    children: [
      for (int row = 0; row < benefits.length; row += 3)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              for (int i = row;
                  i < row + 3 && i < benefits.length;
                  i++)
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
              // Fill remaining columns with empty space for balanced layout
              for (int fill = row + (3 - (row % 3));
                  fill < row + 3 && fill < benefits.length + (3 - (benefits.length % 3)) % 3;
                  fill++)
                const Expanded(child: SizedBox.shrink()),
            ],
          ),
        ),
    ],
  );
}

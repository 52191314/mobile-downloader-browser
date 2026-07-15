import 'package:flutter/material.dart';

import '../../theme/aurora_tokens.dart';

/// Centralized 8-swatch palette used to color-code tab groups
/// (Samsung Browser-style). The swatches are drawn from the existing
/// [AColors] tokens so light-mode propagation is automatic.
///
/// The 8 colors are picked to be visually distinct in both light and
/// dark themes and to keep luminance contrast against the glass
/// surface above WCAG AA for both the swatch fill and the label text.
class TabGroupPalette {
  TabGroupPalette._();

  /// Number of supported swatches.
  static const int swatchCount = 8;

  /// Default palette swatch list. Order is stable — changing it would
  /// shift color assignments for un-overridden groups, so any re-order
  /// should be paired with a migration in `tab_groups.json` reads.
  static final List<Color> swatches = <Color>[
    AColors.dark().groupCyan,    // 0 — accent
    AColors.dark().groupAmber,   // 1
    AColors.dark().groupPurple,  // 2
    AColors.dark().groupGreen,   // 3
    AColors.dark().groupRed,     // 4
    AColors.dark().groupOrange,  // 5
    AColors.dark().groupBlue,    // 6
    AColors.dark().groupPink,    // 7
  ];

  /// Stable color index for a given group name. Same name → same index
  /// across sessions, regardless of whether the group has been
  /// persisted before. The hash is computed on the lower-cased, trimmed
  /// name to make the assignment order-insensitive.
  static int forName(String name) {
    final trimmed = name.trim().toLowerCase();
    if (trimmed.isEmpty) return 0;
    return trimmed.hashCode.abs() % swatchCount;
  }

  /// Resolve the color for a group given an optional [colorIndex]
  /// override (from [TabGroup.colorIndex]) and a fallback group name.
  /// If [colorIndex] is `null` or out-of-range, [forName] is used.
  static Color colorFor({int? colorIndex, required String? groupName}) {
    if (colorIndex != null && colorIndex >= 0 && colorIndex < swatchCount) {
      return swatches[colorIndex];
    }
    return swatches[forName(groupName ?? '')];
  }

  /// Returns the color for a tab, looking up the group's explicit color
  /// index from the tab first, then falling back to the name hash.
  static Color colorForTab({
    required int? colorIndex,
    required String? groupName,
  }) =>
      colorFor(colorIndex: colorIndex, groupName: groupName);

  /// Human-readable label for a swatch (used in the picker a11y
  /// tooltip). Currently English; could be localized later.
  static String labelFor(int index) {
    switch (index) {
      case 0:
        return 'Cyan';
      case 1:
        return 'Amber';
      case 2:
        return 'Purple';
      case 3:
        return 'Green';
      case 4:
        return 'Red';
      case 5:
        return 'Orange';
      case 6:
        return 'Blue';
      case 7:
        return 'Pink';
      default:
        return 'Color $index';
    }
  }
}
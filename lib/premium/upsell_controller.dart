import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'local_funnel_store.dart';
import 'pro_entitlement.dart';
import 'pro_features.dart';
import 'pro_upsell_sheet.dart';

/// Controls upsell sheet frequency and routing.
///
/// Frequency rules (normative):
/// - free hitting Pro/Ultra → two-tier sheet; counts toward 1/session, 2/day.
/// - pro hitting Ultra → Ultra-only upsell; **unlimited** (no free frequency).
/// - ultra → never shown.
/// - snack-only (frequency exceeded) → never counts.
/// - Session = app process lifetime. `recordShown` only when sheet displayed.
class UpsellController {
  UpsellController._();

  static int _sessionShown = 0;
  static const int maxPerSession = 1;
  static const int maxPerDay = 2;

  static Future<File> _stateFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/upsell_state.json');
  }

  /// Whether a free automatic/contextual upsell may be shown now.
  static Future<bool> canShowFree() async {
    if (_sessionShown >= maxPerSession) return false;
    final day = await _today();
    final data = await _readState();
    if (data['day'] == day && (data['shown'] as int? ?? 0) >= maxPerDay) {
      return false;
    }
    return true;
  }

  /// Show the appropriate upsell for [feature] given [userTier].
  ///
  /// Returns true if a sheet was actually shown (so callers can record).
  static Future<bool> show(
    BuildContext context, {
    required ProFeature feature,
    required EntitlementTier userTier,
  }) async {
    final min = ProFeatures.minimumTier[feature]!;
    if (userTier.isAtLeast(min)) return false; // already allowed
    // P14 no-nag: Pro/Ultra never see Pro-tier upsell sheets.
    if (userTier.isAtLeastPro && min == EntitlementTier.pro) return false;

    if (userTier == EntitlementTier.free) {
      if (!await canShowFree()) {
        _showSnackLimit(context, feature);
        return false;
      }
    }
    // Pro hitting Ultra: always allow (no free frequency cap).

    await showProUpsell(context, feature, userTier: userTier);
    if (userTier == EntitlementTier.free) {
      await _recordShown();
      LocalFunnelStore.record('upsell_shown', props: {
        'feature': feature.name,
        'tier': userTier.name,
      });
    }
    return true;
  }

  static void _showSnackLimit(BuildContext context, ProFeature feature) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          '${ProFeatures.displayName(feature)} is an Aurora '
          '${ProFeatures.tierBadge(feature)} feature.',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  static Future<void> _recordShown() async {
    _sessionShown++;
    final day = await _today();
    final data = await _readState();
    if (data['day'] == day) {
      data['shown'] = (data['shown'] as int? ?? 0) + 1;
    } else {
      data['day'] = day;
      data['shown'] = 1;
    }
    await _writeState(data);
  }

  static Future<String> _today() async {
    // Local calendar date string (device timezone).
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  static Future<Map<String, dynamic>> _readState() async {
    try {
      final f = await _stateFile();
      if (!await f.exists()) return <String, dynamic>{};
      final decoded = jsonDecode(await f.readAsString());
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (e) {
      if (kDebugMode) debugPrint('[UpsellController] readState failed: $e');
    }
    return <String, dynamic>{};
  }

  static Future<void> _writeState(Map<String, dynamic> data) async {
    try {
      final f = await _stateFile();
      await f.writeAsString(jsonEncode(data));
    } catch (e) {
      if (kDebugMode) debugPrint('[UpsellController] writeState failed: $e');
    }
  }
}

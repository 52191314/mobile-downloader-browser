import 'package:flutter/foundation.dart';

import 'pro_entitlement_store.dart';

/// Pro entitlement service — the single source of truth for whether the
/// current user has Aurora Pro unlocked.
///
/// Usage:
/// ```dart
/// final entitlement = ProEntitlement();
/// if (entitlement.isPro) { ... }
/// ```
///
/// In **debug/profile** builds, you can toggle Pro for testing via
/// `setDebugPro(true)` from Settings → Aurora Pro. The override is
/// **never** persisted to disk and resets on app restart.
///
/// In **release** builds, debug override is a no-op.
///
/// Play channel: [refresh] / [PlayBillingService] grants Pro after purchase
/// or restore. Last-known grant is cached offline via [ProEntitlementStore].
class ProEntitlement extends ChangeNotifier {
  bool _isPro = false;
  bool _debugOverride = false;
  String _source = 'none';

  /// Whether the user has Pro unlocked.
  bool get isPro => _isPro || _debugOverride;

  /// Where Pro came from: `none`, `play`, `cache`, `debug`.
  String get source => _debugOverride ? 'debug' : _source;

  /// Force Pro on/off in debug/profile builds (no-op in release).
  void setDebugPro(bool value) {
    if (kReleaseMode) return;
    if (_debugOverride == value) return;
    _debugOverride = value;
    notifyListeners();
  }

  /// Load last-known entitlement from disk (offline cache).
  Future<void> loadCachedEntitlement() async {
    final data = await ProEntitlementStore.read();
    if (data == null) return;
    final cached = data['isPro'] == true;
    if (cached && !_isPro) {
      _isPro = true;
      _source = (data['source'] as String?) ?? 'cache';
      notifyListeners();
    }
  }

  /// Refresh entitlement from Play Billing / cached receipt.
  /// Prefer calling [PlayBillingService.init] / [restorePurchases].
  Future<void> refresh() async {
    await loadCachedEntitlement();
  }

  /// Persist a verified Pro entitlement (called by Play purchase flow).
  Future<void> grantPro({String source = 'play'}) async {
    final changed = !_isPro || _source != source;
    _isPro = true;
    _source = source;
    await ProEntitlementStore.write(isPro: true, source: source);
    if (changed) notifyListeners();
  }

  /// Revoke Pro (e.g., refund detected).
  Future<void> revokePro() async {
    if (!_isPro && !_debugOverride) return;
    _isPro = false;
    _source = 'none';
    await ProEntitlementStore.write(isPro: false, source: 'none');
    notifyListeners();
  }
}

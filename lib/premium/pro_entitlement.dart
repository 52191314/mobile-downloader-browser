import 'package:flutter/foundation.dart';

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
/// Future: `refresh()` will talk to Play Billing (P0.4).
class ProEntitlement extends ChangeNotifier {
  bool _isPro = false;
  bool _debugOverride = false;

  /// Whether the user has Pro unlocked.
  bool get isPro => _isPro || _debugOverride;

  /// Force Pro on/off in debug/profile builds (no-op in release).
  void setDebugPro(bool value) {
    // Only allow debug toggle in non-release builds.
    if (kReleaseMode) return;
    if (_debugOverride == value) return;
    _debugOverride = value;
    notifyListeners();
  }

  /// Refresh entitlement from Play Billing / cached receipt.
  /// Placeholder until P0.4 is implemented.
  Future<void> refresh() async {
    // TODO(P0.4): query Play Billing purchase status.
  }

  /// Persist a server-verified Pro entitlement (called by P0.4 purchase flow).
  void grantPro() {
    if (_isPro) return;
    _isPro = true;
    notifyListeners();
  }

  /// Revoke Pro (e.g., refund detected).
  void revokePro() {
    if (!_isPro && !_debugOverride) return;
    _isPro = false;
    notifyListeners();
  }
}

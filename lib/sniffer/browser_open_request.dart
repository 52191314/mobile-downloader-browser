import 'package:flutter/foundation.dart';

/// Cross-tab bus: Queue / intents publish a URL; [SnifferScreen] consumes it.
///
/// The shared [SnifferBrowserController.openUrlInNewTab] callback proved
/// unreliable (logs showed the call from main with no matching page load).
/// This notifier is owned by [AuroraHome] and listened to by [SnifferScreen]
/// so external opens do not depend on WebView-controller callback wiring.
class BrowserOpenRequestBus extends ChangeNotifier {
  String? _url;
  int _seq = 0;

  /// Latest requested URL (may be null after clear).
  String? get url => _url;

  /// Monotonic sequence so listeners re-fire even for the same URL string.
  int get seq => _seq;

  void request(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;
    _url = trimmed;
    _seq++;
    notifyListeners();
  }

  void clear() {
    _url = null;
  }
}

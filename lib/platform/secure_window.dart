/// Android FLAG_SECURE toggle for sensitive screens (vault, recovery key).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('aurora_downloader/secure_window');

/// Enables/disables [FLAG_SECURE] on the activity window (blocks screenshots
/// and recent-app previews on Android). No-op on non-Android.
class SecureWindow {
  SecureWindow._();

  static Future<void> setSecure(bool enabled) async {
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod<void>('setSecure', {'enabled': enabled});
    } on MissingPluginException {
      // Desktop / tests.
    } catch (e) {
      if (kDebugMode) debugPrint('[SecureWindow] setSecure failed: $e');
    }
  }
}

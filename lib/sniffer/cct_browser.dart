import 'package:flutter/services.dart';

/// Dart wrapper for launching Android Chrome Custom Tabs (CCT) with an in-app
/// "Sniff & Download" toolbar button for WAF-blocked hosts (xchina.co).
class CctBrowser {
  static const MethodChannel _channel = MethodChannel('aurora_downloader/cct');

  /// Returns true if Chrome Custom Tabs service is available on this device.
  static Future<bool> isSupported() async {
    try {
      final res = await _channel.invokeMethod<bool>('isCustomTabSupported');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Launches [url] inside an in-app Chrome Custom Tab with a custom
  /// "Sniff & Download" action button in the toolbar.
  static Future<bool> openCustomTab(String url, {String? title}) async {
    try {
      final res = await _channel.invokeMethod<bool>('openCustomTab', {
        'url': url,
        'title': title ?? '',
      });
      return res ?? false;
    } catch (_) {
      return false;
    }
  }
}

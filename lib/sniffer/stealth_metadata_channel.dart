import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

/// Native platform channel that applies Chrome-like Client Hints metadata
/// to an Android WebView, replacing "Android WebView" with "Google Chrome"
/// in the `Sec-CH-UA` header that the Chromium engine sends automatically.
///
/// This is critical for bypassing Cloudflare WAF detection, which cross-checks
/// the `Sec-CH-UA` header against the `User-Agent` string and blocks requests
/// where `"Android WebView"` appears as a brand.
class StealthMetadataChannel {
  static const _channel = MethodChannel('aurora_downloader/webview_stealth');

  /// Applies Chrome-like Client Hints metadata to the WebView identified by
  /// [webViewId]. The [chromeVersion] should match the version from the
  /// system's native User-Agent to maintain consistency with Sec-CH-UA.
  ///
  /// Returns the number of WebViews patched, or `-1` if the feature is unsupported.
  static Future<int> applyStealthMetadata({
    required String chromeVersion,
  }) async {
    try {
      final result = await _channel.invokeMethod<int>('applyStealthMetadata', {
        'chromeVersion': chromeVersion,
      });
      return result ?? 0;
    } catch (e) {
      debugPrint('[StealthMetadata] Failed to apply: $e');
      return 0;
    }
  }

  /// Extracts the Chrome major version from a User-Agent string.
  /// e.g. "... Chrome/124.0.6367.61 ..." → "124"
  static String? extractChromeVersion(String? userAgent) {
    if (userAgent == null) return null;
    final match = RegExp(r'Chrome/(\d+)').firstMatch(userAgent);
    return match?.group(1);
  }

  /// Extracts the full Chrome version from a User-Agent string.
  /// e.g. "... Chrome/124.0.6367.61 ..." → "124.0.6367.61"
  static String? extractFullChromeVersion(String? userAgent) {
    if (userAgent == null) return null;
    final match = RegExp(r'Chrome/([\d.]+)').firstMatch(userAgent);
    return match?.group(1);
  }
}

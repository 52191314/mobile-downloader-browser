import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Provides Android-native network operations that bypass Dart's
/// `dart:io` HTTP client.  The native Android HTTP stack
/// (`HttpURLConnection` in this implementation) produces a TLS
/// fingerprint (JA3) that Cloudflare and similar WAFs accept —
/// whereas Dart's `http.Client` triggers challenge pages on
/// surrit.com, beeg24, and many other streaming CDNs.
///
/// All methods are static; instantiation is not needed.
class NetworkBindingService {
  static const MethodChannel _channel = MethodChannel(
    'aurora_downloader/network',
  );

  /// Returns `true` if the process is now bound to the default active
  /// network.  No-op on non-Android platforms.
  static Future<bool> bindProcessToDefaultNetwork() async {
    if (!Platform.isAndroid) return true;
    try {
      final result = await _channel.invokeMethod<bool>(
        'bindProcessToNetwork',
      );
      if (kDebugMode) {
        debugPrint(
          '[NetworkBindingService] bindProcessToNetwork -> ${result ?? false}',
        );
      }
      return result ?? false;
    } on PlatformException catch (e) {
      if (kDebugMode) {
        debugPrint(
          '[NetworkBindingService] bindProcessToNetwork failed: '
          'code=${e.code} message=${e.message}',
        );
      }
      return false;
    } on MissingPluginException {
      return true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[NetworkBindingService] unexpected error: $e');
      }
      return false;
    }
  }

  /// Fetches [url] through Android's native [HttpURLConnection], which
  /// behaves like a normal Android app's HTTP stack and does not trigger
  /// Cloudflare WAF challenge pages the way Dart's `http.Client` does.
  ///
  /// Returns `{statusCode: int, body: String}` on success or `null` on
  /// any error.  Never throws.
  ///
  /// The [headers] map is forwarded to the native side; known-good
  /// defaults are applied by the native caller for `User-Agent`,
  /// `Referer`, `Origin`, `Accept`, and `Accept-Language` when those
  /// keys are absent.
  static Future<Map<String, dynamic>?> fetchUrl(
    String url, {
    Map<String, String>? headers,
    String? cookieHeader,
  }) async {
    if (!Platform.isAndroid) return null;
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'fetchUrl',
        {
          'url': url,
          'referer': headers?['Referer'] ?? '',
          'origin': headers?['Origin'] ?? '',
          'userAgent': headers?['User-Agent'] ?? '',
          if (cookieHeader != null && cookieHeader.isNotEmpty)
            'cookie': cookieHeader,
        },
      );
      if (kDebugMode) {
        debugPrint(
          '[NetworkBindingService] fetchUrl statusCode=${result?['statusCode']} '
          'body=${(result?['body'] as String?)?.substring(0, 80).replaceAll('\n', ' ')}…',
        );
      }
      return result;
    } on MissingPluginException {
      return null;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[NetworkBindingService] fetchUrl error: $e');
      }
      return null;
    }
  }

  /// Streams a binary resource (HLS segment, etc.) to [filePath] using
  /// Android native [HttpURLConnection] + WebView [CookieManager] cookies.
  ///
  /// This is the high-throughput path (similar to 1DM): no Dart TLS, no
  /// WebView base64 bridge. Returns `{statusCode, bytesWritten}` or null.
  static Future<Map<String, dynamic>?> streamSegmentToFile(
    String url,
    String filePath, {
    Map<String, String>? headers,
    String? cookieHeader,
  }) async {
    if (!Platform.isAndroid) return null;
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'streamSegmentToFile',
        {
          'url': url,
          'filePath': filePath,
          'referer': headers?['Referer'] ?? headers?['referer'] ?? '',
          'origin': headers?['Origin'] ?? headers?['origin'] ?? '',
          'userAgent': headers?['User-Agent'] ?? headers?['user-agent'] ?? '',
          if (cookieHeader != null && cookieHeader.isNotEmpty)
            'cookie': cookieHeader,
        },
      );
      return result;
    } on MissingPluginException {
      return null;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[NetworkBindingService] streamSegmentToFile error: $e');
      }
      return null;
    }
  }
}

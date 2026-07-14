import 'dart:convert';
import 'dart:io';

import '../logging/aurora_log.dart';
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
      AuroraLog.instance.debug(
        'bindProcessToNetwork -> ${result ?? false}',
        category: LogCategory.platform,
        screen: LogScreen.background,
        eventType: LogEventType.network,
      );
      return result ?? false;
    } on PlatformException catch (e) {
      if (kDebugMode) {
        debugPrint(
          '[NetworkBindingService] bindProcessToNetwork failed: '
          'code=${e.code} message=${e.message}',
        );
      }
      AuroraLog.instance.error(
        'bindProcessToNetwork failed: code=${e.code} message=${e.message}',
        category: LogCategory.platform,
        screen: LogScreen.background,
        eventType: LogEventType.error,
      );
      return false;
    } on MissingPluginException {
      return true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[NetworkBindingService] unexpected error: $e');
      }
      AuroraLog.instance.error(
        'NetworkBindingService unexpected error: $e',
        category: LogCategory.platform,
        screen: LogScreen.background,
        eventType: LogEventType.error,
      );
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
      AuroraLog.instance.debug(
        'fetchUrl statusCode=${result?['statusCode']} '
        'body=${(result?['body'] as String?)?.substring(0, 80).replaceAll('\n', ' ')}…',
        category: LogCategory.platform,
        screen: LogScreen.background,
        eventType: LogEventType.network,
      );
      return result;
    } on MissingPluginException {
      return null;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[NetworkBindingService] fetchUrl error: $e');
      }
      AuroraLog.instance.error(
        'NetworkBindingService fetchUrl error: $e',
        category: LogCategory.platform,
        screen: LogScreen.background,
        eventType: LogEventType.error,
      );
      return null;
    }
  }

  /// Streams a binary resource (HLS segment, DASH .m4s, etc.) directly to a
  /// file path on disk using Android's native [HttpURLConnection] with
  /// media-player request headers.  Unlike [fetchBinaryUrl], this method does
  /// NOT base64-encode the response — it writes raw bytes directly to disk on
  /// the native side, eliminating the memory overhead and encoding cost of
  /// transferring large segments across the platform channel.
  ///
  /// Returns `({int statusCode, int bytesWritten})` on success, or `null` on
  /// any error.  Never throws.
  ///
  /// The caller should verify the output file after the call returns.
  static Future<({int statusCode, int bytesWritten})?> streamSegmentToFile({
    required String url,
    required String filePath,
    Map<String, String>? headers,
    String? cookieHeader,
    String? rangeHeader,
  }) async {
    if (!Platform.isAndroid) return null;
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'streamSegmentToFile',
        {
          'url': url,
          'filePath': filePath,
          'referer': headers?['Referer'] ?? '',
          'origin': headers?['Origin'] ?? '',
          'userAgent': headers?['User-Agent'] ?? '',
          if (cookieHeader != null && cookieHeader.isNotEmpty)
            'cookie': cookieHeader,
          if (rangeHeader != null && rangeHeader.isNotEmpty)
            'range': rangeHeader,
        },
      );
      if (result == null) return null;
      final statusCode = (result['statusCode'] as int?) ?? 0;
      final bytesWritten = (result['bytesWritten'] as num?)?.toInt() ?? 0;
      AuroraLog.instance.debug(
        'streamSegmentToFile statusCode=$statusCode bytesWritten=$bytesWritten',
        category: LogCategory.platform,
        screen: LogScreen.background,
        eventType: LogEventType.network,
      );
      return (statusCode: statusCode, bytesWritten: bytesWritten);
    } on MissingPluginException {
      return null;
    } catch (e) {
      AuroraLog.instance.error(
        'NetworkBindingService streamSegmentToFile error: $e',
        category: LogCategory.platform,
        screen: LogScreen.background,
        eventType: LogEventType.error,
      );
      return null;
    }
  }

  /// Fetches [url] as **binary** through Android's native [HttpURLConnection]
  /// with **media-player request headers** (`Accept: video/MP2T`,
  /// `Sec-Fetch-Dest: video`, optional `Range`). This is the fingerprint a
  /// real video player uses — unlike [fetchUrl] which sends XHR-style headers.
  /// Some CDNs (e.g. TikTok CDN) serve placeholder/PNG content to non-media
  /// requests, so HLS segment downloads must look like a media player request
  /// to receive real video bytes.
  ///
  /// Returns `({statusCode: int, data: Uint8List?})` on success, or `null` on
  /// any error. Never throws.
  static Future<({int statusCode, Uint8List? data})?> fetchBinaryUrl(
    String url, {
    Map<String, String>? headers,
    String? cookieHeader,
    String? rangeHeader,
  }) async {
    if (!Platform.isAndroid) return null;
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'fetchBinaryUrl',
        {
          'url': url,
          'referer': headers?['Referer'] ?? '',
          'origin': headers?['Origin'] ?? '',
          'userAgent': headers?['User-Agent'] ?? '',
          if (cookieHeader != null && cookieHeader.isNotEmpty)
            'cookie': cookieHeader,
          if (rangeHeader != null && rangeHeader.isNotEmpty)
            'range': rangeHeader,
        },
      );
      if (result == null) return null;
      final statusCode = (result['statusCode'] as int?) ?? 0;
      final dataB64 = result['data'] as String? ?? '';
      final data = dataB64.isNotEmpty ? base64Decode(dataB64) : null;
      AuroraLog.instance.debug(
        'fetchBinaryUrl statusCode=$statusCode bytes=${data?.length ?? 0}',
        category: LogCategory.platform,
        screen: LogScreen.background,
        eventType: LogEventType.network,
      );
      return (statusCode: statusCode, data: data);
    } on MissingPluginException {
      return null;
    } catch (e) {
      AuroraLog.instance.error(
        'NetworkBindingService fetchBinaryUrl error: $e',
        category: LogCategory.platform,
        screen: LogScreen.background,
        eventType: LogEventType.error,
      );
      return null;
    }
  }
}

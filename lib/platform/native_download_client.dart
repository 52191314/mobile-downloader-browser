import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';


/// Result of a single native chunk download.
class NativeChunkResult {
  final int statusCode;
  final int bytesWritten;
  final String? downloadId;
  final bool cancelled;

  const NativeChunkResult({
    required this.statusCode,
    required this.bytesWritten,
    this.downloadId,
    this.cancelled = false,
  });
}

/// Wraps the native OkHttp download engine for fast chunked HTTP downloads.
///
/// The native side ([NativeDownloadEngine]) uses OkHttp with HTTP/2,
/// connection pooling, and direct-to-disk streaming — avoiding the
/// base64 encode/decode overhead and HTTP/1.1 limitations of Dart's
/// [http.Client].
///
/// Usage: call [downloadChunk] for each chunk.  If it returns null
/// (native engine unavailable or failed), fall back to Dart's HTTP client.
class NativeDownloadClient {
  static const MethodChannel _channel = MethodChannel(
    'aurora_downloader/native_download',
  );

  /// Downloads a single chunk through the native OkHttp engine.
  ///
  /// [url] — the full chunk URL.
  /// [filePath] — absolute path where the chunk bytes should be written.
  /// [rangeStart], [rangeEnd] — byte range (pass null/0 for no range).
  /// [headers] — optional HTTP headers (Referer, Origin, User-Agent, etc.).
  /// [cookieHeader] — optional Cookie header value.
  /// [downloadId] — optional custom unique ID for cancellation tracking.
  ///
  /// Returns a [NativeChunkResult] on success, or `null` if the native
  /// engine is unavailable (non-Android, plugin not registered).
  ///
  /// Never throws — errors are logged and returned as null.
  static Future<NativeChunkResult?> downloadChunk({
    required String url,
    required String filePath,
    int rangeStart = 0,
    int rangeEnd = -1,
    Map<String, String>? headers,
    String? cookieHeader,
    String? downloadId,
  }) async {
    if (!Platform.isAndroid) return null;

    String rangeHeader = '';
    if (rangeEnd >= rangeStart) {
      rangeHeader = 'bytes=$rangeStart-$rangeEnd';
    }

    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'downloadChunk',
        {
          'url': url,
          'filePath': filePath,
          'rangeHeader': rangeHeader,
          'referer': headers?['Referer'] ?? '',
          'origin': headers?['Origin'] ?? '',
          'userAgent': headers?['User-Agent'] ?? '',
          if (cookieHeader != null && cookieHeader.isNotEmpty)
            'cookie': cookieHeader,
          if (downloadId != null)
            'downloadId': downloadId,
        },
      );
      if (result == null) return null;

      final statusCode = (result['statusCode'] as int?) ?? 0;
      final bytesWritten = (result['bytesWritten'] as num?)?.toInt() ?? 0;
      final cancelled = (result['cancelled'] as bool?) ?? false;
      final retDownloadId = result['downloadId'] as String?;

      if (kDebugMode) {
        debugPrint(
          '[NativeDownloadClient] chunk status=$statusCode '
          'bytes=$bytesWritten cancelled=$cancelled',
        );
      }
      debugPrint('NativeDownloadClient chunk status=$statusCode bytes=$bytesWritten '
        'cancelled=$cancelled');
      return NativeChunkResult(
        statusCode: statusCode,
        bytesWritten: bytesWritten,
        downloadId: retDownloadId,
        cancelled: cancelled,
      );
    } on MissingPluginException {
      return null;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[NativeDownloadClient] error: $e');
      }
      debugPrint('NativeDownloadClient error: $e');
      return null;
    }
  }

  /// Cancels an active native chunk download by its [downloadId].
  static Future<bool> cancelChunk(String downloadId) async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await _channel.invokeMethod<bool>(
        'cancelChunk',
        {'downloadId': downloadId},
      );
      return result ?? false;
    } catch (e) {
      debugPrint('[NativeDownloadClient] cancelChunk error: $e');
      return false;
    }
  }
}

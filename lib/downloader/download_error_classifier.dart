import 'dart:io';
import 'dart:async';
import 'models.dart';

/// Maps raw exceptions and HTTP status codes to structured
/// [DownloadFailure] values and generates clear, user-friendly messages.
///
/// This is a pure utility class — no state, no side-effects.
class DownloadErrorClassifier {
  DownloadErrorClassifier._();

  // ──────────────────────────────────────────────────────────────────────
  // Classification
  // ──────────────────────────────────────────────────────────────────────

  /// Classifies an error into a [DownloadFailure] category.
  ///
  /// [error] — the caught exception/error object.
  /// [httpStatus] — if known, the HTTP status code from the response.
  static DownloadFailure classify(Object error, {int? httpStatus}) {
    // ── HTTP status code (highest priority when provided) ──
    if (httpStatus != null) {
      final reason = _fromHttpStatus(httpStatus);
      if (reason != null) return reason;
    }

    // ── SocketException (network layer) ──
    if (error is SocketException) {
      return _fromSocketException(error);
    }

    // ── TimeoutException ──
    if (error is TimeoutException) {
      return DownloadFailure.connectionTimeout;
    }

    // ── FileSystemException (disk I/O) ──
    if (error is FileSystemException) {
      return _fromFileSystemException(error);
    }

    // ── TLS / Handshake errors ──
    if (error is HandshakeException || error is TlsException) {
      return DownloadFailure.connectionReset;
    }

    // ── HttpException (Dart's built-in) ──
    if (error is HttpException) {
      return _fromMessageHeuristic(error.message);
    }

    // ── FormatException (bad URL / bad torrent) ──
    if (error is FormatException) {
      final msg = error.message.toLowerCase();
      if (msg.contains('torrent') || msg.contains('bencode')) {
        return DownloadFailure.torrentMetadataFailed;
      }
      return DownloadFailure.urlInvalid;
    }

    // ── StateError (usually from HLS) ──
    if (error is StateError) {
      return _fromMessageHeuristic(error.message);
    }

    // ── Exception / generic ──
    final msg = error.toString();
    return _fromMessageHeuristic(msg);
  }

  /// Classifies an HTTP status code to a [DownloadFailure], or null if
  /// the status code is not an error (2xx).
  static DownloadFailure? fromHttpStatus(int statusCode) =>
      _fromHttpStatus(statusCode);

  // ──────────────────────────────────────────────────────────────────────
  // User-facing messages
  // ──────────────────────────────────────────────────────────────────────

  /// Returns a clear, actionable, user-visible error message for the
  /// given [reason].  The optional [detail] is appended for context
  /// when the generic message might be insufficient.
  static String userMessage(
    DownloadFailure reason, {
    String? detail,
    int? httpStatus,
    String? host,
    String? thresholdLabel,
    int? stallTimeoutSeconds,
    String? percentage,
  }) {
    switch (reason) {
      // ── Network ──
      case DownloadFailure.noInternet:
        return 'No internet connection. '
            'Check your WiFi or mobile data and try again.';
      case DownloadFailure.dnsLookupFailed:
        final h = host ?? _extractHost(detail);
        return h != null
            ? 'Cannot reach the server — DNS lookup failed for "$h". '
                'Check your internet connection.'
            : 'Cannot reach the server — DNS lookup failed. '
                'Check your internet connection.';
      case DownloadFailure.connectionRefused:
        return 'The server refused the connection. '
            'It may be down or blocking your region.';
      case DownloadFailure.connectionTimeout:
        return 'Connection timed out. '
            'The server is not responding — it may be overloaded or blocked.';
      case DownloadFailure.responseTimeout:
        return 'The server stopped responding mid-download. '
            'Try again — if it keeps happening, the server may be overloaded.';
      case DownloadFailure.connectionReset:
        return 'The connection was interrupted. '
            'Your ISP or the CDN may have reset the connection. Retry to resume.';

      // ── HTTP ──
      case DownloadFailure.httpUnauthorized:
        return 'Access denied (401). '
            'Authentication is required — the URL may need a fresh token.';
      case DownloadFailure.httpForbidden:
        return 'Access denied (403). '
            'The server blocked this request — the URL may have expired '
            'or your IP was rate-limited.';
      case DownloadFailure.httpNotFound:
        return 'File not found (404). '
            'The resource was removed or the URL is invalid.';
      case DownloadFailure.httpRateLimited:
        return 'Rate limited (429). '
            'The server is throttling downloads. Wait a few minutes and retry.';
      case DownloadFailure.httpServerError:
        final code = httpStatus != null ? ' ($httpStatus)' : '';
        return 'Server error$code. '
            'The server is having problems — try again later.';
      case DownloadFailure.httpUnexpectedStatus:
        final code = httpStatus != null ? ' ($httpStatus)' : '';
        return 'Unexpected server response$code. '
            'The download could not proceed.'
            '${detail != null ? ' $detail' : ''}';

      // ── Content ──
      case DownloadFailure.urlExpired:
        return 'The download URL has expired. '
            'Go back to the source page and get a fresh link.';
      case DownloadFailure.urlInvalid:
        return detail ?? 'The URL is invalid or unsupported.';
      case DownloadFailure.contentMismatch:
        return 'The server returned an HTML page instead of the media file. '
            'The URL may have expired or require authentication.';
      case DownloadFailure.hashMismatch:
        return 'File integrity check failed — the downloaded file is corrupt. '
            '${detail ?? 'Retry the download.'}';
      case DownloadFailure.emptyResponse:
        return 'The server returned an empty file (0 bytes). '
            'The URL may have expired or require authentication.';
      case DownloadFailure.resourceChanged:
        return 'The file on the server has changed since the download started. '
            'The download will restart with the updated file.';

      // ── HLS ──
      case DownloadFailure.hlsPlaylistEmpty:
        return 'The HLS playlist did not contain any media segments. '
            'The stream may have ended or the URL is invalid.';
      case DownloadFailure.hlsPlaylistFetchFailed:
        return 'Could not fetch the HLS playlist. '
            '${detail ?? 'Re-sniff the link from the video page.'}';
      case DownloadFailure.hlsKeyFetchFailed:
        return 'Could not fetch the encryption key for this stream. '
            'Re-sniff the link from the video page.';
      case DownloadFailure.hlsTokenExpired:
        return 'The stream URL has expired and could not be refreshed. '
            'Go back to the video page and re-sniff the link.';
      case DownloadFailure.hlsCircuitBreaker:
        return 'The CDN blocked access after repeated 403 errors. '
            'Wait a few minutes, then re-sniff from the video page.';

      // ── File I/O ──
      case DownloadFailure.diskFull:
        return 'Not enough storage space. '
            'Free up space on your device and retry.';
      case DownloadFailure.permissionDenied:
        return 'Cannot write to the download folder — '
            'storage permission is missing or the folder is read-only.';
      case DownloadFailure.fileSystemError:
        return 'A file system error occurred. '
            '${detail ?? 'Check that the download folder exists and is writable.'}';

      // ── Download integrity ──
      case DownloadFailure.chunkIncomplete:
        return 'Download interrupted — not all parts completed. '
            'Retry to resume from where it stopped.';
      case DownloadFailure.chunkCorrupt:
        return detail ?? 'A downloaded part is corrupt or missing. '
            'Retry will re-download the affected parts.';
      case DownloadFailure.mergeInterrupted:
        return 'The download was interrupted while merging saved parts. '
            'Retry to re-merge.';
      case DownloadFailure.mergeFailed:
        return detail ?? 'Could not merge the downloaded parts into a file.';

      // ── Stall / Speed ──
      case DownloadFailure.speedStall:
        final threshold = thresholdLabel ?? 'the configured minimum';
        final timeout = stallTimeoutSeconds ?? 20;
        return '[Speed stall] Speed stayed below $threshold '
            'for ${timeout}s. Auto-retrying...';
      case DownloadFailure.partialDownload:
        final pct = percentage ?? '?';
        return '[Download stalled at $pct%] '
            'Use "Force Merge" to salvage the partial file, or tap Retry to resume.';

      // ── Torrent ──
      case DownloadFailure.nativeEngineUnavailable:
        return detail ?? 'The native torrent engine is not available. '
            'Torrent downloads require the native engine.';
      case DownloadFailure.torrentMetadataFailed:
        return detail ?? 'Could not parse the torrent file or fetch metadata.';
      case DownloadFailure.torrentEngineError:
        return detail ?? 'The torrent engine reported an error.';

      // ── Other ──
      case DownloadFailure.unknown:
        return detail ?? 'Download failed due to an unexpected error.';
    }
  }

  /// Convenience: classify + generate message in one call.
  static ({DownloadFailure reason, String message}) classifyAndMessage(
    Object error, {
    int? httpStatus,
  }) {
    final reason = classify(error, httpStatus: httpStatus);
    final message = userMessage(
      reason,
      detail: _cleanDetail(error.toString()),
      httpStatus: httpStatus,
    );
    return (reason: reason, message: message);
  }

  // ──────────────────────────────────────────────────────────────────────
  // Private helpers
  // ──────────────────────────────────────────────────────────────────────

  static DownloadFailure? _fromHttpStatus(int code) {
    return switch (code) {
      401 => DownloadFailure.httpUnauthorized,
      403 => DownloadFailure.httpForbidden,
      404 => DownloadFailure.httpNotFound,
      429 => DownloadFailure.httpRateLimited,
      >= 500 && <= 504 => DownloadFailure.httpServerError,
      >= 400 => DownloadFailure.httpUnexpectedStatus,
      _ => null,
    };
  }

  static DownloadFailure _fromSocketException(SocketException e) {
    final msg = e.message.toLowerCase();
    final osMsg = e.osError?.message?.toLowerCase() ?? '';
    final combined = '$msg $osMsg';

    if (combined.contains('failed host lookup') ||
        combined.contains('getaddrinfo') ||
        combined.contains('name or service not known') ||
        combined.contains('no address associated')) {
      return DownloadFailure.dnsLookupFailed;
    }
    if (combined.contains('connection refused') ||
        combined.contains('econnrefused')) {
      return DownloadFailure.connectionRefused;
    }
    if (combined.contains('connection reset') ||
        combined.contains('econnreset') ||
        combined.contains('broken pipe') ||
        combined.contains('epipe')) {
      return DownloadFailure.connectionReset;
    }
    if (combined.contains('timed out') ||
        combined.contains('etimedout')) {
      return DownloadFailure.connectionTimeout;
    }
    if (combined.contains('network is unreachable') ||
        combined.contains('enetunreach') ||
        combined.contains('no route to host') ||
        combined.contains('ehostunreach')) {
      return DownloadFailure.noInternet;
    }
    // Generic socket error — most likely no connectivity.
    return DownloadFailure.noInternet;
  }

  static DownloadFailure _fromFileSystemException(FileSystemException e) {
    final msg = e.message.toLowerCase();
    final osMsg = e.osError?.message?.toLowerCase() ?? '';
    final combined = '$msg $osMsg';

    if (combined.contains('no space left') ||
        combined.contains('enospc') ||
        combined.contains('disk quota')) {
      return DownloadFailure.diskFull;
    }
    if (combined.contains('permission denied') ||
        combined.contains('eacces') ||
        combined.contains('eperm') ||
        combined.contains('read-only file system')) {
      return DownloadFailure.permissionDenied;
    }
    return DownloadFailure.fileSystemError;
  }

  /// Heuristic classification from the error message string.
  /// Used as a fallback when the exception type is generic.
  static DownloadFailure _fromMessageHeuristic(String msg) {
    final lower = msg.toLowerCase();

    // HTTP status codes embedded in messages.
    if (lower.contains('status 401') || lower.contains('401 unauthorized')) {
      return DownloadFailure.httpUnauthorized;
    }
    if (lower.contains('status 403') || lower.contains('403 forbidden')) {
      return DownloadFailure.httpForbidden;
    }
    if (lower.contains('status 404') || lower.contains('404 not found')) {
      return DownloadFailure.httpNotFound;
    }
    if (lower.contains('status 429')) {
      return DownloadFailure.httpRateLimited;
    }
    if (lower.contains('status 500') || lower.contains('status 502') ||
        lower.contains('status 503') || lower.contains('status 504')) {
      return DownloadFailure.httpServerError;
    }
    // Generic non-2xx.
    final statusMatch = RegExp(r'status (\d{3})').firstMatch(lower);
    if (statusMatch != null) {
      final code = int.tryParse(statusMatch.group(1)!);
      if (code != null && code >= 400) {
        return _fromHttpStatus(code) ?? DownloadFailure.httpUnexpectedStatus;
      }
    }

    // Content issues.
    if (lower.contains('0 bytes') || lower.contains('empty file') ||
        lower.contains('returned 0 bytes')) {
      return DownloadFailure.emptyResponse;
    }
    if (lower.contains('html error page') || lower.contains('html page instead')) {
      return DownloadFailure.contentMismatch;
    }
    if (lower.contains('sha-256 mismatch') || lower.contains('hash mismatch')) {
      return DownloadFailure.hashMismatch;
    }

    // HLS-specific.
    if (lower.contains('no media segments') || lower.contains('playlist did not contain')) {
      return DownloadFailure.hlsPlaylistEmpty;
    }
    if (lower.contains('token refresh') && lower.contains('failed')) {
      return DownloadFailure.hlsTokenExpired;
    }
    if (lower.contains('circuit breaker') || lower.contains('consecutive 403')) {
      return DownloadFailure.hlsCircuitBreaker;
    }
    if (lower.contains('hls download failed') || lower.contains('re-sniff')) {
      return DownloadFailure.hlsPlaylistFetchFailed;
    }
    if (lower.contains('key fetch failed') || lower.contains('encryption key')) {
      return DownloadFailure.hlsKeyFetchFailed;
    }

    // Chunk / merge issues.
    if (lower.contains('not all chunks completed') || lower.contains('chunk incomplete')) {
      return DownloadFailure.chunkIncomplete;
    }
    if (lower.contains('chunk') && (lower.contains('corrupt') ||
        lower.contains('truncated') || lower.contains('missing'))) {
      return DownloadFailure.chunkCorrupt;
    }
    if (lower.contains('merge interrupted')) {
      return DownloadFailure.mergeInterrupted;
    }
    if (lower.contains('merge failed') || lower.contains('force merge')) {
      return DownloadFailure.mergeFailed;
    }

    // Stall / Speed.
    if (lower.contains('speed stall') || lower.contains('speed stayed below')) {
      return DownloadFailure.speedStall;
    }
    if (lower.contains('stalled near completion') || lower.contains('partial')) {
      return DownloadFailure.partialDownload;
    }

    // Token / auth expiry.
    if (lower.contains('token expired') || lower.contains('url expired') ||
        lower.contains('url may have expired')) {
      return DownloadFailure.urlExpired;
    }

    // Torrent.
    if (lower.contains('unsupported torrent') || lower.contains('torrent url')) {
      return DownloadFailure.urlInvalid;
    }
    if (lower.contains('torrent') && lower.contains('metadata')) {
      return DownloadFailure.torrentMetadataFailed;
    }

    // Network (from message text).
    if (lower.contains('failed host lookup') || lower.contains('dns')) {
      return DownloadFailure.dnsLookupFailed;
    }
    if (lower.contains('connection refused')) {
      return DownloadFailure.connectionRefused;
    }
    if (lower.contains('connection reset') || lower.contains('broken pipe')) {
      return DownloadFailure.connectionReset;
    }
    if (lower.contains('timed out') || lower.contains('timeout')) {
      return DownloadFailure.connectionTimeout;
    }
    if (lower.contains('no internet') || lower.contains('network is unreachable')) {
      return DownloadFailure.noInternet;
    }

    // Disk.
    if (lower.contains('no space left') || lower.contains('enospc')) {
      return DownloadFailure.diskFull;
    }
    if (lower.contains('permission denied') || lower.contains('eacces')) {
      return DownloadFailure.permissionDenied;
    }

    return DownloadFailure.unknown;
  }

  /// Tries to extract a hostname from an error detail string.
  static String? _extractHost(String? detail) {
    if (detail == null) return null;
    final match = RegExp(r"host '([^']+)'").firstMatch(detail);
    return match?.group(1);
  }

  /// Strips common Dart exception class prefixes from toString() output
  /// to produce a cleaner detail string for user messages.
  static String _cleanDetail(String raw) {
    // Remove "Exception: ", "StateError: ", "HttpException: " etc.
    final cleaned = raw.replaceFirst(
      RegExp(r'^(Exception|StateError|FormatException|HttpException|'
          r'SocketException|FileSystemException|TimeoutException'
          r'|HandshakeException|TlsException): '),
      '',
    );
    return cleaned;
  }
}

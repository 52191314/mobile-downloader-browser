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
            ? 'Couldn\'t reach $h. '
                'Aurora couldn\'t translate the address to a server. '
                'Check the URL is correct and try again.'
            : 'Couldn\'t reach the server. '
                'Aurora couldn\'t translate the address to a server. '
                'Check the URL and try again.';
      case DownloadFailure.connectionRefused:
        return 'Couldn\'t connect. '
            'The server refused the connection. '
            'Check the server is online and try again.';
      case DownloadFailure.connectionTimeout:
        return 'Couldn\'t connect. '
            'The server didn\'t respond in time. '
            'Check the server is online and try again.';
      case DownloadFailure.responseTimeout:
        return 'Couldn\'t finish the download. '
            'The server stopped responding mid-stream. '
            'Try again — if it keeps happening, the server may be overloaded.';
      case DownloadFailure.connectionReset:
        return 'Couldn\'t keep the connection open. '
            'A network device or the server reset the link. '
            'Try again to resume.';

      // ── HTTP ──
      case DownloadFailure.httpUnauthorized:
        return 'Couldn\'t download. '
            'Server requires authentication (401). '
            'The URL may need a fresh token or login.';
      case DownloadFailure.httpForbidden:
        return 'Couldn\'t download. '
            'The server blocked the request (403). '
            'The URL may have expired or your IP was rate-limited. '
            'Go back to the source and get a fresh link.';
      case DownloadFailure.httpNotFound:
        return 'Couldn\'t download. '
            'Server says the file doesn\'t exist (404). '
            'The resource may have been removed.';
      case DownloadFailure.httpRateLimited:
        return 'Couldn\'t download. '
            'Server is throttling requests (429). '
            'Wait a few minutes, then try again.';
      case DownloadFailure.httpServerError:
        final code = httpStatus != null ? ' ($httpStatus)' : '';
        return 'Couldn\'t download. '
            'The server had a problem$code. '
            'Try again later.';
      case DownloadFailure.httpUnexpectedStatus:
        final code = httpStatus != null ? ' ($httpStatus)' : '';
        return 'Couldn\'t download. '
            'Server returned an unexpected response$code.'
            '${detail != null ? ' $detail' : ''}';

      // ── Content ──
      case DownloadFailure.urlExpired:
        return 'Couldn\'t download. '
            'The link has expired. '
            'Go back to the source page and get a fresh link.';
      case DownloadFailure.urlInvalid:
        return detail ?? 'Couldn\'t download. '
            'The URL is not valid or isn\'t supported. '
            'Check the link and try again.';
      case DownloadFailure.contentMismatch:
        return 'Couldn\'t download. '
            'The server sent an HTML page instead of a media file. '
            'The URL may have expired or need authentication. '
            'Re-sniff from the source page.';
      case DownloadFailure.hashMismatch:
        return 'Couldn\'t verify the download. '
            'The file is corrupt or was modified. '
            '${detail ?? 'Try downloading again.'}';
      case DownloadFailure.emptyResponse:
        return 'Couldn\'t download. '
            'The server returned an empty file (0 bytes). '
            'The URL may have expired or need authentication. '
            'Re-sniff from the source page.';
      case DownloadFailure.resourceChanged:
        return 'Couldn\'t finish. '
            'The file changed on the server during the download. '
            'The download will restart with the updated version.';

      // ── HLS ──
      case DownloadFailure.hlsPlaylistEmpty:
        return 'Couldn\'t download. '
            'The streaming playlist has no media segments. '
            'The stream may have ended or the link is invalid. '
            'Re-sniff from the video page.';
      case DownloadFailure.hlsPlaylistFetchFailed:
        return 'Couldn\'t fetch the streaming playlist. '
            '${detail ?? 'Re-sniff the link from the video page.'}';
      case DownloadFailure.hlsKeyFetchFailed:
        return 'Couldn\'t get the decryption key for this stream. '
            'Re-sniff the link from the video page.';
      case DownloadFailure.hlsTokenExpired:
        return 'Couldn\'t download. '
            'The stream link expired and couldn\'t be refreshed. '
            'Go back to the video page and re-sniff.';
      case DownloadFailure.hlsCircuitBreaker:
        return 'Couldn\'t download. '
            'The CDN blocked access after too many rejections (403). '
            'Wait a few minutes, then re-sniff from the video page.';

      // ── File I/O ──
      case DownloadFailure.diskFull:
        return 'Couldn\'t save the file. '
            'Not enough storage space. '
            'Free up space on your device and try again.';
      case DownloadFailure.permissionDenied:
        return 'Couldn\'t save the file. '
            'Storage permission is missing or the download folder is read-only. '
            'Check folder permissions in Settings.';
      case DownloadFailure.fileSystemError:
        return 'Couldn\'t save the file. '
            '${detail ?? 'Check that the download folder exists and is writable.'}';

      // ── Download integrity ──
      case DownloadFailure.chunkIncomplete:
        return 'Couldn\'t finish the download. '
            'Not all parts completed. '
            'Try again to resume from where it stopped.';
      case DownloadFailure.chunkCorrupt:
        return detail ?? 'Couldn\'t verify a downloaded part. '
            'A chunk is corrupt or missing. '
            'Retry will re-download the affected parts.';
      case DownloadFailure.mergeInterrupted:
        return 'Couldn\'t finish merging. '
            'The download was interrupted while joining parts. '
            'Try again to complete the merge.';
      case DownloadFailure.mergeFailed:
        return detail ?? 'Couldn\'t combine the downloaded parts into a single file. '
            'Try again.';

      // ── Stall / Speed ──
      case DownloadFailure.speedStall:
        final threshold = thresholdLabel ?? 'the configured minimum';
        final timeout = stallTimeoutSeconds ?? 20;
        return 'Download slowed down. '
            'Speed stayed below $threshold for ${timeout}s. '
            'Aurora is retrying automatically.';
      case DownloadFailure.partialDownload:
        final pct = percentage ?? '?';
        return 'Download stalled at $pct%. '
            'Use Force Merge to save the partial file, '
            'or tap Retry to resume.';

      // ── Torrent ──
      case DownloadFailure.nativeEngineUnavailable:
        return detail ?? 'Couldn\'t start the torrent engine. '
            'This device doesn\'t support the required native engine.';
      case DownloadFailure.torrentMetadataFailed:
        return detail ?? 'Couldn\'t read the torrent file. '
            'The file may be corrupt or the tracker isn\'t responding.';
      case DownloadFailure.torrentEngineError:
        return detail ?? 'Couldn\'t run the torrent download. '
            'The torrent engine reported an error. Try again.';

      // ── Other ──
      case DownloadFailure.unknown:
        return detail ?? 'Couldn\'t download. '
            'Something unexpected went wrong. Try again.';
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
    final osMsg = e.osError?.message.toLowerCase() ?? '';
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
    final osMsg = e.osError?.message.toLowerCase() ?? '';
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

    // Disk — checked BEFORE the merge-failed pattern below: an in-isolate
    // merge wraps the original FileSystemException text, and a message like
    // "File merge failed: FileSystemException: No space left on device"
    // must still classify as diskFull/permissionDenied, not mergeFailed.
    if (lower.contains('no space left') || lower.contains('enospc')) {
      return DownloadFailure.diskFull;
    }
    if (lower.contains('permission denied') || lower.contains('eacces')) {
      return DownloadFailure.permissionDenied;
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

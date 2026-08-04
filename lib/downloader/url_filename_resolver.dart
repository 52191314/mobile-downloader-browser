import 'dart:async';

import 'package:http/http.dart' as http;

import 'media_file_types.dart';

/// Result of a URL filename resolution via HTTP probe.
class ResolvedFilename {
  /// The resolved/suggested filename (may include extension).
  final String name;

  /// The Content-Type header value from the probe, if available.
  final String? contentType;

  /// The Content-Length header value from the probe, if available.
  final int? contentLength;

  const ResolvedFilename({
    required this.name,
    this.contentType,
    this.contentLength,
  });
}

/// Synchronous filename derivation from a URI (no HTTP probe).
/// This is the fallback when probing fails or the URL already has an
/// extension.  Unlike the old [_safeFileName] in main.dart, the `.bin`
/// suffix is dropped — the caller should supply a real extension from
/// a mime→ext mapping.
///
/// Returns a sanitised filename (may be extensionless).
String safeFileName(Uri uri) {
  final lastSegment = uri.pathSegments.isNotEmpty
      ? uri.pathSegments.last
      : 'aurora-download';
  final decoded = Uri.decodeComponent(lastSegment);
  final sanitized = decoded.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  return sanitized.isEmpty ? 'aurora-download' : sanitized;
}

/// Extracts the file extension (including the leading dot, e.g. `.mp4`)
/// from a URL's path.  Returns an empty string if the path has no
/// recognisable extension.
///
/// Example:
///   `extensionFromUrlPath('https://example.com/video.mp4?q=1')` → `.mp4`
///   `extensionFromUrlPath('https://example.com/path/')` → ``
String extensionFromUrlPath(String url) {
  return MediaFileTypes.extensionFromUrlPath(url);
}

/// Parses a `Content-Disposition` header value and returns the suggested
/// filename, or `null` if the header contains no filename directive.
///
/// Supports both:
/// - `filename*=UTF-8''encoded-name.ext`  (RFC 5987)
/// - `filename="name.ext"`                (basic form)
String? parseContentDispositionFilename(String contentDisposition) {
  try {
    // Try the RFC 5987 UTF-8 encoded form first.
    final starMatch = RegExp(
      r"filename\*=(?:utf|UTF)-8''([^;\n\s]+)",
      caseSensitive: false,
    ).firstMatch(contentDisposition);
    if (starMatch != null) {
      final encoded = starMatch.group(1);
      if (encoded != null) {
        final decoded = Uri.decodeComponent(encoded);
        final cleaned = decoded.replaceAll('"', '').trim();
        if (cleaned.isNotEmpty) {
          return cleaned;
        }
      }
    }

    // Fall back to the basic filename= form.
    final normalMatch = RegExp(
      r'filename\s*=\s*([^;\n]+)',
      caseSensitive: false,
    ).firstMatch(contentDisposition);
    if (normalMatch != null) {
      String val = normalMatch.group(1)!.trim();
      if (val.startsWith('"') && val.endsWith('"') && val.length >= 2) {
        val = val.substring(1, val.length - 1);
      } else if (val.startsWith("'") &&
          val.endsWith("'") &&
          val.length >= 2) {
        val = val.substring(1, val.length - 1);
      }
      val = val.trim();
      if (val.isNotEmpty) {
        return val;
      }
    }
  } catch (_) {}
  return null;
}

/// Probes a URL with a HEAD request (falling back to Range-GET `bytes=0-0`)
/// to determine the real filename, Content-Type, and Content-Length.
///
/// **Extension priority** (first wins):
///   1. Extension from the `Content-Disposition` header filename.
///   2. Extension already present in the URL path.
///   3. Extension derived from the `Content-Type` header via
///      [PublicDownloadsService.extensionForMime].
///   4. No extension (bare name).
///
/// When the URL already has a known extension **and** no
/// [suggestedFilename] is supplied, the probe is skipped (fast path).
///
/// The optional [client] allows injection of a custom [http.Client] for
/// testing (the caller is responsible for closing it).
Future<ResolvedFilename> resolveFilename({
  required String url,
  required Map<String, String> headers,
  String? suggestedFilename,
  http.Client? client,
}) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) {
    return ResolvedFilename(name: safeFileName(uri ?? Uri()));
  }

  // Fast path: URL already has a known media extension and no explicit
  // suggestedFilename to override it.
  final urlExt = extensionFromUrlPath(url);
  if (urlExt.isNotEmpty && suggestedFilename == null) {
    final lastSegment = uri.pathSegments.isNotEmpty
        ? uri.pathSegments.last
        : 'download';
    final base = lastSegment.replaceAll(RegExp(r'\.[^.]+$'), '');
    return ResolvedFilename(name: '$base$urlExt');
  }

  // Probe the URL.
  final httpClient = client ?? http.Client();
  String? contentType;
  int? contentLength;
  String? dispositionFilename;

  try {
    final headResp = await httpClient
        .head(uri, headers: _probeHeaders(headers))
        .timeout(const Duration(seconds: 10))
        .catchError((_) => http.Response('', 500));

    if (headResp.statusCode >= 200 && headResp.statusCode < 400) {
      contentType = headResp.headers['content-type'] ?? '';
      final contentRange = headResp.headers['content-range'] ?? '';
      final rangeMatch =
          RegExp(r'bytes \d+-\d+/(\d+)').firstMatch(contentRange);
      if (rangeMatch != null) {
        contentLength = int.tryParse(rangeMatch.group(1)!);
      } else {
        contentLength =
            int.tryParse(headResp.headers['content-length'] ?? '');
      }
      final cd = headResp.headers['content-disposition'];
      if (cd != null && cd.isNotEmpty) {
        dispositionFilename = parseContentDispositionFilename(cd);
      }
    } else {
      // Fallback: Range-GET bytes=0-0 (same pattern as MediaEnricher Tier 2).
      try {
        final request = http.Request('GET', uri);
        request.headers.addAll({
          ..._probeHeaders(headers),
          'Range': 'bytes=0-0',
        });
        request.followRedirects = true;
        final response = await httpClient
            .send(request)
            .timeout(const Duration(seconds: 10));
        if (response.statusCode >= 200 && response.statusCode < 400) {
          final resHeaders = response.headers;
          final cr = resHeaders['content-range'] ?? '';
          final rMatch = RegExp(r'bytes \d+-\d+/(\d+)').firstMatch(cr);
          if (rMatch != null) {
            contentLength = int.tryParse(rMatch.group(1)!);
          } else {
            final lh = resHeaders['content-length'] ?? '';
            final parsed = int.tryParse(lh);
            if (parsed != null && parsed > 1) {
              contentLength = parsed;
            }
          }
          contentType = resHeaders['content-type'] ?? '';
          final cd = resHeaders['content-disposition'];
          if (cd != null && cd.isNotEmpty) {
            dispositionFilename = parseContentDispositionFilename(cd);
          }
        }
        // Drain only when the body is small (the range probe normally
        // returns 1 byte). If the server ignored Range and streamed the
        // whole file, abort instead of downloading it all to discard it.
        final probeLen = response.contentLength;
        if (response.statusCode == 206 ||
            (probeLen != null && probeLen <= 65536)) {
          unawaited(response.stream.drain<void>().catchError((_) {}));
        } else {
          unawaited(
            response
                .stream
                .listen((_) {}, onError: (_) {})
                .cancel()
                .catchError((_) {}),
          );
        }
      } catch (_) {}
    }
  } catch (_) {
    // Probe failed entirely — fall through to build a name from existing info.
  } finally {
    if (client == null) {
      httpClient.close();
    }
  }

  final name = _buildFileName(
    url: url,
    uri: uri,
    suggestedFilename: suggestedFilename,
    dispositionFilename: dispositionFilename,
    contentType: contentType,
  );

  return ResolvedFilename(
    name: name,
    contentType: contentType?.isNotEmpty == true ? contentType : null,
    contentLength: contentLength,
  );
}

/// Ensures the probe request carries a `User-Agent` header so CDNs don't
/// reject the HEAD/Range request out of hand.
Map<String, String> _probeHeaders(Map<String, String> original) {
  if (original.entries.any((e) => e.key.toLowerCase() == 'user-agent')) {
    return original;
  }
  return {
    ...original,
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/125.0.0.0 Safari/537.36',
  };
}

/// Core name-building logic implementing the four-tier priority (see
/// [resolveFilename] doc comment).
String _buildFileName({
  required String url,
  required Uri uri,
  String? suggestedFilename,
  String? dispositionFilename,
  String? contentType,
}) {
  // ------ Priority 1: Content-Disposition filename ------
  if (dispositionFilename != null && dispositionFilename.isNotEmpty) {
    final sanitized = dispositionFilename
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .trim();
    if (sanitized.isNotEmpty && sanitized.contains('.')) {
      return sanitized;
    }
    if (sanitized.isNotEmpty) {
      // Has name but no extension — add one from Content-Type or URL.
      final ext = _extensionForContentType(contentType) ??
          extensionFromUrlPath(url);
      return ext.isNotEmpty ? '$sanitized$ext' : sanitized;
    }
  }

  // ------ Priority 2: suggestedFilename from WebView ------
  if (suggestedFilename != null && suggestedFilename.isNotEmpty) {
    final sugExt = suggestedFilename.contains('.')
        ? '.${suggestedFilename.split('.').last}'
        : '';
    if (sugExt.isNotEmpty && sugExt.toLowerCase() != '.bin') {
      // It has a real extension — use as-is.
      return suggestedFilename
          .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
          .trim();
    }
    // .bin or extensionless — try to replace with real extension.
    final base = suggestedFilename.replaceAll(RegExp(r'\.[^.]+$'), '');
    final ext = _extensionForContentType(contentType) ??
        extensionFromUrlPath(url);
    if (ext.isNotEmpty) {
      return '$base$ext';
    }
    return base;
  }

  // ------ Priority 3: URL path extension ------
  final urlExt = extensionFromUrlPath(url);
  if (urlExt.isNotEmpty) {
    final lastSeg = uri.pathSegments.isNotEmpty
        ? uri.pathSegments.last
        : 'download';
    final base = lastSeg.replaceAll(RegExp(r'\.[^.]+$'), '');
    return '$base$urlExt';
  }

  // ------ Priority 4: URL last segment + mime-derived extension ------
  final nameFromUrl = uri.pathSegments.isNotEmpty
      ? uri.pathSegments.last
      : 'aurora-download';
  final decoded = Uri.decodeComponent(nameFromUrl);
  final base = decoded.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  final baseName = base.isEmpty ? 'aurora-download' : base;

  final ext = _extensionForContentType(contentType) ?? '';
  return ext.isNotEmpty ? '$baseName$ext' : baseName;
}

/// Maps a Content-Type string to a file extension (including the dot),
/// or returns `null` if the MIME type is unknown.
String? _extensionForContentType(String? contentType) {
  if (contentType == null || contentType.isEmpty) return null;
  return MediaFileTypes.extensionForMime(contentType);
}

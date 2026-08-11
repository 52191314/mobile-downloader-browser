import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../platform/network_binding_service.dart';

/// Comprehensive utility that fetches web page HTML using Android's native [HttpURLConnection]
/// (bypassing Cloudflare WebView WAF blocks via native TLS fingerprint) and extracts embedded
/// video streams (.m3u8, .mp4, .mpd) from direct HTML, JS variables, Base64 strings, and iframe embeds.
class NativeHtmlMediaExtractor {
  static final RegExp _m3u8RegExp = RegExp(
    // Protocol-relative (//host/...) URLs resolve to https: at parse time.
    r'(?:https?:)?//[^\s"<>]+?\.(?:m3u8|mp4|mpd)(?:\?[^\s"<>]+)?',
    caseSensitive: false,
  );

  static final RegExp _escapedM3u8RegExp = RegExp(
    r'(?:https?:)?\\/\\/[^\s"<>]+?\.(?:m3u8|mp4|mpd)(?:\?[^\s"<>]+)?',
    caseSensitive: false,
  );

  static final RegExp _iframeDoubleQuoteRegExp = RegExp(
    r'<iframe[^>]+src="([^">]+)"',
    caseSensitive: false,
  );

  static final RegExp _iframeSingleQuoteRegExp = RegExp(
    r"<iframe[^>]+src='([^'>]+)'",
    caseSensitive: false,
  );

  static final RegExp _base64CandidateRegExp = RegExp(
    r'aHR0c[a-zA-Z0-9+/=]{20,}',
  );

  /// Synchronously parses an HTML string for media streams.
  static List<String> parseHtmlForMedia(String html) {
    if (html.isEmpty) return const [];
    final results = <String>{};

    // 1. Direct URLs (absolute or protocol-relative)
    for (final match in _m3u8RegExp.allMatches(html)) {
      var raw = match.group(0);
      if (raw != null && raw.isNotEmpty) {
        if (raw.startsWith('//')) raw = 'https:$raw';
        raw = _cleanStreamUrl(raw);
        if (_isValidStreamUrl(raw)) results.add(raw);
      }
    }

    // 2. Escaped JSON URLs e.g. https:\/\/... or \/\/...
    for (final match in _escapedM3u8RegExp.allMatches(html)) {
      var raw = match.group(0);
      if (raw != null && raw.isNotEmpty) {
        var unescaped = raw.replaceAll(r'\/', '/');
        if (unescaped.startsWith('//')) unescaped = 'https:$unescaped';
        unescaped = _cleanStreamUrl(unescaped);
        if (_isValidStreamUrl(unescaped)) results.add(unescaped);
      }
    }

    // 3. Base64 encoded stream URLs (e.g. aHR0cHM6...)
    for (final match in _base64CandidateRegExp.allMatches(html)) {
      final b64 = match.group(0);
      if (b64 != null && b64.isNotEmpty) {
        try {
          final decoded = utf8.decode(base64.decode(base64.normalize(b64)));
          final cleaned = _cleanStreamUrl(decoded);
          if (_isValidStreamUrl(cleaned)) results.add(cleaned);
        } catch (_) {}
      }
    }

    return results.toList();
  }

  /// Fetches [pageUrl] using native [HttpURLConnection] and parses the response
  /// body for video stream URLs (including nested iframes).
  static Future<List<String>> extractMediaFromUrl(
    String pageUrl, {
    Map<String, String>? headers,
    int depth = 0,
  }) async {
    if (pageUrl.isEmpty || !pageUrl.startsWith('http')) return const [];
    if (depth > 2) return const []; // Limit recursion depth for embedded iframes

    try {
      final requestHeaders = <String, String>{
        'User-Agent':
            headers?['User-Agent'] ??
            'Mozilla/5.0 (Linux; Android 14; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.6778.135 Mobile Safari/537.36',
        'Referer': headers?['Referer'] ?? pageUrl,
        if (headers?['Cookie'] != null) 'Cookie': headers!['Cookie']!,
      };

      final result = await NetworkBindingService.fetchUrl(
        pageUrl,
        headers: requestHeaders,
      );

      if (result == null || result['body'] is! String) return const [];

      final String body = result['body'] as String;
      if (body.isEmpty) return const [];

      final results = <String>{};

      // Direct HTML parsing
      results.addAll(parseHtmlForMedia(body));

      // Nested IFrame Embeds
      if (depth == 0) {
        final iframeMatches = [
          ..._iframeDoubleQuoteRegExp.allMatches(body),
          ..._iframeSingleQuoteRegExp.allMatches(body),
        ];
        for (final match in iframeMatches) {
          final iframeSrc = match.group(1);
          if (iframeSrc != null && iframeSrc.isNotEmpty) {
            final resolvedIframeUrl = _resolveUrl(pageUrl, iframeSrc);
            if (resolvedIframeUrl != null) {
              final nestedResults = await extractMediaFromUrl(
                resolvedIframeUrl,
                headers: requestHeaders,
                depth: depth + 1,
              );
              results.addAll(nestedResults);
            }
          }
        }
      }

      if (kDebugMode) {
        debugPrint(
          '[NativeHtmlMediaExtractor] Found ${results.length} media streams on $pageUrl (depth=$depth)',
        );
      }

      return results.toList();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[NativeHtmlMediaExtractor] Error extracting from $pageUrl: $e');
      }
      return const [];
    }
  }

  static String _cleanStreamUrl(String raw) {
    var cleaned = raw.trim();
    // Trim trailing single/double quotes, semicolons, commas, or parentheses
    while (cleaned.isNotEmpty &&
        (cleaned.endsWith("'") ||
            cleaned.endsWith('"') ||
            cleaned.endsWith(';') ||
            cleaned.endsWith(',') ||
            cleaned.endsWith(')'))) {
      cleaned = cleaned.substring(0, cleaned.length - 1);
    }
    return cleaned;
  }

  static bool _isValidStreamUrl(String url) {
    if (!url.startsWith('http')) return false;
    if (url.contains('ping.m3u8') || url.contains('/ping')) return false;
    return url.contains('.m3u8') || url.contains('.mp4') || url.contains('.mpd');
  }

  static String? _resolveUrl(String baseUrl, String relativeOrAbsolute) {
    try {
      final base = Uri.parse(baseUrl);
      final resolved = base.resolve(relativeOrAbsolute);
      return resolved.toString();
    } catch (_) {
      return null;
    }
  }
}

import 'package:flutter/foundation.dart';

import 'models/browser_tab.dart';

/// Desktop Chrome UA used for download requests to mimic a browser.
const String snifferDownloadUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36';

/// Regex matching common media file extensions for fast-path detection.
final RegExp mediaFastPathRegExp = RegExp(
  r'\.(mp4|m3u8|webm|mkv|avi|flv|mov|3gp|ogv|wmv|m4v|f4v|mpeg|mpg|mts|m2ts|hevc|'
  r'mp3|wav|aac|ogg|m4a|flac|opus|wma|mid|midi|aiff|alac|'
  r'jpg|jpeg|png|gif|webp|bmp|svg|ico|avif|tiff|tif|heic|heif|psd|'
  r'pdf|epub|mobi|docx?|xlsx?|pptx?|txt|csv|tsv|rtf|'
  r'zip|rar|7z|tar|gz|bz2|xz|iso|cab|arj|lzh|ace|dmg|'
  r'srt|vtt|ass|ssa|sub|idx|'
  r'exe|msi|apk|deb|rpm|AppImage|'
  r'mpd|f4m|smil|m3u|'
  r'torrent)(\?.*)?$',
  caseSensitive: false,
);

/// The original UA string from the WebView with `wv` (WebView) marker and
/// version suffixes stripped. Many CDNs throttle requests that carry a `wv`
/// marker, so we clean it.
String cleanUserAgent(String raw) {
  return raw
      .replaceAll(RegExp(r'\s*; wv\b'), '')
      .replaceAll(RegExp(r'\s*AppleWebKit/[0-9.]+'), '')
      .replaceAll(RegExp(r'\s*\(KHTML, like Gecko\)'), '')
      .replaceAll(RegExp(r'\s*Chrome/[0-9.]+'), ' Chrome/125.0.0.0')
      .replaceAll(RegExp(r'\s*Safari/[0-9.]+'), ' Safari/537.36')
      .replaceAll(RegExp(r'\s*Mobile\b'), '')
      .replaceAll(RegExp(r'\s*Version/[0-9.]+'), '');
}

/// Returns the download-appropriate User-Agent for [targetUrl].
/// For Cloudflare-protected sites (surrit.com), the raw WebView UA must be
/// preserved (it earned the `cf_clearance` cookie). For other hosts, the
/// cleaned UA is used to avoid CDN throttling.
String downloadUserAgent(String targetUrl, BrowserTab tab) {
  final raw = tab.userAgent;
  if (raw == null || raw.isEmpty) return snifferDownloadUserAgent;
  if (targetUrl.toLowerCase().contains('surrit.com')) {
    return raw; // Must match the UA that earned Cloudflare clearance.
  }
  return cleanUserAgent(raw);
}

/// Normalizes headers for media requests to protected CDNs.
/// For surrit.com, the Referer must be the current-page URL (not the source
/// page that contains the video link) because the CDN validates Referer
/// against the short-lived auth token embedded in the media URL.
Map<String, String> normalizeHeadersForUrl(
  Map<String, String> headers,
  String targetUrl, {
  String? currentUrl,
  String? addressText,
  String? sourcePageUrl,
}) {
  final targetLower = targetUrl.toLowerCase();
  if (targetLower.contains('surrit.com')) {
    String? refererKey;
    for (final key in headers.keys) {
      if (key.toLowerCase() == 'referer') {
        refererKey = key;
        break;
      }
    }
    if (refererKey != null) {
      final candidate = firstNonEmpty([currentUrl, addressText, sourcePageUrl]);
      if (candidate != null && candidate.isNotEmpty) {
        headers = Map<String, String>.from(headers);
        headers[refererKey] = candidate;
      }
    }
  }
  return headers;
}

/// Returns the first non-null, non-empty string from the iterable.
String? firstNonEmpty(Iterable<String?> values) {
  for (final v in values) {
    if (v != null && v.isNotEmpty) return v;
  }
  return null;
}

/// Fast-path check: returns true if [url] looks like it might point to
/// downloadable media (extension match or blob/magnet scheme).
bool looksLikeMediaUrl(String url) {
  if (url.startsWith('blob:') || url.startsWith('magnet:')) return true;
  return mediaFastPathRegExp.hasMatch(url);
}

/// Canonical set of URL path hints that suggest a URL may be a disguised
/// HLS/DASH playlist served under a non-standard extension (e.g.
/// `.../hls/.../index.jpg` whose body is `#EXTM3U`). Centralized so every
/// playlist-routing / detection site uses the same list — previously this
/// list was duplicated in 7 places with drift risk.
const Set<String> _playlistPathHints = {
  '/hls/',
  '/master',
  '/playlist',
  '/manifest',
  '/dash/',
};

/// Returns true if [url] contains a known disguised-playlist path hint.
/// Case-insensitive. Used by classification, enrichment, capture analysis,
/// download routing, and the WebView resource guard.
bool isPlaylistPathHint(String url) {
  final low = url.toLowerCase();
  return _playlistPathHints.any((h) => low.contains(h));
}

/// Returns the standard base request headers for media downloads.
/// Currently only includes Do-Not-Track headers if enabled.
Map<String, String> baseRequestHeaders(bool doNotTrackEnabled) {
  if (!doNotTrackEnabled) return const {};
  return const {'DNT': '1', 'Sec-GPC': '1'};
}

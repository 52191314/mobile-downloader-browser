import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'models/browser_tab.dart';
import 'models/sniffed_media.dart';

/// Desktop Chrome UA used for download requests to mimic a browser.
const String snifferDownloadUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36';

/// Default mobile Chrome UA (browser UI profile + download fallback).
const String snifferMobileUserAgent =
    'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

/// Predefined User-Agent profiles keyed by [DownloadSettings.userAgentProfile].
const Map<String, String> uaProfiles = <String, String>{
  'mobile': snifferMobileUserAgent,
  'desktop_chrome': snifferDownloadUserAgent,
  'desktop_firefox':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:127.0) '
      'Gecko/20100101 Firefox/127.0',
  'safari':
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 '
      '(KHTML, like Gecko) Version/17.5 Safari/605.1.15',
};

/// Human-readable label for each profile key.
const Map<String, String> uaProfileLabels = <String, String>{
  'mobile': 'Mobile Chrome',
  'desktop_chrome': 'Desktop Chrome',
  'desktop_firefox': 'Desktop Firefox',
  'safari': 'Safari (macOS)',
  'custom': 'Custom User-Agent',
};

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

String? _systemUserAgent;

/// The raw native system User-Agent fetched at startup, or null if not yet
/// initialised. Used by [StealthMetadataChannel] to extract the Chrome version.
String? get systemUserAgent => _systemUserAgent;

/// Asynchronously fetches the native system User-Agent. Should be called
/// once at app startup so [uaForProfile] can synchronously return a clean
/// User-Agent that perfectly matches the engine's Sec-CH-UA headers.
Future<void> initSystemUserAgent() async {
  try {
    _systemUserAgent = await InAppWebViewController.getDefaultUserAgent();
  } catch (_) {}
}

/// Returns the User-Agent string for a given profile key.
String uaForProfile(String profile, {String customUserAgent = ''}) {
  if (profile == 'custom' && customUserAgent.isNotEmpty) {
    return customUserAgent;
  }
  if (profile == 'mobile' && _systemUserAgent != null) {
    return stripWebViewUaMarkers(_systemUserAgent!);
  }
  return uaProfiles[profile] ?? stripWebViewUaMarkers(_systemUserAgent);
}

/// Aggressive UA rewrite for callers that want a desktop-like fingerprint.
/// Prefer [stripWebViewUaMarkers] for download requests (Cloudflare-safe).
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

/// Strips only WebView markers (`; wv`, bare `wv`, `Version/4.0`) so the rest
/// of the browser UA stays intact. Used for download User-Agent selection.
String stripWebViewUaMarkers(String? ua) {
  if (ua == null || ua.isEmpty) return snifferMobileUserAgent;
  return ua
      .replaceAll(RegExp(r';\s*wv', caseSensitive: false), '')
      .replaceAll(RegExp(r'\bwv\b', caseSensitive: false), '')
      .replaceAll(RegExp(r'Version/4\.0\s*', caseSensitive: false), '');
}

/// Returns the download-appropriate User-Agent for [targetUrl].
///
/// For Cloudflare-protected sites (surrit.com), the raw WebView UA must be
/// preserved (it earned the `cf_clearance` cookie). For other hosts, only
/// WebView markers are stripped to avoid CDN throttling while keeping the
/// rest of the UA stable.
String downloadUserAgent(String targetUrl, BrowserTab tab) {
  final raw = tab.userAgent;
  if (raw == null || raw.isEmpty) return snifferMobileUserAgent;
  if (targetUrl.toLowerCase().contains('surrit.com')) {
    return raw; // Must match the UA that earned Cloudflare clearance.
  }
  return stripWebViewUaMarkers(raw);
}

/// Case-insensitive header presence check.
bool hasHeader(Map<String, String> headers, String name) {
  return headers.keys.any((key) => key.toLowerCase() == name.toLowerCase());
}

/// Merges [source] into [target], replacing any existing key with the same
/// name ignoring case.
void mergeHeaders(Map<String, String> target, Map<String, String> source) {
  for (final entry in source.entries) {
    target.removeWhere(
      (key, _) => key.toLowerCase() == entry.key.toLowerCase(),
    );
    target[entry.key] = entry.value;
  }
}

/// If [headers] lacks `Origin`, derives one from [referer] (scheme + host).
void ensureOriginHeader(Map<String, String> headers, String referer) {
  if (hasHeader(headers, 'Origin')) return;
  final uri = Uri.tryParse(referer);
  if (uri != null && uri.host.isNotEmpty && uri.scheme.isNotEmpty) {
    headers['Origin'] = '${uri.scheme}://${uri.host}';
  }
}

/// Normalizes headers for media requests to protected CDNs (surrit.com).
///
/// Mutates [headers] in place and returns the same map.
Map<String, String> normalizeHeadersForUrl(
  Map<String, String> headers,
  String targetUrl, {
  String? currentUrl,
  String? addressText,
  String? sourcePageUrl,
}) {
  final targetLower = targetUrl.toLowerCase();
  if (!targetLower.contains('surrit.com')) return headers;

  String? refererKey;
  for (final key in headers.keys) {
    if (key.toLowerCase() == 'referer') {
      refererKey = key;
      break;
    }
  }

  String? currentReferer = refererKey != null ? headers[refererKey] : null;

  // 1. Always fix missav.com -> missav.ws domain migration if present.
  if (currentReferer != null &&
      currentReferer.toLowerCase().contains('missav.com')) {
    currentReferer = currentReferer.replaceAll(
      RegExp(r'missav\.com', caseSensitive: false),
      'missav.ws',
    );
    if (refererKey != null) {
      headers.remove(refererKey);
    }
    headers['Referer'] = currentReferer;
    ensureOriginHeader(headers, currentReferer);
    return headers;
  }

  // 2. If the referer is already a surrit.com URL, keep it (CDN needs it).
  if (currentReferer != null &&
      currentReferer.toLowerCase().contains('surrit.com')) {
    ensureOriginHeader(headers, currentReferer);
    return headers;
  }

  // 3. No referer (or empty) — build a fallback.
  if (currentReferer == null || currentReferer.isEmpty) {
    final candidate = firstNonEmpty([
      sourcePageUrl,
      currentUrl,
      addressText,
    ]);
    if (candidate != null && !candidate.toLowerCase().contains('surrit.com')) {
      currentReferer = candidate;
    } else {
      final targetUri = Uri.tryParse(targetUrl);
      if (targetUri != null && targetUri.host.isNotEmpty) {
        currentReferer = '${targetUri.scheme}://${targetUri.host}/';
      } else {
        currentReferer = 'https://missav.ws/';
      }
    }
  }

  if (!currentReferer.startsWith('http://') &&
      !currentReferer.startsWith('https://')) {
    final targetUri = Uri.tryParse(targetUrl);
    if (targetUri != null && targetUri.host.isNotEmpty) {
      currentReferer = '${targetUri.scheme}://${targetUri.host}/';
    } else {
      currentReferer = 'https://missav.ws/';
    }
  }

  if (refererKey != null) {
    headers.remove(refererKey);
  }
  headers['Referer'] = currentReferer;
  ensureOriginHeader(headers, currentReferer);
  return headers;
}

/// Builds the full header map for a sniffed-media download enqueue.
Map<String, String> buildSniffedDownloadHeaders({
  required BrowserTab tab,
  required SniffedMedia media,
  required Map<String, String> cookieHeaders,
  String? currentUrl,
}) {
  final headers = <String, String>{
    'User-Agent': downloadUserAgent(media.url, tab),
  };
  mergeHeaders(headers, tab.controller.currentHeaders);
  mergeHeaders(headers, sanitizeSniffedMediaHeaders(media.headers));

  if (!hasHeader(headers, 'Referer')) {
    final referer = firstNonEmpty([
      media.sourcePageUrl,
      currentUrl,
      tab.addressController.text,
    ]);
    if (referer != null) {
      headers['Referer'] = referer;
    }
  }

  mergeHeaders(headers, cookieHeaders);

  // Re-add Authorization from sniff-time cache (sanitized out of media.headers).
  final cachedAuth = tab.authHeaderCache[media.url];
  if (cachedAuth != null &&
      cachedAuth.isNotEmpty &&
      !hasHeader(headers, 'Authorization')) {
    headers['Authorization'] = cachedAuth;
  }

  normalizeHeadersForUrl(
    headers,
    media.url,
    currentUrl: currentUrl,
    addressText: tab.addressController.text,
    sourcePageUrl: media.sourcePageUrl,
  );

  return headers;
}

/// Returns the first non-null, non-empty (after trim) string from [values].
String? firstNonEmpty(Iterable<String?> values) {
  for (final value in values) {
    final trimmed = value?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      return trimmed;
    }
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

/// Secondary path hints that may indicate video content but are too generic
/// to classify directly (e.g. `/media/`, `/video/`).  These are used by the
/// extensionless URL probe (G1) as triggers for a content-type HEAD probe
/// rather than being treated as direct playlist classifiers.  Empty by
/// default; populated when G1 probes are active.
const Set<String> _secondaryMediaPathHints = {
  '/media/',
  '/video/',
  '/stream/',
  '/cdn/',
};

/// Returns true if [url] contains a known disguised-playlist path hint.
/// Case-insensitive. Used by classification, enrichment, capture analysis,
/// download routing, and the WebView resource guard.
bool isPlaylistPathHint(String url) {
  final low = url.toLowerCase();
  return _playlistPathHints.any((h) => low.contains(h));
}

/// Returns true if [url] contains a secondary media path hint such as
/// `/media/`, `/video/`, `/stream/`, or `/cdn/`.  These are used by the
/// extensionless URL probe (G1) as triggers for a content-type HEAD probe
/// rather than being treated as direct playlist classifiers.
bool isSecondaryMediaPathHint(String url) {
  final low = url.toLowerCase();
  return _secondaryMediaPathHints.any((h) => low.contains(h));
}

/// Known video-hosting CDN domains that serve video through redirect chains
/// or iframe embeds (DoodStream, Streamtape, MixDrop, etc.). These URLs
/// rarely end in `.mp4` — they use token-based download paths like
/// `/d/abc123` or `/download/hash/...`. When `onLoadResource` sees a
/// request to one of these hosts, we capture it as a potential video.
const Set<String> _knownVideoHosts = {
  // DoodStream / DoodStream mirrors
  'dood.sh', 'dood.so', 'doodstream.com', 'doodcdn.io', 'doodcdn.com',
  'dood.pm', 'dood.ws', 'dood.cx', 'dood.re', 'dood.yt',
  // PlayMogo (DoodStream CDN)
  'playmogo.com',
  // Streamtape
  'streamtape.com', 'streamtape.net', 'streamtape.to', 'streamtape.cc',
  // MixDrop
  'mixdrop.co', 'mixdrop.to', 'mixdrop.ch', 'mixdrop.sc',
  // Upstream
  'upstream.to', 'upstreamembed.com',
  // Vidoza
  'vidoza.net', 'vidoza.co', 'vidoza.org',
  // FileMoon
  'filemoon.sx', 'filemoon.in', 'filemoon.to',
  // StreamWish
  'streamwish.to', 'streamwish.com', 'streamwish.cc',
  // UqLoad
  'uqload.co', 'uqload.com',
  // VideoVard
  'videovard.sx', 'videovard.to',
  // Fastream
  'fastream.to', 'fastream.co',
  // Guccihideout
  'guccihideout.com',
  // Voe
  'voe.sx', 'voe-unblock.com', 'voe-unblock.net',
  // Vidplay
  'vidplay.site', 'vidplay.online', 'vidplay.live',
};

/// Returns true if [url] points to a known video-hosting CDN that serves
/// video through redirect chains or iframe embeds. Used by `onLoadResource`
/// to capture video URLs that don't have a standard media extension.
///
/// [extraHosts] can be used to extend the built-in set with user-configured
/// domains from the app settings (G2 placeholder).
bool isVideoHostingUrl(String url, {Set<String>? extraHosts}) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) return false;
  final host = uri.host.toLowerCase();
  // Check built-in known hosts.
  for (final known in _knownVideoHosts) {
    if (host == known || host.endsWith('.$known')) return true;
  }
  // Check user-configured custom hosts.
  if (extraHosts != null) {
    for (final known in extraHosts) {
      if (host == known.toLowerCase() || host.endsWith('.$known')) return true;
    }
  }
  return false;
}

/// Shared DOM-query JavaScript used by both [HeadlessPageResniffer] and
/// [_SnifferScreenState._queryHlsFromPage] to find the first .m3u8 URL on
/// a page. Extracted so the headless path (P1) and the visible-tab path
/// share one source of truth.
const String kHlsDomQueryJs = r'''
(() => {
  function findHls(root) {
    if (!root || !root.querySelectorAll) return '';
    const sources = root.querySelectorAll('source[src]');
    for (const s of sources) {
      const src = s.src || s.getAttribute('src') || '';
      if (src && src.indexOf('.m3u8') !== -1 && src.indexOf('ping.m3u8') === -1 && src.indexOf('/ping') === -1) return src;
    }
    const medias = root.querySelectorAll('video, audio');
    for (const m of medias) {
      const src = m.currentSrc || m.src || '';
      if (src && src.indexOf('.m3u8') !== -1 && src.indexOf('ping.m3u8') === -1 && src.indexOf('/ping') === -1) return src;
    }
    const scripts = root.querySelectorAll('script');
    for (const sc of scripts) {
      const text = sc.textContent || '';
      const match = text.match(/https?:\/\/[^"\\s]+\.m3u8[^"\\s]*/);
      if (match) {
        const u = match[0];
        if (u.indexOf('ping.m3u8') === -1 && u.indexOf('/ping') === -1) return u;
      }
    }
    return '';
  }
  let url = findHls(document);
  if (url) return url;
  const iframes = document.querySelectorAll('iframe');
  for (const iframe of iframes) {
    try {
      url = findHls(iframe.contentDocument);
      if (url) return url;
    } catch (e) {}
  }
  return '';
})()
''';

/// Normalises a URL for comparison by stripping query parameters.
/// Used when comparing a refreshed token URL against the stale one.
String normalizeUrlForCompare(String url) {
  try {
    final uri = Uri.parse(url);
    return uri.replace(queryParameters: {}).toString();
  } catch (_) {
    return url;
  }
}

/// Returns the standard base request headers for media downloads.
/// Currently only includes Do-Not-Track headers if enabled.
Map<String, String> baseRequestHeaders(bool doNotTrackEnabled) {
  if (!doNotTrackEnabled) return const {};
  return const {'DNT': '1', 'Sec-GPC': '1'};
}

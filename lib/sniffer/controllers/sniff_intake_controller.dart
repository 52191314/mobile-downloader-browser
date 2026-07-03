import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../downloader/downloader.dart';
import '../../settings/download_settings.dart';
import '../cookie_header_cache.dart';
import '../models/browser_tab.dart';
import '../models/sniffed_media.dart';
import 'tab_manager.dart';

/// Owns the URL intake pipeline that feeds sniffed media into the
/// [MediaSnifferEngine] for the active browser tab.
///
/// The controller:
///   - runs the fast-path media URL filter,
///   - resolves target headers (UA, Referer, cookies, base request
///     headers) for the sniffed URL,
///   - caches cookies by origin for ~5s to avoid flooding the native
///     cookie manager per captured URL,
///   - persists the Authorization header into the tab's authHeaderCache
///     so download tasks can re-attach it later,
///   - hands the captured media to the per-tab [MediaSnifferEngine].
///
/// All side effects that touch the host ([setState], snackbars, the
/// sniffed-count badge) are surfaced as named callbacks so this class
/// can be unit-tested in isolation.
class SniffIntakeController {
  /// Tab list + active-tab state. Used to resolve the current active tab
  /// and its media-change throttling timers.
  final TabManager tabManager;

  /// Cookie header cache, keyed by URL origin.
  final CookieHeaderCache cookieCache = CookieHeaderCache();

  /// Reference to the download queue — kept for parity with the
  /// [TabManager] and future enrichment hooks. The controller does not
  /// enqueue downloads itself; that is the role of the
  /// [DownloadQueue.addTask] call sites in [SnifferScreen].
  final DownloadQueue? downloadQueue;

  /// Download settings — used for Do-Not-Track / `Sec-GPC` headers.
  final DownloadSettings settings;

  /// Base directory for sniffed-media cache persistence. When non-null
  /// the controller can auto-save the per-tab media cache after each
  /// detection.
  final String? baseDir;

  /// Triggers a `setState` on the host widget. The host decides what
  /// to rebuild.
  final void Function(VoidCallback fn) setState;

  /// Returns `true` while the host widget is still mounted.
  final bool Function() isMounted;

  /// Optional callback invoked when the captured-media count changes,
  /// so the host can update the FAB badge.
  final void Function(int? count)? onSniffedCountChanged;

  /// Returns the User-Agent string for a given profile key
  /// (e.g. `mobile`, `desktop_chrome`). Wraps the parent
  /// `_uaForProfile` top-level function.
  final String Function(String profile) uaForProfile;

  /// Returns the download-appropriate User-Agent for a given target URL
  /// and active tab. Wraps `downloadUserAgent` from
  /// [sniffer_url_utils.dart].
  final String Function(String targetUrl, BrowserTab tab) downloadUserAgent;

  /// Returns the base request headers (DNT / Sec-GPC) according to the
  /// current `doNotTrackEnabled` setting.
  final Map<String, String> Function() baseRequestHeaders;

  /// Normalizes a request-header map for the given target URL. The
  /// adapter may mutate the input map in place and/or return a new map
  /// (matching the original `_normalizeHeadersForUrl` top-level
  /// function's contract).
  final Map<String, String> Function(
    Map<String, String> headers,
    String targetUrl, {
    String? currentUrl,
    String? addressText,
    String? sourcePageUrl,
  }) normalizeHeadersForUrl;

  /// Returns the first non-null, non-empty string in [values].
  final String? Function(Iterable<String?> values) firstNonEmpty;

  SniffIntakeController({
    required this.tabManager,
    required this.settings,
    this.downloadQueue,
    this.baseDir,
    required this.setState,
    required this.isMounted,
    this.onSniffedCountChanged,
    required this.uaForProfile,
    required this.downloadUserAgent,
    required this.baseRequestHeaders,
    required this.normalizeHeadersForUrl,
    required this.firstNonEmpty,
  });

  // ---------------------------------------------------------------------------
  // Media URL fast-path
  // ---------------------------------------------------------------------------

  /// Extension + path-prefix regex used to drop CSS / JS / fonts /
  /// analytics URLs from the sniffer before any async work. Includes
  /// the path prefixes `/hls/`, `/master/`, `/playlist/`, etc. that
  /// often point at HLS segments and playlists.
  static final RegExp _mediaFastPathRegExp = RegExp(
    r'\.(mp4|m3u8|webm|mkv|avi|flv|mov|3gp|ogv|wmv|m4v|f4v|mpeg|mpg|mts|m2ts|hevc|'
    r'mp3|wav|aac|ogg|m4a|flac|opus|wma|mid|midi|aiff|alac|'
    r'jpg|jpeg|png|gif|webp|bmp|svg|ico|avif|tiff|tif|heic|heif|psd|'
    r'pdf|epub|mobi|docx?|xlsx?|pptx?|txt|csv|tsv|rtf|'
    r'zip|rar|7z|tar|gz|bz2|xz|iso|cab|arj|lzh|ace|dmg|'
    r'srt|vtt|ass|ssa|sub|idx|exe|msi|apk|deb|rpm|AppImage|mpd|f4m|smil|m3u)'
    r'|/(?:hls|master|playlist|manifest|dash|media|stream|video|seg|chunk)/',
    caseSensitive: false,
  );

  static bool _looksLikeMediaUrl(String url) {
    if (url.startsWith('blob:') || url.startsWith('magnet:')) return true;
    return _mediaFastPathRegExp.hasMatch(url);
  }

  // ---------------------------------------------------------------------------
  // Public intake
  // ---------------------------------------------------------------------------

  /// Main captured-URL intake path. Fast-path filters out non-media
  /// URLs (CSS/JS/fonts/analytics) and delegates to [sniffWithLiveHeaders]
  /// for the rest. Keep unfiltered for content-type-bearing media
  /// responses.
  void sniffBrowserUrl(
    BrowserTab tab,
    String url, {
    String? sourcePageUrl,
    String? contentType,
    int? contentLength,
  }) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;
    // Fast-path: skip CSS/JS/fonts/analytics/etc. before any async work.
    // If contentType is provided, it may be a media response — let it through.
    if (contentType == null && !_looksLikeMediaUrl(trimmed)) return;
    unawaited(
      sniffWithLiveHeaders(
        tab,
        trimmed,
        sourcePageUrl: sourcePageUrl,
        contentType: contentType,
        contentLength: contentLength,
      ),
    );
  }

  /// Captures a media URL using normalized target URL headers, target
  /// origin cookies, and the browser's current request context. Captures
  /// the Authorization header (which gets sanitized out of
  /// [SniffedMedia.headers] by `sanitizeSniffedMediaHeaders`) into the
  /// tab's `authHeaderCache` so download tasks can re-attach it later.
  Future<void> sniffWithLiveHeaders(
    BrowserTab tab,
    String url, {
    String? sourcePageUrl,
    String? contentType,
    int? contentLength,
  }) async {
    try {
      final currentUrl = await tab.controller.currentUrl();
      final pageUrl =
          firstNonEmpty([
            sourcePageUrl,
            currentUrl,
            tab.addressController.text,
          ]) ??
          '';
      final liveHeaders = <String, String>{
        'User-Agent': downloadUserAgent(url, tab),
        ...baseRequestHeaders(),
      };
      if (pageUrl.isNotEmpty) {
        liveHeaders['Referer'] = pageUrl;
      }

      liveHeaders.addAll(tab.controller.currentHeaders);
      liveHeaders.addAll(await getCachedCookiesForUrl(url));

      normalizeHeadersForUrl(
        liveHeaders,
        url,
        currentUrl: currentUrl,
        addressText: tab.addressController.text,
        sourcePageUrl: sourcePageUrl,
      );

      // Capture Authorization header before it gets sanitized out of the
      // SniffedMedia.headers by sanitizeSniffedMediaHeaders.
      final auth = liveHeaders['Authorization'] ?? liveHeaders['authorization'];
      if (auth != null && auth.isNotEmpty) {
        tab.authHeaderCache[url] = auth;
      }

      tab.snifferEngine.sniff(
        url,
        sourcePageUrl: pageUrl,
        headers: liveHeaders,
        contentType: contentType,
        contentLength: contentLength,
      );
    } catch (e) {
      debugPrint('[SniffIntakeController] sniffWithLiveHeaders failed for $url: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Media cache save scheduling
  // ---------------------------------------------------------------------------

  /// Auto-save tab media cache after each detection. Bypasses throttling
  /// and writes immediately. Used by [scheduleMediaSave] after the
  /// throttling timer fires.
  void autoSaveTabMedia(BrowserTab tab) {
    if (baseDir == null) return;
    unawaited(
      tab.snifferEngine.saveDetectedMedia(
        '$baseDir/sniffed_media_cache_${tab.id}.json',
      ),
    );
  }

  /// Throttled UI rebuild — at most once per 500ms, batched.
  void scheduleMediaRebuild() {
    if (!isMounted()) return;
    final active = tabManager.activeTab;
    onSniffedCountChanged?.call(active.snifferEngine.detectedMedia.length);
    tabManager.mediaRebuildTimer?.cancel();
    tabManager.mediaRebuildTimer = Timer(const Duration(milliseconds: 500), () {
      if (isMounted()) setState(() {});
    });
  }

  /// Throttled media save — at most once per 3s, batched.
  void scheduleMediaSave(BrowserTab tab) {
    tabManager.mediaSaveTimer?.cancel();
    tabManager.mediaSaveTimer = Timer(const Duration(seconds: 3), () {
      autoSaveTabMedia(tab);
    });
  }

  // ---------------------------------------------------------------------------
  // Cookies
  // ---------------------------------------------------------------------------

  /// Cache key for [cookieCache]. Returns a scheme://host[:port] string
  /// for URLs with a valid host, or null if the URL cannot be parsed.
  String? cookieCacheKey(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty || uri.scheme.isEmpty) return null;
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host.toLowerCase()}$port';
  }

  /// Returns cookies for [url] from the [cookieCache] if fresh, else
  /// fetches them through [getCookiesForUrl] and caches the result.
  Future<Map<String, String>> getCachedCookiesForUrl(String url) async {
    final key = cookieCacheKey(url);
    if (key == null) return const {};
    final cached = cookieCache.get(key);
    if (cached != null) return cached;
    final cookies = await getCookiesForUrl(url);
    cookieCache.set(key, cookies);
    return cookies;
  }

  /// Retrieve cookies for the given URL from the WebView cookie store.
  /// Falls back to `document.cookie` for same-host / subdomain matches
  /// when the native cookie manager returns nothing.
  Future<Map<String, String>> getCookiesForUrl(String url) async {
    try {
      final uri = Uri.tryParse(url);
      if (uri != null) {
        final cookies = await CookieManager.instance().getCookies(
          url: WebUri.uri(uri),
        );
        if (cookies.isNotEmpty) {
          final parts = <String>[];
          for (final c in cookies) {
            if (c.name.isNotEmpty && c.value.isNotEmpty) {
              parts.add('${c.name}=${c.value}');
            }
          }
          if (parts.isNotEmpty) {
            return {'Cookie': parts.join('; ')};
          }
        }
      }
    } catch (e) {
      debugPrint(
        '[SniffIntakeController] CookieManager.getCookies failed for $url: $e',
      );
    }

    // Fallback: try document.cookie for page domain, only if same
    // domain/subdomain. Wraps the active tab from the host's tabManager
    // so the lookup uses the same-domain tab.
    try {
      final active = tabManager.activeTab;
      final activeUrl = active.addressController.text;
      final activeUri = Uri.tryParse(activeUrl);
      final targetUri = Uri.tryParse(url);
      if (activeUri != null && targetUri != null) {
        final activeHost = activeUri.host.toLowerCase();
        final targetHost = targetUri.host.toLowerCase();
        final isSameHost =
            activeHost == targetHost ||
            activeHost.endsWith('.$targetHost') ||
            targetHost.endsWith('.$activeHost');
        if (isSameHost) {
          final result = await active.controller.evaluateJavaScript(
            'document.cookie',
          );
          if (result is String && result.isNotEmpty) {
            final cookie = result.startsWith('"') && result.endsWith('"')
                ? result.substring(1, result.length - 1)
                : result;
            if (cookie.isNotEmpty) {
              return {'Cookie': cookie};
            }
          }
        }
      }
    } catch (e) {
      debugPrint(
        '[SniffIntakeController] document.cookie fallback failed for $url: $e',
      );
    }
    return {};
  }

  /// Clear the cookie cache. Called on `onPageStarted` to avoid stale
  /// cookies from a previous page influencing the new page's media
  /// captures.
  void clearCookieCache() {
    cookieCache.clear();
  }
}

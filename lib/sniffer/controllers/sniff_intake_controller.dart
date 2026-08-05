import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../downloader/downloader.dart';
import '../../settings/download_settings.dart';
import '../cookie_header_cache.dart';
import '../models/browser_tab.dart';
import '../models/sniffed_media.dart';
import '../sniffer_url_utils.dart';
import '../../compliance/restricted_media_policy.dart';
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
  static const int _maxActiveLiveHeaderSniffs = 4;
  static const int _maxQueuedLiveHeaderSniffs = 120;
  static const Duration _recentSniffWindow = Duration(seconds: 2);

  /// Tab list + active-tab state. Used to resolve the current active tab
  /// and its media-change throttling timers.
  final TabManager tabManager;

  /// Cookie header cache, keyed by URL origin.
  final CookieHeaderCache cookieCache = CookieHeaderCache();

  final Queue<_QueuedSniff> _queuedSniffs = Queue<_QueuedSniff>();
  final Set<String> _queuedSniffKeys = <String>{};
  final Map<String, DateTime> _recentSniffs = <String, DateTime>{};
  int _activeLiveHeaderSniffs = 0;

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
  })
  normalizeHeadersForUrl;

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
    String? thumbnailUrl,
  }) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;
    // Play: site-level hard-off (restricted surface page) — primary gate.
    if (!tab.sniffingEnabled) return;
    // Play: URL/CDN/page backstop (embeds, paste-equivalent captures).
    final pageUrl = sourcePageUrl ?? tab.currentUrl;
    if (RestrictedMediaPolicy.isBlocked(
      mediaUrl: trimmed,
      sourcePageUrl: pageUrl,
    )) {
      return;
    }
    // Fast-path: skip CSS/JS/fonts/analytics/etc. before any async work.
    // If contentType is provided, it may be a media response — let it through.
    if (contentType == null && !_looksLikeMediaUrl(trimmed)) return;
    _enqueueLiveHeaderSniff(
      _QueuedSniff(
        tab,
        trimmed,
        sourcePageUrl: sourcePageUrl,
        contentType: contentType,
        contentLength: contentLength,
        thumbnailUrl: thumbnailUrl,
      ),
    );
  }

  void _enqueueLiveHeaderSniff(_QueuedSniff request) {
    final key = request.key;
    final now = DateTime.now();
    _pruneRecentSniffs(now);
    final lastSeen = _recentSniffs[key];
    if (lastSeen != null && now.difference(lastSeen) < _recentSniffWindow) {
      return;
    }
    if (_queuedSniffKeys.contains(key)) return;

    if (_queuedSniffs.length >= _maxQueuedLiveHeaderSniffs) {
      // Evict the lowest-priority queued sniff (tie-break: oldest first)
      // instead of blindly dropping the oldest. This keeps important HLS /
      // master playlist captures alive when the queue is saturated by a
      // burst of low-value image/document URLs.
      var minPriority = _queuedSniffs.first.priority;
      var dropIndex = 0;
      for (var i = 1; i < _queuedSniffs.length; i++) {
        final p = _queuedSniffs.elementAt(i).priority;
        if (p < minPriority) {
          minPriority = p;
          dropIndex = i;
        }
      }
      final dropped = _queuedSniffs.elementAt(dropIndex);
      _queuedSniffs.remove(dropped);
      _queuedSniffKeys.remove(dropped.key);
    }
    _queuedSniffs.addLast(request);
    _queuedSniffKeys.add(key);
    _drainLiveHeaderSniffs();
  }

  void _drainLiveHeaderSniffs() {
    while (_activeLiveHeaderSniffs < _maxActiveLiveHeaderSniffs &&
        _queuedSniffs.isNotEmpty) {
      final request = _queuedSniffs.removeFirst();
      _queuedSniffKeys.remove(request.key);
      _activeLiveHeaderSniffs++;
      _recentSniffs[request.key] = DateTime.now();
      unawaited(
        sniffWithLiveHeaders(
          request.tab,
          request.url,
          sourcePageUrl: request.sourcePageUrl,
          contentType: request.contentType,
          contentLength: request.contentLength,
          thumbnailUrl: request.thumbnailUrl,
        ).whenComplete(() {
          _activeLiveHeaderSniffs--;
          _drainLiveHeaderSniffs();
        }),
      );
    }
  }

  void _pruneRecentSniffs(DateTime now) {
    if (_recentSniffs.length < 120) return;
    _recentSniffs.removeWhere(
      (_, seenAt) => now.difference(seenAt) > _recentSniffWindow,
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
    String? thumbnailUrl,
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
      if (!tab.sniffingEnabled) return;
      if (RestrictedMediaPolicy.isBlocked(
        mediaUrl: url,
        sourcePageUrl: pageUrl.isEmpty ? null : pageUrl,
      )) {
        return;
      }
      final liveHeaders = <String, String>{
        'User-Agent': downloadUserAgent(url, tab),
        ...baseRequestHeaders(),
      };
      if (pageUrl.isNotEmpty) {
        liveHeaders['Referer'] = pageUrl;
      }

      liveHeaders.addAll(tab.controller.currentHeaders);
      liveHeaders.addAll(await getCachedCookiesForUrl(url));

      if (RestrictedMediaPolicy.isBlocked(
        mediaUrl: url,
        sourcePageUrl: pageUrl.isEmpty ? null : pageUrl,
        headers: liveHeaders,
      )) {
        return;
      }

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

      // Prefer structured page meta (og:title) over raw WebView title so
      // downloads get descriptive names (e.g. MissAV full titles) instead of
      // URL slugs when the tab title is empty or a WAF interstitial.
      final metaTitle = tab.pageMeta.title.trim();
      final structured = tab.pageMeta.structuredName?.trim() ?? '';
      final tabTitle = tab.title?.trim() ?? '';
      final pageTitle = metaTitle.isNotEmpty
          ? metaTitle
          : (structured.isNotEmpty
              ? structured
              : (tabTitle.isNotEmpty ? tabTitle : null));

      // Poster: only what the DOM scan attached to this exact element. The
      // page's og:image is *not* folded in here — whether it is a fair stand-in
      // depends on how many playable captures the page turns out to have, which
      // is not knowable yet at sniff time. The capture sheet applies it at paint
      // time instead, where it can see the whole list.
      final trimmedPoster = thumbnailUrl?.trim();
      final poster =
          (trimmedPoster == null || trimmedPoster.isEmpty) ? null : trimmedPoster;

      tab.snifferEngine.sniff(
        url,
        sourcePageUrl: pageUrl,
        pageTitle: pageTitle,
        headers: liveHeaders,
        contentType: contentType,
        contentLength: contentLength,
        thumbnailUrl: poster,
      );
    } catch (e) {
      debugPrint('sniffWithLiveHeaders failed for $url: $e');
    }
  }

  /// True when a page-level `og:image` is a reasonable stand-in poster for
  /// [url]. Video/audio/playlist captures on a watch page share that page's
  /// artwork; images already are their own thumbnail, and documents/archives
  /// would just be mislabelled by it.
  ///
  /// Called by the capture sheet rather than from this class: the page-level
  /// poster is resolved at paint time, not at sniff time. Two reasons. The
  /// guard is injected at document start, so its first `og:image` read is empty
  /// and the real value only lands on a later re-post; and a page's artwork is
  /// only a fair stand-in when the page holds a single playable capture, which
  /// is not yet known while captures are still arriving.
  static bool acceptsPageLevelPoster(String url, String? contentType) {
    final ct = contentType?.toLowerCase().split(';').first.trim() ?? '';
    if (ct.startsWith('video/') || ct.startsWith('audio/')) return true;
    if (ct.contains('mpegurl') || ct == 'application/dash+xml') return true;
    if (ct.startsWith('image/')) return false;
    if (ct.isNotEmpty && !ct.startsWith('application/octet-stream')) {
      return false;
    }
    return RegExp(
      r'\.(mp4|m3u8|mpd|webm|mkv|avi|flv|mov|m4v|ts|mp3|m4a|aac|flac|opus|ogg|wav)'
      r'(\?|$)',
      caseSensitive: false,
    ).hasMatch(url);
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

  /// Collects and merges cookies for media playback from the media host
  /// and the page host (CDN cookies + session cookies). CDNs often need
  /// both a valid Cookie jar and a page Referer; page-only cookies are
  /// useless on a third-party host but merging is always safe.
  Future<Map<String, String>> getPlaybackCookies({
    required String mediaUrl,
    String? pageUrl,
  }) async {
    final maps = <Map<String, String>>[];
    maps.add(await getCookiesForUrl(mediaUrl));
    final mediaUri = Uri.tryParse(mediaUrl);
    if (mediaUri != null && mediaUri.host.isNotEmpty) {
      final root = '${mediaUri.scheme}://${mediaUri.host}/';
      if (root != mediaUrl) {
        maps.add(await getCookiesForUrl(root));
      }
    }
    final page = pageUrl?.trim();
    if (page != null && page.isNotEmpty) {
      maps.add(await getCookiesForUrl(page));
      final pageUri = Uri.tryParse(page);
      if (pageUri != null && pageUri.host.isNotEmpty) {
        final root = '${pageUri.scheme}://${pageUri.host}/';
        if (root != page) {
          maps.add(await getCookiesForUrl(root));
        }
      }
    }
    return mergeCookieHeaderMaps(maps);
  }

  /// Merges multiple `Cookie` header maps into one by cookie name.
  /// Later maps win on name collision (page cookies override only when
  /// the media map lacked that name — callers pass media first, page last).
  static Map<String, String> mergeCookieHeaderMaps(
    List<Map<String, String>> maps,
  ) {
    final byName = <String, String>{};
    for (final m in maps) {
      String? raw;
      for (final e in m.entries) {
        if (e.key.toLowerCase() == 'cookie') {
          raw = e.value;
          break;
        }
      }
      if (raw == null || raw.isEmpty) continue;
      for (final part in raw.split(';')) {
        final trimmed = part.trim();
        if (trimmed.isEmpty) continue;
        final eq = trimmed.indexOf('=');
        if (eq <= 0) continue;
        final name = trimmed.substring(0, eq).trim();
        final value = trimmed.substring(eq + 1).trim();
        if (name.isEmpty) continue;
        byName[name] = value;
      }
    }
    if (byName.isEmpty) return const {};
    return {
      'Cookie': byName.entries.map((e) => '${e.key}=${e.value}').join('; '),
    };
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
      debugPrint('CookieManager.getCookies failed for $url: $e');
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
      debugPrint('document.cookie fallback failed for $url: $e');
    }
    return {};
  }

  /// Clear the cookie cache. Called on `onPageStarted` to avoid stale
  /// cookies from a previous page influencing the new page's media
  /// captures.
  void clearCookieCache() {
    cookieCache.clear();
  }

  void clearCookieCacheForHost(String host) {
    cookieCache.clearForHost(host);
  }
}

class _QueuedSniff {
  final BrowserTab tab;
  final String url;
  final String? sourcePageUrl;
  final String? contentType;
  final int? contentLength;
  final String? thumbnailUrl;

  const _QueuedSniff(
    this.tab,
    this.url, {
    this.sourcePageUrl,
    this.contentType,
    this.contentLength,
    this.thumbnailUrl,
  });

  String get key =>
      '${tab.id}|$url|${contentType ?? ''}|${contentLength ?? ''}';

  /// Eviction priority: higher = more important and kept longer when the
  /// queue is saturated. HLS/DASH playlists (incl. disguised ones under
  /// non-.m3u8 URLs) are highest; other media is medium; everything else
  /// is low.
  int get priority {
    final low = url.toLowerCase();
    if (isPlaylistPathHint(low) || low.contains('m3u8') || low.contains('mpd')) {
      return 3;
    }
    if (mediaFastPathRegExp.hasMatch(low)) return 2;
    return 1;
  }
}

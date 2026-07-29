import 'dart:async';

import 'package:http/http.dart' as http;

import '../compliance/restricted_media_policy.dart';
import '../downloader/media_file_types.dart';
import 'media_enricher.dart';
import 'models/sniffed_media.dart';
import 'sniffed_media_cache.dart';
import 'sniffer_url_utils.dart';

class MediaSnifferEngine implements MediaEnricherHost {
  final http.Client client;
  final Duration dedupDuration;
  final _mediaDetectedController = StreamController<SniffedMedia>.broadcast();
  Stream<SniffedMedia> get onMediaDetected => _mediaDetectedController.stream;
  Stream<SniffedMedia> get onMediaChanged => cache.mediaChangedController.stream;

  /// Owns the detected media list, dedup sets, eviction timers, and
  /// suppression counters. See [SniffedMediaCache] for details.
  late final SniffedMediaCache cache;

  int get maxDetectedMedia => cache.maxDetectedMedia;
  set maxDetectedMedia(int v) => cache.maxDetectedMedia = v;
  int get suppressedMediaCount => cache.suppressedMediaCount;
  Map<String, int> get suppressedReasons => cache.suppressedReasons;
  List<SniffedMedia> get detectedMedia => cache.unmodifiableDetectedMedia;
  bool get capReached => cache.capReached;

  Set<MediaType> disabledMediaTypes = const {};

  Set<String> _customVideoHosts = const {};

  /// Updates the set of user-configured video-hosting domains.
  /// These are checked in addition to the built-in [isVideoHostingUrl] list.
  void setCustomVideoHosts(Set<String> hosts) {
    _customVideoHosts = hosts;
  }

  /// Tracks URLs that have already been enqueued for enrichment.
  /// Used to skip re-enrichment when a content-type update or re-classification
  /// fires for an already-enriched item, preventing redundant HTTP probe chains.
  final Set<String> _enrichedUrls = {};

  bool _isDisposed = false;
  bool get isDisposed => _isDisposed;

  /// Optional callback that fetches cookies from the browser's cookie jar.
  /// When a [url] is provided, cookies are fetched for that URL's domain;
  /// otherwise defaults to the current page URL.
  Future<Map<String, String>> Function({String? url})? cookieProvider;

  /// Optional callback that fetches response headers for a URL through the
  /// WebView's JavaScript networking stack (bypasses Cloudflare WAF that
  /// blocks Dart's http.Client). Returns a map of lowercased header names,
  /// including 'statusCode', 'content-length', 'content-type'. Returns null
  /// on failure. Set by the owning [SnifferScreen] to point at the active
  /// tab's [SnifferBrowserController.fetchHeadersViaJavaScript].
  Future<Map<String, String>?> Function(String url)? fetchViaWebView;

  /// Optional callback that fetches the full response body for a URL through
  /// the WebView's JavaScript networking stack. Used to fetch HLS playlist
  /// bodies that the browser already loaded but Dart HTTP cannot reach
  /// (Cloudflare WAF). Set by the owning [SnifferScreen] to point at the
  /// active tab's [SnifferBrowserController.fetchPlaylistBodyViaJavaScript].
  /// When this callback is non-null and the [hlsPlaylistCache] lookup misses,
  /// enrichment will use the WebView to fetch the playlist body before
  /// falling back to a Dart HTTP GET.
  Future<String?> Function(String url)? fetchPlaylistBodyViaWebView;

  /// Optional callback that fetches the full response body for a URL through
  /// a headless WebView navigated to the CDN origin, using same-origin XHR
  /// to bypass both CORS (same origin) and Cloudflare WAF (real Chrome TLS
  /// fingerprint + cf_clearance cookie). Set by the owning
  /// [TabLifecycleController] to point at the per-tab
  /// [HeadlessWebViewFetcher.fetchText].
  ///
  /// This is the last-resort tier (4th attempt) after the JS body cache,
  /// page-origin WebView XHR, and Dart HTTP all fail. It should succeed for
  /// cross-origin / WAF-protected CDNs where the other tiers are blocked.
  Future<String?> Function(String url)? fetchPlaylistBodyViaHeadlessWebView;

  /// Optional per-tab HLS playlist body cache. When the browser already loaded
  /// a protected playlist, enrichment can parse that body without triggering a
  /// second Dart HTTP request that may be blocked by WAF/CORS policy.
  String? Function(String url)? hlsPlaylistCache;

  /// Active enrichment pipeline. Owns the enrich queue and the
  /// active-enrich counter.
  late final MediaEnricher enricher;

  MediaSnifferEngine({
    http.Client? client,
    this.dedupDuration = const Duration(seconds: 30),
    int maxDetectedMedia = 200,
    this.disabledMediaTypes = const {},
  }) : client = client ?? http.Client() {
    cache = SniffedMediaCache(
      mediaChangedController: StreamController<SniffedMedia>.broadcast(),
      maxDetectedMedia: maxDetectedMedia,
    );
    enricher = MediaEnricher(host: this);
  }

  // RegExp patterns matching specific categories
  // NOTE: .ts is intentionally excluded — individual HLS segments flood the
  // list and are not downloadable on their own. HLS playlists (.m3u8) are
  // detected via _streamRegExp and handled by the HLS downloader.
  static final RegExp _videoRegExp = RegExp(
    r'\.(mp4|m3u8|m3u|webm|mkv|avi|flv|mov|3gp|ogv|wmv|m4v|f4v|mpeg|mpg|mts|m2ts|hevc)(\?.*)?$',
    caseSensitive: false,
  );

  static final RegExp _audioRegExp = RegExp(
    r'\.(mp3|wav|aac|ogg|m4a|flac|opus|wma|mid|midi|aiff|alac)(\?.*)?$',
    caseSensitive: false,
  );

  static final RegExp _imageRegExp = RegExp(
    r'\.(jpg|jpeg|png|gif|webp|bmp|svg|ico|avif|tiff|tif|heic|heif|psd)(\?.*)?$',
    caseSensitive: false,
  );

  static final RegExp _documentRegExp = RegExp(
    r'\.(pdf|epub|mobi|docx?|xlsx?|pptx?|txt|csv|tsv|rtf)(\?.*)?$',
    caseSensitive: false,
  );

  static final RegExp _archiveRegExp = RegExp(
    r'\.(zip|rar|7z|tar|gz|bz2|xz|iso|cab|arj|lzh|ace|dmg)(\?.*)?$',
    caseSensitive: false,
  );

  static final RegExp _subtitleRegExp = RegExp(
    r'\.(srt|vtt|ass|ssa|sub|idx)(\?.*)?$',
    caseSensitive: false,
  );

  static final RegExp _executableRegExp = RegExp(
    r'\.(exe|msi|apk|deb|rpm|AppImage)(\?.*)?$',
    caseSensitive: false,
  );

  static final RegExp _streamRegExp = RegExp(
    r'\.(mpd|f4m|smil)(\?.*)?$',
    caseSensitive: false,
  );

  static final RegExp _torrentRegExp = RegExp(
    r'\.torrent(\?.*)?$',
    caseSensitive: false,
  );

  /// Returns true for URLs that are HLS/DASH segment files rather than
  /// playable/discoverable media. These are intentionally dropped so the
  /// 50-item cap is not filled with hundreds of .ts/.m4s fragments.
  static bool _looksLikeSegment(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    if (path.isEmpty) return false;

    // DASH segments and fMP4 HLS segments
    if (path.endsWith('.m4s')) return true;

    // HLS MPEG-TS segments have segment-specific naming patterns.
    if (path.endsWith('.ts')) {
      // Beeg24-style: .../hls/.../segment-47-v1-a1.ts
      if (path.contains('/segment-')) return true;
      if (RegExp(r'-v\d+-a\d+\.ts$').hasMatch(path)) return true;
      if (path.contains('/seg/') ||
          path.contains('/chunks/') ||
          path.contains('/fragments/')) {
        return true;
      }
      // Numbered .ts inside a stream/CDN path is almost certainly a segment.
      // Tightened (G3): match only when the number sits in a segment-like
      // position (e.g. `/seq-123.ts` or `/123.ts` after `/hls/`).  Bare
      // paths like `/clips/fun.ts` on a video host are kept.
      if ((path.contains('/hls/') ||
              path.contains('/stream/') ||
              path.contains('/cdn/')) &&
          RegExp(r'/(\d+|[a-z]+-\d+)\.ts$').hasMatch(path)) {
        return true;
      }
    }

    return false;
  }

  static String bandwidthLabel(int bandwidth) {
    if (bandwidth < 1000) return '$bandwidth bps';
    if (bandwidth < 1000000) {
      return '${(bandwidth / 1000).toStringAsFixed(0)} Kbps';
    }
    return '${(bandwidth / 1000000).toStringAsFixed(1)} Mbps';
  }

  /// Extracts a lowercased file extension (including the leading dot) from
  /// a URL path. Returns `null` when the path has no recognizable extension.
  /// Used by [sniff] to look up the container format label.
  static String? _extensionFromPath(String path) {
    return MediaFileTypes.extensionOf(path);
  }

  /// Maps a URL path's lowercased extension to a canonical container format
  /// label suitable for the `SniffedMedia.containerFormat` field. Returns
  /// `null` when the extension does not map to a known container.
  ///
  /// Used by [sniff] to populate `containerFormat` at detection time so the
  /// UI can show "MP4" / "WebM" / "FLAC" etc. alongside size and duration
  /// without waiting for the enricher to finish probing bytes.
  static String? containerFormatForExtension(String ext) {
    // Delegates to the shared media-type table so sniffer UI labels stay
    // in sync with publish MIME maps and auto-classify categories.
    return MediaFileTypes.containerFormatForExtension(ext);
  }

  void sniff(
    String url, {
    String? contentDisposition,
    String? contentType,
    String? sourcePageUrl,
    String? pageTitle,
    Map<String, String> headers = const {},
    SniffSource sniffSource = SniffSource.javascript,
    int? contentLength,
    String? thumbnailUrl,
  }) {
    // Play: URL/CDN/page backstop (site hard-off is enforced before sniff()).
    if (RestrictedMediaPolicy.isBlocked(
      mediaUrl: url,
      sourcePageUrl: sourcePageUrl,
      headers: headers,
    )) {
      return;
    }
    // Soft cap buffer: allow some extra items so they can be enriched and sorted
    // before we evict them.
    final bufferCap = maxDetectedMedia + 20;
    if (cache.detectedMedia.length >= bufferCap) {
      cache.evictToLimit();
      if (cache.detectedMedia.length >= bufferCap) {
        return; // still capped
      }
    }
    if (_isDisposed) return;
    url = url.trim();
    while (url.startsWith('"') || url.startsWith("'") || url.startsWith('`')) {
      url = url.substring(1);
    }
    while (url.endsWith('"') || url.endsWith("'") || url.endsWith('`')) {
      url = url.substring(0, url.length - 1);
    }
    url = url.trim();
    url = url.replaceAll(' ', '%20');

    if (url.isEmpty) return;

    final normalizedUrl = cache.normalizeUrl(url);

    // Drop HLS/DASH segment URLs before they consume the 50-item cap or get
    // mis-classified by content-type. Playlists (.m3u8/.mpd) and direct media
    // (.mp4/.webm/...) are not affected.
    if (_looksLikeSegment(normalizedUrl)) {
      return;
    }

    // Prevent duplicate items of the same URL from filling up the cache and evicting
    // other media (especially when maxDetectedMedia is small).
    final existingIndex = cache.detectedMedia.indexWhere(
      (m) => cache.normalizeUrl(m.url) == normalizedUrl,
    );
    if (existingIndex != -1) {
      final existing = cache.detectedMedia[existingIndex];
      var updated = existing;
      if (contentType != null && existing.contentType != contentType) {
        updated = updated.copyWith(contentType: contentType);
      }
      if (contentLength != null && existing.contentLengthBytes != contentLength) {
        updated = updated.copyWith(contentLengthBytes: contentLength);
      }
      // Backfill page title when a later sniff has one and the item does not.
      if (pageTitle != null &&
          pageTitle.trim().isNotEmpty &&
          (existing.pageTitle == null || existing.pageTitle!.trim().isEmpty)) {
        updated = updated.copyWith(pageTitle: pageTitle.trim());
      }
      // Same for the poster: the DOM scan that carries it usually lands after
      // the network capture that first created this item.
      if (thumbnailUrl != null &&
          thumbnailUrl.trim().isNotEmpty &&
          (existing.thumbnailUrl == null ||
              existing.thumbnailUrl!.trim().isEmpty)) {
        updated = updated.copyWith(thumbnailUrl: thumbnailUrl.trim());
      }
      if (contentType != null) {
        final ct = contentType.toLowerCase().split(';').first.trim();
        final isHls = ct == 'application/vnd.apple.mpegurl' ||
            ct == 'application/x-mpegurl' ||
            ct.contains('mpegurl');
        final isDash = ct == 'application/dash+xml';
        if ((isHls || isDash) &&
            existing.type != MediaType.video &&
            existing.type != MediaType.playlist) {
          final containerFormat = isDash ? 'mp4' : existing.containerFormat;
          updated = updated.copyWith(
            type: MediaType.video,
            containerFormat: containerFormat,
          );
          // Skip re-enrichment if this normalized URL was already enriched.
          // HLS/DASH reclassify is always a downloadable-priority type.
          if (!url.startsWith('blob:') &&
              !_enrichedUrls.contains(normalizedUrl)) {
            _enrichedUrls.add(normalizedUrl);
            enricher.enqueue(updated);
          }
        }
      }
      if (updated != existing) {
        cache.detectedMedia[existingIndex] = updated;
        cache.mediaChangedController.add(updated);
      }
      return;
    }

    if (!cache.registerUrl(normalizedUrl, dedupDuration)) {
      if (contentType != null) {
        _reclassifyIfNeeded(normalizedUrl, contentType);
      }
      return;
    }

    MediaType? type;
    if (url.startsWith('magnet:') || _torrentRegExp.hasMatch(url)) {
      type = MediaType.torrent;
    } else if (_videoRegExp.hasMatch(url)) {
      type = MediaType.video;
    } else if (_audioRegExp.hasMatch(url)) {
      type = MediaType.audio;
    } else if (_imageRegExp.hasMatch(url)) {
      type = MediaType.image;
    } else if (_subtitleRegExp.hasMatch(url)) {
      type = MediaType.subtitle;
    } else if (_documentRegExp.hasMatch(url)) {
      type = MediaType.document;
    } else if (_archiveRegExp.hasMatch(url)) {
      type = MediaType.archive;
    } else if (_executableRegExp.hasMatch(url)) {
      type = MediaType.executable;
    } else if (_streamRegExp.hasMatch(url)) {
      type = MediaType.playlist;
    }

    // HLS/DASH content-type override: when the server explicitly reports a
    // playlist content-type (e.g. application/vnd.apple.mpegurl), trust the
    // content-type over the URL extension.  Some CDNs serve HLS playlists
    // under non-.m3u8 extensions (e.g. .../index.jpg) to bypass detection.
    if (contentType != null && type != MediaType.video &&
        type != MediaType.playlist) {
      final ct = contentType.toLowerCase().split(';').first.trim();
      if (ct == 'application/vnd.apple.mpegurl' ||
          ct == 'application/x-mpegurl' ||
          ct.contains('mpegurl') ||
          ct == 'application/dash+xml') {
        type = MediaType.video;
      }
    }

    // Content-Type fallback for extensionless URLs
    if (type == null && contentType != null) {
      final ct = contentType.toLowerCase().split(';').first.trim();
      if (ct.startsWith('video/') ||
          ct == 'application/vnd.apple.mpegurl' ||
          ct == 'application/x-mpegurl' ||
          ct == 'application/dash+xml') {
        type = MediaType.video;
      } else if (ct.startsWith('audio/')) {
        type = MediaType.audio;
      } else if (ct.startsWith('image/') && ct != 'image/x-icon') {
        type = MediaType.image;
      } else if (ct == 'application/pdf' ||
          ct == 'application/epub+zip' ||
          ct == 'application/x-mobipocket-ebook') {
        type = MediaType.document;
      } else if (ct == 'application/zip' ||
          ct == 'application/x-rar-compressed' ||
          ct == 'application/x-7z-compressed' ||
          ct == 'application/gzip' ||
          ct == 'application/x-tar') {
        type = MediaType.archive;
      } else if (ct == 'application/x-bittorrent') {
        type = MediaType.torrent;
      } else if (ct == 'application/octet-stream') {
        // For octet-stream, try to detect from URL path hints
        final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
        if (path.contains('video') ||
            path.contains('media') ||
            path.contains('stream') ||
            path.contains('play')) {
          type = MediaType.video;
        }
      }
    }

    // Video-hosting-domain fallback: URLs from known video CDNs
    // (DoodStream, Streamtape, MixDrop, etc.) that don't have a standard
    // media extension. These are video pages/download links that the user
    // can open to reach the actual video.
    if (type == null && isVideoHostingUrl(url, extraHosts: _customVideoHosts)) {
      type = MediaType.video;
    }

    if (type != null) {
      if (disabledMediaTypes.contains(type)) {
        cache.suppressedMediaCount++;
        cache.suppressedReasons.update(
          'media type disabled',
          (v) => v + 1,
          ifAbsent: () => 1,
        );
        return;
      }

      String filename;
      if (contentDisposition != null) {
        final extracted = _parseContentDispositionFilename(contentDisposition);
        filename = extracted ?? cache.extractFilename(url);
      } else {
        filename = cache.extractFilename(url);
      }

      // Derive the container format from the URL path extension so the UI
      // can label the entry as MP4 / WebM / FLAC / etc. immediately. The
      // enricher may overwrite this later if byte-level probing disagrees
      // (e.g. a `.mp3` URL that actually returns an M4A stream).
      final parsedUri = Uri.tryParse(url);
      final ext = parsedUri != null
          ? _extensionFromPath(parsedUri.path)
          : null;
      final containerFormat = ext != null
          ? containerFormatForExtension(ext)
          : null;

      final item = SniffedMedia(
        url: url,
        name: filename,
        type: type,
        contentType: contentType,
        contentLengthBytes: contentLength,
        sourcePageUrl: sourcePageUrl,
        headers: headers,
        sniffSource: sniffSource,
        containerFormat: containerFormat,
        pageTitle: (pageTitle != null && pageTitle.trim().isNotEmpty)
            ? pageTitle.trim()
            : null,
        thumbnailUrl: (thumbnailUrl != null && thumbnailUrl.trim().isNotEmpty)
            ? thumbnailUrl.trim()
            : null,
      );
      cache.detectedMedia.add(item);
      _mediaDetectedController.add(item);
      cache.mediaChangedController.add(item);

      // G6: When a playlist (.m3u8/.mpd) is confirmed, remove any blob:
      // entries sharing the same source page — they're just a proxy for
      // the same stream and clutter the capture tray.  (If no playlist
      // exists, keep the blob entry — it's the only hint.)
      if ((type == MediaType.playlist || type == MediaType.video) &&
          sourcePageUrl != null &&
          sourcePageUrl.isNotEmpty) {
        cache.detectedMedia.removeWhere((m) =>
            m.url.startsWith('blob:') &&
            m.sourcePageUrl == sourcePageUrl);
      }

      // Eager-enrich only downloadable-priority types so thumbnail/doc
      // floods do not trigger HEAD/Range storms mid page-load. Images,
      // documents, archives, etc. stay listed in the capture UI.
      if (!url.startsWith('blob:') &&
          _shouldEagerEnrich(type) &&
          !_enrichedUrls.contains(normalizedUrl)) {
        _enrichedUrls.add(normalizedUrl);
        enricher.enqueue(item);
      } else if (enricher.enrichQueue.isEmpty &&
          enricher.activeEnrichCount == 0) {
        cache.evictToLimit();
      }
    }
  }

  /// Types that get HTTP enrichment probes during sniff.
  /// Non-priority types (image/document/archive/subtitle/executable) are
  /// still listed but skip eager HEAD/Range probes.
  static bool _shouldEagerEnrich(MediaType type) {
    return type == MediaType.video ||
        type == MediaType.audio ||
        type == MediaType.playlist ||
        type == MediaType.torrent;
  }

  /// When a URL was already registered with a wrong type (e.g. a disguised
  /// HLS playlist first classified as an image), update the existing item
  /// in-place if the new [contentType] indicates an HLS/DASH playlist.
  void _reclassifyIfNeeded(String url, String contentType) {
    final ct = contentType.toLowerCase().split(';').first.trim();
    final isHls = ct == 'application/vnd.apple.mpegurl' ||
        ct == 'application/x-mpegurl' ||
        ct.contains('mpegurl');
    final isDash = ct == 'application/dash+xml';
    if (!isHls && !isDash) return;

    final index = cache.detectedMedia.indexWhere((m) => m.url == url);
    if (index == -1) return;
    final existing = cache.detectedMedia[index];
    // Don't downgrade if already classified as video/playlist.
    if (existing.type == MediaType.video ||
        existing.type == MediaType.playlist) return;

    final containerFormat =
        isDash ? 'mp4' : existing.containerFormat;
    final updated = existing.copyWith(
      type: MediaType.video,
      contentType: contentType,
      containerFormat: containerFormat,
    );
    cache.detectedMedia[index] = updated;
    cache.mediaChangedController.add(updated);
    // Enqueue for HLS/DASH enrichment with the corrected type.
    // Skip if this URL was already enqueued for enrichment.
    if (!url.startsWith('blob:') && !_enrichedUrls.contains(url)) {
      _enrichedUrls.add(url);
      enricher.enqueue(updated);
    }
  }

  void suppress(String url, String reason) {
    if (url.trim().isEmpty) return;
    cache.suppressedMediaCount++;
    cache.suppressedReasons[reason] =
        (cache.suppressedReasons[reason] ?? 0) + 1;
  }

  String? _parseContentDispositionFilename(String contentDisposition) {
    try {
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

  void clearCache() {
    cache.clear();
    _enrichedUrls.clear();
  }

  /// Clears the per-engine and global dedup caches without removing any
  /// detected media items. Used by the manual rescan button so re-captured
  /// DOM-scan URLs are not silently dropped by the dedup check.
  void clearDedupOnly() {
    cache.clearDedupOnly();
  }

  /// Clears the global cross-tab dedup cache so the same URL can be
  /// re-detected across tabs. Call this when the user explicitly clears
  /// captured media.
  static void clearGlobalCache() {
    SniffedMediaCache.clearGlobal();
  }

  Future<void> saveDetectedMedia(String filePath) => cache.save(filePath);

  Future<bool> loadDetectedMedia(String filePath) => cache.load(filePath);

  /// Drop Play-restricted items already in the list (YouTube UI sounds, etc.).
  int purgeRestrictedMedia() => cache.purgeRestrictedMedia();

  // ---------------------------------------------------------------------------
  // MediaEnricherHost implementation — gives the enricher access to engine
  // state without exposing the cache and field setters.
  // ---------------------------------------------------------------------------

  // The fields `client`, `cookieProvider`, `fetchViaWebView`,
  // `fetchPlaylistBodyViaWebView`, `hlsPlaylistCache`, and the public
  // `detectedMedia` getter already satisfy the corresponding host
  // interface members — Dart synthesizes the getters automatically.

  @override
  void evictToLimit() => cache.evictToLimit();

  @override
  StreamController<SniffedMedia> get mediaChangedController =>
      cache.mediaChangedController;

  @override
  List<SniffedMedia> get mutableDetectedMedia => cache.detectedMedia;

  @override
  bool get isDisposedEngine => _isDisposed;

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _mediaDetectedController.close();
    cache.mediaChangedController.close();
    cache.dispose();
    client.close();
  }
}

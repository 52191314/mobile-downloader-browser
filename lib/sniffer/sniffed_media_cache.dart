import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'worker_isolate_pool.dart';

import 'package:flutter/foundation.dart';

import '../compliance/restricted_media_policy.dart';
import 'models/sniffed_media.dart';

/// Owns the persistent and in-memory caches of sniffed media for a single
/// [MediaSnifferEngine]. Encapsulates the dedup sets, eviction timers, the
/// "suppressed" counters, and the JSON on-disk save/load format.
///
/// The cross-tab global dedup set remains a static so that URL hits
/// detected by one tab suppress duplicates in all other tabs. The
/// per-engine set, list, and timers are instance state.
class SniffedMediaCache {
  late final List<SniffedMedia> detectedMedia;
  List<SniffedMedia>? _cachedUnmodifiable;
  final Set<String> urlCache = {};
  final Map<String, Timer> evictionTimers = {};

  /// Global cross-tab dedup cache. Static so that all
  /// [MediaSnifferEngine] instances share a single view of which URLs
  /// have already been captured in this session.
  static final Set<String> _globalUrlCache = {};

  /// Stream controller for media-list mutations (additions, enrichment
  /// updates, evictions). Backed by the engine's
  /// [MediaSnifferEngine.onMediaChanged] stream.
  final StreamController<SniffedMedia> mediaChangedController;

  int maxDetectedMedia;
  int suppressedMediaCount = 0;
  final Map<String, int> suppressedReasons = {};
  bool _isDisposed = false;

  SniffedMediaCache({
    required this.mediaChangedController,
    this.maxDetectedMedia = 200,
  }) {
    detectedMedia = MutationAwareList(() {
      _cachedUnmodifiable = null;
    });
  }

  // ---------------------------------------------------------------------------
  // Accessors
  // ---------------------------------------------------------------------------

  List<SniffedMedia> get unmodifiableDetectedMedia =>
      _cachedUnmodifiable ??= List.unmodifiable(detectedMedia);

  bool get capReached => detectedMedia.length >= maxDetectedMedia;

  bool get isDisposed => _isDisposed;

  // ---------------------------------------------------------------------------
  // URL utilities
  // ---------------------------------------------------------------------------

  static const _trackingParams = {
    'utm_source',
    'utm_medium',
    'utm_campaign',
    'utm_term',
    'utm_content',
    'fbclid',
    'gclid',
    'msclkid',
    'ref',
    'source',
    'si',
    'pi',
    '_hsenc',
    '_hsmi',
    'trk',
  };

  String normalizeUrl(String url) {
    if (url.startsWith('blob:')) return url;
    try {
      final uri = Uri.parse(url);
      final params = Map<String, List<String>>.from(uri.queryParametersAll);
      params.removeWhere((k, _) => _trackingParams.contains(k.toLowerCase()));
      return uri
          .replace(queryParameters: params.isEmpty ? null : params)
          .toString();
    } catch (_) {
      return url;
    }
  }

  String extractFilename(String url) {
    try {
      final uri = Uri.parse(url);
      final pathSegments = uri.pathSegments;
      if (pathSegments.isNotEmpty) {
        final lastSegment = pathSegments.last;
        if (lastSegment.isNotEmpty) {
          return Uri.decodeComponent(lastSegment);
        }
      }
    } catch (_) {}
    return 'downloaded_file';
  }

  // ---------------------------------------------------------------------------
  // Dedup registration
  // ---------------------------------------------------------------------------

  /// Register [normalizedUrl] as newly detected. If the URL is already in
  /// the per-engine or the global dedup cache, returns `false` and does
  /// nothing. Otherwise inserts it and schedules an eviction timer with
  /// [ttl]; the entry will be removed from both caches after the timer
  /// fires (unless the engine is disposed first).
  bool registerUrl(String normalizedUrl, Duration ttl) {
    if (urlCache.contains(normalizedUrl)) return false;
    if (_globalUrlCache.contains(normalizedUrl)) return false;
    urlCache.add(normalizedUrl);
    _globalUrlCache.add(normalizedUrl);

    evictionTimers[normalizedUrl]?.cancel();
    evictionTimers[normalizedUrl] = Timer(ttl, () {
      if (_isDisposed) return;
      urlCache.remove(normalizedUrl);
      _globalUrlCache.remove(normalizedUrl);
      evictionTimers.remove(normalizedUrl);
    });
    return true;
  }

  // ---------------------------------------------------------------------------
  // Eviction
  // ---------------------------------------------------------------------------

  int _compareForEviction(SniffedMedia a, SniffedMedia b) {
    if (a.isShortClip != b.isShortClip) {
      return a.isShortClip ? 1 : -1;
    }
    final aIsPlaylist = a.url.toLowerCase().contains('.m3u8');
    final bIsPlaylist = b.url.toLowerCase().contains('.m3u8');
    if (aIsPlaylist != bIsPlaylist) {
      return aIsPlaylist ? -1 : 1;
    }
    if (aIsPlaylist && bIsPlaylist) {
      // Both are playlists. Prefer newer playlists because HLS variant
      // playlists are added after the master playlist and must not be evicted
      // before/during enrichment.
      return b.sniffedAt.compareTo(a.sniffedAt);
    }
    final aSize = a.contentLengthBytes;
    final bSize = b.contentLengthBytes;
    if (aSize != null && bSize != null) {
      return bSize.compareTo(aSize);
    }
    const sizeThreshold = 5 * 1024 * 1024;
    if (aSize != null && bSize == null) {
      return aSize >= sizeThreshold ? -1 : 1;
    }
    if (aSize == null && bSize != null) {
      return bSize >= sizeThreshold ? 1 : -1;
    }
    return b.sniffedAt.compareTo(a.sniffedAt);
  }

  void evictToLimit() {
    if (detectedMedia.length <= maxDetectedMedia) return;
    final evictionSorted = [...detectedMedia];
    evictionSorted.sort(_compareForEviction);
    final toRemove = evictionSorted.sublist(maxDetectedMedia);
    for (final item in toRemove) {
      detectedMedia.remove(item);
      final norm = normalizeUrl(item.url);
      urlCache.remove(norm);
      _globalUrlCache.remove(norm);
    }
    if (!_isDisposed && detectedMedia.isNotEmpty) {
      mediaChangedController.add(detectedMedia.last);
    }
  }

  // ---------------------------------------------------------------------------
  // Clear
  // ---------------------------------------------------------------------------

  void clear() {
    final itemCount = detectedMedia.length;
    debugPrint(
      '[SniffedMediaCache] clear() — removing $itemCount items, '
      '${urlCache.length} dedup entries',
    );
    for (final timer in evictionTimers.values) {
      timer.cancel();
    }
    evictionTimers.clear();
    // Evict this engine's URLs from the global cross-tab dedup cache so the
    // same URLs can be re-detected after the user clears captured media.
    for (final url in urlCache) {
      _globalUrlCache.remove(url);
    }
    urlCache.clear();
    detectedMedia.clear();
    suppressedMediaCount = 0;
    suppressedReasons.clear();
    debugPrint('SniffedMediaCache cleared ($itemCount items removed)');
  }

  /// Clears the global cross-tab dedup cache so the same URL can be
  /// re-detected across tabs. Call this when the user explicitly clears
  /// captured media.
  static void clearGlobal() {
    _globalUrlCache.clear();
  }

  /// Clears the per-engine and global dedup caches without removing any
  /// detected media items. Used by the manual rescan button so re-captured
  /// DOM-scan URLs are not silently dropped by the dedup check while
  /// keeping the existing enriched items intact.
  void clearDedupOnly() {
    for (final timer in evictionTimers.values) {
      timer.cancel();
    }
    evictionTimers.clear();
    for (final url in urlCache) {
      _globalUrlCache.remove(url);
    }
    urlCache.clear();
  }

  // ---------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------

  Future<void> save(String filePath) async {
    try {
      final file = File(filePath);
      final items = detectedMedia
          .take(200)
          .map(
            (m) => {
              'url': m.url,
              'name': m.name,
              'type': m.type.name,
              'sniffedAt': m.sniffedAt.toIso8601String(),
              'contentLengthBytes': m.contentLengthBytes,
              'duration': m.duration?.inMilliseconds,
              'contentType': m.contentType,
              'sourcePageUrl': m.sourcePageUrl,
              'headers': sanitizeSniffedMediaHeaders(m.headers),
              'width': m.width,
              'height': m.height,
              'videoCodec': m.videoCodec,
              'audioCodec': m.audioCodec,
              'bandwidth': m.bandwidth,
              'pageTitle': m.pageTitle,
              'isShortClip': m.isShortClip,
              'isCacheRestored': m.isCacheRestored,
              'isStale': m.isStale,
              'thumbnailUrl': m.thumbnailUrl,
            },
          )
          .toList(growable: false);
      final jsonString = await WorkerIsolatePool.instance.execute(
        'jsonEncode',
        {'data': {'schemaVersion': 2, 'items': items}},
      ) as String;
      await file.writeAsString(jsonString);
    } catch (e) {
      debugPrint('[SniffedMediaCache] Failed to save media cache: $e');
    }
  }

  Future<bool> load(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return false;
      final raw = await file.readAsString();
      final decoded = await WorkerIsolatePool.instance.execute(
        'jsonDecode',
        {'json': raw},
      );
      final items = _cacheItemsFromDecoded(decoded);
      if (items == null) return false;
      var added = 0;
      for (final item in items) {
        final media = _mediaFromCacheItem(item);
        if (media == null) continue;
        // Play channel: drop persisted YouTube UI sounds / media that were
        // cached before the policy gate (e.g. m.youtube.com/.../success.mp3).
        if (RestrictedMediaPolicy.isBlocked(
          mediaUrl: media.url,
          sourcePageUrl: media.sourcePageUrl,
          headers: media.headers,
        )) {
          continue;
        }
        detectedMedia.add(media);
        // Repopulate the per-engine dedup cache so restored entries are
        // not duplicated on immediate re-sniff.  Skip the global cross-tab
        // cache (_globalUrlCache) — restored entries have no eviction timer
        // and would permanently block re-detection after a clear-and-reload
        // cycle (the per-engine urlCache IS cleared on clear()).
        final norm = normalizeUrl(media.url);
        urlCache.add(norm);
        // _globalUrlCache intentionally NOT populated here — see comment above.
        added++;
      }
      // Second pass if channel/policy changed since items were written.
      purgeRestrictedMedia();
      if (added > 0 && detectedMedia.isNotEmpty) {
        mediaChangedController.add(detectedMedia.last);
      }
      return detectedMedia.isNotEmpty;
    } catch (e) {
      debugPrint('[SniffedMediaCache] Failed to load media cache: $e');
      return false;
    }
  }

  /// Removes Play-restricted URLs already in memory (e.g. YouTube UI .mp3).
  int purgeRestrictedMedia() {
    if (!RestrictedMediaPolicy.enforcementEnabled) return 0;
    final before = detectedMedia.length;
    detectedMedia.removeWhere((media) {
      final blocked = RestrictedMediaPolicy.isBlocked(
        mediaUrl: media.url,
        sourcePageUrl: media.sourcePageUrl,
        headers: media.headers,
      );
      if (blocked) {
        final norm = normalizeUrl(media.url);
        urlCache.remove(norm);
        _globalUrlCache.remove(norm);
      }
      return blocked;
    });
    final removed = before - detectedMedia.length;
    if (removed > 0 && detectedMedia.isNotEmpty) {
      mediaChangedController.add(detectedMedia.last);
    }
    return removed;
  }

  List<dynamic>? _cacheItemsFromDecoded(Object? decoded) {
    if (decoded is List) return decoded;
    if (decoded is Map) {
      final items = decoded['items'];
      if (items is List) return items;
    }
    return null;
  }

  SniffedMedia? _mediaFromCacheItem(Object? rawItem) {
    try {
      if (rawItem is! Map) return null;
      final url = _stringFrom(rawItem['url']);
      if (url == null || url.trim().isEmpty) return null;
      final typeName = _stringFrom(rawItem['type']);
      if (typeName == null) return null;
      final type = _mediaTypeFromName(typeName);
      if (type == null) return null;

      final durationMs = _intFrom(rawItem['duration']);
      return SniffedMedia(
        url: url,
        name: _stringFrom(rawItem['name']) ?? extractFilename(url),
        type: type,
        sniffedAt:
            DateTime.tryParse(_stringFrom(rawItem['sniffedAt']) ?? '') ??
            DateTime.now(),
        contentLengthBytes: _intFrom(rawItem['contentLengthBytes']),
        duration: durationMs != null
            ? Duration(milliseconds: durationMs)
            : null,
        contentType: _stringFrom(rawItem['contentType']),
        sourcePageUrl: _stringFrom(rawItem['sourcePageUrl']),
        headers: _headersFromCacheItem(rawItem['headers']),
        width: _intFrom(rawItem['width']),
        height: _intFrom(rawItem['height']),
        videoCodec: _stringFrom(rawItem['videoCodec']),
        audioCodec: _stringFrom(rawItem['audioCodec']),
        bandwidth: _intFrom(rawItem['bandwidth']),
        pageTitle: _stringFrom(rawItem['pageTitle']),
        thumbnailUrl: _stringFrom(rawItem['thumbnailUrl']),
        isShortClip: rawItem['isShortClip'] as bool? ?? false,
        sniffSource: SniffSource.session,
        isCacheRestored: true,
        isStale: true,
      );
    } catch (_) {
      return null;
    }
  }

  MediaType? _mediaTypeFromName(String typeName) {
    for (final type in MediaType.values) {
      if (type.name == typeName) return type;
    }
    return null;
  }

  Map<String, String> _headersFromCacheItem(Object? rawHeaders) {
    if (rawHeaders is! Map) return const {};
    final headers = <String, String>{};
    rawHeaders.forEach((key, value) {
      if (key is String && value is String) {
        headers[key] = value;
      }
    });
    return sanitizeSniffedMediaHeaders(headers);
  }

  String? _stringFrom(Object? value) => value is String ? value : null;

  int? _intFrom(Object? value) {
    if (value is int) return value;
    if (value is num && value.isFinite) return value.round();
    if (value is String) return int.tryParse(value);
    return null;
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    for (final timer in evictionTimers.values) {
      timer.cancel();
    }
    evictionTimers.clear();
  }
}

class MutationAwareList<E> extends ListBase<E> {
  final List<E> _inner = [];
  final VoidCallback onMutated;

  MutationAwareList(this.onMutated);

  @override
  int get length => _inner.length;

  @override
  set length(int newLength) {
    _inner.length = newLength;
    onMutated();
  }

  @override
  E operator [](int index) => _inner[index];

  @override
  void operator []=(int index, E value) {
    _inner[index] = value;
    onMutated();
  }

  @override
  void add(E element) {
    _inner.add(element);
    onMutated();
  }

  @override
  void addAll(Iterable<E> iterable) {
    _inner.addAll(iterable);
    onMutated();
  }

  @override
  bool remove(Object? element) {
    final res = _inner.remove(element);
    if (res) onMutated();
    return res;
  }

  @override
  void clear() {
    _inner.clear();
    onMutated();
  }
}

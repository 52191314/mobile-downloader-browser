import 'media_sniffer_engine.dart';
import 'models/sniffed_media.dart';

class CaptureCandidate {
  final SniffedMedia media;
  final String groupKey;
  final String? qualityLabel;
  final double confidence;
  final String? hiddenReason;
  final bool isRecommended;

  const CaptureCandidate({
    required this.media,
    required this.groupKey,
    required this.confidence,
    this.qualityLabel,
    this.hiddenReason,
    this.isRecommended = false,
  });

  bool get isHidden => hiddenReason != null;

  CaptureCandidate copyWith({bool? isRecommended}) {
    return CaptureCandidate(
      media: media,
      groupKey: groupKey,
      confidence: confidence,
      qualityLabel: qualityLabel,
      hiddenReason: hiddenReason,
      isRecommended: isRecommended ?? this.isRecommended,
    );
  }
}

class CaptureGroup {
  final String groupKey;
  final List<CaptureCandidate> candidates;

  const CaptureGroup({required this.groupKey, required this.candidates});

  CaptureCandidate get primary => candidates.first;
  int get variantCount => candidates.length;
  bool get isRecommended =>
      candidates.any((candidate) => candidate.isRecommended);
  bool get isHidden => candidates.every((candidate) => candidate.isHidden);
}

class MediaCaptureResult {
  final List<CaptureGroup> groups;
  final int hiddenCount;
  final int totalCount;

  const MediaCaptureResult({
    required this.groups,
    required this.hiddenCount,
    required this.totalCount,
  });
}

class MediaCaptureAnalyzer {
  const MediaCaptureAnalyzer();

  MediaCaptureResult analyze(
    List<SniffedMedia> media, {
    required bool showAll,
    int minMediaSizeKb = 0,
    int minMediaDurationSeconds = 0,
  }) {
    final candidates = media
        .map((m) => _candidateFor(m, minMediaSizeKb, minMediaDurationSeconds))
        .toList(growable: false);
    final recommended = _recommendedGroupKey(candidates);
    final marked = candidates
        .map(
          (candidate) => candidate.copyWith(
            isRecommended: candidate.groupKey == recommended,
          ),
        )
        .toList(growable: false);

    final grouped = <String, List<CaptureCandidate>>{};
    for (final candidate in marked) {
      if (!showAll && candidate.isHidden) continue;
      grouped.putIfAbsent(candidate.groupKey, () => []).add(candidate);
    }

    final groups = grouped.entries.map((entry) {
      final items = [...entry.value]..sort(_compareCandidates);
      return CaptureGroup(groupKey: entry.key, candidates: items);
    }).toList()..sort((a, b) => _compareCandidates(a.primary, b.primary));

    return MediaCaptureResult(
      groups: groups,
      hiddenCount: candidates.where((candidate) => candidate.isHidden).length,
      totalCount: candidates.length,
    );
  }

  CaptureCandidate _candidateFor(
    SniffedMedia media,
    int minMediaSizeKb,
    int minMediaDurationSeconds,
  ) {
    final uri = Uri.tryParse(media.url);
    final qualityLabel = _qualityLabel(media, uri);
    final hiddenReason = _hiddenReason(
      media,
      uri,
      minMediaSizeKb: minMediaSizeKb,
      minMediaDurationSeconds: minMediaDurationSeconds,
    );
    final confidence = _confidence(media, hiddenReason);
    return CaptureCandidate(
      media: media,
      groupKey: _groupKey(media, uri),
      qualityLabel: qualityLabel,
      hiddenReason: hiddenReason,
      confidence: confidence,
    );
  }

  String? _recommendedGroupKey(List<CaptureCandidate> candidates) {
    final visible = candidates
        .where((candidate) => !candidate.isHidden)
        .toList(growable: false);
    if (visible.isEmpty) return null;
    final sorted = [...visible]..sort(_compareCandidates);
    return sorted.first.groupKey;
  }

  static int _compareCandidates(CaptureCandidate a, CaptureCandidate b) {
    final byConfidence = b.confidence.compareTo(a.confidence);
    if (byConfidence != 0) return byConfidence;
    final bySize = (b.media.contentLengthBytes ?? -1).compareTo(
      a.media.contentLengthBytes ?? -1,
    );
    if (bySize != 0) return bySize;
    final byDuration = (b.media.duration?.inMilliseconds ?? -1).compareTo(
      a.media.duration?.inMilliseconds ?? -1,
    );
    if (byDuration != 0) return byDuration;
    return b.media.sniffedAt.compareTo(a.media.sniffedAt);
  }

  String _groupKey(SniffedMedia media, Uri? uri) {
    if (uri == null) return '${media.type.name}:${media.url}';
    return '${media.type.name}:${_normalizedUri(uri)}';
  }

  String _normalizedUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri == null ? url : _normalizedUri(uri);
  }

  String _normalizedUri(Uri uri) {
    final ignored = {
      'fbclid',
      'gclid',
      'igshid',
      'mc_cid',
      'mc_eid',
      'utm_campaign',
      'utm_content',
      'utm_medium',
      'utm_source',
      'utm_term',
    };
    final query = Map<String, String>.from(uri.queryParameters)
      ..removeWhere((key, _) => ignored.contains(key.toLowerCase()));
    return Uri(
      scheme: uri.scheme,
      userInfo: uri.userInfo,
      host: uri.host,
      port: uri.hasPort ? uri.port : 0,
      path: uri.path,
      queryParameters: query.isEmpty ? null : query,
      fragment: uri.fragment.isEmpty ? null : uri.fragment,
    ).toString();
  }

  String? _qualityLabel(SniffedMedia media, Uri? uri) {
    final name = media.name.toLowerCase();
    final url = media.url.toLowerCase();
    final resolution = RegExp(
      r'(?<!\d)(2160|1440|1080|720|540|480|360)p(?!\d)',
    ).firstMatch('$name $url')?.group(1);
    if (resolution != null) return '${resolution}p';
    if (_isHls(media, uri)) return 'HLS';
    if (media.contentType != null && media.contentType!.isNotEmpty) {
      return media.contentType!.split(';').first.trim();
    }
    return null;
  }

  String? _hiddenReason(
    SniffedMedia media,
    Uri? uri, {
    int minMediaSizeKb = 0,
    int minMediaDurationSeconds = 0,
  }) {
    final path = (uri?.path ?? media.url).toLowerCase();
    final name = media.name.toLowerCase();

    // User-configurable size filter (skip for images, which already have
    // their own tiny-image rule).
    if (minMediaSizeKb > 0 && media.type != MediaType.image) {
      final size = media.contentLengthBytes;
      if (size != null && size < minMediaSizeKb * 1024) {
        return 'below size threshold';
      }
    }

    // User-configurable duration filter.
    if (minMediaDurationSeconds > 0) {
      final duration = media.duration;
      if (duration != null && duration.inSeconds < minMediaDurationSeconds) {
        return 'below duration threshold';
      }
    }

    if (media.type == MediaType.image) {
      if (path.endsWith('.ico') || path.endsWith('.svg')) return 'site asset';
      if (_looksLikeAssetName(name)) return 'site asset';
      final size = media.contentLengthBytes;
      if (size != null && size < 64 * 1024) {
        // Don't hide images that look like disguised playlists
        // (e.g. /hls/.../index.jpg). These are usually 1-5KB HLS
        // playlists, not real images. The MediaEnricher's body-content
        // check will reclassify them to MediaType.video shortly.
        if (path.contains('/hls/') ||
            path.contains('/master') ||
            path.contains('/playlist') ||
            path.contains('/manifest') ||
            path.contains('/dash/')) {
          // Keep visible — the enricher will reclassify within seconds.
        } else {
          return 'tiny image';
        }
      }
    }
    if (media.type == MediaType.video && path.endsWith('.ts')) {
      final size = media.contentLengthBytes;
      if (size == null || size < 2 * 1024 * 1024 || _looksLikeSegment(name)) {
        return 'HLS segment';
      }
    }
    if (_looksLikeTracker(path)) return 'tracking media';
    return null;
  }

  double _confidence(SniffedMedia media, String? hiddenReason) {
    if (hiddenReason != null) return 5;
    final sizeBoost = media.contentLengthBytes == null
        ? 0
        : (media.contentLengthBytes! / (1024 * 1024)).clamp(0, 20).toDouble();
    final durationBoost = media.duration == null
        ? 0
        : (media.duration!.inSeconds / 60).clamp(0, 15).toDouble();
    final base = switch (media.type) {
      MediaType.video => media.url.toLowerCase().contains('.m3u8') ? 92 : 82,
      MediaType.torrent => 90,
      MediaType.archive => 72,
      MediaType.audio => 68,
      MediaType.document => 56,
      MediaType.image => 24,
      MediaType.subtitle => 40,
      MediaType.executable => 50,
      MediaType.playlist => 80,
    };
    return (base + sizeBoost + durationBoost).toDouble();
  }

  bool _isHls(SniffedMedia media, Uri? uri) {
    if (media.type != MediaType.video && media.type != MediaType.playlist) {
      return false;
    }
    final path = uri?.path.toLowerCase() ?? '';
    if (path.endsWith('.m3u8')) return true;
    if (media.contentType?.toLowerCase().contains('mpegurl') == true) {
      return true;
    }
    // Path hints for disguised playlists (e.g. index.jpg under /hls/).
    if (path.contains('/hls/') ||
        path.contains('/master') ||
        path.contains('/playlist') ||
        path.contains('/manifest') ||
        path.contains('/dash/')) {
      return true;
    }
    return false;
  }

  bool _looksLikeAssetName(String name) {
    return RegExp(
      r'(sprite|icon|logo|avatar|thumb|thumbnail|placeholder|badge)',
    ).hasMatch(name);
  }

  bool _looksLikeSegment(String name) {
    return RegExp(
      r'(^|[-_])(seg|segment|chunk|frag|part)[-_]?\d+',
    ).hasMatch(name);
  }

  bool _looksLikeTracker(String path) {
    return RegExp(
      r'(pixel|beacon|analytics|tracking|collect|1x1)',
    ).hasMatch(path);
  }
}

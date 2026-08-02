enum MediaType {
  video,
  audio,
  image,
  document,
  archive,
  torrent,
  subtitle,
  executable,
  playlist,
}

enum SniffSource { navigation, javascript, resource, download, manual, session }

const _sensitiveSniffedHeaderNames = {'cookie', 'authorization'};

bool isSensitiveSniffedHeader(String name) {
  return _sensitiveSniffedHeaderNames.contains(name.toLowerCase());
}

Map<String, String> sanitizeSniffedMediaHeaders(Map<String, String> headers) {
  return Map<String, String>.fromEntries(
    headers.entries.where((entry) => !isSensitiveSniffedHeader(entry.key)),
  );
}

class SniffedMedia {
  final String url;
  final String name;
  final MediaType type;
  final DateTime sniffedAt;
  final int? contentLengthBytes;
  final Duration? duration;
  final String? contentType;
  final String? sourcePageUrl;
  final Map<String, String> headers;
  final SniffSource sniffSource;
  final String? suppressedReason;
  final int? width;
  final int? height;
  final String? videoCodec;
  final String? audioCodec;
  final int? bandwidth;
  final double? frameRate;
  final int? sampleRate;
  final int? channels;
  final bool? isLive;
  final String? containerFormat;
  final String? pageTitle;
  final bool isShortClip;
  final bool isCacheRestored;
  final bool isStale;
  final bool isSizeEstimated;

  /// When this item is a variant of an HLS master playlist, the URL of the
  /// master that produced it. Set by [MediaEnricher] during variant expansion.
  /// Used by [MediaCaptureAnalyzer] to hide bare master cards once their
  /// variants exist. Null for non-variant items and for the master itself.
  final String? masterUrl;

  /// Poster image for *this element*, harvested from the page DOM — a
  /// `<video poster>` attribute or a nearby `<img>`. Purely cosmetic: the
  /// capture sheet renders it as the row thumbnail and falls back to a type
  /// icon when it is null or fails to load. Always an absolute `http`/`https`
  /// URL — the JS bridge rejects everything else before it reaches here.
  ///
  /// Deliberately excludes the page's `og:image`. That is page artwork, not
  /// this file's own frame, so it is applied at paint time and only on pages
  /// with a single playable capture — see `pagePosterFor` in the capture sheet.
  /// Folding it in here made every row of a gallery page show one identical
  /// image, which reads as a rendering fault rather than a thumbnail.
  final String? thumbnailUrl;

  SniffedMedia({
    required String url,
    required this.name,
    required this.type,
    DateTime? sniffedAt,
    this.contentLengthBytes,
    this.duration,
    this.contentType,
    this.sourcePageUrl,
    this.headers = const {},
    this.sniffSource = SniffSource.javascript,
    this.suppressedReason,
    this.width,
    this.height,
    this.videoCodec,
    this.audioCodec,
    this.bandwidth,
    this.frameRate,
    this.sampleRate,
    this.channels,
    this.isLive,
    this.containerFormat,
    this.pageTitle,
    this.isShortClip = false,
    this.isCacheRestored = false,
    this.isStale = false,
    this.isSizeEstimated = false,
    this.masterUrl,
    this.thumbnailUrl,
  }) : url = _cleanUrl(url),
       sniffedAt = sniffedAt ?? DateTime.now();

  static String _cleanUrl(String rawUrl) {
    var cleaned = rawUrl.trim();
    while (cleaned.startsWith('"') ||
        cleaned.startsWith("'") ||
        cleaned.startsWith('`')) {
      cleaned = cleaned.substring(1);
    }
    while (cleaned.endsWith('"') ||
        cleaned.endsWith("'") ||
        cleaned.endsWith('`')) {
      cleaned = cleaned.substring(0, cleaned.length - 1);
    }
    cleaned = cleaned.trim();
    cleaned = cleaned.replaceAll(' ', '%20');
    return cleaned;
  }

  SniffedMedia copyWith({
    String? url,
    String? name,
    MediaType? type,
    DateTime? sniffedAt,
    int? contentLengthBytes,
    Duration? duration,
    String? contentType,
    String? sourcePageUrl,
    Map<String, String>? headers,
    SniffSource? sniffSource,
    String? suppressedReason,
    int? width,
    int? height,
    String? videoCodec,
    String? audioCodec,
    int? bandwidth,
    double? frameRate,
    int? sampleRate,
    int? channels,
    bool? isLive,
    String? containerFormat,
    String? pageTitle,
    bool? isShortClip,
    bool? isCacheRestored,
    bool? isStale,
    bool? isSizeEstimated,
    String? masterUrl,
    String? thumbnailUrl,
  }) {
    return SniffedMedia(
      url: url ?? this.url,
      name: name ?? this.name,
      type: type ?? this.type,
      sniffedAt: sniffedAt ?? this.sniffedAt,
      contentLengthBytes: contentLengthBytes ?? this.contentLengthBytes,
      duration: duration ?? this.duration,
      contentType: contentType ?? this.contentType,
      sourcePageUrl: sourcePageUrl ?? this.sourcePageUrl,
      headers: headers ?? this.headers,
      sniffSource: sniffSource ?? this.sniffSource,
      suppressedReason: suppressedReason ?? this.suppressedReason,
      width: width ?? this.width,
      height: height ?? this.height,
      videoCodec: videoCodec ?? this.videoCodec,
      audioCodec: audioCodec ?? this.audioCodec,
      bandwidth: bandwidth ?? this.bandwidth,
      frameRate: frameRate ?? this.frameRate,
      sampleRate: sampleRate ?? this.sampleRate,
      channels: channels ?? this.channels,
      isLive: isLive ?? this.isLive,
      containerFormat: containerFormat ?? this.containerFormat,
      pageTitle: pageTitle ?? this.pageTitle,
      isShortClip: isShortClip ?? this.isShortClip,
      isCacheRestored: isCacheRestored ?? this.isCacheRestored,
      isStale: isStale ?? this.isStale,
      isSizeEstimated: isSizeEstimated ?? this.isSizeEstimated,
      masterUrl: masterUrl ?? this.masterUrl,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
    );
  }
}

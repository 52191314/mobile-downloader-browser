/// Lightweight DASH MPD (`.mpd`) manifest parser.
///
/// Mirrors the style of `HlsPlaylistParser`: `parse(body, manifestUri)`
/// returns a [DashPlaylist] containing the top-level [DashRepresentation]
/// entries (one per `<Representation>`) and the parsed media presentation
/// duration.
///
/// This parser only consumes the subset of the DASH schema that the
/// sniffer needs to display variant metadata and estimate total size:
///
///   * `Period` > `AdaptationSet` > `Representation`
///   * `bandwidth`, `width`, `height`, `codecs`, `frameRate`,
///     `audioSamplingRate` attributes on `<Representation>`
///   * `mimeType` / `contentType` on `<AdaptationSet>` to filter to
///     video or audio
///   * `mediaPresentationDuration` / `Period duration` to compute the
///     overall clip length
///   * First `<SegmentTemplate media=... initialization=...>` per
///     representation, for variant URL display purposes
///
/// Segment URL templating is intentionally not implemented — the sniffer
/// only needs to surface a clickable variant URL to the user, and the
/// downstream `DashDownloader` (when added) is responsible for actually
/// fetching segments.
class DashPlaylistParser {
  /// Parses the [body] of a DASH MPD manifest rooted at [manifestUri].
  /// Returns a [DashPlaylist] with zero representations if the body is
  /// not a recognizable MPD document.
  static DashPlaylist parse(String body, Uri manifestUri) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) {
      return DashPlaylist(
        uri: manifestUri,
        durationSeconds: 0,
        representations: const [],
        mpdType: null,
      );
    }

    final mpdType = _readAttr(trimmed, 'MPD', 'type');
    final mpdDuration = _readDurationSeconds(
      _readAttr(trimmed, 'MPD', 'mediaPresentationDuration'),
    );
    // Period can override or set duration; we take the larger of the two
    // since some manifests only declare duration at the Period level.
    final periodDuration = _readDurationSeconds(
      _firstAttr(trimmed, 'Period', 'duration'),
    );
    final durationSeconds = mpdDuration > periodDuration
        ? mpdDuration
        : periodDuration;

    final representations = <DashRepresentation>[];
    final adaptationSetRegex = RegExp(
      r'<AdaptationSet\b([^>]*?)>(.*?)</AdaptationSet>',
      caseSensitive: false,
      dotAll: true,
    );
    final representationRegex = RegExp(
      r'<Representation\b([^>]*?)>(.*?)</Representation>',
      caseSensitive: false,
      dotAll: true,
    );
    final selfClosingRepRegex = RegExp(
      r'<Representation\b([^>]*?)/>',
      caseSensitive: false,
    );

    for (final adaptMatch in adaptationSetRegex.allMatches(trimmed)) {
      final adaptAttrs = adaptMatch.group(1) ?? '';
      final adaptBody = adaptMatch.group(2) ?? '';
      final mimeType = _readAttributeString(adaptAttrs, 'mimeType');
      final contentType = _readAttributeString(adaptAttrs, 'contentType');
      final widthAs = _readAttributeInt(adaptAttrs, 'width');
      final heightAs = _readAttributeInt(adaptAttrs, 'height');
      final frameRateAs = _readAttributeDouble(adaptAttrs, 'frameRate');
      final codecsAs = _readAttributeString(adaptAttrs, 'codecs');
      final segmentTemplateAs = _firstSegmentTemplate(adaptBody);

      void addFromAttrs(String repAttrs, String repBody) {
        final rep = _buildRepresentation(
          repAttrs: repAttrs,
          repBody: repBody,
          mimeType: mimeType,
          contentType: contentType,
          widthAs: widthAs,
          heightAs: heightAs,
          frameRateAs: frameRateAs,
          codecsAs: codecsAs,
          segmentTemplateAs: segmentTemplateAs,
          manifestUri: manifestUri,
        );
        if (rep != null) representations.add(rep);
      }

      for (final repMatch
          in representationRegex.allMatches(adaptBody)) {
        addFromAttrs(repMatch.group(1) ?? '', repMatch.group(2) ?? '');
      }
      for (final repMatch in selfClosingRepRegex.allMatches(adaptBody)) {
        addFromAttrs(repMatch.group(1) ?? '', '');
      }
    }

    return DashPlaylist(
      uri: manifestUri,
      durationSeconds: durationSeconds,
      representations: representations,
      mpdType: mpdType,
    );
  }

  /// Parses an ISO-8601 duration string such as "PT1H23M45.678S",
  /// "PT45S", "PT2M10.5S", or "PT0H0M10S". Returns the duration in
  /// seconds as a double, or 0 when [value] is null/empty/malformed.
  static double _readDurationSeconds(String? value) {
    if (value == null) return 0;
    final trimmed = value.trim();
    if (!trimmed.startsWith('PT') && !trimmed.startsWith('P')) return 0;
    final hours = _firstNumber(RegExp(r'(\d+(?:\.\d+)?)H', caseSensitive: false)
        .firstMatch(trimmed));
    final minutes = _firstNumber(RegExp(
      r'(\d+(?:\.\d+)?)M',
      caseSensitive: false,
    ).firstMatch(trimmed));
    final seconds = _firstNumber(RegExp(
      r'(\d+(?:\.\d+)?)S',
      caseSensitive: false,
    ).firstMatch(trimmed));
    final total = hours * 3600 + minutes * 60 + seconds;
    return total.isFinite && total > 0 ? total : 0;
  }

  /// Builds a [DashRepresentation] from raw XML attribute strings, or
  /// returns null when the required `bandwidth` attribute is missing.
  static DashRepresentation? _buildRepresentation({
    required String repAttrs,
    required String repBody,
    required String? mimeType,
    required String? contentType,
    required int? widthAs,
    required int? heightAs,
    required double? frameRateAs,
    required String? codecsAs,
    required _SegmentTemplate? segmentTemplateAs,
    required Uri manifestUri,
  }) {
    final bandwidthStr = _readAttributeString(repAttrs, 'bandwidth');
    final bandwidth = int.tryParse(bandwidthStr ?? '');
    if (bandwidth == null || bandwidth <= 0) return null;

    final id = _readAttributeString(repAttrs, 'id') ?? '';
    final width = _readAttributeInt(repAttrs, 'width') ?? widthAs;
    final height = _readAttributeInt(repAttrs, 'height') ?? heightAs;
    final frameRate =
        _readAttributeDouble(repAttrs, 'frameRate') ?? frameRateAs;
    final codecs = _readAttributeString(repAttrs, 'codecs') ?? codecsAs;
    final audioSamplingRate =
        _readAttributeInt(repAttrs, 'audioSamplingRate');

    // Pick the first segment template inside the Representation, falling
    // back to the AdaptationSet-level template if the Representation
    // doesn't carry its own.
    final segTemplate =
        _firstSegmentTemplate(repBody) ?? segmentTemplateAs;
    final initUri = segTemplate?.initialization != null
        ? _resolveAgainstManifest(
            manifestUri,
            segTemplate!.initialization!,
            id,
          )
        : null;
    final mediaUri = segTemplate?.media != null
        ? _resolveAgainstManifest(
            manifestUri,
            segTemplate!.media!,
            id,
          )
        : null;

    final resolvedMime = (_readAttributeString(repAttrs, 'mimeType')) ??
        mimeType ??
        contentType;

    return DashRepresentation(
      id: id,
      bandwidth: bandwidth,
      width: width,
      height: height,
      frameRate: frameRate,
      codecs: codecs,
      mimeType: resolvedMime,
      audioSamplingRate: audioSamplingRate,
      mediaTemplate: mediaUri,
      initializationUri: initUri,
    );
  }

  /// Reads the value of [attr] on the first opening `<tag ...>` in
  /// [body], or null if not found.
  static String? _readAttr(String body, String tag, String attr) {
    final openTag = RegExp(
      '<$tag\\b([^>]*?)>',
      caseSensitive: false,
    ).firstMatch(body);
    if (openTag == null) return null;
    return _readAttributeString(openTag.group(1) ?? '', attr);
  }

  /// Reads the value of [attr] on the first `<tag ...>` (opening or
  /// self-closing) in [body], or null if not found.
  static String? _firstAttr(String body, String tag, String attr) {
    final openTag = RegExp(
      '<$tag\\b([^>]*?)/?>',
      caseSensitive: false,
    ).firstMatch(body);
    if (openTag == null) return null;
    return _readAttributeString(openTag.group(1) ?? '', attr);
  }

  /// Extracts the value of [attr] from a raw attribute string, returning
  /// null when the attribute is missing. Trims surrounding quotes. Uses a
  /// negative lookbehind to ensure the attribute name is not a prefix of
  /// a longer name (e.g. `width` should not match `minWidth`).
  static String? _readAttributeString(String attrs, String attr) {
    final re = RegExp(
      '(?<![A-Za-z0-9:_\\-])$attr\\s*=\\s*"([^"]*)"',
      caseSensitive: false,
    );
    final m = re.firstMatch(attrs);
    if (m != null) return m.group(1);
    final re2 = RegExp(
      "(?<![A-Za-z0-9:_\\-])$attr\\s*=\\s*'([^']*)'",
      caseSensitive: false,
    );
    final m2 = re2.firstMatch(attrs);
    return m2?.group(1);
  }

  /// Reads [attr] as an int, or null when missing or not parseable.
  static int? _readAttributeInt(String attrs, String attr) {
    return int.tryParse(_readAttributeString(attrs, attr) ?? '');
  }

  /// Reads [attr] as a double, supporting DASH's "30000/1001" style
  /// fractional frame-rate notation. Returns null when missing or
  /// unparseable.
  static double? _readAttributeDouble(String attrs, String attr) {
    final raw = _readAttributeString(attrs, attr);
    if (raw == null) return null;
    if (raw.contains('/')) {
      final parts = raw.split('/');
      if (parts.length == 2) {
        final num = double.tryParse(parts[0].trim());
        final den = double.tryParse(parts[1].trim());
        if (num != null && den != null && den != 0) return num / den;
      }
      return null;
    }
    return double.tryParse(raw);
  }

  /// Returns the parsed first [SegmentTemplate] inside [body], or null
  /// when none is present.
  static _SegmentTemplate? _firstSegmentTemplate(String body) {
    final m = RegExp(
      '<SegmentTemplate\\b([^>]*?)/?>',
      caseSensitive: false,
    ).firstMatch(body);
    if (m == null) return null;
    final attrs = m.group(1) ?? '';
    return _SegmentTemplate(
      media: _readAttributeString(attrs, 'media'),
      initialization: _readAttributeString(attrs, 'initialization'),
    );
  }

  /// Resolves a (possibly templated) relative URL against the manifest
  /// base URI. Replaces `$RepresentationID$`, `$Number$`, and `$Time$`
  /// placeholders (including format specifiers like `$Number%05d$`) with
  /// literal tokens so the URL is at least partially usable as a display
  /// label and for variant selection.
  static Uri _resolveAgainstManifest(
    Uri manifestUri,
    String value,
    String representationId,
  ) {
    var resolved = value
        .replaceAll('\$RepresentationID\$', representationId)
        .replaceAll(RegExp(r'\$Number(?:%(\d+)d)?\$'), '1')
        .replaceAll('\$Time\$', '1');
    final resolvedUri = Uri.tryParse(resolved);
    if (resolvedUri != null && resolvedUri.hasScheme) {
      return resolvedUri;
    }
    return manifestUri.resolve(resolved);
  }

  static double _firstNumber(RegExpMatch? match) {
    if (match == null) return 0;
    return double.tryParse(match.group(1) ?? '') ?? 0;
  }
}

/// A single DASH variant parsed from a `<Representation>` element.
class DashRepresentation {
  final String id;
  final int bandwidth;
  final int? width;
  final int? height;
  final double? frameRate;
  final String? codecs;
  final String? mimeType;
  final int? audioSamplingRate;
  final Uri? mediaTemplate;
  final Uri? initializationUri;

  const DashRepresentation({
    required this.id,
    required this.bandwidth,
    this.width,
    this.height,
    this.frameRate,
    this.codecs,
    this.mimeType,
    this.audioSamplingRate,
    this.mediaTemplate,
    this.initializationUri,
  });

  /// True when this representation carries image dimensions.
  bool get isVideo =>
      (width != null && width! > 0) ||
      (height != null && height! > 0) ||
      (mimeType?.toLowerCase().startsWith('video/') ?? false);

  /// True when this representation describes an audio track.
  bool get isAudio =>
      (audioSamplingRate != null && audioSamplingRate! > 0) ||
      (mimeType?.toLowerCase().startsWith('audio/') ?? false);

  String get displayLabel {
    if (width != null && width! > 0 && height != null && height! > 0) {
      return '${width}x$height';
    }
    if (bandwidth > 0) {
      if (bandwidth < 1000000) {
        return '${(bandwidth / 1000).toStringAsFixed(0)} Kbps';
      }
      return '${(bandwidth / 1000000).toStringAsFixed(1)} Mbps';
    }
    return 'Dash stream';
  }
}

/// A parsed DASH MPD manifest. Holds the list of representations and the
/// overall presentation duration in seconds.
class DashPlaylist {
  final Uri uri;
  final double durationSeconds;
  final List<DashRepresentation> representations;
  final String? mpdType;

  const DashPlaylist({
    required this.uri,
    required this.durationSeconds,
    required this.representations,
    this.mpdType,
  });

  bool get isLive => mpdType?.toLowerCase() == 'dynamic';

  /// True if there is more than one Representation, meaning the manifest
  /// is a multi-variant master manifest rather than a single-stream file.
  bool get isMultiVariant => representations.length > 1;

  /// Filters to video-only representations.
  List<DashRepresentation> get videoRepresentations =>
      representations.where((r) => r.isVideo).toList(growable: false);

  /// Filters to audio-only representations.
  List<DashRepresentation> get audioRepresentations =>
      representations.where((r) => r.isAudio).toList(growable: false);

  Duration get duration =>
      Duration(milliseconds: (durationSeconds * 1000).round());
}

/// Internal helper for the small subset of `<SegmentTemplate>` attributes
/// the sniffer cares about.
class _SegmentTemplate {
  final String? media;
  final String? initialization;
  const _SegmentTemplate({this.media, this.initialization});
}

import 'dart:typed_data';

class HlsSegment {
  final Uri uri;
  final double durationSeconds;
  final int? byteRangeLength;

  const HlsSegment({
    required this.uri,
    required this.durationSeconds,
    this.byteRangeLength,
  });
}

class HlsVariant {
  final Uri uri;
  final int bandwidth;
  final String? resolution;

  const HlsVariant({
    required this.uri,
    required this.bandwidth,
    this.resolution,
  });

  String get displayLabel {
    final parsed = resolution == null
        ? null
        : RegExp(r'^\d+x(\d+)$').firstMatch(resolution!);
    if (parsed != null) return '${parsed.group(1)}p';
    if (bandwidth > 0) {
      return '${(bandwidth / 1000000).toStringAsFixed(1)} Mbps';
    }
    return 'HLS variant';
  }
}

class HlsEncryptionKey {
  final String method;
  final Uri uri;
  final Uint8List? iv;

  const HlsEncryptionKey({required this.method, required this.uri, this.iv});

  bool get isAes128 => method.toUpperCase() == 'AES-128';
}

class HlsPlaylist {
  final Uri uri;
  final List<HlsVariant> variants;
  final List<HlsSegment> segments;
  final bool hasEncryption;
  final bool hasFmp4;
  final Uri? initSegmentUri;
  final HlsEncryptionKey? encryptionKey;
  final int mediaSequence;
  final bool isLive;

  const HlsPlaylist({
    required this.uri,
    required this.variants,
    required this.segments,
    required this.hasEncryption,
    required this.hasFmp4,
    this.initSegmentUri,
    this.encryptionKey,
    this.mediaSequence = 0,
    this.isLive = false,
  });

  bool get isMaster => variants.isNotEmpty;
  double get durationSeconds =>
      segments.fold<double>(0, (sum, segment) => sum + segment.durationSeconds);

  /// Exact sum of EXT-X-BYTERANGE lengths when every media segment has one.
  /// Does not include the init segment (probed separately).
  int? get totalByteRangeLength {
    if (segments.isEmpty) return null;
    int total = 0;
    for (final segment in segments) {
      if (segment.byteRangeLength == null) return null;
      total += segment.byteRangeLength!;
    }
    return total > 0 ? total : null;
  }

  /// True when every media segment carries an EXT-X-BYTERANGE length.
  bool get hasFullByteRanges => totalByteRangeLength != null;
}

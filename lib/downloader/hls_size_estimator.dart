import 'dart:math' as math;

import 'hls_models.dart';

/// One probed segment used for size estimation.
class HlsSizeSample {
  final int index;
  final int bytes;
  final double durationSeconds;

  const HlsSizeSample({
    required this.index,
    required this.bytes,
    required this.durationSeconds,
  });
}

/// Result of an HLS total-size estimate.
class HlsSizeEstimate {
  /// Estimated total file size in bytes, or null if unknown.
  final int? totalBytes;

  /// How the estimate was produced.
  final HlsSizeEstimateSource source;

  /// True when the value is approximate (sampled / bandwidth) rather than
  /// an exact byte-range sum.
  final bool isEstimated;

  /// Human-readable debug detail.
  final String detail;

  const HlsSizeEstimate({
    required this.totalBytes,
    required this.source,
    required this.isEstimated,
    this.detail = '',
  });

  static const HlsSizeEstimate unknown = HlsSizeEstimate(
    totalBytes: null,
    source: HlsSizeEstimateSource.unknown,
    isEstimated: true,
    detail: 'unknown',
  );
}

enum HlsSizeEstimateSource {
  /// Sum of EXT-X-BYTERANGE lengths (exact).
  byteRangeExact,

  /// Duration-weighted sample of real segment sizes.
  durationWeightedSample,

  /// Average segment size × count.
  segmentAverageSample,

  /// Master/media BANDWIDTH × playlist duration.
  bandwidthDuration,

  /// Refined mid-download from completed segments.
  progressiveRefine,

  unknown,
}

/// Shared HLS / m3u8 size estimation for the sniffer enricher and downloader.
///
/// Priority (best → fallback):
/// 1. Exact byte-range sum from the playlist
/// 2. Duration-weighted average from strategic segment samples
/// 3. Simple average segment size × count
/// 4. BANDWIDTH × duration
/// 5. Progressive refinement as real segments complete
class HlsSizeEstimator {
  HlsSizeEstimator._();

  /// Sanity cap per segment (bytes) — rejects absurd CDN Content-Lengths.
  static const int maxSegmentBytes = 150 * 1024 * 1024;

  /// Minimum segment size accepted as a real media chunk (not a stub/HTML).
  static const int minSegmentBytes = 256;

  /// Select up to [maxSamples] strategically placed indices across [count]
  /// segments (first, last, quartiles, evenly spaced).
  static List<int> selectSampleIndices(
    int count, {
    int maxSamples = 8,
  }) {
    if (count <= 0) return const [];
    if (count <= maxSamples) {
      return List<int>.generate(count, (i) => i);
    }

    final indices = <int>{
      0,
      count - 1,
      count ~/ 4,
      count ~/ 2,
      (count * 3) ~/ 4,
    };

    // Fill remaining slots evenly so long VODs still get mid coverage.
    final remaining = maxSamples - indices.length;
    if (remaining > 0) {
      final step = count / (remaining + 1);
      for (var i = 1; i <= remaining; i++) {
        indices.add((step * i).floor().clamp(0, count - 1));
      }
    }

    // Cap at maxSamples while keeping first/last.
    final sorted = indices.toList()..sort();
    if (sorted.length <= maxSamples) return sorted;

    final result = <int>{0, count - 1};
    final mid = sorted.where((i) => i != 0 && i != count - 1).toList();
    final need = maxSamples - result.length;
    if (need > 0 && mid.isNotEmpty) {
      final step = mid.length / need;
      for (var i = 0; i < need; i++) {
        result.add(mid[(step * i).floor().clamp(0, mid.length - 1)]);
      }
    }
    return result.toList()..sort();
  }

  /// Estimate total size from a parsed [playlist] and optional probed
  /// [samples]. When [samples] is empty, falls back to bandwidth×duration
  /// using [bandwidthBps] if provided.
  static HlsSizeEstimate estimate({
    required HlsPlaylist playlist,
    List<HlsSizeSample> samples = const [],
    int? bandwidthBps,
    int initSegmentBytes = 0,
  }) {
    if (playlist.isLive) {
      return const HlsSizeEstimate(
        totalBytes: null,
        source: HlsSizeEstimateSource.unknown,
        isEstimated: true,
        detail: 'live',
      );
    }

    final segs = playlist.segments;
    if (segs.isEmpty) return HlsSizeEstimate.unknown;

    // 1) Exact byte-range sum
    final br = playlist.totalByteRangeLength;
    if (br != null && br > 0) {
      final total = br + (initSegmentBytes > 0 ? initSegmentBytes : 0);
      return HlsSizeEstimate(
        totalBytes: total,
        source: HlsSizeEstimateSource.byteRangeExact,
        isEstimated: false,
        detail: 'byte-range sum=$br + init=$initSegmentBytes',
      );
    }

    final validSamples = samples
        .where((s) =>
            s.bytes >= minSegmentBytes && s.bytes <= maxSegmentBytes)
        .toList(growable: false);

    // 2) Duration-weighted sample
    final durationWeighted = _durationWeighted(validSamples, segs, initSegmentBytes);
    if (durationWeighted != null) return durationWeighted;

    // 3) Average size × count
    final avgSample = _averageSample(validSamples, segs.length, initSegmentBytes);
    if (avgSample != null) return avgSample;

    // 4) BANDWIDTH × duration
    final bw = bandwidthBps ?? 0;
    final dur = playlist.durationSeconds;
    if (bw > 0 && dur > 0) {
      final total =
          ((bw / 8.0) * dur).round() + (initSegmentBytes > 0 ? initSegmentBytes : 0);
      // Sanity: 100 bps – 100 Mbps average equivalent
      if (total > 0 && total < 50 * 1024 * 1024 * 1024) {
        return HlsSizeEstimate(
          totalBytes: total,
          source: HlsSizeEstimateSource.bandwidthDuration,
          isEstimated: true,
          detail: 'bandwidth=${bw}bps × ${dur.toStringAsFixed(1)}s',
        );
      }
    }

    return HlsSizeEstimate.unknown;
  }

  /// Refine a running estimate from **completed** segments only.
  ///
  /// IMPORTANT: Do NOT pass [DownloadTask.downloadedBytes] here. That value
  /// includes in-flight concurrent segment partials and would systematically
  /// inflate bytes/sec and remaining-size estimates mid-download.
  ///
  /// Prefer duration-weighted bytes/sec from completed sizes when durations
  /// are known; otherwise use average completed size × remaining count.
  static HlsSizeEstimate refine({
    required int completedSegmentCount,
    required int totalSegmentCount,
    double completedDurationSeconds = 0,
    double totalDurationSeconds = 0,
    int initSegmentBytes = 0,
    List<int> completedSegmentSizes = const [],
    /// Optional floor so the UI never shows total < already-written bytes.
    int downloadedBytesFloor = 0,
  }) {
    if (totalSegmentCount <= 0) return HlsSizeEstimate.unknown;

    final sizes = completedSegmentSizes
        .where((b) => b >= minSegmentBytes && b <= maxSegmentBytes)
        .toList();
    final counted = sizes.isNotEmpty ? sizes.length : completedSegmentCount;
    if (counted <= 0) return HlsSizeEstimate.unknown;

    final completedBytes = sizes.isNotEmpty
        ? sizes.reduce((a, b) => a + b)
        : 0;
    if (completedBytes <= 0 && sizes.isEmpty) {
      return HlsSizeEstimate.unknown;
    }

    final remainingCount =
        (totalSegmentCount - counted).clamp(0, totalSegmentCount);
    final baseCompleted = completedBytes + (initSegmentBytes > 0 ? initSegmentBytes : 0);

    // All media segments done — exact from completed sizes.
    if (remainingCount == 0 && baseCompleted > 0) {
      return HlsSizeEstimate(
        totalBytes: math.max(baseCompleted, downloadedBytesFloor),
        source: HlsSizeEstimateSource.progressiveRefine,
        isEstimated: false,
        detail: 'complete ($counted segs)',
      );
    }

    // Duration-weighted refine (VBR) — uses COMPLETED bytes only.
    if (completedBytes > 0 &&
        completedDurationSeconds > 0.5 &&
        totalDurationSeconds > completedDurationSeconds) {
      final bytesPerSec = completedBytes / completedDurationSeconds;
      final total =
          (bytesPerSec * totalDurationSeconds).round() +
          (initSegmentBytes > 0 ? initSegmentBytes : 0);
      return HlsSizeEstimate(
        totalBytes: math.max(total, math.max(baseCompleted, downloadedBytesFloor)),
        source: HlsSizeEstimateSource.progressiveRefine,
        isEstimated: true,
        detail:
            'refine bps=${bytesPerSec.toStringAsFixed(0)} × '
            '${totalDurationSeconds.toStringAsFixed(1)}s',
      );
    }

    // Count-based: avg(completed) × totalCount + init.
    if (completedBytes > 0) {
      final avg = completedBytes ~/ counted;
      final total =
          avg * totalSegmentCount + (initSegmentBytes > 0 ? initSegmentBytes : 0);
      return HlsSizeEstimate(
        totalBytes: math.max(total, math.max(baseCompleted, downloadedBytesFloor)),
        source: HlsSizeEstimateSource.progressiveRefine,
        isEstimated: true,
        detail: 'refine avg=$avg × $totalSegmentCount segs',
      );
    }

    return HlsSizeEstimate.unknown;
  }

  static HlsSizeEstimate? _durationWeighted(
    List<HlsSizeSample> samples,
    List<HlsSegment> segs,
    int initBytes,
  ) {
    if (samples.isEmpty) return null;

    double weightedBpsSum = 0;
    double weightSum = 0;
    for (final s in samples) {
      final d = s.durationSeconds > 0.05
          ? s.durationSeconds
          : (s.index >= 0 && s.index < segs.length
              ? segs[s.index].durationSeconds
              : 0.0);
      if (d > 0.05) {
        weightedBpsSum += s.bytes / d;
        weightSum += 1;
      }
    }
    if (weightSum < 1) return null;

    final avgBps = weightedBpsSum / weightSum;
    final totalDur = segs.fold<double>(0, (a, s) => a + s.durationSeconds);
    if (totalDur <= 0) return null;

    final total =
        (avgBps * totalDur).round() + (initBytes > 0 ? initBytes : 0);
    if (total <= 0) return null;

    return HlsSizeEstimate(
      totalBytes: total,
      source: HlsSizeEstimateSource.durationWeightedSample,
      isEstimated: true,
      detail:
          'duration-weighted ${samples.length} samples, '
          '${avgBps.toStringAsFixed(0)} B/s × ${totalDur.toStringAsFixed(1)}s',
    );
  }

  static HlsSizeEstimate? _averageSample(
    List<HlsSizeSample> samples,
    int segmentCount,
    int initBytes,
  ) {
    if (samples.isEmpty || segmentCount <= 0) return null;
    final avg =
        samples.map((s) => s.bytes).reduce((a, b) => a + b) ~/ samples.length;
    final total = avg * segmentCount + (initBytes > 0 ? initBytes : 0);
    if (total <= 0) return null;
    return HlsSizeEstimate(
      totalBytes: total,
      source: HlsSizeEstimateSource.segmentAverageSample,
      isEstimated: true,
      detail: 'avg=$avg × $segmentCount segs',
    );
  }
}

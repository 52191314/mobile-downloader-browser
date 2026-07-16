import 'package:flutter_test/flutter_test.dart';

import 'package:aurora_downloader/downloader/hls_models.dart';
import 'package:aurora_downloader/downloader/hls_size_estimator.dart';

void main() {
  group('HlsSizeEstimator.selectSampleIndices', () {
    test('returns all indices when count is small', () {
      expect(HlsSizeEstimator.selectSampleIndices(3), [0, 1, 2]);
    });

    test('always includes first and last for large playlists', () {
      final idx = HlsSizeEstimator.selectSampleIndices(100, maxSamples: 8);
      expect(idx.first, 0);
      expect(idx.last, 99);
      expect(idx.length, lessThanOrEqualTo(8));
      expect(idx.toSet().length, idx.length); // unique
    });
  });

  group('HlsSizeEstimator.estimate', () {
    HlsPlaylist mediaPlaylist({
      required List<HlsSegment> segments,
      bool isLive = false,
    }) {
      return HlsPlaylist(
        uri: Uri.parse('https://cdn.example.com/index.m3u8'),
        variants: const [],
        segments: segments,
        hasEncryption: false,
        hasFmp4: false,
        isLive: isLive,
      );
    }

    test('byte-range sum is exact', () {
      final playlist = mediaPlaylist(segments: [
        HlsSegment(
          uri: Uri.parse('https://cdn.example.com/a.ts'),
          durationSeconds: 4,
          byteRangeLength: 1000,
        ),
        HlsSegment(
          uri: Uri.parse('https://cdn.example.com/b.ts'),
          durationSeconds: 4,
          byteRangeLength: 2000,
        ),
      ]);
      final est = HlsSizeEstimator.estimate(
        playlist: playlist,
        initSegmentBytes: 100,
      );
      expect(est.totalBytes, 3100);
      expect(est.isEstimated, isFalse);
      expect(est.source, HlsSizeEstimateSource.byteRangeExact);
    });

    test('duration-weighted sample beats simple average for VBR', () {
      final playlist = mediaPlaylist(segments: [
        for (var i = 0; i < 10; i++)
          HlsSegment(
            uri: Uri.parse('https://cdn.example.com/seg$i.ts'),
            durationSeconds: i < 5 ? 2.0 : 10.0,
          ),
      ]);
      // Early short segments are small; later long segments are large.
      final samples = [
        const HlsSizeSample(index: 0, bytes: 200000, durationSeconds: 2),
        const HlsSizeSample(index: 9, bytes: 1000000, durationSeconds: 10),
      ];
      final est = HlsSizeEstimator.estimate(
        playlist: playlist,
        samples: samples,
      );
      expect(est.totalBytes, isNotNull);
      expect(est.isEstimated, isTrue);
      expect(est.source, HlsSizeEstimateSource.durationWeightedSample);
      // Duration-weighted: avg ~100KB/s × (5*2 + 5*10)=60s ≈ 6MB
      expect(est.totalBytes!, greaterThan(4 * 1024 * 1024));
      expect(est.totalBytes!, lessThan(8 * 1024 * 1024));
    });

    test('bandwidth×duration fallback when no samples', () {
      final playlist = mediaPlaylist(segments: [
        HlsSegment(
          uri: Uri.parse('https://cdn.example.com/a.ts'),
          durationSeconds: 10,
        ),
        HlsSegment(
          uri: Uri.parse('https://cdn.example.com/b.ts'),
          durationSeconds: 10,
        ),
      ]);
      final est = HlsSizeEstimator.estimate(
        playlist: playlist,
        bandwidthBps: 8 * 1000 * 1000, // 8 Mbps
      );
      // 8e6/8 * 20s = 20_000_000
      expect(est.totalBytes, 20000000);
      expect(est.source, HlsSizeEstimateSource.bandwidthDuration);
      expect(est.isEstimated, isTrue);
    });

    test('live playlists return unknown', () {
      final playlist = mediaPlaylist(
        segments: [
          HlsSegment(
            uri: Uri.parse('https://cdn.example.com/a.ts'),
            durationSeconds: 6,
          ),
        ],
        isLive: true,
      );
      final est = HlsSizeEstimator.estimate(playlist: playlist);
      expect(est.totalBytes, isNull);
      expect(est.detail, 'live');
    });
  });

  group('HlsSizeEstimator.refine', () {
    test('refines from completed sizes only (not in-flight downloadedBytes)', () {
      final refined = HlsSizeEstimator.refine(
        completedSegmentCount: 3,
        totalSegmentCount: 10,
        completedSegmentSizes: [500000, 500000, 500000],
        // Floor is only a minimum; formula uses completed sizes alone.
        downloadedBytesFloor: 0,
      );
      // avg 500KB × 10 segs = 5MB
      expect(refined.totalBytes, 10 * 500000);
      expect(refined.source, HlsSizeEstimateSource.progressiveRefine);
    });

    test('duration-weighted refine preferred when durations known', () {
      final refined = HlsSizeEstimator.refine(
        completedSegmentCount: 2,
        totalSegmentCount: 10,
        completedDurationSeconds: 10,
        totalDurationSeconds: 50,
        completedSegmentSizes: [1000000, 1000000],
      );
      // 2MB / 10s = 200KB/s × 50s = 10MB
      expect(refined.totalBytes, 10000000);
    });

    test('ignores downloadedBytes partials for average', () {
      // 2 completed × 1MB, but "downloaded" claims 20MB of in-flight junk
      final refined = HlsSizeEstimator.refine(
        completedSegmentCount: 2,
        totalSegmentCount: 10,
        completedSegmentSizes: [1000000, 1000000],
        downloadedBytesFloor: 20 * 1000000,
      );
      // Formula from completed: avg 1MB × 10 = 10MB, floor raises to 20MB
      expect(refined.totalBytes, 20 * 1000000);
    });
  });
}

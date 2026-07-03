import 'package:flutter_test/flutter_test.dart';

import 'package:aurora_downloader/sniffer/media_capture_analyzer.dart';
import 'package:aurora_downloader/sniffer/media_sniffer_engine.dart';
import 'package:aurora_downloader/sniffer/models/sniffed_media.dart';

void main() {
  group('MediaCaptureAnalyzer', () {
    const analyzer = MediaCaptureAnalyzer();

    test(
      'hides tiny noisy assets by default and restores them with showAll',
      () {
        final media = [
          SniffedMedia(
            url: 'https://cdn.example.com/favicon.ico',
            name: 'favicon.ico',
            type: MediaType.image,
            contentLengthBytes: 2048,
          ),
          SniffedMedia(
            url: 'https://cdn.example.com/movie.m3u8',
            name: 'movie.m3u8',
            type: MediaType.video,
          ),
        ];

        final likely = analyzer.analyze(media, showAll: false);
        expect(likely.groups.length, 1);
        expect(likely.groups.single.primary.media.name, 'movie.m3u8');
        expect(likely.hiddenCount, 1);

        final all = analyzer.analyze(media, showAll: true);
        expect(all.groups.length, 2);
        expect(
          all.groups.any((group) => group.primary.media.name == 'favicon.ico'),
          isTrue,
        );
      },
    );

    test('groups duplicate URLs after removing tracking params', () {
      final media = [
        SniffedMedia(
          url: 'https://cdn.example.com/video.mp4?utm_source=a',
          name: 'video.mp4',
          type: MediaType.video,
        ),
        SniffedMedia(
          url: 'https://cdn.example.com/video.mp4?utm_source=b',
          name: 'video-copy.mp4',
          type: MediaType.video,
        ),
      ];

      final result = analyzer.analyze(media, showAll: true);
      expect(result.groups.length, 1);
      expect(result.groups.single.variantCount, 2);
    });

    test('does not group HLS variants from the same source page', () {
      final media = [
        SniffedMedia(
          url: 'https://cdn.example.com/master.m3u8',
          name: 'master.m3u8',
          type: MediaType.video,
          sourcePageUrl: 'https://site.example/watch/123',
        ),
        SniffedMedia(
          url: 'https://cdn.example.com/720/index.m3u8',
          name: '720p.m3u8',
          type: MediaType.video,
          sourcePageUrl: 'https://site.example/watch/123',
        ),
      ];

      final result = analyzer.analyze(media, showAll: true);
      expect(result.groups.length, 2);
      expect(result.groups[0].variantCount, 1);
      expect(result.groups[1].variantCount, 1);
    });

    test('recommends likely main media over noisy media', () {
      final media = [
        SniffedMedia(
          url: 'https://cdn.example.com/logo.png',
          name: 'logo.png',
          type: MediaType.image,
          contentLengthBytes: 4096,
        ),
        SniffedMedia(
          url: 'https://cdn.example.com/video-1080p.mp4',
          name: 'video-1080p.mp4',
          type: MediaType.video,
          contentLengthBytes: 200 * 1024 * 1024,
          duration: const Duration(minutes: 42),
        ),
      ];

      final result = analyzer.analyze(media, showAll: false);
      expect(result.groups.single.isRecommended, isTrue);
      expect(result.groups.single.primary.qualityLabel, '1080p');
    });
  });
}

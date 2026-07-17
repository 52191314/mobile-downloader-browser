import 'package:flutter_test/flutter_test.dart';

import 'package:aurora_downloader/sniffer/controllers/media_catch_controller.dart';
import 'package:aurora_downloader/sniffer/media_capture_analyzer.dart';
import 'package:aurora_downloader/sniffer/models/sniffed_media.dart';

SniffedMedia _media({
  required String url,
  required String name,
  required MediaType type,
  bool isShortClip = false,
  int? contentLengthBytes,
  Duration? duration,
}) {
  return SniffedMedia(
    url: url,
    name: name,
    type: type,
    isShortClip: isShortClip,
    contentLengthBytes: contentLengthBytes,
    duration: duration,
  );
}

CaptureGroup _group({
  required String key,
  required List<SniffedMedia> candidates,
  bool recommended = false,
}) {
  return CaptureGroup(
    groupKey: key,
    candidates: [
      for (var i = 0; i < candidates.length; i++)
        CaptureCandidate(
          media: candidates[i],
          groupKey: key,
          confidence: 1.0 - (i * 0.1),
          isRecommended: recommended && i == 0,
        ),
    ],
  );
}

void main() {
  group('MediaCatchController selection (displayed-group indices)', () {
    late MediaCatchController controller;

    setUp(() {
      controller = MediaCatchController();
    });

    tearDown(() {
      controller.dispose();
    });

    test(
      'selectedFrom group index 1 returns G1 primary, not G0 second candidate',
      () {
        // G0 has two candidates; G1 has one. Historic flat-index bug would
        // map selected index 1 → G0.candidates[1]. Group-index model must
        // map index 1 → G1.
        final g0Primary = _media(
          url: 'https://cdn.example.com/video-1080.mp4',
          name: 'video-1080.mp4',
          type: MediaType.video,
          contentLengthBytes: 100 * 1024 * 1024,
        );
        final g0Variant = _media(
          url: 'https://cdn.example.com/video-720.mp4',
          name: 'video-720.mp4',
          type: MediaType.video,
          contentLengthBytes: 50 * 1024 * 1024,
        );
        final g1Primary = _media(
          url: 'https://cdn.example.com/other.mp4',
          name: 'other.mp4',
          type: MediaType.video,
          contentLengthBytes: 20 * 1024 * 1024,
        );

        final displayed = [
          _group(key: 'g0', candidates: [g0Primary, g0Variant]),
          _group(key: 'g1', candidates: [g1Primary]),
        ];

        controller.toggleSelection(1);
        final selected = controller.selectedFrom(displayed);

        expect(selected, hasLength(1));
        expect(selected.single.groupKey, 'g1');
        expect(selected.single.primary.media.url, g1Primary.url);
        expect(selected.single.primary.media.url, isNot(g0Variant.url));
      },
    );

    test('toggleSelection adds and removes displayed-group indices', () {
      final displayed = [
        _group(
          key: 'a',
          candidates: [
            _media(
              url: 'https://cdn.example.com/a.mp4',
              name: 'a.mp4',
              type: MediaType.video,
            ),
          ],
        ),
        _group(
          key: 'b',
          candidates: [
            _media(
              url: 'https://cdn.example.com/b.mp4',
              name: 'b.mp4',
              type: MediaType.video,
            ),
          ],
        ),
        _group(
          key: 'c',
          candidates: [
            _media(
              url: 'https://cdn.example.com/c.mp4',
              name: 'c.mp4',
              type: MediaType.video,
            ),
          ],
        ),
      ];

      controller.toggleSelection(0);
      controller.toggleSelection(2);
      expect(controller.selectedIndices, {0, 2});
      expect(controller.selectedCount(displayed.length), 2);

      final selected = controller.selectedFrom(displayed);
      expect(selected.map((g) => g.groupKey).toList(), ['a', 'c']);

      controller.toggleSelection(0);
      expect(controller.selectedIndices, {2});
      expect(controller.selectedFrom(displayed).single.groupKey, 'c');
    });

    test(
      'recommendedGroupIndices empty when recommended group filtered out (HLS)',
      () {
        // Full analyzed list: recommended progressive MP4 + non-recommended HLS.
        final recommendedMp4 = _group(
          key: 'feature-mp4',
          candidates: [
            _media(
              url: 'https://cdn.example.com/feature.mp4',
              name: 'feature.mp4',
              type: MediaType.video,
              contentLengthBytes: 200 * 1024 * 1024,
              duration: const Duration(minutes: 40),
            ),
          ],
          recommended: true,
        );
        final hlsNotRecommended = _group(
          key: 'hls-stream',
          candidates: [
            _media(
              url: 'https://cdn.example.com/stream.m3u8',
              name: 'stream.m3u8',
              type: MediaType.video,
            ),
          ],
          recommended: false,
        );

        final analyzed = [recommendedMp4, hlsNotRecommended];
        // Sheet HLS chip post-filter: only HLS groups remain (sheet must pass
        // this list to Best — never the unfiltered analyzed list).
        final displayedHlsOnly = [hlsNotRecommended];

        expect(controller.recommendedGroupIndices(analyzed), {0});
        expect(controller.recommendedGroupIndices(displayedHlsOnly), isEmpty);
      },
    );

    test('selectAll clears stale high indices before selecting', () {
      controller.selectedIndices.addAll({0, 1, 5, 9});
      controller.selectAll(2);
      expect(controller.selectedIndices, {0, 1});
      expect(controller.selectedIndices.contains(5), isFalse);
      expect(controller.selectedIndices.contains(9), isFalse);
    });

    test(
      'recommendedGroupIndices indexes into displayed list, not candidate slots',
      () {
        final displayed = [
          _group(
            key: 'noise',
            candidates: [
              _media(
                url: 'https://cdn.example.com/thumb.jpg',
                name: 'thumb.jpg',
                type: MediaType.image,
              ),
              _media(
                url: 'https://cdn.example.com/thumb2.jpg',
                name: 'thumb2.jpg',
                type: MediaType.image,
              ),
            ],
            recommended: false,
          ),
          _group(
            key: 'main',
            candidates: [
              _media(
                url: 'https://cdn.example.com/feature.mp4',
                name: 'feature.mp4',
                type: MediaType.video,
                contentLengthBytes: 200 * 1024 * 1024,
                duration: const Duration(minutes: 40),
              ),
            ],
            recommended: true,
          ),
        ];

        final indices = controller.recommendedGroupIndices(displayed);
        // One index per recommended group (group 1), not flat candidate 0+1.
        expect(indices, {1});

        controller.selectedIndices
          ..clear()
          ..addAll(indices);
        final selected = controller.selectedFrom(displayed);
        expect(selected.single.groupKey, 'main');
      },
    );

    test(
      'short-clip exclusion: recommended only sees groups already in displayed list',
      () {
        // Sheet pipeline drops short clips before analyze/display. Controller
        // must not invent indices for groups the UI never showed.
        final shortClip = _group(
          key: 'clip',
          candidates: [
            _media(
              url: 'https://cdn.example.com/ad.mp4',
              name: 'ad.mp4',
              type: MediaType.video,
              isShortClip: true,
              duration: const Duration(seconds: 3),
            ),
          ],
          recommended: true,
        );
        final main = _group(
          key: 'main',
          candidates: [
            _media(
              url: 'https://cdn.example.com/movie.mp4',
              name: 'movie.mp4',
              type: MediaType.video,
              contentLengthBytes: 150 * 1024 * 1024,
              duration: const Duration(minutes: 90),
            ),
          ],
          recommended: true,
        );

        // If short clip were still in the list, both would be recommended.
        expect(
          controller.recommendedGroupIndices([shortClip, main]),
          {0, 1},
        );

        // Displayed list after short-clip filter: only main remains at index 0.
        final displayed = [main];
        expect(controller.recommendedGroupIndices(displayed), {0});
        controller.selectedIndices
          ..clear()
          ..addAll(controller.recommendedGroupIndices(displayed));
        expect(
          controller.selectedFrom(displayed).single.primary.media.name,
          'movie.mp4',
        );
      },
    );

    test('selectAll uses displayed group count', () {
      final displayed = [
        _group(
          key: 'g0',
          candidates: [
            _media(
              url: 'https://cdn.example.com/a.mp4',
              name: 'a.mp4',
              type: MediaType.video,
            ),
            _media(
              url: 'https://cdn.example.com/a2.mp4',
              name: 'a2.mp4',
              type: MediaType.video,
            ),
          ],
        ),
        _group(
          key: 'g1',
          candidates: [
            _media(
              url: 'https://cdn.example.com/b.mp4',
              name: 'b.mp4',
              type: MediaType.video,
            ),
          ],
        ),
      ];

      controller.selectAll(displayed.length);
      expect(controller.selectedIndices, {0, 1});
      expect(controller.selectedFrom(displayed), hasLength(2));
    });
  });
}

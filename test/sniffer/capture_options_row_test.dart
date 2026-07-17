import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aurora_downloader/settings/download_settings.dart';
import 'package:aurora_downloader/sniffer/capture/capture_media_row.dart';
import 'package:aurora_downloader/sniffer/capture/capture_options_row.dart';
import 'package:aurora_downloader/sniffer/media_capture_analyzer.dart';
import 'package:aurora_downloader/sniffer/models/sniffed_media.dart';
import 'package:aurora_downloader/theme/aurora_palette.dart';
import 'package:aurora_downloader/theme/aurora_tokens.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    home: AuroraPalette(
      colors: AColors.dark(),
      isLight: false,
      child: Scaffold(body: child),
    ),
  );
}

void main() {
  group('CaptureOptionsRow', () {
    testWidgets('show-all switch keeps current copy and fires callback', (
      tester,
    ) async {
      bool? showAll;
      await tester.pumpWidget(
        _wrap(
          CaptureOptionsRow(
            settings: DownloadSettings.defaults(),
            showAll: false,
            onShowAllChanged: (v) => showAll = v,
            onSettingsChanged: (_) {},
          ),
        ),
      );

      expect(find.text('Show all captured media'), findsOneWidget);
      expect(
        find.text('Show only URLs that look like playable media'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('capture_show_all_switch')), findsOneWidget);

      await tester.tap(find.byKey(const Key('capture_show_all_switch')));
      await tester.pumpAndSettle();
      expect(showAll, isTrue);
    });

    testWidgets('sort dropdown calls onSettingsChanged with sniffedMediaSort', (
      tester,
    ) async {
      DownloadSettings? next;
      await tester.pumpWidget(
        _wrap(
          CaptureOptionsRow(
            settings: DownloadSettings.defaults(),
            showAll: false,
            onShowAllChanged: (_) {},
            onSettingsChanged: (s) => next = s,
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('capture_sort_dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('size').last);
      await tester.pumpAndSettle();

      expect(next, isNotNull);
      expect(next!.sniffedMediaSort, SniffedMediaSort.size);
      expect(
        next!.sniffedMediaDisplayMode,
        DownloadSettings.defaults().sniffedMediaDisplayMode,
      );
    });

    testWidgets(
      'display-mode dropdown calls onSettingsChanged with sniffedMediaDisplayMode',
      (tester) async {
        DownloadSettings? next;
        await tester.pumpWidget(
          _wrap(
            CaptureOptionsRow(
              settings: DownloadSettings.defaults(),
              showAll: false,
              onShowAllChanged: (_) {},
              onSettingsChanged: (s) => next = s,
            ),
          ),
        );

        await tester.tap(find.byKey(const Key('capture_display_mode_dropdown')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('duration').last);
        await tester.pumpAndSettle();

        expect(next, isNotNull);
        expect(next!.sniffedMediaDisplayMode, SniffedMediaDisplayMode.duration);
        expect(
          next!.sniffedMediaSort,
          DownloadSettings.defaults().sniffedMediaSort,
        );
      },
    );
  });

  group('buildCaptureSubtitle display mode', () {
    CaptureGroup groupFor(SniffedMedia media) {
      return CaptureGroup(
        groupKey: media.url,
        candidates: [
          CaptureCandidate(
            media: media,
            groupKey: media.url,
            confidence: 1,
            qualityLabel: '720p',
          ),
        ],
      );
    }

    final media = SniffedMedia(
      url: 'https://cdn.example.com/clip.mp4',
      name: 'clip.mp4',
      type: MediaType.video,
      contentLengthBytes: 5 * 1024 * 1024,
      isSizeEstimated: true,
      width: 1280,
      height: 720,
      duration: const Duration(minutes: 3, seconds: 5),
      contentType: 'video/mp4',
    );

    test('size mode omits duration', () {
      final subtitle = buildCaptureSubtitle(
        media,
        groupFor(media),
        hls: false,
        displayMode: SniffedMediaDisplayMode.size,
      );
      expect(subtitle, contains('~'));
      expect(subtitle, contains('1280x720'));
      expect(subtitle, isNot(contains('3:05')));
      expect(subtitle, contains('video/mp4'));
    });

    test('duration mode omits size', () {
      final subtitle = buildCaptureSubtitle(
        media,
        groupFor(media),
        hls: false,
        displayMode: SniffedMediaDisplayMode.duration,
      );
      expect(subtitle, isNot(contains('MB')));
      expect(subtitle, contains('3:05'));
      expect(subtitle, contains('1280x720'));
    });

    test('both mode includes size and duration', () {
      final subtitle = buildCaptureSubtitle(
        media,
        groupFor(media),
        hls: false,
        displayMode: SniffedMediaDisplayMode.both,
      );
      expect(subtitle, contains('MB'));
      expect(subtitle, contains('3:05'));
    });
  });
}

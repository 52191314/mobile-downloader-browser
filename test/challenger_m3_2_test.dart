import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aurora_downloader/sniffer/browser_controller.dart';
import 'package:aurora_downloader/sniffer/media_sniffer_engine.dart';
import 'package:aurora_downloader/sniffer/models/sniffed_media.dart';
import 'package:aurora_downloader/sniffer/sniffer_screen.dart';
import 'package:aurora_downloader/downloader/downloader.dart';

void main() {
  group('Milestone 3 Deduplication & Headers Tests', () {
    late MediaSnifferEngine snifferEngine;
    late DownloadQueue downloadQueue;
    late MockBrowserController mockController;

    setUp(() {
      MediaSnifferEngine.clearGlobalCache();
      snifferEngine = MediaSnifferEngine(
        dedupDuration: const Duration(seconds: 1),
      );
      downloadQueue = DownloadQueue(maxConcurrentDownloads: 0);
      mockController = MockBrowserController(initialUrl: 'https://example.com');
    });

    tearDown(() async {
      await downloadQueue.dispose();
      snifferEngine.dispose();
    });

    test(
      'Simulate high volume of duplicate media URLs within 1 second',
      () async {
        final List<SniffedMedia> emittedEvents = [];
        final subscription = snifferEngine.onMediaDetected.listen(
          emittedEvents.add,
        );

        const url = 'https://example.com/movie.mp4';

        // Emit the URL 100 times sequentially
        for (int i = 0; i < 100; i++) {
          snifferEngine.sniff(url);
        }

        // Allow event stream to process
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(
          emittedEvents.length,
          equals(1),
          reason: 'Stream should emit exactly 1 event (de-duplicated).',
        );
        expect(
          snifferEngine.detectedMedia.length,
          equals(1),
          reason: 'Detected media list should contain exactly 1 item.',
        );

        await subscription.cancel();
      },
    );

    test(
      'Verify after deduplication window expires, a new request with the same URL is successfully emitted',
      () async {
        final List<SniffedMedia> emittedEvents = [];
        final subscription = snifferEngine.onMediaDetected.listen(
          emittedEvents.add,
        );

        const url = 'https://example.com/movie.mp4';

        snifferEngine.sniff(url);

        // Let's assume a deduplication window duration (e.g. 1 second).
        // Wait for the window to expire (1.5 seconds)
        await Future<void>.delayed(const Duration(milliseconds: 1500));

        // Sniff the same URL again after the window expires
        snifferEngine.sniff(url);

        // Allow event stream to process
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(
          emittedEvents.length,
          equals(2),
          reason:
              'A new request with the same URL should be emitted after the deduplication window expires.',
        );
        expect(
          snifferEngine.detectedMedia.length,
          equals(2),
          reason:
              'A new request with the same URL should be recorded in detectedMedia.',
        );

        await subscription.cancel();
      },
    );

    testWidgets(
      'Custom headers (Cookie, Referer) are successfully preserved and mapped to the enqueued DownloadTask',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: SnifferScreen(
              controller: mockController,
              downloadQueue: downloadQueue,
              snifferEngine: snifferEngine,
            ),
          ),
        );

        // Load a request with custom headers
        const pageUrl = 'https://example.com/video_page';
        const customHeaders = {
          'Cookie': 'session_token=xyz123',
          'Referer': 'https://previous-page.com',
        };
        await mockController.loadRequest(
          Uri.parse(pageUrl),
          headers: customHeaders,
        );
        await tester.pumpAndSettle();

        // Intercept a video link through the JS channel
        const mediaUrl = 'https://example.com/video.mp4';
        mockController.simulateJavaScriptMessage(
          'MediaSnifferChannel',
          mediaUrl,
        );
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pumpAndSettle();

        // Verify FAB badge is updated to 1
        expect(
          find.descendant(
            of: find.byKey(const Key('sniffer_fab')),
            matching: find.text('1'),
          ),
          findsOneWidget,
        );

        // Tap FAB to open the drawer
        await tester.tap(find.byKey(const Key('sniffer_fab')));
        await tester.pumpAndSettle();

        // Verify drawer is shown
        expect(find.byKey(const Key('sniffer_drawer')), findsOneWidget);

        // Tap download on the sniffed item
        await tester.tap(find.byKey(const Key('download_item_0')));
        await tester.pumpAndSettle();

        // Verify the add-to-queue dialog is shown
        expect(find.text('Add to Download Queue'), findsOneWidget);

        // Tap 'Download' button in the dialog to enqueue the task
        await tester.tap(find.byKey(const Key('dialog_add_button')));
        await tester.pumpAndSettle();

        // Check the task added to DownloadQueue
        final allTasks = [
          ...downloadQueue.activeTasks,
          ...downloadQueue.queuedTasks,
        ];
        expect(
          allTasks.length,
          equals(1),
          reason: 'Exactly one task should have been added to the queue.',
        );

        final task = allTasks.first;
        expect(task.url, equals(mediaUrl));

        // Verify custom headers (Cookie, Referer) are preserved
        expect(
          task.headers,
          isNotNull,
          reason: 'Task headers should not be null.',
        );
        expect(
          task.headers,
          containsPair('Cookie', 'session_token=xyz123'),
          reason: 'Task should preserve the Cookie header.',
        );
        expect(
          task.headers,
          containsPair('Referer', 'https://previous-page.com'),
          reason: 'Task should preserve the Referer header.',
        );
      },
    );

    testWidgets(
      'Verify surrit.com Referer header correction',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: SnifferScreen(
              controller: mockController,
              downloadQueue: downloadQueue,
              snifferEngine: snifferEngine,
            ),
          ),
        );

        // Scenario A: User is on a missav page, but the media URL is on surrit.com
        const pageUrl = 'https://missav.com/en/instv-717';
        await mockController.loadRequest(Uri.parse(pageUrl));
        await tester.pumpAndSettle();

        const mediaUrl = 'https://surrit.com/some-uuid/360p/video.m3u8';
        mockController.simulateJavaScriptMessage(
          'MediaSnifferChannel',
          mediaUrl,
        );
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pumpAndSettle();

        // Tap FAB to open the drawer
        await tester.tap(find.byKey(const Key('sniffer_fab')));
        await tester.pumpAndSettle();

        // Tap download on the sniffed item
        await tester.tap(find.byKey(const Key('download_item_0')));
        await tester.pumpAndSettle();

        // Tap 'Download' button in the dialog to enqueue the task
        await tester.tap(find.byKey(const Key('dialog_add_button')));
        await tester.pumpAndSettle();

        // Check the task added to DownloadQueue
        final allTasks = [
          ...downloadQueue.activeTasks,
          ...downloadQueue.queuedTasks,
        ];
        expect(allTasks.length, equals(1));
        final task = allTasks.first;

        // Verify Referer was normalized from missav.com to missav.ws
        expect(task.headers, isNotNull);
        expect(
          task.headers!['Referer'],
          equals('https://missav.ws/en/instv-717'),
          reason: 'Should normalize missav.com Referer to missav.ws.',
        );
      },
    );

    testWidgets(
      'Verify surrit.com same-origin Referer is preserved',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: SnifferScreen(
              controller: mockController,
              downloadQueue: downloadQueue,
              snifferEngine: snifferEngine,
            ),
          ),
        );

        // Scenario B: User manually visits a surrit.com URL which resolves as the page URL
        const surritPageUrl = 'https://surrit.com/some-uuid/360p/video.m3u8';
        await mockController.loadRequest(Uri.parse(surritPageUrl));
        await tester.pumpAndSettle();

        mockController.simulateJavaScriptMessage(
          'MediaSnifferChannel',
          surritPageUrl,
        );
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pumpAndSettle();

        // Tap FAB to open the drawer
        await tester.tap(find.byKey(const Key('sniffer_fab')));
        await tester.pumpAndSettle();

        // Tap download on the sniffed item
        await tester.tap(find.byKey(const Key('download_item_0')));
        await tester.pumpAndSettle();

        // Tap 'Download' button in the dialog to enqueue the task
        await tester.tap(find.byKey(const Key('dialog_add_button')));
        await tester.pumpAndSettle();

        final allTasksB = [
          ...downloadQueue.activeTasks,
          ...downloadQueue.queuedTasks,
        ];
        expect(allTasksB.length, equals(1));
        final taskB = allTasksB.first;

        // When both the referer and target are on surrit.com (same-origin),
        // the referer MUST be preserved — surrit.com's CDN rejects cross-origin
        // missav.ws referer with 403.
        expect(taskB.headers, isNotNull);
        expect(
          taskB.headers!['Referer'],
          equals(surritPageUrl),
          reason: 'Should preserve same-origin surrit.com Referer.',
        );
        // Verify Origin header was also added as a side-effect.
        expect(
          taskB.headers!['Origin'],
          equals('https://surrit.com'),
          reason: 'Should add Origin header matching the referer host.',
        );
      },
    );
  });
}

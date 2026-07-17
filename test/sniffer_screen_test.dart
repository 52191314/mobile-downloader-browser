import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aurora_downloader/settings/download_settings.dart';
import 'package:aurora_downloader/sniffer/browser_controller.dart';
import 'package:aurora_downloader/sniffer/media_sniffer_engine.dart';
import 'package:aurora_downloader/sniffer/models/sniffed_media.dart';
import 'package:aurora_downloader/sniffer/sniffer_screen.dart';
import 'package:aurora_downloader/downloader/downloader.dart';

void main() {
  group('SnifferScreen Widget Tests', () {
    late MockBrowserController mockController;
    late DownloadQueue downloadQueue;
    late MediaSnifferEngine snifferEngine;

    setUp(() {
      MediaSnifferEngine.clearGlobalCache();
      mockController = MockBrowserController(initialUrl: 'https://example.com');
      downloadQueue = DownloadQueue(maxConcurrentDownloads: 0);
      snifferEngine = MediaSnifferEngine();
    });

    tearDown(() async {
      await downloadQueue.dispose();
      snifferEngine.dispose();
    });

    Future<void> pumpSnifferRebuild(WidgetTester tester) async {
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
    }

    testWidgets('Renders address bar and mock webview placeholder', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SnifferScreen(
            controller: mockController,
            downloadQueue: downloadQueue,
            snifferEngine: snifferEngine,
          ),
        ),
      );

      expect(find.byKey(const Key('browser_address_chip')), findsOneWidget);
      expect(find.byKey(const Key('mock_webview_placeholder')), findsOneWidget);
      expect(find.byKey(const Key('sniffer_fab')), findsOneWidget);
      // Toolbar and hamburger menu were consolidated into the unified bottom strip

      expect(find.text('Built-in Browser & Sniffer'), findsNothing);
    });

    testWidgets('Address bar navigation loads request and sniffs media', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 900);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        MaterialApp(
          home: SnifferScreen(
            controller: mockController,
            downloadQueue: downloadQueue,
            snifferEngine: snifferEngine,
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('browser_address_chip')));
      await tester.pumpAndSettle();

      // Type a media URL into the address bar
      await tester.tap(find.byKey(const Key('sniffer_address_bar')));
      await tester.enterText(
        find.byKey(const Key('sniffer_address_bar')),
        'example.com/video.mp4',
      );
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();

      // Verify the controller loaded it (with prepended scheme if needed)
      final currentUrl = await mockController.currentUrl();
      expect(currentUrl, 'https://example.com/video.mp4');

      // Check if sniffer engine detected it
      expect(snifferEngine.detectedMedia.length, 1);
      expect(snifferEngine.detectedMedia.first.name, 'video.mp4');
    });

    testWidgets('JS Channel interception adds to media sniffer', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SnifferScreen(
            controller: mockController,
            downloadQueue: downloadQueue,
            snifferEngine: snifferEngine,
          ),
        ),
      );

      // Simulate JS message
      mockController.simulateJavaScriptMessage(
        'MediaSnifferChannel',
        'https://example.com/audio.mp3',
      );
      await tester.pumpAndSettle();

      // Verify it was detected
      expect(snifferEngine.detectedMedia.length, 1);
      expect(
        snifferEngine.detectedMedia.first.url,
        'https://example.com/audio.mp3',
      );
      expect(snifferEngine.detectedMedia.first.type, MediaType.audio);
    });

    testWidgets('Ad blocker blocks ad domain navigation', (tester) async {
      tester.view.physicalSize = const Size(800, 900);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        MaterialApp(
          home: SnifferScreen(
            controller: mockController,
            downloadQueue: downloadQueue,
            snifferEngine: snifferEngine,
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('browser_address_chip')));
      await tester.pumpAndSettle();

      // Enter ad URL
      await tester.enterText(
        find.byKey(const Key('sniffer_address_bar')),
        'doubleclick.net',
      );
      await tester.tap(find.byKey(const Key('sniffer_go_button')));
      await tester.pumpAndSettle();

      // Verify navigation was blocked (current URL remains initial)
      final currentUrl = await mockController.currentUrl();
      expect(currentUrl, 'https://example.com');
    });

    testWidgets('JS Channel handles AdBlocker popup messages', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SnifferScreen(
            controller: mockController,
            downloadQueue: downloadQueue,
            snifferEngine: snifferEngine,
          ),
        ),
      );

      expect(mockController.blockedPopupsCount, 0);

      // Simulate popup blocked event
      mockController.simulateJavaScriptMessage(
        'AdBlockerChannel',
        'popup_blocked',
      );
      await tester.pumpAndSettle();

      expect(mockController.blockedPopupsCount, 1);
    });

    testWidgets(
      'structured popup messages increment counter and offer recovery',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: SnifferScreen(
              controller: mockController,
              downloadQueue: downloadQueue,
              snifferEngine: snifferEngine,
            ),
          ),
        );

        mockController.simulateJavaScriptMessage(
          'PopupBlockerChannel',
          '{"url":"https://ads.example/popup","userInitiated":false}',
        );
        await tester.pump();

        expect(mockController.blockedPopupsCount, 1);
        expect(find.text('Popup blocked.'), findsOneWidget);
        expect(find.text('Open once'), findsOneWidget);
      },
    );

    testWidgets('one-tab browser keeps page strip visible', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SnifferScreen(
            controller: mockController,
            downloadQueue: downloadQueue,
            snifferEngine: snifferEngine,
          ),
        ),
      );

      expect(find.byKey(const Key('browser_tab_strip')), findsOneWidget);
    });

    testWidgets('closing second tab leaves page strip visible', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SnifferScreen(
            controller: mockController,
            debugControllerFactory: () => MockBrowserController(),
            downloadQueue: downloadQueue,
            snifferEngine: snifferEngine,
          ),
        ),
      );

      mockController.simulateJavaScriptMessage(
        'LinkContextChannel',
        '{"href":"https://example.com/second","text":"Second page","pageUrl":"https://example.com","pageTitle":"Example"}',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open in Background Tab'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('browser_tab_close_1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('browser_tab_strip')), findsOneWidget);
    });

    testWidgets('element context menu opens without a target URL', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SnifferScreen(
            controller: mockController,
            downloadQueue: downloadQueue,
            snifferEngine: snifferEngine,
          ),
        ),
      );

      mockController.simulateJavaScriptMessage(
        'LinkContextChannel',
        '{"text":"Plain article text","selector":"p.article:nth-of-type(2)","tagName":"p","pageUrl":"https://example.com/article","pageTitle":"Article"}',
      );
      await tester.pumpAndSettle();

      expect(find.text('Block This Element'), findsOneWidget);
      expect(find.text('Copy Page URL'), findsOneWidget);
      expect(find.text('Open in Browser'), findsNothing);
    });

    testWidgets('link context menu exposes target actions', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SnifferScreen(
            controller: mockController,
            downloadQueue: downloadQueue,
            snifferEngine: snifferEngine,
          ),
        ),
      );

      mockController.simulateJavaScriptMessage(
        'LinkContextChannel',
        '{"href":"https://example.com/download","text":"Download","selector":"a.cta:nth-of-type(1)","tagName":"a","pageUrl":"https://example.com","pageTitle":"Example"}',
      );
      await tester.pumpAndSettle();

      expect(find.text('Open in Browser'), findsOneWidget);
      expect(find.text('Open in New Tab'), findsOneWidget);
      expect(find.text('Copy Target URL'), findsOneWidget);
      expect(find.text('Block This Element'), findsOneWidget);
    });

    testWidgets('media context menu can add target URL to queue', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SnifferScreen(
            controller: mockController,
            downloadQueue: downloadQueue,
            snifferEngine: snifferEngine,
          ),
        ),
      );

      mockController.simulateJavaScriptMessage(
        'LinkContextChannel',
        '{"src":"https://cdn.example.com/video/movie.mp4","text":"Movie preview","selector":"video:nth-of-type(1)","tagName":"video","pageUrl":"https://example.com/watch","pageTitle":"Watch"}',
      );
      await tester.pumpAndSettle();

      expect(find.text('Copy Target URL'), findsOneWidget);
      await tester.tap(find.text('Add to Queue'));
      await tester.pumpAndSettle();

      final allTasks = [
        ...downloadQueue.activeTasks,
        ...downloadQueue.queuedTasks,
      ];
      expect(allTasks.length, 1);
      expect(allTasks.single.url, 'https://cdn.example.com/video/movie.mp4');
    });

    testWidgets(
      'Sniffer Drawer displays detected media and download triggers dialog',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: SnifferScreen(
              controller: mockController,
              downloadQueue: downloadQueue,
              snifferEngine: snifferEngine,
            ),
          ),
        );

        // Intercept a video link
        mockController.simulateJavaScriptMessage(
          'MediaSnifferChannel',
          'https://example.com/files/lecture.pdf',
        );
        await pumpSnifferRebuild(tester);

        // Verify FAB shows radar icon when media is detected
        expect(find.byIcon(Icons.radar), findsOneWidget);

        // Open media sheet
        await tester.tap(find.byKey(const Key('sniffer_fab')));
        await tester.pumpAndSettle();

        // Verify media sheet and items are visible
        expect(find.byKey(const Key('sniffed_item_0')), findsOneWidget);
        expect(find.text('Capture Media'), findsOneWidget);
        expect(find.text('lecture.pdf'), findsOneWidget);

        // Select item, then header Download (multi-select flow)
        await tester.tap(
          find.descendant(
            of: find.byKey(const Key('sniffed_item_0')),
            matching: find.byType(Checkbox),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('capture_download_selected_button')));
        await tester.pumpAndSettle();

         // Verify "Add to Download Queue" dialog opened
        expect(find.text('Add to Download Queue'), findsOneWidget);
        expect(find.byKey(const Key('dialog_rename_pencil_button')), findsOneWidget);
        expect(find.text('example.com_lecture.pdf'), findsOneWidget);

        // Tap rename pencil button to spawn child dialog
        await tester.tap(find.byKey(const Key('dialog_rename_pencil_button')));
        await tester.pumpAndSettle();

        // Verify child rename dialog is open
        expect(find.text('Rename File'), findsOneWidget);
        expect(find.byKey(const Key('dialog_filename_input')), findsOneWidget);

        // Verify filename field uses page context plus the media filename.
        final TextFormField filenameField = tester.widget<TextFormField>(
          find.byKey(const Key('dialog_filename_input')),
        );
        expect(filenameField.controller?.text, 'example.com_lecture.pdf');

        // Edit filename inside the child dialog
        await tester.enterText(
          find.byKey(const Key('dialog_filename_input')),
          'chemistry_lecture.pdf',
        );

        // Tap child dialog OK button
        await tester.tap(find.byKey(const Key('dialog_rename_ok_button')));
        await tester.pumpAndSettle();

        // Verify child dialog is closed and parent is updated
        expect(find.text('Rename File'), findsNothing);
        expect(find.text('chemistry_lecture.pdf'), findsOneWidget);

        // Tap priority dropdown
        await tester.tap(find.byKey(const Key('dialog_priority_dropdown')));
        await tester.pumpAndSettle();

        // Tap 'HIGH' menu item
        await tester.tap(find.text('HIGH').last);
        await tester.pumpAndSettle();

        // Tap 'Download' button
        await tester.tap(find.byKey(const Key('dialog_add_button')));
        await tester.pumpAndSettle();

        // Verify dialog is closed and snackbar is shown
        expect(find.text('Add to Download Queue'), findsNothing);
        expect(
          find.text('Added "chemistry_lecture.pdf" to queue.'),
          findsOneWidget,
        );

        // Verify task in the DownloadQueue
        final allTasks = [
          ...downloadQueue.activeTasks,
          ...downloadQueue.queuedTasks,
        ];
        expect(allTasks.length, 1);
        final task = allTasks.first;
        expect(task.url, 'https://example.com/files/lecture.pdf');
        expect(task.priority, DownloadPriority.high);
        expect(task.savePath.endsWith('chemistry_lecture.pdf'), isTrue);
      },
    );

    testWidgets('Capture Mode hides noisy assets until Show all is enabled', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SnifferScreen(
            controller: mockController,
            downloadQueue: downloadQueue,
            snifferEngine: snifferEngine,
          ),
        ),
      );

      mockController.simulateJavaScriptMessage(
        'MediaSnifferChannel',
        'https://example.com/favicon.ico',
      );
      mockController.simulateJavaScriptMessage(
        'MediaSnifferChannel',
        'https://example.com/movie-720p.mp4',
      );
      await pumpSnifferRebuild(tester);

      await tester.tap(find.byKey(const Key('sniffer_fab')));
      await tester.pumpAndSettle();

      expect(find.text('movie-720p.mp4'), findsOneWidget);
      expect(find.text('favicon.ico'), findsNothing);
      expect(find.text('1 hidden'), findsOneWidget);

      await tester.tap(find.byKey(const Key('capture_show_all_switch')));
      await tester.pumpAndSettle();

      expect(find.text('favicon.ico'), findsOneWidget);
    });

    testWidgets('Ad media URLs pass through the sniffer', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SnifferScreen(
            controller: mockController,
            downloadQueue: downloadQueue,
            snifferEngine: snifferEngine,
          ),
        ),
      );

      // Ad URL matching built-in /vast/ rule should be suppressed
      mockController.simulateJavaScriptMessage(
        'MediaSnifferChannel',
        'https://adserver.example.com/vast/ad.m3u8',
      );
      // Regular URL should pass through
      mockController.simulateJavaScriptMessage(
        'MediaSnifferChannel',
        'https://video.example.com/movie.mp4',
      );
      await pumpSnifferRebuild(tester);

      expect(snifferEngine.detectedMedia.length, 2);
      expect(
        snifferEngine.detectedMedia.map((media) => media.name),
        contains('movie.mp4'),
      );
      expect(snifferEngine.suppressedMediaCount, 0);
    });

    testWidgets('MediaSnifferDataChannel forwards content type', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SnifferScreen(
            controller: mockController,
            downloadQueue: downloadQueue,
            snifferEngine: snifferEngine,
          ),
        ),
      );

      // Simulate structured data from JS with content-type for extensionless URL
      mockController.simulateJavaScriptMessage(
        'MediaSnifferDataChannel',
        '{"url":"https://cdn.example.com/get_file/abc123","contentType":"video/mp4","contentLength":"1048576"}',
      );
      await tester.pumpAndSettle();

      expect(snifferEngine.detectedMedia.length, 1);
      expect(snifferEngine.detectedMedia.first.type, MediaType.video);
      expect(snifferEngine.detectedMedia.first.name, 'abc123');
    });

    testWidgets(
      'extensionless video/mp4 media enqueues with immediate content type',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: SnifferScreen(
              controller: mockController,
              downloadQueue: downloadQueue,
              snifferEngine: snifferEngine,
            ),
          ),
        );

        mockController.simulateJavaScriptMessage(
          'MediaSnifferDataChannel',
          '{"url":"https://cdn.example.com/get_file/abc123","contentType":"video/mp4"}',
        );
        await pumpSnifferRebuild(tester);

        expect(snifferEngine.detectedMedia.length, 1);
        expect(snifferEngine.detectedMedia.single.contentType, 'video/mp4');

        await tester.tap(find.byKey(const Key('sniffer_fab')));
        await tester.pumpAndSettle();
        // Select item, then header Download (multi-select flow)
        await tester.tap(
          find.descendant(
            of: find.byKey(const Key('sniffed_item_0')),
            matching: find.byType(Checkbox),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('capture_download_selected_button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('dialog_add_button')));
        await tester.pumpAndSettle();

        final allTasks = [
          ...downloadQueue.activeTasks,
          ...downloadQueue.queuedTasks,
        ];
        expect(allTasks.length, 1);
        expect(allTasks.single.url, 'https://cdn.example.com/get_file/abc123');
        expect(allTasks.single.contentType, 'video/mp4');
      },
    );

    testWidgets('Injected snifferEngine is used across all tabs', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SnifferScreen(
            controller: mockController,
            debugControllerFactory: () => MockBrowserController(),
            downloadQueue: downloadQueue,
            snifferEngine: snifferEngine,
          ),
        ),
      );

      // Open a second tab via context menu
      mockController.simulateJavaScriptMessage(
        'LinkContextChannel',
        '{"href":"https://example.com/second","text":"Second","pageUrl":"https://example.com","pageTitle":"Example"}',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open in Background Tab'));
      await tester.pumpAndSettle();

      // Sniff something in the first tab
      mockController.simulateJavaScriptMessage(
        'MediaSnifferChannel',
        'https://example.com/video1.mp4',
      );
      await tester.pumpAndSettle();

      // The injected snifferEngine should have the media
      expect(snifferEngine.detectedMedia.length, 1);
      expect(snifferEngine.detectedMedia.first.name, 'video1.mp4');
    });

  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aurora_downloader/main.dart';
import 'package:aurora_downloader/sniffer/browser_controller.dart';
import 'package:aurora_downloader/sync/sync.dart';
import 'package:aurora_downloader/ui/pages/queue_page.dart';
import 'package:aurora_downloader/downloader/downloader.dart';

void main() {
  testWidgets('Aurora app launches into browser shell', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MyApp(
        browserController: MockBrowserController(),
        driveSyncService: DriveSyncService(
          client: MockGoogleDriveClient(latency: Duration.zero),
        ),
      ),
    );

    // Verify the consolidated bottom strip is rendered with back button
    expect(find.byKey(const Key('sniffer_back_button')), findsOneWidget);
  });

  testWidgets('Settings expose Drive sync and speed limiter controls', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MyApp(
        initialTabIndex: 2, // Start on Settings tab
        browserController: MockBrowserController(),
        driveSyncService: DriveSyncService(
          client: MockGoogleDriveClient(latency: Duration.zero),
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    // Dashboard cards are visible
    expect(find.text('Drive Sync'), findsOneWidget);
    expect(find.text('Speed'), findsOneWidget);
    expect(find.text('Adblock'), findsOneWidget);
    expect(find.text('Search'), findsOneWidget);
    expect(find.text('Sniffer'), findsOneWidget);
  });

  testWidgets('Queue opens from dock tab', (WidgetTester tester) async {
    await tester.pumpWidget(
      MyApp(
        initialTabIndex: 0, // Start on Queue tab
        browserController: MockBrowserController(
          initialUrl: 'https://example.com',
        ),
        driveSyncService: DriveSyncService(
          client: MockGoogleDriveClient(latency: Duration.zero),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('Downloads'), findsOneWidget); // AppBar title
    expect(find.text('No downloads yet'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsNWidgets(2)); // Queue input + dock FAB (browser tab not yet built — lazy main tabs)
  });

  testWidgets('QueuePage folder tabs filter tasks correctly', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final queue = DownloadQueue();
    
    // Add some tasks
    final task1 = DownloadTask(
      id: '1',
      url: 'https://example.com/file1.mp4',
      savePath: '/downloads/completed/FolderA/file1.mp4',
      tempDir: '/downloads/temp/1',
      state: DownloadState.completed,
      createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
    );
    final task2 = DownloadTask(
      id: '2',
      url: 'https://example.com/file2.mp4',
      savePath: '/downloads/completed/FolderB/file2.mp4',
      tempDir: '/downloads/temp/2',
      state: DownloadState.completed,
      createdAt: DateTime.now().subtract(const Duration(minutes: 2)),
    );
    final task3 = DownloadTask(
      id: '3',
      url: 'https://example.com/file3.mp4',
      savePath: '/downloads/completed/file3.mp4', // Default/No custom folder
      tempDir: '/downloads/temp/3',
      state: DownloadState.completed,
      createdAt: DateTime.now().subtract(const Duration(minutes: 1)),
    );
    final task4 = DownloadTask(
      id: '4',
      url: 'https://example.com/file4.mp4',
      savePath: '/downloads/completed/file4.mp4',
      tempDir: '/downloads/temp/4',
      exportDirectoryUri: 'content://com.android.providers.downloads/FolderC',
      state: DownloadState.completed,
      createdAt: DateTime.now().subtract(const Duration(seconds: 30)),
    );
    final task5 = DownloadTask(
      id: '5',
      url: 'https://example.com/file5.mp4',
      savePath: '/data/user/150/com.personal.aurora_downloader/files/FolderD/file5.mp4',
      tempDir: '/downloads/temp/5',
      state: DownloadState.completed,
      createdAt: DateTime.now(), // Newest
    );

    queue.addTask(task1);
    queue.addTask(task2);
    queue.addTask(task3);
    queue.addTask(task4);
    queue.addTask(task5);

    final urlController = TextEditingController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QueuePage(
            queue: queue,
            urlController: urlController,
            onAddDownload: () async {},
            onOpenDownload: (t) async {},
            onShareDownload: (t) async {},
            speedLimitKbps: 0,
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify ChoiceChips are rendered for FolderA, FolderB, FolderC, FolderD, Default, All
    expect(find.byKey(const Key('folder_tab_All')), findsOneWidget);
    expect(find.byKey(const Key('folder_tab_Default')), findsOneWidget);
    expect(find.byKey(const Key('folder_tab_FolderA')), findsOneWidget);
    expect(find.byKey(const Key('folder_tab_FolderB')), findsOneWidget);
    expect(find.byKey(const Key('folder_tab_FolderC')), findsOneWidget);
    expect(find.byKey(const Key('folder_tab_FolderD')), findsOneWidget);

    // Default selection is All -> should find all 5 tasks
    expect(find.text('file1.mp4'), findsOneWidget);
    expect(find.text('file2.mp4'), findsOneWidget);
    expect(find.text('file3.mp4'), findsOneWidget);
    expect(find.text('file4.mp4'), findsOneWidget);
    expect(find.text('file5.mp4'), findsOneWidget);

    // Tap FolderA chip
    await tester.tap(find.byKey(const Key('folder_tab_FolderA')));
    await tester.pumpAndSettle();

    // Should only show file1.mp4
    expect(find.text('file1.mp4'), findsOneWidget);
    expect(find.text('file2.mp4'), findsNothing);
    expect(find.text('file3.mp4'), findsNothing);
    expect(find.text('file4.mp4'), findsNothing);
    expect(find.text('file5.mp4'), findsNothing);

    // Tap FolderD chip
    await tester.tap(find.byKey(const Key('folder_tab_FolderD')));
    await tester.pumpAndSettle();

    // Should only show file5.mp4
    expect(find.text('file5.mp4'), findsOneWidget);
    expect(find.text('file1.mp4'), findsNothing);
    expect(find.text('file2.mp4'), findsNothing);
    expect(find.text('file3.mp4'), findsNothing);
    expect(find.text('file4.mp4'), findsNothing);

    // Tap FolderC chip
    await tester.tap(find.byKey(const Key('folder_tab_FolderC')));
    await tester.pumpAndSettle();

    // Should only show file4.mp4
    expect(find.text('file4.mp4'), findsOneWidget);
    expect(find.text('file1.mp4'), findsNothing);

    // Tap Default chip
    await tester.tap(find.byKey(const Key('folder_tab_Default')));
    await tester.pumpAndSettle();

    // Should only show file3.mp4
    expect(find.text('file3.mp4'), findsOneWidget);
    expect(find.text('file1.mp4'), findsNothing);
  });
}

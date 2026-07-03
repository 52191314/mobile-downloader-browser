# Milestone 3: Browser & Media Sniffer — Test & Mocking Design Report

## 1. Observation
* The file `D:\02_Projects\Final_52191314_Server_and_Apps\aurora_downloader\pubspec.yaml` declares standard project dependencies (such as `http`, `crypto`, `path_provider`), but does not yet contain a dependency for `webview_flutter` (viewed lines 30–45).
* There are no active implementations of a web browser or media sniffer screen in the `lib/` directory, nor any corresponding test files in `test/`.
* Running `flutter test` on the command-line runs in a headless environment. In this environment, any attempt to instantiate or render native Android/iOS platform views (such as a real browser engine using `WebViewWidget` from `webview_flutter`) will fail or throw platform channel exception errors (e.g., `MissingPluginException` or platform channel bindings not registered).

## 2. Logic Chain
1. Since a real browser rendering engine cannot run in `flutter test` on the command line, we must decouple the UI and the sniffing logic from the direct concrete dependency on `webview_flutter` platform classes.
2. We achieve this by defining an abstract interface, `SnifferBrowserController`, which encapsulates all the actions we need to control the web browser (loading requests, navigating history, injecting JavaScript, and receiving JS-to-Dart messages).
3. The production implementation (`SnifferWebViewControllerImpl`) will simply delegate these calls to `webview_flutter`'s concrete `WebViewController`.
4. The test environment will use a custom `MockBrowserController` which implements `SnifferBrowserController` and simulates the navigation history stack, page titles, and Javascript channel callbacks entirely in-memory.
5. In the UI tree, we wrap the native web view widget inside a custom `BrowserWidget`. The `BrowserWidget` takes an optional `testBuilder` parameter (or automatically detects a mock controller) to render a safe placeholder widget (`MockWebViewPlaceholderWidget`) during testing instead of the native platform-bound widget.
6. The `MediaSnifferEngine` compiles regex patterns of media files (e.g. `.mp4`, `.m3u8`, `.mp3`, `.pdf`, `.zip`) and exposes a broadcast `Stream<SniffedMedia>`. This engine is a pure Dart service, making it 100% testable via standard unit tests and stream expectations.

## 3. Caveats
* **Mock Fidelity:** The mocking strategy relies on manual replication of browser lifecycles (such as simulating `onPageStarted` and `onPageFinished` when a load request is made). If the real WebView behaves differently (e.g., redirecting pages, throwing SSL exceptions, or delayed JS execution), the tests might not detect integration issues. To mitigate this, a few manual integration checks on a real device/emulator are recommended.
* **Complex Media Detection:** If websites hide media URLs behind dynamic obfuscation or blob URLs, simple DOM mutation observers and standard link interception might not catch them. The JS injection script will need continuous refinement.

## 4. Conclusion
We recommend implementing a decoupled Sniffer Architecture as detailed below. This ensures high test coverage, robust separation of concerns, and 100% hermetic unit and widget tests on the command line without real browser engines.

### A. Interception & Sniffer Engine Design
The `MediaSnifferEngine` will manage matching rules and output stream.

```dart
// lib/sniffer/media_sniffer_engine.dart
import 'dart:async';

class SniffedMedia {
  final String url;
  final String extension;
  final DateTime detectedAt;
  final String pageTitle;

  SniffedMedia({
    required this.url,
    required this.extension,
    required this.detectedAt,
    required this.pageTitle,
  });
}

class MediaSnifferEngine {
  final List<RegExp> _mediaPatterns = [
    RegExp(r'\.(mp4|mkv|webm|avi|mov|m3u8)(\?.*)?$', caseSensitive: false),
    RegExp(r'\.(mp3|wav|m4a|aac|flac)(\?.*)?$', caseSensitive: false),
    RegExp(r'\.(pdf|zip|rar|tar\.gz|exe|dmg)(\?.*)?$', caseSensitive: false),
  ];

  final StreamController<SniffedMedia> _snifferStreamController = StreamController<SniffedMedia>.broadcast();
  final Map<String, DateTime> _recentSniffs = {};
  final Duration deDuplicationWindow;

  MediaSnifferEngine({this.deDuplicationWindow = const Duration(seconds: 2)});

  Stream<SniffedMedia> get sniffedMediaStream => _snifferStreamController.stream;

  bool sniffUrl(String url, {String? pageTitle}) {
    final cleanUrl = url.split('?').first;
    for (final pattern in _mediaPatterns) {
      if (pattern.hasMatch(url)) {
        final now = DateTime.now();
        // Time-based de-duplication to prevent spamming the UI
        if (_recentSniffs.containsKey(url)) {
          final lastTime = _recentSniffs[url]!;
          if (now.difference(lastTime) < deDuplicationWindow) {
            return true; 
          }
        }
        _recentSniffs[url] = now;
        _pruneCache(now);

        final extension = _extractExtension(cleanUrl);
        final media = SniffedMedia(
          url: url,
          extension: extension,
          detectedAt: now,
          pageTitle: pageTitle ?? 'Unknown Media',
        );
        _snifferStreamController.add(media);
        return true;
      }
    }
    return false;
  }

  void _pruneCache(DateTime now) {
    _recentSniffs.removeWhere((url, time) => now.difference(time) > deDuplicationWindow * 5);
  }

  String _extractExtension(String cleanUrl) {
    final parts = cleanUrl.split('.');
    if (parts.length > 1) {
      return parts.last.toLowerCase();
    }
    return '';
  }

  void dispose() {
    _snifferStreamController.close();
  }
}
```

### B. Unit Tests for Interception Engine
```dart
// test/sniffer/media_sniffer_engine_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:aurora_downloader/sniffer/media_sniffer_engine.dart';

void main() {
  group('MediaSnifferEngine Unit Tests', () {
    late MediaSnifferEngine snifferEngine;

    setUp(() {
      snifferEngine = MediaSnifferEngine();
    });

    tearDown(() {
      snifferEngine.dispose();
    });

    test('matches media extensions and emits sniffed event', () async {
      final sniffedList = <SniffedMedia>[];
      final sub = snifferEngine.sniffedMediaStream.listen(sniffedList.add);

      final isMedia = snifferEngine.sniffUrl('https://example.com/video.mp4', pageTitle: 'Test Video');
      expect(isMedia, isTrue);
      
      await Future<void>.delayed(Duration.zero);
      expect(sniffedList.length, 1);
      expect(sniffedList[0].url, 'https://example.com/video.mp4');
      expect(sniffedList[0].extension, 'mp4');
      expect(sniffedList[0].pageTitle, 'Test Video');
      await sub.cancel();
    });

    test('handles url parameters correctly and extracts extension', () async {
      final sniffedList = <SniffedMedia>[];
      final sub = snifferEngine.sniffedMediaStream.listen(sniffedList.add);

      snifferEngine.sniffUrl('https://example.com/music.mp3?user=1&token=xyz');
      await Future<void>.delayed(Duration.zero);
      expect(sniffedList[0].extension, 'mp3');
      await sub.cancel();
    });

    test('ignores non-media links like .html or .png', () async {
      final sniffedList = <SniffedMedia>[];
      final sub = snifferEngine.sniffedMediaStream.listen(sniffedList.add);

      final isMedia = snifferEngine.sniffUrl('https://example.com/index.html');
      expect(isMedia, isFalse);
      
      await Future<void>.delayed(Duration.zero);
      expect(sniffedList, isEmpty);
      await sub.cancel();
    });

    test('de-duplicates duplicate sniff requests within time-window', () async {
      final sniffedList = <SniffedMedia>[];
      final sub = snifferEngine.sniffedMediaStream.listen(sniffedList.add);

      snifferEngine.sniffUrl('https://example.com/file.zip');
      snifferEngine.sniffUrl('https://example.com/file.zip'); // Repeated immediately

      await Future<void>.delayed(Duration.zero);
      expect(sniffedList.length, 1); // Only 1 event is broadcast
      await sub.cancel();
    });
  });
}
```

### C. WebView Controller Mocking Strategy & Interfaces
```dart
// lib/sniffer/browser_controller.dart
import 'dart:async';

abstract class SnifferBrowserController {
  Future<void> loadRequest(Uri uri);
  Future<void> setNavigationDelegate(SnifferNavigationDelegate delegate);
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode);
  Future<void> goBack();
  Future<void> goForward();
  Future<bool> canGoBack();
  Future<bool> canGoForward();
  Future<String?> currentUrl();
  Future<String?> getTitle();
  Future<void> runJavaScript(String javascript);
  Future<void> addJavaScriptChannel(
    String name, {
    required void Function(JavaScriptMessage message) onMessageReceived,
  });
}

enum JavaScriptMode { disabled, unrestricted }

class JavaScriptMessage {
  final String message;
  JavaScriptMessage({required this.message});
}

class SnifferNavigationDelegate {
  final FutureOr<NavigationDecision> Function(NavigationRequest request)? onNavigationRequest;
  final void Function(String url)? onPageStarted;
  final void Function(String url)? onPageFinished;
  final void Function(WebResourceError error)? onWebResourceError;
  final void Function(UrlChange change)? onUrlChange;
  final void Function(int progress)? onProgress;

  SnifferNavigationDelegate({
    this.onNavigationRequest,
    this.onPageStarted,
    this.onPageFinished,
    this.onWebResourceError,
    this.onUrlChange,
    this.onProgress,
  });
}

enum NavigationDecision { prevent, navigate }

class NavigationRequest {
  final String url;
  final bool isMainFrame;
  NavigationRequest({required this.url, required this.isMainFrame});
}

class WebResourceError {
  final String description;
  final int errorCode;
  WebResourceError({required this.description, required this.errorCode});
}

class UrlChange {
  final String? url;
  UrlChange({this.url});
}
```

Implementation of the Mock Controller used in tests:
```dart
// test/mocks/mock_browser_controller.dart
import 'dart:async';
import 'package:aurora_downloader/sniffer/browser_controller.dart';

class MockBrowserController implements SnifferBrowserController {
  final List<String> history = [];
  int historyIndex = -1;
  String? mockTitle;
  
  SnifferNavigationDelegate? navigationDelegate;
  JavaScriptMode javaScriptMode = JavaScriptMode.disabled;
  final Map<String, void Function(JavaScriptMessage)> jsChannels = {};
  final List<String> executedJavaScript = [];

  MockBrowserController({String? initialUrl}) {
    if (initialUrl != null) {
      history.add(initialUrl);
      historyIndex = 0;
    }
  }

  // Simulated browser engine triggers
  Future<void> simulateNavigatingTo(String url) async {
    if (navigationDelegate?.onNavigationRequest != null) {
      final decision = await navigationDelegate!.onNavigationRequest!(
        NavigationRequest(url: url, isMainFrame: true),
      );
      if (decision == NavigationDecision.prevent) return;
    }

    if (historyIndex < history.length - 1) {
      history.removeRange(historyIndex + 1, history.length);
    }
    history.add(url);
    historyIndex++;

    navigationDelegate?.onPageStarted?.call(url);
    navigationDelegate?.onProgress?.call(50);
    navigationDelegate?.onProgress?.call(100);
    navigationDelegate?.onUrlChange?.call(UrlChange(url: url));
    navigationDelegate?.onPageFinished?.call(url);
  }

  void simulateJsMessage(String channelName, String message) {
    if (jsChannels.containsKey(channelName)) {
      jsChannels[channelName]!(JavaScriptMessage(message: message));
    }
  }

  @override
  Future<void> loadRequest(Uri uri) async => simulateNavigatingTo(uri.toString());

  @override
  Future<void> setNavigationDelegate(SnifferNavigationDelegate delegate) async {
    navigationDelegate = delegate;
  }

  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {
    javaScriptMode = mode;
  }

  @override
  Future<void> goBack() async {
    if (await canGoBack()) {
      historyIndex--;
      final url = history[historyIndex];
      navigationDelegate?.onPageStarted?.call(url);
      navigationDelegate?.onUrlChange?.call(UrlChange(url: url));
      navigationDelegate?.onPageFinished?.call(url);
    }
  }

  @override
  Future<void> goForward() async {
    if (await canGoForward()) {
      historyIndex++;
      final url = history[historyIndex];
      navigationDelegate?.onPageStarted?.call(url);
      navigationDelegate?.onUrlChange?.call(UrlChange(url: url));
      navigationDelegate?.onPageFinished?.call(url);
    }
  }

  @override
  Future<bool> canGoBack() async => historyIndex > 0;

  @override
  Future<bool> canGoForward() async => historyIndex < history.length - 1;

  @override
  Future<String?> currentUrl() async => historyIndex >= 0 ? history[historyIndex] : null;

  @override
  Future<String?> getTitle() async => mockTitle ?? (historyIndex >= 0 ? "Mock Page" : null);

  @override
  Future<void> runJavaScript(String javascript) async {
    executedJavaScript.add(javascript);
  }

  @override
  Future<void> addJavaScriptChannel(
    String name, {
    required void Function(JavaScriptMessage message) onMessageReceived,
  }) async {
    jsChannels[name] = onMessageReceived;
  }
}
```

Mock Browser Widget Builder pattern for Widget testing:
```dart
// lib/sniffer/browser_widget.dart
import 'package:flutter/material.dart';
import 'browser_controller.dart';
import 'browser_controller_impl.dart';

class BrowserWidget extends StatelessWidget {
  final SnifferBrowserController controller;

  const BrowserWidget({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    if (controller is SnifferWebViewControllerImpl) {
      // Return real webview widget in production
      // return webview_flutter.WebViewWidget(controller: (controller as SnifferWebViewControllerImpl).controller);
    }
    
    // Return standard test placeholder in headless / mock tests
    return Container(
      color: Colors.black87,
      alignment: Alignment.center,
      key: const Key('mock_webview_placeholder'),
      child: FutureBuilder<String?>(
        future: controller.currentUrl(),
        builder: (context, snapshot) {
          return Text(
            'Mock WebView: ${snapshot.data ?? "about:blank"}',
            style: const TextStyle(color: Colors.white, fontSize: 16),
          );
        },
      ),
    );
  }
}
```

### D. Widget Tests for the Sniffer Screen
```dart
// test/sniffer/sniffer_screen_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aurora_downloader/sniffer/browser_controller.dart';
import 'package:aurora_downloader/sniffer/sniffer_screen.dart';
import 'package:aurora_downloader/sniffer/media_sniffer_engine.dart';
import 'package:aurora_downloader/downloader/download_queue.dart';
import '../mocks/mock_browser_controller.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

void main() {
  group('SnifferScreen Widget Tests', () {
    late MockBrowserController mockController;
    late MediaSnifferEngine snifferEngine;
    late DownloadQueue downloadQueue;

    setUp(() {
      mockController = MockBrowserController(initialUrl: 'https://google.com');
      snifferEngine = MediaSnifferEngine();
      downloadQueue = DownloadQueue(
        maxConcurrentDownloads: 1,
        httpClient: MockClient((_) async => http.Response('', 200)),
      );
    });

    tearDown(() {
      snifferEngine.dispose();
    });

    Widget createTestWidget() {
      return MaterialApp(
        home: SnifferScreen(
          controller: mockController,
          snifferEngine: snifferEngine,
          downloadQueue: downloadQueue,
        ),
      );
    }

    testWidgets('renders address bar and mock webview container', (tester) async {
      await tester.pumpWidget(createTestWidget());
      await tester.pump();

      // Verify URL text in address bar
      final addressField = find.byType(TextField);
      expect(addressField, findsOneWidget);
      expect(tester.widget<TextField>(addressField).controller?.text, 'https://google.com');

      // Verify the WebView placeholder is shown instead of real native WebView
      expect(find.byKey(const Key('mock_webview_placeholder')), findsOneWidget);
      expect(find.textContaining('Mock WebView: https://google.com'), findsOneWidget);
    });

    testWidgets('submitting new URL updates controllers and navigation stack', (tester) async {
      await tester.pumpWidget(createTestWidget());
      await tester.pump();

      final addressField = find.byType(TextField);
      await tester.enterText(addressField, 'https://example.com');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pumpAndSettle();

      // Navigation has been triggered
      expect(mockController.historyIndex, 1);
      expect(mockController.history[1], 'https://example.com');
    });

    testWidgets('triggers media sniff popup upon receiving javascript channel signals', (tester) async {
      await tester.pumpWidget(createTestWidget());
      await tester.pump();

      // Ensure panel is not visible initially
      expect(find.byKey(const Key('media_sniffer_panel')), findsNothing);

      // Simulate a JS payload sniffed from the page
      mockController.simulateJsMessage(
        'SnifferChannel',
        '{"type":"media_element","url":"https://example.com/video.mp4","title":"Cool Video"}',
      );
      await tester.pumpAndSettle();

      // The media sniff list panel should appear showing the movie filename and details
      expect(find.byKey(const Key('media_sniffer_panel')), findsOneWidget);
      expect(find.text('video.mp4'), findsOneWidget);
      expect(find.text('Cool Video'), findsOneWidget);
    });

    testWidgets('downloads sniffed media item and adds to queue with configurations', (tester) async {
      await tester.pumpWidget(createTestWidget());
      await tester.pump();

      // Sniff media
      mockController.simulateJsMessage(
        'SnifferChannel',
        '{"type":"media_element","url":"https://example.com/video.mp4","title":"Cool Video"}',
      );
      await tester.pumpAndSettle();

      // Tap download button of item
      final downloadBtn = find.byKey(const Key('btn_download_video.mp4'));
      await tester.tap(downloadBtn);
      await tester.pumpAndSettle();

      // Alert dialog to verify download settings should display
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Add to Download Queue'), findsOneWidget);

      // Tap confirm button
      final confirmBtn = find.byKey(const Key('btn_dialog_confirm'));
      await tester.tap(confirmBtn);
      await tester.pumpAndSettle();

      // Screen should dismiss dialog and enqueue the new download task
      expect(find.byType(AlertDialog), findsNothing);
      expect(downloadQueue.queuedTasks.length + downloadQueue.activeTasks.length, 1);
      expect(downloadQueue.queuedTasks.first.url, 'https://example.com/video.mp4');
    });
  });
}
```

## 5. Verification Method
1. Run `flutter test` from the terminal root (`D:\02_Projects\Final_52191314_Server_and_Apps\aurora_downloader`) once these files are implemented to verify clean runs on the command-line without launching simulators.
2. Confirm the absence of any platform exception warnings on CLI tests.

# Milestone 3 Design Recommendation: Browser & Media Sniffer

This report provides the analysis and design recommendations for Milestone 3 (Browser & Media Sniffer) of the Aurora Downloader project. It evaluates package compatibility, controller configuration for resource interception, and the architecture of the media and document sniffer engine.

---

## 1. Observation
I have conducted direct checks in the Flutter project environment using the available CLI tools. Here are the verbatim findings:

1. **Dependency Compatibility (Dry Run):**
   Running `flutter pub add webview_flutter --dry-run` succeeded and resolved dependencies:
   - `webview_flutter 4.13.1`
   - `webview_flutter_android 4.10.1`
   - `webview_flutter_platform_interface 2.14.0`
   - `webview_flutter_wkwebview 3.23.0`

   Running `flutter pub add flutter_inappwebview --dry-run` also succeeded and resolved dependencies:
   - `flutter_inappwebview 6.1.5`
   - `flutter_inappwebview_android 1.1.3`
   - `flutter_inappwebview_ios 1.1.2`
   - `flutter_inappwebview_platform_interface 1.3.0+1`

2. **Android Environment Configuration (`android/app/build.gradle.kts` & SDK Constants):**
   - In `android/settings.gradle.kts`, the Android Gradle Plugin (AGP) version is configured as `8.7.3` and Kotlin plugin version is `2.1.0`.
   - In `android/app/build.gradle.kts`, SDK versions are bound to the Flutter Gradle Plugin properties:
     ```kotlin
     minSdk = flutter.minSdkVersion
     targetSdk = flutter.targetSdkVersion
     compileSdk = flutter.compileSdkVersion
     ```
   - In the Flutter SDK's `FlutterExtension.kt` (located at `C:\Users\52191314\flutter\flutter\packages\flutter_tools\gradle\src\main\kotlin\FlutterExtension.kt`), the default SDK targets are defined as:
     - `compileSdkVersion: 35`
     - `minSdkVersion: 21`
     - `targetSdkVersion: 35`

---

## 2. Logic Chain
Based on the observations above, I evaluated the suitability and compilation profiles of the packages and drafted the sniffer engine's architecture:

### Package Selection & Compile Analysis
- **Minimum SDK Matches:** Both `webview_flutter` (requires `minSdkVersion 19`) and `flutter_inappwebview` (requires `minSdkVersion 21`) are fully supported because the project's default `minSdkVersion` is **21**.
- **Build Configurations:** The modern Gradle plugin and Kotlin versions (AGP 8.7.3, Kotlin 2.1.0) match the requirements for both libraries. Since both dry runs completed successfully with no dependency conflicts, both packages are technically capable of compiling in this environment.
- **Interception Comparison:**
  - **`webview_flutter`:**
    - *Pros:* Official Flutter team package; lightweight.
    - *Cons:* No native subresource loading interception. You cannot catch `.m3u8` or `.mpd` requests natively. Intercepting media requires injecting JavaScript hacks that override `window.fetch` and `XMLHttpRequest`, or using `MutationObserver` on `<video>` tags. It also lacks a native `onDownloadStart` hook.
  - **`flutter_inappwebview` (Recommended):**
    - *Pros:* Extremely rich feature set. It supports native callbacks for subresource loading (`onLoadResource`), AJAX requests (`onAjaxReadyStateChange`), fetch requests (`onFetchRequest`), and direct download requests (`onDownloadStartRequest`). This makes media sniffing robust, performant, and resistant to client-side JS blocking.
    - *Cons:* Larger library size compared to `webview_flutter`.

**Recommendation:** I strongly recommend **`flutter_inappwebview`** for the sniffer interface due to its native interception capabilities, with **`webview_flutter`** as a fallback design.

---

## 3. Caveats
- **Testing Restrictions:** As I operate under a read-only investigation constraint ("Write only to your folder"), I did not modify `pubspec.yaml` to run a full physical compilation check. However, the dry run and environment audit provide a high degree of confidence.
- **Platform Limitations:** Since `flutter_inappwebview` relies heavily on Android/iOS native WebViews, any desktop-focused builds (Windows/macOS) will have limited sniffing support unless custom desktop platforms are specifically targeted and configured.
- **Dynamic Stream URLs:** Some media websites (e.g., YouTube) obfuscate media URLs or serve video/audio in separate streams (DASH). Standard Sniffer patterns will catch the stream manifest (`.m3u8` or `.mpd`), but direct video downloads may require a post-processing engine.

---

## 4. Conclusion & Proposed Design

I propose a unified **Sniffer Engine Architecture** that operates on top of the WebView. The design is modular, separating the interception mechanism from the matching rules.

### A. WebView Controller Configurations

#### Option 1: Native Interception (Recommended - `flutter_inappwebview`)
```dart
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class InAppSnifferWebView extends StatelessWidget {
  final String initialUrl;
  final Function(SniffedResource) onResourceSniffed;

  const InAppSnifferWebView({
    super.key, 
    required this.initialUrl, 
    required this.onResourceSniffed,
  });

  @override
  Widget build(BuildContext context) {
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(initialUrl)),
      initialSettings: InAppWebViewSettings(
        mediaPlaybackRequiresUserGesture: false,
        useShouldOverrideUrlLoading: true,
        useOnLoadResource: true,
        useOnDownloadStart: true,
      ),
      shouldOverrideUrlLoading: (controller, navigationAction) async {
        final url = navigationAction.request.url?.toString() ?? '';
        if (SnifferEngine.instance.shouldIntercept(url)) {
          final resource = await SnifferEngine.instance.sniffUrl(url);
          if (resource != null) {
            onResourceSniffed(resource);
            return NavigationActionPolicy.CANCEL; // Prevent navigation, handoff to downloader
          }
        }
        return NavigationActionPolicy.ALLOW;
      },
      onLoadResource: (controller, resource) {
        final url = resource.url?.toString() ?? '';
        final mimeType = resource.initiatorType; // Check initiator
        if (SnifferEngine.instance.shouldIntercept(url)) {
          SnifferEngine.instance.sniffUrl(url).then((sniffed) {
            if (sniffed != null) onResourceSniffed(sniffed);
          });
        }
      },
      onDownloadStartRequest: (controller, downloadStartRequest) async {
        final url = downloadStartRequest.url.toString();
        final mimeType = downloadStartRequest.mimeType;
        final contentDisposition = downloadStartRequest.contentDisposition;
        
        final resource = SniffedResource(
          url: url,
          mimeType: mimeType,
          category: SnifferEngine.instance.categorizeMimeType(mimeType),
          filename: SnifferEngine.instance.extractFilename(url, contentDisposition),
        );
        onResourceSniffed(resource);
      },
    );
  }
}
```

#### Option 2: Hybrid JS-Injection Interception (Backup - `webview_flutter`)
If `webview_flutter` must be used, we inject JavaScript to override request methods:
```dart
import 'package:webview_flutter/webview_flutter.dart';

class FlutterSnifferWebView extends StatefulWidget {
  final String initialUrl;
  final Function(SniffedResource) onResourceSniffed;

  const FlutterSnifferWebView({
    super.key,
    required this.initialUrl,
    required this.onResourceSniffed,
  });

  @override
  State<FlutterSnifferWebView> createState() => _FlutterSnifferWebViewState();
}

class _FlutterSnifferWebViewState extends State<FlutterSnifferWebView> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'SnifferChannel',
        onMessageReceived: (JavaScriptMessage message) {
          // JS sent payload containing resource details
          final url = message.message;
          if (SnifferEngine.instance.shouldIntercept(url)) {
            SnifferEngine.instance.sniffUrl(url).then((resource) {
              if (resource != null) widget.onResourceSniffed(resource);
            });
          }
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (NavigationRequest request) async {
            final url = request.url;
            if (SnifferEngine.instance.shouldIntercept(url)) {
              final resource = await SnifferEngine.instance.sniffUrl(url);
              if (resource != null) {
                widget.onResourceSniffed(resource);
                return NavigationDecision.prevent; // Prevent navigation
              }
            }
            return NavigationDecision.navigate;
          },
          onPageFinished: (String url) {
            // Inject AJAX & Fetch Hook
            _controller.runJavaScript('''
              (function() {
                // Intercept XHR
                const open = XMLHttpRequest.prototype.open;
                XMLHttpRequest.prototype.open = function(method, url) {
                  this.addEventListener("readystatechange", function() {
                    if (this.readyState === 4) {
                      SnifferChannel.postMessage(url);
                    }
                  });
                  open.apply(this, arguments);
                };
                
                // Intercept Fetch
                const originalFetch = window.fetch;
                window.fetch = function(input, init) {
                  const url = typeof input === 'string' ? input : input.url;
                  SnifferChannel.postMessage(url);
                  return originalFetch.apply(this, arguments);
                };

                // Watch for dynamically added media elements (video/source)
                const observer = new MutationObserver((mutations) => {
                  mutations.forEach((m) => {
                    m.addedNodes.forEach((node) => {
                      if (node.tagName === 'VIDEO' || node.tagName === 'SOURCE') {
                        if (node.src) SnifferChannel.postMessage(node.src);
                      }
                    });
                  });
                });
                observer.observe(document.body, { childList: true, subtree: true });
              })();
            ''');
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.initialUrl));
  }

  @override
  Widget build(BuildContext context) {
    return WebViewWidget(controller: _controller);
  }
}
```

---

### B. Sniffer Engine & Rules Design

The sniffer engine coordinates rule matching and resource resolution:

```dart
enum ResourceCategory {
  media,
  document,
  archive,
  unknown,
}

class SniffedResource {
  final String url;
  final String filename;
  final ResourceCategory category;
  final String? mimeType;
  final int? contentLength;
  final Map<String, String>? headers;

  SniffedResource({
    required this.url,
    required this.filename,
    required this.category,
    this.mimeType,
    this.contentLength,
    this.headers,
  });
}

class SnifferRule {
  final String name;
  final RegExp pattern;
  final ResourceCategory category;
  final List<String> mimeTypes;

  const SnifferRule({
    required this.name,
    required this.pattern,
    required this.category,
    this.mimeTypes = const [],
  });
}

class SnifferEngine {
  SnifferEngine._privateConstructor() {
    _loadDefaultRules();
  }
  static final SnifferEngine instance = SnifferEngine._privateConstructor();

  final List<SnifferRule> _rules = [];

  void _loadDefaultRules() {
    // 1. Media Rules (.mp4, .m3u8, .mp3, etc.)
    _rules.add(SnifferRule(
      name: 'hls_m3u8',
      pattern: RegExp(r'\.m3u8(?:\?|$)', caseSensitive: false),
      category: ResourceCategory.media,
      mimeTypes: ['application/x-mpegurl', 'application/vnd.apple.mpegurl'],
    ));
    _rules.add(SnifferRule(
      name: 'dash_mpd',
      pattern: RegExp(r'\.mpd(?:\?|$)', caseSensitive: false),
      category: ResourceCategory.media,
      mimeTypes: ['application/dash+xml'],
    ));
    _rules.add(SnifferRule(
      name: 'mp4_video',
      pattern: RegExp(r'\.mp4(?:\?|$)', caseSensitive: false),
      category: ResourceCategory.media,
      mimeTypes: ['video/mp4'],
    ));
    _rules.add(SnifferRule(
      name: 'mp3_audio',
      pattern: RegExp(r'\.mp3(?:\?|$)', caseSensitive: false),
      category: ResourceCategory.media,
      mimeTypes: ['audio/mpeg'],
    ));

    // 2. Document Rules (.pdf, .doc, .docx, .xls, .xlsx, .epub)
    _rules.add(SnifferRule(
      name: 'pdf_document',
      pattern: RegExp(r'\.pdf(?:\?|$)', caseSensitive: false),
      category: ResourceCategory.document,
      mimeTypes: ['application/pdf'],
    ));
    _rules.add(SnifferRule(
      name: 'word_document',
      pattern: RegExp(r'\.docx?(?:\?|$)', caseSensitive: false),
      category: ResourceCategory.document,
      mimeTypes: ['application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'],
    ));
    _rules.add(SnifferRule(
      name: 'excel_document',
      pattern: RegExp(r'\.xlsx?(?:\?|$)', caseSensitive: false),
      category: ResourceCategory.document,
      mimeTypes: ['application/vnd.ms-excel', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'],
    ));

    // 3. Archive Rules (.zip, .rar, .7z)
    _rules.add(SnifferRule(
      name: 'archives',
      pattern: RegExp(r'\.(zip|rar|7z|tar|gz)(?:\?|$)', caseSensitive: false),
      category: ResourceCategory.archive,
      mimeTypes: ['application/zip', 'application/x-rar-compressed', 'application/x-7z-compressed'],
    ));
  }

  bool shouldIntercept(String url) {
    for (final rule in _rules) {
      if (rule.pattern.hasMatch(url)) return true;
    }
    return false;
  }

  ResourceCategory categorizeMimeType(String? mimeType) {
    if (mimeType == null) return ResourceCategory.unknown;
    final lower = mimeType.toLowerCase();
    for (final rule in _rules) {
      if (rule.mimeTypes.contains(lower)) return rule.category;
    }
    return ResourceCategory.unknown;
  }

  String extractFilename(String url, String? contentDisposition) {
    // 1. Try Content-Disposition header
    if (contentDisposition != null) {
      final filenameMatch = RegExp(r'filename="?([^";]+)"?', caseSensitive: false)
          .firstMatch(contentDisposition);
      if (filenameMatch != null && filenameMatch.group(1) != null) {
        return Uri.decodeFull(filenameMatch.group(1)!);
      }
    }
    // 2. Fallback to URL path segment
    try {
      final uri = Uri.parse(url);
      final lastSegment = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : 'downloaded_file';
      return Uri.decodeFull(lastSegment);
    } catch (_) {
      return 'downloaded_file';
    }
  }

  Future<SniffedResource?> sniffUrl(String url, {Map<String, String>? headers}) async {
    // Match URL extensions
    for (final rule in _rules) {
      if (rule.pattern.hasMatch(url)) {
        return SniffedResource(
          url: url,
          filename: extractFilename(url, null),
          category: rule.category,
          headers: headers,
        );
      }
    }
    return null;
  }
}
```

---

## 5. Verification Method
To verify the design without writing runtime application files:

1. **Unit Test Verification:**
   Create a test file `test/sniffer_test.dart` to verify that the `SnifferEngine` accurately matches URLs, extracts filenames from headers/paths, and assigns correct categories:
   ```dart
   import 'package:flutter_test/flutter_test.dart';
   import 'package:aurora_downloader/downloader/models.dart'; // Assume integration here
   // Import Sniffer engine when implemented

   void main() {
     test('SnifferEngine correctly detects file types and categorizes them', () async {
       final engine = SnifferEngine.instance;
       
       expect(engine.shouldIntercept('https://example.com/video.mp4?token=123'), isTrue);
       expect(engine.shouldIntercept('https://example.com/doc.pdf'), isTrue);
       expect(engine.shouldIntercept('https://example.com/index.html'), isFalse);

       final pdfResource = await engine.sniffUrl('https://example.com/report.pdf');
       expect(pdfResource?.category, ResourceCategory.document);
       expect(pdfResource?.filename, 'report.pdf');

       final m3u8Resource = await engine.sniffUrl('https://example.com/master.m3u8?session=abc');
       expect(m3u8Resource?.category, ResourceCategory.media);
       expect(m3u8Resource?.filename, 'master.m3u8');
     });

     test('SnifferEngine extracts filename from content-disposition', () {
       final engine = SnifferEngine.instance;
       final filename = engine.extractFilename(
         'https://example.com/api/download?id=123',
         'attachment; filename="Quarterly_Report.zip"',
       );
       expect(filename, 'Quarterly_Report.zip');
     });
   }
   ```
   Run the tests using `flutter test test/sniffer_test.dart` to assert correct behavior.

2. **Integration Verification:**
   Build the project in debug mode (`flutter build apk --debug`) after adding either of the packages to check that compiler linkages are fully verified.

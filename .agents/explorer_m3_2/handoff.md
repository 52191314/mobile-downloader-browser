# Explorer Handoff Report — Milestone 3: Browser & Media Sniffer Design

## 1. Observation
The following observations were made after examining the existing codebase:
* **Current Dependencies**:
  In `D:\02_Projects\Final_52191314_Server_and_Apps\aurora_downloader\pubspec.yaml`, the current dependencies are:
  ```yaml
  dependencies:
    flutter:
      sdk: flutter
    cupertino_icons: ^1.0.8
    http: ^1.3.0
    crypto: ^3.0.6
    path_provider: ^2.1.5
    path: ^1.9.1
  ```
  No WebView plugin (such as `flutter_inappwebview`) is currently declared.

* **DownloadTask Definition**:
  In `D:\02_Projects\Final_52191314_Server_and_Apps\aurora_downloader\lib\downloader\models.dart`, the `DownloadTask` class defines properties like `url`, `savePath`, `tempDir`, `priority`, etc., but **lacks a property to store HTTP request headers** (like `User-Agent`, `Cookie`, or `Referer`).

* **Network Requests in DownloadSplitter**:
  In `D:\02_Projects\Final_52191314_Server_and_Apps\aurora_downloader\lib\downloader\download_splitter.dart`, network requests are executed without using any request headers (other than the `Range` headers for partial content):
  * Line 65: `final headResponse = await client.head(Uri.parse(task.url));`
  * Line 88-89: 
    ```dart
    final getRequest = http.Request('GET', Uri.parse(task.url));
    getRequest.headers['Range'] = 'bytes=0-0';
    ```
  * Line 281-284:
    ```dart
    final request = http.Request('GET', Uri.parse(task.url));
    if (rangeSupported) {
      request.headers['Range'] = 'bytes=$rangeStart-$rangeEnd';
    }
    ```

* **Lack of Sniffer Components**:
  There are currently no existing classes or utilities in the project handling WebView page navigation, resource loading interception, or stream emission for detected media links.

---

## 2. Logic Chain
1. **Header Requirement for Media Downloads**: Many media hosting servers and content delivery networks (CDNs) enforce session-based security (Cookies), origin verification (Referer), or block non-browser requests (User-Agent). Without passing these headers, a download client attempting to request the media will fail with HTTP 403 Forbidden or 401 Unauthorized errors.
2. **Missing Request Header Support**: Because `DownloadTask` in `models.dart` does not support storing headers and `DownloadSplitter` in `download_splitter.dart` does not transmit custom headers, any media intercepted by the sniffer that requires cookies/referer information cannot be downloaded with the current system.
3. **Requirement to Extend Models**: We must modify `DownloadTask` and `DownloadSplitter` to accept and transmit a `Map<String, String>? headers` property.
4. **Sniffer Implementation Strategy**: We must introduce a WebView integration (preferably using `flutter_inappwebview` because of its advanced resource-loading callbacks and request interception features) and hook it up to a stream interface (`MediaSnifferService`) that broadcasts detected URLs wrapped in a model containing their request headers.
5. **Deduplication Strategy**: Video requests are often chunked (like HLS/DASH loading multiple `.ts` or `.m4s` segments). Directly streaming each chunk would flood the UI. Thus, the sniffer service must include a deduplication mechanism to filter out repeat URLs or segment series within a configurable time window.
6. **Download Queue Integration**: A contract method is needed to easily convert a `SniffedMedia` model into a standard `DownloadTask` with the proper folder paths, filename, and custom headers, before adding it to the `DownloadQueue`.

---

## 3. Caveats
* **Platform Support Limitations**: While `flutter_inappwebview` is feature-rich on mobile (Android and iOS), its features for resource interception and download triggers may have limited support or require different handling on desktop (Windows, macOS) or web environments.
* **Complex Streaming Protocols**: Simple file downloading via `DownloadSplitter` works for monolithic media files (like `.mp4`, `.pdf`). Dynamic stream formats like adaptive HLS (`.m3u8`) or DASH (`.mpd`) cannot be directly downloaded as single files by standard range requests and would require an external parser/downloader library. Therefore, the UI should indicate if a detected resource is a playlist stream and handle it appropriately.

---

## 4. Conclusion & Proposed Design

We recommend a clean design separating the **Sniffer Layer**, the **Integration Bridge**, and the **UI Dialog**.

### A. Sniffer Stream Interface Design

We propose adding `flutter_inappwebview: ^6.1.5` to `pubspec.yaml`.

#### 1. The `SniffedMedia` Model
Add this to the models folder to represent a detected downloadable asset:
```dart
class SniffedMedia {
  final String url;
  final String filename;
  final String? mimeType;
  final int? contentLength;
  final Map<String, String> headers; // Crucial: Cookie, User-Agent, Referer
  final String pageUrl;
  final String? pageTitle;
  final DateTime timestamp;

  SniffedMedia({
    required this.url,
    required this.filename,
    this.mimeType,
    this.contentLength,
    required this.headers,
    required this.pageUrl,
    this.pageTitle,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  bool get isVideo => mimeType?.startsWith('video/') ?? _hasExtension(['.mp4', '.mkv', '.webm', '.avi', '.mov', '.flv', '.m3u8', '.mpd']);
  bool get isAudio => mimeType?.startsWith('audio/') ?? _hasExtension(['.mp3', '.wav', '.m4a', '.ogg', '.flac']);
  bool get isDocument => mimeType == 'application/pdf' || _hasExtension(['.pdf', '.epub']);

  bool _hasExtension(List<String> extensions) {
    final path = Uri.parse(url).path.toLowerCase();
    return extensions.any((ext) => path.endsWith(ext));
  }
}
```

#### 2. The `MediaSnifferService`
Exposes the detection stream and handles filtering/deduplication:
```dart
import 'dart:async';
import 'package:path/path.dart' as p;
import 'models.dart';

class MediaSnifferService {
  final StreamController<SniffedMedia> _snifferController =
      StreamController<SniffedMedia>.broadcast();

  Stream<SniffedMedia> get onMediaDetected => _snifferController.stream;

  // Deduplication cache to prevent UI flooding
  final Set<String> _detectedUrls = {};
  final Duration deduplicationWindow = const Duration(seconds: 10);

  void reset() {
    _detectedUrls.clear();
  }

  void processInterception({
    required String url,
    required Map<String, String> headers,
    required String pageUrl,
    String? pageTitle,
    String? mimeType,
    int? contentLength,
  }) {
    // Normalise/Filter extensions
    if (!_shouldSniff(url, mimeType)) return;

    // Deduplicate
    final cleanUrl = _normalizeUrl(url);
    if (_detectedUrls.contains(cleanUrl)) return;
    _detectedUrls.add(cleanUrl);

    // Invalidate URL from cache after window expires
    Timer(deduplicationWindow, () => _detectedUrls.remove(cleanUrl));

    final filename = _extractFilename(url, mimeType);
    final media = SniffedMedia(
      url: url,
      filename: filename,
      mimeType: mimeType,
      contentLength: contentLength,
      headers: headers,
      pageUrl: pageUrl,
      pageTitle: pageTitle,
    );

    _snifferController.add(media);
  }

  bool _shouldSniff(String url, String? mimeType) {
    if (mimeType != null) {
      final mt = mimeType.toLowerCase();
      if (mt.startsWith('video/') ||
          mt.startsWith('audio/') ||
          mt == 'application/pdf' ||
          mt == 'application/octet-stream' ||
          mt == 'application/zip') {
        return true;
      }
    }

    final path = Uri.parse(url).path.toLowerCase();
    final mediaExtensions = {
      '.mp4', '.mkv', '.webm', '.avi', '.mov', '.flv', // Video
      '.mp3', '.wav', '.m4a', '.ogg', '.flac', '.aac', // Audio
      '.pdf', '.epub', '.docx', '.xlsx', '.pptx',      // Documents
      '.zip', '.rar', '.7z', '.tar.gz',                // Archives
      '.apk', '.dmg', '.exe', '.msi',                  // Executables
      '.m3u8', '.mpd'                                  // Streaming playlists
    };
    return mediaExtensions.any((ext) => path.endsWith(ext));
  }

  String _normalizeUrl(String url) {
    // Remove query parameters to identify duplicate streams
    final uri = Uri.parse(url);
    return '${uri.scheme}://${uri.host}${uri.path}';
  }

  String _extractFilename(String url, String? mimeType) {
    final uri = Uri.parse(url);
    String filename = p.basename(uri.path);
    if (filename.isEmpty || !filename.contains('.')) {
      final ext = _getExtensionFromMime(mimeType) ?? '.bin';
      filename = 'download_${DateTime.now().millisecondsSinceEpoch}$ext';
    }
    return Uri.decodeFull(filename);
  }

  String? _getExtensionFromMime(String? mimeType) {
    if (mimeType == null) return null;
    switch (mimeType.toLowerCase()) {
      case 'application/pdf': return '.pdf';
      case 'application/zip': return '.zip';
      case 'video/mp4': return '.mp4';
      case 'audio/mpeg': return '.mp3';
      default: return null;
    }
  }

  void dispose() {
    _snifferController.close();
  }
}
```

#### 3. WebView Interception Hookup
Inside the UI's WebView screen:
```dart
InAppWebView(
  initialUrlRequest: URLRequest(url: WebUri("https://example.com")),
  onLoadResource: (controller, resource) {
    final url = resource.url?.toString();
    if (url != null) {
      // Capture current cookies and user-agent
      final headers = {
        'User-Agent': 'Mozilla/5.0 ...', // Or query from controller
        'Referer': controller.getUrl().toString(),
      };
      
      // Pass resource to sniffer service
      snifferService.processInterception(
        url: url,
        headers: headers,
        pageUrl: controller.getUrl().toString(),
        pageTitle: pageTitle,
      );
    }
  },
  onDownloadStartRequest: (controller, downloadStartRequest) {
    // Explicit downloads
    final headers = {
      'User-Agent': downloadStartRequest.userAgent ?? '',
      'Referer': controller.getUrl().toString(),
    };
    
    snifferService.processInterception(
      url: downloadStartRequest.url.toString(),
      headers: headers,
      pageUrl: controller.getUrl().toString(),
      mimeType: downloadStartRequest.mimeType,
      contentLength: downloadStartRequest.contentLength,
    );
  },
)
```

---

### B. Download Queue & Sniffer Integration Contract

#### 1. Core Model Changes
Extend `DownloadTask` to support custom headers:
```dart
// lib/downloader/models.dart
class DownloadTask implements Comparable<DownloadTask> {
  ...
  final Map<String, String>? headers; // Add property
  
  DownloadTask({
    required this.id,
    required this.url,
    required this.savePath,
    required this.tempDir,
    this.headers, // Optional parameter
    ...
  });

  Map<String, dynamic> toJson() => {
    ...
    'headers': headers,
  };
  
  // Update fromJson accordingly
}
```

Update `DownloadSplitter` to write the headers:
```dart
// In _probeServerAndInit:
final headRequest = http.Request('HEAD', Uri.parse(task.url));
if (task.headers != null) {
  headRequest.headers.addAll(task.headers!);
}
final headResponse = await client.send(headRequest); // Switch to sending Request for consistency

// In _downloadChunk:
final request = http.Request('GET', Uri.parse(task.url));
if (task.headers != null) {
  request.headers.addAll(task.headers!);
}
if (rangeSupported) {
  request.headers['Range'] = 'bytes=$rangeStart-$rangeEnd';
}
```

#### 2. Bridge Method
Create a service class helper `DownloadBridge` to instantiate tasks:
```dart
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../downloader/downloader.dart';
import 'models.dart';

class DownloadBridge {
  static Future<DownloadTask> createDownloadTaskFromSniffedMedia({
    required SniffedMedia media,
    required String customFilename,
    required DownloadPriority priority,
  }) async {
    final downloadsDir = await getApplicationDocumentsDirectory(); // Or other public downloads folder
    final taskId = DateTime.now().millisecondsSinceEpoch.toString();
    
    final savePath = p.join(downloadsDir.path, customFilename);
    final tempDir = p.join(downloadsDir.path, '.temp_$taskId');

    return DownloadTask(
      id: taskId,
      url: media.url,
      savePath: savePath,
      tempDir: tempDir,
      priority: priority,
      headers: media.headers,
    );
  }
}
```

#### 3. One-Tap Download Bottom Sheet Design
We recommend displaying a sleek, Nordic Dark-themed bottom sheet overlay when a user clicks the floating sniffer action button or automatically (optional, based on settings).

**Layout Specifications**:
* **Header**: File category icon (e.g. video, document, zip) alongside the title: `"Sniffed Media Detected"`.
* **Filename Field**: A `TextField` displaying the extracted `media.filename`, allowing the user to edit it before downloading.
* **URL Preview**: Text displaying the domain and path (truncated with an option to copy the full URL).
* **Storage Path Row**: Displays the destination directory, with a "Change Folder" button.
* **Priority Selector**: A Segmented Control or toggle row allowing choice between Low, Medium, and High priority (maps to `DownloadPriority`).
* **Metadata Information**: Text widgets showing estimated size (if Content-Length is available) or MIME type.
* **Action Row**:
  * `"Download Now"` (Primary button): Calls `DownloadBridge` to instantiate the task, adds it to `DownloadQueue` via `addTask`, starts download, and dismisses the bottom sheet.
  * `"Queue for Later"` (Secondary button): Creates the task but adds it to the queue in a paused/idle state for later retrieval.
  * `"Cancel"` (Text button): Closes sheet.

---

## 5. Verification Method
* **Unit Tests**:
  Upon implementation, verify that `DownloadTask` serializes and deserializes the `headers` field properly by running the test suite:
  ```bash
  flutter test test/downloader_test.dart
  ```
* **Visual QA**:
  Using the mock environment or integration harness, confirm that calling `MediaSnifferService.processInterception` streams the expected values and opens the Bottom Sheet containing the correct file size and filename.
* **Invalidation Condition**:
  If a media file download fails with HTTP 403 or 401 when using the proposed design, inspect the headers inside the `DownloadTask` to verify that cookies and user-agent strings are successfully populated.

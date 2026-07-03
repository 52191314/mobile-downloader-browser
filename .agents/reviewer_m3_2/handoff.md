# Handoff Report — Milestone 3 Review (Reviewer 2)

## 1. Observation

### A. Deduplication Cache and Resource Disposal
In `lib/sniffer/media_sniffer_engine.dart`:
- The cache and detected media lists are stored as member fields without eviction or size limits:
```dart
  final List<SniffedMedia> _detectedMedia = [];
  List<SniffedMedia> get detectedMedia => List.unmodifiable(_detectedMedia);

  final Set<String> _urlCache = {};
```
- In `lib/sniffer/media_sniffer_engine.dart`, the `sniff(String url)` method simply adds URLs to `_urlCache` and items to `_detectedMedia` without any Timer, max-size clamp, or sliding-window pruning:
```dart
  void sniff(String url) {
    if (url.isEmpty) return;

    // De-duplication cache logic
    if (_urlCache.contains(url)) {
      return;
    }
    // ... matches type ...
    if (type != null) {
      _urlCache.add(url);
      final filename = _extractFilename(url);
      final item = SniffedMedia(
        url: url,
        name: filename,
        type: type,
      );
      _detectedMedia.add(item);
      _mediaDetectedController.add(item);
    }
  }
```
- In `lib/sniffer/sniffer_screen.dart`, there is no `dispose()` method in the state class `_SnifferScreenState` to dispose of `_snifferEngine`, which holds a broadcast `StreamController`:
```dart
class _SnifferScreenState extends State<SnifferScreen> {
  late final SnifferBrowserController _controller;
  late final DownloadQueue _downloadQueue;
  late final MediaSnifferEngine _snifferEngine;
  // ... initState and other methods ...
  // No override of dispose() is present
```

### B. Adblocker Implementation
In `lib/sniffer/browser_controller.dart`:
- The `shouldBlockUrl` method checks domain matches using `host.contains(adDomain)` and catches `Uri.parse` errors by returning `false`:
```dart
  @override
  bool shouldBlockUrl(String url) {
    if (!_adBlockerEnabled) return false;
    try {
      final uri = Uri.parse(url);
      final host = uri.host.toLowerCase();
      final adDomains = [
        'doubleclick.net',
        'adcolony.com',
        'googleads.g.doubleclick.net',
        'ads.google.com',
        'popads.net',
      ];
      for (final adDomain in adDomains) {
        if (host == adDomain || host.endsWith('.$adDomain') || host.contains(adDomain)) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }
```
- In `lib/sniffer/browser_controller.dart`, blocking is only applied in the main-frame navigation request delegate:
```dart
        onNavigationRequest: (NavigationRequest request) {
          if (shouldBlockUrl(request.url)) {
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
```

### C. Headers Extraction & Filename Handling
In `lib/downloader/download_splitter.dart`:
- The `_probeServerAndInit` method forwards custom headers but completely ignores server-returned headers for file naming (such as `Content-Disposition`):
```dart
    final headResponse = await client.head(Uri.parse(task.url), headers: task.headers);
    final contentLengthHeader =
        headResponse.headers['content-length'] ?? headResponse.headers['Content-Length'];
    final acceptRangesHeader =
        headResponse.headers['accept-ranges'] ?? headResponse.headers['Accept-Ranges'];
    final etagHeader = headResponse.headers['etag'] ?? headResponse.headers['ETag'];
    final lastModifiedHeader =
        headResponse.headers['last-modified'] ?? headResponse.headers['Last-Modified'];
```
- The filename is exclusively obtained via path segments parsing:
```dart
  String _extractFilename(String url) {
    try {
      final uri = Uri.parse(url);
      final pathSegments = uri.pathSegments;
      if (pathSegments.isNotEmpty) {
        final lastSegment = pathSegments.last;
        if (lastSegment.isNotEmpty) {
          return Uri.decodeComponent(lastSegment);
        }
      }
    } catch (_) {}
    return 'downloaded_file';
  }
```

### D. Test Suite Results
Executing `flutter test` completes successfully:
```
00:23 +37: All tests passed!
```

---

## 2. Logic Chain

1. **Memory & Resource Leak (Sniffer Engine)**:
   - In `sniffer_screen.dart`, when `SnifferScreen` is opened, it instantiates `MediaSnifferEngine` inside `initState()`.
   - Because `_SnifferScreenState` does not override `dispose()`, the `_snifferEngine.dispose()` method is never executed when the screen is closed.
   - Consequently, the broadcast `StreamController` in `MediaSnifferEngine` remains open, causing a stream leak.
2. **Infinite Memory Cache Growth**:
   - As a user browses, every detected media URL is permanently added to `_urlCache` and `_detectedMedia` in the engine.
   - Without an eviction policy or timer-based pruning, this cache grows infinitely, leading to unbounded memory consumption for long browsing sessions.
3. **Adblocker Over-blocking & Bypass**:
   - Using `host.contains(adDomain)` inside `shouldBlockUrl` matches safe hosts that happen to contain the blocked strings (e.g. `my-doubleclick.net` is incorrectly blocked).
   - If a URL is malformed, `Uri.parse(url)` throws. The `try-catch` block catches this and returns `false`, bypassing the adblocker rules and letting the malformed navigation proceed.
   - The adblocker only registers inside `onNavigationRequest` of `NavigationDelegate`. This only blocks main-frame redirects and manual navigation. Subresources (images, banners, scripts, iframes) loaded directly by the page are NOT intercepted or blocked, rendering the adblocker ineffective for page-embedded ads.
4. **Header and Filename Resolution Restrictions**:
   - `MediaSnifferEngine` determines filenames solely by regex parsing the URL path segments. It does not probe the server. If the server serves media from a generic API route (e.g., `/get_file?id=5`) with `Content-Disposition`, the sniffer will either ignore the URL (because it doesn't match extension-based regexes) or fall back to the name `downloaded_file`.
   - The downloader (`download_splitter.dart`) does not parse the `Content-Disposition` header from `headResponse.headers` to update the task's filename, missing a standard feature.

---

## 3. Caveats

- Unit tests run in a mock environment using `MockBrowserController`. They do not render a real native web view. Hence, the lack of subresource interception is not caught by the widget tests (which only simulate navigation calls and JS message injections).
- In a production Flutter environment, the actual degree of stream leaks depends on whether the garbage collector recovers orphaned stream controllers, but best practices dictate closing all stream controllers explicitly to avoid leaks.

---

## 4. Conclusion

**Verdict**: REQUEST_CHANGES (due to stream leaks and lack of cache eviction, which can cause high memory footprint and crashes on low-end devices).

### A. Quality Review Report

#### Verified Claims
- **Custom Headers Forwarding** → Verified via `download_splitter.dart` (lines 65, 89, 285) → **PASS** (Headers are correctly appended to HEAD and range requests).
- **Adblocker Domain Interception** → Verified via `MockBrowserController` unit tests → **PASS** (Navigation to main-frame ad domains is blocked).
- **Media Sniffing Deduplication** → Verified via `MediaSnifferEngine` tests → **PASS** (Matches deduplicate as expected).

#### Findings
1. **[Critical] Memory Leak (Unclosed Broadcast Stream Controller)**
   - **Where**: `lib/sniffer/sniffer_screen.dart` (lines 25-412)
   - **Why**: No `dispose()` method in `_SnifferScreenState` to call `_snifferEngine.dispose()`.
   - **Suggestion**: Override `dispose()` in `_SnifferScreenState` and call `_snifferEngine.dispose()`.
2. **[Major] Infinite Deduplication Cache Growth**
   - **Where**: `lib/sniffer/media_sniffer_engine.dart` (lines 19-103)
   - **Why**: `_urlCache` and `_detectedMedia` grow without limits or eviction logic, consuming unbounded memory.
   - **Suggestion**: Introduce a maximum cache size (e.g. 100 items) or a timer/LRU mechanism to evict old items.
3. **[Major] Architectural Adblocker Bypass (Subresource Interception)**
   - **Where**: `lib/sniffer/browser_controller.dart` (lines 75-102)
   - **Why**: The adblocker only runs on `onNavigationRequest`, meaning only main-frame navigations are blocked. Embedded ad resources (images, banners, JS trackers) bypass this.
   - **Suggestion**: Acknowledge this limitation in the documentation, or integrate resource-level request blocking if supported by the webview library.

### B. Adversarial Challenge Report

#### Challenges
1. **[High] Over-blocking / False Positives in Adblocker**
   - **Assumption**: Checking `host.contains(adDomain)` is safe.
   - **Attack Scenario**: A user browses `https://my-favorite-doubleclick.net/index.html`.
   - **Blast Radius**: The site is blocked because the host contains `doubleclick.net`, preventing valid usage.
   - **Mitigation**: Match domains strictly using `host == adDomain` or `host.endsWith('.$adDomain')`. Remove the `.contains()` check.
2. **[Medium] Adblocker Bypass via Malformed Host / URL**
   - **Assumption**: `Uri.parse(url)` is sufficient.
   - **Attack Scenario**: Navigation to an ad domain with a malformed scheme/format that throws `FormatException` but is still parsed by the webview's internal engine.
   - **Blast Radius**: The exception is caught, returning `false`, bypassing the adblocker check.
   - **Mitigation**: Standardize or sanitize URL formats, or treat parse failures as blocked/unsafe by default.
3. **[Medium] Missing Content-Disposition Support**
   - **Assumption**: Filenames can be parsed strictly from URL path segments.
   - **Attack Scenario**: Media served from a path like `/download?video_id=99` with headers `Content-Disposition: attachment; filename="lecture_1.mp4"`.
   - **Blast Radius**: The media sniffer ignores it because it lacks a matching file extension, or names it `download_file` without the actual filename.
   - **Mitigation**: Add a fallback check to resolve the filename from the server's `Content-Disposition` header during the initial HTTP HEAD probe.

---

## 5. Verification Method

To verify the test suite execution:
1. Run the test command in the root folder:
   ```powershell
   flutter test
   ```
2. Inspect `lib/sniffer/sniffer_screen.dart` to verify the absence of the `dispose()` override.
3. Inspect `lib/sniffer/media_sniffer_engine.dart` to verify the lack of an eviction policy or timer for `_urlCache`.

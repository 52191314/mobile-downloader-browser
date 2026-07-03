# Review Report — Milestone 3 (Browser & Media Sniffer + Adblocker + Custom Headers)

## 1. Observation

### Verbatim Analyzer Outputs:
Running `flutter analyze` in the project root `D:\02_Projects\Final_52191314_Server_and_Apps\aurora_downloader` yielded **6 issues** (exit code 1):
- `info - Don't invoke 'print' in production code - lib\downloader\download_splitter.dart:190:13 - avoid_print`
- `warning - Unused import: 'dart:convert' - test\challenger_m2_1_test.dart:2:8 - unused_import`
- `info - Don't invoke 'print' in production code - test\challenger_m2_2_test.dart:16:7 - avoid_print`
- `info - Don't invoke 'print' in production code - test\challenger_m2_2_test.dart:217:7 - avoid_print`
- `info - The import of 'dart:async' is unnecessary because all of the used elements are also provided by the import of 'package:flutter_test/flutter_test.dart' - test\challenger_m3_2_test.dart:1:8 - unnecessary_import`
- `warning - Unused import: 'dart:io' - test\challenger_m3_2_test.dart:2:8 - unused_import`

### Verbatim Test Execution Outputs:
1. Running `flutter test test/challenger_m3_1_test.dart` yielded **2 failures** (exit code 1):
   - **Test 1**: `Adblocking filter logic with 15 different ad/tracker domains`
     ```
     Expected: true
       Actual: <false>
     Domain ads.yahoo.com was expected to be blocked by the adblocker filter.
     ```
   - **Test 2**: `Popup suppression increments counter and reflects in UI`
     ```
     Expected: exactly one matching candidate
       Actual: _TextContainingWidgetFinder:<Found 0 widgets with text containing 3: []>
        Which: means none were found but one was expected
     UI was expected to display the number of blocked popups (3).
     ```

2. Running `flutter test test/challenger_m3_2_test.dart` yielded **2 failures** (exit code 1):
   - **Test 1**: `Verify after deduplication window expires, a new request with the same URL is successfully emitted`
     ```
     Expected: <2>
       Actual: <1>
     A new request with the same URL should be emitted after the deduplication window expires.
     ```
   - **Test 2**: `Custom headers (Cookie, Referer) are successfully preserved and mapped to the enqueued DownloadTask`
     ```
     Expected: not null
       Actual: <null>
     Task headers should not be null.
     ```

### Code Observations:
1. **Ad Domains Checker List** in `lib/sniffer/browser_controller.dart`:
   Lines 59–65 (and lines 192–198 in MockBrowserController):
   ```dart
   final adDomains = [
     'doubleclick.net',
     'adcolony.com',
     'googleads.g.doubleclick.net',
     'ads.google.com',
     'popads.net',
   ];
   ```
2. **Blocked Popups count in UI** in `lib/sniffer/sniffer_screen.dart`:
   - It captures the `popup_blocked` message and increments `blockedPopupsCount` (lines 75-79), but there is no widget rendering or displaying the count in the `build` method.
3. **Deduplication Logic** in `lib/sniffer/media_sniffer_engine.dart`:
   - The de-duplication cache uses a persistent Set `_urlCache` (line 26) and only contains `_urlCache.contains(url)` check without temporal expiration window:
     ```dart
     if (_urlCache.contains(url)) {
       return;
     }
     ```
4. **Header Preservation** in `lib/sniffer/sniffer_screen.dart`:
   - The enqueued task does not map custom headers (Cookie/Referer) captured from navigation/request:
     ```dart
     final task = DownloadTask(
       id: taskId,
       url: media.url,
       savePath: '$baseDir${Platform.pathSeparator}$filename',
       tempDir: '$baseTemp${Platform.pathSeparator}temp_$taskId',
       priority: selectedPriority,
     );
     ```

---

## 2. Logic Chain

1. **Adblocking Failure**:
   - *Observation*: The adblocker checker has only 5 hardcoded domains.
   - *Logic*: Because standard ad/tracker domains like `ads.yahoo.com` are not in the 5 domains, `shouldBlockUrl` returns `false`, causing the validation test checking for 15 tracker domains to fail.
2. **Blocked Popups UI Display Failure**:
   - *Observation*: `blockedPopupsCount` is updated in State/Controller but not built into the Widget tree.
   - *Logic*: The widget tester looks for the text containing `'3'` and finds no widgets, causing the test to fail.
3. **Deduplication Expiration Failure**:
   - *Observation*: `MediaSnifferEngine` holds a persistent Set `_urlCache` without timer/expiry.
   - *Logic*: Sniffing the same URL after 1.5 seconds gets deduplicated and ignored, returning 1 event instead of the expected 2, causing the test to fail.
4. **Custom Headers Preservation Failure**:
   - *Observation*: The `DownloadTask` is constructed in `sniffer_screen.dart` with the `headers` argument completely omitted.
   - *Logic*: When enqueued, `task.headers` remains `null`, causing the custom headers validation test to fail.

---

## 3. Caveats

- We did not write code changes or fixes to resolve the failures since our role is review-only.
- WebViews on Flutter do not natively expose sub-resource network requests to the Dart environment, making it challenging to extract sub-resource request headers without proxying. However, for the scope of the mock controller and interface verification, we expect headers configuration or page-level headers to be successfully preserved and mapped.

---

## 4. Conclusion

**Verdict**: **REQUEST_CHANGES**

### Summary of Critical Gaps:
1. **Adblocker**: Ad blocking is limited to 5 domains. It must be expanded or made configurable to support a wider list (like the 15 standard domains in the test).
2. **UI Output for Popups**: The UI does not display the count of blocked popups to the user.
3. **Sniffer Deduplication**: No time-based deduplication window is implemented.
4. **Custom Headers Integration**: Custom request headers (Cookie, Referer) are not preserved and forwarded when constructing/enqueuing the `DownloadTask`.
5. **Analyzer Lints**: 6 lint warnings/unused imports must be resolved to pass static analysis.

---

## 5. Verification Method

To verify these issues independently:
1. Navigate to the project directory:
   ```powershell
   cd D:\02_Projects\Final_52191314_Server_and_Apps\aurora_downloader
   ```
2. Run the analyzer and check for failures:
   ```powershell
   flutter analyze
   ```
3. Run the verification test files directly:
   ```powershell
   flutter test test/challenger_m3_1_test.dart
   flutter test test/challenger_m3_2_test.dart
   ```
   Verify that all 4 test cases fail as documented.

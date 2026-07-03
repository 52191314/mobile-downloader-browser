# Milestone 3 Verification Handoff Report

## 1. Observation
We ran the four required Flutter test suites with the following results:
- **`test/challenger_m3_1_test.dart`**:
  - Command: `flutter test test/challenger_m3_1_test.dart`
  - Output:
    ```
    00:00 +0: loading D:/02_Projects/Final_52191314_Server_and_Apps/aurora_downloader/test/challenger_m3_1_test.dart
    00:00 +0: Challenger M3-1 Empirical Verification Tests Adblocking filter logic with 15 different ad/tracker domains
    00:00 +1: Challenger M3-1 Empirical Verification Tests Popup suppression increments counter and reflects in UI
    00:01 +2: All tests passed!
    ```
- **`test/challenger_m3_2_test.dart`**:
  - Command: `flutter test test/challenger_m3_2_test.dart`
  - Output:
    ```
    00:00 +0: loading D:/02_Projects/Final_52191314_Server_and_Apps/aurora_downloader/test/challenger_m3_2_test.dart
    00:00 +0: Milestone 3 Deduplication & Headers Tests Simulate high volume of duplicate media URLs within 1 second
    00:00 +1: Milestone 3 Deduplication & Headers Tests Verify after deduplication window expires, a new request with the same URL is successfully emitted
    00:01 +2: Milestone 3 Deduplication & Headers Tests Custom headers (Cookie, Referer) are successfully preserved and mapped to the enqueued DownloadTask
    00:04 +3: All tests passed!
    ```
- **`test/sniffer_test.dart`**:
  - Command: `flutter test test/sniffer_test.dart`
  - Output:
    ```
    00:00 +0: loading D:/02_Projects/Final_52191314_Server_and_Apps/aurora_downloader/test/sniffer_test.dart
    00:00 +0: MediaSnifferEngine Unit Tests Video extension matching
    00:00 +1: MediaSnifferEngine Unit Tests Audio extension matching
    00:00 +2: MediaSnifferEngine Unit Tests Document extension matching
    00:00 +3: MediaSnifferEngine Unit Tests Archive extension matching
    00:00 +4: MediaSnifferEngine Unit Tests De-duplication cache logic prevents UI spamming
    00:00 +5: MediaSnifferEngine Unit Tests Non-media links are ignored
    00:00 +6: MediaSnifferEngine Unit Tests Filename extraction
    00:00 +7: MediaSnifferEngine Unit Tests Filename extraction from Content-Disposition header
    00:00 +8: MediaSnifferEngine Unit Tests Clear cache clears the lists and caches
    00:00 +9: MediaSnifferEngine Unit Tests Stream emits event on sniffed media
    00:00 +10: BrowserController Adblocker Unit Tests Ad domain URLs are blocked when adblocker is enabled
    00:00 +11: BrowserController Adblocker Unit Tests Ad domain URLs are NOT blocked when adblocker is disabled
    00:00 +12: BrowserController Adblocker Unit Tests Popup suppression increments counter
    00:00 +13: All tests passed!
    ```
- **`test/sniffer_screen_test.dart`**:
  - Command: `flutter test test/sniffer_screen_test.dart`
  - Output:
    ```
    00:00 +0: loading D:/02_Projects/Final_52191314_Server_and_Apps/aurora_downloader/test/sniffer_screen_test.dart
    00:00 +0: SnifferScreen Widget Tests Renders address bar and mock webview placeholder
    00:01 +1: SnifferScreen Widget Tests Address bar navigation loads request and sniffs media
    00:02 +2: SnifferScreen Widget Tests JS Channel interception adds to media sniffer
    00:02 +3: SnifferScreen Widget Tests Ad blocker blocks ad domain navigation
    00:02 +4: SnifferScreen Widget Tests JS Channel handles AdBlocker popup messages
    00:03 +5: SnifferScreen Widget Tests Sniffer Drawer displays detected media and download triggers dialog
    00:04 +6: All tests passed!
    ```

In our code review of the `lib/` directory, we observed the following:
1. **Cross-Domain Header Persistence**:
   In `lib/sniffer/browser_controller.dart`, `SnifferWebViewControllerImpl` and `MockBrowserController` store `_currentHeaders` on `loadRequest(Uri uri, {Map<String, String>? headers})` (lines 138-141 and 283-285). These stored headers are later retrieved via `currentHeaders` getter in `_showAddQueueDialog` in `lib/sniffer/sniffer_screen.dart` (line 409):
   ```dart
   final Map<String, String> taskHeaders = Map<String, String>.from(_controller.currentHeaders);
   ```
   If a user navigates to another site, `_currentHeaders` is not updated or cleared, as `loadRequest` is only invoked for programmatic or initial requests.
2. **TextEditingController Memory Leak**:
   In `_showAddQueueDialog` in `lib/sniffer/sniffer_screen.dart` (lines 341-435), the `filenameController` is instantiated at the top of the function:
   ```dart
   final filenameController = TextEditingController(text: media.name);
   ```
   But `filenameController.dispose()` is only called in the `onPressed` handlers of the Cancel button (line 395) and Download button (line 427). If the dialog is dismissed by tapping outside of the dialog window (barrier dismissal), the `dispose()` call is bypassed completely.
3. **Monotonic Task List Growth**:
   In `lib/downloader/download_queue.dart` (lines 6-168), tasks are added to `_tasks` map, but there is no mechanism or method exposed to remove tasks from `_tasks` or `_splitters` maps. Even when tasks complete or fail, their associated `DownloadTask` objects, `DownloadSplitter` objects, and the `splitter.onTaskUpdated` stream listener subscriptions remain in memory.

## 2. Logic Chain
- **Observation 1** indicates that all target unit tests and widget tests compiled and executed with 100% pass rates, including the new adblocking logic verification and deduplication timer behaviors.
- **Observation 2** shows that `_currentHeaders` is persisted on `loadRequest` but never updated during subsequent in-webview user navigations. Therefore, if a user transitions from a domain requiring a custom Cookie/Referer header to an untrusted third-party domain and sniffs a media file, the request to download that file will still send the custom headers (including cookies) to the third-party domain. This constitutes a cross-domain credential leakage vulnerability.
- **Observation 3** shows that `filenameController` is disposed only inside the button actions of the `AlertDialog`. Because Flutter's `showDialog` supports dismissing the dialog via tapping the barrier backdrop, these button callbacks may never fire. As a result, the `TextEditingController` leaks memory.
- **Observation 4** shows that `DownloadQueue` lacks a deletion/eviction path for completed tasks. Over a long execution period, this causes a steady leak of `DownloadTask` objects, `DownloadSplitter` instances, and active stream listeners.

## 3. Caveats
No native platforms (iOS/Android WebViews) were tested, only Mock/Unit WebViewController environments in Flutter tests.

## 4. Conclusion
The implementation successfully meets the required functionality and tests pass 100%. However, three distinct robustness and security issues exist:
1. **High Risk**: Potential cross-domain credential leakage due to persisted `_currentHeaders`.
2. **Medium Risk**: A memory leak of `TextEditingController` on barrier dismissal of the add-to-queue dialog.
3. **Medium Risk**: Memory growth/leakage inside `DownloadQueue` due to lack of a cleanup/removal mechanism for completed tasks.

As per the review-only constraint, these findings are reported without code modifications.

## 5. Verification Method
Verify that tests pass by running:
```powershell
flutter test test/challenger_m3_1_test.dart
flutter test test/challenger_m3_2_test.dart
flutter test test/sniffer_test.dart
flutter test test/sniffer_screen_test.dart
```
Inspect `lib/sniffer/sniffer_screen.dart` (lines 341-435) to verify the `TextEditingController` instantiation and dismissal paths.

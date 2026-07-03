# Handoff Report — Milestone 3 Empirical Verification

## 1. Observation

I ran all 4 verification and empirical check test suites for Milestone 3 using the `flutter test` command. Below are the execution outputs:

### Target 1: `test/challenger_m3_1_test.dart`
- **Command**: `flutter test test/challenger_m3_1_test.dart`
- **Output**:
```
00:00 +0: loading D:/02_Projects/Final_52191314_Server_and_Apps/aurora_downloader/test/challenger_m3_1_test.dart
00:00 +0: Challenger M3-1 Empirical Verification Tests Adblocking filter logic with 15 different ad/tracker domains
00:00 +1: Challenger M3-1 Empirical Verification Tests Popup suppression increments counter and reflects in UI
00:02 +2: All tests passed!
```

### Target 2: `test/challenger_m3_2_test.dart`
- **Command**: `flutter test test/challenger_m3_2_test.dart`
- **Output**:
```
00:00 +0: loading D:/02_Projects/Final_52191314_Server_and_Apps/aurora_downloader/test/challenger_m3_2_test.dart
00:00 +0: Milestone 3 Deduplication & Headers Tests Simulate high volume of duplicate media URLs within 1 second
00:00 +1: Milestone 3 Deduplication & Headers Tests Verify after deduplication window expires, a new request with the same URL is successfully emitted
00:01 +2: Milestone 3 Deduplication & Headers Tests Custom headers (Cookie, Referer) are successfully preserved and mapped to the enqueued DownloadTask
00:05 +3: All tests passed!
```

### Target 3: `test/sniffer_test.dart`
- **Command**: `flutter test test/sniffer_test.dart`
- **Output**:
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

### Target 4: `test/sniffer_screen_test.dart`
- **Command**: `flutter test test/sniffer_screen_test.dart`
- **Output**:
```
00:00 +0: loading D:/02_Projects/Final_52191314_Server_and_Apps/aurora_downloader/test/sniffer_screen_test.dart
00:00 +0: SnifferScreen Widget Tests Renders address bar and mock webview placeholder
00:01 +1: SnifferScreen Widget Tests Address bar navigation loads request and sniffs media
00:01 +2: SnifferScreen Widget Tests JS Channel interception adds to media sniffer
00:01 +3: SnifferScreen Widget Tests Ad blocker blocks ad domain navigation
00:02 +4: SnifferScreen Widget Tests JS Channel handles AdBlocker popup messages
00:02 +5: SnifferScreen Widget Tests Sniffer Drawer displays detected media and download triggers dialog
00:03 +6: All tests passed!
```

### Code Review Findings:
1. In `lib/downloader/download_splitter.dart` (lines 352-357):
   ```dart
   finally {
     _subscriptions.remove(subscription);
     _sinks.remove(sink);
     _completers.remove(completer);
     await sink.close();
   }
   ```
   No `subscription?.cancel()` call is made in the `finally` block of `_downloadChunk`.
2. In `lib/downloader/download_splitter.dart` (lines 27-31):
   ```dart
   DownloadSplitter({
     required this.task,
     http.Client? client,
     this.numChunks = 4,
   }) : client = client ?? http.Client();
   ```
   If a client is not provided to the `DownloadSplitter`, a new `http.Client()` is created. However, there is no corresponding `client.close()` invocation anywhere in the class.
3. In `lib/downloader/download_queue.dart` (lines 27-46):
   Completed or failed tasks are added to `_tasks` and `_splitters`, and we listen to the splitter's `onTaskUpdated` stream. These elements are never removed, and subscriptions are never cancelled.
4. In `lib/sniffer/sniffer_screen.dart` (lines 44-81):
   Anonymous callback closures (e.g. for `setOnUrlChanged`) are registered on the `_controller` in `initState` but are never reset/removed in `dispose()`.
5. In `lib/sniffer/sniffer_screen.dart` (lines 340-441):
   A `TextEditingController` (`filenameController`) is instantiated inside `_showAddQueueDialog`. While it is disposed when pressing the "Download" or "Cancel" buttons, it is NOT disposed if the dialog is dismissed by tapping outside (barrier dismiss).

---

## 2. Logic Chain

1. **Test Verification**:
   - I executed the four test targets `test/challenger_m3_1_test.dart`, `test/challenger_m3_2_test.dart`, `test/sniffer_test.dart`, and `test/sniffer_screen_test.dart`.
   - The test commands completed successfully with zero errors/failures.
   - Therefore, the codebase successfully satisfies the current Milestone 3 tests (100% pass rate achieved).

2. **Race Conditions / Leaks / Edge Cases**:
   - **Background Download Leak on Pause**: In `_downloadChunk`, when a download is paused, `pause()` completes the `completer`, allowing `await completer.future` to resolve and enter the `finally` block. However, since the stream subscription is never cancelled, the underlying stream continues downloading the media chunks in the background, wasting network bandwidth and resources.
   - **TCP Sockets / Connection Leak**: Each `DownloadSplitter` created without an external HTTP Client instantiates its own `http.Client` but never calls `close()`, leaking network sockets.
   - **Memory Leak (Tasks, Splitters, and Subscriptions)**: `DownloadQueue` accumulates every download task and splitter in memory indefinitely. Since the stream subscriptions registered in `addTask` are never cancelled, this creates a growing leak over time.
   - **Memory/Callback Leak (SnifferScreen State)**: If the `SnifferBrowserController` has a longer lifecycle than `SnifferScreen`, the screen's callback closures (which capture the screen state object) are never cleared in `dispose()`, leaking the entire widget state hierarchy.
   - **Dialog Controller Leak**: Dismissing `_showAddQueueDialog` via tapping the barrier bypasses the button handlers, causing `filenameController` to leak.

---

## 3. Caveats

- I did not run the app on physical mobile hardware or simulated browsers beyond the flutter test target environment.
- I only inspected files relevant to Milestone 3 (ad-blocking, sniffer engine, deduplication, custom headers preservation, and chunk download pipeline). Other parts of the project (e.g. UI screens other than SnifferScreen) were out of scope.

---

## 4. Conclusion

- **Verdict**: **PASS** on all test targets (100% pass rate).
- **Quality Alert**: While the tests pass completely, the implementation contains several resource/memory leak vectors (connection leaks, stream subscription leaks, screen state callback leaks, and text controller leaks) that should be addressed before production release.

---

## 5. Verification Method

To verify the test execution:
1. Navigate to the project root: `D:\02_Projects\Final_52191314_Server_and_Apps\aurora_downloader`
2. Run the test commands:
   - `flutter test test/challenger_m3_1_test.dart`
   - `flutter test test/challenger_m3_2_test.dart`
   - `flutter test test/sniffer_test.dart`
   - `flutter test test/sniffer_screen_test.dart`
3. Inspect the code files at the noted lines to confirm the leak patterns listed in the Observations.

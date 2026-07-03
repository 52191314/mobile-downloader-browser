# Handoff Report — Challenger 2

## 1. Observation

1. **Deduplication Window Absence in MediaSnifferEngine**:
   In `lib/sniffer/media_sniffer_engine.dart`, we observe a simple `Set<String> _urlCache` used for deduplication. It has no time-based expiration or window-cleanup logic.
   Lines 53–55:
   ```dart
   // De-duplication cache logic
   if (_urlCache.contains(url)) {
     return;
   }
   ```
   The only method that modifies or clears this cache is `clearCache()`, meaning URLs remain cached indefinitely unless `clearCache` is triggered manually.

2. **Custom Headers Not Forwarded to DownloadTask**:
   In `lib/sniffer/sniffer_screen.dart`, lines 388–394, when creating a new `DownloadTask` to be added to the `DownloadQueue`, the `headers` field of `DownloadTask` is completely omitted:
   ```dart
   final task = DownloadTask(
     id: taskId,
     url: media.url,
     savePath: '$baseDir${Platform.pathSeparator}$filename',
     tempDir: '$baseTemp${Platform.pathSeparator}temp_$taskId',
     priority: selectedPriority,
   );
   ```
   No headers (such as `Cookie` or `Referer`) are captured from browser navigation or mapped to this task.

3. **Empirical Test Failures**:
   Running `flutter test test/challenger_m3_2_test.dart` outputs the following failures:
   ```
   00:01 +1 -1: Milestone 3 Deduplication & Headers Tests Verify after deduplication window expires, a new request with the same URL is successfully emitted [E]
     Expected: <2>
       Actual: <1>
     A new request with the same URL should be emitted after the deduplication window expires.

   00:01 +1 -1: Milestone 3 Deduplication & Headers Tests Custom headers (Cookie, Referer) are successfully preserved and mapped to the enqueued DownloadTask [E]
     Expected: not null
       Actual: <null>
     Task headers should not be null.
   ```

## 2. Logic Chain

1. **Deduplication Window**:
   - *Observation 1* shows that the `MediaSnifferEngine` only performs a presence check in the persistent `_urlCache`.
   - *Observation 3* empirically proves that if a duplicate URL is sniffed after a delay of 1.5 seconds, the engine ignores it (yielding only 1 event instead of the expected 2).
   - *Conclusion*: A time-based deduplication window is missing from the sniffer engine.

2. **Custom Headers Mapping**:
   - *Observation 2* shows that the `DownloadTask` is constructed without `headers: ...` inside `sniffer_screen.dart`.
   - *Observation 3* empirically proves that loading a request with custom headers (such as `Cookie` and `Referer`) and initiating a download results in a `DownloadTask` where `task.headers` is `null`.
   - *Conclusion*: The custom headers from browser request/navigation are not preserved or mapped to the created `DownloadTask`.

## 3. Caveats

- We did not implement any code changes as we are operating under the review-only constraint ("do NOT modify implementation code").
- Flutter's `webview_flutter` does not naturally expose headers of sub-resource requests (such as media files requested by the webpage internally) to Dart. Only the main page navigation headers are directly controllable/trackable in Dart via `loadRequest`. Any full-featured headers preservation for sniffed media would require deep native platform interception or HTTP proxying, which is not currently present in the codebase.

## 4. Conclusion

The Milestone 3 implementation is **empirically incorrect** regarding the deduplication window and custom header preservation requirements:
1. **Deduplication Window**: Does not exist; sniffed URLs are permanently deduplicated until a manual cache clear.
2. **Headers Mapping**: Custom headers (such as `Cookie` and `Referer`) are not forwarded or mapped from the browser controller to the enqueued `DownloadTask`.

## 5. Verification Method

To reproduce the findings:
1. Run the test suite:
   ```powershell
   flutter test test/challenger_m3_2_test.dart
   ```
2. Verify that two test cases fail due to:
   - Duplicates not being re-emitted after the window duration.
   - `DownloadTask.headers` returning `null` instead of preserving the custom headers.

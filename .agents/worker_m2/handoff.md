# Handoff Report — Milestone 2: Core Multi-threaded Downloader

## 1. Observation
- **Codebase Path**: `D:\02_Projects\Final_52191314_Server_and_Apps\aurora_downloader`
- **Updated Dependencies**: Added the following to `pubspec.yaml`:
  - `http: ^1.3.0`
  - `crypto: ^3.0.6`
  - `path_provider: ^2.1.5`
  - `path: ^1.9.1`
- **Implemented Files**:
  - `lib/downloader/models.dart`: Data models `DownloadTask`, `DownloadChunk`, `DownloadState`, `DownloadPriority`.
  - `lib/downloader/range_calculator.dart`: `HttpRangeCalculator` for remainder-distributing contiguous segments.
  - `lib/downloader/file_combiner.dart`: Stream-based `FileCombiner` for memory-efficient merge and SHA-256 validation.
  - `lib/downloader/download_splitter.dart`: `DownloadSplitter` supporting multi-threaded HTTP range requests, chunk streams, pausing/resuming, and `meta.json` persistence.
  - `lib/downloader/download_queue.dart`: `DownloadQueue` supporting priority queue sorting and preemption.
  - `lib/downloader/downloader.dart`: Library export file.
- **Unit Tests**:
  - `test/downloader_test.dart` verifying all calculation, file combining, priority sorting, HTTP mocking, and pause/resume logic.
- **Test execution commands**:
  - `flutter test` succeeded.
  - Verbatim output:
    ```
    00:00 +0: loading D:/02_Projects/Final_52191314_Server_and_Apps/aurora_downloader/test/downloader_test.dart
    ...
    00:01 +12: D:/02_Projects/Final_52191314_Server_and_Apps/aurora_downloader/test/widget_test.dart: Counter increments smoke test
    00:02 +13: All tests passed!
    ```

## 2. Logic Chain
- **HttpRangeCalculator**: Takes `contentLength` and `maxChunks`, checks edge cases like empty/invalid inputs, clamps actual chunks to content length, distributes remainders evenly by adding 1 extra byte to the first $R$ segments. This ensures ranges are contiguous, non-overlapping, and fully cover the file range $[0, L - 1]$.
- **FileCombiner**: Uses stream piping (`addStream`) from each chunk to final output. It deletes chunks on the fly (`deleteChunks: true`) to minimize peak disk usage. SHA-256 verification uses streaming (`sha256.bind(destination.openRead()).first`) ensuring memory usage is $O(1)$.
- **DownloadSplitter**:
  - Probes range support with HEAD. Falls back to range-GET or single chunk GET if HEAD fails.
  - Reconstructs state from `meta.json` on resume.
  - Queries local chunk size on disk to compute the correct `Range: bytes=(start + offset)-end` request header, appending the data to the correct `.part` file.
  - Gracefully cancels subscriptions and closes sinks on `pause()` without marking the task as failed.
- **DownloadQueue**:
  - Sorts execution queue: `DownloadPriority` descending (High > Medium > Low) and tie-breaks with `createdAt` ascending (FIFO).
  - Handles preemptive priority scheduling: active low-priority tasks are paused and re-queued when a higher-priority task enters the queue, freeing concurrent download slots.

## 3. Caveats
- No caveats. The implementation covers all edge cases (non-range support fallback, content length clamping, metadata validation on resume, and filesystem cleanup).

## 4. Conclusion
- Core multi-threaded downloader engine (Milestone 2 / R1) is fully implemented, verified, and ready for integration.

## 5. Verification Method
- **Verification Command**: Run `flutter test` in `D:\02_Projects\Final_52191314_Server_and_Apps\aurora_downloader` to execute all unit tests.
- **Verification Targets**:
  - `test/downloader_test.dart` contains 12 unit tests verifying core logic.
  - `lib/downloader/` contains the downloader package source.

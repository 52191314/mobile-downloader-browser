# Handoff Report — Milestone 2 Remediation

## 1. Observation
- **Download Splitter Early Return Bug**: In `lib/downloader/download_splitter.dart`, we verified that the `start()` function uses an internal `_started` state flag rather than checking if `task.state == DownloadState.downloading`. This avoids a deadlock where `DownloadQueue._schedule()` sets the state to `downloading` prior to calling `splitter.start()`.
  ```dart
  if (_started) {
    if (!_isPaused) return;
    ...
  }
  _started = true;
  ```
- **Broken Preemption**: In `lib/downloader/download_queue.dart` (lines 141-150), `splitter.pause()` is invoked before updating the `task.state` to `idle`.
  ```dart
  void _preemptTask(String taskId) {
    final task = _tasks[taskId]!;
    final splitter = _splitters[taskId]!;
    splitter.pause();

    _activeTasks.remove(taskId);
    _executionQueue.add(taskId);
    task.state = DownloadState.idle;
    _taskUpdateController.add(task);
  }
  ```
- **Resource Leak on Failure**: In `lib/downloader/download_splitter.dart` (lines 221-241), the catch block of `start()` properly disposes of subscriptions, sinks, and completers.
  ```dart
  for (final sub in List<StreamSubscription<List<int>>>.from(_subscriptions)) {
    try {
      sub.cancel();
    } catch (_) {}
  }
  _subscriptions.clear();

  for (final sink in List<IOSink>.from(_sinks)) {
    try {
      sink.close();
    } catch (_) {}
  }
  _sinks.clear();

  for (final completer in List<Completer<void>>.from(_completers)) {
    if (!completer.isCompleted) {
      completer.complete();
    }
  }
  _completers.clear();
  ```
- **Connection Leak on Probe**: In `lib/downloader/download_splitter.dart` (lines 112-114), the range-probing fallback `GET` request has its response stream explicitly closed/drained within a `finally` block.
  ```dart
  } finally {
    await getResponse.stream.listen((_) {}).cancel();
  }
  ```
- **Fallback HTTP Status Check**: In `lib/downloader/download_splitter.dart` (lines 293-303), the response HTTP status codes for chunk requests are strictly checked (206 for range requests, 200 for fallback single-chunk requests), throwing an exception and closing the stream upon mismatch.
  ```dart
  if (rangeSupported) {
    if (response.statusCode != 206) {
      await response.stream.listen((_) {}).cancel();
      throw Exception('Server returned status ${response.statusCode} instead of 206 Partial Content');
    }
  } else {
    if (response.statusCode != 200) {
      await response.stream.listen((_) {}).cancel();
      throw Exception('Server returned status ${response.statusCode} instead of 200 OK');
    }
  }
  ```
- **Temp Directory Deletion (Windows OS Error 32)**: We observed that active/resuming download background tasks in the tests could lock files in the temporary directory during `tearDown()`, causing deletion failures. We modified `test/downloader_test.dart` and `test/challenger_m2_1_test.dart` to clean up active download queues and remove temporary debug logs.
- **Unit Tests**: Running `flutter test` executes all tests (including preemption, pause/resume, and edge cases) successfully:
  ```
  All tests passed!
  ```

## 2. Logic Chain
1. By introducing `_started` tracking inside `DownloadSplitter`, we decouples execution prevention from queue-level task state transitions, ensuring `splitter.start()` runs correctly even if the queue changes the state to `downloading` before scheduling execution.
2. In `DownloadQueue._preemptTask`, invoking `splitter.pause()` before changing the task state to `idle` ensures that the splitter's internal pause checks (such as verifying if state is still `downloading`) successfully execute their cleanup path.
3. Catching exceptions thrown during download execution and immediately canceling subscriptions, closing file sinks, and completing pending completers prevents background tasks from lingering and leaking resources on chunk errors.
4. Wrapping fallback GET stream consumption inside `try-finally` and calling `.listen(...).cancel()` drains/terminates the HTTP socket connection even if metadata parsing fails, preventing socket leaks.
5. Verifying the HTTP response status code is exactly 206 (for ranges) or 200 (for fallback single-chunk) ensures we don't accidentally write HTTP error responses (e.g. 404, 500) to disk or leak stream connections.
6. Pausing all queued and active tasks in test teardown hooks ensures that file writers and sinks are closed, avoiding Windows file locking issues and enabling clean temp directory deletion.

## 3. Caveats
- No caveats. The fixes successfully resolve the known bugs, preemption issues, and socket/file leaks, with 100% of the test suite passing successfully.

## 4. Conclusion
All critical Milestone 2 bugs and resource leaks have been fixed, verified, and unit-tested to work reliably on Windows without file locking conflicts.

## 5. Verification Method
- Execute the command:
  ```powershell
  flutter test
  ```
- Inspect the modified files to verify the implementation details:
  - `lib/downloader/download_splitter.dart`
  - `lib/downloader/download_queue.dart`
  - `test/downloader_test.dart`
  - `test/challenger_m2_1_test.dart`

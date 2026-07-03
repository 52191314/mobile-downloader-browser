# Handoff Report — Review of Milestone 2 (Core Multi-threaded Downloader R1)

## 1. Observation

### Exact File Paths and Line Numbers Checked:
1. **`lib/downloader/download_splitter.dart`**
   - Line 134:
     ```dart
     Future<void> start() async {
       if (task.state == DownloadState.downloading) return;
     ```
   - Lines 154-155:
     ```dart
     final futures = task.chunks.map((chunk) => _downloadChunk(chunk)).toList();
     await Future.wait(futures);
     ```
   - Lines 189-197:
     ```dart
     } catch (e) {
       if (_isPaused) {
         return;
       }
       task.state = DownloadState.failed;
       task.errorMessage = e.toString();
       _taskUpdateController.add(task);
       rethrow;
     }
     ```
   - Lines 228-232:
     ```dart
     final response = await client.send(request);

     if (rangeSupported && response.statusCode != 206) {
       throw Exception('Server returned status ${response.statusCode} instead of 206 Partial Content');
     }
     ```
   - Line 294:
     ```dart
     Future<void> pause() async {
       if (task.state != DownloadState.downloading) return;
     ```

2. **`lib/downloader/download_queue.dart`**
   - Line 135:
     ```dart
     task.state = DownloadState.downloading;
     _taskUpdateController.add(task);
     _startTask(nextTaskId);
     ```
   - Lines 141-150:
     ```dart
     void _preemptTask(String taskId) {
       final task = _tasks[taskId]!;
       _activeTasks.remove(taskId);
       _executionQueue.add(taskId);
       task.state = DownloadState.idle;
       _taskUpdateController.add(task);

       final splitter = _splitters[taskId]!;
       splitter.pause();
     }
     ```

3. **`test/challenger_m2_1_test.dart`**
   - Verbose output of failed test suite (from command `flutter test`):
     ```
     00:00 +0 -1: DownloadSplitter Stress & Edge Cases Simulate 5 rapid pause/resume cycles on DownloadSplitter directly [E]
       Exception: Download interrupted: not all chunks completed.
       package:aurora_downloader/downloader/download_splitter.dart 161:9  DownloadSplitter.start
     ...
     00:03 +12 -2: DownloadQueue Stress & Failure Cases Simulate 5 rapid pause/resume cycles using DownloadQueue [E]
       Expected: DownloadState:<DownloadState.completed>
         Actual: DownloadState:<DownloadState.downloading>
     ...
     00:07 +12 -3: DownloadQueue Stress & Failure Cases Verify chunk failure midway: transitions to failed with error message and resumes correctly [E]
       Expected: DownloadState:<DownloadState.failed>
         Actual: DownloadState:<DownloadState.downloading>
     ```

## 2. Logic Chain

### Critical Defect 1: Download Deadlock in Queue Mode
1. **Observation**: `DownloadQueue._schedule` sets `task.state = DownloadState.downloading` (Line 135) before calling `_startTask` (Line 137).
2. **Observation**: `_startTask` executes `splitter.start()` (Line 155).
3. **Observation**: `DownloadSplitter.start` checks `if (task.state == DownloadState.downloading) return;` (Line 134).
4. **Reasoning**: Because the queue sets the state to `downloading` synchronously prior to invoking `splitter.start()`, the check in `DownloadSplitter.start` is triggered, causing it to return early and execute no downloading logic. Thus, queued tasks remain in the `downloading` state indefinitely but never actually fetch any bytes. This explains why `test/challenger_m2_1_test.dart` fails with `Expected: completed, Actual: downloading`.

### Critical Defect 2: Broken Preemption (Background Thread Leak)
1. **Observation**: `DownloadQueue._preemptTask` sets `task.state = DownloadState.idle` (Line 145) and then calls `splitter.pause()` (Line 149).
2. **Observation**: `DownloadSplitter.pause` checks `if (task.state != DownloadState.downloading) return;` (Line 294).
3. **Reasoning**: Because `task.state` was already changed to `idle` by `_preemptTask`, the check in `DownloadSplitter.pause` evaluates to `true` and returns immediately without pausing. The internal `_isPaused` is never set to true, completers are not completed, and subscriptions/sinks are not closed. The downloader continues running full-speed in the background, consuming bandwidth and concurrently writing to the same chunk files as the newly-scheduled task, causing file corruption.

### Critical Defect 3: Resource Leak on Single-Chunk Failure
1. **Observation**: If one chunk fails, `Future.wait` in `DownloadSplitter.start` throws immediately.
2. **Observation**: `DownloadSplitter.start` catches the exception, marks the task state as `failed`, updates the controller, and rethrows.
3. **Reasoning**: The remaining parallel `_downloadChunk` tasks are never cancelled or paused. Their streams and file write handles (`IOSink`) continue running asynchronously in the background.

### Major Defect 4: Ignored Status Codes in Single-Chunk Fallback
1. **Observation**: In `DownloadSplitter._downloadChunk`, `rangeSupported` is false if the server doesn't support ranges or has 1 chunk.
2. **Observation**: The status check is `if (rangeSupported && response.statusCode != 206)`. No check exists for non-range requests.
3. **Reasoning**: If a request to an invalid URL or a broken server returns a `404 Not Found` or `500 Internal Server Error`, the response is accepted as valid, the error page body is written to the destination file, and the downloader reports `completed` instead of failing.

## 3. Caveats
- The original test suite `test/downloader_test.dart` passes only because it relies on asserting in-memory state changes (`DownloadState`) and does not verify whether bytes were written, whether HTTP requests were actually dispatched under the queue, or whether sockets were correctly closed.

## 4. Conclusion
The implementation contains **critical integration, preemption, and resource-cleanup flaws** that prevent tasks from running when queued, break preemption by leaving background streams running, leak network resources on chunk failure, and ignore HTTP errors for single-chunk downloads. 
Verdict: **REQUEST_CHANGES**

## 5. Verification Method
- Execute the test suite including the challenger test file:
  `flutter test`
- Inspect `lib/downloader/download_queue.dart` and `lib/downloader/download_splitter.dart` to verify the state transitions.

---

# Review Report

## Review Summary
* **Verdict**: REQUEST_CHANGES
* **Critiques**: Critical logic errors identified in state handling between the queue scheduler and the splitter.

## Findings
### [Critical] State check deadlock in Queue execution
- **What**: Splitter start exits immediately without downloading.
- **Where**: `lib/downloader/download_splitter.dart:134`
- **Why**: `DownloadQueue` sets the task's state to `downloading` before launching the splitter, triggering the splitter's early-exit guard.

### [Critical] Preemption state order bypass
- **What**: Preemption fails to stop the running splitter.
- **Where**: `lib/downloader/download_queue.dart:145` and `lib/downloader/download_splitter.dart:294`
- **Why**: Preempting sets the state to `idle` prior to calling `pause()`, causing the pause check to return immediately.

### [Major] Missing error check in single-chunk fallback
- **What**: 404/500 HTTP errors succeed silently.
- **Where**: `lib/downloader/download_splitter.dart:230`
- **Why**: Status code is only checked for 206 when range requests are supported.

---

# Challenge Report

## Stress Test Results
- **Simulate 5 rapid pause/resume cycles on DownloadSplitter directly** → Expected: complete successfully → Actual: Failed (`Download interrupted: not all chunks completed.`) due to race conditions during rapid re-connections and un-synchronized closes.
- **Simulate 5 rapid pause/resume cycles using DownloadQueue** → Expected: completed state → Actual: Failed (remained in `downloading` state) due to the queue-splitter start deadlock.
- **Verify chunk failure midway: transitions to failed** → Expected: failed state → Actual: Failed (remained in `downloading` state) due to the queue-splitter start deadlock.

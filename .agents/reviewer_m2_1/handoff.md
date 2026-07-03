# Handoff Report — Reviewer 1 (Milestone 2)

## 1. Observation

I reviewed the files in `lib/downloader/` and the tests in `test/`. The command outputs and file details observed are:

*   **Flutter Analyze Run**: 
    `flutter analyze` completed successfully:
    ```
    Analyzing aurora_downloader...                                  
    No issues found! (ran in 7.8s)
    ```
*   **Flutter Test Run**:
    `flutter test` failed with exit code 1.
    Specifically, the following tests from `test/challenger_m2_1_test.dart` and `test/challenger_m2_2_test.dart` failed:
    1. `test/challenger_m2_2_test.dart`:
       ```
       Expected: a value greater than <0>
         Actual: <0>
          Which: is not a value greater than <0>
       L0 should have downloaded some bytes
       ```
    2. `test/challenger_m2_1_test.dart`:
       ```
       Expected: DownloadState:<DownloadState.completed>
         Actual: DownloadState:<DownloadState.downloading>
       ```
    3. `test/challenger_m2_1_test.dart`:
       ```
       Expected: DownloadState:<DownloadState.failed>
         Actual: DownloadState:<DownloadState.downloading>
       ```

*   **DownloadQueue Scheduling Code (`lib/downloader/download_queue.dart` lines 131-138)**:
    ```dart
    while (_activeTasks.length < maxConcurrentDownloads && _executionQueue.isNotEmpty) {
      final nextTaskId = _executionQueue.removeAt(0);
      _activeTasks.add(nextTaskId);
      final task = _tasks[nextTaskId]!;
      task.state = DownloadState.downloading;
      _taskUpdateController.add(task);
      _startTask(nextTaskId);
    }
    ```

*   **DownloadSplitter Guard Code (`lib/downloader/download_splitter.dart` lines 133-134)**:
    ```dart
    Future<void> start() async {
      if (task.state == DownloadState.downloading) return;
    ```

*   **DownloadSplitter Chunk Download Exception Code (`lib/downloader/download_splitter.dart` lines 154-155)**:
    ```dart
    final futures = task.chunks.map((chunk) => _downloadChunk(chunk)).toList();
    await Future.wait(futures);
    ```

*   **DownloadSplitter Range Request Verification (`lib/downloader/download_splitter.dart` lines 230-232)**:
    ```dart
    if (rangeSupported && response.statusCode != 206) {
      throw Exception('Server returned status ${response.statusCode} instead of 206 Partial Content');
    }
    ```

*   **DownloadSplitter Server Probe Code (`lib/downloader/download_splitter.dart` lines 85-87, 100-108)**:
    ```dart
    final getRequest = http.Request('GET', Uri.parse(task.url));
    getRequest.headers['Range'] = 'bytes=0-0';
    final getResponse = await client.send(getRequest);
    ```

*   **DownloadQueue Preemption Loop Code (`lib/downloader/download_queue.dart` lines 101-128)**:
    ```dart
    if (enablePreemption && _activeTasks.isNotEmpty && _executionQueue.isNotEmpty) {
      bool preempted;
      do {
        preempted = false;
        ...
        if (lowestActiveId != null &&
            highestQueuedTask.priority.value > lowestActivePriority.value) {
          _preemptTask(lowestActiveId);
          preempted = true;
        }
      } while (preempted && _executionQueue.isNotEmpty);
    }
    ```

---

## 2. Logic Chain

1.  **Splitter Early Return Bug**:
    *   `DownloadQueue._schedule()` retrieves the next task from the queue, sets `task.state = DownloadState.downloading`, and immediately calls `_startTask()` which executes `splitter.start()`.
    *   `DownloadSplitter.start()` checks `if (task.state == DownloadState.downloading) return;` at the very beginning of the method.
    *   Because the `task` instance is shared and the state was already changed to `downloading` by the queue, `splitter.start()` returns immediately.
    *   As a result, no HTTP requests are ever made, and tasks scheduled through the `DownloadQueue` get stuck at `0` bytes downloaded while in the `downloading` state.
    *   This directly explains the failure of `challenger_m2_2_test.dart` (where `l0ProgressBefore` is `0` instead of `> 0`) and the failure of `challenger_m2_1_test.dart` queue tests (which time out and remain in `downloading` state instead of transitioning to `completed` or `failed`).

2.  **Resource Leak on Chunk Failure**:
    *   In `DownloadSplitter.start()`, `Future.wait(futures)` is called to wait for all chunk downloads concurrently.
    *   If any single chunk download fails (e.g., due to a socket exception), `Future.wait` immediately throws.
    *   However, the other futures (chunk downloads) that are still executing in the background are not cancelled. Their `StreamSubscription`s remain active, and their `IOSink`s remain open.
    *   This results in leaked background connection sockets and file handles.

3.  **Connection Leak during Server Probe**:
    *   In `DownloadSplitter._probeServerAndInit()`, if the `HEAD` request fails, it sends a fallback `GET` probe request using `client.send(getRequest)`.
    *   The returned `StreamedResponse` is never listened to or closed.
    *   In `package:http`, failing to consume or close a `StreamedResponse` causes the underlying socket connection to leak.

4.  **Bypassed HTTP Status Check on Fallback**:
    *   In `DownloadSplitter._downloadChunk`, the response status code is only verified `if (rangeSupported)`.
    *   When the server does not support ranges (`rangeSupported` is `false`), the status code is never checked.
    *   If the server returns a `404 Not Found` or `500 Internal Server Error`, the client proceeds to download the error page payload as if it were the actual file content, marking the task completed successfully with a corrupted file.

5.  **Inefficient Preemption Loop**:
    *   The `do-while` loop in `DownloadQueue._schedule()` preempts active tasks one by one if a higher-priority task is queued.
    *   However, the loop does not re-sort or pop from the `_executionQueue`. Thus, if there are multiple active low-priority tasks and a single queued high-priority task, the loop preempts *all* low-priority active tasks (pausing their downloads and cancelling connections) before starting the high-priority task and immediately restarting all but one of the low-priority tasks.
    *   This causes excessive connection renegotiations and disk I/O overhead.

---

## 3. Caveats

No caveats. All files under `lib/downloader/` and `test/` were fully analyzed and the test failures were reproduced locally.

---

## 4. Conclusion & Verdict

**Verdict**: **REQUEST_CHANGES**

The core multi-threaded downloader implementation is not yet correct or production-ready due to a critical state conflict between the `DownloadQueue` and `DownloadSplitter`, which prevents any queued downloads from executing. Furthermore, multiple major resource leakages and error bypasses exist in the stream connection logic.

### Quality Review Report

#### Findings

##### [Critical] Finding 1: Download Splitter Early Return State Bug
*   **What**: The `DownloadSplitter` exits immediately without downloading bytes if the task state is already set to `downloading`.
*   **Where**: `lib/downloader/download_splitter.dart`, line 134.
*   **Why**: The `DownloadQueue` sets the state of the task to `downloading` prior to starting the splitter, which causes the splitter's guard check to evaluate to `true` and return early.
*   **Suggestion**: Splitter should track its own execution status via an internal boolean (e.g., `_isStarted`), or the `DownloadQueue` should allow the `DownloadSplitter` to manage and update the task state.

##### [Major] Finding 2: Stream/Socket Leak on Chunk Failure
*   **What**: Active chunk downloads are not cancelled if another chunk download fails.
*   **Where**: `lib/downloader/download_splitter.dart`, lines 154-155.
*   **Why**: When a chunk download throws an exception, `Future.wait` propagates it immediately, exiting `start()` and skipping cleanup of the other running futures.
*   **Suggestion**: In the `catch` block of `start()`, actively cancel all active subscriptions and close all open sinks.

##### [Major] Finding 3: Connection Leak during Server Probe
*   **What**: Fallback `GET` probe requests leak socket connections.
*   **Where**: `lib/downloader/download_splitter.dart`, lines 85-108.
*   **Why**: The stream of the `StreamedResponse` from `client.send` is never consumed or closed.
*   **Suggestion**: Consume the stream (e.g., by listening and discarding) or close the response connection.

##### [Major] Finding 4: Bypassed HTTP Status Check in Fallback
*   **What**: HTTP status code is not verified when range requests are not supported.
*   **Where**: `lib/downloader/download_splitter.dart`, lines 230-232.
*   **Why**: The code only asserts that the response is `206` if `rangeSupported` is true.
*   **Suggestion**: Add a status validation to ensure the response is 200 (OK) when range requests are not supported.

##### [Minor] Finding 5: Inefficient Preemption Scheduling Loop
*   **What**: Too many active tasks are preempted when a high-priority task is queued.
*   **Where**: `lib/downloader/download_queue.dart`, lines 101-128.
*   **Why**: The preemption loop does not account for the number of slots required, resulting in all active low-priority tasks being paused.
*   **Suggestion**: Calculate the number of tasks that need to be preempted to fit the new high-priority tasks, or refactor scheduling to sort all tasks together and activate the top N.

#### Verified Claims
*   `HttpRangeCalculator` calculates correct boundaries → verified via `test/downloader_test.dart` -> **PASS**
*   `FileCombiner` combines chunks and hashes → verified via `test/downloader_test.dart` -> **PASS**
*   `DownloadQueue` schedules based on priority and FIFO → verified via `test/downloader_test.dart` -> **PASS**
*   `DownloadQueue` preemption logic functions correctly under stress → verified via `test/challenger_m2_2_test.dart` -> **FAIL**
*   `DownloadSplitter` pause, resume, and persistence work → verified via `test/challenger_m2_1_test.dart` -> **FAIL**

---

### Adversarial Review Report

**Overall risk assessment**: **HIGH**

#### Challenges

##### [Critical] Challenge 1: Shared Task State early-exit return in Splitter
*   **Assumption challenged**: Splitter and Queue can share a single mutable task state without synchronization.
*   **Attack scenario**: Queue sets state to `downloading` before starting splitter. Splitter sees `downloading` and exits immediately.
*   **Blast radius**: All downloads initiated via `DownloadQueue` fail to download any bytes and remain stuck in `downloading` state.
*   **Mitigation**: Splitter should manage state internally or the Queue should not set `downloading` state until Splitter begins work.

##### [High] Challenge 2: Background resource leaks on partial download failures
*   **Assumption challenged**: When one chunk download fails, the exception thrown by `Future.wait` cleans up other chunks.
*   **Attack scenario**: One chunk download throws SocketException. The other chunks continue listening to response stream and writing to disk in the background.
*   **Blast radius**: Leaked HTTP connections, open file handles, wasted memory/bandwidth.
*   **Mitigation**: Cancel all subscriptions and close sinks of remaining chunks if any chunk fails.

##### [High] Challenge 3: HTTP connections leaked during server probe
*   **Assumption challenged**: Inspecting headers from `client.send(...)` is sufficient and does not leak resources.
*   **Attack scenario**: Server does not support HEAD. GET range-probe is sent. `client.send` is called, returning StreamedResponse. The stream is never read or closed.
*   **Blast radius**: TCP/socket connection leaks, server socket exhaustion.
*   **Mitigation**: Wrap probe client requests in `StreamSubscription.cancel()` or listen and discard stream.

##### [Medium] Challenge 4: Error bypass on single-chunk fallback
*   **Assumption challenged**: Server returns valid content on non-range requests.
*   **Attack scenario**: URL points to 404/500 page, server does not support range requests. The single chunk fallback GET request returns status 404, but no status code check is run.
*   **Blast radius**: Corrupted outputs where 404 HTML body is saved as target file, marked as successfully completed.
*   **Mitigation**: Validate that non-range response status is 200 (OK).

---

## 5. Verification Method

To verify the defects and check if a future fix resolves them:
1.  Run `flutter test` from `D:\02_Projects\Final_52191314_Server_and_Apps\aurora_downloader`.
2.  Inspect failures in `test/challenger_m2_1_test.dart` and `test/challenger_m2_2_test.dart`.
3.  Check that all tests pass once the fixes are applied.

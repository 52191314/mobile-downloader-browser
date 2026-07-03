# Handoff Report — Challenger 1 (Milestone 2 Verification)

## 1. Observation
- **Test File Created**: `test/challenger_m2_1_test.dart`
- **Execution Command**: `flutter test test/challenger_m2_1_test.dart`
- **Test Results**:
  - `DownloadSplitter Stress & Edge Cases` (direct splitter testing) **PASSED** both tests:
    - *Simulate 5 rapid pause/resume cycles on DownloadSplitter directly*
    - *Verify chunk failure midway on DownloadSplitter directly: transitions to failed with error and resumes*
  - `DownloadQueue Stress & Failure Cases` (queue-managed testing) **FAILED** both tests:
    - *Simulate 5 rapid pause/resume cycles using DownloadQueue*
      - Verbatim error output:
        ```
        Expected: DownloadState:<DownloadState.completed>
          Actual: DownloadState:<DownloadState.downloading>
        test\challenger_m2_1_test.dart 270:7                main.<fn>.<fn>
        ```
    - *Verify chunk failure midway: transitions to failed with error message and resumes correctly*
      - Verbatim error output:
        ```
        Expected: DownloadState:<DownloadState.failed>
          Actual: DownloadState:<DownloadState.downloading>
        test\challenger_m2_1_test.dart 315:7                main.<fn>.<fn>
        ```

- **Downloader Code Review**:
  - In `lib/downloader/download_splitter.dart` (lines 133-134):
    ```dart
    Future<void> start() async {
      if (task.state == DownloadState.downloading) return;
    ```
  - In `lib/downloader/download_queue.dart` (lines 134-138):
    ```dart
    final task = _tasks[nextTaskId]!;
    task.state = DownloadState.downloading;
    _taskUpdateController.add(task);
    _startTask(nextTaskId);
    ```

## 2. Logic Chain
1. When a task is added/resumed in `DownloadQueue`, the queue scheduling loop `_schedule()` runs.
2. If concurrency slots are available, the scheduler takes the next task and updates its state to `DownloadState.downloading` preemptively.
3. The queue then calls `_startTask()` which executes `splitter.start()`.
4. `DownloadSplitter.start()` contains a guard check: `if (task.state == DownloadState.downloading) return;`.
5. Because the queue already set `task.state` to `DownloadState.downloading`, this guard check evaluates to true, and `splitter.start()` returns immediately without executing any network range requests.
6. As a result, the task is marked as `downloading` in the queue and task models, but no stream subscriptions or network connections are active, leaving it stuck in this state forever.
7. This explains why both queue tests timed out/assert-failed with state `DownloadState.downloading`, while the direct `DownloadSplitter` tests (which bypass the queue) passed with 100% success and correct SHA-256 hashes.

## 3. Caveats
- The failure rate is 100% when using the `DownloadQueue` to execute tasks.
- If the implementation code in `lib/` is not modified to fix this mismatch, queue-managed downloads will never work in practice, even though the underlying `DownloadSplitter` is fully functional.

## 4. Conclusion
The core multi-threaded downloader engine (`DownloadSplitter`) is empirically robust and handles rapid pause/resume cycles and network disconnect failures perfectly when run directly. However, the integration between `DownloadQueue` and `DownloadSplitter` is broken due to a scheduling contract conflict. Specifically, the queue preemptively sets the task state to `downloading`, causing the splitter's safety check to trigger and abort download execution early.

### Suggested Mitigations:
1. **Option A**: Remove the preemptive state update in `DownloadQueue._schedule()`. Let `DownloadSplitter.start()` be solely responsible for setting `task.state = DownloadState.downloading` and notifying listeners.
2. **Option B**: Introduce an internal private state flag (e.g., `_isRunning`) in `DownloadSplitter` to guard against concurrent runs, instead of checking the public shared model property `task.state`.

---

# Adversarial Challenge Report

## Challenge Summary
**Overall risk assessment**: HIGH (Queue execution is completely broken, preventing any downloads from running via the queue).

## Challenges

### [High] Interface Contract Mismatch between DownloadQueue and DownloadSplitter
- **Assumption challenged**: The queue assumes it must manage and broadcast the `downloading` state change of a task before executing it.
- **Attack scenario**: Scheduling any task via the queue.
- **Blast radius**: No task managed by the `DownloadQueue` starts downloading or reaches completion. They all remain stuck in `DownloadState.downloading` with 0 bytes downloaded.
- **Mitigation**: Prevent the queue from modifying the task state to `downloading` before invoking the splitter, or change the splitter's guard check to use an internal flag.

### [Medium] Mock State-Only Testing Pitfall
- **Assumption challenged**: Prior unit tests assumed that asserting the enum value `task.state == DownloadState.downloading` meant the task was actually downloading data.
- **Attack scenario**: Verification of preemption and queue sorting without checking stream completion or byte progress.
- **Blast radius**: Allowed a critical execution bug to pass undetected in the test suite.
- **Mitigation**: Add assertions in tests to verify that `downloadedBytes` increases or that tasks reach `DownloadState.completed`.

## Stress Test Results

- **Splitter Direct Rapid Pause/Resume** → 5 quick cycles → Final file correct and SHA-256 verified → **PASS**
- **Splitter Direct Chunk Failure & Resume** → SocketException midway → Transitions to `failed` with error, resumes and completes correctly → **PASS**
- **Queue-Managed Rapid Pause/Resume** → Runs through queue scheduler → Stuck in `downloading` (no data downloaded) → **FAIL**
- **Queue-Managed Chunk Failure & Resume** → Runs through queue scheduler → Stuck in `downloading` (never encounters failure or completes) → **FAIL**

---

## 5. Verification Method
1. Run `flutter test test/challenger_m2_1_test.dart` to execute the stress tests.
2. Inspect the test output to see the two passing direct splitter tests and the two failing queue tests.
3. Apply one of the suggested mitigations in `lib/downloader/download_queue.dart` to verify that all tests in `test/challenger_m2_1_test.dart` and `test/downloader_test.dart` pass.

# Explorer Handoff Report — Milestone 2: Core Multi-threaded Downloader Design

This report provides the architectural design and implementation recommendations for **Milestone 2: Core Multi-threaded Downloader** in the `aurora_downloader` project.

---

## 1. Observation

The following observations were made after examining the workspace at `D:\02_Projects\Final_52191314_Server_and_Apps\aurora_downloader`:

1. **Clean Codebase Template**: The `lib/` directory contains only `main.dart` (123 lines), which is the standard Flutter counter application. The `test/` directory contains only `widget_test.dart` (30 lines) verifying the counter increment.
2. **Minimal Dependencies**: The `pubspec.yaml` contains only `cupertino_icons` under `dependencies` and `flutter_test` / `flutter_lints` under `dev_dependencies`. There are no packages for HTTP range handling, local directory location, or cryptography.
3. **Environment Viability**: As verified by Milestone 1, Flutter 3.32.1 and Dart 3.8.1 are installed. Running `flutter test` executes the template test suite successfully:
   ```
   00:01 +1: All tests passed!
   ```
4. **Target Platform Context**: The application is intended as a cross-platform mobile and desktop utility. File and folder management must adhere to sandbox conventions (e.g., using `path_provider` for system-independent directory paths).

---

## 2. Logic Chain

1. **Greenfield Implementation**: Because the codebase consists only of the default template (`main.dart`), the implementer has a clean canvas. The downloader must be built from the ground up, establishing clean domain models, repository/service interfaces, and unit tests.
2. **Dependency Extension**: To implement multi-threaded writing and checksum validation, we must add the following packages to `pubspec.yaml`:
   - `path_provider: ^2.1.3` (to access the temporary download directory path in a cross-platform way)
   - `crypto: ^3.0.3` (to perform SHA-256 validation of merged files)
   - `uuid: ^4.3.3` (to generate unique task identifiers if not provided by URL hashing)
3. **Multi-threading Approach**: Dart runs on a single thread (the main event loop). Standard asynchronous I/O (`HttpClient` with socket operations) allows concurrent range downloads because the underlying OS handles socket I/O in parallel. For large file operations (such as chunk merging or SHA-256 calculation), we should use CPU-bound workers (via Dart `Isolates`) to prevent UI stuttering.
4. **Task State & Resume Capabilities**: Storing downloaded chunks directly in a temporary folder (`${savePath}_tmp/part_$index`) and pairing them with a structured JSON metadata file (`${savePath}_tmp/meta.json`) provides crash-resilient persistence. Upon resume, the downloader can read the sizes of the partial chunk files on disk and continue downloading from the exact byte offset using the HTTP `Range: bytes=start-end` header.
5. **Priority Scheduling**: A priority queue with `Low`, `Medium`, and `High` levels can be implemented using a sorted `List` that is rearranged whenever a task's priority changes or when a new task is added. Implementing **preemptive priority scheduling** requires checking if a queued `High` task should suspend a running `Low` or `Medium` task if all active download slots (`maxConcurrentDownloads`) are full.

---

## 3. Caveats

1. **Server-Side Range Support**: The design relies on the remote server supporting HTTP range requests (returning `Accept-Ranges: bytes` and responding with HTTP status `206 Partial Content`). If a server does not support range requests:
   - The downloader must fall back to a single-threaded stream download (1 chunk, start = 0, end = totalBytes - 1).
   - Resuming from a partial byte offset will not be possible; if paused or interrupted, the task must restart from 0.
2. **Resource Consistency (ETag/Last-Modified)**: If a download is paused and the remote file is modified before the task is resumed, completing the download with stale chunks would result in a corrupted file. To mitigate this, the metadata file must record the server's `ETag` and/or `Last-Modified` header. On resume, the downloader must perform a `HEAD` request and invalidate existing chunks if the headers do not match.
3. **Concurrency Bottlenecks**: Writing to disk concurrently using multiple threads can bottleneck on low-end storage devices. The default chunk count should be configurable (typically 4 or 8) depending on file size and connection speed.

---

## 4. Conclusion

Below is the recommended architectural design for Milestone 2: Core Multi-threaded Downloader.

### A. Download Task States and Data Models

#### 1. DownloadState Enum
Represents the current lifecycle phase of a download task.

```dart
enum DownloadState {
  idle,         // Task is created or queued, waiting for an active slot
  downloading,  // Task is actively downloading chunks
  paused,       // Task has been suspended by the user; partial progress is saved
  completed,    // Chunks are successfully merged and SHA-256 verified
  failed        // Task stopped due to an error (network, disk, or checksum mismatch)
}
```

#### 2. DownloadPriority Enum
Determines the scheduling precedence of the task.

```dart
enum DownloadPriority {
  low,
  medium,
  high,
}
```

#### 3. Task State Transition Diagram
```
       [ Add Task ]
            |
            v
        +-------+     Start / Scheduled     +-------------+
  +---->| Idle  |-------------------------->| Downloading |
  |     +-------+                           +-------------+
  |         ^                                  |       |
  |         | Resume                           |       | Merge & Verify Success
  |         |                                  |       +---------------------> [ Completed ]
  |     +-------+           Pause              |
  +-----| Paused|<-----------------------------+
  |     +-------+                              | Error / Verify Fail
  |         ^                                  v
  |         | Retry                         +--------+
  +---------+-------------------------------| Failed |
                                            +--------+
```

#### 4. Model Class Definitions

##### DownloadChunk Model
Tracks byte range parameters and progress for a single HTTP thread.

```dart
class DownloadChunk {
  final int index;
  final int start;
  final int end;
  int bytesDownloaded; // Number of bytes written to the chunk file
  bool isCompleted;

  DownloadChunk({
    required this.index,
    required this.start,
    required this.end,
    this.bytesDownloaded = 0,
    this.isCompleted = false,
  });

  int get size => end - start + 1;

  Map<String, dynamic> toJson() => {
    'index': index,
    'start': start,
    'end': end,
    'bytesDownloaded': bytesDownloaded,
    'isCompleted': isCompleted,
  };

  factory DownloadChunk.fromJson(Map<String, dynamic> json) => DownloadChunk(
    index: json['index'],
    start: json['start'],
    end: json['end'],
    bytesDownloaded: json['bytesDownloaded'],
    isCompleted: json['isCompleted'] ?? false,
  );
}
```

##### DownloadTask Model
Tracks the main task progress, configurations, and list of chunks.

```dart
class DownloadTask {
  final String id;
  final String url;
  final String savePath;
  final String tempDir; // Path: ${savePath}_tmp
  final String? expectedHash; // Target SHA-256 hash (optional)
  DownloadPriority priority;
  DownloadState state;
  int totalBytes;
  int downloadedBytes;
  double speed; // In bytes/second
  String? actualHash;
  String? errorMessage;
  String? etag;
  String? lastModified;
  List<DownloadChunk> chunks;
  
  DownloadTask({
    required this.id,
    required this.url,
    required this.savePath,
    required this.tempDir,
    this.expectedHash,
    this.priority = DownloadPriority.medium,
    this.state = DownloadState.idle,
    this.totalBytes = -1,
    this.downloadedBytes = 0,
    this.speed = 0.0,
    this.actualHash,
    this.errorMessage,
    this.etag,
    this.lastModified,
    this.chunks = const [],
  });

  double get progress => totalBytes > 0 ? downloadedBytes / totalBytes : 0.0;

  Map<String, dynamic> toJson() => {
    'id': id,
    'url': url,
    'savePath': savePath,
    'tempDir': tempDir,
    'expectedHash': expectedHash,
    'priority': priority.name,
    'state': state.name,
    'totalBytes': totalBytes,
    'downloadedBytes': downloadedBytes,
    'etag': etag,
    'lastModified': lastModified,
    'chunks': chunks.map((c) => c.toJson()).toList(),
  };

  factory DownloadTask.fromJson(Map<String, dynamic> json) => DownloadTask(
    id: json['id'],
    url: json['url'],
    savePath: json['savePath'],
    tempDir: json['tempDir'],
    expectedHash: json['expectedHash'],
    priority: DownloadPriority.values.byName(json['priority']),
    state: DownloadState.values.byName(json['state']),
    totalBytes: json['totalBytes'],
    downloadedBytes: json['downloadedBytes'],
    etag: json['etag'],
    lastModified: json['lastModified'],
    chunks: (json['chunks'] as List)
        .map((c) => DownloadChunk.fromJson(c))
        .toList(),
  );
}
```

---

### B. Pause & Resume Logic and Chunk Persistence

#### 1. Directory Structure and Files
To download in a multi-threaded manner:
- Create a temporary directory named `${savePath}_tmp/` next to the destination file.
- Individual chunk parts will be saved to `${savePath}_tmp/part_$index`.
- A metadata file will be stored at `${savePath}_tmp/meta.json` to persist the download parameters.

```
/downloads/
├── my_video.mp4 (Final merged file when completed)
└── my_video.mp4_tmp/
    ├── meta.json  (Contains serialized DownloadTask info)
    ├── part_0     (Contains byte range 0 to 249,999)
    ├── part_1     (Contains byte range 250,000 to 499,999)
    ├── part_2     (Contains byte range 500,000 to 749,999)
    └── part_3     (Contains byte range 750,000 to 999,999)
```

#### 2. Downloader Logic Flow

```
[UI Trigger Start/Resume]
           |
           v
   Check if meta.json exists?
      /         \
   (Yes)        (No)
    /             \
Read meta.json    Send HTTP HEAD request
Verify ETag &      Check "Accept-Ranges" and "Content-Length"
Size matches       Calculate chunk ranges based on thread count (N)
    |              Create temp dir & Save meta.json
    |             /
    v            v
For each Chunk (i = 0 to N-1):
  - Check file size of 'part_i' on disk (fileSize)
  - If fileSize == chunk.size -> Mark completed, skip
  - If fileSize < chunk.size  -> Request Range: 'bytes=(start + fileSize)-end'
                                  Open 'part_i' in FileMode.append
                                  Pipe HTTP stream directly to file
                                  Update bytesDownloaded = fileSize + responseBytes
  |
  +---> [ User triggers Pause ] -> Cancel HTTP Stream subscriptions
  |                                 Flush and Close all file handles
  |                                 Write updated meta.json
  |                                 Transition state to 'paused'
  |
  +---> [ Error Occurs ] --------> Cancel and Close handles
  |                                 Transition state to 'failed'
  |
  +---> [ All chunks finish ] ----> Transition to 'merging' state
                                    Merge part_0...part_N-1 sequentially into target path
                                    Verify SHA-256 checksum
                                    Delete temp directory
                                    Transition state to 'completed'
```

#### 3. Core Technical Details

##### Checking for Range Support
```dart
Future<Map<String, String?>> getFileMetadata(String url) async {
  final client = HttpClient();
  final uri = Uri.parse(url);
  final request = await client.headUrl(uri);
  final response = await request.close();
  
  final acceptRanges = response.headers.value(HttpHeaders.acceptRangesHeader);
  final contentLength = response.headers.value(HttpHeaders.contentLengthHeader);
  final etag = response.headers.value(HttpHeaders.etagHeader);
  final lastModified = response.headers.value(HttpHeaders.lastModifiedHeader);

  return {
    'acceptRanges': acceptRanges,
    'contentLength': contentLength,
    'etag': etag,
    'lastModified': lastModified,
  };
}
```

##### Chunk Stream Writer (Appended Range Writing)
When downloading a chunk, data is directly streamed to disk. The actual file length on disk acts as the source of truth for resuming.
```dart
Future<void> downloadChunk({
  required String url,
  required DownloadChunk chunk,
  required String chunkPath,
  required Function(int progressBytes) onProgress,
  required CancellationToken cancelToken,
}) async {
  final file = File(chunkPath);
  int diskBytes = 0;
  if (await file.exists()) {
    diskBytes = await file.length();
  }

  // If already complete, exit early
  if (diskBytes >= chunk.size) {
    chunk.isCompleted = true;
    chunk.bytesDownloaded = chunk.size;
    return;
  }

  final client = HttpClient();
  final request = await client.getUrl(Uri.parse(url));
  
  // Set Range header for the remaining range
  final int rangeStart = chunk.start + diskBytes;
  final int rangeEnd = chunk.end;
  request.headers.add(HttpHeaders.rangeHeader, 'bytes=$rangeStart-$rangeEnd');

  final response = await request.close();
  if (response.statusCode != HttpStatus.partialContent && diskBytes > 0) {
    throw Exception('Server does not support resuming range requests (Status: ${response.statusCode})');
  }

  final raf = await file.open(mode: FileMode.append);
  try {
    final subscription = response.listen(
      (data) async {
        await raf.writeFrom(data);
        diskBytes += data.length;
        chunk.bytesDownloaded = diskBytes;
        onProgress(data.length);
      },
      cancelOnError: true,
    );

    cancelToken.onCancel(() {
      subscription.cancel();
      raf.close();
      client.close(force: true);
    });

    await subscription.asFuture();
  } finally {
    await raf.close();
  }
}
```

##### Chunk Merging
We sequentialize the binary streams of each chunk into the final target path to conserve system memory.
```dart
Future<void> mergeChunks(List<String> chunkPaths, String destinationPath) async {
  final destFile = File(destinationPath);
  final sink = destFile.openWrite(mode: FileMode.write);

  for (final path in chunkPaths) {
    final chunkFile = File(path);
    if (!await chunkFile.exists()) {
      throw Exception('Missing chunk file: $path');
    }
    await sink.addStream(chunkFile.openRead());
  }
  await sink.close();
}
```

##### SHA-256 Validation
```dart
import 'package:crypto/crypto.dart';

Future<bool> verifyChecksum(String filePath, String expectedHash) async {
  final file = File(filePath);
  final stream = file.openRead();
  final hash = await sha256.bind(stream).first;
  return hash.toString().toLowerCase() == expectedHash.toLowerCase();
}
```

---

### C. Queue Priority Handling

The `DownloadQueue` is responsible for registering tasks, limiting active downloads, and enforcing priority order (`High` > `Medium` > `Low`).

#### 1. Scheduler Logic: Sorting & Preemption
- **Scheduling Order**: The waiting queue is sorted primarily by priority (descending) and secondarily by insertion timestamp (ascending / FIFO).
- **Active Limit**: A configurable parameter `maxConcurrentDownloads` (e.g., 3) controls how many tasks can reside in the `downloading` state.
- **Preemptive Priority**: When a higher-priority task is queued:
  - If there are free active slots, start it immediately.
  - If active slots are full, identify if any running task has a lower priority than the queued task.
  - If a lower-priority task is active, pause it (moving it back to `idle`/`queued`) and allocate its slot to the higher-priority task.

#### 2. Downloader Queue Class Interface

```dart
class DownloadQueue {
  final Map<String, DownloadTask> _tasks = {};
  final List<String> _executionQueue = []; // Queued task IDs
  final Set<String> _activeTasks = {};     // Active task IDs
  final int maxConcurrentDownloads;
  final bool enablePreemption;

  // Stream controller to notify UI of any task updates
  final StreamController<DownloadTask> _taskUpdateController = StreamController<DownloadTask>.broadcast();
  Stream<DownloadTask> get onTaskUpdated => _taskUpdateController.stream;

  DownloadQueue({
    this.maxConcurrentDownloads = 3,
    this.enablePreemption = true,
  });

  void addTask(DownloadTask task) {
    _tasks[task.id] = task;
    if (task.state == DownloadState.idle) {
      _executionQueue.add(task.id);
    }
    _schedule();
  }

  void pauseTask(String taskId) {
    final task = _tasks[taskId];
    if (task == null) return;

    if (_activeTasks.contains(taskId)) {
      _activeTasks.remove(taskId);
      _cancelTaskService(task);
    } else {
      _executionQueue.remove(taskId);
    }

    task.state = DownloadState.paused;
    _taskUpdateController.add(task);
    _schedule();
  }

  void resumeTask(String taskId) {
    final task = _tasks[taskId];
    if (task == null) return;

    task.state = DownloadState.idle;
    if (!_executionQueue.contains(taskId) && !_activeTasks.contains(taskId)) {
      _executionQueue.add(taskId);
    }
    _schedule();
  }

  void updatePriority(String taskId, DownloadPriority newPriority) {
    final task = _tasks[taskId];
    if (task == null) return;
    
    task.priority = newPriority;
    _schedule();
  }

  void _schedule() {
    // 1. Sort the queue: Priority Descending, then FIFO
    _executionQueue.sort((aId, bId) {
      final a = _tasks[aId]!;
      final b = _tasks[bId]!;
      final priorityCompare = b.priority.index.compareTo(a.priority.index);
      if (priorityCompare != 0) return priorityCompare;
      return a.id.compareTo(b.id); // Simple proxy for timestamp
    });

    // 2. Preemptive check
    if (enablePreemption && _activeTasks.isNotEmpty && _executionQueue.isNotEmpty) {
      bool preempted;
      do {
        preempted = false;
        
        // Find running task with lowest priority
        String? lowestActiveId;
        DownloadPriority lowestActivePriority = DownloadPriority.high;
        for (var activeId in _activeTasks) {
          final activeTask = _tasks[activeId]!;
          if (activeTask.priority.index < lowestActivePriority.index) {
            lowestActivePriority = activeTask.priority;
            lowestActiveId = activeId;
          }
        }

        // Find waiting task with highest priority
        final highestQueuedId = _executionQueue.first;
        final highestQueuedTask = _tasks[highestQueuedId]!;

        // Preempt if queued task is higher priority than the lowest running task
        if (lowestActiveId != null && highestQueuedTask.priority.index > lowestActivePriority.index) {
          _preemptTask(lowestActiveId);
          preempted = true;
        }
      } while (preempted && _executionQueue.isNotEmpty);
    }

    // 3. Start tasks up to capacity
    while (_activeTasks.length < maxConcurrentDownloads && _executionQueue.isNotEmpty) {
      final nextTaskId = _executionQueue.removeAt(0);
      _activeTasks.add(nextTaskId);
      final task = _tasks[nextTaskId]!;
      task.state = DownloadState.downloading;
      _taskUpdateController.add(task);
      _startTaskService(task);
    }
  }

  void _preemptTask(String taskId) {
    final task = _tasks[taskId]!;
    _activeTasks.remove(taskId);
    _cancelTaskService(task);
    task.state = DownloadState.idle;
    _executionQueue.add(taskId);
    _taskUpdateController.add(task);
  }

  void _startTaskService(DownloadTask task) {
    // Calls Downloader Service to run chunk tasks
    // Upon completion:
    //   _activeTasks.remove(task.id);
    //   task.state = DownloadState.completed;
    //   _schedule();
  }

  void _cancelTaskService(DownloadTask task) {
    // Sends cancel signal to task's active workers
  }
}
```

---

## 5. Verification Method

To verify the correct operation of the downloader design:

### 1. Verification Test Commands
Run the Flutter test command:
```powershell
flutter test
```

### 2. Suggested Unit Test Cases (in `test/downloader/downloader_test.dart`)

1. **Task Range Splitting Test**:
   - Verify that a file size of `1000` bytes split into `4` threads generates chunk ranges: `[0-249]`, `[250-499]`, `[500-749]`, and `[750-999]`.
   - Verify that an indivisible size (e.g., `1003` bytes) allocates the remainder to the last chunk correctly.

2. **Priority Ordering Test**:
   - Add tasks of priorities `[Low, High, Medium, Low]` in sequence.
   - Run the queue sort and verify the queue order results in `[High, Medium, Low, Low]`.

3. **Preemption Test**:
   - Set `maxConcurrentDownloads = 1`.
   - Start a `Low` priority task. Verify it enters the `downloading` state.
   - Queue a `High` priority task.
   - Verify that the `Low` priority task transitions to `idle` (paused/preempted) and the `High` priority task transitions to `downloading`.

4. **Chunk Resume Disk Verification Test**:
   - Write a partial chunk file (e.g. 50 bytes of a 100-byte range) to disk.
   - Initialize the chunk downloader worker.
   - Verify that the range request header is configured to start at `start + 50` bytes, and the local file is appended to rather than overwritten.

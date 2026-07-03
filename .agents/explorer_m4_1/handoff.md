# Handoff Report: Torrent Downloader Design & Integration Analysis

This report outlines the proposed design to introduce a core Torrent Downloader model/service in Dart, integrating it with the existing chunk-based HTTP downloader structure in `lib/downloader/`.

---

## 1. Observation

In the current codebase:
1. **`lib/downloader/models.dart`** defines:
   - `DownloadState`: Enums for `idle`, `downloading`, `paused`, `completed`, `failed`.
   - `DownloadChunk`: Tracks chunk indices, byte ranges, bytes downloaded, and completion.
   - `DownloadTask`: A concrete class representing download metadata, containing HTTP-specific fields (`url`, `etag`, `lastModified`, `headers`, and `chunks`). It handles serialization (`toJson()` and `factory DownloadTask.fromJson()`) and task comparison/prioritization (`compareTo()`).
2. **`lib/downloader/download_queue.dart`** manages concurrency, scheduling, priorities, and preemption. However, it is tightly coupled to `DownloadSplitter`:
   - It maintains a private `_splitters` map: `final Map<String, DownloadSplitter> _splitters = {};`
   - In `addTask()`, it instantiates `DownloadSplitter` directly for every task:
     ```dart
     if (!_splitters.containsKey(task.id)) {
       final splitter = DownloadSplitter(
         task: task,
         client: httpClient,
         numChunks: numChunksPerTask,
       );
       _splitters[task.id] = splitter;
       // ...
     ```
   - In `_startTask()`, `pauseTask()`, and `_preemptTask()`, it calls methods directly on `DownloadSplitter`.
3. **`lib/downloader/download_splitter.dart`** implements the HTTP-specific chunk download process using byte-range requests (`Range: bytes=start-end`), merges chunks using `FileCombiner`, and updates progress/speed metrics.

---

## 2. Logic Chain

1. **Need for Abstraction (Decoupling execution from scheduling)**: 
   Because `DownloadQueue` directly references and instantiates `DownloadSplitter`, we cannot currently support Torrent downloads without rewriting the queue or hacking Torrent logic into `DownloadSplitter`. To solve this, we must introduce an abstraction layer for task execution (e.g., a `DownloadRunner` interface) so that `DownloadQueue` can schedule and control both HTTP and Torrent tasks uniformly.
   
2. **Representing Torrent Tasks**: 
   Torrents are fundamentally different from single-file HTTP downloads: they use peer-to-peer protocols, track metadata such as peer/seeder counts, support upload/seeding statistics, and can download multiple files within a single torrent.
   - Adding a `DownloadType` (enum) lets us distinguish task types.
   - Subclassing `DownloadTask` to `TorrentDownloadTask` provides a clean, backward-compatible way to store Torrent-specific data (`infoHash`, `peersCount`, `seedersCount`, `uploadedBytes`, `uploadSpeed`, `files`) without polluting HTTP tasks.
   - Enhancing `DownloadTask.fromJson()` to support type-based polymorphic deserialization preserves existing JSON storage features.

3. **Decoupling Torrent Engine (TorrentService)**: 
   Handling BitTorrent sockets, DHT, magnet link resolution, tracker communication, and piece writing requires complex background operations. A dedicated, abstract `TorrentService` interface should manage this state.
   - A `TorrentDownloadRunner` (implementing `DownloadRunner`) can act as the bridge between `DownloadQueue` and `TorrentService`, receiving commands from the queue and translating them to the service.

---

## 3. Caveats

1. **Pure Dart vs. Native Bindings**:
   - Building a pure Dart BitTorrent client is complex and may suffer from performance issues with high connection counts.
   - Using native bindings (e.g., wrapping `libtorrent` in C++/Rust via Dart FFI) is significantly more robust and high-performing, but increases building/compilation complexity across Windows, macOS, Android, and iOS.
   - The proposed design remains **implementation-agnostic**, allowing developers to swap the underlying `TorrentService` backend.
2. **Visualizing Progress (Chunks vs. Pieces)**:
   - If the UI visualizes download chunks (like a heatmap), mapping BitTorrent "pieces" directly to `DownloadChunk` objects in `DownloadTask.chunks` allows the existing UI to be reused immediately.
   - However, for large torrents with thousands of pieces, this could cause memory and rendering bottlenecks. An alternative is to leave `chunks` empty and provide a list of `files` (`TorrentFileInfo`) for file-level progress tracking.

---

## 4. Conclusion & Proposls

### A. Core Interface & Model Designs

#### 1. DownloadType Enum & DownloadRunner Interface
Define in `lib/downloader/models.dart` or a new file:

```dart
enum DownloadType {
  http,
  torrent,
}

abstract class DownloadRunner {
  DownloadTask get task;
  Stream<DownloadTask> get onTaskUpdated;
  Future<void> start();
  Future<void> pause();
  Future<void> cancel();
}
```

#### 2. TorrentFileInfo Model
For tracking individual files inside a multi-file torrent:

```dart
class TorrentFileInfo {
  final int index;
  final String path; // Relative path inside target folder
  final int size;
  int downloadedBytes;
  bool isSelected;
  bool isCompleted;

  TorrentFileInfo({
    required this.index,
    required this.path,
    required this.size,
    this.downloadedBytes = 0,
    this.isSelected = true,
    this.isCompleted = false,
  });

  double get progress => size > 0 ? downloadedBytes / size : 0.0;

  Map<String, dynamic> toJson() => {
        'index': index,
        'path': path,
        'size': size,
        'downloadedBytes': downloadedBytes,
        'isSelected': isSelected,
        'isCompleted': isCompleted,
      };

  factory TorrentFileInfo.fromJson(Map<String, dynamic> json) => TorrentFileInfo(
        index: json['index'] as int,
        path: json['path'] as String,
        size: json['size'] as int,
        downloadedBytes: json['downloadedBytes'] as int? ?? 0,
        isSelected: json['isSelected'] as bool? ?? true,
        isCompleted: json['isCompleted'] as bool? ?? false,
      );
}
```

#### 3. TorrentDownloadTask Model
Extends `DownloadTask` with Torrent-specific metadata:

```dart
class TorrentDownloadTask extends DownloadTask {
  final String? infoHash;
  int peersCount;
  int seedersCount;
  int uploadedBytes;
  double uploadSpeed; // in bytes/second
  List<TorrentFileInfo> files;

  TorrentDownloadTask({
    required super.id,
    required super.url, // Magnet URI or local path to .torrent
    required super.savePath, // Destination root folder
    required super.tempDir,
    super.expectedHash,
    super.priority,
    super.state,
    super.totalBytes,
    super.downloadedBytes,
    super.speed,
    super.errorMessage,
    super.createdAt,
    this.infoHash,
    this.peersCount = 0,
    this.seedersCount = 0,
    this.uploadedBytes = 0,
    this.uploadSpeed = 0.0,
    this.files = const [],
  }) : super(type: DownloadType.torrent);

  @override
  Map<String, dynamic> toJson() {
    final data = super.toJson();
    data.addAll({
      'infoHash': infoHash,
      'peersCount': peersCount,
      'seedersCount': seedersCount,
      'uploadedBytes': uploadedBytes,
      'uploadSpeed': uploadSpeed,
      'files': files.map((f) => f.toJson()).toList(),
    });
    return data;
  }

  factory TorrentDownloadTask.fromJson(Map<String, dynamic> json) {
    return TorrentDownloadTask(
      id: json['id'] as String,
      url: json['url'] as String,
      savePath: json['savePath'] as String,
      tempDir: json['tempDir'] as String,
      expectedHash: json['expectedHash'] as String?,
      priority: DownloadPriority.values.byName(json['priority'] as String),
      state: DownloadState.values.byName(json['state'] as String),
      totalBytes: json['totalBytes'] as int,
      downloadedBytes: json['downloadedBytes'] as int,
      speed: (json['speed'] as num?)?.toDouble() ?? 0.0,
      errorMessage: json['errorMessage'] as String?,
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : DateTime.now(),
      infoHash: json['infoHash'] as String?,
      peersCount: json['peersCount'] as int? ?? 0,
      seedersCount: json['seedersCount'] as int? ?? 0,
      uploadedBytes: json['uploadedBytes'] as int? ?? 0,
      uploadSpeed: (json['uploadSpeed'] as num?)?.toDouble() ?? 0.0,
      files: (json['files'] as List<dynamic>?)
              ?.map((f) => TorrentFileInfo.fromJson(f as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }
}
```

### B. Torrent Service & Runner Integration

#### 1. TorrentService Definition
The main core engine service:

```dart
abstract class TorrentService {
  Future<void> initialize();
  Future<void> dispose();

  /// Subscribes to updates for all torrent tasks
  Stream<List<TorrentDownloadTask>> get onTasksUpdated;

  /// Starts or resumes torrent download session
  Future<void> startTorrent(String taskId);

  /// Pauses torrent session
  Future<void> pauseTorrent(String taskId);

  /// Stops and removes torrent, option to delete files on disk
  Future<void> removeTorrent(String taskId, {bool deleteData = false});

  /// Configures file inclusion/exclusion for a multi-file torrent
  Future<void> selectFiles(String taskId, List<int> fileIndexes, bool select);
}
```

#### 2. TorrentDownloadRunner Adapter
Implements `DownloadRunner` to bridge the queue and the service:

```dart
class TorrentDownloadRunner implements DownloadRunner {
  @override
  final TorrentDownloadTask task;
  final TorrentService _torrentService;
  
  final StreamController<DownloadTask> _updateController =
      StreamController<DownloadTask>.broadcast();

  TorrentDownloadRunner({
    required this.task,
    required TorrentService torrentService,
  }) : _torrentService = torrentService {
    // Listen to changes emitted by the TorrentService
    _torrentService.onTasksUpdated.listen((updatedTasks) {
      for (final updated in updatedTasks) {
        if (updated.id == task.id) {
          // Sync changes back to the task instance
          task.state = updated.state;
          task.downloadedBytes = updated.downloadedBytes;
          task.totalBytes = updated.totalBytes;
          task.speed = updated.speed;
          task.peersCount = updated.peersCount;
          task.seedersCount = updated.seedersCount;
          task.uploadedBytes = updated.uploadedBytes;
          task.uploadSpeed = updated.uploadSpeed;
          task.files = updated.files;
          task.errorMessage = updated.errorMessage;
          
          _updateController.add(task);
        }
      }
    });
  }

  @override
  Stream<DownloadTask> get onTaskUpdated => _updateController.stream;

  @override
  Future<void> start() => _torrentService.startTorrent(task.id);

  @override
  Future<void> pause() => _torrentService.pauseTorrent(task.id);

  @override
  Future<void> cancel() => _torrentService.removeTorrent(task.id, deleteData: true);
}
```

---

## C. How to Integrate into Existing Classes

### 1. In `lib/downloader/models.dart`:
- Add `DownloadType` enum.
- Add `final DownloadType type;` to `DownloadTask`.
- Update the default generative constructor of `DownloadTask` to set `this.type = DownloadType.http`.
- Update `DownloadTask.toJson()` to serialize the `type`.
- Modify `DownloadTask.fromJson()` to polymorphically delegate to `TorrentDownloadTask.fromJson()` when `type == 'torrent'`:
  ```dart
  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String? ?? 'http';
    if (typeStr == 'torrent') {
      return TorrentDownloadTask.fromJson(json);
    }
    // Return regular HTTP DownloadTask
    return DownloadTask(
      id: json['id'] as String,
      // ...
    );
  }
  ```

### 2. In `lib/downloader/download_splitter.dart`:
- Make `DownloadSplitter` implement `DownloadRunner`. (It already conforms to the method names `start()`, `pause()`, `cancel()`, so just adding `implements DownloadRunner` works cleanly).

### 3. In `lib/downloader/download_queue.dart`:
- Replace references to `DownloadSplitter` with `DownloadRunner`:
  ```dart
  // Before
  // final Map<String, DownloadSplitter> _splitters = {};
  
  // After
  final Map<String, DownloadRunner> _runners = {};
  ```
- Update `addTask()` to conditionally instantiate runners:
  ```dart
  void addTask(DownloadTask task) {
    _tasks[task.id] = task;

    if (!_runners.containsKey(task.id)) {
      final DownloadRunner runner;
      if (task.type == DownloadType.torrent) {
        runner = TorrentDownloadRunner(
          task: task as TorrentDownloadTask,
          torrentService: torrentService, // Injectable service instance
        );
      } else {
        runner = DownloadSplitter(
          task: task,
          client: httpClient,
          numChunks: numChunksPerTask,
        );
      }
      _runners[task.id] = runner;

      runner.onTaskUpdated.listen((updatedTask) {
        _taskUpdateController.add(updatedTask);
        if (updatedTask.state == DownloadState.completed ||
            updatedTask.state == DownloadState.failed) {
          _activeTasks.remove(updatedTask.id);
          _schedule();
        }
      });
    }
    // ...
  }
  ```

---

## 5. Verification Method

### Testing Plan
1. **Unit Tests (`test/torrent_integration_test.dart`)**:
   - **Polymorphic Serialization**: Write tests validating that serialization and deserialization of both `DownloadTask` and `TorrentDownloadTask` work correctly, ensuring `DownloadTask.fromJson()` correctly instantiates the subclass.
   - **Queue Integration**: Create a mock `TorrentService` and enqueue both HTTP tasks and Torrent tasks in a single `DownloadQueue`. Verify that:
     - The scheduler respects priorities across both download types.
     - Concurrency limits (`maxConcurrentDownloads`) are applied collectively.
     - Preemption successfully pauses a lower-priority HTTP/Torrent task to run a higher-priority task of either type.
2. **Execute Tests**:
   - Run the project's verification tests using:
     ```powershell
     flutter test
     ```

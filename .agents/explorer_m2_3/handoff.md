# Explorer Handoff Report — Milestone 2: Core Multi-threaded Downloader

## 1. Observation
The following observations were made regarding the `aurora_downloader` codebase structure and Dart/Flutter environment:

1. **Project Location and Structure**:
   * Root: `D:\02_Projects\Final_52191314_Server_and_Apps\aurora_downloader`
   * Key files and directories:
     * `pubspec.yaml` (SDK Constraint: `sdk: ^3.8.1`, dependencies: `flutter`, `cupertino_icons`, dev_dependencies: `flutter_test`, `flutter_lints`)
     * `lib/main.dart` (Default Flutter counter template)
     * `test/widget_test.dart` (Default Flutter counter widget test)
2. **Milestone 1 Conclusions**:
   * In Milestone 1, the environment was verified as fully functional under Flutter SDK `3.32.1` and Dart SDK `3.8.1`, compiling and passing default tests with `flutter test` successfully.
3. **Milestone 2 Goals**:
   * Implement core multi-threaded range-based downloader.
   * Calculate byte segments, execute parallel HTTP GET range requests, stream and combine chunks into a destination file, verify combined file integrity via SHA-256.
   * Control scheduling via a priority-based queue (High, Medium, Low) with a FIFO fallback for tie-breaking.
   * Provide a hermetic testing strategy using mock HTTP clients (`http.MockClient`) to avoid external network calls.

---

## 2. Logic Chain

1. **Byte Range Calculations**:
   * **Problem**: Dividing a file of size $L$ into $N$ segments needs to account for remainder bytes when $L$ is not perfectly divisible by $N$.
   * **Solution**: A calculator utility `HttpRangeCalculator` calculates start and end byte indices. Any remainder $R = L \pmod N$ is distributed evenly by adding 1 extra byte to the first $R$ segments. This yields contiguous, non-overlapping segments that cover the entire file range $[0, L - 1]$.
   * **Edge Case**: If the requested segment count $N$ exceeds the content length $L$, the calculator reduces the segment count to $L$ to avoid empty 0-byte range segments.

2. **Chunk Combining and Integrity Verification**:
   * **Problem**: Large files could cause Out-Of-Memory (OOM) exceptions if entire files or chunks are loaded into memory at once.
   * **Solution**: A streaming-based `FileCombiner` reads chunk files sequentially using `File.openRead()` and writes them to a single destination `IOSink`.
   * **Integrity**: The SHA-256 hash is computed using the `crypto` package stream API (`sha256.bind(destination.openRead()).first`) rather than reading the entire file as bytes, ensuring memory usage scales $O(1)$ with file size.

3. **Queue Priority Scheduling**:
   * **Problem**: The system must run concurrent download tasks and pick pending tasks based on user priority (High > Medium > Low) and queue order (FIFO for equal priority).
   * **Solution**: A `DownloadTask` class implements `Comparable<DownloadTask>` where priorities are ordered in descending order, and creation timestamps are compared ascending (FIFO) for equal priorities. A `DownloadQueue` class maintains a sorted array of tasks and executes them up to a `maxConcurrentDownloads` limit.

4. **HTTP Mocking**:
   * **Problem**: Network calls are flaky and slow down unit tests. Real range requests are also hard to guarantee against public URLs.
   * **Solution**: Using `package:http/testing.dart`, we construct a helper builder `HttpMockBuilder` that returns a `MockClient` responding to:
     * `HEAD` requests (returns `Content-Length` and optionally `Accept-Ranges`).
     * `GET` requests with `Range: bytes=start-end` header (returns `206 Partial Content` with the specified sublist of bytes).
     * `GET` requests without `Range` or on servers without range support (returns `200 OK` with full bytes).

---

## 3. Caveats
* **Third-Party Dependencies**: The proposed design uses the standard `crypto` package for SHA-256 hashing and the `http` package for HTTP requests and testing. These are not yet in `pubspec.yaml` and must be added by the Implementer agent:
  ```yaml
  dependencies:
    http: ^1.2.0
    crypto: ^3.0.3
  ```
* **Thread/Isolate Offloading**: In Dart, multi-threading is achieved via Isolates. While this report focuses on the high-level classes and unit tests, actual file downloads per chunk should ideally run on background Isolates using `Isolate.run` if CPU-bound parsing is required, or standard async I/O since I/O in Dart is non-blocking.

---

## 4. Conclusion
We recommend the following class designs and unit tests to implement and verify Milestone 2.

### 4.1. Range Calculation Design
```dart
class DownloadSegment {
  final int index;
  final int start;
  final int end;

  DownloadSegment({
    required this.index,
    required this.start,
    required this.end,
  });

  int get length => end - start + 1;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DownloadSegment &&
          runtimeType == other.runtimeType &&
          index == other.index &&
          start == other.start &&
          end == other.end;

  @override
  int get hashCode => index.hashCode ^ start.hashCode ^ end.hashCode;

  @override
  String toString() => 'DownloadSegment(index: $index, start: $start, end: $end, length: $length)';
}

class HttpRangeCalculator {
  static List<DownloadSegment> calculate({
    required int contentLength,
    required int maxSegments,
  }) {
    if (contentLength <= 0) {
      return [];
    }
    if (maxSegments <= 0) {
      throw ArgumentError('maxSegments must be greater than 0');
    }

    final actualSegments = maxSegments > contentLength ? contentLength : maxSegments;
    final int chunkSize = contentLength ~/ actualSegments;
    final int remainder = contentLength % actualSegments;

    final List<DownloadSegment> segments = [];
    int start = 0;

    for (int i = 0; i < actualSegments; i++) {
      final int extra = i < remainder ? 1 : 0;
      final int length = chunkSize + extra;
      final int end = start + length - 1;

      segments.add(DownloadSegment(
        index: i,
        start: start,
        end: end,
      ));
      start = end + 1;
    }

    return segments;
  }
}
```

### 4.2. Chunk Combining and Integrity Design
```dart
import 'dart:io';
import 'package:crypto/crypto.dart';

class FileCombiner {
  /// Combines a list of temporary chunk files in the order they appear
  /// into a single destination file.
  /// Then it calculates and returns the SHA-256 hash of the combined file.
  static Future<String> combineAndHash({
    required List<File> chunks,
    required File destination,
  }) async {
    await destination.parent.create(recursive: true);
    
    final IOSink sink = destination.openWrite(mode: FileMode.write);
    try {
      for (final chunk in chunks) {
        if (!await chunk.exists()) {
          throw FileSystemException('Chunk file does not exist', chunk.path);
        }
        await sink.addStream(chunk.openRead());
      }
    } finally {
      await sink.close();
    }

    final hash = await sha256.bind(destination.openRead()).first;
    return hash.toString();
  }
}
```

### 4.3. Queue Priority Design
```dart
import 'dart:async';

enum DownloadPriority implements Comparable<DownloadPriority> {
  low(0),
  medium(1),
  high(2);

  final int value;
  const DownloadPriority(this.value);

  @override
  int compareTo(DownloadPriority other) => value.compareTo(other.value);
}

class DownloadTask implements Comparable<DownloadTask> {
  final String id;
  final String url;
  final String destinationPath;
  final DownloadPriority priority;
  final DateTime createdAt;

  DownloadTask({
    required this.id,
    required this.url,
    required this.destinationPath,
    this.priority = DownloadPriority.medium,
    DateTime? createdAt,
  }) : this.createdAt = createdAt ?? DateTime.now();

  @override
  int compareTo(DownloadTask other) {
    final priorityComparison = other.priority.compareTo(this.priority);
    if (priorityComparison != 0) {
      return priorityComparison;
    }
    return this.createdAt.compareTo(other.createdAt);
  }
}

class DownloadQueue {
  final List<DownloadTask> _queue = [];
  bool _isProcessing = false;
  int _activeDownloads = 0;
  final int maxConcurrentDownloads;
  final Future<void> Function(DownloadTask task) taskExecutor;

  DownloadQueue({
    required this.taskExecutor,
    this.maxConcurrentDownloads = 1,
  });

  void addTask(DownloadTask task) {
    _queue.add(task);
    _queue.sort();
    _processQueue();
  }

  Future<void> _processQueue() async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      while (_queue.isNotEmpty && _activeDownloads < maxConcurrentDownloads) {
        final task = _queue.removeAt(0);
        _activeDownloads++;
        _runTask(task);
      }
    } finally {
      _isProcessing = false;
    }
  }

  Future<void> _runTask(DownloadTask task) async {
    try {
      await taskExecutor(task);
    } catch (_) {
    } finally {
      _activeDownloads--;
      _processQueue();
    }
  }
  
  int get pendingCount => _queue.length;
  int get activeCount => _activeDownloads;
}
```

### 4.4. Mock HTTP Client Strategy
```dart
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class HttpMockBuilder {
  static http.Client createMockDownloaderClient({
    required Uint8List fileData,
    required bool supportsRanges,
    String contentType = 'application/octet-stream',
  }) {
    return MockClient((request) async {
      if (request.method == 'HEAD') {
        final headers = {
          'Content-Length': fileData.length.toString(),
          'Content-Type': contentType,
        };
        if (supportsRanges) {
          headers['Accept-Ranges'] = 'bytes';
        }
        return http.Response('', 200, headers: headers);
      }

      if (request.method == 'GET') {
        final rangeHeader = request.headers['Range'];

        if (rangeHeader != null) {
          if (!supportsRanges) {
            return http.Response.bytes(
              fileData,
              200,
              headers: {
                'Content-Length': fileData.length.toString(),
                'Content-Type': contentType,
              },
            );
          }

          final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(rangeHeader);
          if (match == null) {
            return http.Response('Invalid range header format', 400);
          }

          final start = int.parse(match.group(1)!);
          final end = int.parse(match.group(2)!);

          if (start < 0 || end >= fileData.length || start > end) {
            return http.Response('Requested range not satisfiable', 416, headers: {
              'Content-Range': 'bytes */${fileData.length}',
            });
          }

          final segmentData = fileData.sublist(start, end + 1);
          return http.Response.bytes(
            segmentData,
            206,
            headers: {
              'Content-Range': 'bytes $start-$end/${fileData.length}',
              'Content-Length': segmentData.length.toString(),
              'Content-Type': contentType,
            },
          );
        } else {
          return http.Response.bytes(
            fileData,
            200,
            headers: {
              'Content-Length': fileData.length.toString(),
              'Content-Type': contentType,
            },
          );
        }
      }

      return http.Response('Method not allowed', 405);
    });
  }
}
```

---

## 5. Verification Method

To independently verify the designs, execute the following unit test suite:

### 5.1. Test Suite File (`test/downloader_milestone2_test.dart`)
```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

// [Insert the above classes here or import them once implemented]

void main() {
  group('HttpRangeCalculator Tests', () {
    test('dividing 1000-byte file into 3 segments distributes remainder', () {
      final segments = HttpRangeCalculator.calculate(contentLength: 1000, maxSegments: 3);
      
      expect(segments.length, 3);
      
      expect(segments[0].start, 0);
      expect(segments[0].end, 333);
      expect(segments[0].length, 334);

      expect(segments[1].start, 334);
      expect(segments[1].end, 666);
      expect(segments[1].length, 333);

      expect(segments[2].start, 667);
      expect(segments[2].end, 999);
      expect(segments[2].length, 333);

      final totalLength = segments.fold(0, (sum, seg) => sum + seg.length);
      expect(totalLength, 1000);
    });

    test('dividing 1000-byte file into 4 segments divides exactly', () {
      final segments = HttpRangeCalculator.calculate(contentLength: 1000, maxSegments: 4);
      
      expect(segments.length, 4);
      for (var i = 0; i < 4; i++) {
        expect(segments[i].length, 250);
        expect(segments[i].start, i * 250);
        expect(segments[i].end, (i + 1) * 250 - 1);
      }
    });

    test('small file division clamps segments to content length', () {
      final segments = HttpRangeCalculator.calculate(contentLength: 2, maxSegments: 5);
      expect(segments.length, 2);
      expect(segments[0].start, 0);
      expect(segments[0].end, 0);
      expect(segments[1].start, 1);
      expect(segments[1].end, 1);
    });

    test('empty content returns empty list', () {
      final segments = HttpRangeCalculator.calculate(contentLength: 0, maxSegments: 3);
      expect(segments, isEmpty);
    });

    test('invalid maxSegments throws ArgumentError', () {
      expect(() => HttpRangeCalculator.calculate(contentLength: 100, maxSegments: 0),
          throwsArgumentError);
      expect(() => HttpRangeCalculator.calculate(contentLength: 100, maxSegments: -1),
          throwsArgumentError);
    });
  });

  group('FileCombiner Tests', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('aurora_downloader_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('successfully combines chunks and computes correct SHA-256', () async {
      final chunkContents = [
        'Hello ',
        'World ',
        'from multi-threaded downloader!',
      ];
      final combinedString = chunkContents.join();
      final expectedHash = sha256.convert(utf8.encode(combinedString)).toString();

      final List<File> chunks = [];
      for (var i = 0; i < chunkContents.length; i++) {
        final chunkFile = File('${tempDir.path}/chunk_$i.bin');
        await chunkFile.writeAsString(chunkContents[i]);
        chunks.add(chunkFile);
      }

      final destinationFile = File('${tempDir.path}/destination.bin');

      final calculatedHash = await FileCombiner.combineAndHash(
        chunks: chunks,
        destination: destinationFile,
      );

      expect(await destinationFile.exists(), isTrue);
      expect(await destinationFile.readAsString(), combinedString);
      expect(calculatedHash, expectedHash);
    });

    test('throws FileSystemException when a chunk is missing', () async {
      final file1 = File('${tempDir.path}/chunk_1.bin');
      await file1.writeAsString('Part 1');
      final file2 = File('${tempDir.path}/missing_chunk.bin');
      
      final destinationFile = File('${tempDir.path}/destination.bin');

      expect(
        () => FileCombiner.combineAndHash(
          chunks: [file1, file2],
          destination: destinationFile,
        ),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('DownloadQueue Priority Tests', () {
    test('tasks are executed in descending order of priority (and FIFO for equal priority)', () async {
      final List<String> startedTasks = [];
      final Map<String, Completer<void>> taskCompleters = {};
      
      Future<void> mockExecutor(DownloadTask task) async {
        startedTasks.add(task.id);
        final completer = Completer<void>();
        taskCompleters[task.id] = completer;
        await completer.future;
      }

      final queue = DownloadQueue(
        taskExecutor: mockExecutor,
        maxConcurrentDownloads: 1,
      );

      final firstTask = DownloadTask(
        id: 'task_running',
        url: 'http://example.com/1',
        destinationPath: 'path1',
        priority: DownloadPriority.medium,
      );
      queue.addTask(firstTask);
      
      await Future.delayed(Duration.zero);
      expect(startedTasks, ['task_running']);

      final lowTask = DownloadTask(
        id: 'task_low',
        url: 'http://example.com/low',
        destinationPath: 'path_low',
        priority: DownloadPriority.low,
        createdAt: DateTime.now().add(Duration(milliseconds: 1)),
      );
      
      final highTask1 = DownloadTask(
        id: 'task_high_1',
        url: 'http://example.com/high1',
        destinationPath: 'path_high1',
        priority: DownloadPriority.high,
        createdAt: DateTime.now().add(Duration(milliseconds: 2)),
      );
      
      final highTask2 = DownloadTask(
        id: 'task_high_2',
        url: 'http://example.com/high2',
        destinationPath: 'path_high2',
        priority: DownloadPriority.high,
        createdAt: DateTime.now().add(Duration(milliseconds: 3)),
      );

      final mediumTask = DownloadTask(
        id: 'task_medium',
        url: 'http://example.com/medium',
        destinationPath: 'path_medium',
        priority: DownloadPriority.medium,
        createdAt: DateTime.now().add(Duration(milliseconds: 4)),
      );

      queue.addTask(lowTask);
      queue.addTask(highTask1);
      queue.addTask(highTask2);
      queue.addTask(mediumTask);

      taskCompleters['task_running']?.complete();
      await Future.delayed(Duration.zero);

      expect(startedTasks.last, 'task_high_1');
      taskCompleters['task_high_1']?.complete();
      await Future.delayed(Duration.zero);

      expect(startedTasks.last, 'task_high_2');
      taskCompleters['task_high_2']?.complete();
      await Future.delayed(Duration.zero);

      expect(startedTasks.last, 'task_medium');
      taskCompleters['task_medium']?.complete();
      await Future.delayed(Duration.zero);

      expect(startedTasks.last, 'task_low');
      taskCompleters['task_low']?.complete();
      await Future.delayed(Duration.zero);

      expect(startedTasks, [
        'task_running',
        'task_high_1',
        'task_high_2',
        'task_medium',
        'task_low',
      ]);
    });
  });

  group('HttpMockBuilder Mock Client Verification', () {
    test('mock client returns 206 with correct slice bytes when range requested', () async {
      final fileData = Uint8List.fromList(List.generate(100, (i) => i));
      final client = HttpMockBuilder.createMockDownloaderClient(
        fileData: fileData,
        supportsRanges: true,
      );

      // Verify HEAD request
      final headResponse = await client.head(Uri.parse('http://example.com/test.bin'));
      expect(headResponse.statusCode, 200);
      expect(headResponse.headers['Content-Length'], '100');
      expect(headResponse.headers['Accept-Ranges'], 'bytes');

      // Verify range GET request (bytes 10-19)
      final getResponse = await client.get(
        Uri.parse('http://example.com/test.bin'),
        headers: {'Range': 'bytes=10-19'},
      );
      expect(getResponse.statusCode, 206);
      expect(getResponse.headers['Content-Range'], 'bytes 10-19/100');
      expect(getResponse.headers['Content-Length'], '10');
      expect(getResponse.bodyBytes, fileData.sublist(10, 20));
    });

    test('mock client returns full file 200 OK if ranges are unsupported', () async {
      final fileData = Uint8List.fromList(List.generate(100, (i) => i));
      final client = HttpMockBuilder.createMockDownloaderClient(
        fileData: fileData,
        supportsRanges: false,
      );

      final getResponse = await client.get(
        Uri.parse('http://example.com/test.bin'),
        headers: {'Range': 'bytes=10-19'},
      );
      expect(getResponse.statusCode, 200);
      expect(getResponse.headers['Content-Length'], '100');
      expect(getResponse.bodyBytes, fileData);
    });
  });
}
```

### 5.2. Verification Command
To run tests, execute the project test command:
```powershell
flutter test test/downloader_milestone2_test.dart
```
**Expected Output**:
```
All tests passed!
```

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:aurora_downloader/downloader/downloader.dart';

class HttpMockBuilder {
  static http.Client createMockDownloaderClient({
    required Uint8List fileData,
    required bool supportsRanges,
    String contentType = 'application/octet-stream',
    Duration? streamDelay,
  }) {
    return MockClient.streaming((request, bodyStream) async {
      if (request.method == 'HEAD') {
        final headers = {
          'Content-Length': fileData.length.toString(),
          'Content-Type': contentType,
        };
        if (supportsRanges) {
          headers['Accept-Ranges'] = 'bytes';
        }
        return http.StreamedResponse(
          const Stream<List<int>>.empty(),
          200,
          headers: headers,
        );
      }

      if (request.method == 'GET') {
        final rangeHeader = request.headers['Range'];

        if (rangeHeader != null) {
          if (!supportsRanges) {
            return http.StreamedResponse(
              Stream.value(fileData),
              200,
              headers: {
                'Content-Length': fileData.length.toString(),
                'Content-Type': contentType,
              },
            );
          }

          final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(rangeHeader);
          if (match == null) {
            return http.StreamedResponse(
              Stream.value(utf8.encode('Invalid range header format')),
              400,
            );
          }

          final start = int.parse(match.group(1)!);
          final end = int.parse(match.group(2)!);

          if (start < 0 || end >= fileData.length || start > end) {
            return http.StreamedResponse(
              Stream.value(utf8.encode('Requested range not satisfiable')),
              416,
              headers: {'Content-Range': 'bytes */${fileData.length}'},
            );
          }

          final segmentData = fileData.sublist(start, end + 1);

          Stream<List<int>> byteStream() async* {
            const int chunkSize = 5;
            for (int i = 0; i < segmentData.length; i += chunkSize) {
              if (streamDelay != null) {
                await Future<void>.delayed(streamDelay);
              }
              final currentEnd = (i + chunkSize < segmentData.length)
                  ? i + chunkSize
                  : segmentData.length;
              yield segmentData.sublist(i, currentEnd);
            }
          }

          return http.StreamedResponse(
            byteStream(),
            206,
            headers: {
              'Content-Range': 'bytes $start-$end/${fileData.length}',
              'Content-Length': segmentData.length.toString(),
              'Content-Type': contentType,
            },
          );
        } else {
          return http.StreamedResponse(
            Stream.value(fileData),
            200,
            headers: {
              'Content-Length': fileData.length.toString(),
              'Content-Type': contentType,
            },
          );
        }
      }

      return http.StreamedResponse(
        Stream.value(utf8.encode('Method not allowed')),
        405,
      );
    });
  }
}

class HangingHeadClient extends http.BaseClient {
  final Uint8List fileData;
  int headRequests = 0;
  int getRequests = 0;

  HangingHeadClient(this.fileData);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'HEAD') {
      headRequests++;
      return Completer<http.StreamedResponse>().future;
    }

    if (request.method == 'GET') {
      getRequests++;
      return http.StreamedResponse(
        Stream<List<int>>.value(fileData),
        200,
        headers: {'Content-Type': 'application/octet-stream'},
      );
    }

    return http.StreamedResponse(Stream<List<int>>.empty(), 405);
  }
}

void main() {
  group('HttpRangeCalculator Tests', () {
    test('dividing 1000-byte file into 3 segments distributes remainder', () {
      final chunks = HttpRangeCalculator.calculate(
        contentLength: 1000,
        maxChunks: 3,
      );

      expect(chunks.length, 3);

      expect(chunks[0].start, 0);
      expect(chunks[0].end, 333);
      expect(chunks[0].size, 334);

      expect(chunks[1].start, 334);
      expect(chunks[1].end, 666);
      expect(chunks[1].size, 333);

      expect(chunks[2].start, 667);
      expect(chunks[2].end, 999);
      expect(chunks[2].size, 333);

      final totalLength = chunks.fold<int>(0, (sum, seg) => sum + seg.size);
      expect(totalLength, 1000);
    });

    test('dividing 1000-byte file into 4 segments divides exactly', () {
      final chunks = HttpRangeCalculator.calculate(
        contentLength: 1000,
        maxChunks: 4,
      );

      expect(chunks.length, 4);
      for (var i = 0; i < 4; i++) {
        expect(chunks[i].size, 250);
        expect(chunks[i].start, i * 250);
        expect(chunks[i].end, (i + 1) * 250 - 1);
      }
    });

    test('small file division clamps segments to content length', () {
      final chunks = HttpRangeCalculator.calculate(
        contentLength: 2,
        maxChunks: 5,
      );
      expect(chunks.length, 2);
      expect(chunks[0].start, 0);
      expect(chunks[0].end, 0);
      expect(chunks[1].start, 1);
      expect(chunks[1].end, 1);
    });

    test('empty content returns empty list', () {
      final chunks = HttpRangeCalculator.calculate(
        contentLength: 0,
        maxChunks: 3,
      );
      expect(chunks, isEmpty);
    });

    test('invalid maxSegments throws ArgumentError', () {
      expect(
        () => HttpRangeCalculator.calculate(contentLength: 100, maxChunks: 0),
        throwsArgumentError,
      );
      expect(
        () => HttpRangeCalculator.calculate(contentLength: 100, maxChunks: -1),
        throwsArgumentError,
      );
    });
  });

  group('FileCombiner Tests', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'aurora_downloader_test_',
      );
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
      final expectedHash = sha256
          .convert(utf8.encode(combinedString))
          .toString();

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
        deleteChunks: false,
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

  group('DownloadQueue Priority & Preemption Tests', () {
    late Directory tempDir;
    late Uint8List dummyData;
    late http.Client mockClient;
    DownloadQueue? activeQueue;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('aurora_queue_test_');
      dummyData = Uint8List.fromList(List.generate(50, (i) => i));
      mockClient = HttpMockBuilder.createMockDownloaderClient(
        fileData: dummyData,
        supportsRanges: true,
      );
      activeQueue = null;
    });

    tearDown(() async {
      if (activeQueue != null) {
        await activeQueue!.dispose();
      }

      if (await tempDir.exists()) {
        for (int i = 0; i < 10; i++) {
          try {
            await tempDir.delete(recursive: true);
            break;
          } catch (_) {
            if (i == 9) rethrow;
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
      }
    });

    test(
      'tasks are executed in descending order of priority (and FIFO for equal priority)',
      () async {
        final queue = DownloadQueue(
          maxConcurrentDownloads: 1,
          enablePreemption: false,
          httpClient: mockClient,
        );
        activeQueue = queue;

        final taskRunning = DownloadTask(
          id: 'task_running',
          url: 'http://example.com/running.bin',
          savePath: '${tempDir.path}/running.bin',
          tempDir: '${tempDir.path}/running_tmp',
          priority: DownloadPriority.medium,
        );

        final now = DateTime.now();

        final taskLow = DownloadTask(
          id: 'task_low',
          url: 'http://example.com/low.bin',
          savePath: '${tempDir.path}/low.bin',
          tempDir: '${tempDir.path}/low_tmp',
          priority: DownloadPriority.low,
          createdAt: now.add(const Duration(milliseconds: 10)),
        );

        final taskHigh1 = DownloadTask(
          id: 'task_high_1',
          url: 'http://example.com/high1.bin',
          savePath: '${tempDir.path}/high1.bin',
          tempDir: '${tempDir.path}/high1_tmp',
          priority: DownloadPriority.high,
          createdAt: now.add(const Duration(milliseconds: 20)),
        );

        final taskHigh2 = DownloadTask(
          id: 'task_high_2',
          url: 'http://example.com/high2.bin',
          savePath: '${tempDir.path}/high2.bin',
          tempDir: '${tempDir.path}/high2_tmp',
          priority: DownloadPriority.high,
          createdAt: now.add(const Duration(milliseconds: 30)),
        );

        // Start first task
        queue.addTask(taskRunning);
        expect(queue.activeTasks.first.id, 'task_running');

        // Add other tasks
        queue.addTask(taskLow);
        queue.addTask(taskHigh1);
        queue.addTask(taskHigh2);

        // Wait a microtask and check queued sorting order
        expect(queue.queuedTasks.length, 3);
        expect(queue.queuedTasks[0].id, 'task_high_1');
        expect(queue.queuedTasks[1].id, 'task_high_2');
        expect(queue.queuedTasks[2].id, 'task_low');
      },
    );

    test(
      'preemption pauses lower priority task when higher priority task added',
      () async {
        final slowMockClient = HttpMockBuilder.createMockDownloaderClient(
          fileData: dummyData,
          supportsRanges: true,
          streamDelay: const Duration(milliseconds: 50),
        );

        final queue = DownloadQueue(
          maxConcurrentDownloads: 1,
          enablePreemption: true,
          httpClient: slowMockClient,
        );
        activeQueue = queue;

        final taskLow = DownloadTask(
          id: 'task_low',
          url: 'http://example.com/low.bin',
          savePath: '${tempDir.path}/low.bin',
          tempDir: '${tempDir.path}/low_tmp',
          priority: DownloadPriority.low,
        );

        final taskHigh = DownloadTask(
          id: 'task_high',
          url: 'http://example.com/high.bin',
          savePath: '${tempDir.path}/high.bin',
          tempDir: '${tempDir.path}/high_tmp',
          priority: DownloadPriority.high,
        );

        queue.addTask(taskLow);
        expect(queue.activeTasks.first.id, 'task_low');
        expect(taskLow.state, DownloadState.downloading);

        // Wait a bit so low priority starts downloading
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Add high priority task
        queue.addTask(taskHigh);

        // Verify taskLow is preempted (paused/idle) and taskHigh is active
        expect(queue.activeTasks.first.id, 'task_high');
        expect(taskHigh.state, DownloadState.downloading);
        expect(taskLow.state, DownloadState.idle);
      },
    );

    test(
      'extensionless sniffed video/mp4 URLs are not routed to HLS downloader',
      () async {
        final client = HttpMockBuilder.createMockDownloaderClient(
          fileData: dummyData,
          supportsRanges: false,
          contentType: 'video/mp4',
        );
        final queue = DownloadQueue(
          maxConcurrentDownloads: 1,
          enablePreemption: false,
          httpClient: client,
        );
        activeQueue = queue;

        final task = DownloadTask(
          id: 'direct_extensionless_video',
          url: 'http://example.com/video/abc123',
          savePath: '${tempDir.path}/direct_video.mp4',
          tempDir: '${tempDir.path}/direct_video_tmp',
          expectedHash: sha256.convert(dummyData).toString(),
          contentType: 'video/mp4',
        );

        queue.addTask(task);

        var elapsedMs = 0;
        while (task.state != DownloadState.completed && elapsedMs < 2000) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          elapsedMs += 50;
        }

        expect(task.state, DownloadState.completed);
        expect(task.errorMessage, isNull);
        expect(task.downloadedBytes, dummyData.length);
        expect(await File(task.savePath).readAsBytes(), dummyData);
      },
    );

    test('saveToFile writes queued tasks through a temporary file', () async {
      final queue = DownloadQueue(
        maxConcurrentDownloads: 0,
        enablePreemption: false,
        httpClient: mockClient,
      );
      activeQueue = queue;

      final task = DownloadTask(
        id: 'persisted_task',
        url: 'http://example.com/persisted.bin',
        savePath: '${tempDir.path}/persisted.bin',
        tempDir: '${tempDir.path}/persisted_tmp',
      );
      queue.addTask(task);

      final queueFile = File('${tempDir.path}/queue.json');
      await queue.saveToFile(queueFile.path);

      final decoded = jsonDecode(await queueFile.readAsString());
      expect(decoded, isA<List<dynamic>>());
      expect((decoded as List<dynamic>).single['id'], 'persisted_task');
      expect(await File('${queueFile.path}.tmp').exists(), isFalse);
      expect(await File('${queueFile.path}.bak').exists(), isFalse);
    });

    test(
      'loadFromFile preserves corrupt queue file and emits warning',
      () async {
        final queue = DownloadQueue(httpClient: mockClient);
        activeQueue = queue;
        final queueFile = File('${tempDir.path}/queue.json');
        await queueFile.writeAsString('{not valid json');
        final warningFuture = queue.onWarning.first;

        await queue.loadFromFile(queueFile.path);

        final warning = await warningFuture;
        expect(warning, contains('Failed to restore download queue'));
        expect(await queueFile.exists(), isFalse);
        final preserved = await tempDir
            .list()
            .where((entity) => entity.path.contains('queue.json.corrupt'))
            .toList();
        expect(preserved, hasLength(1));
      },
    );
  });

  group('HttpMockBuilder Mock Client Verification', () {
    test(
      'mock client returns 206 with correct slice bytes when range requested',
      () async {
        final fileData = Uint8List.fromList(List.generate(100, (i) => i));
        final client = HttpMockBuilder.createMockDownloaderClient(
          fileData: fileData,
          supportsRanges: true,
        );

        // Verify HEAD request
        final headResponse = await client.head(
          Uri.parse('http://example.com/test.bin'),
        );
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
      },
    );

    test(
      'mock client returns full file 200 OK if ranges are unsupported',
      () async {
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
      },
    );
  });

  group('DownloadSplitter Pause & Resume Tests', () {
    late Directory tempDir;
    late Uint8List fileData;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('aurora_splitter_test_');
      fileData = Uint8List.fromList(List.generate(120, (i) => i));
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'can start, pause, persist progress to meta.json, and resume successfully',
      () async {
        final client = HttpMockBuilder.createMockDownloaderClient(
          fileData: fileData,
          supportsRanges: true,
          streamDelay: const Duration(milliseconds: 30),
        );

        final savePath = '${tempDir.path}/final_output.bin';
        final tempDirPath = '${tempDir.path}/final_output_tmp';

        final task = DownloadTask(
          id: 'test_task_1',
          url: 'http://example.com/largefile.bin',
          savePath: savePath,
          tempDir: tempDirPath,
          expectedHash: sha256.convert(fileData).toString(),
        );

        final splitter = DownloadSplitter(
          task: task,
          client: client,
          numChunks: 3,
        );

        // Start the download asynchronously
        unawaited(splitter.start());

        // Wait briefly for some data to download deterministically
        int elapsed = 0;
        while (task.downloadedBytes == 0 && elapsed < 3000) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          elapsed += 10;
        }

        // Pause the download
        await splitter.pause();
        expect(task.state, DownloadState.paused);
        expect(task.downloadedBytes, greaterThan(0));
        expect(task.downloadedBytes, lessThan(fileData.length));

        // Verify meta.json exists and contains saved chunk progress
        final metaFile = File('$tempDirPath/meta.json');
        expect(await metaFile.exists(), isTrue);

        final metaContent = await metaFile.readAsString();
        final metaJson = jsonDecode(metaContent) as Map<String, dynamic>;
        expect(metaJson['id'], 'test_task_1');
        expect(metaJson['downloadedBytes'], task.downloadedBytes);

        // Resume download by creating a new splitter using the same task
        final resumeSplitter = DownloadSplitter(
          task: task,
          client: client,
          numChunks: 3,
        );

        await resumeSplitter.start();

        expect(task.state, DownloadState.completed);
        expect(task.downloadedBytes, fileData.length);

        final finalFile = File(savePath);
        expect(await finalFile.exists(), isTrue);
        expect(await finalFile.readAsBytes(), fileData);

        // Temp directory should be cleaned up
        expect(await Directory(tempDirPath).exists(), isFalse);
      },
    );

    test('falls back to full GET when HEAD probe hangs', () async {
      final client = HangingHeadClient(fileData);
      final savePath = '${tempDir.path}/head_hang_output.bin';
      final tempDirPath = '${tempDir.path}/head_hang_tmp';
      final task = DownloadTask(
        id: 'head_hang_task',
        url: 'http://example.com/head-hangs.bin',
        savePath: savePath,
        tempDir: tempDirPath,
        expectedHash: sha256.convert(fileData).toString(),
      );

      final splitter = DownloadSplitter(
        task: task,
        client: client,
        numChunks: 3,
        probeTimeout: const Duration(milliseconds: 20),
        responseTimeout: const Duration(seconds: 1),
        bodyIdleTimeout: const Duration(seconds: 1),
      );

      await splitter.start();

      expect(client.headRequests, 1);
      expect(client.getRequests, greaterThanOrEqualTo(2));
      expect(task.state, DownloadState.completed);
      expect(task.downloadedBytes, fileData.length);
      expect(task.totalBytes, fileData.length);
      expect(await File(savePath).readAsBytes(), fileData);
    });
  });

  group('DownloadSplitter Defensive Checks (Phase 4)', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'aurora_splitter_defensive_',
      );
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'fails loudly when server returns 200 with empty body',
      () async {
        final client = MockClient((request) async {
          // HEAD returns no content-length, GET returns 200 empty
          if (request.method == 'HEAD') {
            return http.Response('', 200, headers: {});
          }
          return http.Response('', 200);
        });
        final savePath = '${tempDir.path}/empty.bin';
        final tempDirPath = '${tempDir.path}/empty_tmp';
        final task = DownloadTask(
          id: 'empty_task',
          url: 'http://example.com/empty.bin',
          savePath: savePath,
          tempDir: tempDirPath,
        );
        final splitter = DownloadSplitter(
          task: task,
          client: client,
          numChunks: 1,
        );
        await expectLater(
          splitter.start(),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'toString',
              contains('0 bytes'),
            ),
          ),
        );
        expect(task.state, DownloadState.failed);
        // The 0KB file must NOT exist on disk
        expect(await File(savePath).exists(), isFalse);
      },
    );

    test(
      'fails loudly when server returns 200 with HTML error page',
      () async {
        const htmlError =
            '<!DOCTYPE html><html><head><title>Access Denied</title></head>'
            '<body><h1>403 Forbidden</h1></body></html>';
        final client = MockClient((request) async {
          if (request.method == 'HEAD') {
            return http.Response(
              '',
              200,
              headers: {'content-length': htmlError.length.toString()},
            );
          }
          return http.Response.bytes(
            utf8.encode(htmlError),
            200,
            headers: {'content-type': 'text/html'},
          );
        });
        final savePath = '${tempDir.path}/htmlerror.bin';
        final tempDirPath = '${tempDir.path}/htmlerror_tmp';
        final task = DownloadTask(
          id: 'html_error_task',
          url: 'http://example.com/protected.bin',
          savePath: savePath,
          tempDir: tempDirPath,
        );
        final splitter = DownloadSplitter(
          task: task,
          client: client,
          numChunks: 1,
        );
        await expectLater(
          splitter.start(),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'toString',
              contains('HTML error page'),
            ),
          ),
        );
        expect(task.state, DownloadState.failed);
        expect(await File(savePath).exists(), isFalse);
      },
    );

    test(
      'fails loudly when server returns 200 with login page',
      () async {
        const loginPage =
            '<!DOCTYPE html><html><body><h1>Please sign in</h1></body></html>';
        final client = MockClient((request) async {
          if (request.method == 'HEAD') {
            return http.Response(
              '',
              200,
              headers: {'content-length': loginPage.length.toString()},
            );
          }
          return http.Response.bytes(
            utf8.encode(loginPage),
            200,
            headers: {'content-type': 'text/html'},
          );
        });
        final savePath = '${tempDir.path}/login.bin';
        final tempDirPath = '${tempDir.path}/login_tmp';
        final task = DownloadTask(
          id: 'login_task',
          url: 'http://example.com/protected.bin',
          savePath: savePath,
          tempDir: tempDirPath,
        );
        final splitter = DownloadSplitter(
          task: task,
          client: client,
          numChunks: 1,
        );
        await expectLater(
          splitter.start(),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'toString',
              contains('HTML error page'),
            ),
          ),
        );
        expect(task.state, DownloadState.failed);
      },
    );

    test(
      'HEAD 403 skips directly to GET probe (no 12s timeout wait)',
      () async {
        var headRequests = 0;
        var getProbes = 0;
        var getDownloads = 0;
        final fileData = Uint8List.fromList(List.generate(50, (i) => i));
        final client = MockClient.streaming((request, bodyStream) async {
          if (request.method == 'HEAD') {
            headRequests++;
            return http.StreamedResponse(
              const Stream<List<int>>.empty(),
              403,
            );
          }
          if (request.method == 'GET' &&
              request.headers['Range'] == 'bytes=0-0') {
            getProbes++;
            return http.StreamedResponse(
              Stream.value(fileData),
              200,
              headers: {
                'content-length': fileData.length.toString(),
                'accept-ranges': 'bytes',
              },
            );
          }
          getDownloads++;
          // Full file GET (no range) since supportsRanges is false here
          return http.StreamedResponse(
            Stream.value(fileData),
            200,
            headers: {'content-length': fileData.length.toString()},
          );
        });
        final savePath = '${tempDir.path}/head403.bin';
        final tempDirPath = '${tempDir.path}/head403_tmp';
        final task = DownloadTask(
          id: 'head_403_task',
          url: 'http://example.com/file.bin',
          savePath: savePath,
          tempDir: tempDirPath,
        );
        final splitter = DownloadSplitter(
          task: task,
          client: client,
          numChunks: 1,
        );
        await splitter.start();
        expect(headRequests, 1);
        expect(getProbes, 1);
        expect(getDownloads, 1);
        expect(task.state, DownloadState.completed);
        expect(await File(savePath).readAsBytes(), fileData);
      },
    );

    test(
      'retries with onTokenExpired URL when direct download returns 403',
      () async {
        var refreshCount = 0;
        final fileData = Uint8List.fromList(List.generate(40, (i) => i));
        final client = MockClient.streaming((request, bodyStream) async {
          final url = request.url.toString();
          if (url.contains('token=fresh')) {
            return http.StreamedResponse(
              Stream.value(fileData),
              200,
              headers: {'content-length': fileData.length.toString()},
            );
          }
          return http.StreamedResponse(
            const Stream<List<int>>.empty(),
            403,
          );
        });
        final savePath = '${tempDir.path}/refresh.bin';
        final tempDirPath = '${tempDir.path}/refresh_tmp';
        final task = DownloadTask(
          id: 'refresh_direct_task',
          url: 'http://example.com/file.bin',
          savePath: savePath,
          tempDir: tempDirPath,
        );
        task.onTokenExpired = ({bool forceReload = false}) async {
          refreshCount++;
          return 'http://example.com/file.bin?token=fresh';
        };
        final splitter = DownloadSplitter(
          task: task,
          client: client,
          numChunks: 1,
        );
        await splitter.start();
        expect(refreshCount, 1);
        expect(task.state, DownloadState.completed);
        expect(task.url, contains('token=fresh'));
        expect(await File(savePath).readAsBytes(), fileData);
      },
    );

    test(
      'fails when 403 and no onTokenExpired callback is set',
      () async {
        final client = MockClient.streaming((request, bodyStream) async {
          return http.StreamedResponse(
            const Stream<List<int>>.empty(),
            403,
          );
        });
        final savePath = '${tempDir.path}/no_refresh.bin';
        final tempDirPath = '${tempDir.path}/no_refresh_tmp';
        final task = DownloadTask(
          id: 'no_refresh_task',
          url: 'http://example.com/file.bin',
          savePath: savePath,
          tempDir: tempDirPath,
        );
        final splitter = DownloadSplitter(
          task: task,
          client: client,
          numChunks: 1,
        );
        await expectLater(
          splitter.start(),
          throwsA(isA<Exception>()),
        );
        expect(task.state, DownloadState.failed);
        expect(task.errorMessage, contains('403'));
      },
    );
  });
}

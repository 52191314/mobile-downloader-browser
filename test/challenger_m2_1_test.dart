import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:aurora_downloader/downloader/downloader.dart';

class FailureSimulatingClient extends http.BaseClient {
  final Uint8List fileData;
  final bool supportsRanges;
  bool shouldFail = false;
  int failAfterBytes = 0;
  int globalBytesSent = 0;
  final Duration chunkDelay;

  FailureSimulatingClient({
    required this.fileData,
    required this.supportsRanges,
    this.chunkDelay = const Duration(milliseconds: 5),
  });

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'HEAD') {
      final headers = {
        'Content-Length': fileData.length.toString(),
        'Content-Type': 'application/octet-stream',
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
      int start = 0;
      int end = fileData.length - 1;

      if (rangeHeader != null && supportsRanges) {
        final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(rangeHeader);
        if (match != null) {
          start = int.parse(match.group(1)!);
          end = int.parse(match.group(2)!);
        }
      }

      final segmentData = fileData.sublist(start, end + 1);

      Stream<List<int>> byteStream() async* {
        const int chunkSize = 5;
        for (int i = 0; i < segmentData.length; i += chunkSize) {
          if (chunkDelay.inMicroseconds > 0) {
            await Future<void>.delayed(chunkDelay);
          }

          final currentEnd = (i + chunkSize < segmentData.length)
              ? i + chunkSize
              : segmentData.length;
          final chunk = segmentData.sublist(i, currentEnd);

          if (shouldFail) {
            if (globalBytesSent + chunk.length >= failAfterBytes) {
              final partialLen = failAfterBytes - globalBytesSent;
              if (partialLen > 0) {
                globalBytesSent += partialLen;
                yield chunk.sublist(0, partialLen);
              }
              throw const SocketException('Simulated network disconnect');
            }
          }

          globalBytesSent += chunk.length;
          yield chunk;
        }
      }

      final status = rangeHeader != null && supportsRanges ? 206 : 200;
      final headers = {'Content-Type': 'application/octet-stream'};
      if (rangeHeader != null && supportsRanges) {
        headers['Content-Range'] = 'bytes $start-$end/${fileData.length}';
        headers['Content-Length'] = segmentData.length.toString();
      } else {
        headers['Content-Length'] = fileData.length.toString();
      }

      return http.StreamedResponse(byteStream(), status, headers: headers);
    }

    throw UnimplementedError('Unsupported method: ${request.method}');
  }
}

void main() {
  late Directory tempDir;
  late Uint8List testData;
  late String expectedHash;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('aurora_challenger_');
    testData = Uint8List.fromList(List.generate(200, (i) => i % 256));
    expectedHash = sha256.convert(testData).toString();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('DownloadSplitter Stress & Edge Cases', () {
    test(
      'Simulate 5 rapid pause/resume cycles on DownloadSplitter directly',
      () async {
        final client = FailureSimulatingClient(
          fileData: testData,
          supportsRanges: true,
          chunkDelay: const Duration(milliseconds: 15),
        );

        final savePath = '${tempDir.path}/splitter_rapid.bin';
        final tempDirPath = '${tempDir.path}/splitter_rapid_tmp';

        final task = DownloadTask(
          id: 'splitter_rapid_task',
          url: 'http://example.com/largefile.bin',
          savePath: savePath,
          tempDir: tempDirPath,
          expectedHash: expectedHash,
        );

        for (int i = 0; i < 5; i++) {
          final splitter = DownloadSplitter(
            task: task,
            client: client,
            numChunks: 4,
          );
          unawaited(splitter.start());
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await splitter.pause();
          expect(task.state, DownloadState.paused);
        }

        final finalSplitter = DownloadSplitter(
          task: task,
          client: client,
          numChunks: 4,
        );
        await finalSplitter.start();

        expect(task.state, DownloadState.completed);
        expect(task.downloadedBytes, testData.length);

        final finalFile = File(savePath);
        expect(await finalFile.exists(), isTrue);
        expect(await finalFile.readAsBytes(), testData);
        expect(task.actualHash, expectedHash);
      },
    );

    test(
      'Verify chunk failure midway on DownloadSplitter directly: transitions to failed with error and resumes',
      () async {
        final client = FailureSimulatingClient(
          fileData: testData,
          supportsRanges: true,
          chunkDelay: const Duration(milliseconds: 10),
        );

        client.shouldFail = true;
        client.failAfterBytes = 60;

        final savePath = '${tempDir.path}/splitter_failed.bin';
        final tempDirPath = '${tempDir.path}/splitter_failed_tmp';

        final task = DownloadTask(
          id: 'splitter_failed_task',
          url: 'http://example.com/largefile.bin',
          savePath: savePath,
          tempDir: tempDirPath,
          expectedHash: expectedHash,
        );

        final initialSplitter = DownloadSplitter(
          task: task,
          client: client,
          numChunks: 4,
        );

        try {
          await initialSplitter.start();
          fail('Should have thrown an exception');
        } catch (e) {
          expect(task.state, DownloadState.failed);
          expect(task.errorMessage, isNotNull);
          expect(task.errorMessage, contains('No internet connection'));
        }

        // Resume download with clean client and reset bytes sent
        client.shouldFail = false;
        client.globalBytesSent = 0;
        final resumeSplitter = DownloadSplitter(
          task: task,
          client: client,
          numChunks: 4,
        );

        await resumeSplitter.start();

        expect(task.state, DownloadState.completed);
        expect(task.downloadedBytes, testData.length);

        final finalFile = File(savePath);
        expect(await finalFile.exists(), isTrue);
        expect(await finalFile.readAsBytes(), testData);
        expect(task.actualHash, expectedHash);
      },
    );
  });

  group('DownloadQueue Stress & Failure Cases', () {
    test('Simulate 5 rapid pause/resume cycles using DownloadQueue', () async {
      final client = FailureSimulatingClient(
        fileData: testData,
        supportsRanges: true,
        chunkDelay: const Duration(milliseconds: 15),
      );

      final queue = DownloadQueue(
        maxConcurrentDownloads: 1,
        enablePreemption: false,
        httpClient: client,
        numChunksPerTask: 4,
      );
      addTearDown(() async => queue.dispose());

      final savePath = '${tempDir.path}/queue_rapid.bin';
      final tempDirPath = '${tempDir.path}/queue_rapid_tmp';

      final task = DownloadTask(
        id: 'queue_rapid_task',
        url: 'http://example.com/largefile.bin',
        savePath: savePath,
        tempDir: tempDirPath,
        expectedHash: expectedHash,
      );

      queue.addTask(task);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      for (int i = 0; i < 5; i++) {
        await queue.pauseTaskAsync(task.id);
        expect(task.state, DownloadState.paused);

        await queue.resumeTaskAsync(task.id);
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      int elapsedMs = 0;
      while (task.state != DownloadState.completed && elapsedMs < 2000) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        elapsedMs += 50;
      }

      expect(task.state, DownloadState.completed);
      expect(task.downloadedBytes, testData.length);

      final finalFile = File(savePath);
      expect(await finalFile.exists(), isTrue);
      expect(await finalFile.readAsBytes(), testData);
      expect(task.actualHash, expectedHash);
    });

    test(
      'Verify chunk failure midway: transitions to failed with error message and resumes correctly',
      () async {
        final client = FailureSimulatingClient(
          fileData: testData,
          supportsRanges: true,
          chunkDelay: const Duration(milliseconds: 10),
        );

        client.shouldFail = true;
        client.failAfterBytes = 60;

        final queue = DownloadQueue(
          maxConcurrentDownloads: 1,
          enablePreemption: false,
          httpClient: client,
          numChunksPerTask: 4,
        );
        addTearDown(() async => queue.dispose());

        final savePath = '${tempDir.path}/queue_failed.bin';
        final tempDirPath = '${tempDir.path}/queue_failed_tmp';

        final task = DownloadTask(
          id: 'queue_failed_task',
          url: 'http://example.com/largefile.bin',
          savePath: savePath,
          tempDir: tempDirPath,
          expectedHash: expectedHash,
        );

        queue.addTask(task);

        int elapsedMs = 0;
        while (task.state != DownloadState.failed && elapsedMs < 8000) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          elapsedMs += 50;
        }

        expect(task.state, DownloadState.failed);
        expect(task.errorMessage, isNotNull);
        expect(task.errorMessage, contains('No internet connection'));

        client.shouldFail = false;
        client.globalBytesSent = 0;
        await queue.resumeTaskAsync(task.id);

        elapsedMs = 0;
        while (task.state != DownloadState.completed && elapsedMs < 2000) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          elapsedMs += 50;
        }

        expect(task.state, DownloadState.completed);
        expect(task.downloadedBytes, testData.length);

        final finalFile = File(savePath);
        expect(await finalFile.exists(), isTrue);
        expect(await finalFile.readAsBytes(), testData);
        expect(task.actualHash, expectedHash);
      },
    );
  });
}

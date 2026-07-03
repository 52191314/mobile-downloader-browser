import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:aurora_downloader/downloader/downloader.dart';

class TestMockClientBuilder {
  static http.Client createMockClient({
    required Uint8List fileData,
    required bool supportsRanges,
    required Duration streamDelay,
  }) {
    return MockClient.streaming((request, bodyStream) async {
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
        if (rangeHeader != null && supportsRanges) {
          final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(rangeHeader);
          if (match != null) {
            final start = int.parse(match.group(1)!);
            final end = int.parse(match.group(2)!);
            final segmentData = fileData.sublist(start, end + 1);

            Stream<List<int>> byteStream() async* {
              const int chunkSize = 5;
              for (int i = 0; i < segmentData.length; i += chunkSize) {
                await Future<void>.delayed(streamDelay);
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
                'Content-Type': 'application/octet-stream',
              },
            );
          }
        }
      }
      return http.StreamedResponse(Stream.value(fileData), 200);
    });
  }
}

void main() {
  group('Challenger M2-2 Preemption Under Heavy Load Tests', () {
    late Directory tempDir;
    late Uint8List dummyData;
    late http.Client mockClient;
    DownloadQueue? activeQueue;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('challenger_m2_2_test_');
      dummyData = Uint8List.fromList(List.generate(100, (i) => i)); // 100 bytes
      mockClient = TestMockClientBuilder.createMockClient(
        fileData: dummyData,
        supportsRanges: true,
        streamDelay: const Duration(milliseconds: 50), // 50ms per 5-byte chunk
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
      'Test 1 [State Machine]: queue correctly updates task states and active list on preemption',
      () async {
        final queue = DownloadQueue(
          maxConcurrentDownloads: 3,
          enablePreemption: true,
          httpClient: mockClient,
          numChunksPerTask: 2,
        );
        activeQueue = queue;

        // Create 5 low-priority tasks
        final lowTasks = List.generate(5, (i) {
          return DownloadTask(
            id: 'low_task_$i',
            url: 'http://example.com/low_$i.bin',
            savePath: '${tempDir.path}/low_$i.bin',
            tempDir: '${tempDir.path}/low_${i}_tmp',
            priority: DownloadPriority.low,
          );
        });

        // Create 3 high-priority tasks
        final highTasks = List.generate(3, (i) {
          return DownloadTask(
            id: 'high_task_$i',
            url: 'http://example.com/high_$i.bin',
            savePath: '${tempDir.path}/high_$i.bin',
            tempDir: '${tempDir.path}/high_${i}_tmp',
            priority: DownloadPriority.high,
          );
        });

        // Queue 5 low-priority tasks
        for (final task in lowTasks) {
          queue.addTask(task);
        }

        // Assert state variable changes (L0, L1, L2 downloading)
        expect(queue.activeTasks.map((t) => t.id).toSet(), {
          'low_task_0',
          'low_task_1',
          'low_task_2',
        });
        for (int i = 0; i < 3; i++) {
          expect(lowTasks[i].state, DownloadState.downloading);
        }

        // Queue 3 high-priority tasks
        for (final task in highTasks) {
          queue.addTask(task);
        }

        // Assert that high-priority tasks preempted the low-priority tasks in terms of queue state
        expect(queue.activeTasks.map((t) => t.id).toSet(), {
          'high_task_0',
          'high_task_1',
          'high_task_2',
        });
        for (final task in highTasks) {
          expect(task.state, DownloadState.downloading);
        }
        for (final task in lowTasks) {
          expect(task.state, DownloadState.idle);
        }
      },
    );

    test(
      'Test 2 [Empirical Integration]: active tasks download bytes and stop downloading when preempted',
      () async {
        final queue = DownloadQueue(
          maxConcurrentDownloads: 3,
          enablePreemption: true,
          httpClient: mockClient,
          numChunksPerTask: 2,
        );
        activeQueue = queue;

        final lowTasks = List.generate(5, (i) {
          return DownloadTask(
            id: 'low_task_$i',
            url: 'http://example.com/low_$i.bin',
            savePath: '${tempDir.path}/low_$i.bin',
            tempDir: '${tempDir.path}/low_${i}_tmp',
            priority: DownloadPriority.low,
          );
        });

        final highTasks = List.generate(3, (i) {
          return DownloadTask(
            id: 'high_task_$i',
            url: 'http://example.com/high_$i.bin',
            savePath: '${tempDir.path}/high_$i.bin',
            tempDir: '${tempDir.path}/high_${i}_tmp',
            priority: DownloadPriority.high,
          );
        });

        for (final task in lowTasks) {
          queue.addTask(task);
        }

        // Wait 150ms to let active tasks download bytes
        await Future<void>.delayed(const Duration(milliseconds: 150));

        final l0ProgressBefore = lowTasks[0].downloadedBytes;
        final l1ProgressBefore = lowTasks[1].downloadedBytes;
        final l2ProgressBefore = lowTasks[2].downloadedBytes;

        // Assert that bytes were actually downloaded.
        // NOTE: This will FAIL because of the bug where DownloadSplitter.start() returns immediately
        // if task.state is already set to downloading by the queue.
        expect(
          l0ProgressBefore,
          greaterThan(0),
          reason: 'L0 must have downloaded bytes',
        );
        expect(
          l1ProgressBefore,
          greaterThan(0),
          reason: 'L1 must have downloaded bytes',
        );
        expect(
          l2ProgressBefore,
          greaterThan(0),
          reason: 'L2 must have downloaded bytes',
        );

        // Queue the 3 high-priority tasks
        for (final task in highTasks) {
          queue.addTask(task);
        }

        // Wait 300ms to verify no further progress is made by preempted tasks
        await Future<void>.delayed(const Duration(milliseconds: 300));

        final l0ProgressAfter = lowTasks[0].downloadedBytes;
        expect(
          l0ProgressAfter,
          l0ProgressBefore,
          reason: 'Preempted task L0 should not download further bytes',
        );
      },
    );
  });
}

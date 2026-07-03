import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:aurora_downloader/downloader/downloader.dart';

void main() {
  group('DownloadQueue Auto-Retry Tests', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('auto_retry_test');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('auto retry triggers on SocketException and respects attempts limit', () async {
      int requestCount = 0;
      final client = MockClient((request) async {
        requestCount++;
        throw const SocketException('Simulated network failure');
      });

      final queue = DownloadQueue(
        maxConcurrentDownloads: 1,
        autoRetry: true,
        httpClient: client,
      );

      final task = DownloadTask(
        id: 'retry_task',
        url: 'http://example.com/file.mp4',
        savePath: '${tempDir.path}/file.mp4',
        tempDir: '${tempDir.path}/retry_task_tmp',
      );

      queue.addTask(task);

      // Wait for task to fail and retry
      // Since delay is 2 seconds, we wait for a bit more than 6 seconds (3 retries * 2s)
      await Future<void>.delayed(const Duration(seconds: 7));

      // Check task status
      expect(task.state, DownloadState.failed);
      expect(task.errorMessage, contains('[Auto-retry failed after 3 attempts]'));
      expect(requestCount, greaterThanOrEqualTo(6));
      expect(requestCount, lessThanOrEqualTo(12));
    });
  });
}


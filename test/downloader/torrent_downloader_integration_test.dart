import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:aurora_downloader/downloader/downloader.dart';

import '../helpers/test_torrent_downloader.dart';

void main() {
  group('TorrentDownloader Integration Tests', () {
    late Directory tempDir;
    late String tempDirPath;
    late String savePath;
    late TorrentMetadata metadata;
    late Uint8List data;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('torrent_test');
      tempDirPath = tempDir.path;
      savePath = '$tempDirPath/output.bin';

      // 2 pieces of 32768 bytes each
      data = Uint8List.fromList(List.generate(32768 * 2, (i) => i % 256));
      final p1 = data.sublist(0, 32768);
      final p2 = data.sublist(32768, 32768 * 2);
      final h1 = sha1.convert(p1).bytes;
      final h2 = sha1.convert(p2).bytes;
      final correctPieces = Uint8List.fromList([...h1, ...h2]);

      metadata = TorrentMetadata(
        name: 'output.bin',
        pieceLength: 32768,
        pieces: correctPieces,
        infoHash: 'abcdefabcdefabcdefabcdefabcdefabcdefabcd',
        trackers: ['http://tracker.com'],
        files: [TorrentFileInfo(length: 32768 * 2, path: 'output.bin')],
        totalSize: 32768 * 2,
        isMultiFile: false,
      );
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('Pause and Resume torrent downloading', () async {
      final task = DownloadTask(
        id: 'task_1',
        url: 'magnet:?xt=urn:btih:abcdefabcdefabcdefabcdefabcdefabcdefabcd',
        savePath: savePath,
        tempDir: tempDirPath,
      );

      final downloader = TestTorrentDownloader(
        task: task,
        metadata: metadata,
        simulatedData: data,
      );

      await downloader.start();
      expect(task.state, DownloadState.downloading);

      // Let it tick once/twice, then pause
      await Future.delayed(const Duration(milliseconds: 70));
      await downloader.pause();
      expect(task.state, DownloadState.paused);
      final bytesAtPause = task.downloadedBytes;

      // Wait and verify no more progress is made while paused
      await Future.delayed(const Duration(milliseconds: 100));
      expect(task.downloadedBytes, bytesAtPause);

      // Resume download
      await downloader.start();
      expect(task.state, DownloadState.downloading);

      final completer = Completer<void>();
      downloader.onTaskUpdated.listen((t) {
        if (t.state == DownloadState.completed) {
          if (!completer.isCompleted) completer.complete();
        }
      });
      await completer.future.timeout(const Duration(seconds: 4));

      expect(task.state, DownloadState.completed);
      expect(task.downloadedBytes, 32768 * 2);

      final downloadedFile = File(savePath);
      expect(downloadedFile.existsSync(), isTrue);
      expect(downloadedFile.lengthSync(), 32768 * 2);
      expect(downloadedFile.readAsBytesSync(), data);
    });

    test('Checkpointing and resume from resume.json', () async {
      final task1 = DownloadTask(
        id: 'task_1',
        url: 'magnet:?xt=urn:btih:abcdefabcdefabcdefabcdefabcdefabcdefabcd',
        savePath: savePath,
        tempDir: tempDirPath,
      );

      final downloader1 = TestTorrentDownloader(
        task: task1,
        metadata: metadata,
        simulatedData: data,
      );

      await downloader1.start();
      final resumeFile = File('$tempDirPath/resume.json');
      var waitedMs = 0;
      var resumeContent = <String, dynamic>{};
      while (waitedMs < 5000) {
        if (resumeFile.existsSync()) {
          resumeContent =
              jsonDecode(resumeFile.readAsStringSync()) as Map<String, dynamic>;
          if ((resumeContent['downloadedBytes'] as int? ?? 0) > 0) {
            break;
          }
        }
        await Future.delayed(const Duration(milliseconds: 50));
        waitedMs += 50;
      }
      await downloader1.pause();

      expect(resumeFile.existsSync(), isTrue);
      expect(resumeContent['downloadedBytes'], greaterThan(0));

      // Create a new downloader instance with a new task targeting the same temp directory
      final task2 = DownloadTask(
        id: 'task_1',
        url: 'magnet:?xt=urn:btih:abcdefabcdefabcdefabcdefabcdefabcdefabcd',
        savePath: savePath,
        tempDir: tempDirPath,
      );

      final downloader2 = TestTorrentDownloader(
        task: task2,
        metadata: metadata,
        simulatedData: data,
      );

      await downloader2.start();
      // It should immediately load the resume checkpoint
      expect(task2.downloadedBytes, greaterThan(0));

      final completer = Completer<void>();
      downloader2.onTaskUpdated.listen((t) {
        if (t.state == DownloadState.completed) {
          if (!completer.isCompleted) completer.complete();
        }
      });
      await completer.future.timeout(const Duration(seconds: 4));

      expect(task2.state, DownloadState.completed);
      expect(File(savePath).readAsBytesSync(), data);
    });

    test('Corrupt piece hash validation, discard and retry', () async {
      final task = DownloadTask(
        id: 'task_1',
        url: 'magnet:?xt=urn:btih:abcdefabcdefabcdefabcdefabcdefabcdefabcd',
        savePath: savePath,
        tempDir: tempDirPath,
      );

      final downloader = TestTorrentDownloader(
        task: task,
        metadata: metadata,
        simulatedData: data,
        corruptPieceIndices: {0},
      );

      final stream = downloader.onTaskUpdated;
      final completer = Completer<void>();
      var hasDropped = false;
      var lastBytes = 0;

      stream.listen((t) {
        if (t.downloadedBytes < lastBytes) {
          hasDropped = true;
        }
        lastBytes = t.downloadedBytes;
        if (t.state == DownloadState.completed) {
          if (!completer.isCompleted) completer.complete();
        }
      });

      await downloader.start();
      await completer.future.timeout(const Duration(seconds: 5));

      expect(hasDropped, isTrue);
      expect(task.state, DownloadState.completed);
      expect(File(savePath).readAsBytesSync(), data);
    });

    test(
      'Disk full/write failures halt download and set state to failed',
      () async {
        final task = DownloadTask(
          id: 'task_1',
          url: 'magnet:?xt=urn:btih:abcdefabcdefabcdefabcdefabcdefabcdefabcd',
          savePath: savePath,
          tempDir: tempDirPath,
        );

        final downloader = TestTorrentDownloader(
          task: task,
          metadata: metadata,
          simulatedData: data,
        );
        downloader.simulateDiskFull = true;

        final completer = Completer<void>();
        downloader.onTaskUpdated.listen((t) {
          if (t.state == DownloadState.failed) {
            if (!completer.isCompleted) completer.complete();
          }
        });

        await downloader.start();
        await completer.future.timeout(const Duration(seconds: 3));

        expect(task.state, DownloadState.failed);
        expect(task.errorMessage, contains('Disk full'));
      },
    );

    test(
      'Preemption pauses lower priority torrent task when higher starts',
      () async {
        final queue = DownloadQueue(
          maxConcurrentDownloads: 1,
          enablePreemption: true,
        );
        addTearDown(() async => queue.dispose());

        final taskLow = DownloadTask(
          id: 'task_low',
          url: 'magnet:?xt=urn:btih:abcdefabcdefabcdefabcdefabcdefabcdefabcd',
          savePath: '$tempDirPath/low.bin',
          tempDir: '$tempDirPath/low_temp',
          priority: DownloadPriority.low,
        );

        final taskHigh = DownloadTask(
          id: 'task_high',
          url: 'magnet:?xt=urn:btih:1234512345123451234512345123451234512345',
          savePath: '$tempDirPath/high.bin',
          tempDir: '$tempDirPath/high_temp',
          priority: DownloadPriority.high,
        );

        queue.addTask(taskLow);

        await Future.delayed(const Duration(milliseconds: 100));
        expect(taskLow.state, DownloadState.downloading);
        expect(queue.activeTasks.map((t) => t.id), contains('task_low'));

        queue.addTask(taskHigh);

        await Future.delayed(const Duration(milliseconds: 150));
        expect(taskLow.state, DownloadState.idle);
        expect(taskHigh.state, DownloadState.downloading);
        expect(queue.activeTasks.map((t) => t.id), contains('task_high'));
        expect(queue.queuedTasks.map((t) => t.id), contains('task_low'));

        await queue.pauseTaskAsync('task_high');
      },
    );
  });
}

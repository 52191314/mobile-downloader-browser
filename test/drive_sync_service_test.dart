import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:aurora_downloader/downloader/downloader.dart';
import 'package:aurora_downloader/sync/sync.dart';

void main() {
  group('DriveSyncService', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('aurora_drive_sync_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('connect signs in to the Google Drive client', () async {
      final service = DriveSyncService(
        client: MockGoogleDriveClient(latency: Duration.zero),
      );

      final account = await service.connect();

      expect(account.email, 'aurora.user@example.com');
      expect(service.state.status, DriveConnectionStatus.connected);
      expect(service.isConnected, isTrue);
    });

    test('uploads a completed task once to the configured folder', () async {
      final file = File('${tempDir.path}/lecture.mp4');
      file.writeAsBytesSync(List<int>.generate(128, (index) => index));
      final service = DriveSyncService(
        client: MockGoogleDriveClient(latency: Duration.zero),
        destinationFolderName: 'Class Archive',
      );
      await service.connect();

      final task = DownloadTask(
        id: 'done-1',
        url: 'https://example.com/lecture.mp4',
        savePath: file.path,
        tempDir: '${tempDir.path}/tmp',
        state: DownloadState.completed,
        totalBytes: 128,
        downloadedBytes: 128,
      );

      final first = await service.syncCompletedTask(task);
      final second = await service.syncCompletedTask(task);

      expect(first, isNotNull);
      expect(first!.folderName, 'Class Archive');
      expect(first.uploadedBytes, 128);
      expect(second, isNull);
      expect(service.state.uploadHistory.length, 1);
    });

    test('deduplicates concurrent completed task uploads', () async {
      final file = File('${tempDir.path}/lecture-concurrent.mp4');
      file.writeAsBytesSync(List<int>.generate(256, (index) => index));
      final client = _SlowMockGoogleDriveClient();
      final service = DriveSyncService(client: client);
      await service.connect();

      final task = DownloadTask(
        id: 'done-concurrent',
        url: 'https://example.com/lecture-concurrent.mp4',
        savePath: file.path,
        tempDir: '${tempDir.path}/tmp',
        state: DownloadState.completed,
        totalBytes: 256,
        downloadedBytes: 256,
      );

      final results = await Future.wait([
        service.syncCompletedTask(task),
        service.syncCompletedTask(task),
      ]);
      final successfulResults = results.whereType<DriveUploadResult>().toList();

      expect(successfulResults, hasLength(1));
      expect(results.where((result) => result == null), hasLength(1));
      expect(client.fileUploadCount, 1);
      expect(service.state.uploadHistory.length, 1);
    });

    test('uploads a completed torrent directory', () async {
      final downloadDir = Directory('${tempDir.path}/torrent_payload')
        ..createSync();
      File('${downloadDir.path}/part-a.bin').writeAsBytesSync([1, 2, 3]);
      File('${downloadDir.path}/part-b.bin').writeAsBytesSync([4, 5]);
      final service = DriveSyncService(
        client: MockGoogleDriveClient(latency: Duration.zero),
      );
      await service.connect();

      final task = DownloadTask(
        id: 'torrent-1',
        url: 'magnet:?xt=urn:btih:3f4e2c1a00000000000000000000000000000000',
        savePath: downloadDir.path,
        tempDir: '${tempDir.path}/tmp',
        state: DownloadState.completed,
      );

      final result = await service.syncCompletedTask(task);

      expect(result, isNotNull);
      expect(result!.uploadedBytes, 5);
      expect(result.sourcePath, downloadDir.path);
    });

    test('reports an error when a completed file is missing', () async {
      final service = DriveSyncService(
        client: MockGoogleDriveClient(latency: Duration.zero),
      );
      await service.connect();

      final task = DownloadTask(
        id: 'missing-1',
        url: 'https://example.com/missing.zip',
        savePath: '${tempDir.path}/missing.zip',
        tempDir: '${tempDir.path}/tmp',
        state: DownloadState.completed,
      );

      final result = await service.syncCompletedTask(task);

      expect(result, isNull);
      expect(service.state.status, DriveConnectionStatus.error);
      expect(service.state.errorMessage, contains('not found'));
    });
  });
}

class _SlowMockGoogleDriveClient extends MockGoogleDriveClient {
  int fileUploadCount = 0;

  _SlowMockGoogleDriveClient() : super(latency: Duration.zero);

  @override
  Future<DriveUploadResult> uploadFile({
    required File file,
    required String folderName,
  }) async {
    fileUploadCount++;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return super.uploadFile(file: file, folderName: folderName);
  }
}

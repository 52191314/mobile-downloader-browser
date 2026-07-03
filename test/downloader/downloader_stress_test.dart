import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:aurora_downloader/downloader/downloader.dart';

void main() {
  group('Downloader Stress Tests', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('aurora_stress_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('Test 1: Transient network connection drops (SocketException) auto-retry', () async {
      int requestCount = 0;
      final client = MockClient((request) async {
        requestCount++;
        final path = request.url.path;
        if (path.endsWith('/playlist.m3u8')) {
          return http.Response('''
#EXTM3U
#EXTINF:1.0,
one.ts
#EXT-X-ENDLIST
''', 200);
        }
        if (path.endsWith('/one.ts')) {
          if (requestCount < 3) {
            // Throw socket connection failure on first few attempts
            throw const SocketException('Connection reset by peer');
          }
          return http.Response.bytes([1, 2, 3], 200);
        }
        return http.Response('Not Found', 404);
      });

      final task = DownloadTask(
        id: 'stress-1',
        url: 'https://cdn.example.com/playlist.m3u8',
        savePath: '${tempDir.path}/video.ts',
        tempDir: '${tempDir.path}/tmp-1',
      );

      final downloader = HlsDownloader(
        task: task,
        client: client,
        maxConcurrentSegments: 1,
      );

      await downloader.start();

      expect(task.state, DownloadState.completed);
      expect(await File(task.savePath).readAsBytes(), [1, 2, 3]);
      expect(requestCount, greaterThanOrEqualTo(3));
    });

    test('Test 2: HTTP 403 Forbidden with token refresh (onTokenExpired) mid-download', () async {
      int requestCount = 0;
      bool tokenRefreshed = false;

      final client = MockClient((request) async {
        requestCount++;
        final path = request.url.path;
        final query = request.url.query;

        if (path.endsWith('/playlist.m3u8')) {
          return http.Response('''
#EXTM3U
#EXTINF:1.0,
one.ts
#EXTINF:1.0,
two.ts
#EXT-X-ENDLIST
''', 200);
        }

        if (path.endsWith('/one.ts')) {
          return http.Response.bytes([10, 20], 200);
        }

        if (path.endsWith('/two.ts')) {
          // If token isn't refreshed/updated, return 403 Forbidden
          if (!query.contains('token=fresh') && !tokenRefreshed) {
            return http.Response('Forbidden', 403);
          }
          return http.Response.bytes([30, 40], 200);
        }

        return http.Response('Not Found', 404);
      });

      final task = DownloadTask(
        id: 'stress-2',
        url: 'https://cdn.example.com/playlist.m3u8',
        savePath: '${tempDir.path}/video_refresh.ts',
        tempDir: '${tempDir.path}/tmp-2',
      );

      task.onTokenExpired = ({bool forceReload = false}) async {
        tokenRefreshed = true;
        // Return a fresh URL with the signed token parameter
        return 'https://cdn.example.com/playlist.m3u8?token=fresh';
      };

      final downloader = HlsDownloader(
        task: task,
        client: client,
        maxConcurrentSegments: 1,
      );

      await downloader.start();

      expect(task.state, DownloadState.completed);
      expect(await File(task.savePath).readAsBytes(), [10, 20, 30, 40]);
      expect(tokenRefreshed, isTrue);
    });

    test('Test 3: HTTP 503 Server Temporary Failures retry recovery', () async {
      int oneRequestAttempts = 0;
      final client = MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/playlist.m3u8')) {
          return http.Response('''
#EXTM3U
#EXTINF:1.0,
one.ts
#EXT-X-ENDLIST
''', 200);
        }
        if (path.endsWith('/one.ts')) {
          oneRequestAttempts++;
          if (oneRequestAttempts < 3) {
            return http.Response('Service Unavailable', 503);
          }
          return http.Response.bytes([100, 101], 200);
        }
        return http.Response('Not Found', 404);
      });

      final task = DownloadTask(
        id: 'stress-3',
        url: 'https://cdn.example.com/playlist.m3u8',
        savePath: '${tempDir.path}/video_503.ts',
        tempDir: '${tempDir.path}/tmp-3',
      );

      final downloader = HlsDownloader(
        task: task,
        client: client,
        maxConcurrentSegments: 1,
      );

      await downloader.start();

      expect(task.state, DownloadState.completed);
      expect(await File(task.savePath).readAsBytes(), [100, 101]);
      expect(oneRequestAttempts, greaterThanOrEqualTo(3));
    });

    test('Test 4: Local filesystem / write permission / disk full errors', () async {
      final client = MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/playlist.m3u8')) {
          return http.Response('''
#EXTM3U
#EXTINF:1.0,
one.ts
#EXT-X-ENDLIST
''', 200);
        }
        if (path.endsWith('/one.ts')) {
          return http.Response.bytes([99, 99], 200);
        }
        return http.Response('Not Found', 404);
      });

      // Target an invalid directory path containing illegal characters to force a FileSystemException
      final task = DownloadTask(
        id: 'stress-4',
        url: 'https://cdn.example.com/playlist.m3u8',
        savePath: '${tempDir.path}/invalid_dir_?<>|*/video_disk_full.ts',
        tempDir: '${tempDir.path}/invalid_dir_?<>|*/tmp-4',
      );

      final downloader = HlsDownloader(
        task: task,
        client: client,
        maxConcurrentSegments: 1,
      );

      await expectLater(
        downloader.start(),
        throwsA(isA<FileSystemException>()),
      );

      expect(task.state, DownloadState.failed);
      expect(task.errorMessage, isNotEmpty);
    });

    test('Test 5: Race conditions on rapid pause/cancel calls during segment downloads', () async {
      final client = MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/playlist.m3u8')) {
          return http.Response('''
#EXTM3U
#EXTINF:0.1,
one.ts
#EXTINF:0.1,
two.ts
#EXTINF:0.1,
three.ts
#EXT-X-ENDLIST
''', 200);
        }
        // Artificial delay to simulate active downloading for cancellation/pause test
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return http.Response.bytes([9], 200);
      });

      final task = DownloadTask(
        id: 'stress-5',
        url: 'https://cdn.example.com/playlist.m3u8',
        savePath: '${tempDir.path}/video_race.ts',
        tempDir: '${tempDir.path}/tmp-5',
      );

      final downloader = HlsDownloader(
        task: task,
        client: client,
        maxConcurrentSegments: 1,
      );

      // Start the downloader async
      final downloadFuture = downloader.start();

      // Instantly pause/cancel while download is running
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await downloader.pause();

      await downloadFuture;

      // Make sure the state was safely set to paused or failed, and it did not crash the isolate/thread
      expect(
        task.state == DownloadState.paused || task.state == DownloadState.failed,
        isTrue,
      );
    });

    test('Test 6: AES decryption key 403 refresh and decryption failures', () async {
      int requestCount = 0;
      bool tokenRefreshed = false;

      final client = MockClient((request) async {
        requestCount++;
        final path = request.url.path;
        final query = request.url.query;

        if (path.endsWith('/encrypted.m3u8')) {
          return http.Response('''
#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x100f0e0d0c0b0a090807060504030201
#EXTINF:1.0,
one.ts
#EXT-X-ENDLIST
''', 200);
        }

        if (path.endsWith('/key.bin')) {
          if (!query.contains('token=fresh') && !tokenRefreshed) {
            return http.Response('Forbidden', 403);
          }
          // Return wrong key length to simulate key fetch corruption error
          return http.Response.bytes([1, 2, 3], 200);
        }

        if (path.endsWith('/one.ts')) {
          return http.Response.bytes([9, 9, 9], 200);
        }

        return http.Response('Not Found', 404);
      });

      final task = DownloadTask(
        id: 'stress-6',
        url: 'https://cdn.example.com/encrypted.m3u8',
        savePath: '${tempDir.path}/video_aes.ts',
        tempDir: '${tempDir.path}/tmp-6',
      );

      task.onTokenExpired = ({bool forceReload = false}) async {
        tokenRefreshed = true;
        return 'https://cdn.example.com/encrypted.m3u8?token=fresh';
      };

      final downloader = HlsDownloader(
        task: task,
        client: client,
        maxConcurrentSegments: 1,
      );

      // It should throw an exception due to key length corruption
      await expectLater(
        downloader.start(),
        throwsA(isA<StateError>()),
      );

      expect(task.state, DownloadState.failed);
      expect(tokenRefreshed, isTrue);
    });

    test('Test 7: Unrecoverable segment download failure (404 Not Found)', () async {
      final client = MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/playlist.m3u8')) {
          return http.Response('''
#EXTM3U
#EXTINF:1.0,
one.ts
#EXTINF:1.0,
two.ts
#EXT-X-ENDLIST
''', 200);
        }
        if (path.endsWith('/one.ts')) {
          return http.Response.bytes([1, 2], 200);
        }
        // Segment 2 fails completely
        return http.Response('Segment missing', 404);
      });

      final task = DownloadTask(
        id: 'stress-7',
        url: 'https://cdn.example.com/playlist.m3u8',
        savePath: '${tempDir.path}/video_fail.ts',
        tempDir: '${tempDir.path}/tmp-7',
      );

      final downloader = HlsDownloader(
        task: task,
        client: client,
        maxConcurrentSegments: 1,
      );

      await expectLater(
        downloader.start(),
        throwsA(isA<HttpException>()),
      );

      expect(task.state, DownloadState.failed);
      expect(task.errorMessage, contains('status 404'));
    });
  });
}

import 'dart:io';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:aurora_downloader/downloader/downloader.dart';

void main() {
  group('HlsPlaylistParser', () {
    test('parses relative TS segments and duration', () {
      final playlist = HlsPlaylistParser.parse('''
#EXTM3U
#EXT-X-TARGETDURATION:8
#EXTINF:6.0,
segment-1.ts
#EXTINF:7.5,
media/segment-2.ts
#EXT-X-ENDLIST
''', Uri.parse('https://cdn.example.com/path/master.m3u8'));

      expect(playlist.isMaster, isFalse);
      expect(playlist.segments.length, 2);
      expect(
        playlist.segments.first.uri.toString(),
        'https://cdn.example.com/path/segment-1.ts',
      );
      expect(
        playlist.segments.last.uri.toString(),
        'https://cdn.example.com/path/media/segment-2.ts',
      );
      expect(playlist.durationSeconds, 13.5);
    });

    test('parses master variants with bandwidth and resolution labels', () {
      final playlist = HlsPlaylistParser.parse('''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1500000,RESOLUTION=854x480
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=4500000,RESOLUTION=1920x1080
high/index.m3u8
''', Uri.parse('https://cdn.example.com/root.m3u8'));

      expect(playlist.isMaster, isTrue);
      expect(playlist.variants.length, 2);
      expect(playlist.variants.last.bandwidth, 4500000);
      expect(playlist.variants.last.resolution, '1920x1080');
      expect(playlist.variants.last.displayLabel, '1080p');
      expect(
        playlist.variants.last.uri.toString(),
        'https://cdn.example.com/high/index.m3u8',
      );
    });
  });

  group('HlsDownloader', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('aurora_hls_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'downloads all TS segments and merges them in playlist order',
      () async {
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
            return http.Response.bytes([1, 2, 3], 200);
          }
          if (path.endsWith('/two.ts')) {
            return http.Response.bytes([4, 5], 200);
          }
          return http.Response('missing', 404);
        });

        final task = DownloadTask(
          id: 'hls-1',
          url: 'https://cdn.example.com/playlist.m3u8',
          savePath: '${tempDir.path}/video.mp4',
          tempDir: '${tempDir.path}/tmp',
        );
        final downloader = HlsDownloader(
          task: task,
          client: client,
          maxConcurrentSegments: 1,
        );

        await downloader.start();

        expect(task.state, DownloadState.completed);
        expect(task.savePath.endsWith('video.ts'), isTrue);
        expect(await File(task.savePath).readAsBytes(), [1, 2, 3, 4, 5]);
        expect(await Directory('${tempDir.path}/tmp').exists(), isFalse);
      },
    );

    test('decrypts AES-128 encrypted playlists', () async {
      final key = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));
      final iv = Uint8List.fromList(List<int>.generate(16, (i) => 16 - i));
      final plainBytes = Uint8List.fromList([1, 2, 3, 4, 5]);
      final encryptedBytes = encrypt.Encrypter(
        encrypt.AES(encrypt.Key(key), mode: encrypt.AESMode.cbc),
      ).encryptBytes(plainBytes, iv: encrypt.IV(iv)).bytes;
      final client = MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/key.bin')) {
          return http.Response.bytes(key, 200);
        }
        if (path.endsWith('/one.ts')) {
          return http.Response.bytes(encryptedBytes, 200);
        }
        return http.Response('''
#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x100f0e0d0c0b0a090807060504030201
#EXTINF:1.0,
one.ts
#EXT-X-ENDLIST
''', 200);
      });

      final task = DownloadTask(
        id: 'hls-2',
        url: 'https://cdn.example.com/encrypted.m3u8',
        savePath: '${tempDir.path}/video.m3u8',
        tempDir: '${tempDir.path}/tmp',
      );
      final downloader = HlsDownloader(task: task, client: client);

      await downloader.start();

      expect(task.state, DownloadState.completed);
      expect(task.savePath.endsWith('video.ts'), isTrue);
      expect(await File(task.savePath).readAsBytes(), plainBytes);
    });

    test('downloads fMP4 HLS playlist with EXT-X-MAP init segment', () async {
      final client = MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/playlist.m3u8')) {
          return http.Response('''
#EXTM3U
#EXT-X-MAP:URI="init.mp4"
#EXTINF:1.0,
one.m4s
#EXTINF:1.0,
two.m4s
#EXT-X-ENDLIST
''', 200);
        }
        if (path.endsWith('/init.mp4')) {
          return http.Response.bytes([10, 20], 200);
        }
        if (path.endsWith('/one.m4s')) {
          return http.Response.bytes([30, 40], 200);
        }
        if (path.endsWith('/two.m4s')) {
          return http.Response.bytes([50], 200);
        }
        return http.Response('missing', 404);
      });

      final task = DownloadTask(
        id: 'hls-3',
        url: 'https://cdn.example.com/playlist.m3u8',
        savePath: '${tempDir.path}/video.m3u8',
        tempDir: '${tempDir.path}/tmp',
      );
      final downloader = HlsDownloader(
        task: task,
        client: client,
        maxConcurrentSegments: 1,
      );

      await downloader.start();

      expect(task.state, DownloadState.completed);
      expect(task.savePath.endsWith('video.mp4'), isTrue);
      expect(await File(task.savePath).readAsBytes(), [10, 20, 30, 40, 50]);
      expect(await Directory('${tempDir.path}/tmp').exists(), isFalse);
    });

    test('preserves query parameters (tokens) in segment requests', () async {
      final client = MockClient((request) async {
        final path = request.url.path;
        final query = request.url.query;
        if (query != 'token=secret') {
          return http.Response('Unauthorized', 403);
        }
        if (path.endsWith('/playlist.m3u8')) {
          return http.Response('''
#EXTM3U
#EXT-X-MAP:URI="init.mp4"
#EXTINF:1.0,
one.ts
#EXT-X-ENDLIST
''', 200);
        }
        if (path.endsWith('/init.mp4')) {
          return http.Response.bytes([1, 2], 200);
        }
        if (path.endsWith('/one.ts')) {
          return http.Response.bytes([3, 4], 200);
        }
        return http.Response('missing', 404);
      });

      final task = DownloadTask(
        id: 'hls-query',
        url: 'https://cdn.example.com/playlist.m3u8?token=secret',
        savePath: '${tempDir.path}/video.m3u8',
        tempDir: '${tempDir.path}/tmp',
      );
      final downloader = HlsDownloader(
        task: task,
        client: client,
        maxConcurrentSegments: 1,
      );

      await downloader.start();

      expect(task.state, DownloadState.completed);
      expect(await File(task.savePath).readAsBytes(), [1, 2, 3, 4]);
    });

    test(
      'queue routes extensionless mpegurl content type to HLS downloader',
      () async {
        final client = MockClient((request) async {
          final path = request.url.path;
          if (path.endsWith('/stream/abc123')) {
            return http.Response(
              '''
#EXTM3U
#EXTINF:1.0,
one.ts
#EXT-X-ENDLIST
''',
              200,
              headers: {'content-type': 'application/vnd.apple.mpegurl'},
            );
          }
          if (path.endsWith('/stream/one.ts')) {
            return http.Response.bytes([9, 8, 7], 200);
          }
          return http.Response('missing', 404);
        });
        final queue = DownloadQueue(
          maxConcurrentDownloads: 1,
          enablePreemption: false,
          httpClient: client,
        );
        final task = DownloadTask(
          id: 'hls-extensionless',
          url: 'https://cdn.example.com/stream/abc123',
          savePath: '${tempDir.path}/stream.mp4',
          tempDir: '${tempDir.path}/tmp_extensionless',
          contentType: 'application/vnd.apple.mpegurl',
        );

        queue.addTask(task);

        var elapsedMs = 0;
        while (task.state != DownloadState.completed && elapsedMs < 2000) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          elapsedMs += 50;
        }

        expect(task.state, DownloadState.completed);
        expect(task.savePath.endsWith('stream.ts'), isTrue);
        expect(await File(task.savePath).readAsBytes(), [9, 8, 7]);
      },
    );

    test(
      'fails loudly when all segments return 403 and no refresh callback',
      () async {
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
          // All segments return 403
          return http.Response('forbidden', 403);
        });

        final task = DownloadTask(
          id: 'hls-all-403',
          url: 'https://cdn.example.com/playlist.m3u8',
          savePath: '${tempDir.path}/video.mp4',
          tempDir: '${tempDir.path}/tmp_all_403',
        );
        final downloader = HlsDownloader(
          task: task,
          client: client,
          maxConcurrentSegments: 2,
        );

        await expectLater(
          downloader.start(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('All 2 segments failed'),
            ),
          ),
        );
        expect(task.state, DownloadState.failed);
        expect(task.errorMessage, contains('expired'));
        // The 0KB file must NOT exist on disk
        expect(await File(task.savePath).exists(), isFalse);
      },
    );

    test(
      'fails loudly when partial segments return 403 (no corrupt merge)',
      () async {
        final client = MockClient((request) async {
          final path = request.url.path;
          if (path.endsWith('/playlist.m3u8')) {
            return http.Response('''
#EXTM3U
#EXTINF:1.0,
one.ts
#EXTINF:1.0,
two.ts
#EXTINF:1.0,
three.ts
#EXT-X-ENDLIST
''', 200);
          }
          if (path.endsWith('/one.ts')) {
            return http.Response.bytes([1, 2, 3], 200);
          }
          if (path.endsWith('/two.ts')) {
            return http.Response('forbidden', 403);
          }
          if (path.endsWith('/three.ts')) {
            return http.Response.bytes([4, 5, 6], 200);
          }
          return http.Response('missing', 404);
        });

        final task = DownloadTask(
          id: 'hls-partial-403',
          url: 'https://cdn.example.com/playlist.m3u8',
          savePath: '${tempDir.path}/video.mp4',
          tempDir: '${tempDir.path}/tmp_partial_403',
        );
        final downloader = HlsDownloader(
          task: task,
          client: client,
          maxConcurrentSegments: 1,
        );

        await expectLater(
          downloader.start(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('1 of 3 segments failed'),
            ),
          ),
        );
        expect(task.state, DownloadState.failed);
        // No corrupt file left on disk
        expect(await File(task.savePath).exists(), isFalse);
      },
    );

    test(
      'token refresh rescues stale segments and completes successfully',
      () async {
        var refreshCount = 0;
        // First call returns a "refreshed" URL with a token; the mock
        // then allows that token through.
        final client = MockClient((request) async {
          final path = request.url.path;
          final token = request.url.queryParameters['token'];
          if (path.endsWith('/playlist.m3u8') && token == 'fresh') {
            return http.Response('''
#EXTM3U
#EXTINF:1.0,
one.ts
#EXT-X-ENDLIST
''', 200);
          }
          if (path.endsWith('/one.ts') && token == 'fresh') {
            return http.Response.bytes([7, 8, 9], 200);
          }
          if (path.endsWith('/playlist.m3u8')) {
            return http.Response('''
#EXTM3U
#EXTINF:1.0,
one.ts
#EXT-X-ENDLIST
''', 200);
          }
          if (path.endsWith('/one.ts')) {
            return http.Response('expired', 403);
          }
          return http.Response('missing', 404);
        });

        final task = DownloadTask(
          id: 'hls-refresh',
          url: 'https://cdn.example.com/playlist.m3u8',
          savePath: '${tempDir.path}/video.mp4',
          tempDir: '${tempDir.path}/tmp_refresh',
        );
        task.onTokenExpired = ({bool forceReload = false}) async {
          refreshCount++;
          return 'https://cdn.example.com/playlist.m3u8?token=fresh';
        };

        final downloader = HlsDownloader(
          task: task,
          client: client,
          maxConcurrentSegments: 1,
        );

        await downloader.start();

        expect(refreshCount, 1);
        expect(task.state, DownloadState.completed);
        expect(task.savePath.endsWith('video.ts'), isTrue);
        expect(await File(task.savePath).readAsBytes(), [7, 8, 9]);
      },
    );

    test(
      'gives up after token refresh still produces 403 (no infinite loop)',
      () async {
        var refreshCount = 0;
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
          return http.Response('still expired', 403);
        });

        final task = DownloadTask(
          id: 'hls-refresh-exhausted',
          url: 'https://cdn.example.com/playlist.m3u8',
          savePath: '${tempDir.path}/video.mp4',
          tempDir: '${tempDir.path}/tmp_refresh_exhausted',
        );
        task.onTokenExpired = ({bool forceReload = false}) async {
          refreshCount++;
          return 'https://cdn.example.com/playlist.m3u8?attempt=$refreshCount';
        };

        final downloader = HlsDownloader(
          task: task,
          client: client,
          maxConcurrentSegments: 1,
        );

        await expectLater(downloader.start(), throwsA(isA<StateError>()));
        // Should attempt exactly 2 refreshes before giving up
        expect(refreshCount, 2);
        expect(task.state, DownloadState.failed);
        expect(await File(task.savePath).exists(), isFalse);
      },
    );
  });
}

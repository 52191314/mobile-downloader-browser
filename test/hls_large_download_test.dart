// Empirical test: does Aurora's real HlsDownloader finish a >1.5 GB HLS
// download all the way (no OOM, no hang, no truncation/corruption)?
//
// Runs the ACTUAL downloader code (no device needed — flutter test runs on the
// host Dart VM). A local HttpServer streams a ~1.54 GB HLS (800 segments of
// 2,068,000 bytes each, every segment shaped like valid MPEG-TS: 0x47 sync byte
// every 188 bytes, and byte[1..3] encoding the segment index so we can prove
// ordering). The only thing mocked is the native TS->MP4 remux MethodChannel
// (no Android in this environment) — it just copies the merged .ts to .mp4.
//
// Integrity is verified by a single streaming read of the merged output:
//   - every 188th byte *within a segment* must be 0x47 (TS structure intact)
//   - byte[1] of every segment must equal that segment's index (ordering)
// No expensive full-file hashing, so it stays I/O-bound and fast.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aurora_downloader/downloader/hls_downloader.dart';
import 'package:aurora_downloader/downloader/models.dart';

const int kTsPacket = 188;
const int kBufPackets = 100; // buffer = 18800 bytes (multiple of 188)
const int kSegPackets = 11000; // segment = 2,068,000 bytes (~2.02 MB)
const int kSegmentBytes = kTsPacket * kSegPackets; // 2,068,000
const int kSegmentCount = 800; // ~1.54 GB total (> 1.5 GB)

late final Uint8List _baseBuffer;

void _buildBaseBuffer() {
  _baseBuffer = Uint8List(kTsPacket * kBufPackets);
  for (int i = 0; i < _baseBuffer.length; i++) {
    _baseBuffer[i] = (i % kTsPacket == 0) ? 0x47 : 0x00;
  }
}

Future<HttpServer> _startServer() async {
  final server = await HttpServer.bind('127.0.0.1', 0);
  server.listen((req) async {
    final path = req.uri.path;
    if (path == '/playlist.m3u8') {
      final sb = StringBuffer();
      sb.writeln('#EXTM3U');
      sb.writeln('#EXT-X-VERSION:3');
      sb.writeln('#EXT-X-TARGETDURATION:10');
      for (int i = 0; i < kSegmentCount; i++) {
        sb.writeln('#EXTINF:10.0,');
        sb.writeln('seg_${i.toString().padLeft(4, '0')}.ts');
      }
      sb.writeln('#EXT-X-ENDLIST');
      req.response
        ..statusCode = 200
        ..headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl')
        ..write(sb.toString())
        ..close();
      return;
    }
    final m = RegExp(r'/seg_(\d+)\.ts').firstMatch(path);
    if (m != null) {
      final seg = int.parse(m.group(1)!);
      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType('video', 'mp2t');
      req.response.contentLength = kSegmentBytes;
      if (req.method != 'HEAD') {
        final send = Uint8List.fromList(_baseBuffer);
        send[1] = seg & 0xff;
        send[2] = (seg >> 8) & 0xff;
        send[3] = (seg >> 16) & 0xff;
        final copies = kSegmentBytes ~/ send.length;
        for (int c = 0; c < copies; c++) {
          req.response.add(send);
        }
      }
      await req.response.close();
      return;
    }
    req.response.statusCode = 404;
    await req.response.close();
  });
  return server;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _buildBaseBuffer();

  testWidgets(
      'HlsDownloader finishes a >1.5GB HLS download (no OOM, no truncation)',
      (tester) async {
    // Mock the native TS->MP4 remux channel (no Android here): just copy.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('aurora_downloader/public_downloads'),
      (call) async {
        if (call.method == 'remuxTsToMp4') {
          final src = call.arguments['sourcePath'] as String;
          final dst = call.arguments['destPath'] as String;
          await File(src).copy(dst);
          return {'success': true, 'error': null};
        }
        return null;
      },
    );

    final server = await _startServer();
    final base = 'http://127.0.0.1:${server.port}';

    final workDir =
        await Directory(r'D:\aurora_hls_test').create(recursive: true);
    await workDir.delete(recursive: true); // fresh start (no resume)
    await workDir.create(recursive: true);
    final savePath = '${workDir.path}\\video.ts';
    final tempDir = '${workDir.path}\\segments';

    final task = DownloadTask(
      id: 'large-test',
      url: '$base/playlist.m3u8',
      savePath: savePath,
      tempDir: tempDir,
      state: DownloadState.idle,
      totalBytes: -1,
      downloadedBytes: 0,
    );

    final dl = HlsDownloader(task: task, maxConcurrentSegments: 16);
    int lastWrittenBytes = 0;
    DownloadState? lastState;
    dl.onTaskUpdated.listen((t) {
      if (t.state != lastState || (t.downloadedBytes - lastWrittenBytes).abs() >= 20 * 1024 * 1024) {
        lastState = t.state;
        lastWrittenBytes = t.downloadedBytes;
        try {
          File('D:\\progress.txt')
              .writeAsStringSync(
                  '[PROGRESS] state=${t.state} '
                  '${t.downloadedBytes}/${t.totalBytes} bytes\n',
                  mode: FileMode.append);
        } catch (_) {}
      }
    });

    File('D:\\progress.txt').writeAsStringSync(
        '[TEST] calling start() at ${DateTime.now()}\n');
    final rssStart = ProcessInfo.currentRss;
    var peakRss = rssStart;
    final memTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final r = ProcessInfo.currentRss;
      if (r > peakRss) peakRss = r;
    });

    Object? caught;
    try {
      await dl.start().timeout(const Duration(minutes: 15));
    } catch (e, s) {
      caught = '$e\n$s';
    } finally {
      memTimer.cancel();
    }
    File('D:\\progress.txt').writeAsStringSync(
        '[TEST] start() returned at ${DateTime.now()} caught=$caught\n');
    await dl.dispose();
    server.close(force: true);

    final out = File(task.savePath);
    final exists = await out.exists();
    final size = exists ? await out.length() : 0;
    debugPrint('[TEST] state=${task.state} error="${task.errorMessage}" '
        'reason=${task.failureReason}');
    debugPrint('[TEST] output=${task.savePath} exists=$exists '
        'size=$size (${(size / 1024 / 1024).toStringAsFixed(1)} MB)');
    debugPrint('[TEST] RSS start=${(rssStart / 1024 / 1024).toStringAsFixed(1)}MB '
        'peak=${(peakRss / 1024 / 1024).toStringAsFixed(1)}MB');

    expect(caught, isNull, reason: 'start() threw:\n$caught');
    expect(task.state, DownloadState.completed,
        reason: 'task did not complete (error="${task.errorMessage}")');
    expect(exists, isTrue, reason: 'output file missing');
    expect(size, greaterThan(1500 * 1024 * 1024),
        reason: 'output only ${size} bytes (< 1.5 GB)');
    expect(size, equals(kSegmentCount * kSegmentBytes),
        reason: 'output size ${size} != expected ${kSegmentCount * kSegmentBytes}');

    // Streaming integrity check: TS sync grid + per-segment index bytes.
    var pos = 0;
    var badSync = -1;
    var badIndex = -1;
    var badIndexVal = 0;
    await for (final chunk in out.openRead()) {
      for (int i = 0; i < chunk.length; i++) {
        final b = chunk[i];
        final local = pos % kSegmentBytes;
        if (local % kTsPacket == 0 && b != 0x47) {
          badSync = pos;
        }
        if (local == 1) {
          final seg = pos ~/ kSegmentBytes;
          if (b != (seg & 0xff)) {
            badIndex = pos;
            badIndexVal = b;
          }
        }
        pos++;
      }
    }
    expect(badSync, -1, reason: 'TS sync byte missing at offset $badSync');
    expect(badIndex, -1,
        reason: 'segment index byte wrong at offset $badIndex (got $badIndexVal)');
    expect(pos, equals(kSegmentCount * kSegmentBytes),
        reason: 'streamed $pos bytes, expected ${kSegmentCount * kSegmentBytes}');

    // Memory must stay bounded — buffering the whole 1.54 GB would blow past.
    expect(peakRss, lessThan(1500 * 1024 * 1024),
        reason: 'peak RSS ${(peakRss / 1024 / 1024).toStringAsFixed(0)}MB '
            'suggests in-memory buffering of the whole file');

    debugPrint('[TEST] PASS: ~1.54 GB HLS downloaded, merged, and verified '
        '(peak RSS ${(peakRss / 1024 / 1024).toStringAsFixed(0)}MB).');

    try {
      await workDir.delete(recursive: true);
    } catch (_) {}
  });
}

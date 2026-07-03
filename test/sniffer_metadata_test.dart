import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:aurora_downloader/sniffer/media_sniffer_engine.dart';
import 'package:aurora_downloader/sniffer/models/browser_tab.dart';
import 'package:aurora_downloader/sniffer/browser_controller.dart';

/// Builds a minimal MP4 byte stream containing a `tkhd` atom with the given
/// width/height (stored as 16.16 fixed-point) and a `mvhd` atom with the given
/// timescale + duration values.
Uint8List _buildMp4WithTkhdMvhd({
  required int width,
  required int height,
  required int mvhdTimescale,
  required int mvhdDuration,
  int mvhdVersion = 0,
}) {
  final bytes = <int>[];

  // --- tkhd atom (version 0) ---
  // Box layout: size(4) + 'tkhd'(4) + version(1) + flags(3) +
  //   creation_time(4) + modification_time(4) + track_id(4) +
  //   reserved(4) + duration(4) + reserved(8) + layer(2) + alt_group(2) +
  //   volume(2) + reserved(2) + matrix(36) + width(4) + height(4)
  // Total = 4 + 4 + 4 + 8 + 8 + 8 + 36 + 4 + 4 = 92 bytes
  final tkhdSize = 92;
  bytes.add((tkhdSize >> 24) & 0xFF);
  bytes.add((tkhdSize >> 16) & 0xFF);
  bytes.add((tkhdSize >> 8) & 0xFF);
  bytes.add(tkhdSize & 0xFF);
  bytes.addAll([0x74, 0x6b, 0x68, 0x64]); // 'tkhd'
  bytes.add(0); // version
  bytes.addAll([0, 0, 0]); // flags
  bytes.addAll([0, 0, 0, 0]); // creation_time
  bytes.addAll([0, 0, 0, 0]); // modification_time
  bytes.addAll([0, 0, 0, 1]); // track_id
  bytes.addAll([0, 0, 0, 0]); // reserved
  bytes.addAll([0, 0, 0, 0]); // duration
  bytes.addAll([0, 0, 0, 0, 0, 0, 0, 0]); // reserved 8 bytes
  bytes.addAll([0, 0]); // layer
  bytes.addAll([0, 0]); // alt_group
  bytes.addAll([0, 0]); // volume
  bytes.addAll([0, 0]); // reserved
  // matrix (36 bytes) - identity matrix
  bytes.addAll([
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x40,
    0x00,
    0x00,
    0x00,
  ]);
  // width and height as 16.16 fixed-point
  final wFixed = width << 16;
  final hFixed = height << 16;
  bytes.add((wFixed >> 24) & 0xFF);
  bytes.add((wFixed >> 16) & 0xFF);
  bytes.add((wFixed >> 8) & 0xFF);
  bytes.add(wFixed & 0xFF);
  bytes.add((hFixed >> 24) & 0xFF);
  bytes.add((hFixed >> 16) & 0xFF);
  bytes.add((hFixed >> 8) & 0xFF);
  bytes.add(hFixed & 0xFF);

  // --- mvhd atom ---
  int mvhdSize;
  if (mvhdVersion == 1) {
    // size(4) + 'mvhd'(4) + ver(1)+flags(3) + creation(8) + mod(8) +
    //   timescale(4) + duration(8) = 40 bytes
    mvhdSize = 40;
  } else {
    // size(4) + 'mvhd'(4) + ver(1)+flags(3) + creation(4) + mod(4) +
    //   timescale(4) + duration(4) = 28 bytes
    mvhdSize = 28;
  }
  bytes.add((mvhdSize >> 24) & 0xFF);
  bytes.add((mvhdSize >> 16) & 0xFF);
  bytes.add((mvhdSize >> 8) & 0xFF);
  bytes.add(mvhdSize & 0xFF);
  bytes.addAll([0x6D, 0x76, 0x68, 0x64]); // 'mvhd'
  bytes.add(mvhdVersion); // version (right after type)
  bytes.addAll([0, 0, 0]); // flags
  if (mvhdVersion == 1) {
    // creation_time (8 bytes) + modification_time (8 bytes)
    bytes.addAll([0, 0, 0, 0, 0, 0, 0, 0]);
    bytes.addAll([0, 0, 0, 0, 0, 0, 0, 0]);
    // timescale (4 bytes) at offset +24 from start of 'mvhd' signature
    bytes.add((mvhdTimescale >> 24) & 0xFF);
    bytes.add((mvhdTimescale >> 16) & 0xFF);
    bytes.add((mvhdTimescale >> 8) & 0xFF);
    bytes.add(mvhdTimescale & 0xFF);
    // duration (8 bytes) at offset +28 from start of 'mvhd' signature
    var d = mvhdDuration;
    for (var j = 7; j >= 0; j--) {
      bytes.add((d >> (j * 8)) & 0xFF);
    }
  } else {
    // creation_time (4) + modification_time (4) at offset +8 from 'mvhd' sig
    bytes.addAll([0, 0, 0, 0]);
    bytes.addAll([0, 0, 0, 0]);
    // timescale (4 bytes) at offset +16 from start of 'mvhd' signature
    bytes.add((mvhdTimescale >> 24) & 0xFF);
    bytes.add((mvhdTimescale >> 16) & 0xFF);
    bytes.add((mvhdTimescale >> 8) & 0xFF);
    bytes.add(mvhdTimescale & 0xFF);
    // duration (4 bytes) at offset +20 from start of 'mvhd' signature
    bytes.add((mvhdDuration >> 24) & 0xFF);
    bytes.add((mvhdDuration >> 16) & 0xFF);
    bytes.add((mvhdDuration >> 8) & 0xFF);
    bytes.add(mvhdDuration & 0xFF);
  }

  // Pad with zeros to ensure the buffer is large enough for the
  // bounds checks in the parser (i + 24 <= b.length for v0,
  // i + 36 <= b.length for v1).
  while (bytes.length < 256) {
    bytes.add(0);
  }

  return Uint8List.fromList(bytes);
}

/// Build a minimal MP4 byte stream containing `tkhd` (width/height),
/// `mvhd` (duration), `mdhd` (per-track timescale) and `stts` (first
/// sample delta). Together mdhd+stts let the sniffer derive the video
/// frame rate.
Uint8List _buildMp4WithStts({
  required int width,
  required int height,
  required int mdhdTimescale,
  required int sttsSampleDelta,
}) {
  final bytes = <int>[];

  // --- tkhd atom (version 0) ---
  final tkhdSize = 92;
  bytes.add((tkhdSize >> 24) & 0xFF);
  bytes.add((tkhdSize >> 16) & 0xFF);
  bytes.add((tkhdSize >> 8) & 0xFF);
  bytes.add(tkhdSize & 0xFF);
  bytes.addAll([0x74, 0x6b, 0x68, 0x64]); // 'tkhd'
  bytes.add(0);
  bytes.addAll([0, 0, 0]);
  bytes.addAll([0, 0, 0, 0]);
  bytes.addAll([0, 0, 0, 0]);
  bytes.addAll([0, 0, 0, 1]);
  bytes.addAll([0, 0, 0, 0]);
  bytes.addAll([0, 0, 0, 0]);
  bytes.addAll([0, 0, 0, 0, 0, 0, 0, 0]);
  bytes.addAll([0, 0]);
  bytes.addAll([0, 0]);
  bytes.addAll([0, 0]);
  bytes.addAll([0, 0]);
  bytes.addAll(List.filled(36, 0)); // matrix
  final wFixed = width << 16;
  final hFixed = height << 16;
  bytes.add((wFixed >> 24) & 0xFF);
  bytes.add((wFixed >> 16) & 0xFF);
  bytes.add((wFixed >> 8) & 0xFF);
  bytes.add(wFixed & 0xFF);
  bytes.add((hFixed >> 24) & 0xFF);
  bytes.add((hFixed >> 16) & 0xFF);
  bytes.add((hFixed >> 8) & 0xFF);
  bytes.add(hFixed & 0xFF);

  // --- mdhd atom (version 0) ---
  // size(4) + 'mdhd'(4) + ver(1)+flags(3) + creation(4) + mod(4) +
  //   timescale(4) + duration(4) + language(2) + pre_defined(2) = 32 bytes
  final mdhdSize = 32;
  bytes.add((mdhdSize >> 24) & 0xFF);
  bytes.add((mdhdSize >> 16) & 0xFF);
  bytes.add((mdhdSize >> 8) & 0xFF);
  bytes.add(mdhdSize & 0xFF);
  bytes.addAll([0x6D, 0x64, 0x68, 0x64]); // 'mdhd'
  bytes.add(0); // version
  bytes.addAll([0, 0, 0]); // flags
  bytes.addAll([0, 0, 0, 0]); // creation
  bytes.addAll([0, 0, 0, 0]); // modification
  bytes.add((mdhdTimescale >> 24) & 0xFF);
  bytes.add((mdhdTimescale >> 16) & 0xFF);
  bytes.add((mdhdTimescale >> 8) & 0xFF);
  bytes.add(mdhdTimescale & 0xFF); // timescale
  bytes.addAll([0, 0, 0, 0]); // duration
  bytes.addAll([0, 0, 0, 0]); // language + pre_defined

  // --- stts atom ---
  // size(4) + 'stts'(4) + ver(1)+flags(3) + entry_count(4) +
  //   sample_count(4) + sample_delta(4) = 24 bytes
  final sttsSize = 24;
  bytes.add((sttsSize >> 24) & 0xFF);
  bytes.add((sttsSize >> 16) & 0xFF);
  bytes.add((sttsSize >> 8) & 0xFF);
  bytes.add(sttsSize & 0xFF);
  bytes.addAll([0x73, 0x74, 0x74, 0x73]); // 'stts'
  bytes.add(0);
  bytes.addAll([0, 0, 0]);
  bytes.addAll([0, 0, 0, 1]); // entry_count = 1
  bytes.addAll([0, 0, 0, 0xFF]); // sample_count = 255
  bytes.add((sttsSampleDelta >> 24) & 0xFF);
  bytes.add((sttsSampleDelta >> 16) & 0xFF);
  bytes.add((sttsSampleDelta >> 8) & 0xFF);
  bytes.add(sttsSampleDelta & 0xFF);

  // Pad to 256 bytes for the parser's bounds check.
  while (bytes.length < 256) {
    bytes.add(0);
  }
  return Uint8List.fromList(bytes);
}

void main() {
  setUp(() {
    MediaSnifferEngine.clearGlobalCache();
  });

  test('sniffed HLS media is enriched with size, type, and duration', () async {
    final client = MockClient((request) async {
      if (request.method == 'HEAD') {
        return http.Response(
          '',
          200,
          headers: {
            'content-length': '82',
            'content-type': 'application/vnd.apple.mpegurl',
          },
        );
      }
      return http.Response('''
#EXTM3U
#EXTINF:4.0,
one.ts
#EXTINF:5.5,
two.ts
''', 200);
    });
    final engine = MediaSnifferEngine(client: client);
    addTearDown(engine.dispose);

    final enrichedFuture = engine.onMediaChanged.firstWhere(
      (item) =>
          item.contentType == 'application/vnd.apple.mpegurl' &&
          item.duration != null,
    );

    engine.sniff(
      'https://cdn.example.com/video/playlist.m3u8',
      sourcePageUrl: 'https://example.com/watch',
      headers: const {'Referer': 'https://example.com/watch'},
      contentLength: 52428800, // 50 MB pre-known from XHR
    );

    final enriched = await enrichedFuture;
    expect(
      enriched.contentLengthBytes,
      52428800,
      reason: 'JS/XHR-provided contentLength must be preserved for HLS',
    );
    expect(enriched.contentType, 'application/vnd.apple.mpegurl');
    expect(enriched.duration, const Duration(milliseconds: 9500));
    expect(enriched.sourcePageUrl, 'https://example.com/watch');
    expect(enriched.headers['Referer'], 'https://example.com/watch');
  });

  test('MP4 tkhd is parsed and width/height use 16.16 fixed-point', () async {
    final mp4Bytes = _buildMp4WithTkhdMvhd(
      width: 1920,
      height: 1080,
      mvhdTimescale: 1000,
      mvhdDuration: 0, // no duration in this test
    );
    final client = MockClient((request) async {
      if (request.method == 'HEAD') {
        return http.Response(
          '',
          200,
          headers: {
            'content-length': '${mp4Bytes.length}',
            'content-type': 'video/mp4',
          },
        );
      }
      return http.Response.bytes(
        mp4Bytes,
        206,
        headers: {
          'content-range': 'bytes 0-${mp4Bytes.length - 1}/${mp4Bytes.length}',
          'content-type': 'video/mp4',
        },
      );
    });
    final engine = MediaSnifferEngine(client: client);
    addTearDown(engine.dispose);

    final enrichedFuture = engine.onMediaChanged.firstWhere(
      (item) => item.width != null && item.height != null,
    );

    engine.sniff('https://cdn.example.com/video/movie.mp4');

    final enriched = await enrichedFuture;
    expect(enriched.width, 1920);
    expect(enriched.height, 1080);
  });

  test('MP4 mvhd is parsed and duration is computed from timescale', () async {
    final mp4Bytes = _buildMp4WithTkhdMvhd(
      width: 1280,
      height: 720,
      mvhdTimescale: 1000,
      mvhdDuration:
          125000, // 125 seconds (1000 ticks/sec -> 125000ms? no: 125000/1000 = 125 seconds)
    );
    final client = MockClient((request) async {
      if (request.method == 'HEAD') {
        return http.Response(
          '',
          200,
          headers: {
            'content-length': '${mp4Bytes.length}',
            'content-type': 'video/mp4',
          },
        );
      }
      return http.Response.bytes(
        mp4Bytes,
        206,
        headers: {
          'content-range': 'bytes 0-${mp4Bytes.length - 1}/${mp4Bytes.length}',
          'content-type': 'video/mp4',
        },
      );
    });
    final engine = MediaSnifferEngine(client: client);
    addTearDown(engine.dispose);

    final enrichedFuture = engine.onMediaChanged.firstWhere(
      (item) => item.duration != null,
    );

    engine.sniff('https://cdn.example.com/video/clip.mp4');

    final enriched = await enrichedFuture;
    expect(enriched.duration, const Duration(seconds: 125));
  });

  test('MP4 frame rate is derived from mdhd timescale and stts sample delta',
      () async {
    // 30 fps at 30000 Hz timescale → sample_delta = 1000
    final mp4Bytes = _buildMp4WithStts(
      width: 1920,
      height: 1080,
      mdhdTimescale: 30000,
      sttsSampleDelta: 1000,
    );
    final client = MockClient((request) async {
      if (request.method == 'HEAD') {
        return http.Response(
          '',
          200,
          headers: {
            'content-length': '${mp4Bytes.length}',
            'content-type': 'video/mp4',
          },
        );
      }
      return http.Response.bytes(
        mp4Bytes,
        206,
        headers: {
          'content-range': 'bytes 0-${mp4Bytes.length - 1}/${mp4Bytes.length}',
          'content-type': 'video/mp4',
        },
      );
    });
    final engine = MediaSnifferEngine(client: client);
    addTearDown(engine.dispose);

    final enrichedFuture = engine.onMediaChanged.firstWhere(
      (item) => item.frameRate != null,
    );

    engine.sniff('https://cdn.example.com/video/clip30.mp4');

    final enriched = await enrichedFuture;
    expect(enriched.frameRate, 30.0);
    expect(enriched.width, 1920);
    expect(enriched.height, 1080);
  });

  test('MP4 mvhd version 1 duration is parsed correctly', () async {
    final mp4Bytes = _buildMp4WithTkhdMvhd(
      width: 640,
      height: 360,
      mvhdTimescale: 48000,
      mvhdDuration: 48000 * 30, // 30 seconds at 48kHz
      mvhdVersion: 1,
    );
    final client = MockClient((request) async {
      if (request.method == 'HEAD') {
        return http.Response(
          '',
          200,
          headers: {
            'content-length': '${mp4Bytes.length}',
            'content-type': 'video/mp4',
          },
        );
      }
      return http.Response.bytes(
        mp4Bytes,
        206,
        headers: {
          'content-range': 'bytes 0-${mp4Bytes.length - 1}/${mp4Bytes.length}',
          'content-type': 'video/mp4',
        },
      );
    });
    final engine = MediaSnifferEngine(client: client);
    addTearDown(engine.dispose);

    final enrichedFuture = engine.onMediaChanged.firstWhere(
      (item) => item.duration != null,
    );

    engine.sniff('https://cdn.example.com/video/long.mp4');

    final enriched = await enrichedFuture;
    expect(enriched.duration, const Duration(seconds: 30));
  });

  test(
    'HLS master playlist variant resolution is parsed into width/height',
    () async {
      final client = MockClient((request) async {
        if (request.method == 'HEAD') {
          return http.Response(
            '',
            200,
            headers: {
              'content-length': '200',
              'content-type': 'application/vnd.apple.mpegurl',
            },
          );
        }
        return http.Response('''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1500000,RESOLUTION=854x480
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=4500000,RESOLUTION=1920x1080
high/index.m3u8
''', 200);
      });
      final engine = MediaSnifferEngine(client: client);
      addTearDown(engine.dispose);

      final variantsFuture = engine.onMediaChanged.firstWhere(
        (item) => item.bandwidth == 4500000,
      );

      engine.sniff('https://cdn.example.com/root.m3u8');

      final variant = await variantsFuture;
      expect(variant.width, 1920);
      expect(variant.height, 1080);
      expect(variant.bandwidth, 4500000);
    },
  );

  test(
    'immediate contentLength from sniff() is preserved before enrichment',
    () async {
      final client = MockClient((request) async {
        if (request.method == 'HEAD') {
          return http.Response(
            '',
            200,
            headers: {'content-length': '999999', 'content-type': 'video/mp4'},
          );
        }
        return http.Response.bytes(
          Uint8List.fromList(List.filled(256, 0)),
          206,
          headers: {
            'content-range': 'bytes 0-255/999999',
            'content-type': 'video/mp4',
          },
        );
      });
      final engine = MediaSnifferEngine(client: client);
      addTearDown(engine.dispose);

      engine.sniff('https://cdn.example.com/video.mp4', contentLength: 1234567);

      final item = engine.detectedMedia.first;
      expect(
        item.contentLengthBytes,
        1234567,
        reason:
            'contentLength must be set immediately on sniff(), not waiting for enrichment',
      );
    },
  );

  test('HLS playlist byte size is not stored as the video size', () async {
    final client = MockClient((request) async {
      if (request.method == 'HEAD') {
        return http.Response(
          '',
          200,
          headers: {
            'content-length': '200',
            'content-type': 'application/vnd.apple.mpegurl',
          },
        );
      }
      return http.Response('''
#EXTM3U
#EXTINF:4.0,
one.ts
#EXTINF:5.5,
two.ts
''', 200);
    });
    final engine = MediaSnifferEngine(client: client);
    addTearDown(engine.dispose);

    final enrichedFuture = engine.onMediaChanged.firstWhere(
      (item) => item.duration != null,
    );

    engine.sniff('https://cdn.example.com/playlist.m3u8');

    final enriched = await enrichedFuture;
    expect(
      enriched.contentLengthBytes,
      isNull,
      reason: 'HLS .m3u8 byte size is the playlist, not the video',
    );
    expect(enriched.duration, const Duration(milliseconds: 9500));
  });

  test(
    'HLS contentLength from JS/XHR is preserved (not overwritten by probe)',
    () async {
      final client = MockClient((request) async {
        if (request.method == 'HEAD') {
          return http.Response(
            '',
            200,
            headers: {
              'content-length': '200',
              'content-type': 'application/vnd.apple.mpegurl',
            },
          );
        }
        return http.Response('''
#EXTM3U
#EXTINF:4.0,
one.ts
#EXTINF:5.5,
two.ts
''', 200);
      });
      final engine = MediaSnifferEngine(client: client);
      addTearDown(engine.dispose);

      final enrichedFuture = engine.onMediaChanged.firstWhere(
        (item) => item.duration != null,
      );

      engine.sniff(
        'https://cdn.example.com/playlist.m3u8',
        contentLength: 104857600, // 100 MB pre-known
      );

      final enriched = await enrichedFuture;
      expect(
        enriched.contentLengthBytes,
        104857600,
        reason:
            'JS/XHR-provided contentLength must not be overwritten by tiny playlist size',
      );
    },
  );

  test(
    'Streamed GET fallback resolves content-length when HEAD fails',
    () async {
      final client = MockClient((request) async {
        if (request.method == 'HEAD') {
          return http.Response('', 405); // Method Not Allowed
        }
        return http.Response(
          'body',
          200,
          headers: {'content-length': '123456', 'content-type': 'video/mp4'},
        );
      });
      final engine = MediaSnifferEngine(client: client);
      addTearDown(engine.dispose);

      final enrichedFuture = engine.onMediaChanged.firstWhere(
        (item) => item.contentLengthBytes != null,
      );

      engine.sniff('https://example.com/video.mp4');

      final enriched = await enrichedFuture;
      expect(enriched.contentLengthBytes, 123456);
      expect(enriched.contentType, 'video/mp4');
    },
  );

  test('HLS variant size estimation based on bandwidth and duration', () async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('master.m3u8')) {
        return http.Response('''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720
variant.m3u8
''', 200);
      } else if (request.url.path.endsWith('variant.m3u8')) {
        return http.Response('''
#EXTM3U
#EXTINF:10.0,
one.ts
#EXTINF:20.0,
two.ts
''', 200);
      }
      return http.Response('', 404);
    });
    final engine = MediaSnifferEngine(client: client);
    addTearDown(engine.dispose);

    final enrichedFuture = engine.onMediaChanged.firstWhere(
      (item) =>
          item.url.contains('variant.m3u8') && item.contentLengthBytes != null,
    );

    engine.sniff('https://example.com/master.m3u8');

    final enriched = await enrichedFuture;
    expect(enriched.duration, const Duration(seconds: 30));
    expect(enriched.bandwidth, 800000);
    expect(enriched.contentLengthBytes, 3000000); // (800000 / 8) * 30
  });

  test(
    'Size-based eviction caps media items list and retains larger items',
    () async {
      final client = MockClient((request) async {
        final url = request.url.toString();
        int size = 1 * 1024 * 1024; // 1 MB
        if (url.contains('large.mp4')) {
          size = 10 * 1024 * 1024; // 10 MB
        } else if (url.contains('small.mp4')) {
          size = 100 * 1024; // 100 KB
        }
        return http.Response(
          '',
          200,
          headers: {
            'content-length': size.toString(),
            'content-type': 'video/mp4',
          },
        );
      });

      final engine = MediaSnifferEngine(
        client: client,
        maxDetectedMedia: 3, // Cap to 3 for testing
      );
      addTearDown(engine.dispose);

      engine.sniff('https://example.com/item1.mp4');
      engine.sniff('https://example.com/item2.mp4');
      engine.sniff('https://example.com/item3.mp4');

      await Future.delayed(const Duration(milliseconds: 300));
      expect(engine.detectedMedia.length, 3);

      engine.sniff('https://example.com/large.mp4');
      engine.sniff('https://example.com/small.mp4');

      await Future.delayed(const Duration(milliseconds: 600));

      expect(engine.detectedMedia.length, 3);
      final urls = engine.detectedMedia.map((m) => m.url).toList();

      expect(urls.contains('https://example.com/large.mp4'), isTrue);
      expect(urls.contains('https://example.com/small.mp4'), isFalse);
    },
  );

  test(
    'HLS media playlist size estimation based on segment count and first segment size',
    () async {
      final client = MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('playlist.m3u8')) {
          return http.Response('''
#EXTM3U
#EXTINF:5.0,
one.ts
#EXTINF:5.0,
two.ts
''', 200);
        } else if (path.endsWith('one.ts')) {
          if (request.method == 'HEAD') {
            return http.Response(
              '',
              200,
              headers: {'content-length': '1500000'},
            );
          }
        }
        return http.Response('', 404);
      });

      final engine = MediaSnifferEngine(client: client);
      addTearDown(engine.dispose);

      final enrichedFuture = engine.onMediaChanged.firstWhere(
        (item) => item.contentLengthBytes != null,
      );

      engine.sniff('https://example.com/playlist.m3u8');

      final enriched = await enrichedFuture;
      expect(enriched.duration, const Duration(seconds: 10));
      expect(enriched.contentLengthBytes, 3000000); // 1.5 MB * 2 segments
    },
  );

  test('HLS media playlist size estimation based on EXT-X-BYTERANGE', () async {
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('playlist.m3u8')) {
        return http.Response('''
#EXTM3U
#EXTINF:5.0,
#EXT-X-BYTERANGE:100000@0
segment.ts
#EXTINF:5.0,
#EXT-X-BYTERANGE:250000@100000
segment.ts
''', 200);
      }
      // If any segment is requested, fail the test
      fail(
        'Segment should not be probed when byte ranges are declared in the playlist',
      );
    });

    final engine = MediaSnifferEngine(client: client);
    addTearDown(engine.dispose);

    final enrichedFuture = engine.onMediaChanged.firstWhere(
      (item) => item.contentLengthBytes != null,
    );

    engine.sniff('https://example.com/playlist.m3u8');

    final enriched = await enrichedFuture;
    expect(enriched.duration, const Duration(seconds: 10));
    expect(enriched.contentLengthBytes, 350000); // 100000 + 250000
  });

  test(
    'HLS enrichment uses browser playlist cache when Dart HTTP is blocked',
    () async {
      const url = 'https://protected.example.com/playlist.m3u8';
      final client = MockClient((request) async => http.Response('', 403));
      final engine = MediaSnifferEngine(client: client);
      addTearDown(engine.dispose);
      engine.hlsPlaylistCache = (requestedUrl) {
        if (requestedUrl != url) return null;
        return '''
#EXTM3U
#EXTINF:5.0,
#EXT-X-BYTERANGE:100000@0
segment.ts
#EXTINF:5.0,
#EXT-X-BYTERANGE:250000@100000
segment.ts
''';
      };

      final enrichedFuture = engine.onMediaChanged.firstWhere(
        (item) => item.duration != null,
      );

      engine.sniff(url);

      final enriched = await enrichedFuture;
      expect(enriched.duration, const Duration(seconds: 10));
      expect(enriched.contentLengthBytes, 350000);
    },
  );

  test(
    'HLS segment size estimation uses WebView headers when Dart probes fail',
    () async {
      final client = MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('playlist.m3u8') && request.method == 'GET') {
          return http.Response('''
#EXTM3U
#EXTINF:5.0,
one.ts
#EXTINF:5.0,
two.ts
''', 200);
        }
        return http.Response('', 403);
      });

      final engine = MediaSnifferEngine(client: client);
      addTearDown(engine.dispose);
      engine.fetchViaWebView = (url) async {
        if (url.endsWith('one.ts')) {
          return {
            'statusCode': '200',
            'content-length': '1500000',
            'content-type': 'video/mp2t',
          };
        }
        return null;
      };

      final enrichedFuture = engine.onMediaChanged.firstWhere(
        (item) => item.contentLengthBytes != null,
      );

      engine.sniff('https://example.com/playlist.m3u8');

      final enriched = await enrichedFuture;
      expect(enriched.duration, const Duration(seconds: 10));
      expect(enriched.contentLengthBytes, 3000000);
    },
  );

  test(
    'Eviction preserves original chronological order in detectedMedia',
    () async {
      final client = MockClient((request) async {
        final url = request.url.toString();
        int size = 1 * 1024 * 1024; // default 1 MB
        if (url.contains('item1.mp4')) {
          size = 5 * 1024 * 1024; // 5 MB
        } else if (url.contains('item2.mp4')) {
          size = 6 * 1024 * 1024; // 6 MB
        } else if (url.contains('item3.mp4')) {
          size = 7 * 1024 * 1024; // 7 MB
        } else if (url.contains('large.mp4')) {
          size = 10 * 1024 * 1024; // 10 MB
        } else if (url.contains('small.mp4')) {
          size = 100 * 1024; // 100 KB
        }
        return http.Response(
          '',
          200,
          headers: {
            'content-length': size.toString(),
            'content-type': 'video/mp4',
          },
        );
      });

      final engine = MediaSnifferEngine(
        client: client,
        maxDetectedMedia: 3, // Cap to 3
      );
      addTearDown(engine.dispose);

      // Sniff 3 initial items chronologically
      engine.sniff('https://example.com/item1.mp4');
      engine.sniff('https://example.com/item2.mp4');
      engine.sniff('https://example.com/item3.mp4');

      await Future.delayed(const Duration(milliseconds: 300));
      expect(engine.detectedMedia.length, 3);

      // Sniff large and small items
      engine.sniff('https://example.com/large.mp4');
      engine.sniff('https://example.com/small.mp4');

      await Future.delayed(const Duration(milliseconds: 600));

      expect(engine.detectedMedia.length, 3);

      // The surviving items must be: item2 (6MB), item3 (7MB), large (10MB)
      // Their order in detectedMedia must be chronological: item2, then item3, then large.
      final urls = engine.detectedMedia.map((m) => m.url).toList();
      expect(urls, [
        'https://example.com/item2.mp4',
        'https://example.com/item3.mp4',
        'https://example.com/large.mp4',
      ]);
    },
  );

  test('BrowserTab groupName property can be set and updated', () {
    final client = http.Client();
    final sniffer = MediaSnifferEngine(client: client);
    final tab = BrowserTab(
      id: 'test-tab',
      controller: MockBrowserController(),
      snifferEngine: sniffer,
      addressController: TextEditingController(),
    );
    addTearDown(() {
      tab.dispose();
      sniffer.dispose();
    });

    expect(tab.groupName, isNull);
    tab.groupName = 'Work';
    expect(tab.groupName, 'Work');
    tab.groupName = null;
    expect(tab.groupName, isNull);
  });

  test(
    'HLS variant enrichment uses bandwidth×default-duration fallback when '
    'body fetch is CORS-blocked',
    () async {
      const masterUrl = 'https://example.com/master.m3u8';

      final client = MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('master.m3u8')) {
          return http.Response('''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720
720p.m3u8
''', 200);
        }
        // All other Dart requests (including variant.m3u8) return 403.
        return http.Response('', 403);
      });

      final engine = MediaSnifferEngine(client: client);
      addTearDown(engine.dispose);

      // Do NOT set fetchPlaylistBodyViaWebView — cross-origin CDNs block
      // synthetic XHR body reads.  This test verifies the bandwidth×1800s
      // default-duration fallback instead.

      // Sniff the master playlist
      engine.sniff(masterUrl);

      // Wait for variant enrichment to complete
      await Future.delayed(const Duration(milliseconds: 500));

      // Variant should exist
      final variants = engine.detectedMedia
          .where((m) => m.url.contains('720p.m3u8'))
          .toList();
      expect(variants, isNotEmpty,
          reason: 'Variant item should exist in detectedMedia');
      final variant = variants.first;

      // Duration should be null because body couldn't be fetched
      expect(variant.duration, isNull,
          reason:
              'Duration is null because variant body fetch was CORS-blocked');

      // Bandwidth is 800000 bps, default duration is 1800s (30 min)
      // expectedSize = (800000 / 8) * 1800 = 180000000
      expect(variant.contentLengthBytes, isNotNull,
          reason: 'Variant should have estimated contentLengthBytes');
      expect(variant.contentLengthBytes, 180000000,
          reason: '800000/8 * 1800s = 180000000 bytes');

      // isSizeEstimated should be true because fallback was used
      expect(variant.isSizeEstimated, isTrue,
          reason: 'Size should be marked as estimated');
    },
  );

  test(
    'Tier 4 parses content-range from WebView Range-GET fallback',
    () async {
      const url = 'https://example.com/video.mp4';

      final client = MockClient((request) async => http.Response('', 403));

      final engine = MediaSnifferEngine(client: client);
      addTearDown(engine.dispose);

      // Simulate WebView Range-GET (after HEAD returns 405) returning
      // a content-range header with the total file size.
      engine.fetchViaWebView = (url) async {
        return {
          'statusCode': '206',
          'content-range': 'bytes 0-0/12345678',
          'content-type': 'video/mp4',
        };
      };

      final enrichedFuture = engine.onMediaChanged.firstWhere(
        (item) => item.contentLengthBytes != null,
      );

      engine.sniff(url);

      final enriched = await enrichedFuture;
      expect(enriched.contentLengthBytes, 12345678);
      expect(enriched.contentType, 'video/mp4');
    },
  );

  test(
    'HLS variant with blocked body fetch gets estimated size from '
    'bandwidth×default-duration and isSizeEstimated flag is true',
    () async {
      const masterUrl = 'https://example.com/master.m3u8';

      // Master playlist returns OK, but variant.m3u8 is blocked (403).
      final client = MockClient((request) async {
        if (request.url.path.endsWith('master.m3u8')) {
          return http.Response('''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1920x1080
1080p.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=854x480
480p.m3u8
''', 200);
        }
        return http.Response('', 403);
      });

      final engine = MediaSnifferEngine(client: client);
      addTearDown(engine.dispose);

      // Sniff master → enrichment creates variant items
      engine.sniff(masterUrl);

      // Wait for both variants to enrich
      await Future.delayed(const Duration(milliseconds: 800));

      // Find the 480p variant
      final variants = engine.detectedMedia
          .where((m) => m.url.contains('480p.m3u8'))
          .toList();
      expect(variants, isNotEmpty);
      final variant = variants.first;

      // Body fetch was CORS-blocked, but bandwidth=500000 & default 1800s
      // gives estimated size = (500000 / 8) * 1800 = 112500000
      expect(variant.duration, isNull,
          reason: 'Duration is null when body fetch is blocked');
      expect(variant.contentLengthBytes, 112500000,
          reason:
              '500000/8 bps × 1800s default = 112500000 bytes (~107 MB)');
      expect(variant.isSizeEstimated, isTrue,
          reason: 'isSizeEstimated should be true for bandwidth fallback');
      expect(variant.bandwidth, 500000);

      // 1080p variant should also have estimated size with higher bandwidth
      final hdVariants = engine.detectedMedia
          .where((m) => m.url.contains('1080p.m3u8'))
          .toList();
      expect(hdVariants, isNotEmpty);
      final hdVariant = hdVariants.first;
      // (2000000 / 8) * 1800 = 450000000
      expect(hdVariant.contentLengthBytes, 450000000,
          reason: '2000000/8 × 1800s = 450000000 bytes (~429 MB)');
      expect(hdVariant.isSizeEstimated, isTrue);
    },
  );
}

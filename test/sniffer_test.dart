import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:aurora_downloader/sniffer/media_sniffer_engine.dart';
import 'package:aurora_downloader/sniffer/models/sniffed_media.dart';
import 'package:aurora_downloader/sniffer/browser_controller.dart';

void main() {
  group('MediaSnifferEngine Unit Tests', () {
    late MediaSnifferEngine engine;

    setUp(() {
      // Clear the static global dedup cache so URLs sniffed in earlier test
      // cases do not block re-detection in subsequent ones.
      MediaSnifferEngine.clearGlobalCache();
      engine = MediaSnifferEngine();
    });

    tearDown(() {
      engine.dispose();
    });

    test('Video extension matching', () {
      engine.sniff('https://example.com/movie.mp4');
      engine.sniff('https://example.com/playlist.m3u8?token=123');
      engine.sniff('https://example.com/stream.webm');
      engine.sniff('https://example.com/clip.mkv');
      engine.sniff('https://example.com/video.avi');
      engine.sniff('https://example.com/live.flv');
      engine.sniff('https://example.com/file.mov');
      engine.sniff('https://example.com/chunk.ts');

      final media = engine.detectedMedia;
      expect(media.length, 7);
      for (var item in media) {
        expect(item.type, MediaType.video);
      }
    });

    test('Audio extension matching', () {
      engine.sniff('https://example.com/song.mp3');
      engine.sniff('https://example.com/recording.wav?param=abc');
      engine.sniff('https://example.com/track.aac');
      engine.sniff('https://example.com/music.ogg');
      engine.sniff('https://example.com/voice.m4a');
      engine.sniff('https://example.com/audio.flac');

      final media = engine.detectedMedia;
      expect(media.length, 6);
      for (var item in media) {
        expect(item.type, MediaType.audio);
      }
    });

    test('Document extension matching', () {
      engine.sniff('https://example.com/document.pdf');
      engine.sniff('https://example.com/book.epub?auth=yes');
      engine.sniff('https://example.com/manual.mobi');
      engine.sniff('https://example.com/notes.docx');
      engine.sniff('https://example.com/sheet.xlsx');
      engine.sniff('https://example.com/slides.pptx');
      engine.sniff('https://example.com/readme.txt');

      final media = engine.detectedMedia;
      expect(media.length, 7);
      for (var item in media) {
        expect(item.type, MediaType.document);
      }
    });

    test('Archive extension matching', () {
      engine.sniff('https://example.com/bundle.zip');
      engine.sniff('https://example.com/backup.rar?date=today');
      engine.sniff('https://example.com/archive.7z');
      engine.sniff('https://example.com/source.tar');
      engine.sniff('https://example.com/dist.gz');

      final media = engine.detectedMedia;
      expect(media.length, 5);
      for (var item in media) {
        expect(item.type, MediaType.archive);
      }
    });

    test('Torrent and magnet matching', () {
      engine.sniff(
        'magnet:?xt=urn:btih:3f4e2c1a00000000000000000000000000000000',
      );
      engine.sniff('https://example.com/linux.iso.torrent?mirror=1');

      final media = engine.detectedMedia;
      expect(media.length, 2);
      for (var item in media) {
        expect(item.type, MediaType.torrent);
      }
    });

    test('De-duplication cache logic prevents UI spamming', () {
      engine.sniff('https://example.com/video.mp4');
      engine.sniff('https://example.com/video.mp4');
      engine.sniff('https://example.com/video.mp4');

      final media = engine.detectedMedia;
      expect(media.length, 1);
      expect(media.first.url, 'https://example.com/video.mp4');
    });

    test('Non-media links are ignored', () {
      engine.sniff('https://example.com/index.html');
      engine.sniff('https://example.com/style.css');
      engine.sniff('https://example.com/script.js');
      engine.sniff('https://example.com/api/v1/users');

      final media = engine.detectedMedia;
      expect(media, isEmpty);
    });

    test('Filename extraction', () {
      engine.sniff(
        'https://example.com/path/to/some_cool_movie.mp4?query=value#fragment',
      );
      final media = engine.detectedMedia;
      expect(media.length, 1);
      expect(media.first.name, 'some_cool_movie.mp4');
    });

    test('Filename extraction from Content-Disposition header', () {
      // 1. Standard filename
      engine.sniff(
        'https://example.com/download?id=123.mp4',
        contentDisposition: 'attachment; filename="my_movie_123.mp4"',
      );
      expect(engine.detectedMedia.last.name, 'my_movie_123.mp4');

      // 2. UTF-8 encoded filename*
      engine.sniff(
        'https://example.com/download?id=456.mp4',
        contentDisposition:
            "attachment; filename*=UTF-8''na%C3%AFve%20file.mp4",
      );
      expect(engine.detectedMedia.last.name, 'naïve file.mp4');

      // 3. Fallback when invalid Content-Disposition
      engine.sniff(
        'https://example.com/movie_fallback.mp4',
        contentDisposition: 'attachment; filename=""',
      );
      expect(engine.detectedMedia.last.name, 'movie_fallback.mp4');
    });

    test('Clear cache clears the lists and caches', () {
      engine.sniff('https://example.com/video.mp4');
      expect(engine.detectedMedia.length, 1);

      engine.clearCache();
      expect(engine.detectedMedia, isEmpty);

      // Can sniff the same url again after clear cache
      engine.sniff('https://example.com/video.mp4');
      expect(engine.detectedMedia.length, 1);
    });

    test('Stream emits event on sniffed media', () async {
      final Future<SniffedMedia> futureMedia = engine.onMediaDetected.first;
      engine.sniff('https://example.com/audio.mp3');
      final emitted = await futureMedia;
      expect(emitted.url, 'https://example.com/audio.mp3');
      expect(emitted.type, MediaType.audio);
    });

    test('Content-Type fallback detects extensionless video URLs', () {
      // URL with no recognizable extension but video Content-Type
      engine.sniff(
        'https://cdn.example.com/get_file/abc123',
        contentType: 'video/mp4',
      );
      expect(engine.detectedMedia.length, 1);
      expect(engine.detectedMedia.first.type, MediaType.video);
      expect(engine.detectedMedia.first.name, 'abc123');
      expect(engine.detectedMedia.first.contentType, 'video/mp4');
    });

    test(
      'Cache loader reads old list cache and skips malformed items',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'aurora_sniffer_cache_',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final file = File('${tempDir.path}${Platform.pathSeparator}cache.json');
        await file.writeAsString(
          jsonEncode([
            {'url': 'https://cdn.example.com/broken.mp4', 'type': 'bad-type'},
            'not an item',
            {
              'url': 'https://cdn.example.com/restored.mp4',
              'name': 'restored.mp4',
              'type': 'video',
              'sniffedAt': '2026-06-22T09:30:00.000',
              'contentLengthBytes': '4096',
              'duration': '1200',
              'contentType': 'video/mp4',
              'sourcePageUrl': 'https://example.com/watch',
              'headers': {
                'Cookie': 'session=old',
                'Authorization': 'Bearer old',
                'Referer': 'https://example.com/watch',
                'X-Media-Token': 'still-ok',
              },
            },
          ]),
        );

        final loaded = await engine.loadDetectedMedia(file.path);

        expect(loaded, isTrue);
        expect(engine.detectedMedia.length, 1);
        final media = engine.detectedMedia.single;
        expect(media.url, 'https://cdn.example.com/restored.mp4');
        expect(media.contentLengthBytes, 4096);
        expect(media.duration, const Duration(milliseconds: 1200));
        expect(media.contentType, 'video/mp4');
        expect(media.sniffSource, SniffSource.session);
        expect(media.isCacheRestored, isTrue);
        expect(media.isStale, isTrue);
        expect(media.headers, {
          'Referer': 'https://example.com/watch',
          'X-Media-Token': 'still-ok',
        });

        final copied = media.copyWith(name: 'copied.mp4');
        expect(copied.isCacheRestored, isTrue);
        expect(copied.isStale, isTrue);
      },
    );

    test('Cache save uses schema envelope without sensitive headers', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'aurora_sniffer_cache_',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final file = File('${tempDir.path}${Platform.pathSeparator}cache.json');

      engine.sniff(
        'https://cdn.example.com/video/secure.mp4',
        contentType: 'video/mp4',
        sourcePageUrl: 'https://example.com/watch',
        headers: const {
          'Cookie': 'session=secret',
          'Authorization': 'Bearer secret',
          'Referer': 'https://example.com/watch',
          'X-Media-Token': 'persistable',
        },
      );
      await engine.saveDetectedMedia(file.path);

      final raw = await file.readAsString();
      expect(raw, isNot(contains('session=secret')));
      expect(raw, isNot(contains('Bearer secret')));

      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      expect(decoded['schemaVersion'], 2);
      final items = decoded['items'] as List<dynamic>;
      final item = items.single as Map<String, dynamic>;
      final headers = item['headers'] as Map<String, dynamic>;
      expect(headers, containsPair('Referer', 'https://example.com/watch'));
      expect(headers, containsPair('X-Media-Token', 'persistable'));
      expect(
        headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('cookie')),
      );
      expect(
        headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('authorization')),
      );
    });

    test('Content-Type fallback detects HLS MIME types', () {
      engine.sniff(
        'https://cdn.example.com/stream/12345',
        contentType: 'application/vnd.apple.mpegurl',
      );
      expect(engine.detectedMedia.length, 1);
      expect(engine.detectedMedia.first.type, MediaType.video);
    });

    test('Content-Type fallback detects audio MIME types', () {
      engine.sniff(
        'https://cdn.example.com/play/track-99',
        contentType: 'audio/mpeg; charset=utf-8',
      );
      expect(engine.detectedMedia.length, 1);
      expect(engine.detectedMedia.first.type, MediaType.audio);
    });

    test('Content-Type fallback ignores non-media types', () {
      engine.sniff(
        'https://cdn.example.com/api/data',
        contentType: 'application/json',
      );
      expect(engine.detectedMedia, isEmpty);
    });

    test('Content-Type octet-stream with video path hint detects video', () {
      engine.sniff(
        'https://cdn.example.com/video/stream/12345',
        contentType: 'application/octet-stream',
      );
      expect(engine.detectedMedia.length, 1);
      expect(engine.detectedMedia.first.type, MediaType.video);
    });

    test('Extension matching takes priority over Content-Type', () {
      // Even with audio content-type, .mp4 extension should win as video
      engine.sniff('https://example.com/file.mp4', contentType: 'audio/mpeg');
      expect(engine.detectedMedia.length, 1);
      expect(engine.detectedMedia.first.type, MediaType.video);
    });

    test('blob: URLs are recorded but do not trigger enrichment', () async {
      engine.sniff('blob:https://example.com/abc-def-123');
      // blob: URL has no extension and no content-type, so won't be detected
      expect(engine.detectedMedia, isEmpty);

      // But with content-type it should be detected
      engine.sniff(
        'blob:https://example.com/xyz-456',
        contentType: 'video/mp4',
      );
      expect(engine.detectedMedia.length, 1);
      expect(
        engine.detectedMedia.first.url,
        'blob:https://example.com/xyz-456',
      );
    });

    test('Dedup cache prevents re-detection within 30 seconds', () {
      engine.sniff('https://example.com/video.mp4');
      engine.sniff('https://example.com/video.mp4');
      engine.sniff('https://example.com/video.mp4');
      expect(engine.detectedMedia.length, 1);
    });
  });

  group('BrowserController Adblocker Unit Tests', () {
    late MockBrowserController controller;

    setUp(() {
      controller = MockBrowserController(initialUrl: 'https://example.com');
    });

    test('Ad domain URLs are blocked when adblocker is enabled', () async {
      expect(controller.adBlockerEnabled, isTrue);

      // Try loading ad domain
      await controller.loadRequest(Uri.parse('https://doubleclick.net'));
      expect(await controller.currentUrl(), 'https://example.com'); // unchanged

      await controller.loadRequest(
        Uri.parse('https://googleads.g.doubleclick.net/adpage'),
      );
      expect(await controller.currentUrl(), 'https://example.com'); // unchanged

      await controller.loadRequest(
        Uri.parse('https://adcolony.com/index.html'),
      );
      expect(await controller.currentUrl(), 'https://example.com'); // unchanged

      // Regular URL should work
      await controller.loadRequest(Uri.parse('https://wikipedia.org'));
      expect(await controller.currentUrl(), 'https://wikipedia.org');
    });

    test('Ad domain URLs are NOT blocked when adblocker is disabled', () async {
      controller.adBlockerEnabled = false;
      expect(controller.adBlockerEnabled, isFalse);

      await controller.loadRequest(Uri.parse('https://doubleclick.net'));
      expect(await controller.currentUrl(), 'https://doubleclick.net');
    });

    test('Popup suppression increments counter', () {
      expect(controller.blockedPopupsCount, 0);

      // Simulate popup suppression callback through JS channel or direct call
      controller.incrementBlockedPopups();
      expect(controller.blockedPopupsCount, 1);
    });
  });

  group('MediaSnifferEngine CDN URL Detection', () {
    late MediaSnifferEngine engine;

    setUp(() {
      // Clear the static global dedup cache so URLs sniffed in earlier test
      // cases do not block re-detection in subsequent ones.
      MediaSnifferEngine.clearGlobalCache();
      engine = MediaSnifferEngine();
    });

    tearDown(() {
      engine.dispose();
    });

    test('detects erome.com-style CDN video URLs', () {
      // Real-world URLs that the sniffer previously missed due to the
      // playlist-only response scanner in browser_guard.js.
      engine.sniff(
        'https://v104.erome.com/5896/ue85iELl/OQNaKY31_720p.mp4',
      );
      engine.sniff(
        'https://v104.erome.com/5896/ue85iELl/Cua8TwIF_720p.mp4',
      );

      expect(engine.detectedMedia.length, 2);
      expect(engine.detectedMedia[0].type, MediaType.video);
      expect(engine.detectedMedia[0].name, 'OQNaKY31_720p.mp4');
      expect(engine.detectedMedia[1].name, 'Cua8TwIF_720p.mp4');
    });

    test('detects CDN URLs with query tokens', () {
      engine.sniff(
        'https://cdn.example.com/videos/abc123_720p.mp4?token=secret&expires=1234',
      );
      expect(engine.detectedMedia.length, 1);
      expect(engine.detectedMedia.first.type, MediaType.video);
      expect(
        engine.detectedMedia.first.name,
        'abc123_720p.mp4',
      );
    });

    test('strips tracking params but keeps CDN URLs', () {
      engine.sniff(
        'https://cdn.example.com/video.mp4?utm_source=test&fbclid=xyz',
      );
      expect(engine.detectedMedia.length, 1);
      // The detected URL preserves tracking params (the CDN may need them);
      // tracking params are only stripped from the dedup cache key.
      expect(
        engine.detectedMedia.first.url,
        'https://cdn.example.com/video.mp4?utm_source=test&fbclid=xyz',
      );
    });
  });
}

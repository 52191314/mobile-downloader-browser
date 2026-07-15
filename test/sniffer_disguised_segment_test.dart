// Regression test for the disguised HLS/DASH segment drop in MediaDetector.
// Validates that Cloudwish-style segments (TS served under .woff2/.png with a
// video/MP2T content-type, or with chunk naming like .../.urlset/seg-1-f1-v1-a1.woff2)
// are dropped, while the playlist (.m3u8 / disguised .txt) is kept.
import 'package:flutter_test/flutter_test.dart';
import 'package:aurora_downloader/sniffer/media_sniffer_engine.dart';
import 'package:aurora_downloader/sniffer/models/sniffed_media.dart';
import 'package:aurora_downloader/sniffer/sniffed_media_cache.dart';

void main() {
  group('disguised HLS/DASH segment drop', () {
    late MediaSnifferEngine engine;

    setUp(() {
      SniffedMediaCache.clearGlobal();
      engine = MediaSnifferEngine();
    });

    tearDown(() => engine.dispose());

    bool has(String url) =>
        engine.detectedMedia.any((m) => m.url == url);

    test('Cloudwish disguised segment (.woff2, video/MP2T) is dropped', () {
      const seg =
          'https://in1rhjc5cqhz.bestonlinecourses.cyou/T4YmM2A3N95n/hls3/01/10741/oy7wyw10959j_,l,n,h,.urlset/seg-1-f1-v1-a1.woff2';
      engine.sniff(seg, contentType: 'video/MP2T');
      expect(has(seg), isFalse);
    });

    test('Cloudwish disguised segment dropped even without content-type (naming)', () {
      const seg =
          'https://in1rhjc5cqhz.bestonlinecourses.cyou/T4YmM2A3N95n/hls3/01/10741/oy7wyw10959j_,l,n,h,.urlset/seg-2-f3-v1-a1.woff2';
      engine.sniff(seg); // no content-type
      expect(has(seg), isFalse);
    });

    test('Cloudwish disguised playlist (.txt, application/vnd.apple.mpegurl) is kept', () {
      const master =
          'https://in1rhjc5cqhz.bestonlinecourses.cyou/T4YmM2A3N95n/hls3/01/10741/oy7wyw10959j_,l,n,h,.urlset/master.txt';
      engine.sniff(master, contentType: 'application/vnd.apple.mpegurl');
      expect(has(master), isTrue);
      expect(engine.detectedMedia.firstWhere((m) => m.url == master).type,
          anyOf(MediaType.video, MediaType.playlist));
    });

    test('standard .ts segment is still dropped', () {
      const seg =
          'https://cdn.example.com/hls/segment-47-v1-a1.ts';
      engine.sniff(seg);
      expect(has(seg), isFalse);
    });

    test('standard .m3u8 playlist is kept', () {
      const pl = 'https://mycloudz.cc/stream/x/y/master.m3u8';
      engine.sniff(pl, contentType: 'application/vnd.apple.mpegurl');
      expect(has(pl), isTrue);
    });

    test('plain .mp4 is kept (not a segment)', () {
      const mp4 = 'https://cdn.example.com/video_1080p.mp4';
      engine.sniff(mp4, contentType: 'video/mp4');
      expect(has(mp4), isTrue);
    });

    test('URL-only capture then content-type arrival removes disguised segment', () {
      const seg =
          'https://host.example/.urlset/seg-3-f2-v1-a1.woff2';
      engine.sniff(seg); // URL-only: registered
      expect(has(seg), isFalse); // dropped immediately by naming hint
      // Even if it had been registered, the content-type re-sniff removes it.
      engine.sniff(seg, contentType: 'video/MP2T');
      expect(has(seg), isFalse);
    });
  });
}

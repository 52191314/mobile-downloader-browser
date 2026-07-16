import 'package:flutter_test/flutter_test.dart';
import 'package:aurora_downloader/sniffer/hls_playlist_cache_lookup.dart';

void main() {
  group('lookupHlsPlaylistCache', () {
    const playlist = '#EXTM3U\n#EXTINF:4.0,\nvideo0.jpeg\n';
    const htmlBlock = '<!DOCTYPE html><html>Sorry, you have been blocked</html>';

    test('exact URL hit', () {
      final cache = {
        'https://surrit.com/abc/480p/video.m3u8': playlist,
      };
      expect(
        lookupHlsPlaylistCache(
          cache,
          'https://surrit.com/abc/480p/video.m3u8',
        ),
        playlist,
      );
    });

    test('host+path match ignores query string differences', () {
      final cache = {
        'https://surrit.com/abc/480p/video.m3u8?token=old': playlist,
      };
      expect(
        lookupHlsPlaylistCache(
          cache,
          'https://surrit.com/abc/480p/video.m3u8?token=new',
        ),
        playlist,
      );
    });

    test('rejects non-playlist bodies (CF HTML)', () {
      final cache = {
        'https://surrit.com/abc/480p/video.m3u8': htmlBlock,
      };
      expect(
        lookupHlsPlaylistCache(
          cache,
          'https://surrit.com/abc/480p/video.m3u8',
        ),
        isNull,
      );
    });

    test('does not cross quality paths', () {
      final cache = {
        'https://surrit.com/abc/1080p/video.m3u8': playlist,
      };
      expect(
        lookupHlsPlaylistCache(
          cache,
          'https://surrit.com/abc/480p/video.m3u8',
        ),
        isNull,
      );
    });
  });
}

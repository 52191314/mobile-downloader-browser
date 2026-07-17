import 'package:flutter_test/flutter_test.dart';

import 'package:aurora_downloader/sniffer/capture/media_accent.dart';
import 'package:aurora_downloader/sniffer/models/sniffed_media.dart';
import 'package:aurora_downloader/theme/aurora_tokens.dart';

void main() {
  final ac = AColors.dark();

  SniffedMedia media({
    required String url,
    required MediaType type,
    String? contentType,
  }) {
    return SniffedMedia(
      url: url,
      name: url.split('/').last,
      type: type,
      contentType: contentType,
    );
  }

  group('isHlsMedia', () {
    test('detects .m3u8 URL', () {
      expect(
        isHlsMedia(
          media(url: 'https://cdn.example.com/a.m3u8', type: MediaType.video),
        ),
        isTrue,
      );
    });

    test('detects m3u8 / apple mpegurl content-type', () {
      expect(
        isHlsMedia(
          media(
            url: 'https://cdn.example.com/stream',
            type: MediaType.video,
            contentType: 'application/x-mpegURL; profile=m3u8',
          ),
        ),
        isTrue,
      );
      expect(
        isHlsMedia(
          media(
            url: 'https://cdn.example.com/stream',
            type: MediaType.video,
            contentType: 'application/vnd.apple/mpegurl',
          ),
        ),
        isTrue,
      );
    });

    test('false for progressive video', () {
      expect(
        isHlsMedia(
          media(url: 'https://cdn.example.com/v.mp4', type: MediaType.video),
        ),
        isFalse,
      );
    });
  });

  group('mediaAccentFor', () {
    test('HLS wins over MediaType.video', () {
      final item = media(
        url: 'https://cdn.example.com/master.m3u8',
        type: MediaType.video,
      );
      expect(
        mediaAccentFor(ac, item, isHls: true),
        ac.mediaHls,
      );
    });

    test('torrent maps to mediaTorrent (not amber / not mediaOther)', () {
      final item = media(
        url: 'magnet:?xt=urn:btih:abc',
        type: MediaType.torrent,
      );
      final accent = mediaAccentFor(ac, item, isHls: false);
      expect(accent, ac.mediaTorrent);
      // Distinct from Best/action accents and the generic other token.
      expect(accent, isNot(ac.accentAmber));
      expect(accent, isNot(ac.mediaOther));
      expect(accent, isNot(ac.accentFrost));
    });

    test('video/audio/image map to their media tokens', () {
      expect(
        mediaAccentFor(
          ac,
          media(url: 'https://cdn.example.com/v.mp4', type: MediaType.video),
          isHls: false,
        ),
        ac.mediaVideo,
      );
      expect(
        mediaAccentFor(
          ac,
          media(url: 'https://cdn.example.com/a.mp3', type: MediaType.audio),
          isHls: false,
        ),
        ac.mediaAudio,
      );
      expect(
        mediaAccentFor(
          ac,
          media(url: 'https://cdn.example.com/i.jpg', type: MediaType.image),
          isHls: false,
        ),
        ac.mediaImage,
      );
    });

    test('unknown / other types map to mediaOther', () {
      expect(
        mediaAccentFor(
          ac,
          media(
            url: 'https://cdn.example.com/doc.pdf',
            type: MediaType.document,
          ),
          isHls: false,
        ),
        ac.mediaOther,
      );
      expect(
        mediaAccentFor(
          ac,
          media(
            url: 'https://cdn.example.com/a.zip',
            type: MediaType.archive,
          ),
          isHls: false,
        ),
        ac.mediaOther,
      );
    });
  });
}

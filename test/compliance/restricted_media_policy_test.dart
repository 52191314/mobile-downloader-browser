import 'package:aurora_downloader/compliance/restricted_media_policy.dart';
import 'package:aurora_downloader/premium/build_channel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RestrictedMediaPolicy YouTube hosts', () {
    test('detects youtube surface hosts', () {
      expect(
        RestrictedMediaPolicy.isYouTubeUrl('https://www.youtube.com/watch?v=1'),
        isTrue,
      );
      expect(
        RestrictedMediaPolicy.isYouTubeUrl('https://m.youtube.com/watch?v=1'),
        isTrue,
      );
      expect(
        RestrictedMediaPolicy.isYouTubeUrl(
          'https://music.youtube.com/watch?v=1',
        ),
        isTrue,
      );
      expect(
        RestrictedMediaPolicy.isYouTubeUrl('https://youtu.be/abcdef'),
        isTrue,
      );
      expect(
        RestrictedMediaPolicy.isYouTubeUrl(
          'https://www.youtube-nocookie.com/embed/x',
        ),
        isTrue,
      );
    });

    test('detects googlevideo CDN', () {
      expect(
        RestrictedMediaPolicy.isYouTubeUrl(
          'https://rr5---sn-abc.googlevideo.com/videoplayback?id=1',
        ),
        isTrue,
      );
    });

    test('allows unrelated hosts', () {
      expect(
        RestrictedMediaPolicy.isYouTubeUrl('https://example.com/video.mp4'),
        isFalse,
      );
      expect(
        RestrictedMediaPolicy.isYouTubeUrl(
          'https://cdn.example.org/master.m3u8',
        ),
        isFalse,
      );
    });
  });

  group('RestrictedMediaPolicy channel gating', () {
    test('default (github) channel does not enforce YouTube block', () {
      // Unit tests run without AURORA_BUILD_CHANNEL=play.
      expect(BuildChannel.isPlay, isFalse);
      expect(RestrictedMediaPolicy.enforcementEnabled, isFalse);

      final d = RestrictedMediaPolicy.evaluate(
        mediaUrl: 'https://www.youtube.com/watch?v=1',
      );
      expect(d.blocked, isFalse);

      expect(
        RestrictedMediaPolicy.isBlocked(
          mediaUrl: 'https://rr1---sn-x.googlevideo.com/videoplayback',
        ),
        isFalse,
      );
    });

    test('forceEnforce still blocks YouTube for Play-policy unit checks', () {
      final d = RestrictedMediaPolicy.evaluate(
        mediaUrl: 'https://cdn.example.com/v.mp4',
        sourcePageUrl: 'https://www.youtube.com/watch?v=1',
        forceEnforce: true,
      );
      expect(d.blocked, isTrue);
      expect(d.reason, RestrictedMediaReason.youtube);
      expect(d.message, RestrictedMediaPolicy.userMessageYouTube);
    });

    test('matchesYouTubeRestriction ignores channel', () {
      expect(
        RestrictedMediaPolicy.matchesYouTubeRestriction(
          mediaUrl: 'https://cdn.example.com/v.mp4',
          headers: {'Referer': 'https://youtube.com/watch?v=1'},
        ),
        isTrue,
      );
    });
  });

  group('RestrictedMediaPolicy.evaluate (Play enforcement)', () {
    test('blocks media when only source page is YouTube', () {
      final d = RestrictedMediaPolicy.evaluate(
        mediaUrl: 'https://cdn.example.com/v.mp4',
        sourcePageUrl: 'https://www.youtube.com/watch?v=1',
        forceEnforce: true,
      );
      expect(d.blocked, isTrue);
    });

    test('blocks media when only Referer is YouTube', () {
      final d = RestrictedMediaPolicy.evaluate(
        mediaUrl: 'https://cdn.example.com/v.mp4',
        headers: {'Referer': 'https://youtube.com/watch?v=1'},
        forceEnforce: true,
      );
      expect(d.blocked, isTrue);
    });

    test('allows clean direct download even when enforcing', () {
      final d = RestrictedMediaPolicy.evaluate(
        mediaUrl: 'https://files.example.com/doc.pdf',
        sourcePageUrl: 'https://files.example.com/',
        forceEnforce: true,
      );
      expect(d.blocked, isFalse);
    });
  });
}

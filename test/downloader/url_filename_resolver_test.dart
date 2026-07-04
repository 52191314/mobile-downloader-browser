import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:aurora_downloader/downloader/url_filename_resolver.dart';
import 'package:aurora_downloader/platform/public_downloads_service.dart';

void main() {
  group('extensionFromUrlPath', () {
    test('returns ext for simple path', () {
      expect(
        extensionFromUrlPath('https://example.com/video.mp4'),
        '.mp4',
      );
    });

    test('returns ext with query params', () {
      expect(
        extensionFromUrlPath('https://cdn.example.com/file.m3u8?token=abc'),
        '.m3u8',
      );
    });

    test('returns empty for extensionless path', () {
      expect(
        extensionFromUrlPath('https://example.com/download/abc123'),
        '',
      );
    });

    test('returns empty for root path', () {
      expect(extensionFromUrlPath('https://example.com/'), '');
    });

    test('returns empty for domain-only URL', () {
      expect(extensionFromUrlPath('https://example.com'), '');
    });

    test('handles double-dot extension', () {
      expect(
        extensionFromUrlPath('https://example.com/file.tar.gz'),
        '.gz',
      );
    });

    test('returns empty for invalid URL', () {
      expect(extensionFromUrlPath(''), '');
    });

    test('returns ext for path with trailing slash', () {
      expect(
        extensionFromUrlPath('https://example.com/path/video.mp4/'),
        '.mp4',
      );
    });
  });

  group('parseContentDispositionFilename', () {
    test('parses filename*=UTF-8 form', () {
      expect(
        parseContentDispositionFilename(
          "attachment; filename*=UTF-8''movie%20trailer.mp4",
        ),
        'movie trailer.mp4',
      );
    });

    test('parses basic filename= form', () {
      expect(
        parseContentDispositionFilename('attachment; filename="report.pdf"'),
        'report.pdf',
      );
    });

    test('parses filename= without quotes', () {
      expect(
        parseContentDispositionFilename('attachment; filename=video.mp4'),
        'video.mp4',
      );
    });

    test('returns null for header without filename', () {
      expect(
        parseContentDispositionFilename('inline'),
        isNull,
      );
    });

    test('returns null for empty header', () {
      expect(parseContentDispositionFilename(''), isNull);
    });

    test('prefers UTF-8 form over basic form', () {
      expect(
        parseContentDispositionFilename(
          "attachment; filename=\"old.mp4\"; filename*=UTF-8''new.mp4",
        ),
        'new.mp4',
      );
    });
  });

  group('safeFileName', () {
    test('returns last segment for normal URL', () {
      expect(
        safeFileName(Uri.parse('https://example.com/path/file.mp4')),
        'file.mp4',
      );
    });

    test('returns fallback for empty path', () {
      expect(
        safeFileName(Uri.parse('https://example.com')),
        'aurora-download',
      );
    });

    test('returns fallback for root path', () {
      expect(
        safeFileName(Uri.parse('https://example.com/')),
        'aurora-download',
      );
    });

    test('sanitizes invalid filename chars', () {
      expect(
        safeFileName(Uri.parse('https://example.com/a<b>c:d.mp4')),
        'a_b_c_d.mp4',
      );
    });
  });

  group('resolveFilename', () {
    group('fast path (no HTTP probe)', () {
      test('returns URL-derived name when URL has known extension', () async {
        final result = await resolveFilename(
          url: 'https://example.com/video.mp4',
          headers: {},
        );

        expect(result.name, 'video.mp4');
        expect(result.contentType, isNull);
        expect(result.contentLength, isNull);
      });

      test('strips query params from fast-path name', () async {
        final result = await resolveFilename(
          url: 'https://example.com/file.webm?token=abc',
          headers: {},
        );

        expect(result.name, 'file.webm');
      });
    });

    group('slow path (HTTP probe)', () {
      test('uses Content-Disposition filename when provided', () async {
        final client = MockClient((request) async {
          if (request.method == 'HEAD') {
            return http.Response('', 200, headers: {
              'content-disposition':
                  "attachment; filename*=UTF-8''movie_trailer.mp4",
              'content-type': 'video/mp4',
              'content-length': '123456',
            });
          }
          return http.Response('', 404);
        });

        final result = await resolveFilename(
          url: 'https://example.com/stream/abc123',
          headers: {},
          client: client,
        );

        expect(result.name, 'movie_trailer.mp4');
        expect(result.contentType, 'video/mp4');
        expect(result.contentLength, 123456);
      });

      test('uses mime-derived ext when no Content-Disposition', () async {
        final client = MockClient((request) async {
          if (request.method == 'HEAD') {
            return http.Response('', 200, headers: {
              'content-type': 'video/mp4',
              'content-length': '500000',
            });
          }
          return http.Response('', 404);
        });

        final result = await resolveFilename(
          url: 'https://example.com/stream/abc123',
          headers: {},
          client: client,
        );

        expect(result.name, 'abc123.mp4');
        expect(result.contentType, 'video/mp4');
        expect(result.contentLength, 500000);
      });

      test('extracts name from URL segment with mime ext for extensionless URL',
          () async {
        final client = MockClient((request) async {
          if (request.method == 'HEAD') {
            return http.Response('', 200, headers: {
              'content-type': 'audio/mpeg',
            });
          }
          return http.Response('', 404);
        });

        final result = await resolveFilename(
          url: 'https://example.com/podcast/episode_42',
          headers: {},
          client: client,
        );

        expect(result.name, 'episode_42.mp3');
      });

      test('replaces .bin suggestedFilename with real ext', () async {
        final client = MockClient((request) async {
          if (request.method == 'HEAD') {
            return http.Response('', 200, headers: {
              'content-type': 'video/mp4',
            });
          }
          return http.Response('', 404);
        });

        final result = await resolveFilename(
          url: 'https://example.com/download',
          headers: {},
          suggestedFilename: 'download.bin',
          client: client,
        );

        expect(result.name, 'download.mp4');
      });

      test('keeps suggestedFilename with real extension as-is', () async {
        // Even though URL has no ext, the probe won't override a real ext.
        final client = MockClient((request) async {
          if (request.method == 'HEAD') {
            return http.Response('', 200, headers: {
              'content-type': 'video/mp4',
            });
          }
          return http.Response('', 404);
        });

        final result = await resolveFilename(
          url: 'https://example.com/path',
          headers: {},
          suggestedFilename: 'report.pdf',
          client: client,
        );

        expect(result.name, 'report.pdf');
      });

      test('falls back to Range-GET when HEAD fails', () async {
        bool rangeAttempted = false;
        final client = MockClient((request) async {
          if (request.method == 'HEAD') {
            return http.Response('', 500);
          }
          if (request.method == 'GET' &&
              request.headers['range'] == 'bytes=0-0') {
            rangeAttempted = true;
            return http.Response('', 206, headers: {
              'content-type': 'video/webm',
              'content-range': 'bytes 0-0/999999',
            });
          }
          return http.Response('', 404);
        });

        final result = await resolveFilename(
          url: 'https://example.com/stream/some_video',
          headers: {},
          client: client,
        );

        expect(rangeAttempted, isTrue);
        expect(result.name, 'some_video.webm');
        expect(result.contentType, 'video/webm');
        expect(result.contentLength, 999999);
      });

      test('falls back to safeFileName when all probes fail', () async {
        final client = MockClient((request) async {
          return http.Response('', 500);
        });

        final result = await resolveFilename(
          url: 'https://example.com/stream/abc123',
          headers: {},
          client: client,
        );

        // Should use URL segment without extension since no mime was found.
        expect(result.name, 'abc123');
        expect(result.contentType, isNull);
        expect(result.contentLength, isNull);
      });

      test('uses URL path ext when probe provides no better info', () async {
        final client = MockClient((request) async {
          return http.Response('', 500);
        });

        final result = await resolveFilename(
          url: 'https://example.com/video.mp4',
          headers: {},
          suggestedFilename: 'generic.bin',
          client: client,
        );

        // suggestedFilename is provided, not null, so the resolver uses it
        // (strips .bin, reapplies URL path's .mp4 ext).
        expect(result.name, 'generic.mp4');
        // No probe attempted because suggestedFilename is non-null and URL
        // has an extension — the reason it's not `video.mp4` is that the
        // resolver still prefers the suggestedFilename base over the URL
        // segment when a suggested name is provided.
        expect(result.contentType, isNull);
      });

      test('uses generic fallback for root URL', () async {
        final client = MockClient((request) async {
          return http.Response('', 500);
        });

        final result = await resolveFilename(
          url: 'https://example.com',
          headers: {},
          client: client,
        );

        expect(result.name, 'aurora-download');
      });

      test('root URL with content-type gets mime-derived ext', () async {
        final client = MockClient((request) async {
          if (request.method == 'HEAD') {
            return http.Response('', 200, headers: {
              'content-type': 'video/mp4',
            });
          }
          return http.Response('', 404);
        });

        final result = await resolveFilename(
          url: 'https://example.com',
          headers: {},
          client: client,
        );

        expect(result.name, 'aurora-download.mp4');
      });
    });

    group('extensionForMime', () {
      test('returns .mp4 for video/mp4', () {
        expect(PublicDownloadsService.extensionForMime('video/mp4'), '.mp4');
      });

      test('returns .mp3 for audio/mpeg', () {
        expect(PublicDownloadsService.extensionForMime('audio/mpeg'), '.mp3');
      });

      test('round-trips with mimeTypeForName', () {
        for (final ext in [
          '.mp4', '.m3u8', '.ts', '.webm', '.mkv', '.mov',
          '.mp3', '.m4a', '.aac', '.flac', '.ogg', '.pdf',
          '.zip', '.rar', '.7z', '.torrent', '.txt',
        ]) {
          final mime = PublicDownloadsService.mimeTypeForName('file$ext');
          final back = PublicDownloadsService.extensionForMime(mime);
          expect(back, ext, reason: 'round-trip failed for $ext → $mime → $back');
        }
      });

      test('returns null for unknown mime type', () {
        expect(
          PublicDownloadsService.extensionForMime('application/octet-stream'),
          isNull,
        );
      });

      test('returns .html for text/html', () {
        expect(
          PublicDownloadsService.extensionForMime('text/html'),
          '.html',
        );
      });

      test('returns null with charset suffix (not stripped by extensionForMime)', () {
        // extensionForMime itself does NOT strip ;charset — callers
        // (_extensionForContentType in the resolver) do that before calling.
        expect(
          PublicDownloadsService.extensionForMime(
            'text/html; charset=utf-8',
          ),
          isNull,
        );
      });
    });
  });
}

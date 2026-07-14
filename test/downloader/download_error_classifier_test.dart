import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:aurora_downloader/downloader/models.dart';
import 'package:aurora_downloader/downloader/download_error_classifier.dart';

void main() {
  group('DownloadErrorClassifier', () {
    test('Classifies HTTP status codes correctly', () {
      expect(DownloadErrorClassifier.classify(Exception('error'), httpStatus: 401),
          DownloadFailure.httpUnauthorized);
      expect(DownloadErrorClassifier.classify(Exception('error'), httpStatus: 403),
          DownloadFailure.httpForbidden);
      expect(DownloadErrorClassifier.classify(Exception('error'), httpStatus: 404),
          DownloadFailure.httpNotFound);
      expect(DownloadErrorClassifier.classify(Exception('error'), httpStatus: 429),
          DownloadFailure.httpRateLimited);
      expect(DownloadErrorClassifier.classify(Exception('error'), httpStatus: 500),
          DownloadFailure.httpServerError);
      expect(DownloadErrorClassifier.classify(Exception('error'), httpStatus: 503),
          DownloadFailure.httpServerError);
      expect(DownloadErrorClassifier.classify(Exception('error'), httpStatus: 418),
          DownloadFailure.httpUnexpectedStatus);
    });

    test('Classifies SocketException subclasses and messages', () {
      expect(
        DownloadErrorClassifier.classify(
          const SocketException('Failed host lookup: google.com'),
        ),
        DownloadFailure.dnsLookupFailed,
      );

      expect(
        DownloadErrorClassifier.classify(
          const SocketException('Connection refused', osError: OSError('Connection refused', 111)),
        ),
        DownloadFailure.connectionRefused,
      );

      expect(
        DownloadErrorClassifier.classify(
          const SocketException('Connection reset by peer'),
        ),
        DownloadFailure.connectionReset,
      );

      expect(
        DownloadErrorClassifier.classify(
          const SocketException('No route to host'),
        ),
        DownloadFailure.noInternet,
      );
    });

    test('Classifies TimeoutException', () {
      expect(
        DownloadErrorClassifier.classify(TimeoutException('Connect timed out')),
        DownloadFailure.connectionTimeout,
      );
    });

    test('Classifies FileSystemException for disk full and permissions', () {
      expect(
        DownloadErrorClassifier.classify(
          const FileSystemException('No space left on device'),
        ),
        DownloadFailure.diskFull,
      );

      expect(
        DownloadErrorClassifier.classify(
          const FileSystemException('Permission denied'),
        ),
        DownloadFailure.permissionDenied,
      );

      expect(
        DownloadErrorClassifier.classify(
          const FileSystemException('Generic I/O error'),
        ),
        DownloadFailure.fileSystemError,
      );
    });

    test('Classifies TLS / Handshake errors', () {
      expect(
        DownloadErrorClassifier.classify(
          HandshakeException('Handshake failed'),
        ),
        DownloadFailure.connectionReset,
      );
      expect(
        DownloadErrorClassifier.classify(
          TlsException('TlsException'),
        ),
        DownloadFailure.connectionReset,
      );
    });

    test('Classifies FormatException for URLs vs Torrents', () {
      expect(
        DownloadErrorClassifier.classify(
          const FormatException('Invalid URL format'),
        ),
        DownloadFailure.urlInvalid,
      );

      expect(
        DownloadErrorClassifier.classify(
          const FormatException('Invalid bencode format for torrent'),
        ),
        DownloadFailure.torrentMetadataFailed,
      );
    });

    test('Classifies based on heuristic string matching for generic StateError/Exception', () {
      expect(
        DownloadErrorClassifier.classify(
          StateError('HLS download failed: HttpException: status 403'),
        ),
        DownloadFailure.httpForbidden,
      );

      expect(
        DownloadErrorClassifier.classify(
          Exception('Server returned 0 bytes.'),
        ),
        DownloadFailure.emptyResponse,
      );

      expect(
        DownloadErrorClassifier.classify(
          Exception('Server returned an HTML error page instead of the media file.'),
        ),
        DownloadFailure.contentMismatch,
      );

      expect(
        DownloadErrorClassifier.classify(
          Exception('SHA-256 mismatch: expected abc, got xyz'),
        ),
        DownloadFailure.hashMismatch,
      );

      expect(
        DownloadErrorClassifier.classify(
          StateError('HLS playlist did not contain any media segments.'),
        ),
        DownloadFailure.hlsPlaylistEmpty,
      );

      expect(
        DownloadErrorClassifier.classify(
          StateError('Token refresh failed — the stream URL may have expired.'),
        ),
        DownloadFailure.hlsTokenExpired,
      );

      expect(
        DownloadErrorClassifier.classify(
          Exception('[Speed stall] Speed stayed below 10 KB/s'),
        ),
        DownloadFailure.speedStall,
      );

      expect(
        DownloadErrorClassifier.classify(
          Exception('[PARTIAL:96.5%] Server closed connection'),
        ),
        DownloadFailure.partialDownload,
      );
    });

    test('Generates user-friendly messages for different failures', () {
      final msg1 = DownloadErrorClassifier.userMessage(DownloadFailure.noInternet);
      expect(msg1, contains('No internet connection'));

      final msg2 = DownloadErrorClassifier.userMessage(DownloadFailure.dnsLookupFailed, host: 'example.com');
      expect(msg2, contains('DNS lookup failed for "example.com"'));

      final msg3 = DownloadErrorClassifier.userMessage(DownloadFailure.diskFull);
      expect(msg3, contains('storage space'));

      final msg4 = DownloadErrorClassifier.userMessage(DownloadFailure.httpForbidden);
      expect(msg4, contains('Access denied (403)'));

      final msg5 = DownloadErrorClassifier.userMessage(DownloadFailure.hlsCircuitBreaker);
      expect(msg5, contains('CDN blocked access'));
    });
  });
}

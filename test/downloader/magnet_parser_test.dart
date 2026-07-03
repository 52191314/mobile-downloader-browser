import 'package:flutter_test/flutter_test.dart';
import 'package:aurora_downloader/downloader/downloader.dart';

void main() {
  group('MagnetLink Parser Tests', () {
    test('Parse valid magnet link with hex info-hash', () {
      final magnetUri =
          'magnet:?xt=urn:btih:3f4e2c1a00000000000000000000000000000000&dn=TestTorrent&tr=udp://tracker.openbittorrent.com:80/announce&tr=udp://tracker.opentrackr.org:1337/announce';
      final magnet = MagnetLink.parse(magnetUri);

      expect(magnet.infoHash, '3f4e2c1a00000000000000000000000000000000');
      expect(magnet.displayName, 'TestTorrent');
      expect(magnet.trackers, [
        'udp://tracker.openbittorrent.com:80/announce',
        'udp://tracker.opentrackr.org:1337/announce',
      ]);
      expect(magnet.webSeeds, isEmpty);
    });

    test(
      'Parse valid magnet link with Base32 info-hash and convert to Hex',
      () {
        final magnetUri =
            'magnet:?xt=urn:btih:MRSWE2LBNYWW2YLHNZSXILLMNFXGW4YA&dn=Debian';
        final magnet = MagnetLink.parse(magnetUri);

        expect(magnet.infoHash, '64656269616e2d6d61676e65742d6c696e6b7300');
        expect(magnet.displayName, 'Debian');
      },
    );

    test('Parse magnet link with multiple trackers and web seeds', () {
      final magnetUri =
          'magnet:?xt=urn:btih:64656269616e2d6d61676e65742d6c696e6b7300&ws=http://seed1.example.com&ws=http://seed2.example.com';
      final magnet = MagnetLink.parse(magnetUri);

      expect(magnet.infoHash, '64656269616e2d6d61676e65742d6c696e6b7300');
      expect(magnet.webSeeds, [
        'http://seed1.example.com',
        'http://seed2.example.com',
      ]);
    });

    test('Throws FormatException for invalid schemes', () {
      expect(
        () => MagnetLink.parse(
          'http:?xt=urn:btih:3f4e2c1a00000000000000000000000000000000',
        ),
        throwsFormatException,
      );
    });

    test('Throws FormatException for missing xt parameter', () {
      expect(() => MagnetLink.parse('magnet:?dn=NoXt'), throwsFormatException);
    });

    test('Throws FormatException for invalid xt prefix', () {
      expect(
        () => MagnetLink.parse(
          'magnet:?xt=urn:sha1:3f4e2c1a00000000000000000000000000000000',
        ),
        throwsFormatException,
      );
    });

    test('Throws FormatException for invalid hex length', () {
      expect(
        () => MagnetLink.parse(
          'magnet:?xt=urn:btih:3f4e2c1a0000000000000000000000000000000',
        ),
        throwsFormatException,
      );
      expect(
        () => MagnetLink.parse(
          'magnet:?xt=urn:btih:3f4e2c1a000000000000000000000000000000001',
        ),
        throwsFormatException,
      );
    });

    test('Throws FormatException for invalid hex characters', () {
      expect(
        () => MagnetLink.parse(
          'magnet:?xt=urn:btih:3f4e2c1a0000000000000000000000000000000G',
        ),
        throwsFormatException,
      );
    });

    test('Throws FormatException for invalid Base32 characters', () {
      expect(
        () => MagnetLink.parse(
          'magnet:?xt=urn:btih:MRSQG43FNVXXG2LBNRUXI2LNNZ2W4ZD1',
        ),
        throwsFormatException,
      ); // 1 is invalid in standard Base32
    });
  });
}

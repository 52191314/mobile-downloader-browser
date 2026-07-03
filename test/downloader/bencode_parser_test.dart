import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:aurora_downloader/downloader/downloader.dart';

void main() {
  group('BencodeDecoder Tests', () {
    test('Decode valid integers', () {
      expect(BencodeDecoder.decode(utf8.encode('i123e')), 123);
      expect(BencodeDecoder.decode(utf8.encode('i-456e')), -456);
      expect(BencodeDecoder.decode(utf8.encode('i0e')), 0);
    });

    test('Throw FormatException for invalid integers', () {
      expect(
        () => BencodeDecoder.decode(utf8.encode('i03e')),
        throwsFormatException,
      );
      expect(
        () => BencodeDecoder.decode(utf8.encode('i-0e')),
        throwsFormatException,
      );
      expect(
        () => BencodeDecoder.decode(utf8.encode('i-03e')),
        throwsFormatException,
      );
      expect(
        () => BencodeDecoder.decode(utf8.encode('i123')),
        throwsFormatException,
      );
      expect(
        () => BencodeDecoder.decode(utf8.encode('ie')),
        throwsFormatException,
      );
    });

    test('Decode valid byte strings', () {
      final decoded = BencodeDecoder.decode(utf8.encode('4:spam'));
      expect(decoded, isA<Uint8List>());
      expect(utf8.decode(decoded as Uint8List), 'spam');

      final empty = BencodeDecoder.decode(utf8.encode('0:'));
      expect(empty, isA<Uint8List>());
      expect((empty as Uint8List), isEmpty);
    });

    test('Throw FormatException for invalid byte strings', () {
      expect(
        () => BencodeDecoder.decode(utf8.encode('4spam')),
        throwsFormatException,
      );
      expect(
        () => BencodeDecoder.decode(utf8.encode('5:spam')),
        throwsFormatException,
      );
    });

    test('Decode valid lists', () {
      final decoded =
          BencodeDecoder.decode(utf8.encode('l4:spami42ee')) as List;
      expect(decoded.length, 2);
      expect(utf8.decode(decoded[0] as Uint8List), 'spam');
      expect(decoded[1], 42);
    });

    test('Throw FormatException for unterminated list', () {
      expect(
        () => BencodeDecoder.decode(utf8.encode('l4:spam')),
        throwsFormatException,
      );
    });

    test('Decode valid dictionaries', () {
      final decoded =
          BencodeDecoder.decode(utf8.encode('d3:cow3:moo4:spam4:eggse')) as Map;
      expect(decoded.length, 2);
      expect(utf8.decode(decoded['cow'] as Uint8List), 'moo');
      expect(utf8.decode(decoded['spam'] as Uint8List), 'eggs');
    });

    test('Throw FormatException for unterminated dictionary', () {
      expect(
        () => BencodeDecoder.decode(utf8.encode('d3:cow3:moo')),
        throwsFormatException,
      );
    });

    test('Capture raw info bytes of info dictionary', () {
      final decoded =
          BencodeDecoder.decode(utf8.encode('d4:infoi123ee'))
              as Map<String, dynamic>;
      expect(decoded.containsKey('_raw_info_bytes'), isTrue);
      expect(utf8.decode(decoded['_raw_info_bytes'] as Uint8List), 'i123e');
    });
  });

  group('TorrentMetadata Parsing Tests', () {
    test('Parse single file torrent metadata', () {
      // Announce: http://tracker.com/announce
      // Info: { name: single.txt, piece length: 16384, pieces: 20-bytes, length: 50000 }
      final piecesBytes = Uint8List(20)..fillRange(0, 20, 1);
      final piecesString = String.fromCharCodes(piecesBytes);
      final infoDictBencoded =
          'd6:lengthi50000e4:name10:single.txt12:piece lengthi16384e6:pieces20:'
          '$piecesString'
          'e';
      final rootBencoded =
          'd8:announce27:http://tracker.com/announce4:info'
          '$infoDictBencoded'
          'e';

      final metadata = TorrentMetadata.fromBytes(utf8.encode(rootBencoded));

      expect(metadata.name, 'single.txt');
      expect(metadata.pieceLength, 16384);
      expect(metadata.pieces.length, 20);
      expect(metadata.totalSize, 50000);
      expect(metadata.isMultiFile, isFalse);
      expect(metadata.trackers, ['http://tracker.com/announce']);

      final expectedInfoHash = sha1
          .convert(utf8.encode(infoDictBencoded))
          .toString()
          .toLowerCase();
      expect(metadata.infoHash, expectedInfoHash);
      expect(metadata.files.length, 1);
      expect(metadata.files[0].path, 'single.txt');
      expect(metadata.files[0].length, 50000);
    });

    test('Parse multi-file torrent metadata with alternative trackers', () {
      // Announce: http://tracker.com/announce
      // Announce-list: [[http://tr2.com], [http://tr3.com]]
      // Info: { name: project_dir, piece length: 32768, pieces: 40-bytes, files: [ { length: 10000, path: [file1.txt] }, { length: 20000, path: [sub, file2.txt] } ] }
      final piecesBytes = Uint8List(40)..fillRange(0, 40, 2);
      final piecesString = String.fromCharCodes(piecesBytes);
      final infoDictBencoded =
          'd5:filesld6:lengthi10000e4:pathl9:file1.txteed6:lengthi20000e4:pathl3:sub9:file2.txteee4:name11:project_dir12:piece lengthi32768e6:pieces40:'
          '$piecesString'
          'e';
      final rootBencoded =
          'd8:announce27:http://tracker.com/announce13:announce-listll14:http://tr2.comel14:http://tr3.comee4:info'
          '$infoDictBencoded'
          'e';

      final metadata = TorrentMetadata.fromBytes(utf8.encode(rootBencoded));

      expect(metadata.name, 'project_dir');
      expect(metadata.pieceLength, 32768);
      expect(metadata.pieces.length, 40);
      expect(metadata.totalSize, 30000);
      expect(metadata.isMultiFile, isTrue);
      expect(metadata.trackers, [
        'http://tracker.com/announce',
        'http://tr2.com',
        'http://tr3.com',
      ]);

      expect(metadata.files.length, 2);
      expect(metadata.files[0].path, 'file1.txt');
      expect(metadata.files[0].length, 10000);
      expect(metadata.files[1].path, 'sub/file2.txt');
      expect(metadata.files[1].length, 20000);
    });

    test('Throw FormatException for invalid pieces checksum length', () {
      final infoDictBencoded =
          'd6:lengthi50000e4:name10:single.txt12:piece lengthi16384e6:pieces19:1234567890123456789e';
      final rootBencoded =
          'd8:announce27:http://tracker.com/announce4:info'
          '$infoDictBencoded'
          'e';

      expect(
        () => TorrentMetadata.fromBytes(utf8.encode(rootBencoded)),
        throwsFormatException,
      );
    });
  });
}

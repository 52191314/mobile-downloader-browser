import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'bencode_decoder.dart';

class TorrentFileInfo {
  final int length;
  final String path;

  TorrentFileInfo({required this.length, required this.path});
}

class TorrentMetadata {
  final String name;
  final int pieceLength;
  final Uint8List pieces;
  final String infoHash;
  final List<String> trackers;
  final List<TorrentFileInfo> files;
  final int totalSize;
  final bool isMultiFile;

  TorrentMetadata({
    required this.name,
    required this.pieceLength,
    required this.pieces,
    required this.infoHash,
    required this.trackers,
    required this.files,
    required this.totalSize,
    required this.isMultiFile,
  });

  int get pieceCount => pieces.length ~/ 20;

  Uint8List getPieceHash(int pieceIndex) {
    if (pieceIndex < 0 || pieceIndex >= pieceCount) {
      throw RangeError('Piece index out of bounds: $pieceIndex');
    }
    final start = pieceIndex * 20;
    return pieces.sublist(start, start + 20);
  }

  factory TorrentMetadata.fromBytes(Uint8List bytes) {
    final decoded = BencodeDecoder.decode(bytes);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('Torrent root must be a dictionary');
    }
    return TorrentMetadata.fromDict(decoded);
  }

  factory TorrentMetadata.fromDict(Map<String, dynamic> dict) {
    final rawInfoBytes = dict['_raw_info_bytes'];
    if (rawInfoBytes is! Uint8List) {
      throw FormatException('Missing raw info bytes');
    }
    final infoHash = sha1.convert(rawInfoBytes).toString().toLowerCase();

    final info = dict['info'];
    if (info is! Map<String, dynamic>) {
      throw FormatException('Missing or invalid info dictionary');
    }

    final nameBytes = info['name'];
    if (nameBytes is! Uint8List) {
      throw FormatException('Missing or invalid name in info dictionary');
    }
    final name = utf8.decode(nameBytes);

    final pieceLength = info['piece length'];
    if (pieceLength is! int) {
      throw FormatException(
        'Missing or invalid piece length in info dictionary',
      );
    }

    final pieces = info['pieces'];
    if (pieces is! Uint8List) {
      throw FormatException('Missing or invalid pieces in info dictionary');
    }
    if (pieces.length % 20 != 0) {
      throw FormatException('Pieces length must be a multiple of 20');
    }

    final trackers = <String>[];
    if (dict.containsKey('announce')) {
      final ann = dict['announce'];
      if (ann is Uint8List) {
        trackers.add(utf8.decode(ann));
      }
    }
    if (dict.containsKey('announce-list')) {
      final annList = dict['announce-list'];
      if (annList is List) {
        for (final tier in annList) {
          if (tier is List) {
            for (final tr in tier) {
              if (tr is Uint8List) {
                final trStr = utf8.decode(tr);
                if (!trackers.contains(trStr)) {
                  trackers.add(trStr);
                }
              }
            }
          }
        }
      }
    }

    final files = <TorrentFileInfo>[];
    var totalSize = 0;
    final bool isMultiFile;

    if (info.containsKey('files')) {
      isMultiFile = true;
      final filesList = info['files'];
      if (filesList is! List) {
        throw FormatException('Invalid files list in info dictionary');
      }
      for (final f in filesList) {
        if (f is! Map<String, dynamic>) {
          throw FormatException('Invalid file entry in files list');
        }
        final len = f['length'];
        if (len is! int) {
          throw FormatException('Invalid length in file entry');
        }
        final pathList = f['path'];
        if (pathList is! List) {
          throw FormatException('Invalid path in file entry');
        }
        final path = pathList
            .map((p) {
              if (p is! Uint8List) {
                throw FormatException('Invalid path component in file entry');
              }
              return utf8.decode(p);
            })
            .join('/');
        files.add(TorrentFileInfo(length: len, path: path));
        totalSize += len;
      }
    } else {
      isMultiFile = false;
      final len = info['length'];
      if (len is! int) {
        throw FormatException(
          'Missing or invalid length in single-file info dictionary',
        );
      }
      files.add(TorrentFileInfo(length: len, path: name));
      totalSize = len;
    }

    return TorrentMetadata(
      name: name,
      pieceLength: pieceLength,
      pieces: pieces,
      infoHash: infoHash,
      trackers: trackers,
      files: files,
      totalSize: totalSize,
      isMultiFile: isMultiFile,
    );
  }
}

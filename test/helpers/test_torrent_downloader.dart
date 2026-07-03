import 'dart:io';
import 'dart:typed_data';

import 'package:aurora_downloader/downloader/downloader.dart';

class TestTorrentDownloader extends TorrentDownloader {
  final Uint8List simulatedData;
  bool simulateDiskFull = false;

  TestTorrentDownloader({
    required super.task,
    required this.simulatedData,
    super.client,
    super.metadata,
    super.verifyPieceHashes,
    super.useNativeEngine,
    super.corruptPieceIndices,
  });

  @override
  int get syntheticDataLength => simulatedData.length;

  @override
  bool get canValidateSyntheticPieceHash => true;

  @override
  Uint8List readPieceBytes(DownloadChunk chunk) {
    return simulatedData.sublist(chunk.start, chunk.end + 1);
  }

  @override
  Future<void> beforeWritePiece(int pieceIndex, Uint8List bytes) async {
    if (!simulateDiskFull) return;
    throw FileSystemException(
      'Disk full or write failed',
      '',
      OSError('Disk full', 28),
    );
  }

  @override
  Duration get tickInterval => const Duration(milliseconds: 50);
}

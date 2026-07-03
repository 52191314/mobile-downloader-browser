import 'dart:io';
import 'package:crypto/crypto.dart';
import 'models.dart';

/// Result of a partial merge pass over downloaded chunk files.
class PartialMergeResult {
  /// Number of bytes actually written to the destination file.
  final int bytesWritten;

  /// Indices of chunks that had no file on disk.
  final List<int> missingChunkIndices;

  /// Indices of chunks that existed on disk but were smaller than their
  /// expected size. Only set for chunks with a known expected size
  /// (i.e. not open-ended).
  final List<int> partialChunkIndices;

  const PartialMergeResult({
    required this.bytesWritten,
    required this.missingChunkIndices,
    required this.partialChunkIndices,
  });

  /// True when every chunk either was open-ended and was appended in
  /// full, or its on-disk file exactly matched its expected size.
  bool get isComplete =>
      missingChunkIndices.isEmpty && partialChunkIndices.isEmpty;

  /// True when at least one byte was written to the destination.
  bool get hasData => bytesWritten > 0;
}

class FileCombiner {
  /// Combines a list of temporary chunk files in the order they appear
  /// into a single destination file.
  /// Then it calculates and returns the SHA-256 hash of the combined file.
  static Future<String> combineAndHash({
    required List<File> chunks,
    required File destination,
    bool deleteChunks = false,
  }) async {
    await destination.parent.create(recursive: true);

    final IOSink sink = destination.openWrite(mode: FileMode.write);
    try {
      for (final chunk in chunks) {
        if (!await chunk.exists()) {
          throw FileSystemException('Chunk file does not exist', chunk.path);
        }
        await sink.addStream(chunk.openRead());
        if (deleteChunks) {
          await chunk.delete();
        }
      }
    } finally {
      await sink.close();
    }

    final hash = await sha256.bind(destination.openRead()).first;
    return hash.toString();
  }

  /// Combines chunk files in order, **skipping** any chunk that does not
  /// exist or is smaller than its expected size. Returns a
  /// [PartialMergeResult] describing what was written and which chunks
  /// were missing or partial.
  ///
  /// Does NOT compute SHA-256 (partial data cannot be expected-hash-checked).
  /// Does NOT delete the source chunk files when [deleteChunks] is true
  /// for partial / open-ended chunks — the caller decides what to keep.
  static Future<PartialMergeResult> combinePartial({
    required List<DownloadChunk> chunks,
    required String tempDir,
    required File destination,
    bool deleteChunks = false,
  }) async {
    await destination.parent.create(recursive: true);

    final missingChunkIndices = <int>[];
    final partialChunkIndices = <int>[];
    int bytesWritten = 0;

    final IOSink sink = destination.openWrite(mode: FileMode.write);
    try {
      for (final chunk in chunks) {
        final chunkFile = File('$tempDir/part_${chunk.index}');
        if (!await chunkFile.exists()) {
          missingChunkIndices.add(chunk.index);
          continue;
        }

        final onDiskBytes = await chunkFile.length();
        final expectedSize = chunk.size;
        if (!chunk.isOpenEnded && expectedSize > 0 &&
            onDiskBytes < expectedSize) {
          partialChunkIndices.add(chunk.index);
          continue;
        }

        await sink.addStream(chunkFile.openRead());
        bytesWritten += onDiskBytes;
        if (deleteChunks) {
          try {
            await chunkFile.delete();
          } catch (_) {}
        }
      }
    } finally {
      await sink.close();
    }

    return PartialMergeResult(
      bytesWritten: bytesWritten,
      missingChunkIndices: missingChunkIndices,
      partialChunkIndices: partialChunkIndices,
    );
  }
}

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

  /// Indices of chunks whose on-disk file was larger than the expected
  /// size (oversized).  Only the first [expectedSize] bytes were written
  /// to the destination; the excess bytes were discarded.
  final List<int> oversizedChunkIndices;

  const PartialMergeResult({
    required this.bytesWritten,
    required this.missingChunkIndices,
    required this.partialChunkIndices,
    this.oversizedChunkIndices = const [],
  });

  /// True when every chunk either was open-ended and was appended in
  /// full, or its on-disk file exactly matched its expected size.
  bool get isComplete =>
      missingChunkIndices.isEmpty &&
      partialChunkIndices.isEmpty &&
      oversizedChunkIndices.isEmpty;

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
    List<int>? expectedSizes,
  }) async {
    await destination.parent.create(recursive: true);

    final IOSink sink = destination.openWrite(mode: FileMode.write);
    try {
      for (var i = 0; i < chunks.length; i++) {
        final chunk = chunks[i];
        if (!await chunk.exists()) {
          throw FileSystemException('Chunk file does not exist', chunk.path);
        }
        // Verify on-disk size matches the expected chunk size when known
        // (open-ended chunks pass 0/null to skip). A truncated chunk from a
        // killed process would otherwise be silently concatenated, producing
        // a corrupt final file that only fails an optional SHA check.
        if (expectedSizes != null &&
            i < expectedSizes.length &&
            expectedSizes[i] > 0) {
          final onDisk = await chunk.length();
          if (onDisk != expectedSizes[i]) {
            throw FileSystemException(
              'Chunk $i size mismatch: expected ${expectedSizes[i]}, '
              'got $onDisk',
              chunk.path,
            );
          }
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
    void Function(int chunkIndex, int totalChunks)? onProgress,
  }) async {
    await destination.parent.create(recursive: true);

    final missingChunkIndices = <int>[];
    final partialChunkIndices = <int>[];
    final oversizedChunkIndices = <int>[];
    int bytesWritten = 0;
    int current = 0;

    final IOSink sink = destination.openWrite(mode: FileMode.write);
    try {
      for (final chunk in chunks) {
        current++;
        onProgress?.call(current, chunks.length);
        final chunkFile = File('$tempDir/part_${chunk.index}');
        if (!await chunkFile.exists()) {
          missingChunkIndices.add(chunk.index);
          continue;
        }

        final onDiskBytes = await chunkFile.length();
        final expectedSize = chunk.size;
        if (!chunk.isOpenEnded && expectedSize > 0) {
          if (onDiskBytes < expectedSize) {
            partialChunkIndices.add(chunk.index);
            continue;
          }
          if (onDiskBytes > expectedSize) {
            // Oversized chunk: write only the first expectedSize bytes
            // to avoid duplicate/corrupt data in the merged output.
            oversizedChunkIndices.add(chunk.index);
            await sink.addStream(chunkFile.openRead(0, expectedSize));
            bytesWritten += expectedSize;
            if (deleteChunks) {
              try {
                await chunkFile.delete();
              } catch (_) {}
            }
            continue;
          }
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
      oversizedChunkIndices: oversizedChunkIndices,
    );
  }

  /// Scans [tempDir] for HLS segment files (segment_*.ts, segment_*.m4s,
  /// segment_*.mp4), sorts them, and concatenates all found/valid segments.
  static Future<PartialMergeResult> combineHlsPartial({
    required String tempDir,
    required File destination,
    void Function(int current, int total)? onProgress,
  }) async {
    await destination.parent.create(recursive: true);

    final dir = Directory(tempDir);
    if (!await dir.exists()) {
      return const PartialMergeResult(
        bytesWritten: 0,
        missingChunkIndices: [],
        partialChunkIndices: [],
      );
    }

    final List<FileSystemEntity> list = await dir.list().toList();
    final List<File> segmentFiles = [];
    for (final entity in list) {
      if (entity is File) {
        final name = entity.path.split(Platform.pathSeparator).last;
        // Match segment_XXXXXX.ts or segment_XXXXXX.m4s or segment_XXXXXX.mp4
        if (name.startsWith('segment_') &&
            (name.endsWith('.ts') || name.endsWith('.m4s') || name.endsWith('.mp4'))) {
          segmentFiles.add(entity);
        }
      }
    }

    if (segmentFiles.isEmpty) {
      return const PartialMergeResult(
        bytesWritten: 0,
        missingChunkIndices: [],
        partialChunkIndices: [],
      );
    }

    // Sort segment files by their index
    int getIndex(File file) {
      final name = file.path.split(Platform.pathSeparator).last;
      final part = name.replaceAll('segment_', '');
      final dotIdx = part.indexOf('.');
      final numStr = dotIdx != -1 ? part.substring(0, dotIdx) : part;
      return int.tryParse(numStr) ?? 999999;
    }

    segmentFiles.sort((a, b) => getIndex(a).compareTo(getIndex(b)));

    final IOSink sink = destination.openWrite(mode: FileMode.write);
    int bytesWritten = 0;
    int current = 0;

    try {
      for (final file in segmentFiles) {
        current++;
        onProgress?.call(current, segmentFiles.length);
        final length = await file.length();
        if (length == 0) continue;
        await sink.addStream(file.openRead());
        bytesWritten += length;
      }
    } finally {
      await sink.close();
    }

    return PartialMergeResult(
      bytesWritten: bytesWritten,
      missingChunkIndices: const [],
      partialChunkIndices: const [],
    );
  }
}

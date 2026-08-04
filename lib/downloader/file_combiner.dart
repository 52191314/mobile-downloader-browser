import 'dart:io';
import 'dart:isolate';

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
    // Validate on the caller so FileSystemException keeps its concrete type
    // (the error classifier maps it to a disk-I/O failure). The heavy
    // byte-copy + hash then runs on a background isolate so a multi-GB
    // concatenation doesn't stream through the UI isolate's event loop
    // (previously only the SHA-256 was offloaded).
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
    }
    await destination.parent.create(recursive: true);

    final chunkPaths = List<String>.unmodifiable(chunks.map((c) => c.path));
    final destPath = destination.path;
    return Isolate.run(() async {
      try {
        final dest = File(destPath);
        final sink = dest.openWrite(mode: FileMode.write);
        try {
          for (var i = 0; i < chunkPaths.length; i++) {
            await sink.addStream(File(chunkPaths[i]).openRead());
            if (deleteChunks) {
              try {
                await File(chunkPaths[i]).delete();
              } catch (_) {}
            }
          }
        } finally {
          await sink.close();
        }

        final digest = await sha256.bind(dest.openRead()).first;
        return digest.toString();
      } catch (e) {
        // Errors crossing an isolate boundary arrive as RemoteError; rethrow
        // as a plain Exception so the classifier's message heuristic works.
        throw Exception('File merge failed: $e');
      }
    });
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

    // Only send primitives across the isolate boundary (chunk index / size /
    // openness; paths are strings). The heavy per-chunk file I/O then runs on
    // a background isolate so a multi-GB partial merge does not stream through
    // the caller's (UI) event loop — same pattern as [combineAndHash].
    final chunkData = chunks
        .map(
          (c) => <String, Object>{
            'index': c.index,
            'size': c.size,
            'isOpenEnded': c.isOpenEnded,
          },
        )
        .toList(growable: false);

    final receivePort = ReceivePort();
    final isolate = await Isolate.spawn(
      _combinePartialIsolateEntry,
      <String, Object?>{
        'sendPort': receivePort.sendPort,
        'chunks': chunkData,
        'tempDir': tempDir,
        'destination': destination.path,
        'deleteChunks': deleteChunks,
      },
    );
    try {
      // The byte-copy loop runs in the spawned isolate; progress messages are
      // bridged back to [onProgress] with the same per-chunk cadence as the
      // previous inline loop, and the final result is decoded here.
      return await _receivePartialMergeResult(receivePort, onProgress);
    } finally {
      receivePort.close();
      isolate.kill(priority: Isolate.immediate);
    }
  }

  /// Scans [tempDir] for HLS segment files (segment_*.ts, segment_*.m4s,
  /// segment_*.mp4), sorts them, and concatenates all found/valid segments.
  static Future<PartialMergeResult> combineHlsPartial({
    required String tempDir,
    required File destination,
    void Function(int current, int total)? onProgress,
  }) async {
    await destination.parent.create(recursive: true);

    final receivePort = ReceivePort();
    final isolate = await Isolate.spawn(
      _combineHlsPartialIsolateEntry,
      <String, Object?>{
        'sendPort': receivePort.sendPort,
        'tempDir': tempDir,
        'destination': destination.path,
      },
    );
    try {
      // Segment scan + concatenation run on a background isolate (same
      // pattern as [combinePartial]); progress and the result come back over
      // the port with the same cadence as the previous inline loop.
      return await _receivePartialMergeResult(receivePort, onProgress);
    } finally {
      receivePort.close();
      isolate.kill(priority: Isolate.immediate);
    }
  }

  /// Bridges progress / result / error messages from a merge isolate back to
  /// the caller. Progress messages are forwarded to [onProgress]; the final
  /// result message is decoded into a [PartialMergeResult]; error messages
  /// are rethrown as plain `Exception`s (mirroring [combineAndHash]'s
  /// `Isolate.run` error wrapping, so the classifier's message heuristic
  /// keeps working).
  static Future<PartialMergeResult> _receivePartialMergeResult(
    ReceivePort receivePort,
    void Function(int current, int total)? onProgress,
  ) async {
    await for (final raw in receivePort) {
      if (raw is! Map) continue;
      switch (raw['type']) {
        case 'progress':
          final current = raw['current'];
          final total = raw['total'];
          if (current is int && total is int) {
            onProgress?.call(current, total);
          }
          break;
        case 'result':
          final bytesWritten = raw['bytesWritten'];
          final missing = raw['missingChunkIndices'];
          final partial = raw['partialChunkIndices'];
          final oversized = raw['oversizedChunkIndices'];
          if (bytesWritten is int &&
              missing is List &&
              partial is List &&
              oversized is List) {
            return PartialMergeResult(
              bytesWritten: bytesWritten,
              missingChunkIndices: List<int>.from(missing),
              partialChunkIndices: List<int>.from(partial),
              oversizedChunkIndices: List<int>.from(oversized),
            );
          }
          break;
        case 'error':
          final message = raw['message'];
          throw Exception(
            message is String ? message : 'Isolate merge failed',
          );
      }
    }
    throw Exception('Merge isolate exited without sending a result');
  }
}

/// Top-level isolate entry for [FileCombiner.combinePartial]. Must be a
/// top-level function so it can be passed to [Isolate.spawn].
///
/// Replicates the exact semantics of the original inline loop: skip chunks
/// whose part file is missing or smaller than its expected size, truncate
/// oversized chunks to [expectedSize] bytes, honor [deleteChunks], and report
/// progress once per chunk (including skipped ones). Any error is forwarded
/// as an `{'type': 'error', ...}` message so it crosses the isolate boundary
/// as a readable string rather than a RemoteError.
Future<void> _combinePartialIsolateEntry(Map<dynamic, dynamic> args) async {
  final sendPort = args['sendPort'] as SendPort;
  final chunks = (args['chunks'] as List).cast<Map<dynamic, dynamic>>();
  final tempDir = args['tempDir'] as String;
  final destPath = args['destination'] as String;
  final deleteChunks = args['deleteChunks'] as bool;

  final missingChunkIndices = <int>[];
  final partialChunkIndices = <int>[];
  final oversizedChunkIndices = <int>[];
  int bytesWritten = 0;
  int current = 0;

  try {
    final IOSink sink = File(destPath).openWrite(mode: FileMode.write);
    try {
      for (final chunk in chunks) {
        current++;
        sendPort.send({
          'type': 'progress',
          'current': current,
          'total': chunks.length,
        });

        final index = (chunk['index'] as num).toInt();
        final expectedSize = (chunk['size'] as num).toInt();
        final isOpenEnded = chunk['isOpenEnded'] as bool;

        final chunkFile = File('$tempDir/part_$index');
        if (!await chunkFile.exists()) {
          missingChunkIndices.add(index);
          continue;
        }

        final onDiskBytes = await chunkFile.length();
        if (!isOpenEnded && expectedSize > 0) {
          if (onDiskBytes < expectedSize) {
            partialChunkIndices.add(index);
            continue;
          }
          if (onDiskBytes > expectedSize) {
            // Oversized chunk: write only the first expectedSize bytes
            // to avoid duplicate/corrupt data in the merged output.
            oversizedChunkIndices.add(index);
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

    sendPort.send({
      'type': 'result',
      'bytesWritten': bytesWritten,
      'missingChunkIndices': missingChunkIndices,
      'partialChunkIndices': partialChunkIndices,
      'oversizedChunkIndices': oversizedChunkIndices,
    });
  } catch (e) {
    sendPort.send({
      'type': 'error',
      'message': 'Partial merge failed: $e',
    });
  }
}

/// Top-level isolate entry for [FileCombiner.combineHlsPartial]. Scans
/// [tempDir] for segment_*.ts / .m4s / .mp4 files, sorts them by index, and
/// concatenates all found/valid segments on the background isolate.
Future<void> _combineHlsPartialIsolateEntry(Map<dynamic, dynamic> args) async {
  final sendPort = args['sendPort'] as SendPort;
  final tempDir = args['tempDir'] as String;
  final destPath = args['destination'] as String;

  void sendEmptyResult() {
    sendPort.send({
      'type': 'result',
      'bytesWritten': 0,
      'missingChunkIndices': <int>[],
      'partialChunkIndices': <int>[],
      'oversizedChunkIndices': <int>[],
    });
  }

  try {
    final dir = Directory(tempDir);
    if (!await dir.exists()) {
      sendEmptyResult();
      return;
    }

    final List<FileSystemEntity> list = await dir.list().toList();
    final List<File> segmentFiles = [];
    for (final entity in list) {
      if (entity is File) {
        final name = entity.path.split(Platform.pathSeparator).last;
        // Match segment_XXXXXX.ts or segment_XXXXXX.m4s or segment_XXXXXX.mp4
        if (name.startsWith('segment_') &&
            (name.endsWith('.ts') ||
                name.endsWith('.m4s') ||
                name.endsWith('.mp4'))) {
          segmentFiles.add(entity);
        }
      }
    }

    if (segmentFiles.isEmpty) {
      sendEmptyResult();
      return;
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

    final IOSink sink = File(destPath).openWrite(mode: FileMode.write);
    int bytesWritten = 0;
    int current = 0;

    try {
      for (final file in segmentFiles) {
        current++;
        sendPort.send({
          'type': 'progress',
          'current': current,
          'total': segmentFiles.length,
        });
        final length = await file.length();
        if (length == 0) continue;
        await sink.addStream(file.openRead());
        bytesWritten += length;
      }
    } finally {
      await sink.close();
    }

    sendPort.send({
      'type': 'result',
      'bytesWritten': bytesWritten,
      'missingChunkIndices': <int>[],
      'partialChunkIndices': <int>[],
      'oversizedChunkIndices': <int>[],
    });
  } catch (e) {
    sendPort.send({
      'type': 'error',
      'message': 'HLS merge failed: $e',
    });
  }
}

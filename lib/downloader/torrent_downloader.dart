import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:libtorrent_flutter/libtorrent_flutter.dart' as lt hide TorrentStateX;
import 'package:path/path.dart' as p;
import 'models.dart';
import 'magnet_link.dart';
import 'torrent_metadata.dart';
import '../premium/ffmpeg/ffmpeg_module_loader.dart';
import '../premium/build_channel.dart';

void _logError(String context, Object error, [StackTrace? stack]) {
  final message = '[TorrentDownloader] $context: $error';
  debugPrint(message);
}

// The Dart code itself lives in the base module; only the native lib
// (liblibtorrent_flutter.so) is on-demand via the :torrent module.
bool _isLtLoaded = false;

/// Outcome of [TorrentDownloader._ensureLtLoaded].
enum _LtLoadResult {
  /// Native engine is initialized and usable.
  ready,

  /// Engine is not available (module missing/failed, or a real load error).
  unavailable,

  /// The `:torrent` split was installed mid-process but the running process
  /// cannot dlopen its native lib; the app is relaunching so the queued task
  /// auto-resumes with the lib loadable.
  restarting,

  /// The split was installed mid-process but the user declined the
  /// restart prompt (or it failed). The task stays paused with a message
  /// instead of being failed; it resumes after a manual app restart.
  restartDeclined,
}

/// True when the error means the native library itself could not be resolved
/// by the loader (vs. a session/engine-level failure).
bool _isMissingNativeLibrary(Object error) {
  final msg = error.toString();
  return msg.contains('Failed to load dynamic library') ||
      msg.contains('dlopen failed') ||
      msg.contains('cannot find library') ||
      msg.contains('UnsatisfiedLinkError');
}

Future<_LtLoadResult> _ensureLtLoaded(String saveDirectory) async {
  if (lt.LibtorrentFlutter.isInitialized) return _LtLoadResult.ready;
  final loader = FeatureModuleLoader.instance;
  try {
    // Download the :torrent on-demand module from Play Store if needed.
    final installed = await loader.ensureInstalled('torrent');
    if (!installed) {
      debugPrint('[TorrentDownloader] torrent module not available');
      return _LtLoadResult.unavailable;
    }
    // Module is present — now the native engine must ACTUALLY load. Only
    // mark ready after init succeeded; otherwise an auto-retry re-runs this
    // whole path instead of blindly re-trying a failed dlopen.
    await Directory(saveDirectory).create(recursive: true);
    if (!lt.LibtorrentFlutter.isInitialized) {
      await lt.LibtorrentFlutter.init(
        defaultSavePath: saveDirectory,
        pollInterval: const Duration(milliseconds: 600),
      );
    }
    _isLtLoaded = true;
    return _LtLoadResult.ready;
  } catch (e, s) {
    _logError('Failed to load the torrent engine', e, s);
    _isLtLoaded = false;
    // Play Core limitation: a split installed while this process was already
    // running has its native libs invisible to the process's dlopen() path
    // (Dart FFI loads by plain name). The module IS installed and the task
    // is persisted as 'downloading' — relaunch the app so the lib becomes
    // loadable; the queue auto-resumes the task after the restart. Guarded
    // by installedInCurrentProcess so a second failure after the restart
    // (a real ABI/library problem) fails normally instead of looping.
    if (BuildChannel.isPlay &&
        loader.installedInCurrentProcess('torrent') &&
        _isMissingNativeLibrary(e)) {
      debugPrint(
        '[TorrentDownloader] :torrent module installed mid-process; '
        'relaunching so the native library becomes loadable.',
      );
      final restarted = await loader.requestRestart(moduleId: 'torrent');
      if (restarted) return _LtLoadResult.restarting;
      // User declined the restart (or it failed): the module IS installed
      // but its libs are invisible to this process's dlopen path. The task
      // stays 'downloading' and the queue auto-resumes it after a later
      // manual restart — do not fail it outright.
      return _LtLoadResult.restartDeclined;
    }
    return _LtLoadResult.unavailable;
  }
}

class TorrentDownloader implements BaseDownloader {
  final DownloadTask task;
  final http.Client? client;
  TorrentMetadata? metadata;
  bool verifyPieceHashes;
  final bool useNativeEngine;
  final Set<int> corruptPieceIndices;

  Timer? _timer;
  StreamSubscription<dynamic>? _nativeSubscription;
  int? _nativeTorrentId;
  bool _isPaused = false;
  DateTime? _startTime;
  int _startDownloadedBytes = 0;
  bool _inTick = false;

  final StreamController<DownloadTask> _taskUpdateController =
      StreamController<DownloadTask>.broadcast();
  @override
  Stream<DownloadTask> get onTaskUpdated => _taskUpdateController.stream;

  TorrentDownloader({
    required this.task,
    this.client,
    this.metadata,
    this.verifyPieceHashes = true,
    this.useNativeEngine = true,
    Set<int>? corruptPieceIndices,
  }) : corruptPieceIndices = Set<int>.from(corruptPieceIndices ?? <int>{});

  static Future<void> setNativeDownloadLimit(int bytesPerSecond) async {
    if (_isLtLoaded && lt.LibtorrentFlutter.isInitialized) {
      lt.LibtorrentFlutter.instance.setDownloadLimit(bytesPerSecond);
    }
  }

  @override
  Future<void> start() async {
    if (_shouldUseNativeEngine) {
      await _startNative();
      return;
    }

    // Pure-Dart tick path only exists for unit tests that override
    // [syntheticDataLength]. Production must never write zero-filled
    // mock files for magnets/.torrent links.
    if (syntheticDataLength == null) {
      _failNativeRequired();
      return;
    }

    if (task.state == DownloadState.downloading) {
      if (!_isPaused) return;
    }

    _isPaused = false;
    task.state = DownloadState.downloading;
    task.errorMessage = null;
    task.failureReason = null;
    _startTime = DateTime.now();
    _startDownloadedBytes = task.downloadedBytes;
    _taskUpdateController.add(task);

    try {
      final resumeLoaded = await _loadResumeState();

      if (!resumeLoaded || metadata == null) {
        await _initMetadata();
      }

      await _saveResumeState();

      _timer?.cancel();
      _timer = Timer.periodic(tickInterval, (timer) async => _tick());
    } catch (e) {
      task.state = DownloadState.failed;
      task.errorMessage = e.toString();
      task.speed = 0.0;
      _taskUpdateController.add(task);
    }
  }

  void _failNativeRequired() {
    final isMagnet = task.url.startsWith('magnet:');
    task.state = DownloadState.failed;
    task.failureReason = DownloadFailure.nativeEngineUnavailable;
    task.errorMessage = isMagnet
        ? 'Magnet downloads require the native torrent engine, which is '
            'unavailable for this task.'
        : 'Torrent downloads require the native torrent engine, which is '
            'unavailable for this task.';
    task.speed = 0.0;
    _taskUpdateController.add(task);
  }

  @override
  Future<void> pause({DownloadState targetState = DownloadState.paused}) async {
    _isPaused = true;
    _timer?.cancel();
    await _nativeSubscription?.cancel();
    _nativeSubscription = null;
    if (_isLtLoaded && _nativeTorrentId != null && lt.LibtorrentFlutter.isInitialized) {
      lt.LibtorrentFlutter.instance.pauseTorrent(_nativeTorrentId!);
    }
    task.state = targetState;
    task.speed = 0.0;
    _taskUpdateController.add(task);
  }

  @override
  Future<void> dispose() async {
    await pause(targetState: task.state);
    await _nativeSubscription?.cancel();
    _nativeSubscription = null;
    if (!_taskUpdateController.isClosed) {
      await _taskUpdateController.close();
    }
  }

  bool get _shouldUseNativeEngine =>
      useNativeEngine && metadata == null && syntheticDataLength == null;

  @protected
  int? get syntheticDataLength => null;

  @protected
  bool get canValidateSyntheticPieceHash => false;

  @protected
  Uint8List readPieceBytes(DownloadChunk chunk) => Uint8List(chunk.size);

  @protected
  Future<void> beforeWritePiece(int pieceIndex, Uint8List bytes) async {}

  @protected
  Duration get tickInterval => const Duration(milliseconds: 500);

  Future<void> _startNative() async {
    // NOTE: do NOT early-return on `task.state == downloading` here. The queue
    // (_schedule) sets the state to `downloading` BEFORE calling start(), so a
    // state-based guard would skip native init entirely — torrent tasks would
    // hang at 0% and the :torrent on-demand module would never install. Re-entry
    // is already safe: LibtorrentFlutter.isInitialized skips init and
    // _nativeTorrentId != null resumes instead of re-adding.

    _isPaused = false;
    task.state = DownloadState.downloading;
    task.errorMessage = null;
    task.failureReason = null;
    _taskUpdateController.add(task);

    try {
      final saveDirectory = _nativeSaveDirectory();
      final loaded = await _ensureLtLoaded(saveDirectory);
      if (loaded == _LtLoadResult.unavailable) {
        _failNativeRequired();
        return;
      }
      if (loaded == _LtLoadResult.restarting) {
        // The app is relaunching so the freshly-installed :torrent split's
        // native lib becomes loadable. The task stays in 'downloading' state
        // (persisted by the queue) and auto-resumes after the restart.
        return;
      }
      if (loaded == _LtLoadResult.restartDeclined) {
        // The module is installed but the user declined the restart, so the
        // libs are still invisible to this process. Pause with a message
        // instead of failing: the user can resume after a manual restart.
        _isPaused = true;
        task.state = DownloadState.paused;
        task.errorMessage =
            'The torrent engine was installed. Restart Aurora, then '
            'resume this download.';
        task.failureReason = null;
        task.speed = 0.0;
        _taskUpdateController.add(task);
        return;
      }
      await Directory(saveDirectory).create(recursive: true);
      if (!lt.LibtorrentFlutter.isInitialized) {
        await lt.LibtorrentFlutter.init(
          defaultSavePath: saveDirectory,
          pollInterval: const Duration(milliseconds: 600),
        );
      }

      final engine = lt.LibtorrentFlutter.instance;
      _nativeSubscription ??= engine.torrentUpdates.listen(_handleNativeUpdate);

      if (_nativeTorrentId == null) {
        if (task.url.startsWith('magnet:')) {
          _nativeTorrentId = engine.addMagnet(task.url, saveDirectory);
        } else if (_isTorrentFileUrl(task.url)) {
          final torrentPath = await _materializeTorrentFile();
          _nativeTorrentId = engine.addTorrentFile(torrentPath, saveDirectory);
        } else {
          throw FormatException('Unsupported torrent URL: ${task.url}');
        }
      } else {
        engine.resumeTorrent(_nativeTorrentId!);
      }
    } catch (e) {
      task.state = DownloadState.failed;
      // Prefer the dedicated unavailable reason for init/load failures so the
      // UI can show a clear "engine not available" message for magnets.
      final msg = e.toString();
      final unavailable = msg.contains('UnimplementedError') ||
          msg.contains('MissingPluginException') ||
          msg.contains('not available') ||
          msg.contains('Failed to load') ||
          msg.contains('cannot find');
      task.failureReason = unavailable
          ? DownloadFailure.nativeEngineUnavailable
          : DownloadFailure.torrentEngineError;
      task.errorMessage = msg;
      task.speed = 0.0;
      _taskUpdateController.add(task);
    }
  }

  void _handleNativeUpdate(Map<int, dynamic> torrents) {
    final nativeId = _nativeTorrentId;
    if (nativeId == null) return;

    final info = torrents[nativeId];
    if (info == null) return;

    task.totalBytes = info.totalWanted > 0 ? info.totalWanted : task.totalBytes;
    task.downloadedBytes = info.totalDone;
    task.speed = info.downloadRate.toDouble();
    task.errorMessage = info.errorMsg.isEmpty ? null : info.errorMsg;

    if (info.totalWanted > 0) {
      task.chunks = [
        DownloadChunk(
          index: 0,
          start: 0,
          end: info.totalWanted - 1,
          bytesDownloaded: info.totalDone,
          isCompleted: info.isFinished,
        ),
      ];
    }

    final stateStr = info.state.toString();
    task.state = switch (stateStr) {
      'TorrentState.error' => DownloadState.failed,
      'TorrentState.finished' ||
      'TorrentState.seeding' => DownloadState.completed,
      _ when info.isPaused == true => DownloadState.paused,
      _ => DownloadState.downloading,
    };

    _taskUpdateController.add(task);
  }

  String _nativeSaveDirectory() {
    final extension = p.extension(task.savePath);
    if (extension.isEmpty) {
      return task.savePath;
    }
    return p.dirname(task.savePath);
  }

  bool _isTorrentFileUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri?.path.toLowerCase().endsWith('.torrent') ??
        url.toLowerCase().endsWith('.torrent');
  }

  Future<String> _materializeTorrentFile() async {
    final localFile = File(task.url);
    if (await localFile.exists()) {
      return localFile.path;
    }

    final uri = Uri.parse(task.url);
    final ownedClient = client == null ? http.Client() : null;
    final activeClient = client ?? ownedClient!;
    try {
      final response = await activeClient.get(uri);
      if (response.statusCode >= 400) {
        throw HttpException(
          'Unable to fetch torrent file (${response.statusCode})',
          uri: uri,
        );
      }
      final dir = Directory(task.tempDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final target = File('${task.tempDir}/source.torrent');
      await target.writeAsBytes(response.bodyBytes, flush: true);
      return target.path;
    } finally {
      ownedClient?.close();
    }
  }

  Future<void> _initMetadata() async {
    if (metadata != null) {
      _setupChunksFromMetadata();
      return;
    }

    if (task.url.startsWith('magnet:')) {
      final magnet = MagnetLink.parse(task.url);
      final infoHash = magnet.infoHash;

      final possiblePaths = [
        '${task.tempDir}/$infoHash.torrent',
        '${Directory(task.savePath).parent.path}/$infoHash.torrent',
        '$infoHash.torrent',
      ];
      for (final p in possiblePaths) {
        final f = File(p);
        if (await f.exists()) {
          final bytes = await f.readAsBytes();
          metadata = TorrentMetadata.fromBytes(bytes);
          break;
        }
      }
    } else if (task.url.endsWith('.torrent')) {
      try {
        final bytes = await File(task.url).readAsBytes();
        metadata = TorrentMetadata.fromBytes(bytes);
      } catch (e) {
        if (client != null) {
          final response = await client!.get(Uri.parse(task.url));
          metadata = TorrentMetadata.fromBytes(response.bodyBytes);
        }
      }
    }

    if (metadata != null) {
      _setupChunksFromMetadata();
      return;
    }

    final synthetic = syntheticDataLength;
    if (synthetic == null) {
      // Never invent a zero-filled mock torrent for production.
      throw StateError(
        task.url.startsWith('magnet:')
            ? 'Magnet downloads require the native torrent engine.'
            : 'Unable to load torrent metadata. Provide a readable .torrent '
                'file or enable the native torrent engine.',
      );
    }

    // Test-only synthetic progress path (subclass sets syntheticDataLength).
    final totalSize = synthetic;
    task.totalBytes = totalSize;
    const pieceSize = 20480;
    final pieceCount = (totalSize / pieceSize).ceil();
    final chunks = <DownloadChunk>[];
    for (var i = 0; i < pieceCount; i++) {
      final start = i * pieceSize;
      final end = (i == pieceCount - 1) ? totalSize - 1 : start + pieceSize - 1;
      chunks.add(
        DownloadChunk(
          index: i,
          start: start,
          end: end,
          bytesDownloaded: 0,
          isCompleted: false,
        ),
      );
    }
    task.chunks = chunks;
  }

  void _setupChunksFromMetadata() {
    final meta = metadata!;
    final totalSize = meta.totalSize;
    final pieceLength = meta.pieceLength;
    final pieceCount = meta.pieceCount;

    task.totalBytes = totalSize;
    final chunks = <DownloadChunk>[];
    for (var i = 0; i < pieceCount; i++) {
      final start = i * pieceLength;
      final end = (i == pieceCount - 1)
          ? totalSize - 1
          : start + pieceLength - 1;
      chunks.add(
        DownloadChunk(
          index: i,
          start: start,
          end: end,
          bytesDownloaded: 0,
          isCompleted: false,
        ),
      );
    }
    task.chunks = chunks;
  }

  Future<void> _tick() async {
    if (_inTick || _isPaused || task.state != DownloadState.downloading) return;
    _inTick = true;

    try {
      DownloadChunk? activeChunk;
      for (final chunk in task.chunks) {
        if (!chunk.isCompleted) {
          activeChunk = chunk;
          break;
        }
      }

      if (activeChunk == null) {
        _timer?.cancel();
        task.state = DownloadState.completed;
        task.speed = 0.0;
        final file = File('${task.tempDir}/resume.json');
        if (await file.exists()) {
          await file.delete();
        }
        _taskUpdateController.add(task);
        _inTick = false;
        return;
      }

      final chunkSize = activeChunk.size;
      final remaining = chunkSize - activeChunk.bytesDownloaded;
      var bytesToDownload = (chunkSize * 0.2).clamp(1024, 1024000).toInt();
      if (bytesToDownload > remaining) {
        bytesToDownload = remaining;
      }

      final pieceIndex = activeChunk.index;

      activeChunk.bytesDownloaded += bytesToDownload;
      task.downloadedBytes = task.chunks.fold(
        0,
        (sum, c) => sum + c.bytesDownloaded,
      );

      final now = DateTime.now();
      final elapsedMs = now.difference(_startTime!).inMilliseconds;
      if (elapsedMs > 0) {
        task.speed =
            (task.downloadedBytes - _startDownloadedBytes) /
            (elapsedMs / 1000.0);
      }

      if (activeChunk.bytesDownloaded == chunkSize) {
        final pieceBytes = readPieceBytes(activeChunk);

        await _writePiece(pieceIndex, pieceBytes);

        bool isValid = true;
        if (metadata != null && verifyPieceHashes) {
          if (corruptPieceIndices.contains(pieceIndex)) {
            isValid = false;
          } else if (canValidateSyntheticPieceHash) {
            final expectedHash = metadata!.getPieceHash(pieceIndex);
            final computedHash = sha1.convert(pieceBytes).bytes;
            isValid = _listEquals(computedHash, expectedHash);
          }
        }

        if (isValid) {
          activeChunk.isCompleted = true;
          corruptPieceIndices.remove(pieceIndex);
          await _saveResumeState();
        } else {
          corruptPieceIndices.remove(pieceIndex);
          activeChunk.bytesDownloaded = 0;
          task.downloadedBytes = task.chunks.fold(
            0,
            (sum, c) => sum + c.bytesDownloaded,
          );
        }
      }

      _taskUpdateController.add(task);
    } catch (e) {
      _timer?.cancel();
      task.state = DownloadState.failed;
      task.errorMessage = e.toString();
      task.speed = 0.0;
      _taskUpdateController.add(task);
    } finally {
      _inTick = false;
    }
  }

  Future<void> _writePiece(int pieceIndex, Uint8List bytes) async {
    await beforeWritePiece(pieceIndex, bytes);

    if (metadata == null) {
      final offset = task.chunks.length > pieceIndex
          ? task.chunks[pieceIndex].start
          : pieceIndex * bytes.length;
      await _writeBytesAt(task.savePath, offset, bytes);
      return;
    }

    final pieceLength = metadata!.pieceLength;
    final pieceStartOffset = pieceIndex * pieceLength;
    var bytesToOffset = 0;

    for (final fileInfo in metadata!.files) {
      final fileLength = fileInfo.length;
      final fileStart = bytesToOffset;
      final fileEnd = bytesToOffset + fileLength;

      final pieceEnd = pieceStartOffset + bytes.length;
      if (pieceStartOffset < fileEnd && pieceEnd > fileStart) {
        final overlapStart = pieceStartOffset > fileStart
            ? pieceStartOffset
            : fileStart;
        final overlapEnd = pieceEnd < fileEnd ? pieceEnd : fileEnd;

        final pieceBytesStart = overlapStart - pieceStartOffset;
        final pieceBytesEnd = overlapEnd - pieceStartOffset;
        final fileWriteOffset = overlapStart - fileStart;

        final segment = bytes.sublist(pieceBytesStart, pieceBytesEnd);

        final targetPath = metadata!.isMultiFile
            ? '${task.savePath}/${fileInfo.path}'
            : task.savePath;

        await _writeBytesAt(targetPath, fileWriteOffset, segment);
      }
      bytesToOffset += fileLength;
    }
  }

  Future<void> _writeBytesAt(
    String targetPath,
    int offset,
    Uint8List segment,
  ) async {
    if (segment.isEmpty) return;

    final file = File(targetPath);
    final parent = file.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }

    final raf = await file.open(mode: FileMode.write);
    try {
      await raf.setPosition(offset);
      await raf.writeFrom(segment);
    } finally {
      await raf.close();
    }
  }

  Future<void> _saveResumeState() async {
    final dir = Directory(task.tempDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final file = File('${task.tempDir}/resume.json');
    final data = {
      'downloadedBytes': task.downloadedBytes,
      'chunks': task.chunks.map((c) => c.toJson()).toList(),
    };
    await file.writeAsString(jsonEncode(data));
  }

  Future<bool> _loadResumeState() async {
    final file = File('${task.tempDir}/resume.json');
    if (await file.exists()) {
      try {
        final content = await file.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        task.downloadedBytes = json['downloadedBytes'] as int;
        final loadedChunks = (json['chunks'] as List<dynamic>)
            .map((c) => DownloadChunk.fromJson(c as Map<String, dynamic>))
            .toList();
        task.chunks = loadedChunks;
        return true;
      } catch (e, s) {
        _logError('Failed to load resume state', e, s);
      }
    }
    return false;
  }

  bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

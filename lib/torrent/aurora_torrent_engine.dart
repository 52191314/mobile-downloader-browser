// Copyright (c) 2026 Aurora Downloader Authors. All rights reserved.
// Proprietary & Confidential — In-house High Performance Native BitTorrent Engine.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

// ─── Opaque native types ──────────────────────────────────────────────────────
final class _LtSessionOpaque extends Opaque {}

// ─── Native struct: Torrent Status ───────────────────────────────────────────
final class _LtTorrentStatusNative extends Struct {
  @Int64()
  external int id;

  @Array(512)
  external Array<Char> name;

  @Array(1024)
  external Array<Char> savePath;

  @Array(256)
  external Array<Char> errorMsg;

  @Int32()
  external int state;

  @Float()
  external double progress;

  @Int32()
  external int downloadRate;

  @Int32()
  external int uploadRate;

  @Int64()
  external int totalDone;

  @Int64()
  external int totalWanted;

  @Int64()
  external int totalUploaded;

  @Int32()
  external int numPeers;

  @Int32()
  external int numSeeds;

  @Int32()
  external int numPieces;

  @Int32()
  external int piecesDone;

  @Int32()
  external int isPaused;

  @Int32()
  external int isFinished;

  @Int32()
  external int hasMetadata;

  @Int32()
  external int queuePosition;
}

// ─── Native Function Signatures ──────────────────────────────────────────────
typedef _CreateSessionNative = Pointer<_LtSessionOpaque> Function(
    Pointer<Utf8>, Int32, Int32);
typedef _CreateSessionDart = Pointer<_LtSessionOpaque> Function(
    Pointer<Utf8>, int, int);

typedef _DestroySessionNative = Void Function(Pointer<_LtSessionOpaque>);
typedef _DestroySessionDart = void Function(Pointer<_LtSessionOpaque>);

typedef _AddMagnetNative = Int64 Function(
    Pointer<_LtSessionOpaque>, Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _AddMagnetDart = int Function(
    Pointer<_LtSessionOpaque>, Pointer<Utf8>, Pointer<Utf8>, int);

typedef _AddTorrentFileNative = Int64 Function(
    Pointer<_LtSessionOpaque>, Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _AddTorrentFileDart = int Function(
    Pointer<_LtSessionOpaque>, Pointer<Utf8>, Pointer<Utf8>, int);

typedef _PauseTorrentNative = Void Function(
    Pointer<_LtSessionOpaque>, Int64);
typedef _PauseTorrentDart = void Function(
    Pointer<_LtSessionOpaque>, int);

typedef _ResumeTorrentNative = Void Function(
    Pointer<_LtSessionOpaque>, Int64);
typedef _ResumeTorrentDart = void Function(
    Pointer<_LtSessionOpaque>, int);

typedef _RemoveTorrentNative = Void Function(
    Pointer<_LtSessionOpaque>, Int64, Int32);
typedef _RemoveTorrentDart = void Function(
    Pointer<_LtSessionOpaque>, int, int);

typedef _SetDownloadLimitNative = Void Function(
    Pointer<_LtSessionOpaque>, Int32);
typedef _SetDownloadLimitDart = void Function(
    Pointer<_LtSessionOpaque>, int);

typedef _GetAllTorrentStatusesNative = Int32 Function(
    Pointer<_LtSessionOpaque>, Pointer<_LtTorrentStatusNative>, Int32);
typedef _GetAllTorrentStatusesDart = int Function(
    Pointer<_LtSessionOpaque>, Pointer<_LtTorrentStatusNative>, int);

// ─── Dart-facing Models ──────────────────────────────────────────────────────
enum AuroraTorrentState {
  queued,
  checkingFiles,
  downloadingMetadata,
  downloading,
  finished,
  seeding,
  allocating,
  checkingResumeData,
  paused,
  error,
  unknown,
}

class AuroraTorrentInfo {
  final int id;
  final String name;
  final String savePath;
  final String errorMsg;
  final AuroraTorrentState state;
  final double progress;
  final int downloadRate;
  final int uploadRate;
  final int totalDone;
  final int totalWanted;
  final int totalUploaded;
  final int numPeers;
  final int numSeeds;
  final bool isPaused;
  final bool isFinished;
  final bool hasMetadata;

  const AuroraTorrentInfo({
    required this.id,
    required this.name,
    required this.savePath,
    required this.errorMsg,
    required this.state,
    required this.progress,
    required this.downloadRate,
    required this.uploadRate,
    required this.totalDone,
    required this.totalWanted,
    required this.totalUploaded,
    required this.numPeers,
    required this.numSeeds,
    required this.isPaused,
    required this.isFinished,
    required this.hasMetadata,
  });

  @override
  String toString() =>
      'AuroraTorrentInfo(id: $id, progress: ${(progress * 100).toStringAsFixed(1)}%, speed: $downloadRate B/s, done: $totalDone/$totalWanted, state: $state)';
}

// ─── In-House Torrent Engine ─────────────────────────────────────────────────
class AuroraTorrentEngine {
  static AuroraTorrentEngine? _instance;
  static AuroraTorrentEngine get instance =>
      _instance ??= AuroraTorrentEngine._();

  static bool get isInitialized =>
      _instance != null && _instance!._session != null;

  AuroraTorrentEngine._();

  DynamicLibrary? _dylib;
  Pointer<_LtSessionOpaque>? _session;
  Timer? _pollTimer;

  late final _CreateSessionDart _createSession;
  late final _DestroySessionDart _destroySession;
  late final _AddMagnetDart _addMagnet;
  late final _AddTorrentFileDart _addTorrentFile;
  late final _PauseTorrentDart _pauseTorrent;
  late final _ResumeTorrentDart _resumeTorrent;
  late final _RemoveTorrentDart _removeTorrent;
  late final _SetDownloadLimitDart _setDownloadLimit;
  late final _GetAllTorrentStatusesDart _getAllTorrentStatuses;

  final StreamController<Map<int, AuroraTorrentInfo>> _updateController =
      StreamController<Map<int, AuroraTorrentInfo>>.broadcast();

  Stream<Map<int, AuroraTorrentInfo>> get torrentUpdates =>
      _updateController.stream;

  static DynamicLibrary _openLibrary() {
    if (Platform.isAndroid) {
      try {
        return DynamicLibrary.open('liblibtorrent_flutter.so');
      } catch (_) {
        return DynamicLibrary.open('libtorrent.so');
      }
    } else if (Platform.isIOS || Platform.isMacOS) {
      return DynamicLibrary.process();
    } else if (Platform.isWindows) {
      return DynamicLibrary.open('torrent_engine.dll');
    } else if (Platform.isLinux) {
      return DynamicLibrary.open('libtorrent.so');
    }
    return DynamicLibrary.process();
  }

  static Future<void> init({
    required String defaultSavePath,
    Duration pollInterval = const Duration(milliseconds: 600),
    int listenPort = 6881,
    int alertMask = 0x7FFFFFFF,
  }) async {
    final engine = instance;
    if (engine._session != null) return;

    engine._dylib = _openLibrary();
    final lib = engine._dylib!;

    engine._createSession = lib
        .lookup<NativeFunction<_CreateSessionNative>>('lt_create_session')
        .asFunction<_CreateSessionDart>();
    engine._destroySession = lib
        .lookup<NativeFunction<_DestroySessionNative>>('lt_destroy_session')
        .asFunction<_DestroySessionDart>();
    engine._addMagnet = lib
        .lookup<NativeFunction<_AddMagnetNative>>('lt_add_magnet')
        .asFunction<_AddMagnetDart>();
    engine._addTorrentFile = lib
        .lookup<NativeFunction<_AddTorrentFileNative>>('lt_add_torrent_file')
        .asFunction<_AddTorrentFileDart>();
    engine._pauseTorrent = lib
        .lookup<NativeFunction<_PauseTorrentNative>>('lt_pause_torrent')
        .asFunction<_PauseTorrentDart>();
    engine._resumeTorrent = lib
        .lookup<NativeFunction<_ResumeTorrentNative>>('lt_resume_torrent')
        .asFunction<_ResumeTorrentDart>();
    engine._removeTorrent = lib
        .lookup<NativeFunction<_RemoveTorrentNative>>('lt_remove_torrent')
        .asFunction<_RemoveTorrentDart>();
    engine._setDownloadLimit = lib
        .lookup<NativeFunction<_SetDownloadLimitNative>>('lt_set_download_limit')
        .asFunction<_SetDownloadLimitDart>();
    engine._getAllTorrentStatuses = lib
        .lookup<NativeFunction<_GetAllTorrentStatusesNative>>(
            'lt_get_all_torrent_statuses')
        .asFunction<_GetAllTorrentStatusesDart>();

    final nativeSavePath = defaultSavePath.toNativeUtf8();
    try {
      engine._session = engine._createSession(
        nativeSavePath,
        listenPort,
        alertMask,
      );
    } finally {
      calloc.free(nativeSavePath);
    }

    if (engine._session == null || engine._session == nullptr) {
      throw StateError('Failed to initialize native BitTorrent session');
    }

    engine._pollTimer?.cancel();
    engine._pollTimer = Timer.periodic(pollInterval, (_) => engine._poll());
  }

  int addMagnet(String magnetUri, String savePath, [int flags = 0]) {
    _ensureReady();
    final nativeUri = magnetUri.toNativeUtf8();
    final nativePath = savePath.toNativeUtf8();
    try {
      final id = _addMagnet(_session!, nativeUri, nativePath, flags);
      if (id < 0) {
        throw StateError('Failed to enqueue magnet link (code $id)');
      }
      return id;
    } finally {
      calloc.free(nativeUri);
      calloc.free(nativePath);
    }
  }

  int addTorrentFile(String filePath, String savePath, [int flags = 0]) {
    _ensureReady();
    final nativeFile = filePath.toNativeUtf8();
    final nativePath = savePath.toNativeUtf8();
    try {
      final id = _addTorrentFile(_session!, nativeFile, nativePath, flags);
      if (id < 0) {
        throw StateError('Failed to add .torrent file (code $id)');
      }
      return id;
    } finally {
      calloc.free(nativeFile);
      calloc.free(nativePath);
    }
  }

  void pauseTorrent(int id) {
    if (_session == null || _session == nullptr) return;
    _pauseTorrent(_session!, id);
  }

  void resumeTorrent(int id) {
    _ensureReady();
    _resumeTorrent(_session!, id);
  }

  void removeTorrent(int id, {bool deleteFiles = false}) {
    if (_session == null || _session == nullptr) return;
    _removeTorrent(_session!, id, deleteFiles ? 1 : 0);
  }

  void setDownloadLimit(int bytesPerSecond) {
    if (_session == null || _session == nullptr) return;
    _setDownloadLimit(_session!, bytesPerSecond);
  }

  void _poll() {
    if (_session == null || _session == nullptr) return;
    const maxStatuses = 128;
    final buffer = calloc<_LtTorrentStatusNative>(maxStatuses);
    try {
      final count = _getAllTorrentStatuses(_session!, buffer, maxStatuses);
      if (count <= 0) {
        _updateController.add(const <int, AuroraTorrentInfo>{});
        return;
      }

      final result = <int, AuroraTorrentInfo>{};
      for (var i = 0; i < count; i++) {
        final status = buffer[i];
        final id = status.id;
        final name = _charArrayToString(status.name, 512);
        final savePath = _charArrayToString(status.savePath, 1024);
        final errorMsg = _charArrayToString(status.errorMsg, 256);
        final state = _mapState(status.state, status.isPaused != 0, status.isFinished != 0);

        result[id] = AuroraTorrentInfo(
          id: id,
          name: name,
          savePath: savePath,
          errorMsg: errorMsg,
          state: state,
          progress: status.progress,
          downloadRate: status.downloadRate,
          uploadRate: status.uploadRate,
          totalDone: status.totalDone,
          totalWanted: status.totalWanted,
          totalUploaded: status.totalUploaded,
          numPeers: status.numPeers,
          numSeeds: status.numSeeds,
          isPaused: status.isPaused != 0,
          isFinished: status.isFinished != 0,
          hasMetadata: status.hasMetadata != 0,
        );
      }
      _updateController.add(result);
    } catch (e) {
      debugPrint('[AuroraTorrentEngine] poll error: $e');
    } finally {
      calloc.free(buffer);
    }
  }

  void _ensureReady() {
    if (_session == null || _session == nullptr) {
      throw StateError('AuroraTorrentEngine is not initialized. Call init() first.');
    }
  }

  static String _charArrayToString(Array<Char> array, int maxLength) {
    final bytes = <int>[];
    for (var i = 0; i < maxLength; i++) {
      final code = array[i];
      if (code == 0) break;
      bytes.add(code);
    }
    if (bytes.isEmpty) return '';
    try {
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return String.fromCharCodes(bytes);
    }
  }

  static AuroraTorrentState _mapState(int rawState, bool isPaused, bool isFinished) {
    if (isFinished) return AuroraTorrentState.finished;
    if (isPaused) return AuroraTorrentState.paused;
    return switch (rawState) {
      0 => AuroraTorrentState.queued,
      1 => AuroraTorrentState.checkingFiles,
      2 => AuroraTorrentState.downloadingMetadata,
      3 => AuroraTorrentState.downloading,
      4 => AuroraTorrentState.finished,
      5 => AuroraTorrentState.seeding,
      6 => AuroraTorrentState.allocating,
      7 => AuroraTorrentState.checkingResumeData,
      8 => AuroraTorrentState.paused,
      9 => AuroraTorrentState.error,
      _ => AuroraTorrentState.unknown,
    };
  }

  Future<void> dispose() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (_session != null && _session != nullptr) {
      try {
        _destroySession(_session!);
      } catch (_) {}
      _session = null;
    }
    _dylib = null;
    await _updateController.close();
  }
}

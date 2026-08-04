import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import 'hls_decryptor.dart';

/// Persistent worker pool for HLS AES-128 segment decryption.
///
/// Replaces the previous one-shot `Isolate.run` per segment: spawning a fresh
/// isolate (and re-expanding the AES key schedule) for every segment of a
/// multi-hundred-segment playlist. Long-lived workers process segments back
/// to back, so key schedules stay cached inside the worker isolate.
class HlsDecryptPool {
  HlsDecryptPool._();

  /// Global singleton — lives for the process lifetime.
  static final HlsDecryptPool instance = HlsDecryptPool._();

  static const int _minPoolSize = 2;
  static const int _maxPoolSize = 6;

  int _poolSize = 2;

  /// Number of decrypt workers to spawn on [ensureInitialized].
  ///
  /// Must be set before the first [ensureInitialized] call takes effect
  /// (the pool keeps the value across `dispose`/re-init). Clamped to the
  /// sane [_minPoolSize]..[_maxPoolSize] range so a huge segment
  /// concurrency cannot spawn unbounded worker isolates.
  set poolSize(int n) {
    _poolSize = n.clamp(_minPoolSize, _maxPoolSize);
  }

  final List<_DecryptWorkerEntry> _workers = [];
  final Map<int, Completer<void>> _pending = {};
  final Set<Isolate> _crashedIsolates = {};
  int _nextId = 0;
  int _roundRobin = 0;
  bool _initialized = false;

  /// Spawns the worker isolates (idempotent). Call early during HLS setup so
  /// the first encrypted segment does not stall on isolate creation.
  Future<void> ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;
    await Future.wait(List.generate(_poolSize, (_) => _spawnWorker()));
  }

  Future<void> _spawnWorker() async {
    final responsePort = ReceivePort();
    late Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _workerEntryPoint,
        responsePort.sendPort,
      );
    } catch (e) {
      responsePort.close();
      debugPrint('[HlsDecryptPool] Failed to spawn worker: $e');
      return;
    }
    isolate.addErrorListener(responsePort.sendPort);

    final sendPortCompleter = Completer<SendPort>();
    responsePort.listen((dynamic message) {
      if (message is SendPort) {
        sendPortCompleter.complete(message);
        return;
      }
      if (message is List) {
        // Unhandled error from the worker — respawn.
        _onWorkerCrash(isolate, responsePort, message.first);
        return;
      }
      if (message is Map) {
        _onWorkerResponse(message as Map<String, dynamic>);
      }
    });

    final workerSendPort = await sendPortCompleter.future;
    if (_crashedIsolates.contains(isolate)) {
      // The worker died between registering its port and completing spawn —
      // never re-add a dead isolate to the pool (sends to it would be
      // silently dropped, orphaning the pending completer forever).
      isolate.kill(priority: Isolate.immediate);
      return;
    }
    _workers.add(_DecryptWorkerEntry(
      isolate: isolate,
      sendPort: workerSendPort,
    ));
  }

  void _onWorkerResponse(Map<String, dynamic> data) {
    final id = data['id'] as int;
    final completer = _pending.remove(id);
    if (completer == null) return;
    if (data.containsKey('error')) {
      completer.completeError(Exception(data['error']));
    } else {
      completer.complete();
    }
  }

  void _onWorkerCrash(Isolate isolate, ReceivePort port, Object error) {
    _workers.removeWhere((w) => w.isolate == isolate);
    _crashedIsolates.add(isolate);
    // Fail every in-flight request: a crash cannot be reliably attributed to
    // a single worker, and an orphaned completer would hang the segment
    // worker's `await decryptInPlace(...)` forever — the old one-shot
    // Isolate.run completed with an error instead, which callers caught and
    // retried through the fallback paths.
    final pending = Map<int, Completer<void>>.from(_pending);
    _pending.clear();
    for (final entry in pending.entries) {
      if (!entry.value.isCompleted) {
        entry.value.completeError(
          Exception('HLS decrypt worker crashed: $error'),
        );
      }
    }
    port.close();
    _spawnWorker().catchError((_) {});
  }

  /// Decrypts [file] in place on a pooled worker. [key] and [iv] are copied
  /// into the worker isolate (they are 16 bytes each).
  Future<void> decryptInPlace(File file, Uint8List key, Uint8List iv) {
    if (_workers.isEmpty) {
      // Pool failed to spawn (rare) — fall back to a one-shot isolate.
      return HlsDecryptor.decryptInPlace(file, key, iv);
    }
    final id = _nextId++;
    final completer = Completer<void>();
    _pending[id] = completer;
    // Clamp the index: a crash can shrink `_workers` while `_roundRobin`
    // still points past the old length.
    final workerIndex = _roundRobin % _workers.length;
    _workers[workerIndex].sendPort.send({
      'id': id,
      'path': file.path,
      'key': key.toList(),
      'iv': iv.toList(),
    });
    _roundRobin = (_roundRobin + 1) % _workers.length;
    return completer.future;
  }

  /// Best-effort shutdown (the pool normally lives for the process; used by
  /// tests and teardown paths).
  void dispose() {
    for (final worker in _workers) {
      try {
        worker.sendPort.send({'id': -1, 'shutdown': true});
        worker.isolate.kill(priority: Isolate.immediate);
      } catch (_) {}
    }
    _workers.clear();
    for (final entry in _pending.entries) {
      if (!entry.value.isCompleted) {
        entry.value.completeError(StateError('HlsDecryptPool disposed'));
      }
    }
    _pending.clear();
    _crashedIsolates.clear();
    _initialized = false;
  }
}

class _DecryptWorkerEntry {
  final Isolate isolate;
  final SendPort sendPort;

  const _DecryptWorkerEntry({
    required this.isolate,
    required this.sendPort,
  });
}

/// Entry point for each decrypt worker isolate. [mainResponsePort] is the
/// SendPort on the main isolate's response ReceivePort.
void _workerEntryPoint(SendPort mainResponsePort) {
  final requestPort = ReceivePort();
  mainResponsePort.send(requestPort.sendPort);

  requestPort.listen((dynamic message) {
    final data = message as Map<String, dynamic>;
    final id = data['id'] as int;
    if (data['shutdown'] == true) {
      requestPort.close();
      return;
    }
    final path = data['path'] as String;
    final key = Uint8List.fromList((data['key'] as List<dynamic>).cast<int>());
    final iv = Uint8List.fromList((data['iv'] as List<dynamic>).cast<int>());

    // Fire-and-forget: handle asynchronously, reply via mainResponsePort.
    HlsDecryptor.decryptInPlaceSync(File(path), key, iv)
        .then((_) {
      mainResponsePort.send({'id': id, 'result': true});
    }).catchError((Object error) {
      mainResponsePort.send({'id': id, 'error': error.toString()});
    });
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'media_binary_parsers.dart';

// ---------------------------------------------------------------------------
// Persistent worker-isolate pool — replaces one-shot Isolate.run() calls
// with a pool of 3 long-lived workers that handle HTTP probes, JSON
// (de)serialisation, and binary media parsing until the app is disposed.
// ---------------------------------------------------------------------------

/// A pool of persistent worker isolates for HTTP probes, JSON
/// (de)serialization, and binary media parsing. Workers stay alive until
/// [dispose] is called.
class WorkerIsolatePool {
  /// Global singleton.
  static final WorkerIsolatePool instance = WorkerIsolatePool._();

  WorkerIsolatePool._();

  static const int _poolSize = 3;

  final List<_WorkerEntry> _workers = [];
  final Map<int, Completer<dynamic>> _pending = {};
  int _nextId = 0;
  int _roundRobin = 0;
  bool _initialized = false;
  bool _disposed = false;

  /// Ensures the worker pool is initialised (spawns all workers if needed).
  /// Safe to call multiple times — only the first call spawns workers.
  /// Call from [main] to prewarm the pool so the first [execute] does not
  /// stall on isolate creation.
  Future<void> ensureInitialized() => _ensureInitialized();

  /// Sends a request of [type] with [params] to the least-busy worker and
  /// returns its result. Throws [StateError] if the pool is disposed.
  Future<dynamic> execute(String type, Map<String, dynamic> params) {
    if (_disposed) {
      throw StateError('WorkerIsolatePool has been disposed');
    }
    return _executeUnsafe(type, params);
  }

  Future<dynamic> _executeUnsafe(String type, Map<String, dynamic> params) async {
    final initFuture = _ensureInitialized();
    if (_workers.isEmpty) {
      // A concurrent caller raced the spawn batch (workers still
      // registering) — wait for the shared batch instead of throwing
      // "No workers available" and misreporting e.g. an empty queue.
      await initFuture;
    }
    if (_workers.isEmpty) {
      throw StateError('No workers available in the pool');
    }
    final id = _nextId++;
    final completer = Completer<dynamic>.sync();
    _pending[id] = completer;
    _workers[_roundRobin].sendPort.send({
      'id': id,
      'type': type,
      'params': params,
    });
    _roundRobin = (_roundRobin + 1) % _workers.length;
    return completer.future;
  }

  /// Memoized initialization future so concurrent callers (e.g. cold-start
  /// log restore + queue restore) await the SAME spawn batch. The old code
  /// set `_initialized = true` before the spawns finished, so a second caller
  /// could observe an empty `_workers` list and throw.
  Future<void>? _initFuture;

  Future<void> _ensureInitialized() {
    if (_initialized) return Future<void>.value();
    return _initFuture ??= _doEnsureInitialized();
  }

  Future<void> _doEnsureInitialized() async {
    // Spawn all workers concurrently, each gets its own response port.
    // _spawnWorker never throws (spawn failures are logged and skipped), so
    // this always completes.
    await Future.wait(List.generate(_poolSize, (_) => _spawnWorker()));
    _initialized = true;
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
      debugPrint('[WorkerIsolatePool] Failed to spawn worker: $e');
      return;
    }

    // Setup error listener before any message processing.
    isolate.addErrorListener(responsePort.sendPort);

    // Use a Completer to wait for the worker's SendPort registration while
    // having the listener fully established (avoid "Stream already listened to").
    final sendPortCompleter = Completer<SendPort>();
    responsePort.listen((dynamic message) {
      if (message is SendPort) {
        sendPortCompleter.complete(message);
        return;
      }
      if (message is List) {
        // Unhandled error from the isolate — respawn.
        final error = message[0];
        _onWorkerCrash(isolate, responsePort, error);
        return;
      }
      if (message is Map) {
        _onWorkerResponse(message as Map<String, dynamic>);
      }
    });

    final SendPort? workerSendPort;
    try {
      workerSendPort = await sendPortCompleter.future
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Worker never registered its port (rare) — skip it so the pool runs
      // degraded rather than hanging the shared init batch.
      isolate.kill(priority: Isolate.immediate);
      responsePort.close();
      return;
    }
    _workers.add(_WorkerEntry(
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
      completer.complete(data['result']);
    }
  }

  void _onWorkerCrash(Isolate isolate, ReceivePort port, Object error) {
    // Remove from active pool.
    _workers.removeWhere((w) => w.isolate == isolate);
    port.close();

    // Re-spawn to keep the pool at full strength.
    _spawnWorker().catchError((_) {});
  }

  /// Disposes the pool: sends shutdown to all workers, kills isolates, and
  /// completes any pending requests with an error. Safe to call multiple
  /// times. Call from [AuroraHome.dispose].
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _initialized = false;
    _initFuture = null;

    for (final worker in _workers) {
      try {
        worker.sendPort.send({'id': -1, 'type': 'shutdown', 'params': <String, dynamic>{}});
        worker.isolate.kill(priority: Isolate.immediate);
      } catch (_) {}
    }
    _workers.clear();

    // Fail all pending requests.
    for (final entry in _pending.entries) {
      if (!entry.value.isCompleted) {
        entry.value.completeError(StateError('WorkerIsolatePool was disposed'));
      }
    }
    _pending.clear();
  }
}

class _WorkerEntry {
  final Isolate isolate;
  final SendPort sendPort;

  const _WorkerEntry({
    required this.isolate,
    required this.sendPort,
  });
}

// ---------------------------------------------------------------------------
// Worker isolate entry point — runs in a separate isolate.
// ---------------------------------------------------------------------------

/// Entry point for each worker isolate. [mainResponsePort] is the SendPort
/// on the main isolate's response ReceivePort. The worker creates its own
/// ReceivePort for incoming requests, sends its SendPort back via
/// [mainResponsePort], then listens for requests forever (or until shutdown).
void _workerEntryPoint(SendPort mainResponsePort) {
  // Port for receiving requests from the main isolate.
  final requestPort = ReceivePort();
  // Register this worker's request SendPort with the main isolate.
  mainResponsePort.send(requestPort.sendPort);

  // Reusable HTTP client — connection pool persists across probe calls.
  final client = http.Client();

  requestPort.listen((dynamic message) {
    final data = message as Map<String, dynamic>;
    final id = data['id'] as int;
    final type = data['type'] as String;
    final params = data['params'] as Map<String, dynamic>?;

    if (type == 'shutdown') {
      client.close();
      requestPort.close();
      return;
    }

    // Fire-and-forget: handle the request asynchronously, send response
    // via mainResponsePort when done.
    _handleRequest(id, type, params ?? <String, dynamic>{}, client)
        .then((result) {
      mainResponsePort.send({'id': id, 'result': result});
    }).catchError((Object error) {
      mainResponsePort.send({'id': id, 'error': error.toString()});
    });
  });
}

/// Dispatches a single request to the appropriate handler based on [type].
Future<dynamic> _handleRequest(
  int id,
  String type,
  Map<String, dynamic> params,
  http.Client client,
) async {
  switch (type) {
    case 'probe':
      return _handleProbe(params, client);
    case 'jsonDecode':
      return jsonDecode(params['json'] as String);
    case 'jsonEncode':
      return jsonEncode(params['data']);
    case 'parseImage':
      final bytes = Uint8List.fromList(
        (params['bytes'] as List<dynamic>).cast<int>(),
      );
      return parseImageDimensions(bytes);
    case 'parseAudio':
      final bytes = Uint8List.fromList(
        (params['bytes'] as List<dynamic>).cast<int>(),
      );
      return parseAudioHeaders(bytes);
    case 'parseMp4':
      final bytes = Uint8List.fromList(
        (params['bytes'] as List<dynamic>).cast<int>(),
      );
      return parseVideoMp4Atoms(bytes);
    default:
      throw ArgumentError('Unknown worker request type: $type');
  }
}

/// Runs an HTTP probe (HEAD or GET with optional Range) using the shared
/// [client]. Returns the same map shape as the old `_probeInIsolate`:
/// `{statusCode, contentType, contentLength, contentRange, headers, bodyBytes}`.
/// Returns `null` if the request failed or returned a non-2xx/non-3xx status
/// when [onlySuccess] is true.
Future<Map<String, dynamic>?> _handleProbe(
  Map<String, dynamic> params,
  http.Client client,
) async {
  final method = params['method'] as String;
  final url = params['url'] as String;
  final headers = Map<String, String>.from(
    (params['headers'] as Map<String, dynamic>?)?.cast<String, String>() ?? {},
  );
  final range = params['range'] as String?;
  final timeoutSeconds = params['timeoutSeconds'] as int? ?? 10;
  final onlySuccess = params['onlySuccess'] as bool? ?? false;

  try {
    final uri = Uri.parse(url);
    final request = http.Request(method, uri);
    request.headers.addAll(headers);
    if (range != null && range.isNotEmpty) {
      request.headers['Range'] = range;
    }
    request.followRedirects = true;

    final streamedResponse = await client
        .send(request)
        .timeout(Duration(seconds: timeoutSeconds));

    final response = await http.Response.fromStream(streamedResponse);
    if (onlySuccess &&
        (response.statusCode < 200 || response.statusCode >= 400)) {
      return null;
    }
    return {
      'statusCode': response.statusCode,
      'contentType': response.headers['content-type'] ?? '',
      'contentLength':
          int.tryParse(response.headers['content-length'] ?? ''),
      'contentRange': response.headers['content-range'] ?? '',
      'headers': Map<String, String>.from(response.headers),
      'bodyBytes': response.bodyBytes,
    };
  } catch (_) {
    return null;
  }
}

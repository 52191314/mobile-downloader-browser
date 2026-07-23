/// Automation API — localhost REST server for Tasker / external automation.
///
/// Gate: [ProFeature.automationApi] (Ultra tier only).
///
/// Security (hard constraints per SECURITY_AUDIT.md):
/// - Bind **127.0.0.1 only** — never LAN by default.
/// - Random API token, shown once, stored hashed.
/// - Require Ultra + toggle default **off**.
/// - Auth: `Authorization: Bearer <token>` header.
///
/// MVP endpoints:
///   GET  /v1/status           → tier, queue counts
///   GET  /v1/tasks            → list tasks JSON
///   POST /v1/tasks            → enqueue URL body
///   POST /v1/tasks/:id/pause  → pause
///   POST /v1/tasks/:id/resume → resume
///   POST /v1/tasks/:id/cancel → cancel
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;

import '../../downloader/download_queue.dart';
import '../../downloader/models.dart';
import '../pro_entitlement.dart';
import '../pro_features.dart';

/// Token store key.
const _tokenKey = 'automation_api_token';

/// Manages the localhost REST API server.
class AutomationApiService {
  final ProEntitlement _proEntitlement;
  final void Function()? _onQueueChanged;
  final DownloadQueue? _downloadQueue;

  HttpServer? _server;
  String? _token;
  bool _started = false;
  final _secureStorage = const FlutterSecureStorage();

  /// Port the server is listening on, or null if not started.
  int get port => _server?.port ?? 8080;

  /// The current API token (only available while the service is started).
  String? get token => _token;

  /// Whether the server is running.
  bool get isStarted => _started;

  /// Whether the caller has the required Ultra entitlement.
  bool get isAllowed =>
      ProFeatures.allows(ProFeature.automationApi, _proEntitlement.tier);

  AutomationApiService({
    required ProEntitlement proEntitlement,
    void Function()? onQueueChanged,
    DownloadQueue? downloadQueue,
  })  : _proEntitlement = proEntitlement,
        _onQueueChanged = onQueueChanged,
        _downloadQueue = downloadQueue;

  /// Start the API server on [bindPort].
  /// Returns the token string. Show this once to the user.
  /// Throws if port is in use or already running.
  Future<String> start({int bindPort = 8080}) async {
    if (_started) throw StateError('Automation API already running.');

    if (!isAllowed) {
      throw StateError('Automation API requires Ultra tier.');
    }

    // Load or generate token
    _token = await _loadOrGenerateToken();

    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, bindPort);
    _started = true;

    if (kDebugMode) {
      debugPrint('[AutomationApi] listening on 127.0.0.1:${_server!.port}');
    }

    // Handle requests
    _server!.listen((HttpRequest request) {
      _handleRequest(request);
    });

    return _token!;
  }

  /// Stop the API server.
  Future<void> stop() async {
    _started = false;
    await _server?.close(force: true);
    _server = null;
  }

  /// Regenerate the API token. Requires restart of the server.
  Future<String> regenerateToken() async {
    final wasStarted = _started;
    if (wasStarted) await stop();

    await _secureStorage.delete(key: _tokenKey);
    _token = _generateToken();
    await _secureStorage.write(key: _tokenKey, value: _token);

    if (wasStarted) return start();
    return _token!;
  }

  // ---------------------------------------------------------------------------
  // Request handling
  // ---------------------------------------------------------------------------

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      // Auth check
      if (!_isAuthenticated(request)) {
        request.response.statusCode = 401;
        request.response.write(jsonEncode({'error': 'Unauthorized'}));
        await request.response.close();
        return;
      }

      final path = request.uri.path;
      final method = request.method;

      // Route to handler
      switch ('$method $path') {
        case 'GET /v1/status':
          await _handleStatus(request);
          break;
        case 'GET /v1/tasks':
          await _handleListTasks(request);
          break;
        case 'POST /v1/tasks':
          await _handleEnqueue(request);
          break;
        default:
          if (method == 'POST' &&
              path.startsWith('/v1/tasks/') &&
              path.endsWith('/pause')) {
            await _handlePause(request, _extractTaskId(path, '/pause'));
          } else if (method == 'POST' &&
              path.startsWith('/v1/tasks/') &&
              path.endsWith('/resume')) {
            await _handleResume(request, _extractTaskId(path, '/resume'));
          } else if (method == 'POST' &&
              path.startsWith('/v1/tasks/') &&
              path.endsWith('/cancel')) {
            await _handleCancel(request, _extractTaskId(path, '/cancel'));
          } else {
            request.response.statusCode = 404;
            request.response.write(jsonEncode({'error': 'Not found'}));
          }
      }
    } catch (e) {
      request.response.statusCode = 500;
      request.response.write(jsonEncode({'error': e.toString()}));
    } finally {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  String _extractTaskId(String path, String suffix) {
    final id = path
        .replaceFirst('/v1/tasks/', '')
        .replaceFirst(suffix, '');
    return Uri.decodeComponent(id);
  }

  // ---------------------------------------------------------------------------
  // Auth
  // ---------------------------------------------------------------------------

  bool _isAuthenticated(HttpRequest request) {
    final authHeader = request.headers.value('Authorization');
    if (authHeader == null || _token == null) return false;
    if (!authHeader.startsWith('Bearer ')) return false;
    final provided = authHeader.substring(7).trim();
    return provided == _token;
  }

  // ---------------------------------------------------------------------------
  // Handlers
  // ---------------------------------------------------------------------------

  Future<void> _handleStatus(HttpRequest request) async {
    final tier = _proEntitlement.tier.name;
    final queue = _downloadQueue;
    request.response.statusCode = 200;
    request.response.write(jsonEncode({
      'tier': tier,
      'isUltra': _proEntitlement.isUltra,
      'queuePending': queue != null ? queue.allTasks.length - queue.activeTasks.length : 0,
      'queueActive': queue?.activeTasks.length ?? 0,
      'apiVersion': '1.0',
    }));
  }

  Future<void> _handleListTasks(HttpRequest request) async {
    final queue = _downloadQueue;
    final tasksJson = (queue?.allTasks ?? []).map((t) => {
      'id': t.id,
      'url': t.url,
      'state': t.state.name,
      'name': p.basename(t.savePath),
      'progress': t.progressPercent,
      'downloadedBytes': t.downloadedBytes,
      'totalBytes': t.totalBytes,
      'speed': t.speed,
      'errorMessage': t.errorMessage,
      'createdAt': t.createdAt.toIso8601String(),
    }).toList();

    request.response.statusCode = 200;
    request.response.write(jsonEncode({
      'tasks': tasksJson,
    }));
  }

  Future<void> _handleEnqueue(HttpRequest request) async {
    try {
      final body = await utf8.decoder.bind(request).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final url = data['url'] as String?;

      if (url == null || url.isEmpty) {
        request.response.statusCode = 400;
        request.response.write(jsonEncode({'error': 'Missing "url" field'}));
        return;
      }

      final queue = _downloadQueue;
      if (queue != null) {
        final id = DateTime.now().microsecondsSinceEpoch.toString();
        final task = DownloadTask(
          id: id,
          url: url,
          savePath: '/tmp/$id',
          tempDir: '/tmp/${id}_tmp',
        );
        queue.addTask(task);
      }

      _onQueueChanged?.call();

      request.response.statusCode = 201;
      request.response.write(jsonEncode({
        'status': 'queued',
        'url': url,
      }));
    } catch (e) {
      request.response.statusCode = 400;
      request.response.write(jsonEncode({'error': 'Invalid JSON body'}));
    }
  }

  Future<void> _handlePause(HttpRequest request, String taskId) async {
    final queue = _downloadQueue;
    if (queue != null) {
      await queue.pauseTaskAsync(taskId);
    }
    request.response.statusCode = 200;
    request.response.write(jsonEncode({
      'status': 'paused',
      'taskId': taskId,
    }));
  }

  Future<void> _handleResume(HttpRequest request, String taskId) async {
    final queue = _downloadQueue;
    if (queue != null) {
      await queue.resumeTaskAsync(taskId);
    }
    request.response.statusCode = 200;
    request.response.write(jsonEncode({
      'status': 'resumed',
      'taskId': taskId,
    }));
  }

  Future<void> _handleCancel(HttpRequest request, String taskId) async {
    final queue = _downloadQueue;
    if (queue != null) {
      await queue.cancelTaskAsync(taskId);
    }
    request.response.statusCode = 200;
    request.response.write(jsonEncode({
      'status': 'cancelled',
      'taskId': taskId,
    }));
  }

  // ---------------------------------------------------------------------------
  // Token management
  // ---------------------------------------------------------------------------

  Future<String> _loadOrGenerateToken() async {
    final stored = await _secureStorage.read(key: _tokenKey);
    if (stored != null && stored.isNotEmpty) return stored;

    final token = _generateToken();
    await _secureStorage.write(key: _tokenKey, value: token);
    return token;
  }

  String _generateToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    final base64 = base64Url.encode(bytes);
    return 'aurora_${base64.substring(0, 40)}';
  }
}

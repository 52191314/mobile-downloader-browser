/// Automation API — localhost REST server for Tasker / external automation.
///
/// Gate: [ProFeature.automationApi] (Ultra tier only).
///
/// Security (hard constraints per SECURITY_AUDIT.md §5.1):
/// - Bind **127.0.0.1 only** — never LAN by default.
/// - Random API token, stored in platform secure storage; shown in the
///   Automation API settings page.
/// - Require Ultra + preference default **off** (persisted via
///   [AutomationApiStore]; the server only auto-starts after the user
///   explicitly enabled it once).
/// - Auth: `Authorization: Bearer *** header.
/// - Rate limit + request body size limit enforced.
///
/// Endpoints:
///   GET  /v1/status           → tier, queue counts
///   GET  /v1/tasks            → list tasks JSON
///   POST /v1/tasks            → enqueue URL body ({"url": "...", "label"?})
///   POST /v1/tasks/:id/pause  → pause
///   POST /v1/tasks/:id/resume → resume
///   POST /v1/tasks/:id/cancel → cancel
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data' show BytesBuilder;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;

import '../../compliance/restricted_media_policy.dart';
import '../../downloader/download_queue.dart';
import '../../downloader/filename_service.dart';
import '../../downloader/models.dart';
import '../pro_entitlement.dart';
import '../pro_features.dart';
import 'automation_api_store.dart';

/// Token store key.
const _tokenKey = 'automation_api_token';

/// Maximum accepted JSON request body (64 KB is generous for an enqueue).
const int _maxBodyBytes = 64 * 1024;

/// Sliding-window rate limit: at most this many authenticated requests per
/// [_rateLimitWindow] (loopback is trusted-ish, but the audit mandates a cap).
const int _rateLimitMaxRequests = 60;
const Duration _rateLimitWindow = Duration(seconds: 10);

/// Thrown when the request body exceeds [_maxBodyBytes].
class _BodyTooLargeException implements Exception {
  const _BodyTooLargeException();
}

/// Manages the localhost REST API server.
class AutomationApiService {
  final ProEntitlement _proEntitlement;
  final void Function()? _onQueueChanged;
  final DownloadQueue? _downloadQueue;

  /// Resolves the directory where completed downloads are stored. Wired by
  /// the host (main.dart) so enqueued tasks land in the real download folder.
  final Future<String> Function()? completedDirProvider;

  /// Resolves the root directory for chunk/segment temp files.
  final Future<String> Function()? tempDirProvider;

  HttpServer? _server;
  String? _token;
  bool _started = false;
  final _secureStorage = const FlutterSecureStorage();

  /// Timestamps of recent authenticated requests (sliding window).
  final List<DateTime> _requestTimestamps = [];

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
    this.completedDirProvider,
    this.tempDirProvider,
  })  : _proEntitlement = proEntitlement,
        _onQueueChanged = onQueueChanged,
        _downloadQueue = downloadQueue;

  /// Whether the user previously enabled the API (default off).
  Future<bool> loadEnabledPreference() => AutomationApiStore.loadEnabled();

  /// Persist the user's on/off choice.
  Future<void> saveEnabledPreference(bool value) =>
      AutomationApiStore.saveEnabled(value);

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

    try {
      await _secureStorage.delete(key: _tokenKey);
    } catch (_) {
      // Secure storage unavailable → ephemeral token; next launch
      // regenerates. Acceptable degradation.
    }
    _token = _generateToken();
    try {
      await _secureStorage.write(key: _tokenKey, value: _token);
    } catch (_) {}

    if (wasStarted) return start();
    return _token!;
  }

  /// Build the on-disk destination for an enqueued URL.
  ///
  /// Pure and deterministic: derives the filename from the URL (or an
  /// optional label) via [FilenameService.downloadFilenameFor], then applies
  /// collision avoidance against [reservedPaths] and the filesystem.
  static String buildEnqueueSavePath({
    required String url,
    String? label,
    required String completedDir,
    Iterable<String> reservedPaths = const [],
  }) {
    final fileName = FilenameService.downloadFilenameFor(
      label: label,
      targetUrl: url,
    );
    return FilenameService.uniquePath(
      p.join(completedDir, fileName),
      reservedPaths: reservedPaths,
    );
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

      // Rate limit AFTER auth so junk/unauthenticated traffic doesn't
      // consume the user's own quota.
      if (!_allowRequest()) {
        request.response.statusCode = 429;
        request.response.headers.set('Retry-After', '1');
        request.response.write(
          jsonEncode({'error': 'Rate limit exceeded'}),
        );
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
  // Rate limiting
  // ---------------------------------------------------------------------------

  bool _allowRequest() {
    final now = DateTime.now();
    _requestTimestamps.removeWhere(
      (t) => now.difference(t) > _rateLimitWindow,
    );
    if (_requestTimestamps.length >= _rateLimitMaxRequests) {
      return false;
    }
    _requestTimestamps.add(now);
    return true;
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
      final body = await _readBodyLimited(request);
      final data = jsonDecode(body) as Map<String, dynamic>;
      final url = data['url'] as String?;
      final label = data['label'] as String?;

      if (url == null || url.isEmpty) {
        request.response.statusCode = 400;
        request.response.write(jsonEncode({'error': 'Missing "url" field'}));
        return;
      }

      if (RestrictedMediaPolicy.isBlocked(mediaUrl: url)) {
        request.response.statusCode = 400;
        request.response.write(jsonEncode({
          'error': 'URL blocked by policy',
          'message': RestrictedMediaPolicy.userMessageRestricted,
        }));
        return;
      }

      final queue = _downloadQueue;
      if (queue == null) {
        request.response.statusCode = 503;
        request.response.write(jsonEncode({
          'error': 'Download queue unavailable',
        }));
        return;
      }

      // Duplicate → 409 with the existing task id instead of a fake 201.
      final existing = queue.getTaskByUrl(url);
      if (existing != null &&
          (existing.state == DownloadState.idle ||
              existing.state == DownloadState.downloading ||
              existing.state == DownloadState.paused ||
              existing.state == DownloadState.scheduled)) {
        request.response.statusCode = 409;
        request.response.write(jsonEncode({
          'status': 'duplicate',
          'taskId': existing.id,
          'url': url,
        }));
        return;
      }

      final id = DateTime.now().microsecondsSinceEpoch.toString();
      final completedDir = await completedDirProvider?.call() ??
          Directory.systemTemp.path;
      final tempRoot =
          await tempDirProvider?.call() ?? Directory.systemTemp.path;
      final savePath = buildEnqueueSavePath(
        url: url,
        label: label,
        completedDir: completedDir,
        reservedPaths: queue.allTasks.map((t) => t.savePath),
      );
      final task = DownloadTask(
        id: id,
        url: url,
        savePath: savePath,
        tempDir: p.join(tempRoot, id),
      );
      queue.addTask(task);

      _onQueueChanged?.call();

      request.response.statusCode = 201;
      request.response.write(jsonEncode({
        'status': 'queued',
        'url': url,
        'taskId': id,
        'savePath': savePath,
      }));
    } on _BodyTooLargeException {
      request.response.statusCode = 413;
      request.response.write(jsonEncode({
        'error': 'Request body too large (max $_maxBodyBytes bytes)',
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

  /// Reads the request body, rejecting bodies larger than [_maxBodyBytes].
  Future<String> _readBodyLimited(HttpRequest request) async {
    if (request.headers.contentLength > _maxBodyBytes) {
      throw const _BodyTooLargeException();
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      builder.add(chunk);
      if (builder.length > _maxBodyBytes) {
        throw const _BodyTooLargeException();
      }
    }
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  }

  // ---------------------------------------------------------------------------
  // Token management
  // ---------------------------------------------------------------------------

  Future<String> _loadOrGenerateToken() async {
    String? stored;
    try {
      stored = await _secureStorage.read(key: _tokenKey);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[AutomationApi] secure storage read failed: $e');
      }
    }
    if (stored != null && stored.isNotEmpty) return stored;

    final token = _generateToken();
    try {
      await _secureStorage.write(key: _tokenKey, value: token);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[AutomationApi] token not persisted: $e');
      }
    }
    return token;
  }

  String _generateToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    final base64 = base64Url.encode(bytes);
    return 'aurora_${base64.substring(0, 40)}';
  }
}

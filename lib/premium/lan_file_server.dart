import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// ignore: implementation_imports
import 'package:aurora_downloader/platform/download_foreground_service.dart';

import 'free_taste.dart';
import 'pro_entitlement.dart';
import 'pro_features.dart';

/// Send-to-PC LAN file server (P6) — hardened.
///
/// Security model:
/// - Binds the **LAN IPv4 address only** (not 0.0.0.0) when Wi-Fi is active.
/// - Single route: `GET /d/{token}/{safeFileName}`.
/// - Tokens map 1:1 to allowlisted absolute paths under known download roots.
/// - Tokens are **single-use** and the whole share session has an absolute TTL.
/// - Files are **streamed** (no full-file RAM load).
/// - Cleartext HTTP on LAN only (documented risk).
/// - Re-checks entitlement / free-taste inside [start] (no `permitted` footgun).
class LanFileServer {
  LanFileServer._();

  static const int defaultPort = 17890;
  static const Duration idleTimeout = Duration(minutes: 10);
  static const Duration absoluteTtl = Duration(minutes: 15);
  static const int maxConcurrent = 4;
  static const int rateLimitPerMinute = 30;

  static HttpServer? _server;
  static String? _lanIpAddress;
  static final Map<String, _ShareEntry> _tokenToPath = {};
  static final Map<String, int> _ipRequestCounts = {};
  static final Set<HttpRequest> _active = {};
  static Timer? _idleTimer;
  static Timer? _absoluteTimer;
  static DateTime? _lastRequestAt;
  static DateTime? _startedAt;
  static final Random _rng = Random.secure();
  static List<String> _allowedRoots = const [];

  static bool get isRunning => _server != null;

  static String? get baseUrl {
    if (_server == null || _lanIpAddress == null) return null;
    return 'http://$_lanIpAddress:$defaultPort';
  }

  /// Absolute share deadline (wall clock), if running.
  static DateTime? get expiresAt {
    final started = _startedAt;
    if (started == null) return null;
    return started.add(absoluteTtl);
  }

  /// Issues a **single-use** token scoped to [filePath].
  static String? issueToken(String filePath) {
    if (_server == null) return null;
    final resolved = _resolveAllowedPath(filePath);
    if (resolved == null) return null;
    final token = _randomToken();
    _tokenToPath[token] = _ShareEntry(path: resolved);
    final safeName = Uri.encodeComponent(p.basename(resolved));
    return '${baseUrl!}/d/$token/$safeName';
  }

  /// Starts the server for [files] if [tier] may use Send-to-PC free taste
  /// or Pro+. Returns true on success.
  ///
  /// Free daily quota is **not** consumed here — the caller must consume after
  /// a successful start (peek is done inside for a fail-closed check).
  static Future<bool> start(
    List<String> files, {
    required EntitlementTier tier,
  }) async {
    if (_server != null) return true;
    if (files.isEmpty) return false;

    // Entitlement re-check (do not trust a bare permitted flag).
    final unlimited = ProFeatures.allows(ProFeature.sendToPc, tier);
    if (!unlimited) {
      final peek = await FreeTaste.evaluate(
        feature: ProFeature.sendToPc,
        tier: tier,
        n: files.length,
        consume: false,
      );
      if (!peek.allowed) return false;
    }

    if (!await _onWifi()) return false;
    final ip = await _lanIp();
    if (ip == null) return false;
    _lanIpAddress = ip;

    _allowedRoots = await _computeAllowedRoots();
    final allowedFiles = <String>[];
    for (final f in files) {
      final resolved = _resolveAllowedPath(f);
      if (resolved != null) allowedFiles.add(resolved);
    }
    if (allowedFiles.isEmpty) return false;

    try {
      // Bind only the LAN address — not anyIPv4.
      _server = await HttpServer.bind(InternetAddress(ip), defaultPort);
    } catch (e) {
      _lanIpAddress = null;
      if (kDebugMode) debugPrint('[LanFileServer] bind failed: $e');
      return false;
    }

    _tokenToPath.clear();
    _ipRequestCounts.clear();
    _lastRequestAt = DateTime.now();
    _startedAt = DateTime.now();
    _armIdleTimer();
    _armAbsoluteTimer();

    unawaited(DownloadForegroundService.start(count: 1));

    _server!.listen(_handleRequest, onError: (e) {
      if (kDebugMode) debugPrint('[LanFileServer] request error: $e');
    });
    return true;
  }

  static Future<void> stop() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    _absoluteTimer?.cancel();
    _absoluteTimer = null;
    final server = _server;
    _server = null;
    _lanIpAddress = null;
    _startedAt = null;
    _tokenToPath.clear();
    _ipRequestCounts.clear();
    _allowedRoots = const [];
    for (final req in _active) {
      try {
        req.response.close();
      } catch (_) {}
    }
    _active.clear();
    if (server != null) {
      await server.close(force: true);
    }
    unawaited(DownloadForegroundService.stop());
  }

  // ---- internals ----

  static Future<void> _handleRequest(HttpRequest req) async {
    _lastRequestAt = DateTime.now();
    _armIdleTimer();

    // Absolute TTL enforced on every request.
    final started = _startedAt;
    if (started != null &&
        DateTime.now().difference(started) >= absoluteTtl) {
      _respond(req, HttpStatus.gone, 'Share expired');
      unawaited(stop());
      return;
    }

    final clientIp = req.connectionInfo?.remoteAddress.address ?? '';
    if (!_rateOk(clientIp)) {
      _respond(req, HttpStatus.tooManyRequests, 'Rate limited');
      return;
    }
    if (_active.length >= maxConcurrent) {
      _respond(req, HttpStatus.serviceUnavailable, 'Too many connections');
      return;
    }

    if (req.method != 'GET' || !req.uri.path.startsWith('/d/')) {
      _respond(req, HttpStatus.notFound, 'Not found');
      return;
    }

    final segments = req.uri.pathSegments;
    if (segments.length < 3) {
      _respond(req, HttpStatus.notFound, 'Not found');
      return;
    }
    final token = segments[1];
    final entry = _tokenToPath.remove(token); // single-use
    if (entry == null) {
      _respond(req, HttpStatus.forbidden, 'Invalid or used token');
      return;
    }

    // Re-validate path still under roots (TOCTOU).
    final allowedPath = _resolveAllowedPath(entry.path);
    if (allowedPath == null) {
      _respond(req, HttpStatus.forbidden, 'Path not allowed');
      return;
    }

    final file = File(allowedPath);
    if (!file.existsSync()) {
      _respond(req, HttpStatus.notFound, 'File gone');
      return;
    }

    try {
      _active.add(req);
      final name = _safeContentFilename(segments.last);
      final length = await file.length();
      req.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.binary
        ..headers.set(
          'Content-Disposition',
          'attachment; filename="$name"',
        )
        ..headers.contentLength = length;
      await req.response.addStream(file.openRead());
      await req.response.close();
    } catch (e) {
      // Token already consumed; do not re-issue.
      _respond(req, HttpStatus.internalServerError, 'Read failed');
    } finally {
      _active.remove(req);
    }
  }

  static String _safeContentFilename(String raw) {
    var name = Uri.decodeComponent(raw);
    name = p.basename(name).replaceAll(RegExp(r'[\r\n"]'), '_');
    if (name.isEmpty) name = 'download';
    return name;
  }

  static void _respond(HttpRequest req, int code, String body) {
    try {
      req.response
        ..statusCode = code
        ..headers.contentType = ContentType.text
        ..headers.contentLength = body.length
        ..write(body)
        ..close();
    } catch (_) {}
  }

  static bool _rateOk(String ip) {
    final now = DateTime.now();
    final minuteKey =
        '${now.year}-${now.month}-${now.day}-${now.hour}-${now.minute}';
    final key = '$ip@$minuteKey';
    final count = (_ipRequestCounts[key] ?? 0) + 1;
    _ipRequestCounts[key] = count;
    // Evict only old minutes, do not wipe all limits.
    if (_ipRequestCounts.length > 256) {
      final prefix =
          '${now.year}-${now.month}-${now.day}-${now.hour}-${now.minute}';
      _ipRequestCounts.removeWhere((k, _) => !k.endsWith(prefix));
    }
    return count <= rateLimitPerMinute;
  }

  static void _armIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(idleTimeout, () {
      if (_lastRequestAt != null &&
          DateTime.now().difference(_lastRequestAt!) >= idleTimeout) {
        unawaited(stop());
      }
    });
  }

  static void _armAbsoluteTimer() {
    _absoluteTimer?.cancel();
    _absoluteTimer = Timer(absoluteTtl, () {
      unawaited(stop());
    });
  }

  static String _randomToken() {
    final bytes = List<int>.generate(32, (_) => _rng.nextInt(256));
    return base64Url.encode(bytes);
  }

  static Future<bool> _onWifi() async {
    try {
      final result = await Connectivity().checkConnectivity();
      return result.contains(ConnectivityResult.wifi);
    } catch (_) {
      return false;
    }
  }

  static Future<String?> _lanIp() async {
    try {
      for (final iface in await NetworkInterface.list()) {
        final n = iface.name.toLowerCase();
        if (n.contains('wlan') ||
            n.contains('wi') ||
            n.contains('eth') ||
            n.contains('en')) {
          for (final addr in iface.addresses) {
            if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
              return addr.address;
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }

  static Future<List<String>> _computeAllowedRoots() async {
    final roots = <String>[];
    try {
      final docs = await getApplicationDocumentsDirectory();
      roots.add(await Directory(docs.path).resolveSymbolicLinks());
      final completed = Directory(p.join(docs.path, 'completed'));
      if (await completed.exists()) {
        roots.add(await completed.resolveSymbolicLinks());
      }
    } catch (_) {}
    try {
      final support = await getApplicationSupportDirectory();
      roots.add(await Directory(support.path).resolveSymbolicLinks());
    } catch (_) {}
    try {
      final tmp = await getTemporaryDirectory();
      roots.add(await Directory(tmp.path).resolveSymbolicLinks());
    } catch (_) {}
    return roots;
  }

  /// Returns resolved absolute path if file exists and is under an allowed root.
  static String? _resolveAllowedPath(String filePath) {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return null;
      final resolved = file.resolveSymbolicLinksSync();
      final normalized = p.normalize(resolved);
      for (final root in _allowedRoots) {
        final r = p.normalize(root);
        if (normalized == r ||
            normalized.startsWith(r.endsWith(p.separator) ? r : '$r${p.separator}')) {
          return normalized;
        }
      }
      // Also allow exact path if roots not yet loaded but file is under docs
      // (issueToken after start always has roots).
      if (_allowedRoots.isEmpty) return null;
    } catch (_) {}
    return null;
  }
}

class _ShareEntry {
  final String path;
  _ShareEntry({required this.path});
}

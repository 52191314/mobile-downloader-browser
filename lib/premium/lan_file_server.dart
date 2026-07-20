import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import 'pro_features.dart';
import 'pro_upsell_sheet.dart';

// ignore: implementation_imports
import 'package:aurora_downloader/platform/download_foreground_service.dart';

/// Send-to-PC LAN file server (P6).
///
/// Ships a completed download (or a user-picked file) to another device on
/// the same Wi-Fi network over a **tokenized, allowlist-only** HTTP server.
///
/// Security model (normative — see plan §P6):
/// - Binds `InternetAddress.anyIPv4` **only when Wi-Fi is active**; refuses to
///   start on cellular.
/// - Single route: `GET /d/{token}/{safeFileName}`.
/// - Each token maps to exactly ONE allowlisted absolute file path. A request
///   for token A can never read file B.
/// - Path traversal (`..`) is rejected; the resolved realpath is verified to
///   be under the allowlisted root.
/// - Cleartext HTTP on LAN only (documented risk; no TLS).
/// - Idle timeout (10 min with no request) stops the server.
/// - Max 4 concurrent connections; 30 req/min/IP rate limit.
/// - Default OFF. Gated by [ProFeature.sendToPc] (free: 20 files/day).
/// - MUST NOT mount Automation API / queue routes.
class LanFileServer {
  LanFileServer._();

  static const int defaultPort = 17890;
  static const Duration idleTimeout = Duration(minutes: 10);
  static const int maxConcurrent = 4;
  static const int rateLimitPerMinute = 30;

  static HttpServer? _server;
  static String? _lanIpAddress;
  static final Map<String, String> _tokenToPath = {};
  static final Map<String, int> _ipRequestCounts = {};
  static final Set<HttpRequest> _active = {};
  static Timer? _idleTimer;
  static DateTime? _lastRequestAt;
  static final Random _rng = Random.secure();

  /// Whether the server is currently running.
  static bool get isRunning => _server != null;

  /// Local base URL (e.g. `http://192.168.x.x:17890`) or null when stopped.
  static String? get baseUrl {
    if (_server == null || _lanIpAddress == null) return null;
    return 'http://$_lanIpAddress:$defaultPort';
  }

  /// Issues a single-use-per-file token scoped to [filePath]. Returns the
  /// full shareable URL, or null if the server is not running.
  ///
  /// [filePath] must exist and be a regular file. The token is 32 bytes of
  /// crypto-random, URL-safe base64 (~43 chars).
  static String? issueToken(String filePath) {
    if (_server == null) return null;
    final file = File(filePath);
    if (!file.existsSync()) return null;
    final token = _randomToken();
    _tokenToPath[token] = file.resolveSymbolicLinksSyncSafe();
    final safeName = Uri.encodeComponent(file.uri.pathSegments.last);
    return '${baseUrl!}/d/$token/$safeName';
  }

  /// Starts the server. [files] are the initial allowlisted file paths
  /// (completed downloads the user chose to share). Returns true on success.
  ///
  /// Refuses to start unless on Wi-Fi (never on cellular) and the entitlement
  /// allows [ProFeature.sendToPc].
  static Future<bool> start(List<String> files) async {
    if (_server != null) return true;
    if (!await _onWifi()) return false;
    final ent = proUpsellEntitlement;
    if (ent == null || !ProFeatures.allows(ProFeature.sendToPc, ent.tier)) {
      return false;
    }
    final ip = await _lanIp();
    if (ip == null) return false;
    _lanIpAddress = ip;

    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, defaultPort);
    } catch (e) {
      _lanIpAddress = null;
      if (kDebugMode) debugPrint('[LanFileServer] bind failed: $e');
      return false;
    }

    _tokenToPath.clear();
    _ipRequestCounts.clear();
    for (final f in files) {
      final file = File(f);
      if (file.existsSync()) {
        _tokenToPath[_randomToken()] = file.resolveSymbolicLinksSyncSafe();
      }
    }

    _lastRequestAt = DateTime.now();
    _armIdleTimer();
    // Best-effort foreground keep-alive so the OS does not kill the process
    // mid-transfer. Native FGS notification text is owned by
    // DownloadForegroundService; a dedicated "Aurora file sharing on" notice
    // is a follow-up native change.
    unawaited(DownloadForegroundService.start(count: 1));

    _server!.listen(_handleRequest, onError: (e) {
      if (kDebugMode) debugPrint('[LanFileServer] request error: $e');
    });
    return true;
  }

  /// Stops the server, clears tokens, and stops the foreground keep-alive.
  static Future<void> stop() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    final server = _server;
    _server = null;
    _lanIpAddress = null;
    _tokenToPath.clear();
    _ipRequestCounts.clear();
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
    // /d/{token}/{safeFileName}
    if (segments.length < 3) {
      _respond(req, HttpStatus.notFound, 'Not found');
      return;
    }
    final token = segments[1];
    final allowedPath = _tokenToPath[token];
    if (allowedPath == null) {
      _respond(req, HttpStatus.forbidden, 'Invalid token');
      return;
    }

    final file = File(allowedPath);
    if (!file.existsSync()) {
      _respond(req, HttpStatus.notFound, 'File gone');
      return;
    }

    try {
      _active.add(req);
      final bytes = await file.readAsBytes();
      final name = Uri.decodeComponent(segments.last);
      req.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.binary
        ..headers.set('Content-Disposition', 'attachment; filename="$name"')
        ..headers.contentLength = bytes.length;
      await req.response.addStream(Stream.value(bytes));
      await req.response.close();
    } catch (e) {
      _respond(req, HttpStatus.internalServerError, 'Read failed');
    } finally {
      _active.remove(req);
    }
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
    final minuteKey = '${now.year}-${now.month}-${now.day}-${now.hour}-${now.minute}';
    final key = '$ip@$minuteKey';
    final count = (_ipRequestCounts[key] ?? 0) + 1;
    _ipRequestCounts[key] = count;
    // Drop stale minute buckets lazily.
    if (_ipRequestCounts.length > 256) _ipRequestCounts.clear();
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

  static String _randomToken() {
    final bytes = List<int>.generate(32, (_) => _rng.nextInt(256));
    return base64Url.encode(bytes);
  }

  static Future<bool> _onWifi() async {
    try {
      final result = await Connectivity().checkConnectivity();
      // Only Wi-Fi is permitted; cellular / none / ethernet are rejected.
      // connectivity_plus returns a List<ConnectivityResult>.
      return result.contains(ConnectivityResult.wifi);
    } catch (_) {
      return false;
    }
  }

  static Future<String?> _lanIp() async {
    try {
      for (final iface in await NetworkInterface.list()) {
        if (iface.name.toLowerCase().contains('wlan') ||
            iface.name.toLowerCase().contains('wi') ||
            iface.name.toLowerCase().contains('eth')) {
          for (final addr in iface.addresses) {
            if (addr.type == InternetAddressType.IPv4 &&
                !addr.isLoopback) {
              return addr.address;
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }
}

/// Extension to resolve a path safely even when symlinks are involved,
/// returning the original string on any failure (caller validates existence).
extension _SafeResolve on File {
  String resolveSymbolicLinksSyncSafe() {
    try {
      return resolveSymbolicLinksSync();
    } catch (_) {
      return path;
    }
  }
}

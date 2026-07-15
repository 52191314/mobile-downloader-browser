import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'downloader/download_logger.dart';

/// A tiny HTTP server that exposes the in-memory [DownloadLogger] log buffer as
/// a human-readable web page and a JSON endpoint.
///
/// Intentionally debug-only: it is only ever started when [kDebugMode] is true
/// (see [startLogServerIfDebug]). Shipping it in a release build would expose
/// internal download metadata (URLs, file paths) over the local network, so the
/// caller must never start it in release mode.
class LogServer {
  LogServer._internal();
  static final LogServer instance = LogServer._internal();

  HttpServer? _server;
  int _port = 8080;

  bool get isRunning => _server != null;
  int get port => _port;

  Future<void> start({int port = 8080}) async {
    if (_server != null) return;
    _port = port;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      _server!.listen(_handleRequest);
      debugPrint('[LogServer] Listening on http://0.0.0.0:$port');
    } catch (e) {
      debugPrint('[LogServer] Failed to start: $e');
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (path == '/json') {
        await _serveJson(request);
      } else {
        await _serveHtml(request);
      }
    } catch (e) {
      try {
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..write('Error: $e')
          ..close();
      } catch (_) {
        // Response already closed or unavailable.
      }
    }
  }

  Future<void> _serveJson(HttpRequest request) async {
    final logs = DownloadLogger.instance.logs
        .map((e) => e.toJson())
        .toList(growable: false);
    final body = jsonEncode({'logs': logs});
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(body)
      ..close();
  }

  Future<void> _serveHtml(HttpRequest request) async {
    final logs = DownloadLogger.instance.logs;
    final rows = logs.map((e) {
      final esc = _escape(e.message);
      return '<tr class="${e.level.toLowerCase()}">'
          '<td>${e.formattedTime}</td>'
          '<td>${e.level}</td>'
          '<td>$esc</td></tr>';
    }).join('\n');
    final body = '''
<!doctype html>
<html><head><meta charset="utf-8">
<title>Aurora Download Logs</title>
<style>
body{font-family:monospace;background:#111;color:#eee;padding:16px}
table{border-collapse:collapse;width:100%}
td,th{border:1px solid #333;padding:4px 8px;text-align:left;vertical-align:top}
th{background:#222}
.ERROR{color:#ff6b6b}.WARN{color:#ffd93d}.INFO{color:#6bcb77}
h1{font-size:18px}
a{color:#6bcb77}
</style></head>
<body>
<h1>Aurora Download Logs (debug)</h1>
<p>${logs.length} entries. <a href="/json">JSON</a></p>
<table>
<tr><th>Time</th><th>Level</th><th>Message</th></tr>
$rows
</table>
</body></html>''';
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..write(body)
      ..close();
  }

  String _escape(String s) {
    return s
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
  }
}

/// Starts the log server only in debug builds. No-op in release.
Future<void> startLogServerIfDebug({int port = 8080}) async {
  if (!kDebugMode) return;
  await LogServer.instance.start(port: port);
}

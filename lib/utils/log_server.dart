import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../logging/aurora_log.dart';

class LogServer {
  static HttpServer? _server;
  static final List<WebSocket> _clients = [];

  static Future<void> start() async {
    if (_server != null) return;

    try {
      // Bind to 0.0.0.0 so it is accessible from the local network (Wi-Fi)
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
      debugPrint('[LogServer] Embedded log server listening on port 8080');

      // Listen to log events from AuroraLog
      AuroraLog.instance.onLogAdded.listen((entry) {
        final logMsg = '[${entry.formattedTime}] [${entry.level.name.toUpperCase()}] [${entry.category.name}/${entry.screen.name}] ${entry.message}';
        _broadcast(logMsg);
      });

      _server!.listen((HttpRequest request) async {
        if (request.uri.path == '/ws' && WebSocketTransformer.isUpgradeRequest(request)) {
          final socket = await WebSocketTransformer.upgrade(request);
          _clients.add(socket);
          debugPrint('[LogServer] Client connected to live WebSocket console');

          // Send recent logs history to newly connected client
          final recentEntries = AuroraLog.instance.entries.take(100).toList().reversed;
          for (final entry in recentEntries) {
            final logMsg = '[${entry.formattedTime}] [${entry.level.name.toUpperCase()}] [${entry.category.name}/${entry.screen.name}] ${entry.message}';
            socket.add(logMsg);
          }

          socket.done.then((_) {
            _clients.remove(socket);
            debugPrint('[LogServer] Client disconnected from live WebSocket console');
          });
        } else if (request.uri.path == '/') {
          // Serve the interactive dark-mode HTML Console Dashboard
          request.response
            ..headers.contentType = ContentType.html
            ..write(_htmlConsolePage())
            ..close();
        } else {
          request.response
            ..statusCode = HttpStatus.notFound
            ..close();
        }
      });
    } catch (e) {
      debugPrint('[LogServer] Failed to start log server: $e');
    }
  }

  static void _broadcast(String message) {
    for (final client in _clients) {
      try {
        client.add(message);
      } catch (_) {
        // Prevent broken socket writes from crashing the server
      }
    }
  }

  static String _htmlConsolePage() {
    return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Aurora Downloader Console</title>
  <style>
    body { background-color: #1e1e1e; color: #d4d4d4; font-family: 'Consolas', 'Courier New', monospace; padding: 20px; margin: 0; }
    h2 { margin: 0 0 15px 0; font-family: sans-serif; font-weight: 500; font-size: 1.5rem; color: #e1e1e1; }
    #console { border: 1px solid #333; height: 85vh; overflow-y: scroll; padding: 12px; background-color: #0c0c0c; border-radius: 6px; box-shadow: inset 0 0 10px rgba(0,0,0,0.8); }
    .log { margin: 4px 0; white-space: pre-wrap; line-height: 1.4; border-bottom: 1px solid #141414; padding-bottom: 2px; }
    .debug { color: #858585; }
    .info { color: #4fc1ff; }
    .warn { color: #cca700; }
    .error { color: #f44747; font-weight: bold; }
    .fatal { color: #ff3333; font-weight: bold; text-transform: uppercase; background: rgba(255, 51, 51, 0.1); padding: 2px 4px; border-radius: 3px; }
  </style>
</head>
<body>
  <h2>Aurora Downloader Log Dashboard</h2>
  <div id="console"></div>
  <script>
    const consoleDiv = document.getElementById('console');
    const wsUri = 'ws://' + window.location.host + '/ws';
    const websocket = new WebSocket(wsUri);

    websocket.onmessage = function(evt) {
      const logLine = document.createElement('div');
      logLine.className = 'log';
      const msg = evt.data;
      
      if (msg.includes('[DEBUG]')) logLine.classList.add('debug');
      else if (msg.includes('[INFO]')) logLine.classList.add('info');
      else if (msg.includes('[WARN]')) logLine.classList.add('warn');
      else if (msg.includes('[ERROR]')) logLine.classList.add('error');
      else if (msg.includes('[FATAL]')) logLine.classList.add('fatal');

      logLine.textContent = msg;
      consoleDiv.appendChild(logLine);
      consoleDiv.scrollTop = consoleDiv.scrollHeight;
    };

    websocket.onopen = function() {
      const conn = document.createElement('div');
      conn.className = 'log info';
      conn.textContent = '[Console] Connected to live Aurora Downloader socket.';
      consoleDiv.appendChild(conn);
    };

    websocket.onclose = function() {
      const disconn = document.createElement('div');
      disconn.className = 'log error';
      disconn.textContent = '[Console] Connection lost. Reconnecting...';
      consoleDiv.appendChild(disconn);
      setTimeout(() => location.reload(), 3000);
    };
  </script>
</body>
</html>
    ''';
  }
}

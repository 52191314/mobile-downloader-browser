import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../downloader/hls_playlist_parser.dart';

/// WebView-side WAF-bypass fetch methods.
///
/// These methods either run JS in the WebView to fetch URLs through the
/// browser's networking stack (which carries the WebView's TLS fingerprint,
/// cookies, and other context that Dart's `http.Client` lacks) or wrap a
/// Dart `http.Client` GET with cookies lifted from the WebView. This is
/// the key to bypassing Cloudflare WAF and similar protections that block
/// standalone Dart HTTP clients.
class WebViewFetchDelegate {
  WebViewFetchDelegate({
    required InAppWebViewController? controller,
    required String? Function() getCurrentUrl,
  })  : _controller = controller,
        _getCurrentUrl = getCurrentUrl;

  InAppWebViewController? _controller;
  final String? Function() _getCurrentUrl;
  int _fetchCounter = 0;

  /// Cap concurrent binary XHRs through one WebView. Flooding the bridge
  /// with multi‑MB base64 payloads (4–8 workers × ~2 MB) causes mass
  /// timeouts on surrit-style CDNs.
  static const int _maxConcurrentBinaryFetches = 2;
  static int _activeBinaryFetches = 0;
  static final List<Completer<void>> _binaryFetchWaiters = [];

  static Future<void> _acquireBinarySlot() async {
    if (_activeBinaryFetches < _maxConcurrentBinaryFetches) {
      _activeBinaryFetches++;
      return;
    }
    final c = Completer<void>();
    _binaryFetchWaiters.add(c);
    await c.future;
    _activeBinaryFetches++;
  }

  static void _releaseBinarySlot() {
    _activeBinaryFetches = math.max(0, _activeBinaryFetches - 1);
    if (_binaryFetchWaiters.isNotEmpty) {
      _binaryFetchWaiters.removeAt(0).complete();
    }
  }

  /// Update the WebView controller. Called by
  /// [SnifferWebViewControllerImpl.onWebViewCreated] when the InAppWebView
  /// finishes creating its controller.
  void setController(InAppWebViewController? controller) {
    _controller = controller;
  }

  /// Fetches the playlist URL with fresh cookies and returns the highest
  /// bandwidth variant for a master playlist, or [url] as-is otherwise.
  Future<String?> fetchFreshPlaylistUrl(String url) async {
    try {
      final cookieJs = await _controller?.evaluateJavascript(
        source: "document.cookie||''",
      );
      final cookieStr = (cookieJs?.toString() ?? '').replaceAll('"', '');
      final client = http.Client();
      try {
        final resp = await client.get(
          Uri.parse(url),
          headers: {
            if (cookieStr.isNotEmpty) 'Cookie': cookieStr,
            'User-Agent': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36',
          },
        );
        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          if (url.toLowerCase().endsWith('.m3u8')) {
            final playlist = HlsPlaylistParser.parse(resp.body, Uri.parse(url));
            if (playlist.isMaster && playlist.variants.isNotEmpty) {
              final sorted = [...playlist.variants]
                ..sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
              return sorted.first.uri.toString();
            }
          }
          return url;
        }
      } finally {
        client.close();
      }
    } catch (_) {}
    return url;
  }

  /// Fetches a URL through the WebView's JS networking stack and returns
  /// the body text. Returns null on failure (timeout, network error, or
  /// non-2xx status). Used to bypass Cloudflare WAF for resources the
  /// browser cached but the Dart HTTP client cannot reach.
  Future<String?> fetchViaJavaScript(String url, {Map<String, String>? headers}) async {
    if (_controller == null) return null;
    try {
      final safeUrl = url.replaceAll("'", "\\'");
      // Unique channel name so concurrent calls don't collide.
      final channelName = 'FetchResponse_${DateTime.now().millisecondsSinceEpoch}_${_fetchCounter++}';

      final completer = Completer<String?>();
      // Register a one-shot JS handler.  Android WebView's evaluateJavascript
      // does NOT support Promise return values (it serialises the Promise
      // object as {}).  Instead we make an async XHR and pipe the result
      // back to Dart via callHandler.
      _controller!.addJavaScriptHandler(
        handlerName: channelName,
        callback: (args) {
          if (!completer.isCompleted && args.isNotEmpty) {
            completer.complete(args[0].toString());
          }
        },
      );

      // Trigger the async XHR through the WebView's networking stack.
      // We do NOT pass any custom headers: the browser automatically sets
      // User-Agent, Referer, Origin, Accept, Cookie, etc. based on the
      // page context and the WebView's TLS fingerprint. Setting headers
      // like Referer manually triggers a CORS preflight (OPTIONS) that
      // CDNs such as surrit.com do not handle → "network error".
      // withCredentials is omitted (defaults to false) because
      // surrit.com's CORS headers use Access-Control-Allow-Origin: *,
      // which is incompatible with credentialed requests.
      await _controller!.evaluateJavascript(source: '''
(function() {
  try {
    var xhr = new XMLHttpRequest();
    xhr.open('GET', '$safeUrl', true);
    xhr.onload = function() {
      // Accept 2xx and 3xx — matches fetchPlaylistBodyViaJavaScript.
      // Some CDNs return 302-followed bodies; others use 206 for partials.
      if (xhr.status >= 200 && xhr.status < 400) {
        window.flutter_inappwebview.callHandler('$channelName', 'OK:' + xhr.responseText);
      } else {
        window.flutter_inappwebview.callHandler('$channelName', 'ERROR:STATUS:' + xhr.status);
      }
    };
    xhr.onerror = function() {
      window.flutter_inappwebview.callHandler('$channelName', 'ERROR:EXCEPTION:network error');
    };
    xhr.send();
  } catch(e) {
    window.flutter_inappwebview.callHandler('$channelName', 'ERROR:EXCEPTION:' + (e.message || 'unknown'));
  }
})();
''');

      // Wait for the callback with a 20-second timeout.
      final result = await completer.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          debugPrint('fetchViaJavaScript timed out for $safeUrl');
          return null;
        },
      );

      // Clean up the one-shot handler.
      try { _controller!.removeJavaScriptHandler(handlerName: channelName); } catch (_) {}

      debugPrint('fetchViaJavaScript raw result: $result');
      if (result is String && result.startsWith('OK:')) {
        final body = result.substring(3);
        debugPrint('fetchViaJavaScript SUCCESS, body length=${body.length}');
        return body;
      }
      if (result is String) {
        debugPrint('fetchViaJavaScript failed: $result');
      }
      return null;
    } catch (e) {
      debugPrint('fetchViaJavaScript threw: $e');
      return null;
    }
  }

  /// Fetches response headers for [url] through the WebView's networking
  /// stack using an async XHR HEAD request. Returns a map of lowercased
  /// header names to values, including at minimum 'statusCode'. Returns
  /// null on failure (timeout, network error, or non-2xx status).
  /// The 'content-length' key is reliably populated for CORS-safelisted
  /// responses (Content-Length is always exposed cross-origin).
  Future<Map<String, String>?> fetchHeadersViaJavaScript(String url) async {
    if (_controller == null) return null;
    try {
      final safeUrl = url.replaceAll("'", "\\'");
      final channelName =
          'HeaderFetch_${DateTime.now().millisecondsSinceEpoch}_${_fetchCounter++}';

      final completer = Completer<Map<String, String>?>();
      _controller!.addJavaScriptHandler(
        handlerName: channelName,
        callback: (args) {
          if (!completer.isCompleted && args.isNotEmpty) {
            final result = args[0].toString();
            if (result.startsWith('OK:')) {
              final jsonStr = result.substring(3);
              try {
                final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
                // If we have content-range but no content-length, extract
                // the total size from "bytes 0-0/N". Some CDNs reply 206
                // Partial Content with Content-Range but no Content-Length.
                if (decoded['content-length'] == null ||
                    (decoded['content-length'] as String).isEmpty) {
                  final cr = decoded['content-range'] as String?;
                  if (cr != null && cr.isNotEmpty) {
                    final rangeMatch =
                        RegExp(r'bytes \d+-\d+/(\d+)').firstMatch(cr);
                    if (rangeMatch != null) {
                      decoded['content-length'] = rangeMatch.group(1);
                    }
                  }
                }
                completer.complete(
                  decoded.map((k, v) => MapEntry(k, v.toString())),
                );
              } catch (e) {
                debugPrint(
                  '[BrowserController] fetchHeadersViaJavaScript JSON decode failed: $e',
                );
                completer.complete(null);
              }
            } else {
              debugPrint(
                '[BrowserController] fetchHeadersViaJavaScript: result does not start with OK: $result',
              );
              completer.complete(null);
            }
          }
        },
      );

      await _controller!.evaluateJavascript(source: '''
(function() {
  try {
    var xhr = new XMLHttpRequest();
    xhr.open('HEAD', '$safeUrl', true);
    xhr.onload = function() {
      var headers = {};
      headers['statusCode'] = xhr.status.toString();
      if (xhr.status >= 200 && xhr.status < 400) {
        try {
          var cl = xhr.getResponseHeader('Content-Length');
          if (cl) headers['content-length'] = cl;
          var ct = xhr.getResponseHeader('Content-Type');
          if (ct) headers['content-type'] = ct;
        } catch(e) {}
        window.flutter_inappwebview.callHandler('$channelName', 'OK:' + JSON.stringify(headers));
      } else if (xhr.status === 405) {
        // HEAD not allowed — retry with Range: bytes=0-0 via GET
        var xhr2 = new XMLHttpRequest();
        xhr2.open('GET', '$safeUrl', true);
        xhr2.setRequestHeader('Range', 'bytes=0-0');
        xhr2.onload = function() {
          var h2 = {};
          h2['statusCode'] = xhr2.status.toString();
          if (xhr2.status >= 200 && xhr2.status < 400) {
            try {
              var cr = xhr2.getResponseHeader('Content-Range');
              if (cr) h2['content-range'] = cr;
              var cl2 = xhr2.getResponseHeader('Content-Length');
              if (cl2) h2['content-length'] = cl2;
              var ct2 = xhr2.getResponseHeader('Content-Type');
              if (ct2) h2['content-type'] = ct2;
            } catch(e) {}
          }
          window.flutter_inappwebview.callHandler('$channelName', 'OK:' + JSON.stringify(h2));
        };
        xhr2.onerror = function() {
          window.flutter_inappwebview.callHandler('$channelName', 'ERROR:EXCEPTION:HEAD 405 Range fallback failed');
        };
        xhr2.send();
      } else {
        window.flutter_inappwebview.callHandler('$channelName', 'ERROR:STATUS:' + xhr.status);
      }
    };
    xhr.onerror = function() {
      window.flutter_inappwebview.callHandler('$channelName', 'ERROR:EXCEPTION:HEAD failed');
    };
    xhr.send();
  } catch(e) {
    window.flutter_inappwebview.callHandler('$channelName', 'ERROR:EXCEPTION:' + (e.message || 'unknown'));
  }
})();
''');

      final result = await completer.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          debugPrint(
            '[BrowserController] fetchHeadersViaJavaScript timed out for $safeUrl',
          );
          return null;
        },
      );

      try {
        _controller!.removeJavaScriptHandler(handlerName: channelName);
      } catch (e) {
        debugPrint(
          '[BrowserController] fetchHeadersViaJavaScript handler removal failed: $e',
        );
      }

      return result;
    } catch (e) {
      debugPrint('fetchHeadersViaJavaScript threw: $e');
      return null;
    }
  }

  /// Fetches the full response body for [url] through the WebView's JS
  /// networking stack using a GET request. Returns the response text or
  /// null on failure. Used to fetch HLS playlist bodies that the browser
  /// cached but the Dart HTTP client cannot reach (Cloudflare WAF).
  Future<String?> fetchPlaylistBodyViaJavaScript(String url) async {
    if (_controller == null) return null;
    try {
      final safeUrl = url.replaceAll("'", "\\'");
      final channelName =
          'PlaylistBodyFetch_${DateTime.now().millisecondsSinceEpoch}_${_fetchCounter++}';

      final completer = Completer<String?>();
      _controller!.addJavaScriptHandler(
        handlerName: channelName,
        callback: (args) {
          if (!completer.isCompleted && args.isNotEmpty) {
            final result = args[0].toString();
            if (result.startsWith('OK:')) {
              completer.complete(result.substring(3));
            } else {
              completer.complete(null);
            }
          }
        },
      );

      await _controller!.evaluateJavascript(source: '''
(function() {
  try {
    var xhr = new XMLHttpRequest();
    xhr.open('GET', '$safeUrl', true);
    xhr.onload = function() {
      if (xhr.status >= 200 && xhr.status < 400) {
        window.flutter_inappwebview.callHandler('$channelName', 'OK:' + (xhr.responseText || ''));
      } else {
        window.flutter_inappwebview.callHandler('$channelName', 'ERROR:STATUS:' + xhr.status);
      }
    };
    xhr.onerror = function() {
      window.flutter_inappwebview.callHandler('$channelName', 'ERROR:NETWORK');
    };
    xhr.send();
  } catch(e) {
    window.flutter_inappwebview.callHandler('$channelName', 'ERROR:EXCEPTION:' + (e.message || 'unknown'));
  }
})();
''');

      final result = await completer.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          debugPrint(
            '[BrowserController] fetchPlaylistBodyViaJavaScript timed out for $safeUrl',
          );
          return null;
        },
      );

      try {
        _controller!.removeJavaScriptHandler(handlerName: channelName);
      } catch (_) {}

      if (result != null) {
        debugPrint(
          '[BrowserController] fetchPlaylistBodyViaJavaScript SUCCESS for $safeUrl (${result.length} chars)',
        );
      } else {
        debugPrint(
          '[BrowserController] fetchPlaylistBodyViaJavaScript FAILED for $safeUrl',
        );
      }
      return result;
    } catch (e) {
      debugPrint('fetchPlaylistBodyViaJavaScript threw: $e');
      return null;
    }
  }

  /// Fetches binary data (e.g. .ts / disguised .jpeg segments) through the
  /// WebView's networking stack. Returns null on failure.
  ///
  /// Uses `responseType: 'blob'` + FileReader (same as headless path) instead
  /// of a per-byte string loop — the old loop was O(n²) on multi‑MB segments
  /// and routinely blew the previous 6s timeout on surrit.com.
  /// Concurrent fetches are capped so the JS bridge is not flooded.
  Future<Uint8List?> fetchBinaryViaJavaScript(String url) async {
    if (_controller == null) return null;
    await _acquireBinarySlot();
    try {
      final safeUrl = url.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
      final channelName =
          'BinaryFetch_${DateTime.now().millisecondsSinceEpoch}_${_fetchCounter++}';

      final completer = Completer<Uint8List?>();
      _controller!.addJavaScriptHandler(
        handlerName: channelName,
        callback: (args) {
          if (!completer.isCompleted && args.isNotEmpty) {
            final result = args[0].toString();
            if (result.startsWith('OK:')) {
              try {
                final bytes = base64Decode(result.substring(3));
                completer.complete(Uint8List.fromList(bytes));
              } catch (_) {
                completer.complete(null);
              }
            } else {
              completer.complete(null);
            }
          }
        },
      );

      await _controller!.evaluateJavascript(source: '''
(function() {
  try {
    var xhr = new XMLHttpRequest();
    xhr.open('GET', '$safeUrl', true);
    xhr.responseType = 'blob';
    xhr.timeout = 40000;
    xhr.onload = function() {
      if (xhr.status >= 200 && xhr.status < 300 && xhr.response) {
        try {
          var reader = new FileReader();
          reader.onload = function() {
            try {
              var dataUrl = reader.result || '';
              var comma = dataUrl.indexOf(',');
              var b64 = comma >= 0 ? dataUrl.substring(comma + 1) : dataUrl;
              window.flutter_inappwebview.callHandler('$channelName', 'OK:' + b64);
            } catch (e) {
              try {
                window.flutter_inappwebview.callHandler('$channelName', 'ERROR:READER');
              } catch (e2) {}
            }
          };
          reader.onerror = function() {
            try {
              window.flutter_inappwebview.callHandler('$channelName', 'ERROR:READER');
            } catch (e) {}
          };
          reader.readAsDataURL(xhr.response);
        } catch (e) {
          try {
            window.flutter_inappwebview.callHandler('$channelName', 'ERROR:BLOB:' + (e.message || 'unknown'));
          } catch (e2) {}
        }
      } else {
        try {
          window.flutter_inappwebview.callHandler('$channelName', 'ERROR:STATUS:' + xhr.status);
        } catch (e) {}
      }
    };
    xhr.onerror = function() {
      try {
        window.flutter_inappwebview.callHandler('$channelName', 'ERROR:EXCEPTION:network error');
      } catch (e) {}
    };
    xhr.ontimeout = function() {
      try {
        window.flutter_inappwebview.callHandler('$channelName', 'ERROR:TIMEOUT');
      } catch (e) {}
    };
    xhr.send();
  } catch(e) {
    try {
      window.flutter_inappwebview.callHandler('$channelName', 'ERROR:EXCEPTION:' + (e.message || 'unknown'));
    } catch (e2) {}
  }
})();
''');

      // 45s: multi‑MB segments + FileReader base64 over the platform channel.
      final result = await completer.future.timeout(
        const Duration(seconds: 45),
        onTimeout: () {
          debugPrint('fetchBinaryViaJavaScript timed out for $safeUrl');
          return null;
        },
      );

      try {
        _controller!.removeJavaScriptHandler(handlerName: channelName);
      } catch (_) {}

      if (result != null) {
        debugPrint('fetchBinaryViaJavaScript SUCCESS, ${result.length} bytes');
      }
      return result;
    } catch (e) {
      debugPrint('fetchBinaryViaJavaScript threw: $e');
      return null;
    } finally {
      _releaseBinarySlot();
    }
  }

  /// Returns cookies for the given [url]. If [url] is null or empty, falls
  /// back to the current page URL.
  Future<Map<String, String>> getCookiesForDomain({String? url}) async {
    final effectiveUrl =
        (url != null && url.isNotEmpty) ? url : _getCurrentUrl();
    if (effectiveUrl == null || effectiveUrl.isEmpty) return {};
    final uri = Uri.tryParse(effectiveUrl);
    if (uri == null || !uri.hasScheme) return {};
    try {
      // Use the native cookie manager so HttpOnly cookies are included.
      // document.cookie evaluated via JS only returns non-HttpOnly cookies,
      // missing session tokens that many streaming sites protect with HttpOnly.
      final cookies = await CookieManager.instance().getCookies(
        url: WebUri.uri(uri),
      );
      if (cookies.isEmpty) return {};
      final map = <String, String>{};
      for (final c in cookies) {
        map[c.name] = c.value.toString();
      }
      // Build a single Cookie header value for the HTTP client.
      final cookieHeader = map.entries
          .map((e) => '${e.key}=${e.value}')
          .join('; ');
      return cookieHeader.isNotEmpty ? {'Cookie': cookieHeader} : {};
    } catch (_) {
      return {};
    }
  }
}

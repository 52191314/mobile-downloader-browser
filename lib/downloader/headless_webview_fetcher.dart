import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';


/// A fallback segment fetcher that uses a [HeadlessInAppWebView] to download
/// binary data from CDN hosts that block Dart's HTTP client (Cloudflare TLS
/// fingerprint detection) and block cross-origin XHR from the main WebView.
///
/// How it works:
/// 1. A headless (invisible) WebView is created and navigated to the CDN's
///    root domain (e.g. `https://surrit.com/`).
/// 2. The headless WebView passes Cloudflare's challenge using its real
///    Chrome TLS fingerprint and gets a `cf_clearance` cookie.
/// 3. Once loaded, same-origin XHR requests to segment URLs (e.g.
///    `https://surrit.com/.../video0.jpeg`) succeed because the headless
///    WebView is on the same origin — no CORS restriction.
/// 4. The headless WebView is kept alive for subsequent segment requests
///    to avoid re-navigating for every segment.
///
/// Concurrent XHRs are **serialized** (max 2 in flight). Flooding a single
/// headless WebView with parallel multi‑MB fetches caused mass timeouts on
/// surrit-style CDNs while speed sat at 0.
class HeadlessWebViewFetcher {
  HeadlessInAppWebView? _headless;
  InAppWebViewController? _controller;
  String? _originDomain;
  bool _isInitializing = false;
  Completer<void>? _initCompleter;

  /// Serialize multi‑MB XHRs so the headless bridge is not saturated.
  static const int _maxInFlight = 2;
  int _inFlight = 0;
  final List<Completer<void>> _waiters = [];

  Future<void> _acquire() async {
    if (_inFlight < _maxInFlight) {
      _inFlight++;
      return;
    }
    final c = Completer<void>();
    _waiters.add(c);
    await c.future;
    _inFlight++;
  }

  void _release() {
    _inFlight = _inFlight > 0 ? _inFlight - 1 : 0;
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    }
  }

  /// Fetches binary data from [url] using a headless WebView.
  /// Returns `null` if the fetch fails or if the headless WebView
  /// cannot be initialized.
  Future<Uint8List?> fetchBinary(String url) async {
    if (!Platform.isAndroid && !Platform.isIOS) return null;

    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return null;
    final origin = '${uri.scheme}://${uri.host}';

    await _acquire();
    try {
      // If the origin changed, we need a new headless WebView.
      if (_originDomain != null && _originDomain != origin) {
        await dispose();
      }

      // Initialize (or wait for existing initialization).
      if (_controller == null) {
        if (_isInitializing) {
          final waiting = _initCompleter;
          if (waiting != null) {
            await waiting.future.timeout(
              const Duration(seconds: 45),
              onTimeout: () {},
            );
          }
          if (_controller == null) return null;
        } else {
          _originDomain = origin;
          final ok = await _initialize(origin);
          if (!ok) return null;
        }
      }

      if (_controller == null) return null;

      return await _xhrFetchBinary(url);
    } catch (e) {
      debugPrint('HeadlessWebViewFetcher: XHR failed for $url: $e');
      return null;
    } finally {
      _release();
    }
  }

  /// Creates the headless WebView and navigates it to [origin].
  Future<bool> _initialize(String origin) async {
    _isInitializing = true;
    _initCompleter = Completer<void>();
    try {
      final completer = Completer<bool>();
      _headless = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(origin)),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          // Prefer a real mobile Chrome UA so CF challenge matches the app.
          userAgent:
              'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36',
        ),
        onLoadStop: (controller, url) {
          if (!completer.isCompleted) {
            completer.complete(true);
          }
        },
        onReceivedError: (controller, request, error) {
          // Only fail hard on main-frame errors during init.
          if (request.isForMainFrame == true && !completer.isCompleted) {
            debugPrint('HeadlessWebViewFetcher: load error for $origin: ${error.description}');
            completer.complete(false);
          }
        },
      );

      await _headless!.run();
      _controller = _headless!.webViewController;

      if (_controller == null) {
        _completeInit();
        return false;
      }

      // Wait for the page to load (Cloudflare challenge + redirect).
      final ok = await completer.future.timeout(
        const Duration(seconds: 45),
        onTimeout: () {
          debugPrint('HeadlessWebViewFetcher: timeout loading $origin');
          return false;
        },
      );

      // Brief settle so CF set-cookie + any secondary redirects finish.
      if (ok) {
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }

      _completeInit();
      if (ok) {
        debugPrint('HeadlessWebViewFetcher: initialized for $origin');
      }
      return ok;
    } catch (e) {
      debugPrint('HeadlessWebViewFetcher: init failed for $origin: $e');
      _completeInit();
      return false;
    } finally {
      _isInitializing = false;
    }
  }

  void _completeInit() {
    final c = _initCompleter;
    if (c != null && !c.isCompleted) c.complete();
  }

  /// Makes a same-origin XHR from the headless WebView to fetch binary data.
  Future<Uint8List?> _xhrFetchBinary(String url) async {
    if (_controller == null) return null;
    final safeUrl = url.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
    final channelName =
        'HeadlessFetch_${DateTime.now().microsecondsSinceEpoch}';

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
            } catch(e) {
              try {
                window.flutter_inappwebview.callHandler('$channelName', 'ERROR:READER');
              } catch(e2) {}
            }
          };
          reader.onerror = function() {
            try {
              window.flutter_inappwebview.callHandler('$channelName', 'ERROR:READER');
            } catch(e) {}
          };
          reader.readAsDataURL(xhr.response);
        } catch(e) {
          try {
            window.flutter_inappwebview.callHandler('$channelName', 'ERROR:BLOB:' + (e.message || 'unknown'));
          } catch(e2) {}
        }
      } else {
        try {
          window.flutter_inappwebview.callHandler('$channelName', 'ERROR:STATUS:' + xhr.status);
        } catch(e) {}
      }
    };
    xhr.onerror = function() {
      try {
        window.flutter_inappwebview.callHandler('$channelName', 'ERROR:NETWORK');
      } catch(e) {}
    };
    xhr.ontimeout = function() {
      try {
        window.flutter_inappwebview.callHandler('$channelName', 'ERROR:TIMEOUT');
      } catch(e) {}
    };
    xhr.send();
  } catch(e) {
    try {
      window.flutter_inappwebview.callHandler('$channelName', 'ERROR:EXCEPTION:' + (e.message || 'unknown'));
    } catch(e2) {}
  }
})();
''');

    final result = await completer.future.timeout(
      const Duration(seconds: 50),
      onTimeout: () {
        debugPrint('HeadlessWebViewFetcher: XHR timed out for $url');
        return null;
      },
    );

    try {
      _controller?.removeJavaScriptHandler(handlerName: channelName);
    } catch (_) {}

    return result;
  }

  /// Fetches text data (e.g. an HLS playlist body) from [url] using
  /// a headless WebView. Uses same-origin XHR from the CDN's domain,
  /// bypassing both CORS (same origin) and Cloudflare WAF (real Chrome
  /// TLS fingerprint + cf_clearance cookie). Returns null on failure.
  Future<String?> fetchText(String url) async {
    if (!Platform.isAndroid && !Platform.isIOS) return null;

    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return null;
    final origin = '${uri.scheme}://${uri.host}';

    await _acquire();
    try {
      if (_originDomain != null && _originDomain != origin) {
        await dispose();
      }

      if (_controller == null) {
        if (_isInitializing) {
          final waiting = _initCompleter;
          if (waiting != null) {
            await waiting.future.timeout(
              const Duration(seconds: 45),
              onTimeout: () {},
            );
          }
          if (_controller == null) return null;
        } else {
          _originDomain = origin;
          final ok = await _initialize(origin);
          if (!ok) return null;
        }
      }

      if (_controller == null) return null;

      return await _xhrFetchText(url);
    } catch (e) {
      debugPrint('HeadlessWebViewFetcher: XHR text fetch failed for $url: $e');
      return null;
    } finally {
      _release();
    }
  }

  /// Same-origin XHR from the headless WebView to fetch [url] as text.
  Future<String?> _xhrFetchText(String url) async {
    if (_controller == null) return null;
    final safeUrl = url.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
    final channelName =
        'HeadlessTextFetch_${DateTime.now().microsecondsSinceEpoch}';

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
    xhr.responseType = 'text';
    xhr.timeout = 30000;
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
    xhr.ontimeout = function() {
      window.flutter_inappwebview.callHandler('$channelName', 'ERROR:TIMEOUT');
    };
    xhr.send();
  } catch(e) {
    window.flutter_inappwebview.callHandler('$channelName', 'ERROR:EXCEPTION:' + (e.message || 'unknown'));
  }
})();
''');

    final result = await completer.future.timeout(
      const Duration(seconds: 35),
      onTimeout: () {
        debugPrint('HeadlessWebViewFetcher: text XHR timed out for $url');
        return null;
      },
    );

    try {
      _controller?.removeJavaScriptHandler(handlerName: channelName);
    } catch (_) {}

    return result;
  }

  /// Disposes the headless WebView and releases resources.
  Future<void> dispose() async {
    try {
      await _headless?.dispose();
    } catch (_) {}
    _headless = null;
    _controller = null;
    _originDomain = null;
    _isInitializing = false;
    // Allow a fresh completer on next init.
    if (_initCompleter != null && !_initCompleter!.isCompleted) {
      _initCompleter!.complete();
    }
    _initCompleter = null;
  }
}

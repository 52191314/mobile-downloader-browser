import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../logging/aurora_log.dart';

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
class HeadlessWebViewFetcher {
  HeadlessInAppWebView? _headless;
  InAppWebViewController? _controller;
  String? _originDomain;
  bool _isInitializing = false;
  final Completer<void> _initCompleter = Completer<void>();

  /// Fetches binary data from [url] using a headless WebView.
  /// Returns `null` if the fetch fails or if the headless WebView
  /// cannot be initialized.
  Future<Uint8List?> fetchBinary(String url) async {
    if (!Platform.isAndroid && !Platform.isIOS) return null;

    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return null;
    final origin = '${uri.scheme}://${uri.host}';

    // If the origin changed, we need a new headless WebView.
    if (_originDomain != null && _originDomain != origin) {
      await dispose();
    }

    // Initialize (or wait for existing initialization).
    if (_controller == null) {
      if (_isInitializing) {
        await _initCompleter.future.timeout(
          const Duration(seconds: 30),
          onTimeout: () => null,
        );
        if (_controller == null) return null;
      } else {
        _originDomain = origin;
        final ok = await _initialize(origin);
        if (!ok) return null;
      }
    }

    if (_controller == null) return null;

    // Make a same-origin XHR to fetch the binary data.
    try {
      final data = await _xhrFetchBinary(url);
      return data;
    } catch (e) {
      AuroraLog.instance.debug(
        'HeadlessWebViewFetcher: XHR failed for $url: $e',
        category: LogCategory.hls,
        screen: LogScreen.background,
        eventType: LogEventType.network,
      );
      return null;
    }
  }

  /// Creates the headless WebView and navigates it to [origin].
  Future<bool> _initialize(String origin) async {
    _isInitializing = true;
    try {
      final completer = Completer<bool>();
      _headless = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(origin)),
        onLoadStop: (controller, url) {
          if (!completer.isCompleted) {
            completer.complete(true);
          }
        },
        onReceivedError: (controller, request, error) {
          if (!completer.isCompleted) {
            AuroraLog.instance.debug(
              'HeadlessWebViewFetcher: load error for $origin: ${error.description}',
              category: LogCategory.hls,
              screen: LogScreen.background,
              eventType: LogEventType.network,
            );
            completer.complete(false);
          }
        },
      );

      await _headless!.run();
      _controller = _headless!.webViewController;

      if (_controller == null) {
        if (!_initCompleter.isCompleted) _initCompleter.complete();
        return false;
      }

      // Wait for the page to load (Cloudflare challenge + redirect).
      final ok = await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          AuroraLog.instance.debug(
            'HeadlessWebViewFetcher: timeout loading $origin',
            category: LogCategory.hls,
            screen: LogScreen.background,
            eventType: LogEventType.network,
          );
          return false;
        },
      );

      if (!_initCompleter.isCompleted) _initCompleter.complete();
      if (ok) {
        AuroraLog.instance.debug(
          'HeadlessWebViewFetcher: initialized for $origin',
          category: LogCategory.hls,
          screen: LogScreen.background,
          eventType: LogEventType.network,
        );
      }
      return ok;
    } catch (e) {
      AuroraLog.instance.debug(
        'HeadlessWebViewFetcher: init failed for $origin: $e',
        category: LogCategory.hls,
        screen: LogScreen.background,
        eventType: LogEventType.network,
      );
      if (!_initCompleter.isCompleted) _initCompleter.complete();
      return false;
    } finally {
      _isInitializing = false;
    }
  }

  /// Makes a same-origin XHR from the headless WebView to fetch binary data.
  Future<Uint8List?> _xhrFetchBinary(String url) async {
    if (_controller == null) return null;
    final safeUrl = url.replaceAll("'", "\\'");
    final channelName =
        'HeadlessFetch_${DateTime.now().millisecondsSinceEpoch}';

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
    xhr.onload = function() {
      if (xhr.status >= 200 && xhr.status < 300) {
        try {
          var reader = new FileReader();
          reader.onload = function() {
            try {
              var dataUrl = reader.result;
              var b64 = dataUrl.substring(dataUrl.indexOf(',') + 1);
              window.flutter_inappwebview.callHandler('$channelName', 'OK:' + b64);
            } catch(e) {}
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
    xhr.timeout = 20000;
    xhr.send();
  } catch(e) {
    try {
      window.flutter_inappwebview.callHandler('$channelName', 'ERROR:EXCEPTION:' + (e.message || 'unknown'));
    } catch(e2) {}
  }
})();
''');

    final result = await completer.future.timeout(
      const Duration(seconds: 25),
      onTimeout: () {
        AuroraLog.instance.debug(
          'HeadlessWebViewFetcher: XHR timed out for $url',
          category: LogCategory.hls,
          screen: LogScreen.background,
          eventType: LogEventType.network,
        );
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
  ///
  /// Mirrors [fetchBinary] but with `responseType: 'text'` so the result
  /// is a raw string rather than base64-decoded bytes.
  Future<String?> fetchText(String url) async {
    if (!Platform.isAndroid && !Platform.isIOS) return null;

    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return null;
    final origin = '${uri.scheme}://${uri.host}';

    // If the origin changed, we need a new headless WebView.
    if (_originDomain != null && _originDomain != origin) {
      await dispose();
    }

    // Initialize (or wait for existing initialization).
    if (_controller == null) {
      if (_isInitializing) {
        await _initCompleter.future.timeout(
          const Duration(seconds: 30),
          onTimeout: () => null,
        );
        if (_controller == null) return null;
      } else {
        _originDomain = origin;
        final ok = await _initialize(origin);
        if (!ok) return null;
      }
    }

    if (_controller == null) return null;

    try {
      final data = await _xhrFetchText(url);
      return data;
    } catch (e) {
      AuroraLog.instance.debug(
        'HeadlessWebViewFetcher: XHR text fetch failed for $url: $e',
        category: LogCategory.hls,
        screen: LogScreen.background,
        eventType: LogEventType.network,
      );
      return null;
    }
  }

  /// Same-origin XHR from the headless WebView to fetch [url] as text.
  Future<String?> _xhrFetchText(String url) async {
    if (_controller == null) return null;
    final safeUrl = url.replaceAll("'", "\\'");
    final channelName =
        'HeadlessTextFetch_${DateTime.now().millisecondsSinceEpoch}';

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
    xhr.timeout = 20000;
    xhr.send();
  } catch(e) {
    window.flutter_inappwebview.callHandler('$channelName', 'ERROR:EXCEPTION:' + (e.message || 'unknown'));
  }
})();
''');

    final result = await completer.future.timeout(
      const Duration(seconds: 25),
      onTimeout: () {
        AuroraLog.instance.debug(
          'HeadlessWebViewFetcher: text XHR timed out for $url',
          category: LogCategory.hls,
          screen: LogScreen.background,
          eventType: LogEventType.network,
        );
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
  }
}

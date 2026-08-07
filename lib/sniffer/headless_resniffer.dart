import 'dart:async';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// DOM query JS that mirrors [_queryHlsFromPage] in `sniffer_screen.dart`:
/// finds the first non-ping `.m3u8` URL in <source>, <video>/<audio>, or
/// inline <script> text.
const String _kHlsDomQueryJs = '''
(() => {
  function findHls(root) {
    if (!root || !root.querySelectorAll) return '';
    const sources = root.querySelectorAll('source[src]');
    for (const s of sources) {
      const src = s.src || s.getAttribute('src') || '';
      if (src && src.indexOf('.m3u8') !== -1 && src.indexOf('ping.m3u8') === -1 && src.indexOf('/ping') === -1) return src;
    }
    const medias = root.querySelectorAll('video, audio');
    for (const m of medias) {
      const src = m.currentSrc || m.src || '';
      if (src && src.indexOf('.m3u8') !== -1 && src.indexOf('ping.m3u8') === -1 && src.indexOf('/ping') === -1) return src;
    }
    const scripts = root.querySelectorAll('script');
    for (const sc of scripts) {
      const text = sc.textContent || '';
      const match = text.match(/https?:\\/\\/[^"\\\\s]+\\.m3u8[^"\\\\s]*/);
      if (match) {
        const u = match[0];
        if (u.indexOf('ping.m3u8') === -1 && u.indexOf('/ping') === -1) return u;
      }
    }
    return '';
  }
  const r = findHls(document);
  if (r) return r;
  const iframes = document.querySelectorAll('iframe');
  for (const f of iframes) {
    try { const fr = f.contentDocument; if (fr) { const ir = findHls(fr); if (ir) return ir; } } catch (_) {}
  }
  return '';
})();
''';

/// A single-use headless page loader that navigates to a source page,
/// waits for the page to render, then queries the DOM for a fresh HLS
/// playlist URL (identical to [_queryHlsFromPage] but without a visible
/// [BrowserTab]).
///
/// Created by [HeadlessPageResniffer.resniff] and disposed automatically
/// after the first result or timeout.  The caller must NOT reuse the
/// instance.
///
/// ## Why this exists
///
/// `_reloadForFreshUrl` (in `sniffer_screen.dart`) previously called
/// `tab.controller.loadRequest()` on a **visible** browser tab, hijacking
/// whatever the user was watching.  This component runs the same DOM query
/// in a **headless** WebView — the user never sees the page load.
class HeadlessPageResniffer {
  HeadlessInAppWebView? _headless;
  InAppWebViewController? _controller;
  bool _isDisposed = false;

  static const Duration _pageLoadTimeout = Duration(seconds: 15);
  static const Duration _jsGracePeriod = Duration(seconds: 3);
  static const Duration _resourcePollDelay = Duration(seconds: 1);

  /// Loads [sourcePageUrl] in a headless HeadlessInAppWebView, waits for
  /// the page to render, queries the DOM for a playlist URL, and returns
  /// it (or null if nothing was found).
  ///
  /// If [mustMatchPathOf] is provided, the returned URL's path must match
  /// that of the given URL (query may differ — that's the token).  This
  /// prevents picking up a completely unrelated stream from the same page.
  Future<String?> resniff(
    String sourcePageUrl, {
    String? mustMatchPathOf,
  }) async {
    if (!Platform.isAndroid && !Platform.isIOS) return null;
    if (_isDisposed) return null;
    if (!sourcePageUrl.startsWith('http')) return null;

    final loadCompleter = Completer<bool>();

    try {
      _headless = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(sourcePageUrl)),
        initialSettings: InAppWebViewSettings(
          incognito: true,
          javaScriptEnabled: true,
          domStorageEnabled: true,
          databaseEnabled: true,
          mediaPlaybackRequiresUserGesture: false,
          useShouldOverrideUrlLoading: true,
          useOnLoadResource: false,
          useShouldInterceptRequest: true,
        ),
        onLoadStop: (controller, url) {
          if (!loadCompleter.isCompleted) {
            loadCompleter.complete(true);
          }
        },
        onReceivedError: (controller, request, error) {
          if (request.isForMainFrame == true && !loadCompleter.isCompleted) {
            loadCompleter.complete(false);
          }
        },
      );
      await _headless!.run();
      _controller = _headless!.webViewController;
      if (_controller == null) return null;

      // Wait for the page to load.
      final ok = await loadCompleter.future.timeout(_pageLoadTimeout);
      if (_isDisposed || !ok) return null;

      // Give JS time to execute and the player to initialise.
      await Future<void>.delayed(_jsGracePeriod);
      if (_isDisposed) return null;

      // Query the DOM for an .m3u8 URL (same JS as _queryHlsFromPage).
      final fromDom = await _queryDom();
      if (fromDom != null) {
        return _validateResult(fromDom, mustMatchPathOf);
      }

      // Fallback: poll performance entries for fetch-based media loads.
      await Future<void>.delayed(_resourcePollDelay);
      if (_isDisposed) return null;
      final fromPerf = await _queryPerformanceEntries();
      if (fromPerf != null) {
        return _validateResult(fromPerf, mustMatchPathOf);
      }

      return null;
    } catch (_) {
      return null;
    } finally {
      await dispose();
    }
  }

  /// Runs the same DOM query JS used by [_queryHlsFromPage] in
  /// `sniffer_screen.dart`.
  Future<String?> _queryDom() async {
    final ctrl = _controller;
    if (ctrl == null) return null;
    try {
      final result = await ctrl.evaluateJavascript(source: _kHlsDomQueryJs);
      if (result is String &&
          result.isNotEmpty &&
          result.contains('.m3u8') &&
          !result.contains('ping.m3u8') &&
          !result.contains('/ping')) {
        return result;
      }
    } catch (_) {}
    return null;
  }

  /// Polls `performance.getEntriesByType('resource')` for .m3u8 / .mpd
  /// URLs — catches players that fetch playlists via XHR/fetch rather
  /// than setting them as DOM element src.
  Future<String?> _queryPerformanceEntries() async {
    final ctrl = _controller;
    if (ctrl == null) return null;
    try {
      final result = await ctrl.evaluateJavascript(source: '''
        (() => {
          try {
            const entries = performance.getEntriesByType('resource');
            for (const e of entries) {
              const u = e.name;
              if ((u.indexOf('.m3u8') !== -1 || u.indexOf('.mpd') !== -1) &&
                  u.indexOf('ping.m3u8') === -1 &&
                  u.indexOf('/ping') === -1) {
                return u;
              }
            }
          } catch(e) {}
          return '';
        })()
      ''');
      if (result is String &&
          result.isNotEmpty &&
          result.contains('.m3u8')) {
        return result;
      }
    } catch (_) {}
    return null;
  }

  /// Validates the result against [mustMatchPathOf] if provided.
  String? _validateResult(String url, String? mustMatchPathOf) {
    if (mustMatchPathOf == null) return url;
    final fresh = Uri.tryParse(url);
    final stale = Uri.tryParse(mustMatchPathOf);
    if (fresh == null || stale == null) return null;
    // Path must match; query may differ (that's the token refresh).
    return fresh.path == stale.path ? url : null;
  }

  /// Disposes the headless WebView. Idempotent. Called automatically
  /// in [resniff]'s `finally` block.
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    _controller = null;
    try {
      await _headless?.dispose();
    } catch (_) {}
    _headless = null;
  }
}

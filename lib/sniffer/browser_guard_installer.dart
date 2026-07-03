import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Installs the JS guard script in the WebView and periodically refreshes
/// the hooks to catch overwrites by page JS.
///
/// The single injected script (in `assets/browser_guard.js`) does all of
/// the following:
///
/// * Scans the DOM for `video`, `audio`, `a[href]`, `img[src]`, `source[src]`.
/// * Intercepts the `HTMLMediaElement.prototype.src` setter.
/// * Listens for `loadedmetadata`.
/// * Wraps `fetch` and `XMLHttpRequest` to capture media requests.
/// * Sets up a `MutationObserver` for dynamic DOM changes.
///
/// This class also runs a 20-second refresh timer that re-injects the
/// guard (with `force: true`) so that overwrites by page JS after
/// `onLoadStop` are caught. The expensive DOM scan and observer setup
/// flags are preserved by the JS script, so only the fetch/XHR/src
/// function wrappers are re-applied.
class BrowserGuardInstaller {
  BrowserGuardInstaller({required InAppWebViewController? controller})
      : _controller = controller {
    // Eagerly start loading the guard script so it's cached and ready
    // by the time the first WebView is created.  Without this, the
    // first WebView's `onWebViewCreated` callback would have to wait
    // for the async file read before the user script can be added.
    _loadGuardScript();
  }

  InAppWebViewController? _controller;
  bool _guardInstalled = false;
  bool _userScriptAdded = false;
  Timer? _guardRefreshTimer;

  /// Update the WebView controller. Called by
  /// [SnifferWebViewControllerImpl.onWebViewCreated] when the InAppWebView
  /// finishes creating its controller.
  void setController(InAppWebViewController? controller) {
    _controller = controller;
  }

  /// Public entry point used to (re-)install the guard. The [force] flag
  /// forces a re-injection even if the guard was previously installed.
  /// When `force` is false the guard is only installed once per page load.
  /// The implementation delegates to [_installBrowserGuards].
  Future<void> installBrowserGuards({bool force = false}) async {
    await _installBrowserGuards(force: force);
  }

  /// Installs the guard as a WebView user script that runs at document
  /// start, BEFORE any page JavaScript executes.  This ensures the
  /// fetch/XHR/PerformanceObserver hooks are in place when the page's
  /// HLS player (e.g. hls.js) first fires a playlist request.  Without
  /// this, `evaluateJavascript` in `onLoadStart` can race with the
  /// page's own `<script>` tags and the guard may not be installed in
  /// time to catch the first fetch.
  ///
  /// Only adds the script once per WebView (idempotent).  Subsequent
  /// navigations within the same WebView reuse the registered script.
  Future<void> installAsUserScript() async {
    if (_userScriptAdded) return;
    final controller = _controller;
    if (controller == null) return;
    try {
      final script = await _loadGuardScript();
      await controller.addUserScript(
        userScript: UserScript(
          source: script,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          groupName: 'aurora_guard',
        ),
      );
      _userScriptAdded = true;
    } catch (_) {}
  }

  Future<void> _installBrowserGuards({bool force = false}) async {
    if (_controller == null) return;
    if (!force && _guardInstalled) return;
    if (force) {
      _guardInstalled = false;
      // Reset only the version counter so hooks are re-wrapped.
      // Do NOT reset __auroraHtmlScanned — the initial DOM scan is expensive
      // and only needed once per navigation. __auroraPerformanceObserverActive
      // and __auroraObserverActive are also preserved by browser_guard.js
      // so they skip re-setup on force-reinject.
      await _controller!
          .evaluateJavascript(
            source: 'window.__auroraGuardVersion = 0;',
          )
          .catchError((_) {});
    }
    final guardScript = await _loadGuardScript();
    await _controller!
        .evaluateJavascript(source: guardScript)
        .catchError((_) {});
    _guardInstalled = true;
    _startGuardRefreshTimer();
  }

  /// Periodically re-injects the guard hooks so that overwrites by page JS
  /// (e.g. a site redefining `window.fetch` or `XMLHttpRequest.prototype.open`
  /// after onLoadStop) are caught. Uses `force: true` but the expensive DOM
  /// scan and observer setup flags are preserved, so only the fetch/XHR/src
  /// function wrappers are re-applied.
  void _startGuardRefreshTimer() {
    _guardRefreshTimer?.cancel();
    _guardRefreshTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => _installBrowserGuards(force: true),
    );
  }

  // JS shim + guard script lives in assets/browser_guard.js so it can be
  // syntax-checked and edited as JavaScript instead of as a Dart string.
  static Future<String>? _guardScriptFuture;

  static Future<String> _loadGuardScript() {
    return _guardScriptFuture ??= rootBundle.loadString(
      'assets/browser_guard.js',
    );
  }

  /// Cancel the refresh timer. Called by
  /// [SnifferWebViewControllerImpl.dispose].
  void dispose() {
    _guardRefreshTimer?.cancel();
  }
}

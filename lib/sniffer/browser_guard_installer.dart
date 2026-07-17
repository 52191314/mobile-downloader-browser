import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Installs the JS guard script in the WebView and provides a way to
/// re-inject it on demand (e.g. from `onLoadStop` or a manual button).
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
/// The guard is installed as a user script (`AT_DOCUMENT_START`) once per
/// WebView, which guarantees it runs before any page JS. A force re-injection
/// via [installBrowserGuards] (called from `onLoadStop` or a manual button)
/// re-applies the fetch/XHR/src wrappers and optionally re-scans the DOM.
/// No periodic refresh timer exists — [installAsUserScript] + `onLoadStop`
/// force-injection cover normal navigation, and the manual "Re-scan" button
/// handles rare cases where page JS overwrites hooks after `onLoadStop`.
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
          // All frames: ad iframes use window.open / top navigations that
          // never hit the main-frame-only guard.
          forMainFrameOnly: false,
          groupName: 'aurora_guard',
        ),
      );
      _userScriptAdded = true;
    } catch (_) {}
  }

  Future<void> _installBrowserGuards({bool force = false}) async {
    if (_controller == null) return;
    // Document-start user script covers first paint; force re-inject still
    // re-wraps hooks if page JS tore them down after load (SPA / anti-adblock).
    if (!force && (_guardInstalled || _userScriptAdded)) return;
    if (force) {
      _guardInstalled = false;
      // Reset only the version counter so hooks are re-wrapped.
      // Do NOT reset __auroraHtmlScanned during normal force-reinject
      // (onLoadStop) — the initial DOM scan is expensive and only needed
      // once per navigation.  Use [rescanPage] for a full re-scan.
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
  }

  /// Full page re-scan: resets the DOM-scan flag so [installBrowserGuards]
  /// re-scans the page's `<video>`, `<audio>`, `<a>` and related elements
  /// in addition to re-wrapping fetch/XHR/src hooks.
  ///
  /// Called from the manual "Re-scan" button in the browser menu.  This is
  /// the only path that resets `__auroraHtmlScanned`.
  Future<void> rescanPage() async {
    final controller = _controller;
    if (controller == null) return;
    await controller
        .evaluateJavascript(
          source:
              'window.__auroraHtmlScanned = false; window.__auroraGuardVersion = 0;',
        )
        .catchError((_) {});
    await _installBrowserGuards(force: true);
  }

  // JS shim + guard script lives in assets/browser_guard.js so it can be
  // syntax-checked and edited as JavaScript instead of as a Dart string.
  static Future<String>? _guardScriptFuture;

  static Future<String> _loadGuardScript() {
    return _guardScriptFuture ??= rootBundle.loadString(
      'assets/browser_guard.js',
    );
  }

  /// No-op — kept for backward compatibility. The refresh timer was removed
  /// in favor of `onLoadStop` force-injection + a manual button.
  void dispose() {
    // Nothing to dispose — no periodic timer.
  }
}

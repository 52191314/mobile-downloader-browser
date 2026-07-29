import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'ad_block_engine_native.dart';

/// Injects cosmetic filtering JS and scriptlet engine into the WebView
/// at document_start. On each page load, evaluates per-domain cosmetic CSS
/// and scriptlet invocations based on the current engine's filter rules.
class AdblockInjector {
  AdblockInjector({
    required InAppWebViewController? controller,
    required AdBlockEngine engine,
  })  : _controller = controller,
        _engine = engine {
    _loadScripts();
  }

  InAppWebViewController? _controller;
  AdBlockEngine _engine;
  bool _userScriptsAdded = false;

  static Future<String>? _cosmeticScriptFuture;
  static Future<String>? _scriptletScriptFuture;

  /// Update the WebView controller. Called by
  /// [SnifferWebViewControllerImpl.onWebViewCreated].
  void setController(InAppWebViewController? controller) {
    _controller = controller;
    _userScriptsAdded = false;
  }

  /// Update the engine reference. Called by
  /// [SnifferWebViewControllerImpl.configureAdBlock] after the engine is
  /// rebuilt with the user's filter sources.
  void setEngine(AdBlockEngine engine) {
    _engine = engine;
  }

  Future<void> installAsUserScript() async {
    if (_userScriptsAdded) return;
    final controller = _controller;
    if (controller == null) return;
    try {
      final cosmeticScript = await _loadCosmeticScript();
      final scriptletScript = await _loadScriptletScript();

      await controller.addUserScript(
        userScript: UserScript(
          source: cosmeticScript,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          groupName: 'aurora_adblock',
        ),
      );

      await controller.addUserScript(
        userScript: UserScript(
          source: scriptletScript,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          groupName: 'aurora_adblock',
        ),
      );

      // Generic (hostless) cosmetic rules are the bulk of EasyList. They never
      // vary by page, so they ship once as a user script instead of crossing
      // the platform channel on every navigation.
      final genericCss = _engine.getGenericCosmeticCss();
      if (genericCss.isNotEmpty) {
        final escaped = _escapeForJsSingleQuotes(genericCss);
        await controller.addUserScript(
          userScript: UserScript(
            source: '''
(function() {
  var css = '$escaped';
  function apply() {
    if (!document.documentElement) return false;
    var style = document.createElement('style');
    style.setAttribute('data-aurora-adblock', 'generic');
    style.textContent = css;
    (document.head || document.documentElement).appendChild(style);
    return true;
  }
  if (!apply()) {
    document.addEventListener('DOMContentLoaded', apply, { once: true });
  }
})();
''',
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
            groupName: 'aurora_adblock',
          ),
        );
      }

      _userScriptsAdded = true;
    } catch (_) {}
  }

  /// Inject per-page adblock config. Call this on onLoadStart for each page.
  Future<void> injectForPage(String pageUrl) async {
    final controller = _controller;
    if (controller == null) return;

    final host = Uri.tryParse(pageUrl)?.host ?? '';
    if (host.isEmpty) return;

    // Host-specific cosmetic CSS. Generic rules are already in place via the
    // document_start user script installed by [installAsUserScript].
    final cosmeticCss = _engine.getCosmeticCssForHost(host);
    if (cosmeticCss.isNotEmpty) {
      final escapedCss = _escapeForJsSingleQuotes(cosmeticCss);
      await controller
          .evaluateJavascript(
            source: '''
(function() {
  window.__auroraCosmeticConfig = { css: '$escapedCss' };
  if (window.__auroraSetCosmeticCss) {
    window.__auroraSetCosmeticCss('$escapedCss');
  }
})();
''',
          )
          .catchError((_) {});
    }

    // Scriptlet rules — batched into a single evaluateJavascript call
    // instead of one per rule, so a page with 10+ scriptlets only pays
    // one platform-channel round-trip instead of 10+.
    final scriptlets = _engine.getScriptletsForHost(host);
    if (scriptlets.isNotEmpty) {
      final buffer = StringBuffer();
      for (final rule in scriptlets) {
        final escapedName = rule.name.replaceAll("'", "\\'");
        final argsStr = rule.args
            .map((a) => "'${a.replaceAll("'", "\\'")}'")
            .join(', ');
        buffer.writeln(
          "window.__auroraScriptlets?.invoke('$escapedName', [$argsStr]);",
        );
      }
      await controller
          .evaluateJavascript(source: buffer.toString())
          .catchError((_) {});
    }
  }

  /// Escapes CSS for embedding inside a single-quoted JS string literal.
  /// Carriage returns matter too: a bare CR inside a JS string is a syntax
  /// error, and filter lists fetched over HTTP often carry CRLF line endings.
  static String _escapeForJsSingleQuotes(String value) {
    return value
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "\\'")
        .replaceAll('\r', '\\r')
        .replaceAll('\n', '\\n');
  }

  static Future<String> _loadCosmeticScript() {
    return _cosmeticScriptFuture ??=
        rootBundle.loadString('assets/adblock_cosmetic.js');
  }

  static Future<String> _loadScriptletScript() {
    return _scriptletScriptFuture ??=
        rootBundle.loadString('assets/scriptlets.js');
  }

  /// Eagerly start loading both scripts so they're cached and ready
  /// by the time the first WebView is created. This mirrors the pattern
  /// used by [BrowserGuardInstaller].
  void _loadScripts() {
    _loadCosmeticScript();
    _loadScriptletScript();
  }

  void dispose() {
    _userScriptsAdded = false;
  }
}

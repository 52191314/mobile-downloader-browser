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

      _userScriptsAdded = true;
    } catch (_) {}
  }

  /// Inject per-page adblock config. Call this on onLoadStart for each page.
  Future<void> injectForPage(String pageUrl) async {
    final controller = _controller;
    if (controller == null) return;

    final host = Uri.tryParse(pageUrl)?.host ?? '';
    if (host.isEmpty) return;

    // Cosmetic CSS
    final cosmeticCss = _engine.getCosmeticCssForHost(host);
    if (cosmeticCss.isNotEmpty) {
      final escapedCss = cosmeticCss
          .replaceAll('\\', '\\\\')
          .replaceAll("'", "\\'")
          .replaceAll('\n', '\\n');
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

    // Scriptlet rules
    final scriptlets = _engine.getScriptletsForHost(host);
    if (scriptlets.isNotEmpty) {
      for (final rule in scriptlets) {
        final escapedName = rule.name.replaceAll("'", "\\'");
        final argsStr = rule.args
            .map((a) => "'${a.replaceAll("'", "\\'")}'")
            .join(', ');
        await controller
            .evaluateJavascript(
              source:
                  "window.__auroraScriptlets?.invoke('$escapedName', [$argsStr]);",
            )
            .catchError((_) {});
      }
    }
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

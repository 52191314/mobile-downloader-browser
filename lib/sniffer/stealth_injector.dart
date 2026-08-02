import 'dart:async';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'stealth_metadata_channel.dart';
import 'sniffer_url_utils.dart';

/// Installs a document-start stealth UserScript to bypass Cloudflare Turnstile
/// and bot-detection heuristics in Android WebViews.
class StealthInjector {
  StealthInjector({required InAppWebViewController? controller})
      : _controller = controller;

  InAppWebViewController? _controller;
  bool _userScriptAdded = false;

  static String _buildStealthJs() {
    final fullVersion = StealthMetadataChannel.extractFullChromeVersion(
          systemUserAgent,
        ) ??
        '131.0.6778.135';
    final majorVersion = StealthMetadataChannel.extractChromeVersion(
          systemUserAgent,
        ) ??
        '131';
    return '''
(function() {
  try {
    // 1. Mask navigator.webdriver
    Object.defineProperty(navigator, 'webdriver', {
      get: function() { return undefined; },
      configurable: true
    });

    // 2. Unconditionally override navigator.userAgentData to purge Android WebView brands
    var mockUaData = {
      brands: [
        { brand: 'Not_A Brand', version: '99' },
        { brand: 'Chromium', version: '$majorVersion' },
        { brand: 'Google Chrome', version: '$majorVersion' }
      ],
      mobile: true,
      platform: 'Android',
      getHighEntropyValues: function(hints) {
        return Promise.resolve({
          architecture: '',
          bitness: '',
          brands: [
            { brand: 'Not_A Brand', version: '99' },
            { brand: 'Chromium', version: '$majorVersion' },
            { brand: 'Google Chrome', version: '$majorVersion' }
          ],
          fullVersionList: [
            { brand: 'Not_A Brand', version: '99.0.0.0' },
            { brand: 'Chromium', version: '$fullVersion' },
            { brand: 'Google Chrome', version: '$fullVersion' }
          ],
          mobile: true,
          model: 'K',
          platform: 'Android',
          platformVersion: '10.0.0',
          uaFullVersion: '$fullVersion'
        });
      }
    };
    Object.defineProperty(navigator, 'userAgentData', {
      get: function() { return mockUaData; },
      configurable: true
    });

    // 3. Ensure navigator.languages is present
    if (window.navigator && !window.navigator.languages) {
      Object.defineProperty(window.navigator, 'languages', {
        get: function() { return ['en-US', 'en']; },
        configurable: true
      });
    }

    // 4. Ensure window.chrome exists to match desktop/standard mobile Chrome
    if (!window.chrome) {
      window.chrome = {
        runtime: {},
        loadTimes: function() {},
        csi: function() {},
        app: {}
      };
    }
  } catch (e) {}
})();
''';
  }

  void setController(InAppWebViewController? controller) {
    _controller = controller;
  }

  /// Installs the stealth script into the WebView if [enabled] is true.
  Future<void> installAsUserScript({bool enabled = true}) async {
    if (!enabled) return;
    if (_userScriptAdded) return;
    final controller = _controller;
    if (controller == null) return;

    try {
      await controller.addUserScript(
        userScript: UserScript(
          source: _buildStealthJs(),
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: false,
          groupName: 'aurora_stealth',
        ),
      );
      _userScriptAdded = true;
    } catch (_) {}
  }

  /// Removes the stealth user script group.
  Future<void> removeUserScript() async {
    final controller = _controller;
    if (controller == null || !_userScriptAdded) return;

    try {
      await controller.removeUserScriptsByGroupName(groupName: 'aurora_stealth');
      _userScriptAdded = false;
    } catch (_) {}
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../settings/download_settings.dart';
import '../models/browser_tab.dart';

/// Manages the "Block page element" (surgical mode) state machine.
///
/// Injected dependencies (constructor parameters) keep the controller
/// free of widget/BuildContext dependencies.
class ElementPickerController {
  final BrowserTab Function() _activeTabGetter;
  final ValueChanged<DownloadSettings>? _onSettingsChanged;
  final void Function(String message) _showSnack;

  bool _isActive = false;
  Timer? _timeout;
  final ValueNotifier<bool> _isActiveNotifier = ValueNotifier<bool>(false);

  ElementPickerController({
    required BrowserTab Function() activeTabGetter,
    required ValueChanged<DownloadSettings>? onSettingsChanged,
    required void Function(String message) showSnack,
  })  : _activeTabGetter = activeTabGetter,
        _onSettingsChanged = onSettingsChanged,
        _showSnack = showSnack;

  // ---------------------------------------------------------------------------
  // Reactive state
  // ---------------------------------------------------------------------------

  /// Whether the element picker is currently active.
  bool get isActive => _isActive;

  /// A [ValueListenable] that fires when [isActive] changes.
  ValueListenable<bool> get isActiveListenable => _isActiveNotifier;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Start the element picker on the active tab.
  Future<void> startPicker() async {
    if (_isActive) return;
    _isActive = true;
    _isActiveNotifier.value = true;

    _timeout?.cancel();
    _timeout = Timer(const Duration(seconds: 30), () {
      cancelPicker(autoCancelled: true);
    });

    try {
      final tab = _activeTabGetter();
      await tab.controller.evaluateJavaScript(
        '__auroraElementPickerActive = true;',
      );
    } catch (_) {}
  }

  /// Cancel the element picker.
  Future<void> cancelPicker({bool autoCancelled = false}) async {
    if (!_isActive) return;
    _isActive = false;
    _isActiveNotifier.value = false;

    _timeout?.cancel();
    _timeout = null;

    try {
      final tab = _activeTabGetter();
      await tab.controller.evaluateJavaScript(
        '__auroraElementPickerActive = false;',
      );
    } catch (_) {}

    if (autoCancelled) {
      _showSnack('Element picker auto-cancelled.');
    }
  }

  /// Handle a picked element message from the ElementPickerChannel
  /// (interactive picker) or from the context-menu "Block This Element"
  /// action.  The `_isActive` guard was removed because the context-menu
  /// path provides element data directly without activating the picker.
  /// Returns the updated [DownloadSettings] with the new rule added, or
  /// `null` if the element could not be parsed or the host was empty.
  Future<DownloadSettings?> handlePickedElement(
    BrowserTab tab,
    String rawMessage,
    DownloadSettings settings,
  ) async {
    _isActive = false;
    _isActiveNotifier.value = false;
    _timeout?.cancel();
    _timeout = null;

    try {
      final data = _parsePickerMessage(rawMessage);
      if (data == null) return null;

      final currentUrl = await tab.controller.currentUrl();
      final pageHost =
          (Uri.tryParse(currentUrl ?? '')?.host ??
                  data['host'] as String? ??
                  '')
              .toLowerCase();
      if (pageHost.isEmpty) return null;

      final srcOrHref = ((data['src'] as String?)?.trim().isNotEmpty ?? false)
          ? (data['src'] as String).trim()
          : (data['href'] as String? ?? '').trim();
      final selector = _cleanElementSelector(data['selector'] as String?);

      DownloadSettings? updated;
      final resourceUri = Uri.tryParse(srcOrHref);
      if (resourceUri != null && resourceUri.host.isNotEmpty) {
        // Network rule — block by host
        final host = resourceUri.host.toLowerCase();
        updated = settings.copyWith(
          manualAdBlockRules: [
            ...settings.manualAdBlockRules,
            ManualAdBlockRule(pattern: host, domainRule: true),
          ],
        );
        _onSettingsChanged?.call(updated);
      } else if (selector != null) {
        // Cosmetic rule — hide by selector
        if (pageHost.isNotEmpty) {
          updated = settings.copyWith(
            manualCosmeticRules: [
              ...settings.manualCosmeticRules,
              CosmeticAdRule(host: pageHost, selector: selector),
            ],
          );
          _onSettingsChanged?.call(updated);
        }
      }

      try {
        await tab.controller.evaluateJavaScript(
          '__auroraElementPickerActive = false;',
        );
      } catch (_) {}

      return updated;
    } catch (e) {
      debugPrint('[ElementPicker] handlePickedElement error: $e');
      return null;
    }
  }

  /// Apply cosmetic rules to the given tab.
  Future<void> applyCosmeticRules(
    BrowserTab tab, {
    DownloadSettings? settings,
  }) async {
    final s = settings;
    if (s == null) return;
    if (s.manualCosmeticRules.isEmpty) return;

    try {
      final currentUrl = await tab.controller.currentUrl();
      final pageHost = Uri.tryParse(currentUrl ?? '')?.host ?? '';
      final rulesForHost = s.manualCosmeticRules
          .where((r) => r.host == pageHost)
          .toList(growable: false);
      if (rulesForHost.isEmpty) return;

      final cssSelectors =
          rulesForHost.map((r) => r.selector).join(',\n');
      final js = '''
(function() {
  var style = document.getElementById('aurora-manual-cosmetic-rules');
  if (!style) {
    style = document.createElement('style');
    style.id = 'aurora-manual-cosmetic-rules';
    document.head.appendChild(style);
  }
  style.textContent = '$cssSelectors { display: none !important; }';
})();
''';
      await tab.controller.evaluateJavaScript(js);
    } catch (_) {}
  }

  /// Reset all manual block rules for the current host and reload.
  Future<void> resetPageElementBlocks(DownloadSettings settings) async {
    final tab = _activeTabGetter();
    try {
      final currentUrl = await tab.controller.currentUrl();
      final pageHost = Uri.tryParse(currentUrl ?? '')?.host ?? '';

      final updated = settings.copyWith(
        manualAdBlockRules: settings.manualAdBlockRules
            .where((r) => r.pattern != pageHost)
            .toList(growable: false),
        manualCosmeticRules: settings.manualCosmeticRules
            .where((r) => r.host != pageHost)
            .toList(growable: false),
      );
      _onSettingsChanged?.call(updated);

      try {
        await tab.controller.evaluateJavaScript(
          '__auroraElementPickerActive = false;',
        );
      } catch (_) {}

      _showSnack('Page element blocks reset. Reloading…');
      await tab.controller.reload();
    } catch (_) {
      _showSnack('Failed to reset blocks.');
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Map<String, dynamic>? _parsePickerMessage(String raw) {
    try {
      // Messages come as JSON string or raw string
      if (raw.startsWith('{')) {
        return Map<String, dynamic>.from(
          const JsonDecoder().convert(raw) as Map,
        );
      }
      // Legacy format: just a URL/selector string
      return {'selector': raw, 'ruleType': 'network'};
    } catch (_) {
      return null;
    }
  }

  String? _cleanElementSelector(String? selector) {
    if (selector == null || selector.isEmpty) return null;
    // Remove leading/trailing whitespace and quotes
    var cleaned = selector.trim();
    if ((cleaned.startsWith('"') && cleaned.endsWith('"')) ||
        (cleaned.startsWith("'") && cleaned.endsWith("'"))) {
      cleaned = cleaned.substring(1, cleaned.length - 1);
    }
    // Escape CSS special characters that could break the selector
    cleaned = cleaned.replaceAll("'", "\\'");
    return cleaned.isNotEmpty ? cleaned : null;
  }

  void dispose() {
    _timeout?.cancel();
    _timeout = null;
    _isActive = false;
    _isActiveNotifier.dispose();
  }
}

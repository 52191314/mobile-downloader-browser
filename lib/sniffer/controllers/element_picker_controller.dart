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

  final int? _maxRules;

  ElementPickerController({
    required BrowserTab Function() activeTabGetter,
    required ValueChanged<DownloadSettings>? onSettingsChanged,
    required void Function(String message) showSnack,
    int? maxRules,
  })  : _activeTabGetter = activeTabGetter,
        _onSettingsChanged = onSettingsChanged,
        _showSnack = showSnack,
        _maxRules = maxRules;

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
      _showSnack('Picker timed out after 30 seconds. Tap "Block Element" to try again.');
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
      final resourceHost = resourceUri?.host.toLowerCase() ?? '';

      // A third-party host is safe to block wholesale. The page's own host is
      // not: blocking it takes out the site's own images and scripts, which
      // looks like Aurora broke the page. Fall through to a cosmetic rule,
      // which hides exactly the element the user pointed at.
      final isThirdParty = resourceHost.isNotEmpty &&
          resourceHost != pageHost &&
          !resourceHost.endsWith('.$pageHost') &&
          !pageHost.endsWith('.$resourceHost');

      if (isThirdParty) {
        final alreadyBlocked = settings.manualAdBlockRules
            .any((r) => r.pattern.toLowerCase() == resourceHost);
        if (alreadyBlocked) {
          _showSnack('$resourceHost is already blocked.');
          return null;
        }
        updated = settings.copyWith(
          manualAdBlockRules: [
            ...settings.manualAdBlockRules,
            ManualAdBlockRule(
              pattern: resourceHost,
              domainRule: true,
              // Provenance, so "Reset element blocks" on this page can find it.
              addedForHost: pageHost,
            ),
          ],
        );
        _onSettingsChanged?.call(updated);
      } else if (selector != null && pageHost.isNotEmpty) {
        // Cosmetic rule — hide by selector
        final alreadyHidden = settings.manualCosmeticRules
            .any((r) => r.host == pageHost && r.selector == selector);
        if (alreadyHidden) {
          _showSnack('That element is already hidden on $pageHost.');
          return null;
        }
        final maxRules = _maxRules;
        if (maxRules != null &&
            settings.manualCosmeticRules.length >= maxRules) {
          _showSnack(
            'Cosmetic rule limit ($_maxRules) reached. Upgrade to Pro for unlimited rules.',
          );
          return null;
        }
        updated = settings.copyWith(
          manualCosmeticRules: [
            ...settings.manualCosmeticRules,
            CosmeticAdRule(host: pageHost, selector: selector),
          ],
        );
        _onSettingsChanged?.call(updated);
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

  // NOTE: an `applyCosmeticRules` helper used to live here that injected a
  // <style> tag directly. It had no callers -- cosmetic rules reach the page
  // through AdBlockEngine, which serialises them to ABP `host##selector` and
  // lets the native matcher handle subdomains. It was also broken: selectors
  // were joined with a newline and then embedded in a single-quoted JS string
  // literal, so the injected script raised a SyntaxError and applied *nothing*
  // as soon as a host had two rules. Removed rather than fixed, so there is one
  // cosmetic path instead of two that disagree.

  /// Reset all manual block rules for the current host and reload.
  Future<void> resetPageElementBlocks(DownloadSettings settings) async {
    final tab = _activeTabGetter();
    try {
      final currentUrl = await tab.controller.currentUrl();
      final pageHost = Uri.tryParse(currentUrl ?? '')?.host ?? '';

      // Network rules are keyed by the resource host, so matching `pattern`
      // against the page host cleared almost nothing. Match on provenance
      // instead, keeping the old `pattern == pageHost` test so rules saved
      // before addedForHost existed are still resettable.
      final updated = settings.copyWith(
        manualAdBlockRules: settings.manualAdBlockRules
            .where((r) =>
                r.addedForHost != pageHost &&
                !(r.addedForHost == null && r.pattern == pageHost))
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

      _showSnack('Element blocks cleared. Reloading page…');
      await tab.controller.reload();
    } catch (_) {
      _showSnack('Could not reset element blocks. Try again.');
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

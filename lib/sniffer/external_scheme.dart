import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform/public_downloads_service.dart';
import 'external_app_preference_store.dart';

export 'external_app_preference_store.dart'
    show
        ExternalAppDecision,
        ExternalAppPreferenceStore,
        externalAppDisplayNameForKey,
        externalAppDisplayNameForUri,
        externalAppKeyForUri,
        externalAppSubtitleForKey;

/// Result of the "open external app?" prompt.
enum ExternalAppPromptResult {
  /// Open this once; ask again next time.
  openOnce,

  /// Open and remember allow for this app key.
  alwaysOpen,

  /// Do not open; ask again next time.
  denyOnce,

  /// Do not open; remember deny for this app key.
  alwaysDeny,
}

/// UI hook: show a confirmation dialog. Registered by [SnifferScreen].
///
/// Returns the user's choice. If null is registered, non-forced opens are
/// denied (safer than silently launching apps from ads).
typedef ExternalAppPromptHandler = Future<ExternalAppPromptResult> Function({
  required Uri uri,
  required String appKey,
  required String displayName,
  String? pageHost,
});

/// Global prompt handler (set from browser UI).
ExternalAppPromptHandler? externalAppPromptHandler;

/// Schemes the in-app WebView can load without an external app.
///
/// Everything else (`tg:`, `intent://`, `market://`, `mailto:`, …) must be
/// cancelled in the WebView and handed to the system via ACTION_VIEW —
/// otherwise Chromium shows `net::ERR_UNKNOWN_URL_SCHEME`.
bool isWebViewNavigableScheme(String scheme) {
  switch (scheme.toLowerCase()) {
    case 'http':
    case 'https':
    case 'about':
    case 'data':
    case 'blob':
    case 'javascript':
    case 'file':
    case 'chrome':
    case 'chrome-error':
    case 'chrome-native':
      return true;
    default:
      return false;
  }
}

/// True when [uri] must leave the WebView (app deep link, mail, store, …).
///
/// [magnet] is included — callers usually enqueue it in Aurora rather than
/// opening an external torrent client.
bool isExternalAppUri(Uri uri) {
  if (!uri.hasScheme) return false;
  return !isWebViewNavigableScheme(uri.scheme);
}

bool isMagnetUri(Uri uri) => uri.scheme.toLowerCase() == 'magnet';

/// Opens [url] with the system app resolver.
///
/// Returns `true` if the platform accepted the launch, `false` if no handler
/// was found or the channel failed.
@visibleForTesting
Future<bool> Function(String url)? externalAppLauncherOverride;

Future<bool> launchExternalAppUrl(String url) async {
  if (externalAppLauncherOverride != null) {
    return externalAppLauncherOverride!(url);
  }
  final trimmed = url.trim();
  if (trimmed.isEmpty) return false;
  try {
    await PublicDownloadsService.openUrl(trimmed);
    return true;
  } on PlatformException catch (e) {
    debugPrint('[external_scheme] openUrl failed: ${e.code} ${e.message}');
    return false;
  } catch (e) {
    debugPrint('[external_scheme] openUrl failed: $e');
    return false;
  }
}

/// If [uri] is a non-WebView scheme, launches it externally (or reports magnet).
///
/// Returns `true` when the caller should **not** load [uri] in the WebView.
///
/// By default, **websites** that try to open an app are confirmed via
/// [externalAppPromptHandler], unless the user previously chose "don't ask
/// again" for that app ([ExternalAppPreferenceStore]).
///
/// [skipPrompt] is for explicit user actions (address bar, context menu) where
/// the user already chose the destination.
///
/// [onMagnet] is invoked for magnet links; if null, magnets also go external
/// (with the same prompt rules).
///
/// [pageHost] is shown in the dialog (origin page host), when known.
Future<bool> handleExternalAppUri(
  Uri uri, {
  void Function(String url)? onMagnet,
  bool skipPrompt = false,
  String? pageHost,
}) async {
  if (!isExternalAppUri(uri)) return false;
  final url = uri.toString();

  if (isMagnetUri(uri)) {
    if (onMagnet != null) {
      onMagnet(url);
      return true;
    }
  }

  final appKey = externalAppKeyForUri(uri);
  final displayName = externalAppDisplayNameForUri(uri);
  final store = ExternalAppPreferenceStore.instance;

  if (!skipPrompt) {
    final saved = await store.decisionFor(appKey);
    if (saved == ExternalAppDecision.alwaysDeny) {
      debugPrint(
        '[external_scheme] denied by preference: $appKey',
      );
      return true;
    }
    if (saved == ExternalAppDecision.alwaysAllow) {
      await launchExternalAppUrl(url);
      return true;
    }

    final prompt = externalAppPromptHandler;
    if (prompt == null) {
      // No UI registered — do not silently open apps (ad / auto-redirect safe).
      debugPrint(
        '[external_scheme] no prompt handler; blocking $appKey',
      );
      return true;
    }

    final result = await prompt(
      uri: uri,
      appKey: appKey,
      displayName: displayName,
      pageHost: pageHost,
    );

    switch (result) {
      case ExternalAppPromptResult.denyOnce:
        return true;
      case ExternalAppPromptResult.alwaysDeny:
        await store.setDecision(appKey, ExternalAppDecision.alwaysDeny);
        return true;
      case ExternalAppPromptResult.openOnce:
        await launchExternalAppUrl(url);
        return true;
      case ExternalAppPromptResult.alwaysOpen:
        await store.setDecision(appKey, ExternalAppDecision.alwaysAllow);
        await launchExternalAppUrl(url);
        return true;
    }
  }

  await launchExternalAppUrl(url);
  return true;
}

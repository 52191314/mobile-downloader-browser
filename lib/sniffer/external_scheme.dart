import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform/public_downloads_service.dart';

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
Future<bool> launchExternalAppUrl(String url) async {
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
/// [onMagnet] is invoked for magnet links; if null, magnets also go external.
Future<bool> handleExternalAppUri(
  Uri uri, {
  void Function(String url)? onMagnet,
}) async {
  if (!isExternalAppUri(uri)) return false;
  final url = uri.toString();
  if (isMagnetUri(uri)) {
    if (onMagnet != null) {
      onMagnet(url);
      return true;
    }
  }
  await launchExternalAppUrl(url);
  return true;
}

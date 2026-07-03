import 'dart:io' show Platform;
import 'package:flutter/services.dart';

/// Thin Dart wrapper around the native [DownloadForegroundService].
///
/// All calls are no-ops on non-Android platforms.  On Android, they
/// invoke the `aurora_downloader/foreground_service` MethodChannel,
/// which [MainActivity] forwards to [DownloadForegroundService] via
/// intents.
class DownloadForegroundService {
  static const _channel = MethodChannel('aurora_downloader/foreground_service');

  /// Start the foreground service with [count] active downloads.
  /// Posts a persistent notification and elevates process priority.
  static Future<void> start({required int count}) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('start', {'count': count});
    } catch (e) {
      // Best-effort; service is a nice-to-have, not a hard requirement.
    }
  }

  /// Update the persistent notification with current [count],
  /// optional [currentFileName], and overall [percent] (0-100).
  static Future<void> update({
    required int count,
    String? currentFileName,
    required int percent,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('update', {
        'count': count,
        'fileName': currentFileName,
        'percent': percent,
      });
    } catch (e) {
      // Best-effort.
    }
  }

  /// Stop the foreground service and remove its notification.
  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('stop');
    } catch (e) {
      // Best-effort.
    }
  }
}

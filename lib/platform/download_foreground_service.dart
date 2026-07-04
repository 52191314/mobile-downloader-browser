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

  /// Requests the POST_NOTIFICATIONS runtime permission on Android 13+.
  /// Shows the system permission dialog. Safe to call on older API levels
  /// (no-op on the native side).
  static Future<void> requestNotificationPermission() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('requestNotificationPermission');
    } catch (e) {
      // Best-effort.
    }
  }

  /// Opens the Android system intent to let the user whitelist Aurora
  /// from battery optimisations (ignores battery optimisation).
  /// On Android 6+ this opens a system dialog; on older devices it is a
  /// no-op.  Every Android manufacturer's doze / app-standby policy is
  /// different, so this gives the user a fighting chance regardless of OEM.
  static Future<void> requestBatteryOptimizationExemption() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('requestBatteryOpt');
    } catch (e) {
      // Best-effort.
    }
  }
}

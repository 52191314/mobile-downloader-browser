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
  /// (no-op on the native side). Prefer [areNotificationsEnabled] first so
  /// we do not re-prompt when already granted.
  static Future<void> requestNotificationPermission() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('requestNotificationPermission');
    } catch (e) {
      // Best-effort.
    }
  }

  /// Whether notification permission is already granted (API 33+) or
  /// notifications are enabled for the app (older APIs via NotificationManager).
  /// Always true on non-Android.
  static Future<bool> areNotificationsEnabled() async {
    if (!Platform.isAndroid) return true;
    try {
      final bool? result =
          await _channel.invokeMethod<bool>('areNotificationsEnabled');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Opens the Android system intent to let the user whitelist Aurora
  /// from battery optimisations (ignores battery optimisation).
  /// On Android 6+ this opens a system dialog; on older devices it is a
  /// no-op.  Every Android manufacturer's doze / app-standby policy is
  /// different, so this gives the user a fighting chance regardless of OEM.
  ///
  /// Returns a map with an optional "oem" key (e.g. "xiaomi", "huawei",
  /// "samsung") when the manufacturer has separate autostart / background-
  /// activity settings that the user should also adjust.  Returns an empty
  /// map on non-Android or when the manufacturer is not specially detected.
  static Future<Map<String, dynamic>> requestBatteryOptimizationExemption() async {
    if (!Platform.isAndroid) return {};
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
          'requestBatteryOpt');
      return Map<String, dynamic>.from(result ?? {});
    } catch (e) {
      return {};
    }
  }

  /// Checks whether the app is already whitelisted from battery optimisations.
  /// Always returns true on non-Android platforms.
  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;
    try {
      final bool? result =
          await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Opens the manufacturer-specific autostart / background-activity
  /// settings page when the device is from a known OEM that has separate
  /// toggles outside the standard AOSP battery optimisation whitelist.
  static Future<void> openOemAutostartPage() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('openOemAutostartPage');
    } catch (e) {
      // Best-effort.
    }
  }

  /// Returns a human-readable label for the OEM settings screen that the
  /// user needs to visit, given the [oem] key returned by
  /// [requestBatteryOptimizationExemption].  Returns null for unknown OEMs.
  static String? oemLabel(String oem) {
    switch (oem) {
      case 'xiaomi':
        return 'Auto-start in Security centre';
      case 'huawei':
        return 'Protected apps in Phone Manager';
      case 'oppo':
      case 'realme':
        return 'Auto-start in Safe centre';
      case 'vivo':
        return 'Auto-start in iManager';
      case 'oneplus':
        return 'Background activity in Security';
      case 'samsung':
        return 'Battery in Device care';
      default:
        return null;
    }
  }

  /// Returns a human-readable name for the OEM, given the [oem] key.
  static String? oemName(String oem) {
    switch (oem) {
      case 'xiaomi':
        return 'Xiaomi';
      case 'huawei':
        return 'Huawei';
      case 'oppo':
        return 'OPPO / Realme';
      case 'realme':
        return 'OPPO / Realme';
      case 'vivo':
        return 'Vivo';
      case 'oneplus':
        return 'OnePlus';
      case 'samsung':
        return 'Samsung';
      default:
        return null;
    }
  }
}

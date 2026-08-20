import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../analytics/aurora_analytics_service.dart';
import '../ui/notifications/aurora_snackbar.dart';
import '../ui/widgets/force_update_dialog.dart';

/// Update availability status matching Google Play In-App Updates constants.
enum AppUpdateAvailability {
  unknown(0),
  notAvailable(1),
  available(2),
  inProgress(3);

  final int value;
  const AppUpdateAvailability(this.value);

  static AppUpdateAvailability fromValue(int val) {
    return AppUpdateAvailability.values.firstWhere(
      (e) => e.value == val,
      orElse: () => AppUpdateAvailability.unknown,
    );
  }
}

/// Metadata describing the available app update returned by Google Play.
class AppUpdateInfo {
  final AppUpdateAvailability availability;
  final int availableVersionCode;
  final bool isImmediateAllowed;
  final bool isFlexibleAllowed;
  final int? clientVersionStalenessDays;
  final int updatePriority;
  final String? packageName;

  const AppUpdateInfo({
    required this.availability,
    required this.availableVersionCode,
    required this.isImmediateAllowed,
    required this.isFlexibleAllowed,
    this.clientVersionStalenessDays,
    required this.updatePriority,
    this.packageName,
  });

  factory AppUpdateInfo.fromMap(Map<dynamic, dynamic> map) {
    return AppUpdateInfo(
      availability: AppUpdateAvailability.fromValue(map['availability'] as int? ?? 0),
      availableVersionCode: map['availableVersionCode'] as int? ?? 0,
      isImmediateAllowed: map['isImmediateAllowed'] as bool? ?? false,
      isFlexibleAllowed: map['isFlexibleAllowed'] as bool? ?? false,
      clientVersionStalenessDays: map['clientVersionStalenessDays'] as int?,
      updatePriority: map['updatePriority'] as int? ?? 0,
      packageName: map['packageName'] as String?,
    );
  }

  /// Whether an update is ready or actively in progress on Google Play.
  bool get isUpdateAvailable =>
      availability == AppUpdateAvailability.available ||
      availability == AppUpdateAvailability.inProgress;

  /// Minimum supported build code required across the network / client.
  /// Any user running a build code lower than this is hard-blocked (force update).
  static const int defaultMinSupportedBuildCode = 86;

  /// Determines if a hard/mandatory force update should be enforced.
  ///
  /// Criteria for force update (Supercell style):
  /// 1. A minimum supported version is configured (defaults to 86) and client is below it.
  /// 2. Google Play updatePriority >= 4 (high-priority security/protocol fix).
  /// 3. Immediate update is in progress.
  bool isForceUpdateRequired({
    int currentBuildCode = 86,
    int minSupportedBuildCode = defaultMinSupportedBuildCode,
    int minPriorityForForce = 4,
  }) {
    if (currentBuildCode < minSupportedBuildCode) {
      return true;
    }
    if (updatePriority >= minPriorityForForce) {
      return true;
    }
    if (availability == AppUpdateAvailability.inProgress) {
      return true;
    }
    return false;
  }
}

/// Service managing Google Play In-App Updates and forced update version gates.
class AppUpdateService with ChangeNotifier {
  AppUpdateService._();
  static final AppUpdateService instance = AppUpdateService._();

  static const MethodChannel _channel = MethodChannel('aurora_downloader/app_update');
  static const MethodChannel _publicDownloadsChannel =
      MethodChannel('aurora_downloader/public_downloads');

  static const String playStoreMarketUri =
      'market://details?id=com.personal.aurora_downloader';
  static const String playStoreWebUrl =
      'https://play.google.com/store/apps/details?id=com.personal.aurora_downloader';

  AppUpdateInfo? _cachedInfo;
  AppUpdateInfo? get cachedInfo => _cachedInfo;

  bool _isChecking = false;
  bool get isChecking => _isChecking;

  /// Checks Google Play for an available app update.
  Future<AppUpdateInfo?> checkAppUpdate() async {
    _isChecking = true;
    notifyListeners();
    try {
      final res = await _channel.invokeMapMethod<dynamic, dynamic>('checkAppUpdate');
      if (res != null) {
        _cachedInfo = AppUpdateInfo.fromMap(res);
        return _cachedInfo;
      }
    } on MissingPluginException {
      // Non-Android platform (e.g. tests or desktop).
    } catch (e) {
      debugPrint('[AppUpdateService] checkAppUpdate error: $e');
    } finally {
      _isChecking = false;
      notifyListeners();
    }
    return null;
  }

  /// Starts the Google Play In-App Update flow (immediate full-screen or flexible).
  Future<String> startUpdate({bool immediate = true}) async {
    AuroraAnalyticsService.instance.logAppUpdateAccepted(
      buildCode: _cachedInfo?.availableVersionCode ?? 0,
    );
    try {
      final res = await _channel.invokeMethod<String>('startUpdate', {
        'type': immediate ? 'immediate' : 'flexible',
      });
      return res ?? 'ok';
    } catch (e) {
      debugPrint('[AppUpdateService] startUpdate error: $e');
      // If native flow fails, fallback to opening Google Play Store page
      await openPlayStore();
      return 'fallback_store_opened';
    }
  }

  /// Completes a flexible background update by triggering Play Store app restart.
  Future<bool> completeFlexibleUpdate() async {
    try {
      final res = await _channel.invokeMethod<bool>('completeFlexibleUpdate');
      return res ?? false;
    } catch (e) {
      debugPrint('[AppUpdateService] completeFlexibleUpdate error: $e');
      return false;
    }
  }

  /// Opens the official Google Play Store listing for Aurora Downloader.
  Future<void> openPlayStore() async {
    try {
      await _publicDownloadsChannel.invokeMethod('openUrl', {'url': playStoreMarketUri});
    } catch (_) {
      try {
        await _publicDownloadsChannel.invokeMethod('openUrl', {'url': playStoreWebUrl});
      } catch (e) {
        debugPrint('[AppUpdateService] openPlayStore failed: $e');
      }
    }
  }

  /// Checks for updates and displays the appropriate update dialog/prompt.
  Future<void> checkAndPromptAutoUpdate(
    BuildContext context, {
    int currentBuildCode = 87,
    int? minSupportedBuildCode,
    bool isInteractive = false,
  }) async {
    final info = await checkAppUpdate();
    if (!context.mounted) return;

    final effectiveMin = minSupportedBuildCode ?? AppUpdateInfo.defaultMinSupportedBuildCode;
    final isMandatory = (currentBuildCode < effectiveMin) ||
        (info != null &&
            info.isForceUpdateRequired(
              currentBuildCode: currentBuildCode,
              minSupportedBuildCode: effectiveMin,
            ));

    if (isMandatory || (info != null && info.isUpdateAvailable)) {
      final effectiveInfo = info ??
          AppUpdateInfo(
            availability: AppUpdateAvailability.available,
            availableVersionCode: effectiveMin,
            isImmediateAllowed: true,
            isFlexibleAllowed: false,
            updatePriority: 5,
            packageName: 'com.personal.aurora_downloader',
          );

      AuroraAnalyticsService.instance.logAppUpdatePrompted(
        buildCode: effectiveInfo.availableVersionCode,
      );

      await showDialog<void>(
        context: context,
        barrierDismissible: !isMandatory,
        builder: (ctx) => ForceUpdateDialog(
          updateInfo: effectiveInfo,
          isMandatory: isMandatory,
          onUpdateTap: () async {
            if (info != null && (info.isImmediateAllowed || isMandatory)) {
              final res = await startUpdate(immediate: true);
              if (res != 'ok') {
                await openPlayStore();
              }
            } else {
              await openPlayStore();
            }
          },
        ),
      );
    } else if (isInteractive) {
      AuroraSnackbar.show(
        context,
        'You are using the latest version of Aurora Downloader.',
        actionLabel: 'OK',
      );
    }
  }
}

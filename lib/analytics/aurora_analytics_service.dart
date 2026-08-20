import 'dart:async';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';
import '../premium/local_funnel_store.dart';

/// Centralized, privacy-safe analytics service for Aurora Downloader.
///
/// Compliant with Google Play Data Safety policies and Firebase guidelines:
/// - Never logs PII (emails, account IDs, tokens, personal search queries).
/// - Sanitizes URLs to host/protocol only (strips paths, queries, and auth params).
/// - Enforces safe parameter character limits for Firebase Analytics.
/// - Fail-open: analytics errors are caught and never disrupt app execution.
/// - Mirrors events to [LocalFunnelStore] for local diagnostics and offline support.
class AuroraAnalyticsService {
  AuroraAnalyticsService._();

  static final AuroraAnalyticsService instance = AuroraAnalyticsService._();

  FirebaseAnalytics get _firebase => FirebaseAnalytics.instance;

  /// Helper to sanitize a URL down to just its hostname to prevent
  /// logging private query strings or tokenized paths.
  static String sanitizeHost(String? rawUrl) {
    if (rawUrl == null || rawUrl.isEmpty) return 'unknown';
    try {
      final uri = Uri.tryParse(rawUrl);
      if (uri != null && uri.host.isNotEmpty) {
        return uri.host.toLowerCase();
      }
    } catch (_) {}
    return 'direct';
  }

  /// Truncate string values to meet Firebase Analytics 100-char parameter limit.
  static String _safeParam(String value, [int maxLen = 95]) {
    final clean = value.trim();
    if (clean.length <= maxLen) return clean;
    return clean.substring(0, maxLen);
  }

  /// Generic safe event logger with dual Firebase + LocalFunnel reporting.
  Future<void> logEvent(
    String name, [
    Map<String, Object>? parameters,
  ]) async {
    try {
      final sanitizedName = _safeParam(name, 40);
      final Map<String, Object> safeParams = {};

      if (parameters != null) {
        parameters.forEach((key, val) {
          final safeKey = _safeParam(key, 40);
          if (val is String) {
            safeParams[safeKey] = _safeParam(val, 95);
          } else if (val is num || val is bool) {
            safeParams[safeKey] = val;
          } else {
            safeParams[safeKey] = _safeParam(val.toString(), 95);
          }
        });
      }

      // 1. Log to Firebase Analytics (Play Store channel)
      await _firebase.logEvent(
        name: sanitizedName,
        parameters: safeParams.isNotEmpty ? safeParams : null,
      );

      // 2. Mirror to LocalFunnelStore for offline support diagnostics
      LocalFunnelStore.record(sanitizedName, props: safeParams);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[AnalyticsError] Failed to log $name: $e');
      }
    }
  }

  // ─── 1. Download Lifecycle Funnel ─────────────────────────────────────────

  Future<void> logDownloadStarted({
    required String protocol,
    String? host,
    String? contentType,
  }) async {
    await logEvent('download_started', {
      'protocol': _safeParam(protocol),
      if (host != null) 'host': _safeParam(host),
      if (contentType != null) 'content_type': _safeParam(contentType),
    });
  }

  Future<void> logDownloadCompleted({
    required String protocol,
    required int totalBytes,
    int? durationSeconds,
  }) async {
    await logEvent('download_completed', {
      'protocol': _safeParam(protocol),
      'total_bytes': totalBytes,
      if (durationSeconds != null) 'duration_s': durationSeconds,
    });
  }

  Future<void> logDownloadFailed({
    required String protocol,
    required String failureReason,
    String? errorSnippet,
  }) async {
    await logEvent('download_failed', {
      'protocol': _safeParam(protocol),
      'failure_reason': _safeParam(failureReason),
      if (errorSnippet != null && errorSnippet.isNotEmpty)
        'error_snippet': _safeParam(errorSnippet),
    });
  }

  // ─── 2. Monetization & Paywall Funnel ────────────────────────────────────

  Future<void> logUpsellViewed({
    required String trigger,
    String? currentTier,
  }) async {
    await logEvent('pro_upsell_viewed', {
      'trigger': _safeParam(trigger),
      'current_tier': _safeParam(currentTier ?? 'free'),
    });
  }

  Future<void> logPurchaseInitiated({
    required String productId,
    required String targetTier,
  }) async {
    await logEvent('purchase_initiated', {
      'product_id': _safeParam(productId),
      'target_tier': _safeParam(targetTier),
    });
  }

  Future<void> logPurchaseCompleted({
    required String productId,
    required String grantedTier,
  }) async {
    await logEvent('purchase_completed', {
      'product_id': _safeParam(productId),
      'granted_tier': _safeParam(grantedTier),
    });
  }

  Future<void> logPurchaseFailed({
    required String productId,
    required String errorReason,
  }) async {
    await logEvent('purchase_failed', {
      'product_id': _safeParam(productId),
      'error_reason': _safeParam(errorReason),
    });
  }

  Future<void> logFreeTasteUsed({required String feature}) async {
    await logEvent('free_taste_used', {
      'feature': _safeParam(feature),
    });
  }

  // ─── 3. Onboarding & Tour Funnel ──────────────────────────────────────────

  Future<void> logOnboardingStarted() async {
    await logEvent('onboarding_started');
  }

  Future<void> logOnboardingStepViewed({
    required int stepIndex,
    required String stepTitle,
  }) async {
    await logEvent('onboarding_step_viewed', {
      'step_index': stepIndex,
      'step_title': _safeParam(stepTitle),
    });
  }

  Future<void> logOnboardingCompleted() async {
    await logEvent('onboarding_completed');
  }

  Future<void> logOnboardingSkipped({required int lastStepIndex}) async {
    await logEvent('onboarding_skipped', {
      'last_step_index': lastStepIndex,
    });
  }

  Future<void> logLanguageSelected({
    required String languageCode,
    required bool isFirstLaunch,
  }) async {
    await logEvent('language_selected', {
      'language': _safeParam(languageCode),
      'is_first_launch': isFirstLaunch,
    });
  }

  // ─── 4. Sniffer & Browser Radar Funnel ────────────────────────────────────

  Future<void> logMediaSniffed({
    required String mediaType,
    String? host,
  }) async {
    await logEvent('media_sniffed', {
      'media_type': _safeParam(mediaType),
      if (host != null) 'host': _safeParam(host),
    });
  }

  Future<void> logSnifferRadarOpened({required int mediaCount}) async {
    await logEvent('sniffer_radar_opened', {
      'detected_count': mediaCount,
    });
  }

  Future<void> logBatchDownloadStarted({required int itemCount}) async {
    await logEvent('batch_download_started', {
      'item_count': itemCount,
    });
  }

  // ─── 5. Feature Usage & Tool Adoption ─────────────────────────────────────

  Future<void> logTorrentAdded({required String source}) async {
    await logEvent('torrent_added', {
      'source': _safeParam(source), // magnet / file
    });
  }

  Future<void> logFfmpegToolUsed({required String toolName}) async {
    await logEvent('ffmpeg_tool_used', {
      'tool': _safeParam(toolName),
    });
  }

  Future<void> logVaultAction({required String action}) async {
    await logEvent('vault_action', {
      'action': _safeParam(action), // lock / unlock / import
    });
  }

  Future<void> logBackupTriggered({required String target}) async {
    await logEvent('backup_triggered', {
      'target': _safeParam(target), // webdav / drive
    });
  }

  Future<void> logAppUpdatePrompted({required int buildCode}) async {
    await logEvent('in_app_update_prompted', {
      'target_build': buildCode,
    });
  }

  Future<void> logAppUpdateAccepted({required int buildCode}) async {
    await logEvent('in_app_update_accepted', {
      'target_build': buildCode,
    });
  }
}

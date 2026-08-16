import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../premium/pro_entitlement.dart';
import '../premium/pro_features.dart';
import '../premium/pro_upsell_sheet.dart';
import '../theme/aurora_palette.dart';

/// Manages lifecycle prompts:
/// - 3rd app launch: Google Play Review / Rating Prompt
/// - 7th app launch: Aurora Pro / Ultra Purchase Prompt
///
/// Includes full debug controls for toggling, simulating, and testing.
class EngagementPromptService with ChangeNotifier {
  EngagementPromptService._();

  static final EngagementPromptService instance = EngagementPromptService._();

  static const String _fileName = 'engagement_prompt_state.json';
  static const String playStoreUrl =
      'https://play.google.com/store/apps/details?id=com.personal.aurora_downloader';
  static const String playStoreMarketUri =
      'market://details?id=com.personal.aurora_downloader';

  int _appOpenCount = 0;
  bool _reviewDismissed = false;
  bool _hasRated = false;
  bool _purchaseDismissed = false;
  bool _enabled = true;
  bool _initialized = false;

  int get appOpenCount => _appOpenCount;
  bool get reviewDismissed => _reviewDismissed;
  bool get hasRated => _hasRated;
  bool get purchaseDismissed => _purchaseDismissed;
  bool get enabled => _enabled;

  static Future<File> _getFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  /// Loads saved prompt state from local disk.
  Future<void> initialize() async {
    if (_initialized) return;
    try {
      final file = await _getFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        final json = jsonDecode(content);
        if (json is Map<String, dynamic>) {
          _appOpenCount = (json['appOpenCount'] as num?)?.toInt() ?? 0;
          _reviewDismissed = json['reviewDismissed'] as bool? ?? false;
          _hasRated = json['hasRated'] as bool? ?? false;
          _purchaseDismissed = json['purchaseDismissed'] as bool? ?? false;
          _enabled = json['enabled'] as bool? ?? true;
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[EngagementPromptService] Failed to load state: $e');
      }
    } finally {
      _initialized = true;
      notifyListeners();
    }
  }

  /// Persists current prompt state to disk.
  Future<void> _persist() async {
    try {
      final file = await _getFile();
      final data = {
        'appOpenCount': _appOpenCount,
        'reviewDismissed': _reviewDismissed,
        'hasRated': _hasRated,
        'purchaseDismissed': _purchaseDismissed,
        'enabled': _enabled,
      };
      await file.writeAsString(jsonEncode(data));
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[EngagementPromptService] Failed to persist state: $e');
      }
    }
  }

  /// Increments app open count on launch and triggers matching prompts.
  Future<void> recordAppOpen(
    BuildContext context, {
    required ProEntitlement proEntitlement,
  }) async {
    await initialize();
    _appOpenCount++;
    await _persist();
    notifyListeners();

    if (!_enabled) return;

    // Small post-launch delay to allow the shell UI to settle
    await Future.delayed(const Duration(milliseconds: 1200));
    if (!context.mounted) return;

    if (_appOpenCount == 3) {
      if (!_reviewDismissed && !_hasRated) {
        await showReviewPrompt(context);
      }
    } else if (_appOpenCount == 7) {
      if (!_purchaseDismissed && !proEntitlement.isPro) {
        await showPurchasePrompt(context, proEntitlement: proEntitlement);
      }
    }
  }

  /// Displays the 3rd-open Google Play review prompt dialog.
  Future<void> showReviewPrompt(BuildContext context) async {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) => _ReviewPromptDialog(service: this),
    );
  }

  /// Displays the 7th-open Pro purchase prompt dialog.
  Future<void> showPurchasePrompt(
    BuildContext context, {
    required ProEntitlement proEntitlement,
  }) async {
    if (!context.mounted) return;
    if (proEntitlement.isPro) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You are already an Aurora Pro user!')),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) => _PurchasePromptDialog(
        service: this,
        proEntitlement: proEntitlement,
      ),
    );
  }

  /// Toggles automatic 3rd & 7th open prompt evaluation.
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    await _persist();
    notifyListeners();
  }

  /// Updates the open count (for debug simulation).
  Future<void> setOpenCount(int count) async {
    _appOpenCount = count.clamp(0, 99999);
    await _persist();
    notifyListeners();
  }

  /// Marks the review prompt as completed (user tapped Rate).
  Future<void> markRated() async {
    _hasRated = true;
    _reviewDismissed = true;
    await _persist();
    notifyListeners();
  }

  /// Dismisses the review prompt (user chose 'No thanks').
  Future<void> dismissReview() async {
    _reviewDismissed = true;
    await _persist();
    notifyListeners();
  }

  /// Dismisses the purchase prompt.
  Future<void> dismissPurchase() async {
    _purchaseDismissed = true;
    await _persist();
    notifyListeners();
  }

  /// Resets all counters and prompt flags for debug testing.
  Future<void> resetDebugState() async {
    _appOpenCount = 0;
    _reviewDismissed = false;
    _hasRated = false;
    _purchaseDismissed = false;
    await _persist();
    notifyListeners();
  }

  /// Opens the Google Play Store page for Aurora Downloader.
  static Future<void> openPlayStore() async {
    const channel = MethodChannel('aurora_downloader/public_downloads');
    try {
      // Try market:// URI first for direct Play Store app launch
      await channel.invokeMethod('openUrl', {'url': playStoreMarketUri});
    } catch (_) {
      try {
        // Fallback to HTTPS link
        await channel.invokeMethod('openUrl', {'url': playStoreUrl});
      } catch (e) {
        debugPrint('[EngagementPromptService] Failed to open Play Store: $e');
      }
    }
  }
}

// =============================================================================
// Dialogs
// =============================================================================

class _ReviewPromptDialog extends StatelessWidget {
  final EngagementPromptService service;

  const _ReviewPromptDialog({required this.service});

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return AlertDialog(
      backgroundColor: ac.surfaceCard,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: ac.borderHairline),
      ),
      contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: ac.accentFrost.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.star_rounded, color: ac.accentFrost, size: 28),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Enjoying Aurora?',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: ac.textPrimary,
              ),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'If Aurora helps you download and browse smoothly, please take a moment to leave a 5-star rating on Google Play.',
            style: TextStyle(
              fontSize: 14,
              height: 1.4,
              color: ac.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Your feedback directly supports continued development and new features!',
            style: TextStyle(
              fontSize: 12,
              fontStyle: FontStyle.italic,
              color: ac.textTertiary,
            ),
          ),
        ],
      ),
      actionsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      actions: [
        Row(
          children: [
            TextButton(
              onPressed: () {
                service.dismissReview();
                Navigator.of(context).pop();
              },
              child: Text(
                'No, thanks',
                style: TextStyle(color: ac.textTertiary, fontSize: 13),
              ),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                'Later',
                style: TextStyle(color: ac.textSecondary, fontSize: 13),
              ),
            ),
            const SizedBox(width: 4),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: ac.accentFrost,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              ),
              icon: const Icon(Icons.rate_review, size: 16),
              label: const Text(
                'Rate',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              onPressed: () async {
                await service.markRated();
                Navigator.of(context).pop();
                await EngagementPromptService.openPlayStore();
              },
            ),
          ],
        ),
      ],
    );
  }
}

class _PurchasePromptDialog extends StatelessWidget {
  final EngagementPromptService service;
  final ProEntitlement proEntitlement;

  const _PurchasePromptDialog({
    required this.service,
    required this.proEntitlement,
  });

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return AlertDialog(
      backgroundColor: ac.surfaceCard,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: ac.borderHairline),
      ),
      contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: ac.accentFrost.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.workspace_premium, color: ac.accentFrost, size: 28),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Unlock Aurora Pro',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: ac.textPrimary,
              ),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Supercharge your downloading experience with full Pro capabilities:',
            style: TextStyle(
              fontSize: 14,
              color: ac.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          _featureRow(context, Icons.speed, 'Unlimited high-speed threads & multi-segmenting'),
          _featureRow(context, Icons.cloud_sync_outlined, 'Encrypted WebDAV & Google Drive sync'),
          _featureRow(context, Icons.music_note, 'Native Audio Extraction & Studio tools'),
          _featureRow(context, Icons.radar, 'Unlimited background media sniffing queue'),
        ],
      ),
      actionsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      actions: [
        Row(
          children: [
            TextButton(
              onPressed: () {
                service.dismissPurchase();
                Navigator.of(context).pop();
              },
              child: Text(
                'Maybe later',
                style: TextStyle(color: ac.textTertiary, fontSize: 13),
              ),
            ),
            const Spacer(),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: ac.accentFrost,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              ),
              icon: const Icon(Icons.stars, size: 16),
              label: const Text(
                'View Pro Plans',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              onPressed: () async {
                Navigator.of(context).pop();
                await service.dismissPurchase();
                await showProUpsell(
                  context,
                  ProFeature.turboEngine,
                  userTier: proEntitlement.tier,
                );
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _featureRow(BuildContext context, IconData icon, String text) {
    final ac = context.ac;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: ac.accentFrost),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12.5, color: ac.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

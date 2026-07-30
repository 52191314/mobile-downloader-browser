/// Free-taste gating model — one helper so every free-taste feature behaves
/// the same (remediation plan §3).
///
/// ## Modes
///
/// | Mode | Meaning | Examples |
/// |------|---------|----------|
/// | `hardLock` | Free cannot use at all | proxy, Ultra-only |
/// | `softActionCap` | Free may use first N items per action (no store) | batchCapture first-5, seriesGrab first-5 |
/// | `dailyQuota` | Free may use N units per local calendar day | audioExtract 3/day, sendToPc 20/day |
/// | `inventoryCap` | Free may hold up to N items | privateVault 25 files |
///
/// ## Daily quota consumption
///
/// [evaluate] with [consume] = false only peeks remaining capacity.
/// Use `consume: true` only after the side-effect succeeded (e.g. LAN server
/// started), so failed starts do not burn free taste.
library;

import 'free_cap_store.dart';
import 'pro_entitlement.dart';
import 'pro_features.dart';

// ---------------------------------------------------------------------------
// Taste mode enum
// ---------------------------------------------------------------------------

/// How free users access a Pro/Ultra feature.
enum FreeTasteMode {
  /// Free cannot use at all (hard lock). Example: proxy, Ultra-only.
  hardLock,

  /// Free may use with a soft size cap per action (no daily store).
  /// Example: batchCapture first-5, seriesGrab first-5 episodes.
  softActionCap,

  /// Free may use N units per local calendar day (FreeCapStore).
  /// Example: audioExtract 3/day, sendToPc 20/day.
  dailyQuota,

  /// Free may hold up to N inventory items.
  /// Example: privateVault 25 files.
  inventoryCap,
}

// ---------------------------------------------------------------------------
// Decision type
// ---------------------------------------------------------------------------

/// Result of a free-taste access check.
class FreeTasteDecision {
  final bool allowed;

  /// For [FreeTasteMode.softActionCap]: how many items are allowed (≤ limit).
  /// For other modes: null (or echo of requested [n] for daily when allowed).
  final int? allowedCount;

  /// Human-readable reason string (for debugging / logging).
  final String reason;

  const FreeTasteDecision({
    required this.allowed,
    this.allowedCount,
    required this.reason,
  });

  static const allowedUnlimited =
      FreeTasteDecision(allowed: true, reason: 'unlimited');

  static const denied = FreeTasteDecision(allowed: false, reason: 'denied');
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Static helper: free-taste mode per feature + evaluation.
///
/// All free-taste paths should route through this class to avoid ad-hoc
/// gate checks scattered across the codebase.
class FreeTaste {
  FreeTaste._();

  /// The free-taste mode for [feature], or null if the feature has no free
  /// taste (pure Pro/Ultra gate via [ProFeatures.allows]).
  static FreeTasteMode? mode(ProFeature feature) {
    switch (feature) {
      case ProFeature.batchCapture:
        return FreeTasteMode.softActionCap;
      case ProFeature.seriesGrab:
        return FreeTasteMode.softActionCap;
      case ProFeature.audioExtract:
        return FreeTasteMode.dailyQuota;
      case ProFeature.sendToPc:
        return FreeTasteMode.dailyQuota;
      case ProFeature.privateVault:
        return FreeTasteMode.inventoryCap;
      case ProFeature.videoLibrary:
        return FreeTasteMode.inventoryCap;
      default:
        return null; // hard lock — Pro+ only
    }
  }

  /// Evaluates whether [tier] can use [feature] with free-taste rules.
  ///
  /// - Pro+ tiers always return `allowed: true` (unlimited).
  /// - Free users are evaluated per [mode]:
  ///   - `hardLock` → denied
  ///   - `softActionCap` → `allowedCount = min(actionSize, limit)`
  ///   - `dailyQuota` → peeks or consumes [n] units from [FreeCapStore]
  ///   - `inventoryCap` → `allowed = inventoryCount < limit`
  ///
  /// [actionSize] is used only for `softActionCap`.
  /// [inventoryCount] is used only for `inventoryCap`.
  /// [n] is used only for `dailyQuota` (units to check/consume; default 1).
  /// [consume] for dailyQuota: when false, only checks remaining capacity;
  /// when true, atomically deducts [n] if available.
  static Future<FreeTasteDecision> evaluate({
    required ProFeature feature,
    required EntitlementTier tier,
    int? actionSize,
    int? inventoryCount,
    int n = 1,
    bool consume = true,
  }) async {
    // Pro+ unlimited (at or above the feature's minimum tier).
    if (tier.isAtLeast(ProFeatures.minimumTier[feature]!)) {
      return FreeTasteDecision.allowedUnlimited;
    }

    final tasteMode = mode(feature);
    if (tasteMode == null) {
      return FreeTasteDecision.denied; // hardLock
    }

    switch (tasteMode) {
      case FreeTasteMode.hardLock:
        return FreeTasteDecision.denied;

      case FreeTasteMode.softActionCap:
        final limit = _softActionLimit(feature);
        final size = actionSize ?? 0;
        if (size <= 0) return FreeTasteDecision.denied;
        final allowedCount = size < limit ? size : limit;
        return FreeTasteDecision(
          allowed: true,
          allowedCount: allowedCount,
          reason: 'taste',
        );

      case FreeTasteMode.dailyQuota:
        final kind = _toFreeCapKind(feature);
        if (kind == null) return FreeTasteDecision.denied;
        final units = n < 1 ? 1 : n;
        if (consume) {
          final ok = await FreeCapStore.tryConsume(kind, n: units);
          return FreeTasteDecision(
            allowed: ok,
            allowedCount: ok ? units : null,
            reason: ok ? 'taste' : 'denied',
          );
        }
        final rem = await FreeCapStore.remaining(kind);
        final ok = rem >= units;
        return FreeTasteDecision(
          allowed: ok,
          allowedCount: ok ? units : null,
          reason: ok ? 'taste' : 'denied',
        );

      case FreeTasteMode.inventoryCap:
        final limit = _inventoryLimit(feature);
        final count = inventoryCount ?? 0;
        return FreeTasteDecision(
          allowed: count < limit,
          reason: count < limit ? 'taste' : 'denied',
        );
    }
  }

  // -- internal mappings --

  static int _softActionLimit(ProFeature feature) {
    switch (feature) {
      case ProFeature.batchCapture:
        return ProFeatures.freeBatchCaptureItems;
      case ProFeature.seriesGrab:
        return ProFeatures.freeSeriesGrabEpisodes;
      default:
        return 0;
    }
  }

  static FreeCapKind? _toFreeCapKind(ProFeature feature) {
    switch (feature) {
      case ProFeature.audioExtract:
        return FreeCapKind.audioExtract;
      case ProFeature.sendToPc:
        return FreeCapKind.sendToPc;
      default:
        return null;
    }
  }

  static int _inventoryLimit(ProFeature feature) {
    switch (feature) {
      case ProFeature.privateVault:
        return ProFeatures.freeVaultItems;
      case ProFeature.videoLibrary:
        return ProFeatures.freeVideoLibraryItems;
      default:
        return 0;
    }
  }
}

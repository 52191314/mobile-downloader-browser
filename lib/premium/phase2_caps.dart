/// Phase 2 feature cap stubs — gate + cap wiring for deferred Pro features
/// that need non-trivial native implementation (Media3, Keystore, WebDAV).
///
/// Each method here is the "cap boundary" call site: gated by
/// [ProFeatures.allows], consumes from [FreeCapStore] or checks the
/// filesystem-level inventory cap, and delegates the actual feature work
/// to a TODO callback.  Callers get a single `canProceed` boolean so they
/// can decide UI flow (enqueue, show upsell, or snack refusal).
///
/// Design:
///   - Pure gate+cap logic only — no Flutter/UI imports.
///   - All methods accept the current [EntitlementTier] explicitly.
///   - Native-heavy work is marked `// TODO(P5): Media3 Transformer`.
///   - Features without concrete product rules (webdavBackup, duplicateFinder,
///     themePack, richNotifications) only have their gate checked via
///     [ProFeatures.allows] at their future call site; no stub needed here.
library;

import 'dart:io';

import 'free_cap_store.dart';
import 'pro_entitlement.dart';
import 'pro_features.dart';
import 'pro_upsell_sheet.dart';

/// Static helpers for Phase 2 feature caps that need daily or inventory limits.
///
/// These are not feature implementations — they are the **cap enforcement**
/// boundary. The actual feature work (Media3 transform, Keystore vault,
/// WebDAV upload, etc.) is deferred to dedicated implementation PRs.
class Phase2Caps {
  Phase2Caps._();

  // ---------------------------------------------------------------------------
  // P5 — Audio Extract (Media3 Transformer)
  // ---------------------------------------------------------------------------
  // Product rule: free 3 conversions/day via FreeCapStore; Pro+ unlimited.
  // Implementation tracked as TODO(P5): add Media3 Transformer pipeline.
  // Expected hook: after completed video download → "Extract audio" action.

  /// Attempts to consume one audio-extract slot for [tier].
  ///
  /// Returns `true` immediately (Pro+) or after consuming a daily free slot
  /// (free, if remaining > 0). Returns `false` when the free daily limit is
  /// exhausted.
  ///
  /// Caller should gate the UI action with [ProFeatures.allows] first, then
  /// call this before starting the actual transform.
  ///
  /// ```dart
  /// if (!ProFeatures.allows(ProFeature.audioExtract, tier)) {
  ///   // show upsell
  ///   return;
  /// }
  /// if (!await Phase2Caps.tryConsumeAudioExtract(tier)) {
  ///   // show "Daily limit reached" snack
  ///   return;
  /// }
  /// // TODO(P5): start Media3 Transformer pipeline
  /// ```
  static Future<bool> tryConsumeAudioExtract(EntitlementTier tier) async {
    if (tier.isAtLeastPro) return true; // Pro+ unlimited
    return FreeCapStore.tryConsume(FreeCapKind.audioExtract);
  }

  // ---------------------------------------------------------------------------
  // P7 — Private Vault (Keystore + filesystem inventory)
  // ---------------------------------------------------------------------------
  // Product rule: free ≤25 files in vault dir; delete frees slot.
  // Implementation tracked as TODO(P7): add Keystore key storage, local_auth
  // biometric unlock, recovery key UX, FLAG_SECURE vault UI.
  // Vault dir: <app-support>/vault/ + .nomedia file.

  /// Maximum inventory items for free users.
  static const int maxFreeVaultItems = ProFeatures.freeVaultItems; // 25

  /// Whether [currentCount] items in the vault are within free limits.
  ///
  /// Caller should enumerate the vault directory and pass the count here
  /// before allowing a new item to be added.  Pro+ users can always add.
  static bool vaultInventoryOk(int currentCount, EntitlementTier tier) {
    if (tier.isAtLeastPro) return true;
    return currentCount < maxFreeVaultItems;
  }

  /// Returns the number of regular files directly inside [vaultDir].
  /// Does **not** recurse into subdirectories (vault is flat).
  ///
  /// Future: will be replaced by VaultService.listFiles() that also checks
  /// Keystore-wrapped AES headers.
  static int countVaultFiles(Directory vaultDir) {
    try {
      return vaultDir.listSync().whereType<File>().length;
    } catch (_) {
      return 0;
    }
  }

  // ---------------------------------------------------------------------------
  // P10 — Rich Notifications
  // ---------------------------------------------------------------------------
  // Product rule: free keeps basic notifs; Pro+ gets rich (speed body,
  // convert/play actions).
  // Gate check via ProFeatures.allows(richNotifications, tier) at the
  // notification build site in DownloadNotificationService.
  // TODO(P10): enhance notification builder with speed/ETA body, action
  // buttons for convert (audio-extract) and play.

  // ---------------------------------------------------------------------------
  // P11 — WebDAV Backup
  // ---------------------------------------------------------------------------
  // Product rule: Pro+ only.
  // Gate check via ProFeatures.allows(webdavBackup, tier) at the Settings
  // tile and backup trigger.  Appears as an alternative to Drive when
  // kDriveSyncEnabled is false.
  // TODO(P11): WebDAV client (dav: URL, digest auth), folder pick,
  // incremental backup, restore from WebDAV.

  // ---------------------------------------------------------------------------
  // P12 — Duplicate Finder
  // ---------------------------------------------------------------------------
  // Product rule: Pro+ only.
  // Gate check via ProFeatures.allows(duplicateFinder, tier) at the
  // "Find duplicates" action in Queue or Settings.
  // TODO(P12): hash-based (xxhash) and name-similarity scan of queue +
  // completed downloads; merge/resolve UI.

  // ---------------------------------------------------------------------------
  // P13 — Theme & Accent Pack
  // ---------------------------------------------------------------------------
  // Product rule: system/OLED global stays free; accent pack is Pro+.
  // Gate check via ProFeatures.allows(themePack, tier) at the accent colour
  // picker in Settings → Appearance.
  // TODO(P13): implement accent colour palette (provider + preview +
  // persistence); gate the non-free colours behind Pro.
}

// ---------------------------------------------------------------------------
// Convenience helpers for common cap checks with the global entitlement.
// ---------------------------------------------------------------------------

/// Returns `true` if [feature] is allowed for the current user (using the
/// global [proUpsellEntitlement]).  Handles the null-safety for callers.
bool allowsForCurrentUser(ProFeature feature) {
  final ent = proUpsellEntitlement;
  return ent != null && ProFeatures.allows(feature, ent.tier);
}

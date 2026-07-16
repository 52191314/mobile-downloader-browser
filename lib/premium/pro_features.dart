/// Central feature-gate system for Aurora Pro.
///
/// Every feature that is behind a Pro gate is listed here as a [ProFeature]
/// enum value. Call [ProFeatures.allows] with the current `isPro` state to
/// determine access.
///
/// Canonical caps (adjustable **only** in this file):
///
/// | Cap | Free | Pro |
/// |-----|-----:|----:|
/// | `maxConcurrentDownloads` | 3 | 16 |
/// | `chunksPerTask` | 8 | 32 |
/// | Enabled remote filter lists | 2 | unlimited |
/// | Custom filter list URLs | 0 | unlimited |
/// | Tracker pack | no | yes |
/// | Tab groups | 1 | unlimited |
/// | Auto-host on groups | no | yes |
/// | Cosmetic rules | 10 | unlimited |
/// | Drive sync | no | yes |
/// | Scheduled auto-backup | no | yes |
/// | Manual backup/export | yes | yes |
/// | Proxy (HTTP+SOCKS5+auth) | no | yes |
/// | `wifiOnly` + advanced stall UI | no | yes |
/// | Per-site UA map | no | yes |
/// | Download rules / schedules / site profiles | no | yes |

// ignore_for_file: public_member_api_docs

// ---------------------------------------------------------------------------
// Feature enum
// ---------------------------------------------------------------------------

/// Every feature that can be gated behind Aurora Pro.
///
/// Naming convention: add new items in alphabetical order. Do not reorder
/// existing items — this enum is used for analytics/error strings.
enum ProFeature {
  /// Advanced stall/retry knobs: `wifiOnly`, `stallTimeout`,
  /// `minSpeedThreshold`, partial-merge threshold UI.
  advancedStall,

  /// Auto-host matching on tab groups (new tabs auto-join group by host).
  autoHostGroups,

  /// Custom filter list URL entry (add arbitrary remote filter sources).
  customFilterListUrl,

  /// Download rules & automation (auto-rename, route by host/type, etc.).
  downloadRules,

  /// Google Drive connection + auto-sync.
  driveSync,

  /// More than [freeFilterListSlots] enabled remote filter lists.
  extraFilterLists,

  /// > [maxConcurrentFree] concurrent downloads.
  higherConcurrency,

  /// > [chunksPerTaskFree] chunks per task.
  higherChunks,

  /// Per-site browser/download profiles.
  perSiteUA,

  /// HTTP + SOCKS5 proxy with credential fields.
  proxy,

  /// Scheduled auto-backup (interval + restore UI).
  scheduledAutoBackup,

  /// Scheduled / night-mode download queue.
  scheduledDownloads,

  /// Per-site browser/download profiles.
  siteProfiles,

  /// EasyPrivacy / tracker blocking pack.
  trackerPack,

  /// > [maxFreeCosmeticRules] cosmetic rules.
  unlimitedCosmeticRules,

  /// > [maxFreeTabGroups] tab groups.
  unlimitedTabGroups,

  /// Wi‑Fi only toggle + advanced stall thresholds UI.
  wifiOnly,
}

// ---------------------------------------------------------------------------
// Cap constants
// ---------------------------------------------------------------------------

/// Static helper: feature gate matrix.
class ProFeatures {
  ProFeatures._();

  // -- Download limits --

  static const int maxConcurrentFree = 3;
  static const int maxConcurrentPro = 16;
  static const int chunksPerTaskFree = 8;
  static const int chunksPerTaskPro = 32;

  // -- Adblock limits --

  /// Maximum number of enabled remote filter lists for free users.
  static const int freeFilterListSlots = 2;

  // -- Tab group limits --

  static const int maxFreeTabGroups = 1;

  // -- Cosmetic rule limits --

  static const int maxFreeCosmeticRules = 10;

  // -------------------------------------------------------------------------
  // Gate check
  // -------------------------------------------------------------------------

  /// Returns `true` if [feature] is allowed given the user's Pro status.
  ///
  /// Pro users have access to everything. Free users are restricted.
  static bool allows(ProFeature feature, bool isPro) {
    if (isPro) return true;

    // Free tier: none of the gated features are allowed.
    switch (feature) {
      case ProFeature.extraFilterLists:
      case ProFeature.customFilterListUrl:
      case ProFeature.trackerPack:
      case ProFeature.higherConcurrency:
      case ProFeature.higherChunks:
      case ProFeature.unlimitedTabGroups:
      case ProFeature.autoHostGroups:
      case ProFeature.unlimitedCosmeticRules:
      case ProFeature.driveSync:
      case ProFeature.scheduledAutoBackup:
      case ProFeature.proxy:
      case ProFeature.wifiOnly:
      case ProFeature.advancedStall:
      case ProFeature.perSiteUA:
      case ProFeature.downloadRules:
      case ProFeature.siteProfiles:
      case ProFeature.scheduledDownloads:
        return false;
    }
  }

  /// Returns the human-readable display name for a Pro feature, used in
  /// upsell UI and Settings → Aurora Pro.
  static String displayName(ProFeature feature) {
    switch (feature) {
      case ProFeature.extraFilterLists:
        return 'Extra filter lists';
      case ProFeature.customFilterListUrl:
        return 'Custom filter list URLs';
      case ProFeature.trackerPack:
        return 'Tracker blocking pack';
      case ProFeature.higherConcurrency:
        return 'Higher concurrent downloads';
      case ProFeature.higherChunks:
        return 'More chunks per task';
      case ProFeature.unlimitedTabGroups:
        return 'Unlimited tab groups';
      case ProFeature.autoHostGroups:
        return 'Auto-host tab groups';
      case ProFeature.unlimitedCosmeticRules:
        return 'Unlimited cosmetic rules';
      case ProFeature.driveSync:
        return 'Google Drive sync';
      case ProFeature.scheduledAutoBackup:
        return 'Scheduled auto-backup';
      case ProFeature.proxy:
        return 'HTTP/SOCKS5 proxy';
      case ProFeature.wifiOnly:
        return 'Wi‑Fi only downloads';
      case ProFeature.advancedStall:
        return 'Advanced stall controls';
      case ProFeature.perSiteUA:
        return 'Per-site User‑Agent';
      case ProFeature.downloadRules:
        return 'Download rules & automation';
      case ProFeature.siteProfiles:
        return 'Per-site profiles';
      case ProFeature.scheduledDownloads:
        return 'Scheduled downloads';
    }
  }
}

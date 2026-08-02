/// Central feature-gate system for Aurora Pro / Ultra.
///
/// Every feature that is behind a Pro/Ultra gate is listed here as a
/// [ProFeature] enum value. Call [ProFeatures.allows] with the current
/// [EntitlementTier] to determine access.
///
/// Canonical caps (adjustable **only** in this file):
///
/// | Cap | Free | Pro | Ultra |
/// |-----|-----:|----:|------:|
/// | `maxConcurrentDownloads` | 3 | 16 | 64 |
/// | `chunksPerTask` | 8 | 32 | 64 |
/// | HLS segments | 4 | 8 | 64 (unlimited) |
/// | Enabled remote filter lists | 3 | unlimited | unlimited |
/// | Custom filter list URLs | 0 | unlimited | unlimited |
/// | Tracker pack | no | yes | yes |
/// | Tab groups | 3 | unlimited | unlimited |
/// | Auto-host on groups | no | yes | yes |
/// | Cosmetic rules | 25 | unlimited | unlimited |
/// | ~~Drive sync~~ | — | — | — | **feature removed; see [ProFeature.driveSync]** |
/// | Scheduled auto-backup | no | yes | yes |
/// | Manual backup/export | yes | yes | yes |
/// | Proxy (HTTP+SOCKS5+auth) | no | yes | yes |
/// | `wifiOnly` + advanced stall UI | no | yes | yes |
/// | Per-site UA map | no | yes | yes |
/// | Download rules / schedules / site profiles | no | yes | yes |

// ignore_for_file: public_member_api_docs
// ignore_for_file: dangling_library_doc_comments

import 'pro_entitlement.dart';

// ---------------------------------------------------------------------------
// Feature enum
// ---------------------------------------------------------------------------

/// Every feature that can be gated behind Aurora Pro / Ultra.
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
  ///
  /// **Feature removed 2026-07-27** — the Drive implementation and its four
  /// packages were deleted (see `play_review_audit_2026-07-27.md` §0.1). This
  /// enum entry, its [ProFeatures.minimumTier] mapping, and its display name are
  /// retained only because the enum's append order is frozen for analytics and
  /// error strings. Nothing constructs or queries it. Do not treat a `true` from
  /// [ProFeatures.allows] here as meaning Drive sync exists.
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

  /// Extended/curated tracker lists & auto-updates pack.
  trackerPack,

  /// > [maxFreeCosmeticRules] cosmetic rules.
  unlimitedCosmeticRules,

  /// > [maxFreeTabGroups] tab groups.
  unlimitedTabGroups,

  /// Wi‑Fi only toggle + advanced stall thresholds UI.
  wifiOnly,

  // --- Phase 1 heroes (append order frozen) ---

  /// Grab All / batch capture. Free: per-action size ≤5 (soft first-5),
  /// unlimited such actions. Pro+: unlimited.
  batchCapture,

  /// Pro turbo: uses tier-max concurrency/chunks automatically.
  /// Free: fixed policy from user settings. Host-adaptive tuning is future work.
  turboEngine,

  /// Dead-link auto revival. Free: manual refresh only. Pro+: auto on.
  deadLinkRevival,

  /// Send to PC (LAN). Free: 20 files/day. Pro+: unlimited.
  sendToPc,

  // --- Phase 2 fillers ---

  /// Series auto-grab. Free: ≤5 episodes per grab action. Pro+: unlimited.
  seriesGrab,

  /// Audio extract (Media3). Free: 3 conversions/day. Pro+: unlimited.
  audioExtract,

  /// Private vault. Free: ≤25 items inventory. Pro+: unlimited.
  privateVault,

  /// Clipboard auto-catch on resume. Free: no listener (manual paste free).
  /// Pro+: auto prompt on app resume.
  clipboardCatch,

  /// Rich notifications. Free: basic notifs. Pro+: rich.
  richNotifications,

  /// WebDAV backup. Pro+ only.
  webdavBackup,

  /// Duplicate finder. Pro+ only.
  duplicateFinder,

  /// Theme pack (accent pack). Free: system/OLED global. Pro+: accent pack.
  themePack,

  /// No-nag: Pro+ suppress Pro-tier upsells.
  noNag,

  // --- Phase 3 Ultra ---

  /// Server-grade engine caps (64/64). Ultra only; Pro stays 16/32.
  serverGradeEngine,

  /// FFmpeg suite. Ultra only.
  ffmpegSuite,

  /// Ultra extras bundle. Ultra only.
  ultraExtras,

  // --- Phase 4 Ultra depth (appended in their phase PRs) ---

  /// Watcher. Ultra only.
  watcher,

  /// Automation API (localhost). Ultra only.
  automationApi,

  /// Vault sync. Ultra only.
  vaultSync,

  /// Saved videos + watch history (the Videos subpages of Favorites and
  /// History). Free: [ProFeatures.freeVideoLibraryItems] entries in each list.
  /// Pro+: unlimited. Page bookmarks and page history stay free and uncapped.
  videoLibrary,
}

// ---------------------------------------------------------------------------
// Cap constants
// ---------------------------------------------------------------------------

// Static helper: feature gate matrix + tier-aware caps.
class ProFeatures {
  /// Daily Drive upload file cap for Free tier.
  static const int driveSyncDailyLimitFree = 15;

  /// Daily Drive upload file cap for Pro tier.
  static const int driveSyncDailyLimitPro = 50;

  /// Daily Drive upload file cap for Ultra tier.
  static const int driveSyncDailyLimitUltra = 1000;

  /// Gets daily Google Drive upload cap for a given tier.
  static int driveSyncDailyLimit(EntitlementTier tier) {
    switch (tier) {
      case EntitlementTier.free:
        return driveSyncDailyLimitFree;
      case EntitlementTier.pro:
        return driveSyncDailyLimitPro;
      case EntitlementTier.ultra:
        return driveSyncDailyLimitUltra;
    }
  }
  ProFeatures._();

  // -- Download limits (tier-aware) --

  static const int maxConcurrentFree = 3;
  static const int maxConcurrentPro = 16;
  static const int maxConcurrentUltra = 64;

  static const int chunksPerTaskFree = 8;
  static const int chunksPerTaskPro = 32;
  static const int chunksPerTaskUltra = 64;

  /// HLS concurrent segment cap by tier: Free 4, Pro 8, Ultra 64 (unlimited).
  static const int hlsSegmentCapFree = 4;
  static const int hlsSegmentCapPro = 8;
  static const int hlsSegmentCapUltra = 64;

  // -- Adblock limits --

  /// Maximum number of enabled remote filter lists for free users.
  static const int freeFilterListSlots = 3;

  // -- Tab group limits --

  static const int maxFreeTabGroups = 3;

  // -- Cosmetic rule limits --

  static const int maxFreeCosmeticRules = 25;

  // -- Free taste caps (Phase 1/2) --

  /// Batch capture: free allows up to this many selected items per action
  /// (soft first-N enqueue + upsell beyond).
  static const int freeBatchCaptureItems = 5;

  /// Series grab: free allows up to this many episodes per grab action.
  static const int freeSeriesGrabEpisodes = 5;

  /// Audio extract: free conversions per local day.
  static const int freeAudioExtractPerDay = 3;

  /// Send to PC: free files per local day.
  static const int freeSendToPcPerDay = 20;

  /// Private vault: free inventory item cap.
  static const int freeVaultItems = 25;

  /// Saved videos / watch history: free inventory cap, applied to each list
  /// separately. Generous enough that a casual user never meets it, small
  /// enough that anyone actually collecting videos does.
  static const int freeVideoLibraryItems = 10;

  // -- Pure helpers for free-taste cap decisions (mirror batch pattern) --

  /// Returns `true` if a batch of [selectedCount] items is within free limits
  /// for batch capture (stateless — no persistence needed).
  static bool freeBatchAllows(int selectedCount) =>
      selectedCount <= freeBatchCaptureItems;

  /// Returns how many items to enqueue when a free user selects [selectedCount]
  /// items for batch download (soft first-N: enqueue N, upsell beyond).
  static int freeBatchEnqueueCount(int selectedCount) =>
      selectedCount < freeBatchCaptureItems
          ? selectedCount
          : freeBatchCaptureItems;

  /// Returns `true` if a grab action of [episodeCount] episodes is within free
  /// limits for series grab (stateless — no per-series lifetime persistence).
  static bool freeSeriesGrabAllows(int episodeCount) =>
      episodeCount <= freeSeriesGrabEpisodes;

  /// Returns how many episodes to enqueue when a free user triggers a grab
  /// action of [episodeCount] episodes (soft first-N).
  static int freeSeriesGrabEnqueueCount(int episodeCount) =>
      episodeCount < freeSeriesGrabEpisodes
          ? episodeCount
          : freeSeriesGrabEpisodes;

  // -------------------------------------------------------------------------
  // Minimum tier per feature
  // -------------------------------------------------------------------------

  /// The minimum [EntitlementTier] required to use [feature].
  static const Map<ProFeature, EntitlementTier> minimumTier = {
    ProFeature.advancedStall: EntitlementTier.pro,
    ProFeature.autoHostGroups: EntitlementTier.pro,
    ProFeature.customFilterListUrl: EntitlementTier.pro,
    ProFeature.downloadRules: EntitlementTier.pro,
    ProFeature.driveSync: EntitlementTier.pro,
    ProFeature.extraFilterLists: EntitlementTier.pro,
    ProFeature.higherConcurrency: EntitlementTier.pro,
    ProFeature.higherChunks: EntitlementTier.pro,
    ProFeature.perSiteUA: EntitlementTier.pro,
    ProFeature.proxy: EntitlementTier.pro,
    ProFeature.scheduledAutoBackup: EntitlementTier.pro,
    ProFeature.scheduledDownloads: EntitlementTier.pro,
    ProFeature.siteProfiles: EntitlementTier.pro,
    ProFeature.trackerPack: EntitlementTier.pro,
    ProFeature.unlimitedCosmeticRules: EntitlementTier.pro,
    ProFeature.unlimitedTabGroups: EntitlementTier.pro,
    ProFeature.wifiOnly: EntitlementTier.pro,
    ProFeature.batchCapture: EntitlementTier.pro,
    ProFeature.turboEngine: EntitlementTier.pro,
    ProFeature.deadLinkRevival: EntitlementTier.pro,
    ProFeature.sendToPc: EntitlementTier.pro,
    ProFeature.seriesGrab: EntitlementTier.pro,
    ProFeature.audioExtract: EntitlementTier.pro,
    ProFeature.privateVault: EntitlementTier.pro,
    ProFeature.clipboardCatch: EntitlementTier.pro,
    ProFeature.richNotifications: EntitlementTier.pro,
    ProFeature.webdavBackup: EntitlementTier.pro,
    ProFeature.duplicateFinder: EntitlementTier.pro,
    ProFeature.themePack: EntitlementTier.pro,
    ProFeature.noNag: EntitlementTier.pro,
    ProFeature.serverGradeEngine: EntitlementTier.ultra,
    ProFeature.ffmpegSuite: EntitlementTier.ultra,
    ProFeature.ultraExtras: EntitlementTier.ultra,
    ProFeature.watcher: EntitlementTier.ultra,
    ProFeature.automationApi: EntitlementTier.ultra,
    ProFeature.vaultSync: EntitlementTier.ultra,
    ProFeature.videoLibrary: EntitlementTier.pro,
  };

  // -------------------------------------------------------------------------
  // Gate checks
  // -------------------------------------------------------------------------

  /// Returns `true` if [feature] is allowed given the user's [tier].
  static bool allows(ProFeature feature, EntitlementTier tier) {
    final min = minimumTier[feature]!;
    return tier.isAtLeast(min);
  }

  /// Returns the human-readable display name for a Pro/Ultra feature, used in
  /// upsell UI and Settings → Aurora Pro.
  static String displayName(ProFeature feature) {
    switch (feature) {
      case ProFeature.extraFilterLists:
        return 'Extra filter lists';
      case ProFeature.customFilterListUrl:
        return 'Custom filter list URLs';
      case ProFeature.trackerPack:
        return 'Extended tracker lists & auto-updates';
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
      case ProFeature.batchCapture:
        return 'Batch / Grab All capture';
      case ProFeature.turboEngine:
        return 'Turbo maximum performance';
      case ProFeature.deadLinkRevival:
        return 'Auto dead-link revival';
      case ProFeature.sendToPc:
        return 'Send to PC (LAN)';
      case ProFeature.seriesGrab:
        return 'Series auto-grab';
      case ProFeature.audioExtract:
        return 'Audio extract';
      case ProFeature.privateVault:
        return 'Private vault';
      case ProFeature.clipboardCatch:
        return 'Clipboard URL catch';
      case ProFeature.richNotifications:
        return 'Rich notifications';
      case ProFeature.webdavBackup:
        return 'WebDAV backup';
      case ProFeature.duplicateFinder:
        return 'Duplicate finder';
      case ProFeature.themePack:
        return 'Theme & accent pack';
      case ProFeature.noNag:
        return 'No upsell nags';
      case ProFeature.serverGradeEngine:
        return 'Server-grade engine (64/64)';
      case ProFeature.ffmpegSuite:
        return 'FFmpeg media suite';
      case ProFeature.ultraExtras:
        return 'Ultra extras';
      case ProFeature.watcher:
        return 'Folder watcher';
      case ProFeature.automationApi:
        return 'Automation API';
      case ProFeature.vaultSync:
        return 'Vault sync';
      case ProFeature.videoLibrary:
        return 'Saved videos & watch history';
    }
  }

  /// Returns the badge label for a feature ('PRO' or 'ULTRA').
  static String tierBadge(ProFeature feature) =>
      minimumTier[feature] == EntitlementTier.ultra ? 'ULTRA' : 'PRO';

  // -------------------------------------------------------------------------
  // Tier-aware cap helpers
  // -------------------------------------------------------------------------

  /// Max concurrent downloads allowed for [tier].
  static int maxConcurrentFor(EntitlementTier tier) {
    if (tier.isUltra) return maxConcurrentUltra;
    if (tier.isAtLeastPro) return maxConcurrentPro;
    return maxConcurrentFree;
  }

  /// Max chunks per task allowed for [tier].
  static int chunksFor(EntitlementTier tier) {
    if (tier.isUltra) return chunksPerTaskUltra;
    if (tier.isAtLeastPro) return chunksPerTaskPro;
    return chunksPerTaskFree;
  }

  /// HLS concurrent segment cap for [tier].
  static int hlsSegmentCapFor(EntitlementTier tier) {
    if (tier.isUltra) return hlsSegmentCapUltra;
    if (tier.isAtLeastPro) return hlsSegmentCapPro;
    return hlsSegmentCapFree;
  }

  // -------------------------------------------------------------------------
  // Deprecated back-compat
  // -------------------------------------------------------------------------

  /// Returns `true` if [feature] is allowed given the legacy boolean [isPro].
  @Deprecated('Use allows(feature, tier)')
  static bool allowsBool(ProFeature feature, bool isPro) => allows(
        feature,
        isPro ? EntitlementTier.pro : EntitlementTier.free,
      );
}

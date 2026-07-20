import 'package:aurora_downloader/premium/pro_entitlement.dart';
import 'package:aurora_downloader/premium/pro_features.dart';

/// Turbo engine policy (P3).
///
/// Free users get a **fixed** concurrency/chunk policy derived from their
/// Settings sliders (clamped to the free tier cap). Pro+ users with
/// [ProFeature.turboEngine] unlocked get an **adaptive** policy that drives
/// the engine toward the tier maximum — useful on fast Wi-Fi where the
/// user's conservative slider would otherwise leave bandwidth on the table.
///
/// The policy never exceeds the engine hard ceilings
/// ([DownloadQueue.engineHardMaxConcurrent] / [DownloadQueue.engineHardMaxChunks])
/// or the tier cap; it only raises the *effective* value when the user's
/// setting is below the tier max.
class TurboPolicy {
  TurboPolicy._();

  /// Whether turbo (adaptive) mode is active for [tier].
  static bool isActive(EntitlementTier tier) =>
      ProFeatures.allows(ProFeature.turboEngine, tier);

  /// Resolves the effective concurrency for [tier] given the user's
  /// [userSetting] (already clamped to the tier cap by the caller).
  ///
  /// When turbo is active, the engine uses the tier maximum instead of the
  /// (possibly conservative) user setting. Otherwise the user setting stands.
  static int resolveConcurrent(int userSetting, EntitlementTier tier) {
    if (!isActive(tier)) return userSetting;
    return ProFeatures.maxConcurrentFor(tier);
  }

  /// Resolves the effective chunk count for [tier] given the user's
  /// [userSetting] (already clamped to the tier cap by the caller).
  static int resolveChunks(int userSetting, EntitlementTier tier) {
    if (!isActive(tier)) return userSetting;
    return ProFeatures.chunksFor(tier);
  }
}

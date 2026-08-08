/// Compile-time distribution channel for Aurora builds.
///
/// Pass at build time:
/// ```bash
/// flutter build apk --dart-define=AURORA_BUILD_CHANNEL=play
/// flutter build apk --dart-define=AURORA_BUILD_CHANNEL=github
/// ```
///
/// Default is `github` so open-source / sideload APKs never ship a billing
/// client path by accident.
///
/// OSS edition note: **release** builds on this channel default the effective
/// entitlement tier to Ultra — everything is unlocked, because there is no
/// billing path to sell into (see `ProEntitlement.tier`). Debug/profile builds
/// keep the purchase-derived tier so free-tier flows stay testable.
class BuildChannel {
  BuildChannel._();

  static const String raw = String.fromEnvironment(
    'AURORA_BUILD_CHANNEL',
    defaultValue: 'github',
  );

  /// Google Play Store distributed build (Play Billing required for Pro).
  static bool get isPlay => raw.toLowerCase() == 'play';

  /// GitHub / F-Droid-style / sideload build (no Play Billing).
  static bool get isGithub => !isPlay;

  static String get label => isPlay ? 'play' : 'github';
}

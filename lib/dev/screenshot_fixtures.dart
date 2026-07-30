/// Staged app state for Play Store screenshot capture.
///
/// Enabled with:
/// ```
/// flutter run --profile --dart-define=AURORA_SCREENSHOT_MODE=true
/// ```
///
/// **Profile mode, not release.** [ProEntitlement.setDebugTier] and
/// [DownloadQueue.seedDisplayOnlyTasks] are both no-ops when `kReleaseMode` is
/// true, so a release build cannot be seeded even if the define leaks in.
/// Profile also drops the debug banner and runs at near-release speed.
///
/// ## What this may and may not do
///
/// Play requires store screenshots to represent the actual app. Seeding the
/// **real** UI with staged content — filenames, sizes, progress values — is
/// ordinary practice and is what this file does. What it must never do is
/// fabricate a screen, imply a feature that does not exist, or show throughput
/// the engine cannot actually reach. Keep [_seededSpeeds] plausible.
///
/// Capture recipe lives in `docs/play_store_listing.md`.
library;

import 'package:flutter/foundation.dart';

import '../downloader/download_queue.dart';
import '../downloader/models.dart';
import '../premium/pro_entitlement.dart';

/// True when this build was compiled for screenshot capture.
///
/// Matches the existing `AURORA_*` define convention (see
/// `OnboardingExperiment.compileTimeFlag`, `PlayBillingService`).
const bool kScreenshotMode =
    bool.fromEnvironment('AURORA_SCREENSHOT_MODE');

/// Which shot is being staged. Some fixtures are mutually exclusive — the Pro
/// badges in Settings only render for a *non*-Pro account, while the Queue shot
/// needs Ultra to show more than three concurrent downloads.
///
/// Select with `--dart-define=AURORA_SCREENSHOT_SHOT=settings`.
enum ScreenshotShot {
  /// Default: Ultra tier, full queue. Shots 1, 2, 4, 6.
  queue,

  /// Free tier so `Pro` badges render on Rules and Schedule. Shot 5.
  settings,
}

class ScreenshotFixtures {
  ScreenshotFixtures._();

  static const String _shotName =
      String.fromEnvironment('AURORA_SCREENSHOT_SHOT', defaultValue: 'queue');

  static ScreenshotShot get shot => _shotName == 'settings'
      ? ScreenshotShot.settings
      : ScreenshotShot.queue;

  /// Realistic multi-connection throughput. Do not inflate these — a speed the
  /// engine cannot reach turns a staged screenshot into a false claim.
  static const List<double> _seededSpeeds = [
    8.4 * 1024 * 1024,
    6.1 * 1024 * 1024,
    11.2 * 1024 * 1024,
    4.7 * 1024 * 1024,
  ];

  /// Applies every fixture. Safe to call unconditionally — returns immediately
  /// unless the build was compiled with `AURORA_SCREENSHOT_MODE=true`.
  static void apply({
    required DownloadQueue queue,
    required ProEntitlement entitlement,
  }) {
    if (!kScreenshotMode || kReleaseMode) return;

    entitlement.setDebugTier(
      shot == ScreenshotShot.settings
          ? EntitlementTier.free
          : EntitlementTier.ultra,
    );

    queue.seedDisplayOnlyTasks(_tasks());

    debugPrint(
      '[ScreenshotFixtures] staged shot=${shot.name} '
      'tier=${entitlement.tier.name} tasks=${_tasks().length}',
    );
  }

  static List<DownloadTask> _tasks() {
    final now = DateTime.now();
    return [
      _active(
        id: 'shot-1',
        name: 'Big_Buck_Bunny_1080p_h264.mp4',
        totalBytes: 691 * 1024 * 1024,
        fraction: 0.34,
        speedIndex: 0,
        totalParts: 32,
        createdAt: now.subtract(const Duration(minutes: 4)),
      ),
      _active(
        id: 'shot-2',
        name: 'Sintel_2160p_master.mkv',
        totalBytes: 1240 * 1024 * 1024,
        fraction: 0.71,
        speedIndex: 1,
        totalParts: 32,
        createdAt: now.subtract(const Duration(minutes: 11)),
      ),
      _active(
        id: 'shot-3',
        name: 'Tears_of_Steel_1080p.mp4',
        totalBytes: 372 * 1024 * 1024,
        fraction: 0.18,
        speedIndex: 2,
        totalParts: 16,
        createdAt: now.subtract(const Duration(minutes: 1)),
      ),
      _active(
        id: 'shot-4',
        name: 'Cosmos_Laundromat_720p.webm',
        totalBytes: 148 * 1024 * 1024,
        fraction: 0.86,
        speedIndex: 3,
        totalParts: 16,
        createdAt: now.subtract(const Duration(minutes: 7)),
      ),
      _done(
        id: 'shot-5',
        name: 'Elephants_Dream_1080p.mp4',
        totalBytes: 218 * 1024 * 1024,
        createdAt: now.subtract(const Duration(minutes: 22)),
      ),
      _done(
        id: 'shot-6',
        name: 'reference_manual.pdf',
        totalBytes: 12 * 1024 * 1024,
        createdAt: now.subtract(const Duration(minutes: 38)),
      ),
    ];
  }

  static DownloadTask _active({
    required String id,
    required String name,
    required int totalBytes,
    required double fraction,
    required int speedIndex,
    required int totalParts,
    required DateTime createdAt,
  }) {
    return DownloadTask(
      id: id,
      url: 'https://example.invalid/$name',
      savePath: '/storage/emulated/0/Download/Aurora/$name',
      tempDir: '/data/local/tmp/aurora-screenshot',
      state: DownloadState.downloading,
      totalBytes: totalBytes,
      downloadedBytes: (totalBytes * fraction).round(),
      totalParts: totalParts,
      completedParts: (totalParts * fraction).round(),
      speed: _seededSpeeds[speedIndex % _seededSpeeds.length],
      createdAt: createdAt,
    );
  }

  static DownloadTask _done({
    required String id,
    required String name,
    required int totalBytes,
    required DateTime createdAt,
  }) {
    return DownloadTask(
      id: id,
      url: 'https://example.invalid/$name',
      savePath: '/storage/emulated/0/Download/Aurora/$name',
      tempDir: '/data/local/tmp/aurora-screenshot',
      state: DownloadState.completed,
      totalBytes: totalBytes,
      downloadedBytes: totalBytes,
      createdAt: createdAt,
    );
  }
}

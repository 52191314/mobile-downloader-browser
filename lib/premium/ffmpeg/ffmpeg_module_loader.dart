/// On-demand feature module loader — channel-aware FFmpeg loading.
///
/// Google Play (AAB) builds use dynamic feature delivery to defer the FFmpeg
/// native libraries (~8–12 MB) until the user's first Ultra-gated use.
/// GitHub / sideload (fat APK) builds always have FFmpeg linked — no download.
///
/// Usage:
/// ```dart
/// final loader = FeatureModuleLoader.instance;
/// final status = await loader.ensureInstalled('ffmpeg');
/// if (status == FeatureModuleStatus.ready) {
///   await FfmpegService.instance.probeVersion();
/// }
/// ```
///
/// See: `docs/play_on_demand_modules_plan.md`
library;

import 'dart:async';

import '../build_channel.dart';

// ---------------------------------------------------------------------------
// Status enum
// ---------------------------------------------------------------------------

/// Current state of an on-demand feature module.
///
/// Ordering: `notNeeded` → `missing` → `downloading` → `ready` or `failed`.
enum FeatureModuleStatus {
  /// Module is not needed on this channel (e.g. GitHub fat APK).
  notNeeded,

  /// Module is required but not yet installed (Play on-demand).
  missing,

  /// Module is currently being downloaded.
  downloading,

  /// Module is installed and available for use.
  ready,

  /// Module installation failed (network, Play Store, or platform error).
  failed,
}

// ---------------------------------------------------------------------------
// Progress callback
// ---------------------------------------------------------------------------

/// Progress callback for module download, 0.0–1.0.
typedef ModuleProgressCallback = void Function(double progress);

// ---------------------------------------------------------------------------
// Abstract loader
// ---------------------------------------------------------------------------

/// Channel-aware loader for optional Play Feature Delivery modules.
///
/// Two implementations:
/// - [GitHubModuleLoader] — always returns `ready` / `notNeeded`.
/// - [PlayModuleLoader] — uses Play Core [SplitInstallManager] under the hood.
///
/// The plan suggests a three-method API:
/// ```dart
///   FeatureModuleStatus statusFor(String moduleId);
///   Stream<FeatureModuleStatus> watch(String moduleId);
///   Future<bool> ensureInstalled(String moduleId, {ModuleProgressCallback? onProgress});
/// ```
abstract class FeatureModuleLoader {
  FeatureModuleLoader._();

  /// Singleton instance, auto-resolved by build channel.
  static FeatureModuleLoader get instance => _instance;
  static late final FeatureModuleLoader _instance = _create();

  static FeatureModuleLoader _create() {
    if (BuildChannel.isPlay) {
      return PlayModuleLoader();
    }
    return GitHubModuleLoader();
  }

  /// Returns the current status of [moduleId] without starting any download.
  FeatureModuleStatus statusFor(String moduleId);

  /// A broadcast stream that emits status changes for [moduleId].
  Stream<FeatureModuleStatus> watch(String moduleId);

  /// Ensures [moduleId] is installed. Returns `true` if the module is ready.
  ///
  /// For GitHub builds this returns `true` synchronously.
  /// For Play builds this triggers a [SplitInstallManager] deferred install
  /// if the module is missing, emitting progress via [onProgress].
  Future<bool> ensureInstalled(
    String moduleId, {
    ModuleProgressCallback? onProgress,
  });

  /// Human-readable label for [moduleId], shown in download confirmation UI.
  String displayName(String moduleId);

  /// Estimated download size for [moduleId] in bytes, or null if unknown.
  int? estimatedSizeBytes(String moduleId);
}

// ---------------------------------------------------------------------------
// GitHub / sideload — always ready
// ---------------------------------------------------------------------------

/// GitHub / F-Droid / sideload builds always ship FFmpeg in the fat APK.
/// No download needed — the module is always ready.
class GitHubModuleLoader extends FeatureModuleLoader {
  GitHubModuleLoader() : super._();

  static final _readyStream = Stream<FeatureModuleStatus>.value(
    FeatureModuleStatus.ready,
  );

  @override
  FeatureModuleStatus statusFor(String moduleId) => FeatureModuleStatus.ready;

  @override
  Stream<FeatureModuleStatus> watch(String moduleId) => _readyStream;

  @override
  Future<bool> ensureInstalled(
    String moduleId, {
    ModuleProgressCallback? onProgress,
  }) async {
    // Always ready — no download required.
    return true;
  }

  @override
  String displayName(String moduleId) {
    switch (moduleId) {
      case 'ffmpeg':
        return 'FFmpeg media tools';
      default:
        return moduleId;
    }
  }

  @override
  int? estimatedSizeBytes(String moduleId) => null; // Always included.
}

// ---------------------------------------------------------------------------
// Play Store — on-demand via Play Feature Delivery
// ---------------------------------------------------------------------------

/// Play Store builds defer the FFmpeg native library to an on-demand
/// dynamic feature module. This loader uses Play Core's [SplitInstallManager]
/// to download and install the module on first Ultra-gated use.
///
/// **Current status:** Stub ready for Play Core integration.
/// Full implementation requires:
/// 1. Dynamic feature module `:ffmpeg` in Gradle (PR-C).
/// 2. Dart deferred import split of ffmpeg-kit dependent code (PR-C).
/// 3. Play Core dependency in `build.gradle.kts`.
class PlayModuleLoader extends FeatureModuleLoader {
  PlayModuleLoader() : super._();

  final _statusController = StreamController<FeatureModuleStatus>.broadcast();
  final Map<String, FeatureModuleStatus> _cache = {};
  bool _initialized = false;

  FeatureModuleStatus _resolveStatus(String moduleId) {
    return _cache[moduleId] ?? FeatureModuleStatus.missing;
  }

  @override
  FeatureModuleStatus statusFor(String moduleId) {
    return _resolveStatus(moduleId);
  }

  @override
  Stream<FeatureModuleStatus> watch(String moduleId) {
    return _statusController.stream;
  }

  @override
  Future<bool> ensureInstalled(
    String moduleId, {
    ModuleProgressCallback? onProgress,
  }) async {
    final current = _resolveStatus(moduleId);
    if (current == FeatureModuleStatus.ready ||
        current == FeatureModuleStatus.notNeeded) {
      return true;
    }
    if (current == FeatureModuleStatus.downloading) {
      // Already in progress — wait for the stream to resolve.
      return _waitForModule(moduleId);
    }

    _cache[moduleId] = FeatureModuleStatus.downloading;
    _emit(moduleId, FeatureModuleStatus.downloading);

    try {
      // --- Play Core SplitInstallManager call goes here (PR-C) ---
      // This is a stub that simulates the async install flow.
      // The real implementation will:
      //   1. Create a SplitInstallManager
      //   2. Create a SplitInstallRequest for moduleId
      //   3. Await the install with progress listener
      //   4. Handle state changes (downloading, installed, failed)
      //
      // See: https://developer.android.com/guide/playcore/feature-delivery/on-demand
      //
      // Pseudocode:
      //   final manager = SplitInstallManager.create(context);
      //   final request = SplitInstallRequest.newBuilder()
      //       .addModule(moduleId)
      //       .build();
      //   final task = manager.startInstall(request);
      //   task.addListener(() {
      //     final state = task.installState;
      //     onProgress?.call(state.bytesDownloaded / state.totalBytes);
      //   });
      //   await task; // or handle failures
      //
      // For now, simulate a successful fast-path so Studio can be tested
      // on Play internal track with FFmpeg already in the base APK.

      // TODO(PR-C): Replace with real Play Core SplitInstallManager call.
      await Future.delayed(const Duration(milliseconds: 100));

      _cache[moduleId] = FeatureModuleStatus.ready;
      _emit(moduleId, FeatureModuleStatus.ready);
      return true;
    } catch (e) {
      _cache[moduleId] = FeatureModuleStatus.failed;
      _emit(moduleId, FeatureModuleStatus.failed);
      return false;
    }
  }

  /// Waits for the module stream to resolve to a terminal state.
  Future<bool> _waitForModule(String moduleId) async {
    final completer = Completer<bool>();
    final sub = _statusController.stream.listen((status) {
      if (status == FeatureModuleStatus.ready) {
        completer.complete(true);
      } else if (status == FeatureModuleStatus.failed) {
        completer.complete(false);
      }
    });
    // Check cache again in case it already resolved.
    final current = _resolveStatus(moduleId);
    if (current == FeatureModuleStatus.ready) {
      await sub.cancel();
      return true;
    }
    if (current == FeatureModuleStatus.failed) {
      await sub.cancel();
      return false;
    }
    final result = await completer.future;
    await sub.cancel();
    return result;
  }

  void _emit(String moduleId, FeatureModuleStatus status) {
    if (!_statusController.isClosed) {
      _statusController.add(status);
    }
  }

  @override
  String displayName(String moduleId) {
    switch (moduleId) {
      case 'ffmpeg':
        return 'FFmpeg media tools';
      default:
        return moduleId;
    }
  }

  @override
  int? estimatedSizeBytes(String moduleId) {
    switch (moduleId) {
      case 'ffmpeg':
        return 10 * 1024 * 1024; // ~10 MB estimate
      default:
        return null;
    }
  }

  /// Release resources. Call when the app no longer needs module loading.
  void dispose() {
    _statusController.close();
  }
}

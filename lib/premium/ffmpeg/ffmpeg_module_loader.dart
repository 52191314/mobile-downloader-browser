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

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../build_channel.dart';

/// Method channel name for Play Feature Delivery SplitInstallManager.
const _kFeatureDeliveryChannel = 'aurora_downloader/feature_delivery';

/// Method channel name for install progress events.
const _kFeatureDeliveryProgress = 'aurora_downloader/feature_delivery_progress';

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
      case 'torrent':
        return 'BitTorrent engine';
      case 'mediakit':
        return 'Media player engine';
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
/// Communicates with the native Android [SplitInstallManager] via
/// the `aurora_downloader/feature_delivery` method channel, defined in
/// [MainActivity.kt].
class PlayModuleLoader extends FeatureModuleLoader {
  PlayModuleLoader() : super._();

  final MethodChannel _channel = const MethodChannel(_kFeatureDeliveryChannel);
  final MethodChannel _progressChannel =
      const MethodChannel(_kFeatureDeliveryProgress);

  final _statusController = StreamController<FeatureModuleStatus>.broadcast();
  final Map<String, FeatureModuleStatus> _cache = {};
  bool _listening = false;

  /// Session IDs for active installs, keyed by module name.
  final Map<String, int> _activeSessions = {};

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
      return _waitForModule(moduleId);
    }

    // First, check if the module is already installed.
    final installed = await _checkModuleInstalled(moduleId);
    if (installed) {
      _cache[moduleId] = FeatureModuleStatus.ready;
      _emit(moduleId, FeatureModuleStatus.ready);
      await _registerPlugin(moduleId);
      return true;
    }

    _cache[moduleId] = FeatureModuleStatus.downloading;
    _emit(moduleId, FeatureModuleStatus.downloading);

    try {
      // Listen for progress events from the native side.
      _ensureProgressListener(onProgress);

      // Start the install via method channel.
      final sessionId = await _channel.invokeMethod<int>('startInstall', {
        'module': moduleId,
      });

      if (sessionId == null) {
        throw Exception('Failed to start module install (null session)');
      }

      _activeSessions[moduleId] = sessionId;

      // Wait for completion via the progress stream.
      final success = await _waitForModule(moduleId);
      if (success) {
        await _registerPlugin(moduleId);
      }
      return success;
    } on MissingPluginException {
      // Feature delivery not available (debug APK, emulator, etc.).
      // Assume module is present (fat APK fallback).
      _cache[moduleId] = FeatureModuleStatus.ready;
      _emit(moduleId, FeatureModuleStatus.ready);
      return true;
    } catch (e) {
      _cache[moduleId] = FeatureModuleStatus.failed;
      _emit(moduleId, FeatureModuleStatus.failed);
      return false;
    }
  }

  /// Queries the native side for module install status.
  Future<bool> _checkModuleInstalled(String moduleId) async {
    try {
      final installed = await _channel.invokeMethod<bool>('getModuleStatus', {
        'module': moduleId,
      });
      return installed == true;
    } on MissingPluginException {
      return true; // Feature delivery not available — assume present.
    } catch (_) {
      return false;
    }
  }

  /// Registers the native plugin for [moduleId] in the current process.
  ///
  /// The ffmpeg-kit / media_kit_libs plugins are forked without an Android
  /// `pluginClass`, so they are never registered by GeneratedPluginRegistrant
  /// at launch. After the on-demand module is installed (and SplitCompat has
  /// made its .so loadable), this tells the native side to
  /// `flutterEngine.getPlugins().add(...)` so the plugin's method channel and
  /// static native loading run with the libs present.
  Future<void> _registerPlugin(String moduleId) async {
    try {
      await _channel.invokeMethod<bool>('registerPlugin', {
        'module': moduleId,
      });
    } on MissingPluginException {
      // Fat APK / emulator — plugin already registered at launch; no-op.
    } catch (e) {
      debugPrint('[FeatureModuleLoader] registerPlugin($moduleId) failed: $e');
    }
  }

  /// Registers the progress event listener if not already registered.
  void _ensureProgressListener(ModuleProgressCallback? onProgress) {
    if (_listening) return;
    _listening = true;

    _progressChannel.setMethodCallHandler((call) async {
      if (call.method == 'onProgress') {
        final args = call.arguments as Map<dynamic, dynamic>?;
        final statusCode = args?['status'] as int?;
        final progress = (args?['progress'] as num?)?.toDouble() ?? 0.0;
        final module = args?['module'] as String? ?? 'ffmpeg';

        // Map SplitInstallSessionStatus to FeatureModuleStatus.
        if (statusCode == 5) {
          // SplitInstallSessionStatus.INSTALLED = 5
          _cache[module] = FeatureModuleStatus.ready;
          _emit(module, FeatureModuleStatus.ready);
        } else if (statusCode == 6) {
          // SplitInstallSessionStatus.FAILED = 6
          _cache[module] = FeatureModuleStatus.failed;
          _emit(module, FeatureModuleStatus.failed);
        } else if (statusCode == 3) {
          // SplitInstallSessionStatus.DOWNLOADING = 3
          _cache[module] = FeatureModuleStatus.downloading;
          _emit(module, FeatureModuleStatus.downloading);
          onProgress?.call(progress);
        } else if (statusCode == 4) {
          // SplitInstallSessionStatus.INSTALLING = 4
          _cache[module] = FeatureModuleStatus.downloading;
          _emit(module, FeatureModuleStatus.downloading);
          onProgress?.call(progress);
        }
      }
    });
  }

  /// Waits for the module stream to resolve to a terminal state.
  Future<bool> _waitForModule(String moduleId) async {
    // If already resolved in cache, return immediately.
    final cached = _resolveStatus(moduleId);
    if (cached == FeatureModuleStatus.ready) return true;
    if (cached == FeatureModuleStatus.failed) return false;

    final completer = Completer<bool>();
    final sub = _statusController.stream.listen((status) {
      if (status == FeatureModuleStatus.ready) {
        completer.complete(true);
      } else if (status == FeatureModuleStatus.failed) {
        completer.complete(false);
      }
    });

    // Timeout after 5 minutes — install should not take longer.
    final timer = Timer(const Duration(minutes: 5), () {
      if (!completer.isCompleted) {
        completer.complete(false);
      }
    });

    final result = await completer.future;
    timer.cancel();
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
      case 'torrent':
        return 'BitTorrent engine';
      case 'mediakit':
        return 'Media player engine';
      default:
        return moduleId;
    }
  }

  @override
  int? estimatedSizeBytes(String moduleId) {
    switch (moduleId) {
      case 'ffmpeg':
        // Stripped arm64 suite is ~15–20 MB; show an upper-bound estimate.
        return 18 * 1024 * 1024;
      case 'torrent':
        // libtorrent native lib ~4–6 MB.
        return 6 * 1024 * 1024;
      case 'mediakit':
        // libmpv + mediakitandroidhelper ~12–15 MB.
        return 15 * 1024 * 1024;
      default:
        return null;
    }
  }

  /// Release resources. Call when the app no longer needs module loading.
  void dispose() {
    _statusController.close();
    _progressChannel.setMethodCallHandler(null);
  }
}

/// FFmpeg runtime wrapper — isolates ffmpeg-kit imports for deferred loading.
///
/// This library is the **only** file that imports from
/// `ffmpeg_kit_flutter_new_min_gpl` directly. All other Dart code should
/// go through [FfmpegRuntime] or [FfmpegService] (which uses this wrapper).
///
/// For Play Store AAB builds, this library should be loaded via Dart deferred
/// import so the native ffmpeg-kit `.so` files can be shipped in a separate
/// on-demand dynamic feature module rather than the base APK.
///
/// For GitHub / sideload (fat APK) builds, this library is always linked and
/// the module loader skips the download step entirely.
///
/// Usage (conceptual — the deferred import goes in the module loader):
/// ```dart
/// import 'ffmpeg_runtime.dart' deferred as ffmpeg;
///
/// Future<void> ensureFfmpegReady() async {
///   if (BuildChannel.isGithub) {
///     // Fat APK: already linked
///     await FfmpegService.instance.probeVersion();
///   } else {
///     // Play: deferred load triggers Play on-demand module download
///     await ffmpeg.loadLibrary();
///     await FfmpegService.instance.probeVersion();
///   }
/// }
/// ```
///
/// See: `docs/play_on_demand_modules_plan.md`
library;

// These imports from ffmpeg-kit are the only direct dependency on the
// native plugin. Isolating them here means other Dart files can reference
// FfmpegService / FfmpegJob without pulling ffmpeg-kit into the main bundle.
//
// Both import and export are needed:
// - import: makes the symbols available in THIS file
// - export: re-exports them to consumers of this library
//
// We import from the three key ffmpeg-kit entry points:
//   ffmpeg_kit.dart  → FFmpegKit
//   ffprobe_kit.dart → FFprobeKit
//   return_code.dart → ReturnCode
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/return_code.dart';
export 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
export 'package:ffmpeg_kit_flutter_new_min_gpl/ffprobe_kit.dart';
export 'package:ffmpeg_kit_flutter_new_min_gpl/return_code.dart';

/// Version probe result from the native FFmpeg runtime.
class FfmpegRuntimeProbe {
  final String rawOutput;
  final bool available;
  final String? version;

  const FfmpegRuntimeProbe({
    required this.rawOutput,
    required this.available,
    this.version,
  });

  bool get isAvailable => available;
}

/// Static helpers that delegate to ffmpeg-kit.
///
/// All methods are async and safe to call from any isolate/thread.
class FfmpegRuntime {
  FfmpegRuntime._();

  /// Probes whether the native FFmpeg library is available (loaded).
  ///
  /// Returns null if the probe itself fails (e.g. library not yet loaded
  /// on Play on-demand before [loadLibrary] completes).
  static Future<FfmpegRuntimeProbe?> probeVersion() async {
    try {
      final session = await FFprobeKit.execute('-version');
      final output = (await session.getOutput()) ?? '';
      final returnCode = await session.getReturnCode();
      final success = ReturnCode.isSuccess(returnCode);
      final version = _parseVersion(output);
      return FfmpegRuntimeProbe(
        rawOutput: output,
        available: success,
        version: version,
      );
    } catch (e) {
      // Library not loaded or platform exception.
      return null;
    }
  }

  /// Executes an FFmpeg command and returns the session.
  static Future<dynamic> execute(String cmd) {
    return FFmpegKit.execute(cmd);
  }

  /// Cancels an FFmpeg session by handle.
  static void cancel(int handle) {
    FFmpegKit.cancel(handle);
  }

  /// Parse the first line of `ffmpeg -version` output.
  static String? _parseVersion(String output) {
    final firstLine = output.split('\n').firstOrNull;
    if (firstLine == null) return null;
    // e.g. "ffmpeg version 6.0 ...
    final versionMatch =
        RegExp(r'ffmpeg version (\S+)').firstMatch(firstLine);
    return versionMatch?.group(1);
  }
}

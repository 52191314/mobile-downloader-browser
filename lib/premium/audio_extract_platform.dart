/// P5 audioExtract: method channel bridge to Android's Media3 Transformer.
///
/// Calls the Kotlin platform channel [audioExtractChannel] which uses
/// `androidx.media3.transformer.Transformer` to extract the audio track
/// from a video file and produce an AAC audio file.
library;

import 'package:flutter/services.dart';

import '../downloader/models.dart';
import 'free_cap_store.dart';
import 'phase2_caps.dart';
import 'pro_entitlement.dart';

/// Platform channel name matching [MainActivity] in Kotlin.
const _channelName = 'aurora_downloader/audio_extract';

final MethodChannel _channel = MethodChannel(_channelName);

/// Result of an audio-extract operation.
sealed class AudioExtractResult {
  const AudioExtractResult();
}

class AudioExtractSuccess extends AudioExtractResult {
  final String outputPath;
  const AudioExtractSuccess(this.outputPath);
}

class AudioExtractFailure extends AudioExtractResult {
  final String error;
  const AudioExtractFailure(this.error);
}

class AudioExtractDenied extends AudioExtractResult {
  const AudioExtractDenied();
}

/// Static entry point for audio extraction via platform channel.
///
/// Typical usage:
/// ```dart
/// final result = await AudioExtractPlatform.extract(
///   task: task,
///   tier: proUpsellEntitlement?.tier ?? EntitlementTier.free,
/// );
/// switch (result) {
///   case AudioExtractSuccess(:final outputPath):
///     // Audio file is ready at outputPath
///   case AudioExtractFailure(:final error):
///     // Show error
///   case AudioExtractDenied():
///     // User hit daily cap
/// }
/// ```
class AudioExtractPlatform {
  AudioExtractPlatform._();

  /// Attempts to extract audio from [task]'s saved video file.
  ///
  /// Gates via [ProFeature.audioExtract], consumes [FreeCapStore] for free
  /// users (3/day), and calls the platform channel.
  ///
  /// [tier] defaults to free if not provided.
  static Future<AudioExtractResult> extract({
    required DownloadTask task,
    EntitlementTier? tier,
  }) async {
    final effectiveTier = tier ?? EntitlementTier.free;

    // Gate check.
    if (!effectiveTier.isAtLeastPro &&
        !await FreeCapStore.tryConsume(FreeCapKind.audioExtract)) {
      return const AudioExtractDenied();
    }

    // Determine input and output paths.
    final inputPath = task.savePath;
    if (inputPath.isEmpty) {
      return const AudioExtractFailure('No file path.');
    }

    // Replace extension with .mp3 or .aac.
    final dot = inputPath.lastIndexOf('.');
    final outputPath =
        dot > 0 ? '${inputPath.substring(0, dot)}.aac' : '$inputPath.aac';

    try {
      final result = await _channel.invokeMethod<String>('extractAudio', {
        'inputPath': inputPath,
        'outputPath': outputPath,
      });
      if (result != null) {
        return AudioExtractSuccess(result);
      }
      return const AudioExtractFailure('No result returned.');
    } on MissingPluginException {
      return const AudioExtractFailure(
          'Platform not supported (non-Android or build channel).');
    } catch (e) {
      return AudioExtractFailure(e.toString());
    }
  }
}

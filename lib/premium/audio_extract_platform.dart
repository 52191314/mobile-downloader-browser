/// P5 audioExtract: method channel bridge to Android's Media3 Transformer.
///
/// Calls the Kotlin platform channel [audioExtractChannel] which uses
/// `androidx.media3.transformer.Transformer` to extract the audio track
/// from a video file and produce an AAC audio file.
library;

import 'package:flutter/services.dart';

import '../downloader/models.dart';
import 'free_taste.dart';
import 'pro_entitlement.dart';
import 'pro_features.dart';

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
  /// Free taste via [FreeTaste] (3/day); Pro+ unlimited. Daily quota is
  /// consumed only after the platform channel returns success.
  ///
  /// [tier] defaults to free if not provided.
  static Future<AudioExtractResult> extract({
    required DownloadTask task,
    EntitlementTier? tier,
  }) async {
    final effectiveTier = tier ?? EntitlementTier.free;

    // Peek free capacity first (do not consume on transform failure).
    final peek = await FreeTaste.evaluate(
      feature: ProFeature.audioExtract,
      tier: effectiveTier,
      n: 1,
      consume: false,
    );
    if (!peek.allowed) {
      return const AudioExtractDenied();
    }

    final inputPath = task.savePath;
    if (inputPath.isEmpty) {
      return const AudioExtractFailure('No file path.');
    }

    final dot = inputPath.lastIndexOf('.');
    final outputPath =
        dot > 0 ? '${inputPath.substring(0, dot)}.aac' : '$inputPath.aac';

    try {
      final result = await _channel.invokeMethod<String>('extractAudio', {
        'inputPath': inputPath,
        'outputPath': outputPath,
      });
      if (result != null) {
        // Consume only after a successful transform.
        if (!ProFeatures.allows(ProFeature.audioExtract, effectiveTier)) {
          await FreeTaste.evaluate(
            feature: ProFeature.audioExtract,
            tier: effectiveTier,
            n: 1,
            consume: true,
          );
        }
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

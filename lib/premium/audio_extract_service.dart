/// P5 audio extract service — Media3 Transformer pipeline.
///
/// Gated behind [ProFeature.audioExtract]. Free users get 3/day via
/// [FreeCapStore]; Pro+ unlimited.
///
/// ## Implementation steps (TODO):
/// 1. Add `androidx.media3:media3-transformer` dependency to
///    `android/app/build.gradle`.
/// 2. Create a platform channel method that receives an input file path and
///    output audio path, then invokes Media3 Transformer.
/// 3. Call [Phase2Caps.tryConsumeAudioExtract] before starting the pipeline.
/// 4. Show progress via [DownloadNotificationService] (reuse progress notif).
/// 5. After completion, place the .mp3/.aac file next to the original video.
library;

import 'package:flutter/foundation.dart';

import '../downloader/models.dart';
import 'free_cap_store.dart';
import 'phase2_caps.dart';
import 'pro_entitlement.dart';
import 'pro_features.dart';

/// Static entry point for audio extraction.
///
/// Typical call site:
/// ```
/// if (!ProFeatures.allows(ProFeature.audioExtract, tier)) {
///   showProUpsell(context, ProFeature.audioExtract);
///   return;
/// }
/// if (!await AudioExtractService.tryStart(task, tier)) {
///   // daily limit reached
///   return;
/// }
/// ```
class AudioExtractService {
  AudioExtractService._();

  /// Attempts to start an audio-extract job for [task].
  /// Returns false if the free daily cap is exhausted.
  ///
  /// TODO(P5): actual Media3 Transformer platform channel call.
  static Future<bool> tryStart(DownloadTask task, EntitlementTier tier) async {
    if (!tier.isAtLeastPro && !await FreeCapStore.tryConsume(FreeCapKind.audioExtract)) {
      return false;
    }
    // TODO(P5): invoke platform channel → Media3 Transformer
    // Input: task.savePath
    // Output: replace extension with .mp3
    // Progress: post events back via callback
    debugPrint('[AudioExtract] TODO: transform ${task.savePath}');
    return true;
  }
}

/// P5 audio extract — thin-wrapper over [AudioExtractPlatform].
///
/// All actual work is done by [AudioExtractPlatform.extract]. This class is
/// kept for backward compatibility: existing call sites that imported
/// `AudioExtractService` continue to work.
///
/// New code should call [AudioExtractPlatform.extract] directly.
///
/// Free taste: [FreeTaste.dailyQuota] via [FreeCapStore] (3/day).
/// Pro+ unlimited.
library;

import '../downloader/models.dart';
import 'audio_extract_platform.dart';
import 'pro_entitlement.dart';

/// Thin-wrapper entry point — delegates to [AudioExtractPlatform.extract].
class AudioExtractService {
  AudioExtractService._();

  /// Attempts to start an audio-extract job for [task].
  /// Returns false if the free daily cap is exhausted.
  ///
  /// Prefer [AudioExtractPlatform.extract] in new code.
  static Future<bool> tryStart(DownloadTask task, EntitlementTier tier) async {
    final result = await AudioExtractPlatform.extract(
      task: task,
      tier: tier,
    );
    return result is AudioExtractSuccess;
  }
}

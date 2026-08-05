import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Result of a TS→MP4 remux attempt.
class RemuxResult {
  final bool success;
  final String? error;

  const RemuxResult({required this.success, this.error});

  @override
  String toString() => 'RemuxResult(success: $success, error: $error)';
}

class TsRemuxService {
  static const MethodChannel _channel = MethodChannel(
    'aurora_downloader/public_downloads',
  );

  /// Remuxes an MPEG-TS file to MP4 container using Android's native
  /// MediaExtractor + MediaMuxer. No transcoding — just container change.
  ///
  /// Native side time-interleaves A/V samples and synthesizes AAC `csd-0`
  /// when missing so pure HW decoders (e.g. MX Player HW) get sound; HW+
  /// was more forgiving of the old sequential-track remux.
  ///
  /// Returns a [RemuxResult]; on failure the `.ts` file is kept as fallback
  /// and the failure reason is surfaced via debugPrint.
  static Future<RemuxResult> remuxTsToMp4(
    String sourcePath,
    String destPath,
  ) async {
    try {
      final result = await _channel.invokeMethod<dynamic>('remuxTsToMp4', {
        'sourcePath': sourcePath,
        'destPath': destPath,
      });
      // Native side now returns a map {success: bool, error: String?}.
      // Tolerate a bare bool for backward compatibility.
      bool success;
      String? error;
      if (result is Map) {
        success = (result['success'] as bool?) ?? false;
        error = result['error'] as String?;
      } else {
        success = (result as bool?) ?? false;
      }
      if (!success) {
        debugPrint('remuxTsToMp4 failed: ${error ?? "unknown"} '
          '(source=$sourcePath)');
      }
      return RemuxResult(success: success, error: error);
    } on PlatformException catch (e) {
      debugPrint('[TsRemuxService] remuxTsToMp4 PlatformException: $e');
      debugPrint('remuxTsToMp4 PlatformException: ${e.message}');
      return RemuxResult(success: false, error: e.message);
    } catch (e) {
      debugPrint('[TsRemuxService] remuxTsToMp4 failed: $e');
      debugPrint('remuxTsToMp4 failed: $e');
      return RemuxResult(success: false, error: e.toString());
    }
  }
}

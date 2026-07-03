import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class TsRemuxService {
  static const MethodChannel _channel = MethodChannel(
    'aurora_downloader/public_downloads',
  );

  /// Remuxes an MPEG-TS file to MP4 container using Android's native
  /// MediaExtractor + MediaMuxer. No transcoding — just container change.
  /// Returns true on success, false on failure (the .ts file is kept as fallback).
  static Future<bool> remuxTsToMp4(String sourcePath, String destPath) async {
    try {
      final result = await _channel.invokeMethod<bool>('remuxTsToMp4', {
        'sourcePath': sourcePath,
        'destPath': destPath,
      });
      return result ?? false;
    } catch (e) {
      debugPrint('[TsRemuxService] remuxTsToMp4 failed: $e');
      return false;
    }
  }
}

import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'aurora_log.dart';

/// Tiny store that persists just the [LogVerbosity] preference to a
/// separate JSON file.  Kept outside [DownloadSettings] so the large
/// settings class does not need an additional field in its already
/// fragile serializer.
class LogSettingsStore {
  const LogSettingsStore._();

  static const LogSettingsStore instance = LogSettingsStore._();

  static const String _fileName = 'log_settings.json';

  LogVerbosity get defaultVerbosity =>
      kDebugMode ? LogVerbosity.verbose : LogVerbosity.minimal;

  Future<LogVerbosity> load(String appSupportDir) async {
    try {
      final file = File('$appSupportDir/$_fileName');
      if (await file.exists()) {
        final content = await file.readAsString();
        final decoded = jsonDecode(content) as Map<String, dynamic>;
        final name = decoded['verbosity'] as String?;
        if (name == 'minimal') return LogVerbosity.minimal;
        if (name == 'verbose') return LogVerbosity.verbose;
      }
    } catch (e) {
      debugPrint('[LogSettingsStore] Failed to load: $e');
    }
    return defaultVerbosity;
  }

  Future<void> save(String appSupportDir, LogVerbosity v) async {
    try {
      final file = File('$appSupportDir/$_fileName');
      final tempFile = File('$appSupportDir/$_fileName.tmp');
      await tempFile
          .writeAsString(jsonEncode({'verbosity': v.name}), flush: true);
      if (await tempFile.exists()) {
        if (await file.exists()) {
          await file.delete();
        }
        await tempFile.rename(file.path);
      }
    } catch (e) {
      debugPrint('[LogSettingsStore] Failed to save: $e');
    }
  }
}

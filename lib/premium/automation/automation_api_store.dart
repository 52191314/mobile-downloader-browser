/// Persistence for the Automation API on/off preference.
///
/// Stored as a tiny JSON file in the app support directory
/// (`automation_api_settings.json`), same pattern as [WatcherStore] and
/// [DownloadSettingsStore]. Default is OFF (see SECURITY_AUDIT.md §5.1).
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class AutomationApiStore {
  static const _fileName = 'automation_api_settings.json';

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  /// Whether the user previously enabled the API. Defaults to false.
  static Future<bool> loadEnabled() async {
    try {
      final f = await _file();
      if (!await f.exists()) return false;
      final decoded = jsonDecode(await f.readAsString());
      if (decoded is Map && decoded['enabled'] is bool) {
        return decoded['enabled'] as bool;
      }
    } catch (_) {
      // Corrupt/missing file → default off.
    }
    return false;
  }

  static Future<void> saveEnabled(bool value) async {
    try {
      final f = await _file();
      if (!await f.parent.exists()) {
        await f.parent.create(recursive: true);
      }
      await f.writeAsString(jsonEncode({'enabled': value}), flush: true);
    } catch (_) {
      // Best-effort persistence; a failed write only costs the toggle
      // state on next launch.
    }
  }
}

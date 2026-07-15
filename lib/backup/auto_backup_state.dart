import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Persisted auto-backup runtime state (separate from user settings so a
/// backup run does not rewrite the settings file).
class AutoBackupState {
  const AutoBackupState({this.lastBackupTime = 0});

  /// Milliseconds since epoch of the last successful backup. `0` means never.
  final int lastBackupTime;

  AutoBackupState copyWith({int? lastBackupTime}) =>
      AutoBackupState(lastBackupTime: lastBackupTime ?? this.lastBackupTime);

  Map<String, dynamic> toJson() => {'lastBackupTime': lastBackupTime};

  factory AutoBackupState.fromJson(Map<String, dynamic> json) => AutoBackupState(
        lastBackupTime: (json['lastBackupTime'] as num?)?.toInt() ?? 0,
      );
}

class AutoBackupStateStore {
  const AutoBackupStateStore({this.fileName = 'auto_backup_state.json'});

  final String fileName;

  Future<AutoBackupState> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const AutoBackupState();
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return const AutoBackupState();
      return AutoBackupState.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return const AutoBackupState();
    }
  }

  Future<void> save(AutoBackupState state) async {
    try {
      final file = await _file();
      if (!await file.parent.exists()) await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(state.toJson()));
    } catch (_) {
      // Non-fatal: backup scheduling still works, just can't persist the stamp.
    }
  }

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$fileName');
  }
}

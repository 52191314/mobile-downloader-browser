import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../platform/public_downloads_service.dart';
import '../settings/download_settings.dart';
import 'auto_backup_models.dart';
import 'auto_backup_state.dart';

/// Root folder (relative to the device Downloads collection) where auto
/// backups are written. Matches the app's existing external-storage layout.
const String autoBackupRootRelative = 'Download/Aurora Downloader/Auto Backup';

/// Owns the auto-backup schedule and the one-shot backup/restore operations.
///
/// Backups are written through the existing native `publishFile` channel so
/// they land in `Downloads/Aurora Downloader/Auto Backup/<timestamp>/` with no
/// new storage permissions. Scheduling is in-app (a [Timer] plus a launch
/// catch-up check) — appropriate for a downloader that is normally running.
class AutoBackupService {
  AutoBackupService({AutoBackupStateStore? stateStore})
      : _stateStore = stateStore ?? const AutoBackupStateStore();

  final AutoBackupStateStore _stateStore;
  AutoBackupState _state = const AutoBackupState();
  DownloadSettings? _settings;
  Timer? _timer;
  bool _inProgress = false;

  /// Last successful backup time, or `null` if never.
  DateTime? get lastBackupTime =>
      _state.lastBackupTime == 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(_state.lastBackupTime);

  /// (Re)configures the service from current settings. Loads persisted state,
  /// restarts the schedule, and runs a catch-up backup if the interval has
  /// already elapsed.
  Future<void> configure(DownloadSettings settings) async {
    _settings = settings;
    _state = await _stateStore.load();
    _restartTimer();
    await _runCatchUpIfDue();
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = null;
    final settings = _settings;
    if (settings == null || !settings.autoBackupEnabled) return;
    _timer = Timer.periodic(settings.autoBackupInterval.duration, (_) {
      unawaited(_runIfDue());
    });
  }

  Future<void> _runCatchUpIfDue() async {
    final settings = _settings;
    if (settings == null || !settings.autoBackupEnabled) return;
    final now = DateTime.now();
    final last = lastBackupTime;
    if (last == null ||
        now.difference(last) >= settings.autoBackupInterval.duration) {
      await _runIfDue();
    }
  }

  Future<void> _runIfDue() async {
    final settings = _settings;
    if (settings == null || !settings.autoBackupEnabled) return;
    final last = lastBackupTime;
    if (last != null &&
        DateTime.now().difference(last) < settings.autoBackupInterval.duration) {
      return;
    }
    await performBackup();
  }

  /// Copies every root-level data `.json` (except the sniffed-media cache)
  /// into a new timestamped backup folder in external storage.
  Future<AutoBackupResult> performBackup() async {
    if (_inProgress) {
      return const AutoBackupResult(
        success: false,
        message: "Couldn't start — another backup is running. Wait for it to finish.",
      );
    }
    _inProgress = true;
    try {
      final supportDir = await getApplicationSupportDirectory();
      final sources = await _collectSourceFiles(supportDir);
      if (sources.isEmpty) {
        return const AutoBackupResult(
          success: false,
          message: 'Nothing to back up yet. Download something first.',
        );
      }

      final timestamp = _timestamp(DateTime.now());
      final tempDir = await getTemporaryDirectory();
      final written = <String>[];

      for (final source in sources) {
        final name = p.basename(source.path);
        final temp = File('${tempDir.path}/aurora_bak_$name');
        await source.copy(temp.path);
        final ok = await PublicDownloadsService.backupFileToDownloads(
          sourcePath: temp.path,
          displayName: name,
          relativePath: '$autoBackupRootRelative/$timestamp',
        );
        await temp.delete();
        if (!ok) {
          return AutoBackupResult(
            success: false,
            message: "Couldn't write $name. Free up storage and try again.",
          );
        }
        written.add(name);
      }

      final manifestTemp = File('${tempDir.path}/aurora_bak_manifest.json');
      await manifestTemp.writeAsString(jsonEncode({
        'app': 'Aurora Downloader',
        'createdAt': DateTime.now().toIso8601String(),
        'files': written,
      }));
      final manifestOk = await PublicDownloadsService.backupFileToDownloads(
        sourcePath: manifestTemp.path,
        displayName: 'backup_manifest.json',
        relativePath: '$autoBackupRootRelative/$timestamp',
      );
      await manifestTemp.delete();
      if (!manifestOk) {
        return const AutoBackupResult(
          success: false,
          message: "Couldn't write the backup manifest. Free up storage and try again.",
        );
      }

      _state = _state.copyWith(
        lastBackupTime: DateTime.now().millisecondsSinceEpoch,
      );
      await _stateStore.save(_state);
      return AutoBackupResult(
        success: true,
        message: 'Done — backed up ${written.length} files.',
        timestamp: timestamp,
      );
    } catch (e, s) {
      debugPrint('[AutoBackup] performBackup failed: $e\n$s');
      return AutoBackupResult(success: false, message: "Couldn't back up data. $e. Try again later.");
    } finally {
      _inProgress = false;
    }
  }

  /// Lists available backup snapshots (grouped by timestamp) from external
  /// storage. Returns an empty list if none exist or the query fails.
  Future<List<AutoBackupFile>> listBackups() async {
    try {
      return await PublicDownloadsService.listAutoBackups();
    } catch (e, s) {
      debugPrint('[AutoBackup] listBackups failed: $e\n$s');
      return const [];
    }
  }

  /// Restores every file from the given backup timestamp back into the app
  /// support directory, overwriting the current data files. Returns the number
  /// of files restored.
  Future<int> restoreBackup(String timestamp) async {
    final all = await listBackups();
    final matching = all.where((f) => f.timestamp == timestamp).toList();
    if (matching.isEmpty) return 0;
    final supportDir = await getApplicationSupportDirectory();
    var restored = 0;
    for (final file in matching) {
      final dest = File('${supportDir.path}/${file.name}');
      final ok = await PublicDownloadsService.restoreBackupFile(
        uri: file.uri,
        destPath: dest.path,
      );
      if (ok) restored++;
    }
    return restored;
  }

  Future<List<File>> _collectSourceFiles(Directory supportDir) async {
    final result = <File>[];
    final dir = Directory(supportDir.path);
    if (!await dir.exists()) return result;
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.json')) continue;
      final name = p.basename(entity.path);
      // The sniffed-media cache is large and re-derivable by re-sniffing, so
      // it is intentionally excluded from backups.
      if (name.startsWith('sniffed_media_cache_')) continue;
      result.add(entity);
    }
    return result;
  }

  String _timestamp(DateTime dt) =>
      '${dt.year}-${_pad(dt.month)}-${_pad(dt.day)}_'
      '${_pad(dt.hour)}-${_pad(dt.minute)}-${_pad(dt.second)}';

  String _pad(int n) => n.toString().padLeft(2, '0');

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}

class AutoBackupResult {
  const AutoBackupResult({
    required this.success,
    required this.message,
    this.timestamp,
  });

  final bool success;
  final String message;
  final String? timestamp;
}

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

/// Default auto-backup root when settings have not been applied yet.
const String autoBackupRootRelativeDefault =
    'Download/Aurora Downloader/Auto Backup';

/// Owns the auto-backup schedule and the one-shot backup/restore operations.
///
/// Backups are written through the existing native `publishFile` channel so
/// they land under the configured download destination
/// (`…/Auto Backup/<timestamp>/`) with no new storage permissions. Scheduling
/// is in-app (a [Timer] plus a launch catch-up check).
class AutoBackupService {
  AutoBackupService({
    AutoBackupStateStore? stateStore,
    bool Function()? isProCallback,
  })  : _stateStore = stateStore ?? const AutoBackupStateStore(),
        _isProCallback = isProCallback ?? (() => false);

  final AutoBackupStateStore _stateStore;
  final bool Function() _isProCallback;
  AutoBackupState _state = const AutoBackupState();
  DownloadSettings? _settings;
  Timer? _timer;
  bool _inProgress = false;

  /// MediaStore-relative root for auto backups, derived from
  /// [DownloadSettings.downloadDestination].
  String get autoBackupRootRelative {
    final dest = DownloadSettings.normalizeDownloadDestination(
      _settings?.downloadDestination,
    );
    final media = DownloadSettings.mediaStoreRelativeFromDisplay(dest);
    return '$media/Auto Backup';
  }

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
    // Don't start the timer if the user is not Pro or if backing up on backgrounding.
    if (!_isProCallback()) return;
    if (settings.autoBackupInterval == AutoBackupInterval.onBackground) return;
    _timer = Timer.periodic(settings.autoBackupInterval.duration, (_) {
      unawaited(_runIfDue());
    });
  }

  Future<void> _runCatchUpIfDue() async {
    final settings = _settings;
    if (settings == null || !settings.autoBackupEnabled) return;
    if (settings.autoBackupInterval == AutoBackupInterval.onBackground) return;
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
    if (settings.autoBackupInterval == AutoBackupInterval.onBackground) return;
    final last = lastBackupTime;
    if (last != null &&
        DateTime.now().difference(last) < settings.autoBackupInterval.duration) {
      return;
    }
    await performBackup();
  }

  /// Triggers an automatic backup when the app enters background,
  /// provided auto-backup is enabled and user is eligible.
  Future<AutoBackupResult?> performBackgroundBackup() async {
    final settings = _settings;
    if (settings == null || !settings.autoBackupEnabled) return null;
    if (!_isProCallback()) return null;

    final last = lastBackupTime;
    if (settings.autoBackupInterval != AutoBackupInterval.onBackground) {
      if (last != null &&
          DateTime.now().difference(last) < settings.autoBackupInterval.duration) {
        return null;
      }
    }
    return await performBackup();
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
      final consolidatedMap = <String, dynamic>{};

      for (final source in sources) {
        final name = p.basename(source.path);
        final content = await source.readAsString();
        final dynamic decoded = jsonDecode(content);
        if (name == 'download_queue.json') {
          consolidatedMap['downloadQueue'] = decoded;
        } else if (name == 'download_settings.json') {
          consolidatedMap['settings'] = decoded;
        } else if (name == 'browser_tabs.json') {
          consolidatedMap['tabs'] = decoded;
        } else if (name == 'tab_groups.json') {
          consolidatedMap['tabGroups'] = decoded;
        } else if (name == 'browser_library.json') {
          if (decoded is Map) {
            for (final key in ['favorites', 'folders', 'history', 'savedPages']) {
              if (decoded.containsKey(key)) {
                consolidatedMap[key] = decoded[key];
              }
            }
          }
        } else {
          final key = p.basenameWithoutExtension(source.path);
          consolidatedMap[key] = decoded;
        }
      }

      // Unique display name so MediaStore listing and Local Backups scan can
      // distinguish snapshots (still recognized by isAuroraBackupFileName).
      final displayName = 'aurora_auto_backup_$timestamp.json';
      final temp = File('${tempDir.path}/aurora_bak_$displayName');
      await temp.writeAsString(jsonEncode(consolidatedMap));
      final ok = await PublicDownloadsService.backupFileToDownloads(
        sourcePath: temp.path,
        displayName: displayName,
        relativePath: '$autoBackupRootRelative/$timestamp',
      );
      await temp.delete();

      if (!ok) {
        return const AutoBackupResult(
          success: false,
          message: "Couldn't write the auto-backup file. Free up storage and try again.",
        );
      }

      _state = _state.copyWith(
        lastBackupTime: DateTime.now().millisecondsSinceEpoch,
      );
      await _stateStore.save(_state);
      return AutoBackupResult(
        success: true,
        message: 'Done — backed up 1 consolidated backup file.',
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
    // Prefer consolidated snapshot JSON (new auto names or legacy fixed name).
    AutoBackupFile? consolidated;
    for (final f in matching) {
      final n = f.name.toLowerCase();
      if (n == 'aurora_backup.json' ||
          n.startsWith('aurora_auto_backup_') ||
          n.startsWith('aurora_backup_')) {
        consolidated = f;
        break;
      }
    }
    if (consolidated != null) {
      final file = consolidated;
      final tempDir = await getTemporaryDirectory();
      final tempDest = File('${tempDir.path}/aurora_restore_consolidated.json');
      final ok = await PublicDownloadsService.restoreBackupFile(
        uri: file.uri,
        destPath: tempDest.path,
      );
      if (!ok) return 0;

      try {
        final content = await tempDest.readAsString();
        final dynamic decoded = jsonDecode(content);
        if (decoded is! Map) return 0;

        var restored = 0;

        // Reconstruct downloadQueue -> download_queue.json
        if (decoded.containsKey('downloadQueue')) {
          final f = File('${supportDir.path}/download_queue.json');
          await f.writeAsString(jsonEncode(decoded['downloadQueue']));
          restored++;
        }

        // Reconstruct settings -> download_settings.json
        if (decoded.containsKey('settings')) {
          final f = File('${supportDir.path}/download_settings.json');
          await f.writeAsString(jsonEncode(decoded['settings']));
          restored++;
        }

        // Reconstruct tabs -> browser_tabs.json
        if (decoded.containsKey('tabs')) {
          final f = File('${supportDir.path}/browser_tabs.json');
          await f.writeAsString(jsonEncode(decoded['tabs']));
          restored++;
        }

        // Reconstruct tabGroups -> tab_groups.json
        if (decoded.containsKey('tabGroups')) {
          final f = File('${supportDir.path}/tab_groups.json');
          await f.writeAsString(jsonEncode(decoded['tabGroups']));
          restored++;
        }

        // Reconstruct browser_library.json
        final libraryMap = <String, dynamic>{};
        for (final k in ['favorites', 'folders', 'history', 'savedPages']) {
          if (decoded.containsKey(k)) {
            libraryMap[k] = decoded[k];
          }
        }
        if (libraryMap.isNotEmpty) {
          final f = File('${supportDir.path}/browser_library.json');
          await f.writeAsString(jsonEncode(libraryMap));
          restored++;
        }

        // Reconstruct other keys -> <key>.json
        for (final entry in decoded.entries) {
          final key = entry.key;
          if (const [
            'downloadQueue',
            'settings',
            'tabs',
            'tabGroups',
            'favorites',
            'folders',
            'history',
            'savedPages'
          ].contains(key)) {
            continue;
          }
          final f = File('${supportDir.path}/$key.json');
          await f.writeAsString(jsonEncode(entry.value));
          restored++;
        }

        return restored;
      } catch (e, s) {
        debugPrint('[AutoBackup] restoreBackup failed during decoding: $e\n$s');
        return 0;
      } finally {
        if (await tempDest.exists()) {
          await tempDest.delete();
        }
      }
    } else {
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

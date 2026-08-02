import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart' as google_auth;
import 'package:path/path.dart' as p;

import '../downloader/downloader.dart';
import '../premium/pro_entitlement.dart';
import '../premium/pro_features.dart';

enum DriveConnectionStatus {
  disconnected,
  connecting,
  connected,
  syncing,
  error,
}

enum DriveUploadInterval {
  instant('Instant (on completion)'),
  fifteenMinutes('Every 15 minutes'),
  oneHour('Every 1 hour'),
  sixHours('Every 6 hours'),
  daily('Daily (every 24 hours)');

  final String label;
  const DriveUploadInterval(this.label);
}

/// Thrown when the user cancels the Google Sign-In flow.
class SignInCancelledException implements Exception {
  const SignInCancelledException();
  @override
  String toString() => "You cancelled signing in. Tap Link to try again.";
}

class DriveAccount {
  final String email;
  final String displayName;

  const DriveAccount({required this.email, required this.displayName});
}

class DriveUploadResult {
  final String fileId;
  final String folderName;
  final String sourcePath;
  final int uploadedBytes;
  final DateTime uploadedAt;

  DriveUploadResult({
    required this.fileId,
    required this.folderName,
    required this.sourcePath,
    required this.uploadedBytes,
    DateTime? uploadedAt,
  }) : uploadedAt = uploadedAt ?? DateTime.now();
}

class DriveSyncState {
  final DriveConnectionStatus status;
  final DriveAccount? account;
  final String destinationFolderName;
  final bool autoSyncEnabled;
  final DriveUploadInterval uploadInterval;
  final List<DriveUploadResult> uploadHistory;
  final int pendingUploadCount;
  final int dailyUploadCount;
  final int dailyUploadLimit;
  final String? errorMessage;

  const DriveSyncState({
    required this.status,
    required this.account,
    required this.destinationFolderName,
    required this.autoSyncEnabled,
    required this.uploadInterval,
    required this.uploadHistory,
    required this.pendingUploadCount,
    required this.dailyUploadCount,
    required this.dailyUploadLimit,
    this.errorMessage,
  });
}

abstract interface class GoogleDriveClient {
  Future<DriveAccount> signIn();
  Future<void> signOut();
  Future<DriveUploadResult> uploadFile({
    required File file,
    required String folderName,
  });
  Future<DriveUploadResult> uploadDirectory({
    required Directory directory,
    required String folderName,
  });
}

class MockGoogleDriveClient implements GoogleDriveClient {
  final DriveAccount mockAccount;
  final Duration latency;
  int _uploadCounter = 0;

  MockGoogleDriveClient({
    this.mockAccount = const DriveAccount(
      email: 'aurora.user@example.com',
      displayName: 'Aurora User',
    ),
    this.latency = const Duration(milliseconds: 40),
  });

  @override
  Future<DriveAccount> signIn() async {
    await Future<void>.delayed(latency);
    return mockAccount;
  }

  @override
  Future<void> signOut() async {
    await Future<void>.delayed(latency);
  }

  @override
  Future<DriveUploadResult> uploadFile({
    required File file,
    required String folderName,
  }) async {
    await Future<void>.delayed(latency);
    final length = await file.length();
    _uploadCounter++;
    return DriveUploadResult(
      fileId: 'mock-drive-file-$_uploadCounter',
      folderName: folderName,
      sourcePath: file.path,
      uploadedBytes: length,
    );
  }

  @override
  Future<DriveUploadResult> uploadDirectory({
    required Directory directory,
    required String folderName,
  }) async {
    await Future<void>.delayed(latency);
    var totalBytes = 0;
    await for (final entity in directory.list(recursive: true)) {
      if (entity is File) {
        totalBytes += await entity.length();
      }
    }
    _uploadCounter++;
    return DriveUploadResult(
      fileId: 'mock-drive-folder-$_uploadCounter',
      folderName: folderName,
      sourcePath: directory.path,
      uploadedBytes: totalBytes,
    );
  }
}

class GoogleDriveApiClient implements GoogleDriveClient {
  static const List<String> _scopes = [drive.DriveApi.driveFileScope];
  static const String _serverClientId = String.fromEnvironment(
    'AURORA_GOOGLE_SERVER_CLIENT_ID',
  );

  final GoogleSignIn googleSignIn;

  GoogleSignInAccount? _account;
  google_auth.AuthClient? _authClient;
  String? _folderCachePath;
  final Map<String, String> _folderIdCache = {};

  GoogleDriveApiClient({GoogleSignIn? googleSignIn})
      : googleSignIn =
            googleSignIn ??
            GoogleSignIn(
              scopes: _scopes,
              serverClientId: _serverClientId.isEmpty ? null : _serverClientId,
            );

  Future<void> loadFolderCache(String appSupportPath) async {
    _folderCachePath = '$appSupportPath/synced_drive_folders.json';
    try {
      final file = File(_folderCachePath!);
      if (await file.exists()) {
        final content = await file.readAsString();
        final map = jsonDecode(content);
        if (map is Map) {
          map.forEach((k, v) {
            _folderIdCache[k.toString()] = v.toString();
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _saveFolderCache() async {
    if (_folderCachePath == null) return;
    try {
      final file = File(_folderCachePath!);
      await file.writeAsString(jsonEncode(_folderIdCache));
    } catch (_) {}
  }

  @override
  Future<DriveAccount> signIn() async {
    try {
      final account =
          await googleSignIn.signInSilently() ?? await googleSignIn.signIn();
      if (account == null) {
        throw const SignInCancelledException();
      }
      _account = account;
      _authClient = null;
      return DriveAccount(
        email: account.email,
        displayName: account.displayName ?? account.email,
      );
    } catch (e) {
      if (e is SignInCancelledException) rethrow;
      throw StateError("Google Sign-In failed: $e");
    }
  }

  @override
  Future<void> signOut() async {
    try {
      await googleSignIn.signOut();
    } catch (_) {}
    _account = null;
    _authClient = null;
    clearCache();
  }

  @override
  Future<DriveUploadResult> uploadFile({
    required File file,
    required String folderName,
  }) async {
    final api = await _driveApi();
    final parentFolderId = await _ensureFolder(api, folderName);
    final fileName = p.basename(file.path);
    final media = drive.Media(
      file.openRead(),
      await file.length(),
      contentType: 'application/octet-stream',
    );
    final driveFile = drive.File()
      ..name = fileName
      ..parents = [parentFolderId];

    final created = await api.files.create(
      driveFile,
      uploadMedia: media,
      $fields: 'id, name, size',
    );
    final id = created.id;
    if (id == null) {
      throw StateError("Google Drive didn't return a file ID for $fileName.");
    }
    final size = created.size == null
        ? await file.length()
        : int.tryParse(created.size!) ?? await file.length();
    return DriveUploadResult(
      fileId: id,
      folderName: folderName,
      sourcePath: file.path,
      uploadedBytes: size,
    );
  }

  @override
  Future<DriveUploadResult> uploadDirectory({
    required Directory directory,
    required String folderName,
  }) async {
    final api = await _driveApi();
    final rootFolderId = await _ensureFolder(api, folderName);
    final bundleFolderName = p.basename(directory.path);
    final bundleFolderId = await _createFolder(
      api,
      bundleFolderName,
      rootFolderId,
    );

    var totalBytes = 0;
    final relativeFolderCache = <String, String>{};

    final entities = await directory.list(recursive: true).toList();
    for (final entity in entities) {
      if (entity is! File) continue;
      final relativePath = p.relative(entity.path, from: directory.path);
      final relativeDir = p.dirname(relativePath);
      final parentId = await _ensureRelativeFolderWithCache(
        api,
        bundleFolderId,
        relativeDir,
        relativeFolderCache,
      );

      final media = drive.Media(
        entity.openRead(),
        await entity.length(),
        contentType: 'application/octet-stream',
      );
      final file = drive.File()
        ..name = p.basename(entity.path)
        ..parents = [parentId];

      final created = await api.files.create(
        file,
        uploadMedia: media,
        $fields: 'id, size',
      );

      final bytes = created.size == null
          ? await entity.length()
          : int.tryParse(created.size!) ?? await entity.length();
      totalBytes += bytes;
    }

    return DriveUploadResult(
      fileId: bundleFolderId,
      folderName: folderName,
      sourcePath: directory.path,
      uploadedBytes: totalBytes,
    );
  }

  Future<google_auth.AuthClient?> _createAuthClient(
    GoogleSignInAccount account,
  ) async {
    return googleSignIn.authenticatedClient();
  }

  Future<drive.DriveApi> _driveApi() async {
    final account = _account;
    if (account == null) {
      throw StateError("Google Drive isn't linked. Tap Link to connect.");
    }
    _authClient ??= await _createAuthClient(account);
    final client = _authClient;
    if (client == null) {
      throw StateError("Couldn't connect to Google Drive. Check your connection and try again.");
    }
    return drive.DriveApi(client);
  }

  void clearCache() {
    _folderIdCache.clear();
    unawaited(_saveFolderCache());
  }

  Future<String> _ensureFolder(drive.DriveApi api, String folderName) async {
    if (_folderIdCache.containsKey(folderName)) {
      return _folderIdCache[folderName]!;
    }
    final escapedName = folderName.replaceAll("'", r"\'");
    final existing = await api.files.list(
      q:
          "mimeType='application/vnd.google-apps.folder' and "
          "name='$escapedName' and trashed=false",
      spaces: 'drive',
      $fields: 'files(id, name)',
      pageSize: 1,
    );
    final matches = existing.files ?? const <drive.File>[];
    final match = matches.isEmpty ? null : matches.first;
    if (match?.id != null) {
      final id = match!.id!;
      _folderIdCache[folderName] = id;
      unawaited(_saveFolderCache());
      return id;
    }
    final id = await _createFolder(api, folderName, null);
    _folderIdCache[folderName] = id;
    unawaited(_saveFolderCache());
    return id;
  }

  Future<String> _ensureRelativeFolderWithCache(
    drive.DriveApi api,
    String parentId,
    String relativeFolder,
    Map<String, String> cache,
  ) async {
    if (relativeFolder == '.' || relativeFolder.isEmpty) {
      return parentId;
    }

    if (cache.containsKey(relativeFolder)) {
      return cache[relativeFolder]!;
    }

    final segments = p.split(relativeFolder);
    var currentParent = parentId;
    var currentPath = '';

    for (final segment in segments) {
      currentPath = currentPath.isEmpty ? segment : p.join(currentPath, segment);
      if (cache.containsKey(currentPath)) {
        currentParent = cache[currentPath]!;
      } else {
        currentParent = await _createFolder(api, segment, currentParent);
        cache[currentPath] = currentParent;
      }
    }

    return currentParent;
  }

  Future<String> _createFolder(
    drive.DriveApi api,
    String name,
    String? parentId,
  ) async {
    final folder = await api.files.create(
      drive.File()
        ..name = name
        ..mimeType = 'application/vnd.google-apps.folder'
        ..parents = parentId == null ? null : [parentId],
      $fields: 'id',
    );
    final id = folder.id;
    if (id == null) {
      throw StateError("Google Drive didn't respond. Try again later.");
    }
    return id;
  }
}

class DriveSyncService {
  final GoogleDriveClient client;
  final EntitlementTier Function()? getTierCallback;

  DriveConnectionStatus _status = DriveConnectionStatus.disconnected;
  DriveAccount? _account;
  String _destinationFolderName;
  bool _autoSyncEnabled;
  DriveUploadInterval _uploadInterval;
  String? _errorMessage;
  int _dailyUploadCount = 0;
  String _dailyUploadDate = '';
  final List<DriveUploadResult> _uploadHistory = [];
  final Set<String> _syncedTaskIds = {};
  final Set<String> _syncingTaskIds = {};
  final Set<String> _queuedTaskIds = {};
  final List<DownloadTask> _pendingQueue = [];
  bool _isProcessingQueue = false;
  int _consecutiveQuotaErrors = 0;
  bool _isCircuitBroken = false;

  /// Maximum pending upload queue size. Oldest entries are dropped when exceeded.
  static const int _maxQueueSize = 100;

  /// Cooldown between consecutive uploads to avoid burst API request spikes.
  static const Duration _interUploadDelay = Duration(seconds: 3);
  Timer? _circuitBreakerTimer;
  Timer? _intervalTimer;
  StreamSubscription<DownloadTask>? _queueSubscription;

  final StreamController<DriveSyncState> _stateController =
      StreamController<DriveSyncState>.broadcast();

  DriveSyncService({
    GoogleDriveClient? client,
    this.getTierCallback,
    String destinationFolderName = 'Aurora Downloader',
    bool autoSyncEnabled = true,
    DriveUploadInterval uploadInterval = DriveUploadInterval.instant,
  })  : client = client ?? GoogleDriveApiClient(),
        _destinationFolderName = destinationFolderName,
        _autoSyncEnabled = autoSyncEnabled,
        _uploadInterval = uploadInterval {
    _startIntervalTimer();
  }

  EntitlementTier get currentTier =>
      getTierCallback?.call() ?? EntitlementTier.pro;

  int get currentDailyLimit => ProFeatures.driveSyncDailyLimit(currentTier);

  Stream<DriveSyncState> get onStateChanged => _stateController.stream;

  DriveSyncState get state => DriveSyncState(
        status: _status,
        account: _account,
        destinationFolderName: _destinationFolderName,
        autoSyncEnabled: _autoSyncEnabled,
        uploadInterval: _uploadInterval,
        uploadHistory: List.unmodifiable(_uploadHistory),
        pendingUploadCount: _pendingQueue.length,
        dailyUploadCount: _dailyUploadCount,
        dailyUploadLimit: currentDailyLimit,
        errorMessage: _errorMessage,
      );

  bool get isConnected => _status == DriveConnectionStatus.connected;

  Future<DriveAccount> connect() async {
    _setStatus(DriveConnectionStatus.connecting);
    try {
      _account = await client.signIn();
      _errorMessage = null;
      _setStatus(DriveConnectionStatus.connected);
      return _account!;
    } catch (e) {
      _errorMessage = e.toString();
      _setStatus(DriveConnectionStatus.error);
      rethrow;
    }
  }

  String? _syncTasksPath;
  String? _syncSettingsPath;
  String? _syncDailyPath;

  Future<void> disconnect() async {
    await client.signOut();
    if (client is GoogleDriveApiClient) {
      (client as GoogleDriveApiClient).clearCache();
    }
    _account = null;
    _syncedTaskIds.clear();
    _pendingQueue.clear();
    _queuedTaskIds.clear();
    _errorMessage = null;
    unawaited(_saveSyncedTasks());
    _setStatus(DriveConnectionStatus.disconnected);
  }

  void attachQueue(DownloadQueue queue) {
    _queueSubscription?.cancel();
    _queueSubscription = queue.onTaskUpdated.listen((task) {
      if (task.state == DownloadState.completed) {
        unawaited(syncCompletedTask(task));
      }
    });
  }

  void setDestinationFolder(String folderName) {
    final trimmed = folderName.trim();
    if (trimmed.isEmpty) return;
    _destinationFolderName = trimmed;
    unawaited(_saveSettings());
    _emitState();
  }

  void setAutoSyncEnabled(bool enabled) {
    _autoSyncEnabled = enabled;
    unawaited(_saveSettings());
    _emitState();
  }

  void setUploadInterval(DriveUploadInterval interval) {
    _uploadInterval = interval;
    _startIntervalTimer();
    unawaited(_saveSettings());
    _emitState();
  }

  void _startIntervalTimer() {
    _intervalTimer?.cancel();
    _intervalTimer = null;
    Duration? duration;
    switch (_uploadInterval) {
      case DriveUploadInterval.instant:
        duration = null;
        break;
      case DriveUploadInterval.fifteenMinutes:
        duration = const Duration(minutes: 15);
        break;
      case DriveUploadInterval.oneHour:
        duration = const Duration(hours: 1);
        break;
      case DriveUploadInterval.sixHours:
        duration = const Duration(hours: 6);
        break;
      case DriveUploadInterval.daily:
        duration = const Duration(hours: 24);
        break;
    }
    if (duration != null) {
      _intervalTimer = Timer.periodic(duration, (_) {
        if (_autoSyncEnabled && isConnected && !_isCircuitBroken) {
          unawaited(_processUploadQueue());
        }
      });
    }
  }

  /// Pushes completed download task to the single-worker upload queue.
  /// If [uploadInterval] is instant, triggers upload immediately.
  /// Otherwise, stays queued until interval timer or manual [syncNow] trigger.
  Future<DriveUploadResult?> syncCompletedTask(DownloadTask task) async {
    if (!_autoSyncEnabled || task.state != DownloadState.completed) {
      return null;
    }
    if (!isConnected || _isCircuitBroken) {
      return null;
    }
    if (_syncedTaskIds.contains(task.id) || _syncingTaskIds.contains(task.id)) {
      return null;
    }

    if (_queuedTaskIds.add(task.id)) {
      _pendingQueue.add(task);
      // Cap queue size: drop oldest entries to prevent unbounded growth.
      while (_pendingQueue.length > _maxQueueSize) {
        final dropped = _pendingQueue.removeAt(0);
        _queuedTaskIds.remove(dropped.id);
      }
      _emitState();
      if (_uploadInterval == DriveUploadInterval.instant) {
        unawaited(_processUploadQueue());
      }
    }
    return null;
  }

  /// Manually triggers processing of all pending queued uploads.
  Future<void> syncNow() async {
    if (!isConnected || _isCircuitBroken) return;
    await _processUploadQueue();
  }

  Future<void> _processUploadQueue() async {
    if (_isProcessingQueue) return;
    _isProcessingQueue = true;

    try {
      var isFirst = true;
      while (_pendingQueue.isNotEmpty && isConnected && !_isCircuitBroken) {
        // Cooldown between consecutive uploads to smooth API frequency.
        if (!isFirst) {
          await Future<void>.delayed(_interUploadDelay);
        }
        isFirst = false;
        final task = _pendingQueue.removeAt(0);
        _queuedTaskIds.remove(task.id);
        await _syncSingleTask(task);
        _emitState();
      }
    } finally {
      _isProcessingQueue = false;
      _emitState();
    }
  }

  Future<DriveUploadResult?> _syncSingleTask(DownloadTask task) async {
    if (!_autoSyncEnabled || task.state != DownloadState.completed) {
      return null;
    }
    if (!isConnected || _isCircuitBroken) {
      return null;
    }
    if (_syncedTaskIds.contains(task.id)) {
      return null;
    }
    if (!_syncingTaskIds.add(task.id)) {
      return null;
    }

    try {
      final today = DateTime.now().toIso8601String().substring(0, 10);
      if (_dailyUploadDate != today) {
        _dailyUploadDate = today;
        _dailyUploadCount = 0;
        unawaited(_saveDailyQuota());
      }

      final limit = currentDailyLimit;
      if (_dailyUploadCount >= limit) {
        _errorMessage =
            "Daily Google Drive upload limit reached ($_dailyUploadCount/$limit files today for ${currentTier.name.toUpperCase()} tier).";
        _setStatus(DriveConnectionStatus.error);
        return null;
      }

      final entityType = await FileSystemEntity.type(task.savePath);
      if (entityType == FileSystemEntityType.notFound) {
        _errorMessage = "Couldn't sync — completed file not found.";
        _setStatus(DriveConnectionStatus.error);
        return null;
      }

      _setStatus(DriveConnectionStatus.syncing);
      final result = await _executeWithBackoff(() async {
        return entityType == FileSystemEntityType.directory
            ? await client.uploadDirectory(
                directory: Directory(task.savePath),
                folderName: _destinationFolderName,
              )
            : await client.uploadFile(
                file: File(task.savePath),
                folderName: _destinationFolderName,
              );
      });

      _consecutiveQuotaErrors = 0;
      _dailyUploadCount++;
      unawaited(_saveDailyQuota());
      _uploadHistory.insert(0, result);
      _syncedTaskIds.add(task.id);
      unawaited(_saveSyncedTasks());
      _errorMessage = null;
      _setStatus(DriveConnectionStatus.connected);
      return result;
    } catch (e) {
      if (_isQuotaError(e)) {
        _consecutiveQuotaErrors++;
        if (_consecutiveQuotaErrors >= 3) {
          _triggerCircuitBreaker();
          return null;
        }
      }
      _errorMessage = e.toString();
      _setStatus(DriveConnectionStatus.error);
      return null;
    } finally {
      _syncingTaskIds.remove(task.id);
    }
  }

  bool _isQuotaError(Object error) {
    if (error is drive.DetailedApiRequestError) {
      if (error.status == 429) return true;
      if (error.status == 403) {
        final msg = error.message?.toLowerCase() ?? '';
        return msg.contains('ratelimit') ||
            msg.contains('quota') ||
            msg.contains('limitexceeded');
      }
    }
    final str = error.toString().toLowerCase();
    return str.contains('429') ||
        str.contains('user rate limit') ||
        str.contains('quotaexceeded');
  }

  Future<T> _executeWithBackoff<T>(
    Future<T> Function() action, {
    int maxRetries = 3,
  }) async {
    int attempt = 0;
    while (true) {
      try {
        return await action();
      } catch (e) {
        attempt++;
        if (attempt > maxRetries || !_isQuotaError(e)) {
          rethrow;
        }
        final jitter = (math.Random().nextDouble() * 500).toInt();
        final delayMs = (math.pow(2, attempt) * 1000).toInt() + jitter;
        debugPrint(
          '[DriveSync] Rate limit hit (attempt $attempt/$maxRetries). Retrying in ${delayMs}ms...',
        );
        await Future<void>.delayed(Duration(milliseconds: delayMs));
      }
    }
  }

  void _triggerCircuitBreaker() {
    _isCircuitBroken = true;
    _errorMessage =
        'Drive API rate limit reached. Auto-sync paused for 30 minutes to protect quota.';
    _setStatus(DriveConnectionStatus.error);
    _circuitBreakerTimer?.cancel();
    _circuitBreakerTimer = Timer(const Duration(minutes: 30), () {
      _isCircuitBroken = false;
      _consecutiveQuotaErrors = 0;
      _errorMessage = null;
      if (isConnected) {
        _setStatus(DriveConnectionStatus.connected);
        unawaited(_processUploadQueue());
      }
    });
  }

  Future<void> dispose() async {
    _intervalTimer?.cancel();
    _circuitBreakerTimer?.cancel();
    await _queueSubscription?.cancel();
    await _stateController.close();
  }

  void _setStatus(DriveConnectionStatus status) {
    _status = status;
    _emitState();
  }

  Future<void> loadSyncedTasks(String appSupportPath) async {
    _syncTasksPath = '$appSupportPath/synced_drive_tasks.json';
    _syncSettingsPath = '$appSupportPath/synced_drive_settings.json';
    _syncDailyPath = '$appSupportPath/synced_drive_daily.json';
    if (client is GoogleDriveApiClient) {
      await (client as GoogleDriveApiClient).loadFolderCache(appSupportPath);
    }
    await _loadSettings();
    await _loadDailyQuota();
    try {
      final file = File(_syncTasksPath!);
      if (await file.exists()) {
        final content = await file.readAsString();
        final list = jsonDecode(content);
        if (list is List) {
          _syncedTaskIds.addAll(list.map((e) => e.toString()));
        }
      }
    } catch (_) {}
  }

  Future<void> _loadDailyQuota() async {
    if (_syncDailyPath == null) return;
    try {
      final file = File(_syncDailyPath!);
      if (await file.exists()) {
        final content = await file.readAsString();
        final map = jsonDecode(content);
        if (map is Map) {
          final today = DateTime.now().toIso8601String().substring(0, 10);
          if (map['date'] == today) {
            _dailyUploadDate = today;
            _dailyUploadCount = map['count'] is int ? map['count'] : 0;
          } else {
            _dailyUploadDate = today;
            _dailyUploadCount = 0;
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _saveDailyQuota() async {
    if (_syncDailyPath == null) return;
    try {
      final file = File(_syncDailyPath!);
      final data = {
        'date': _dailyUploadDate,
        'count': _dailyUploadCount,
      };
      await file.writeAsString(jsonEncode(data));
    } catch (_) {}
  }

  Future<void> _loadSettings() async {
    if (_syncSettingsPath == null) return;
    try {
      final file = File(_syncSettingsPath!);
      if (await file.exists()) {
        final content = await file.readAsString();
        final map = jsonDecode(content);
        if (map is Map) {
          if (map['destinationFolderName'] is String) {
            _destinationFolderName = map['destinationFolderName'];
          }
          if (map['autoSyncEnabled'] is bool) {
            _autoSyncEnabled = map['autoSyncEnabled'];
          }
          if (map['uploadInterval'] is String) {
            final name = map['uploadInterval'];
            _uploadInterval = DriveUploadInterval.values.firstWhere(
              (e) => e.name == name,
              orElse: () => DriveUploadInterval.instant,
            );
            _startIntervalTimer();
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _saveSettings() async {
    if (_syncSettingsPath == null) return;
    try {
      final file = File(_syncSettingsPath!);
      final data = {
        'destinationFolderName': _destinationFolderName,
        'autoSyncEnabled': _autoSyncEnabled,
        'uploadInterval': _uploadInterval.name,
      };
      await file.writeAsString(jsonEncode(data));
    } catch (_) {}
  }

  Future<void> _saveSyncedTasks() async {
    if (_syncTasksPath == null) return;
    try {
      final file = File(_syncTasksPath!);
      final content = jsonEncode(_syncedTaskIds.toList());
      await file.writeAsString(content);
    } catch (_) {}
  }

  void _emitState() {
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }
}

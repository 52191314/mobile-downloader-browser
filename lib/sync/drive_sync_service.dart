import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart' as google_auth;
import 'package:path/path.dart' as p;

import '../downloader/downloader.dart';

enum DriveConnectionStatus {
  disconnected,
  connecting,
  connected,
  syncing,
  error,
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
  final List<DriveUploadResult> uploadHistory;
  final String? errorMessage;

  const DriveSyncState({
    required this.status,
    required this.account,
    required this.destinationFolderName,
    required this.autoSyncEnabled,
    required this.uploadHistory,
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

  GoogleDriveApiClient({GoogleSignIn? googleSignIn})
    : googleSignIn = googleSignIn ?? GoogleSignIn.instance;

  @override
  Future<DriveAccount> signIn() async {
    await _initializeSignIn();
    GoogleSignInAccount? account;
    try {
      final lightweight = googleSignIn.attemptLightweightAuthentication();
      account =
          (lightweight == null ? null : await lightweight) ??
          await googleSignIn.authenticate(scopeHint: _scopes);
    } on GoogleSignInException catch (error) {
      if (error.code == GoogleSignInExceptionCode.canceled) {
        throw const SignInCancelledException();
      }
      final description = error.description;
      throw StateError(
        description == null || description.isEmpty
            ? "Couldn't sign in to Google: ${error.code.name}. Check your account and try again."
            : "Couldn't sign in to Google: $description. Check your account and try again.",
      );
    }
    if (account == null) {
      throw const SignInCancelledException();
    }
    _account = account;
    _authClient = await _createAuthClient(account);
    return DriveAccount(
      email: account.email,
      displayName: account.displayName ?? account.email,
    );
  }

  @override
  Future<void> signOut() async {
    _authClient?.close();
    _authClient = null;
    _account = null;
    clearCache();
    await googleSignIn.signOut();
  }

  @override
  Future<DriveUploadResult> uploadFile({
    required File file,
    required String folderName,
  }) async {
    final api = await _driveApi();
    final parentId = await _ensureFolder(api, folderName);
    final length = await file.length();
    final created = await api.files.create(
      drive.File()
        ..name = p.basename(file.path)
        ..parents = [parentId],
      uploadMedia: drive.Media(file.openRead(), length),
      uploadOptions: drive.UploadOptions.resumable,
      $fields: 'id',
    );
    return DriveUploadResult(
      fileId: created.id ?? file.path,
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
    final api = await _driveApi();
    final parentId = await _ensureFolder(api, folderName);
    final torrentFolder = await _createFolder(
      api,
      p.basename(directory.path),
      parentId,
    );
    var totalBytes = 0;
    final Map<String, String> localFolderCache = {};
    await for (final entity in directory.list(recursive: true)) {
      if (entity is! File) continue;
      final relativePath = p.relative(entity.path, from: directory.path);
      final createdParents = await _ensureRelativeFolderWithCache(
        api,
        torrentFolder,
        p.dirname(relativePath),
        localFolderCache,
      );
      final length = await entity.length();
      totalBytes += length;
      await api.files.create(
        drive.File()
          ..name = p.basename(entity.path)
          ..parents = [createdParents],
        uploadMedia: drive.Media(entity.openRead(), length),
        uploadOptions: drive.UploadOptions.resumable,
        $fields: 'id',
      );
    }
    return DriveUploadResult(
      fileId: torrentFolder,
      folderName: folderName,
      sourcePath: directory.path,
      uploadedBytes: totalBytes,
    );
  }

  Future<void> _initializeSignIn() async {
    try {
      await googleSignIn.initialize(
        serverClientId: _serverClientId.isEmpty ? null : _serverClientId,
      );
    } on StateError {
      // GoogleSignIn.instance is process-wide and can only be initialized once.
    }
  }

  Future<google_auth.AuthClient> _createAuthClient(
    GoogleSignInAccount account,
  ) async {
    final authorization =
        await account.authorizationClient.authorizationForScopes(_scopes) ??
        await account.authorizationClient.authorizeScopes(_scopes);
    return authorization.authClient(scopes: _scopes);
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

  final Map<String, String> _folderIdCache = {};

  void clearCache() {
    _folderIdCache.clear();
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
      return id;
    }
    final id = await _createFolder(api, folderName, null);
    _folderIdCache[folderName] = id;
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

  Future<String> _ensureRelativeFolder(
    drive.DriveApi api,
    String parentId,
    String relativeFolder,
  ) async {
    if (relativeFolder == '.' || relativeFolder.isEmpty) {
      return parentId;
    }
    var currentParent = parentId;
    for (final segment in p.split(relativeFolder)) {
      currentParent = await _createFolder(api, segment, currentParent);
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

  DriveConnectionStatus _status = DriveConnectionStatus.disconnected;
  DriveAccount? _account;
  String _destinationFolderName;
  bool _autoSyncEnabled;
  String? _errorMessage;
  final List<DriveUploadResult> _uploadHistory = [];
  final Set<String> _syncedTaskIds = {};
  final Set<String> _syncingTaskIds = {};
  StreamSubscription<DownloadTask>? _queueSubscription;

  final StreamController<DriveSyncState> _stateController =
      StreamController<DriveSyncState>.broadcast();

  DriveSyncService({
    GoogleDriveClient? client,
    String destinationFolderName = 'Aurora Downloads',
    bool autoSyncEnabled = true,
  }) : client = client ?? GoogleDriveApiClient(),
       _destinationFolderName = destinationFolderName,
       _autoSyncEnabled = autoSyncEnabled;

  Stream<DriveSyncState> get onStateChanged => _stateController.stream;

  DriveSyncState get state => DriveSyncState(
    status: _status,
    account: _account,
    destinationFolderName: _destinationFolderName,
    autoSyncEnabled: _autoSyncEnabled,
    uploadHistory: List.unmodifiable(_uploadHistory),
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

  Future<void> disconnect() async {
    await client.signOut();
    if (client is GoogleDriveApiClient) {
      (client as GoogleDriveApiClient).clearCache();
    }
    _account = null;
    _syncedTaskIds.clear();
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
    _emitState();
  }

  void setAutoSyncEnabled(bool enabled) {
    _autoSyncEnabled = enabled;
    _emitState();
  }

  Future<DriveUploadResult?> syncCompletedTask(DownloadTask task) async {
    if (!_autoSyncEnabled || task.state != DownloadState.completed) {
      return null;
    }
    if (!isConnected) {
      return null;
    }
    if (_syncedTaskIds.contains(task.id)) {
      return null;
    }
    if (!_syncingTaskIds.add(task.id)) {
      return null;
    }

    try {

      final entityType = await FileSystemEntity.type(task.savePath);
      if (entityType == FileSystemEntityType.notFound) {
        _errorMessage = "Couldn't sync — completed file not found.";
        _setStatus(DriveConnectionStatus.error);
        return null;
      }

      _setStatus(DriveConnectionStatus.syncing);
      final result = entityType == FileSystemEntityType.directory
          ? await client.uploadDirectory(
              directory: Directory(task.savePath),
              folderName: _destinationFolderName,
            )
          : await client.uploadFile(
              file: File(task.savePath),
              folderName: _destinationFolderName,
            );
      _uploadHistory.insert(0, result);
      _syncedTaskIds.add(task.id);
      unawaited(_saveSyncedTasks());
      _errorMessage = null;
      _setStatus(DriveConnectionStatus.connected);
      return result;
    } catch (e) {
      _errorMessage = e.toString();
      _setStatus(DriveConnectionStatus.error);
      return null;
    } finally {
      _syncingTaskIds.remove(task.id);
    }
  }

  Future<void> dispose() async {
    await _queueSubscription?.cancel();
    await _stateController.close();
  }

  void _setStatus(DriveConnectionStatus status) {
    _status = status;
    _emitState();
  }

  Future<void> loadSyncedTasks(String appSupportPath) async {
    _syncTasksPath = '$appSupportPath/synced_drive_tasks.json';
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

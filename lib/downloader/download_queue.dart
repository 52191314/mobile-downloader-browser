import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path/path.dart' as p;
import 'models.dart';
import 'download_splitter.dart';
import 'file_combiner.dart';
import 'hls_downloader.dart';
import 'speed_limiter.dart';
import 'torrent_downloader.dart';
import '../logging/aurora_log.dart';
import '../platform/download_foreground_service.dart';
import '../settings/download_settings.dart' show ProxyType;
import 'file_classifier.dart';

void _logError(String context, Object error, [StackTrace? stack]) {
  debugPrint('[DownloadQueue] $context: $error');
  AuroraLog.instance.error(
    '$context: $error',
    category: LogCategory.download,
    screen: LogScreen.background,
    eventType: LogEventType.error,
    stackTrace: stack,
  );
}

/// Internal pair for relevance-scored search results used by
/// [DownloadQueue.searchTasks].
final class _ScoredTask {
  final DownloadTask task;
  final int score;
  const _ScoredTask({required this.task, required this.score});
}

class DownloadQueue {
  final Map<String, DownloadTask> _tasks = {};
  final Map<String, BaseDownloader> _splitters = {};
  final Map<String, StreamSubscription<DownloadTask>> _downloaderSubscriptions =
      {};
  final Map<String, Future<void>> _taskOperations = {};
  final List<String> _executionQueue = []; // Waiting task IDs
  final Set<String> _activeTasks = {}; // Running task IDs
  final Set<String> _publishingTasks = {};
  bool _isDisposed = false;
  int maxConcurrentDownloads;
  final bool enablePreemption;
  final bool useNativeTorrentEngine;
  int numChunksPerTask;
  final http.Client? httpClient;
  late final http.Client _client;
  final bool _ownsClient;
  CompletedDownloadPublisher? completedDownloadPublisher;
  bool wifiOnly = false;
  bool autoClassifyEnabled = true;
  bool remuxTsToMp4 = true;
  bool autoRetry = true;
  int retryLimit = 3;
  int minSpeedThresholdBytesPerSec = 0;
  int stallTimeoutSeconds = 20;
  double partialDownloadThreshold = 0.95;
  int minBytesBeforeFullRetry = 10 * 1024 * 1024; // 10 MB default
  final Map<String, int> _autoRetryAttempts = {};

  /// Global speed limiter shared across all active downloads.
  /// Set via [setSpeedLimit]; 0 = unlimited (no-op).
  final SpeedLimiter speedLimiter = SpeedLimiter();

  /// Current proxy configuration, applied via [applyProxySettings].
  ProxyType _proxyType = ProxyType.none;
  String _proxyHost = '';
  int _proxyPort = 8080;
  String _proxyUsername = '';
  String _proxyPassword = '';

  String? queuePath;
  bool _isLoading = false;
  bool _isSaving = false;
  Future<void>? _pendingSaveFuture;

  /// Debounce timer for persisting the queue to disk.  Without this the
  /// queue is written on every 500ms progress tick (from every active
  /// download), which saturates flash I/O and causes the UI progress bar
  /// to appear frozen.
  Timer? _saveDebounceTimer;

  /// True while the Android foreground service is active, so we avoid
  /// redundant start/stop calls.
  bool _fgServiceActive = false;

  /// Max completed/failed tasks kept for history before evicting oldest.
  /// Prevents unbounded growth of [_tasks] over months of use.
  int maxCompletedTasks = 500;

  /// Last time the foreground service notification was updated, used to
  /// throttle updates to at most once per second.
  DateTime _lastFgUpdate = DateTime(2000);

  final StreamController<DownloadTask> _taskUpdateController =
      StreamController<DownloadTask>.broadcast();
  Stream<DownloadTask> get onTaskUpdated => _taskUpdateController.stream;
  final StreamController<String> _taskRemovedController =
      StreamController<String>.broadcast();
  Stream<String> get onTaskRemoved => _taskRemovedController.stream;
  final StreamController<String> _warningController =
      StreamController<String>.broadcast();
  Stream<String> get onWarning => _warningController.stream;

  /// When set, the queue is in "resniff" mode.  Duplicate URLs that match
  /// the task with this ID will trigger [onResniffDuplicate] instead of
  /// being silently skipped.  Set to null to exit resniff mode.
  String? resniffPendingTaskId;

  /// Called when a URL is added that duplicates an existing task while
  /// [resniffPendingTaskId] is set.  The queue page uses this to ask the
  /// user whether to update the existing download or create a new one.
  /// Signature: (existingTaskId, newUrl, contentType)
  void Function(String existingTaskId, String newUrl, String? contentType)?
      onResniffDuplicate;

  DownloadQueue({
    this.maxConcurrentDownloads = 3,
    this.enablePreemption = true,
    this.useNativeTorrentEngine = false,
    this.numChunksPerTask = 8,
    this.httpClient,
    this.completedDownloadPublisher,
    this.autoRetry = true,
    this.retryLimit = 3,
  }) : _ownsClient = httpClient == null {
    _client = httpClient ?? _createDefaultClient();
  }

  static http.Client _createDefaultClient({ProxyType proxyType = ProxyType.none, String proxyHost = '', int proxyPort = 8080, String proxyUsername = '', String proxyPassword = ''}) {
    final inner = HttpClient()
      ..maxConnectionsPerHost = 32
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 90);

    if (proxyType != ProxyType.none && proxyHost.isNotEmpty) {
      inner.findProxy = (uri) {
        final scheme = proxyType == ProxyType.socks5 ? 'SOCKS5' : 'PROXY';
        final auth = (proxyUsername.isNotEmpty && proxyPassword.isNotEmpty)
            ? '$proxyUsername:$proxyPassword@'
            : '';
        return '$scheme ${auth}$proxyHost:$proxyPort';
      };
    }

    return IOClient(inner);
  }

  /// Applies proxy settings by recreating the shared HTTP client.
  /// Called when the user changes proxy configuration in Settings.
  void applyProxySettings(ProxyType type, String host, int port, String username, String password) {
    _proxyType = type;
    _proxyHost = host;
    _proxyPort = port;
    _proxyUsername = username;
    _proxyPassword = password;
    _client = _createDefaultClient(
      proxyType: type,
      proxyHost: host,
      proxyPort: port,
      proxyUsername: username,
      proxyPassword: password,
    );
  }

  /// Sets a global speed cap across all active HTTP/HLS downloads.
  /// [kbps] — kilobytes per second. 0 disables the limiter (no overhead).
  void setSpeedLimit(int kbps) {
    speedLimiter.setLimit(kbps);
  }

  void configure({
    int? maxConcurrentDownloads,
    int? numChunksPerTask,
    CompletedDownloadPublisher? completedDownloadPublisher,
    bool? autoClassifyEnabled,
    bool? remuxTsToMp4,
    bool? autoRetry,
    int? retryLimit,
    int? minSpeedThresholdBytesPerSec,
    int? stallTimeoutSeconds,
    double? partialDownloadThreshold,
    int? minBytesBeforeFullRetry,
  }) {
    if (maxConcurrentDownloads != null) {
      this.maxConcurrentDownloads = maxConcurrentDownloads.clamp(1, 12).toInt();
    }
    if (numChunksPerTask != null) {
      this.numChunksPerTask = numChunksPerTask.clamp(1, 16).toInt();
    }
    if (completedDownloadPublisher != null) {
      this.completedDownloadPublisher = completedDownloadPublisher;
    }
    if (autoClassifyEnabled != null) {
      this.autoClassifyEnabled = autoClassifyEnabled;
    }
    if (remuxTsToMp4 != null) {
      this.remuxTsToMp4 = remuxTsToMp4;
    }
    if (autoRetry != null) {
      this.autoRetry = autoRetry;
    }
    if (retryLimit != null) {
      this.retryLimit = retryLimit.clamp(1, 10).toInt();
    }
    if (minSpeedThresholdBytesPerSec != null) {
      this.minSpeedThresholdBytesPerSec = minSpeedThresholdBytesPerSec.clamp(0, 100 * 1024 * 1024).toInt();
    }
    if (stallTimeoutSeconds != null) {
      this.stallTimeoutSeconds = stallTimeoutSeconds.clamp(5, 120).toInt();
    }
    if (partialDownloadThreshold != null) {
      this.partialDownloadThreshold =
          partialDownloadThreshold.clamp(0.0, 1.0);
    }
    if (minBytesBeforeFullRetry != null) {
      this.minBytesBeforeFullRetry =
          minBytesBeforeFullRetry.clamp(0, 1024 * 1024 * 1024).toInt();
    }
    _schedule();
  }

  void addTask(DownloadTask task, {bool force = false}) {
    if (_isDisposed) return;
    _autoRetryAttempts.remove(task.id);
    if (!force) {
      // Duplicate prevention: skip if a task with the same URL is already
      // in the queue (idle, downloading, or paused). Completed/failed tasks
      // don't block re-downloading the same URL.
      final normalizedUrl = _normalizeUrl(task.url);
      final existing = _tasks.values.where(
        (t) =>
            _normalizeUrl(t.url) == normalizedUrl &&
            (t.state == DownloadState.idle ||
                t.state == DownloadState.downloading ||
                t.state == DownloadState.paused),
      );
      if (existing.isNotEmpty) {
        // When resniff mode is active and the existing task matches the
        // pending resniff task, delegate to the callback so the user can
        // choose "Update existing" or "Create new".
        if (resniffPendingTaskId != null &&
            onResniffDuplicate != null &&
            _tasks[resniffPendingTaskId]?.url == task.url) {
          onResniffDuplicate!(resniffPendingTaskId!, task.url, task.contentType);
          return;
        }
        _warn('Already in queue: ${task.url}');
        return;
      }
    }
    if (task.isBackupImport && task.state != DownloadState.completed) {
      task.state = DownloadState.paused;
    }
    _tasks[task.id] = task;

    // Completed tasks are kept for history only; no downloader needed.
    if (task.state == DownloadState.completed) {
      _emitTask(task);
      return;
    }

    // Blob URLs (e.g. blob:https://example.com/uuid) are created by
    // MSE-based players (HLS.js, etc.) and are NOT real network URLs —
    // they point to an in-memory streaming buffer inside the WebView and
    // cannot be downloaded via HTTP. Fail immediately with a clear message
    // instead of crashing the downloader with "No host specified in URI".
    if (task.url.startsWith('blob:')) {
      task.state = DownloadState.failed;
      task.errorMessage =
          'Blob URLs (MediaSource) cannot be downloaded directly. '
          'Look for the .m3u8 or .mpd playlist URL in the captured media list instead.';
      _emitTask(task);
      return;
    }

    // Auto-classify: inject category subfolder into savePath.
    if (autoClassifyEnabled && task.state != DownloadState.completed) {
      _applyAutoClassification(task);
    }

    if (!_splitters.containsKey(task.id)) {
      BaseDownloader downloader;
      if (task.url.startsWith('magnet:') || task.url.endsWith('.torrent')) {
        downloader = TorrentDownloader(
          task: task,
          client: _client,
          useNativeEngine: useNativeTorrentEngine,
        );
      } else if (_isHlsTask(task)) {
        downloader = HlsDownloader(
          task: task,
          client: _client,
          maxConcurrentSegments: numChunksPerTask,
          speedLimiter: speedLimiter,
        );
      } else {
        downloader = DownloadSplitter(
          task: task,
          client: _client,
          numChunks: numChunksPerTask,
          minSpeedBytesPerSec: minSpeedThresholdBytesPerSec,
          stallTimeoutSeconds: stallTimeoutSeconds,
          partialDownloadThreshold: partialDownloadThreshold,
          remuxTsToMp4: remuxTsToMp4,
          speedLimiter: speedLimiter,
        );
      }
      _splitters[task.id] = downloader;

      _downloaderSubscriptions[task.id] = downloader.onTaskUpdated.listen((
        updatedTask,
      ) async {
        _emitTask(updatedTask);
        if (updatedTask.state == DownloadState.completed ||
            updatedTask.state == DownloadState.failed) {
          final wasActive = _activeTasks.remove(updatedTask.id);
          if (updatedTask.state == DownloadState.completed) {
            _autoRetryAttempts.remove(updatedTask.id);
            if (wasActive) {
              if (autoClassifyEnabled) {
                final oldPath = updatedTask.savePath;
                _applyAutoClassification(updatedTask);
                final newPath = updatedTask.savePath;
                if (oldPath != newPath) {
                  try {
                    final oldFile = File(oldPath);
                    if (await oldFile.exists()) {
                      final newFile = File(newPath);
                      await newFile.parent.create(recursive: true);
                      await oldFile.rename(newPath);
                      AuroraLog.instance.info(
                        'Auto-classified completed file moved from $oldPath to $newPath',
                        category: LogCategory.download,
                        screen: LogScreen.background,
                        eventType: LogEventType.fileIo,
                        taskId: updatedTask.id,
                      );
                    }
                  } catch (e) {
                    updatedTask.savePath = oldPath;
                    AuroraLog.instance.error(
                      'Failed to move auto-classified file: $e',
                      category: LogCategory.download,
                      screen: LogScreen.background,
                      eventType: LogEventType.error,
                      taskId: updatedTask.id,
                    );
                  }
                }
              }
              unawaited(_publishCompletedTask(updatedTask));
            }
          }
          _schedule();

          if (updatedTask.state == DownloadState.failed) {
            AuroraLog.instance.error(
              'Download failed: ${updatedTask.savePath.split("/").last}. Error: ${updatedTask.errorMessage}',
              category: LogCategory.download,
              screen: LogScreen.background,
              eventType: LogEventType.error,
              taskId: updatedTask.id,
            );
            if (autoRetry && !updatedTask.isBackupImport) {
              final isStallOrTruncation =
                  (updatedTask.errorMessage ?? '').contains('Speed stall') ||
                      (updatedTask.errorMessage ?? '')
                          .contains('not all chunks completed');
              final alreadyDownloadedEnough =
                  updatedTask.downloadedBytes >= minBytesBeforeFullRetry;
              if (isStallOrTruncation && alreadyDownloadedEnough) {
                // Don't full-restart. Mark as failed with a
                // salvageable-data message so the user can Force Merge.
                AuroraLog.instance.error(
                  'Skipped auto-retry for '
                  '${updatedTask.savePath.split("/").last}: '
                  'already downloaded '
                  '${(updatedTask.downloadedBytes / 1024 / 1024).toStringAsFixed(1)} MB. '
                  'User can use Force Merge or manual retry.',
                  category: LogCategory.download,
                  screen: LogScreen.background,
                  eventType: LogEventType.error,
                  taskId: updatedTask.id,
                );
                final alreadyMb =
                    (updatedTask.downloadedBytes / 1024 / 1024).toStringAsFixed(1);
                updatedTask.errorMessage =
                    '[Download stalled near completion] '
                    '$alreadyMb MB already downloaded. '
                    'Use "Force Merge" to salvage, or tap Retry to resume.';
                _emitTask(updatedTask);
                return;
              }
              final attempts = _autoRetryAttempts[updatedTask.id] ?? 0;
              if (attempts < retryLimit) {
                final nextAttempt = attempts + 1;
                _autoRetryAttempts[updatedTask.id] = nextAttempt;
                final originalError = updatedTask.errorMessage ?? 'Unknown error';
                updatedTask.errorMessage = '[Retrying in 2s, attempt $nextAttempt/$retryLimit] $originalError';
                _emitTask(updatedTask);

                Future.delayed(const Duration(seconds: 2), () {
                  if (_tasks[updatedTask.id]?.state == DownloadState.failed) {
                    retryHlsTaskWithRefresh(updatedTask.id, forceReload: false, isAutoRetry: true);
                  }
                });
              } else {
                AuroraLog.instance.error(
                  'Auto-retry limits exceeded for ${updatedTask.savePath.split("/").last}.',
                  category: LogCategory.download,
                  screen: LogScreen.background,
                  eventType: LogEventType.error,
                  taskId: updatedTask.id,
                );
                final originalError = updatedTask.errorMessage ?? 'Unknown error';
                final cleanError = originalError.replaceFirst(RegExp(r'^\[Retrying in 2s, attempt \d+/\d+\] '), '');
                updatedTask.errorMessage = '[Auto-retry failed after $retryLimit attempts] $cleanError';
                _emitTask(updatedTask);
              }
            }
          }
        }
      });
    }

    if (task.state == DownloadState.idle) {
      if (!_executionQueue.contains(task.id)) {
        _executionQueue.add(task.id);
      }
    }
    _schedule();
    if (queuePath != null && !_isLoading) {
      unawaited(saveToFile(queuePath!));
    }
  }

  void pauseTask(String taskId) {
    unawaited(pauseTaskAsync(taskId));
  }

  Future<void> pauseTaskAsync(String taskId) async {
    final task = _tasks[taskId];
    if (task == null) return;
    _autoRetryAttempts.remove(taskId);

    final wasActive = _activeTasks.remove(taskId);
    _executionQueue.remove(taskId);
    task.state = DownloadState.paused;
    _emitTask(task);

    if (_activeTasks.contains(taskId)) {
      _activeTasks.remove(taskId);
    }

    Future<void>? pauseFuture;
    if (wasActive) {
      final splitter = _splitters[taskId];
      if (splitter != null) {
        pauseFuture = _runTaskOperation(
          taskId,
          () => _pauseDownloader(splitter, DownloadState.paused),
        );
      }
    }
    _schedule();
    if (queuePath != null && !_isLoading) {
      unawaited(saveToFile(queuePath!));
    }
    if (pauseFuture != null) {
      await pauseFuture;
    }
  }

  void resumeTask(String taskId) {
    unawaited(resumeTaskAsync(taskId));
  }

  void cancelTask(String taskId) {
    unawaited(cancelTaskAsync(taskId));
  }

  Future<void> cancelTaskAsync(String taskId) async {
    final task = _tasks[taskId];
    if (task == null) return;

    _autoRetryAttempts.remove(taskId);
    _activeTasks.remove(taskId);
    _executionQueue.remove(taskId);

    // Stop the downloader if active
    final splitter = _splitters[taskId];
    if (splitter != null) {
      await _runTaskOperation(
        taskId,
        () => _pauseDownloader(splitter, DownloadState.paused),
      );
    }

    // Clean up files (temp files and completed/partial files)
    try {
      final tempDir = Directory(task.tempDir);
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
      if (task.state != DownloadState.completed) {
        final type = await FileSystemEntity.type(task.savePath);
        if (type == FileSystemEntityType.file) {
          await File(task.savePath).delete();
        } else if (type == FileSystemEntityType.directory) {
          await Directory(task.savePath).delete(recursive: true);
        }
      }
    } catch (e, s) {
      _logError('Failed to clean files for cancelled task $taskId', e, s);
    }

    // Cancel stream subscriptions and dispose splitters
    final sub = _downloaderSubscriptions.remove(taskId);
    if (sub != null) {
      await sub.cancel();
    }
    final dispSplitter = _splitters.remove(taskId);
    if (dispSplitter != null) {
      await dispSplitter.dispose();
    }

    _tasks.remove(taskId);
    if (!_taskRemovedController.isClosed) _taskRemovedController.add(taskId);
    _schedule();
    if (queuePath != null && !_isLoading) {
      unawaited(saveToFile(queuePath!));
    }
  }

  /// User-initiated force-merge for a failed task. Combines whatever
  /// chunk bytes are still on disk into a usable output file at
  /// [task.savePath] without re-downloading. Returns true if the
  /// destination was written, false otherwise (no data, refused for a
  /// still-downloading task, or unknown task id).
  Future<bool> forceMergeTask(String taskId) async {
    final task = _tasks[taskId];
    if (task == null) return false;

    if (task.state == DownloadState.downloading) {
      AuroraLog.instance.error(
        'Force merge refused for '
        '${task.savePath.split("/").last}: task is still downloading.',
        category: LogCategory.download,
        screen: LogScreen.background,
        eventType: LogEventType.error,
        taskId: task.id,
      );
      task.errorMessage = '[Force merge refused] Task is still downloading.';
      _emitTask(task);
      return false;
    }

    // Release any active downloader so chunk file handles are free.
    final splitter = _splitters[taskId];
    if (splitter != null) {
      await _runTaskOperation(
        taskId,
        () => _pauseDownloader(splitter, DownloadState.paused),
      );
    }

    task.state = DownloadState.merging;
    task.downloadedBytes = 0;
    task.totalBytes = task.chunks.length;
    _emitTask(task);

    try {
      // Pull chunks from in-memory task (loaded from meta.json in _loadMeta
      // or already on the in-memory model).
      final result = await FileCombiner.combinePartial(
        chunks: task.chunks,
        tempDir: task.tempDir,
        destination: File(task.savePath),
        onProgress: (chunkIndex, totalChunks) {
          task.downloadedBytes = chunkIndex;
          task.totalBytes = totalChunks;
          _emitTask(task);
        },
      );

      if (!result.hasData) {
        task.state = DownloadState.failed;
        task.errorMessage =
            '[Force merge failed] No chunk data on disk to merge.';
        _emitTask(task);
        return false;
      }

      task.state = DownloadState.completed;
      task.downloadedBytes = result.bytesWritten;
      task.totalBytes = result.bytesWritten;
      task.actualHash = null;
      task.errorMessage = null;

      if (autoClassifyEnabled) {
        final oldPath = task.savePath;
        _applyAutoClassification(task);
        final newPath = task.savePath;
        if (oldPath != newPath) {
          try {
            final oldFile = File(oldPath);
            if (await oldFile.exists()) {
              final newFile = File(newPath);
              await newFile.parent.create(recursive: true);
              await oldFile.rename(newPath);
            }
          } catch (_) {
            task.savePath = oldPath;
          }
        }
      }

      _activeTasks.remove(taskId);
      _executionQueue.remove(taskId);
      _autoRetryAttempts.remove(taskId);

      // Clean up the temp directory now that the merge succeeded.
      try {
        final tempDir = Directory(task.tempDir);
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (e, s) {
        _logError('Failed to clean temp dir after force merge', e, s);
      }

      _emitTask(task);
      syncForegroundService();
      unawaited(_publishCompletedTask(task));
      if (queuePath != null && !_isLoading) {
        unawaited(saveToFile(queuePath!));
      }
      return true;
    } catch (e, s) {
      _logError('Exception during force merge', e, s);
      task.state = DownloadState.failed;
      task.errorMessage = '[Force merge failed] Error: $e';
      _emitTask(task);
      if (queuePath != null && !_isLoading) {
        unawaited(saveToFile(queuePath!));
      }
      return false;
    }
  }

  /// Retry a failed HLS download by asking the sniffer to refresh the token
  /// (reload the source page and re-query for a fresh HLS URL), then re-run
  /// the download. Falls back to a simple re-run if no refresh callback is
  /// registered or no fresh URL is obtained.
  void retryHlsTaskWithRefresh(
    String taskId, {
    bool forceReload = false,
    bool isAutoRetry = false,
  }) {
    unawaited(retryHlsTaskWithRefreshAsync(
      taskId,
      forceReload: forceReload,
      isAutoRetry: isAutoRetry,
    ));
  }

  Future<void> retryHlsTaskWithRefreshAsync(
    String taskId, {
    bool forceReload = false,
    bool isAutoRetry = false,
  }) async {
    if (!isAutoRetry) {
      _autoRetryAttempts.remove(taskId);
    }
    final splitter = _splitters[taskId];
    if (splitter is HlsDownloader) {
      await _runTaskOperation(taskId, () async {
        try {
          await splitter.retryWithRefresh(forceReload: forceReload);
        } catch (e, s) {
          _logError('Retry failed for task $taskId', e, s);
          _warn('Retry failed for task "$taskId": $e');
        }
      });
    } else {
      // Non-HLS task — just resume
      await resumeTaskAsync(taskId, isAutoRetry: isAutoRetry);
    }
  }

  Future<void> resumeTaskAsync(String taskId, {bool isAutoRetry = false}) async {
    final task = _tasks[taskId];
    if (task == null) return;
    if (!isAutoRetry) {
      _autoRetryAttempts.remove(taskId);
    }

    task.state = DownloadState.idle;
    if (!_executionQueue.contains(taskId) && !_activeTasks.contains(taskId)) {
      _executionQueue.add(taskId);
    }
    final pending = _taskOperations[taskId];
    if (pending != null) {
      await pending;
    }
    _schedule();
    if (queuePath != null && !_isLoading) {
      unawaited(saveToFile(queuePath!));
    }
  }

  void updatePriority(String taskId, DownloadPriority newPriority) {
    final task = _tasks[taskId];
    if (task == null) return;

    task.priority = newPriority;
    _schedule();
  }

  Future<void> _waitAndSave(String path) async {
    while (_isSaving) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    _pendingSaveFuture = null;
    await saveToFile(path);
  }

  Future<void> saveToFile(String path) async {
    if (_isSaving) {
      if (_pendingSaveFuture == null) {
        _pendingSaveFuture = _waitAndSave(path);
      }
      return _pendingSaveFuture;
    }

    _isSaving = true;
    try {
      final file = File(path);
      final fileDir = file.parent;
      if (!await fileDir.exists()) {
        await fileDir.create(recursive: true);
      }
      final tempFile = File('$path.tmp');
      final tempDir = tempFile.parent;
      if (!await tempDir.exists()) {
        await tempDir.create(recursive: true);
      }
      final backupFile = File('$path.bak');
      // Persist all tasks, including completed history, so the queue survives
      // app restarts and ADB installs.
      final data = _tasks.values.map((t) => t.toJson()).toList(growable: false);
      final jsonString = await Isolate.run(() => jsonEncode(data));
      await tempFile.writeAsString(jsonString, flush: true);
      // Backup existing file (best-effort).
      try {
        if (await file.exists()) {
          await file.rename(backupFile.path);
        }
      } catch (_) {
        // Backup failure is non-fatal — the new file can still be written.
      }
      // Atomically replace with the new data.
      try {
        await tempFile.rename(file.path);
      } catch (renameError) {
        // If the rename fails, the temp file is left behind and will be
        // picked up on the next save attempt.
      }
      // Clean up backup (best-effort).
      try {
        if (await backupFile.exists()) {
          await backupFile.delete();
        }
      } catch (_) {}
    } catch (e, s) {
      _logError('Failed to save queue to file', e, s);
      _warn('Failed to save download queue: $e');
    } finally {
      _isSaving = false;
    }
  }

  Future<void> loadFromFile(String path) async {
    _isLoading = true;
    final file = File(path);
    try {
      if (!await file.exists()) return;
      final json = await file.readAsString();
      // Run JSON parsing on a background isolate to avoid blocking the UI
      // thread.  This matters when the queue file is large (many completed
      // tasks in history).
      final decoded = await Isolate.run(() => jsonDecode(json));
      if (decoded is! List) {
        await _preserveCorruptQueueFile(file, 'Queue file was not a list.');
        return;
      }
      // Derive the persistent downloads_tmp directory from the queue file
      // path (e.g. /data/data/.../files/download_queue.json → downloads_tmp).
      final appSupportDir = file.parent.path;
      final persistentDownloadsTmp = '$appSupportDir/downloads_tmp';

      for (final item in decoded) {
        if (item is! Map) continue;
        try {
          // Re-base tempDir from the old getTemporaryDirectory() (non-persistent)
          // to the persistent getApplicationSupportDirectory()/downloads_tmp so
          // partial download bytes survive OS cache clearing.
          final tempDirStr = (item as Map)['tempDir'] as String? ?? '';
          if (tempDirStr.isNotEmpty) {
            final normalized = tempDirStr.replaceAll('\\', '/');
            if (!normalized.contains('downloads_tmp')) {
              // Extract basename (e.g. 'temp_1783417343907' or '1783417343907')
              final lastSlash = normalized.lastIndexOf('/');
              final basename = lastSlash != -1
                  ? normalized.substring(lastSlash + 1)
                  : normalized;
              (item as Map)['tempDir'] =
                  '$persistentDownloadsTmp/$basename';
            }
          }

          final task = DownloadTask.fromJson(Map<String, dynamic>.from(item));
          // Reset in-flight states to idle so _schedule() re-queues them.
          // Without this, tasks saved as 'downloading' are never re-started
          // because addTask only puts 'idle' tasks into the execution queue.
          if (task.isBackupImport && task.state != DownloadState.completed) {
            task.state = DownloadState.paused;
          } else if (task.state == DownloadState.downloading) {
            task.state = DownloadState.idle;
          } else if (task.state == DownloadState.merging) {
            task.state = DownloadState.failed;
            task.errorMessage = '[Merge interrupted] Rename the task to a shorter name and retry.';
          }
          addTask(task);
        } catch (e, s) {
          _logError('Skipped loading corrupted task in queue file', e, s);
        }
        // Yield to the event loop between tasks so the UI can process
        // frames and download updates even during a large queue restore.
        await Future.delayed(Duration.zero);
      }
    } catch (e, s) {
      _logError('Failed to load queue from file', e, s);
      await _preserveCorruptQueueFile(file, e.toString());
    } finally {
      _isLoading = false;
    }

    // Recover any tasks from previous corrupt backups
    await _recoverCorruptQueueFiles(path);
  }

  void _schedule() {
    if (_isDisposed) return;
    // 1. Sort execution queue: priority descending, then createdAt ascending
    _executionQueue.sort((aId, bId) {
      final a = _tasks[aId]!;
      final b = _tasks[bId]!;
      return a.compareTo(b);
    });

    // 2. Preemptive check
    if (enablePreemption &&
        _activeTasks.isNotEmpty &&
        _executionQueue.isNotEmpty) {
      bool preempted;
      do {
        preempted = false;

        // Find active task with lowest priority
        String? lowestActiveId;
        DownloadPriority lowestActivePriority = DownloadPriority.high;
        for (var activeId in _activeTasks) {
          final activeTask = _tasks[activeId]!;
          if (activeTask.priority.value < lowestActivePriority.value) {
            lowestActivePriority = activeTask.priority;
            lowestActiveId = activeId;
          }
        }

        // Find waiting task with highest priority
        final highestQueuedId = _executionQueue.first;
        final highestQueuedTask = _tasks[highestQueuedId]!;

        // Preempt if waiting task is higher priority than lowest running task
        if (lowestActiveId != null &&
            highestQueuedTask.priority.value > lowestActivePriority.value) {
          _preemptTask(lowestActiveId);
          preempted = true;
        }
      } while (preempted && _executionQueue.isNotEmpty);
    }

    // 3. Start tasks up to capacity
    while (_activeTasks.length < maxConcurrentDownloads &&
        _executionQueue.isNotEmpty) {
      final nextIndex = _executionQueue.indexWhere(
        (id) => !_taskOperations.containsKey(id),
      );
      if (nextIndex == -1) break;

      final nextTaskId = _executionQueue.removeAt(nextIndex);
      _activeTasks.add(nextTaskId);
      final task = _tasks[nextTaskId]!;
      task.state = DownloadState.downloading;
      try {
        _emitTask(task);
      } catch (e, s) {
        // _emitTask can throw if the stream controller is in an error state.
        // Remove from active set so it doesn't hang in 'downloading' forever.
        _logError('Failed to emit state for task $nextTaskId', e, s);
        _activeTasks.remove(nextTaskId);
        task.state = DownloadState.idle;
        continue;
      }
      _startTask(nextTaskId);
    }
    // Keep the foreground service in sync with the current active count.
    syncForegroundService();
  }

  void _preemptTask(String taskId) {
    final task = _tasks[taskId]!;
    final splitter = _splitters[taskId]!;

    _activeTasks.remove(taskId);
    _executionQueue.add(taskId);
    task.state = DownloadState.idle;
    _emitTask(task);
    unawaited(
      _runTaskOperation(
        taskId,
        () => _pauseDownloader(splitter, DownloadState.idle),
      ),
    );
  }

  Future<void> _startTask(String taskId) async {
    final pendingOperation = _taskOperations[taskId];
    if (pendingOperation != null) {
      await pendingOperation;
      if (!_activeTasks.contains(taskId) || _isDisposed) return;
    }
    try {
      final splitter = _splitters[taskId];
      if (splitter == null) {
        // Task was cancelled/disposed between scheduling and start.
        // Remove from active set so it doesn't hang forever.
        _logError(
          'Splitter for task $taskId vanished before start (cancelled?)',
          '',
        );
        _activeTasks.remove(taskId);
        final task = _tasks[taskId];
        if (task != null) {
          task.state = DownloadState.idle;
          _emitTask(task);
        }
        return;
      }
      await splitter.start();
    } catch (e, s) {
      _logError('Failed to start splitter task', e, s);
    }
  }

  List<DownloadTask> get queuedTasks =>
      _executionQueue.map((id) => _tasks[id]!).toList();

  List<DownloadTask> get activeTasks =>
      _activeTasks.map((id) => _tasks[id]!).toList();

  List<DownloadTask> get allTasks => List.unmodifiable(_tasks.values);

  DownloadTask? getTask(String id) => _tasks[id];

  static String _normalizeUrl(String url) {
    // Matches SniffedMediaCache.normalizeUrl — strips common tracking params.
    const trackingParams = {
      'utm_source', 'utm_medium', 'utm_campaign', 'utm_term', 'utm_content',
      'fbclid', 'gclid', 'msclkid', 'ref', 'source', 'si', 'pi',
      '_hsenc', '_hsmi', 'trk',
    };
    if (url.startsWith('blob:')) return url;
    try {
      final uri = Uri.parse(url);
      final params = Map<String, List<String>>.from(uri.queryParametersAll);
      params.removeWhere((k, _) => trackingParams.contains(k.toLowerCase()));
      return uri
          .replace(queryParameters: params.isEmpty ? null : params)
          .toString();
    } catch (_) {
      return url;
    }
  }

  bool urlExists(String url, {bool activeOnly = false}) {
    final normalized = _normalizeUrl(url);
    return _tasks.values.any((t) {
      if (_normalizeUrl(t.url) != normalized) return false;
      if (activeOnly) {
        return t.state == DownloadState.idle ||
            t.state == DownloadState.downloading ||
            t.state == DownloadState.paused;
      }
      return true;
    });
  }

  // ---------------------------------------------------------------------------
  // Search, sort, and filter helpers
  // ---------------------------------------------------------------------------

  /// Convenience: all tasks whose state is [DownloadState.completed].
  List<DownloadTask> get completedTasks =>
      _tasks.values.where((t) => t.state == DownloadState.completed).toList();

  /// Convenience: all tasks whose state is [DownloadState.failed].
  List<DownloadTask> get failedTasks =>
      _tasks.values.where((t) => t.state == DownloadState.failed).toList();

  /// Convenience: all tasks that are currently active (downloading), queued
  /// (idle), or paused — i.e. not in a terminal state.
  List<DownloadTask> get activeAndQueuedTasks => _tasks.values
      .where((t) => t.state != DownloadState.completed &&
          t.state != DownloadState.failed)
      .toList();

  /// Returns the filename portion of a task's [savePath], URL-decoded.
  /// Matching is case-insensitive; the query is split into space-separated
  /// tokens and every token must match at least one searched field.
  ///
  /// Searched fields and the weight of each hit:
  ///  1. URL (highest weight — direct match)
  ///  2. Filename (medium weight)
  ///  3. Content-type label (low weight)
  ///  4. Source page title or URL (low weight)
  ///  5. Error-message keywords when [includeFailedDetails] is true
  ///
  /// Returns results sorted by relevance (best match first).
  List<DownloadTask> searchTasks(
    String query, {
    bool includeFailedDetails = false,
    Iterable<DownloadTask>? targetTasks,
  }) {
    final trimmed = query.trim();
    final tasksSource = targetTasks ?? _tasks.values;
    if (trimmed.isEmpty) return tasksSource.toList();

    final tokens = trimmed.toLowerCase().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    if (tokens.isEmpty) return tasksSource.toList();

    final scored = <_ScoredTask>[];

    for (final task in tasksSource) {
      int score = 0;
      final urlLower = task.url.toLowerCase();
      final nameLower = _fileName(task.savePath).toLowerCase();
      final ext = _extensionFromUrl(task.url);
      final fileExt = _extensionFromUrl(task.savePath);
      final contentTypeLower = (task.contentType ?? '').toLowerCase();
      final sourcePageLower = (task.sourcePageUrl ?? '').toLowerCase();
      final errorLower = includeFailedDetails
          ? (task.errorMessage ?? '').toLowerCase()
          : '';

      for (final token in tokens) {
        // URL match — strongest signal
        if (urlLower.contains(token)) {
          // Prefer domain+path matches over query-param matches
          if (urlLower.startsWith('https://$token') ||
              urlLower.startsWith('http://$token') ||
              urlLower.contains('/$token/') ||
              urlLower.contains('.$token/')) {
            score += 50;
          } else {
            score += 30;
          }
        }
        // Filename match
        if (nameLower.contains(token)) {
          score += 20;
        }
        // Extension match (e.g. "mp4", "m3u8")
        if (ext != null && ext == '.$token') score += 15;
        if (fileExt != null && fileExt == '.$token') score += 15;
        // Content-type match
        if (contentTypeLower.contains(token)) score += 10;
        // Source page match
        if (sourcePageLower.contains(token)) score += 8;
        // Error message match (when explicitly opted in)
        if (includeFailedDetails && errorLower.contains(token)) score += 5;
      }

      if (score > 0) {
        scored.add(_ScoredTask(task: task, score: score));
      }
    }

    // Sort by score descending, then by date descending for ties
    scored.sort((a, b) {
      final c = b.score.compareTo(a.score);
      if (c != 0) return c;
      return b.task.createdAt.compareTo(a.task.createdAt);
    });
    return scored.map((s) => s.task).toList();
  }

  /// Returns a new list of tasks that match all of the supplied criteria.
  /// When a parameter is `null` or empty that criterion is not applied.
  ///
  /// Parameters are AND-ed together (all must match).  Pass `states` to
  /// constrain the result to a specific set of [DownloadState] values.
  /// Pass [query] to perform full-text search (delegates to [searchTasks],
  /// then the other filters are applied on top).
  ///
  /// When [sortBy] is set the result is sorted accordingly; otherwise the
  /// default ordering (priority descending, then creation date ascending)
  /// used by [DownloadTask.compareTo] is preserved.
  List<DownloadTask> queryTasks({
    Set<DownloadState>? states,
    String? query,
    TaskSortField? sortBy,
    bool sortDescending = true,
    DateTime? fromDate,
    DateTime? toDate,
    int? minSize,
    int? maxSize,
    String? urlFilter,
    bool includeFailedDetails = false,
  }) {
      Iterable<DownloadTask> results = _tasks.values;

    // 1. State filter
    if (states != null && states.isNotEmpty) {
      results = results.where((t) => states.contains(t.state));
    }

    // 2. Date range
    if (fromDate != null) {
      results = results.where((t) => !t.createdAt.isBefore(fromDate));
    }
    if (toDate != null) {
      results =
          results.where((t) => !t.createdAt.isAfter(toDate.add(const Duration(days: 1))));
    }

    // 3. Size range
    if (minSize != null) {
      results = results.where((t) => t.totalBytes >= minSize);
    }
    if (maxSize != null) {
      results = results.where((t) => t.totalBytes <= maxSize);
    }

    // 4. URL exact-match filter (normalized)
    if (urlFilter != null && urlFilter.isNotEmpty) {
      final normalized = _normalizeUrl(urlFilter);
      results = results.where((t) => _normalizeUrl(t.url) == normalized);
    }

    // 5. Full-text search (runs after hard filters to reduce work)
    if (query != null && query.trim().isNotEmpty) {
      results = searchTasks(
        query,
        includeFailedDetails: includeFailedDetails,
        targetTasks: results,
      );
    }

    // 6. Sort
    final list = results.toList();
    if (sortBy != null) {
      _sortTasks(list, sortBy, descending: sortDescending);
    }

    return list;
  }

  /// Sorts [tasks] in-place by [field].
  static void _sortTasks(
    List<DownloadTask> tasks,
    TaskSortField field, {
    bool descending = true,
  }) {
    tasks.sort((a, b) {
      int c;
      switch (field) {
        case TaskSortField.date:
          c = a.createdAt.compareTo(b.createdAt);
        case TaskSortField.name:
          c = _fileName(a.savePath)
              .toLowerCase()
              .compareTo(_fileName(b.savePath).toLowerCase());
        case TaskSortField.size:
          final aSize = a.totalBytes;
          final bSize = b.totalBytes;
          if (aSize < 0 && bSize < 0) {
            c = 0;
          } else if (aSize < 0) {
            c = 1;
          } else if (bSize < 0) {
            c = -1;
          } else {
            c = aSize.compareTo(bSize);
          }
        case TaskSortField.priority:
          c = a.priority.compareTo(b.priority);
        case TaskSortField.state:
          c = a.state.index.compareTo(b.state.index);
        case TaskSortField.speed:
          c = a.speed.compareTo(b.speed);
      }
      return descending ? -c : c;
    });
  }

  /// Returns the last path segment of [path] (URL or file path).
  static String _fileName(String path) {
    final normalized = path.replaceAll('\\', '/');
    return normalized.split('/').last;
  }

  /// Returns the lowercased file extension (including the dot) from a URL
  /// or file path, or `null` when there is no recognizable extension.
  static String? _extensionFromUrl(String url) {
    try {
      final uri = Uri.parse(url);
      final path = uri.path;
      final slash = path.lastIndexOf('/');
      final lastSegment = slash >= 0 ? path.substring(slash + 1) : path;
      final dot = lastSegment.lastIndexOf('.');
      if (dot <= 0 || dot == lastSegment.length - 1) return null;
      return lastSegment.substring(dot).toLowerCase();
    } catch (_) {
      return null;
    }
  }

  /// Applies auto-classification to [task.savePath], inserting a category
  /// subfolder (e.g. "Videos", "Documents") between `/completed/` and the
  /// filename. No-op when the path already has a user-chosen subfolder or
  /// does not live under `/completed/`.
  void _applyAutoClassification(DownloadTask task) {
    final normalized = task.savePath.replaceAll('\\', '/');
    const sep = '/completed/';
    final idx = normalized.lastIndexOf(sep);
    // Not under completed/ – skip (torrents, custom exports, etc.)
    if (idx == -1) return;
    var after = normalized.substring(idx + sep.length);
    // Already has a subfolder (user's manual choice) – skip, EXCEPT if the
    // subfolder is "Other" (the fallback category), in which case we allow
    // re-classifying it when the download completes with a valid extension.
    if (after.contains('/')) {
      final parts = after.split('/');
      if (parts.first != 'Other') return;
      after = parts.last;
    }

    final category = FileClassifier.classify(after);
    final label = FileClassifier.categoryLabel(category);
    final base = task.savePath.substring(0, idx + sep.length - 1);
    task.savePath = '$base/$label/$after';
  }

  /// Removes oldest completed/failed tasks when the history limit is exceeded.
  /// This prevents unbounded memory and JSON-serialization growth.
  void _evictOldCompletedTasks() {
    if (maxCompletedTasks <= 0 || _tasks.length <= maxCompletedTasks) return;

    // Collect terminal (completed/failed) task IDs sorted by last update
    // (most recent first). We keep the newest ones.
    final terminal = _tasks.entries
        .where(
          (e) =>
              e.value.state == DownloadState.completed ||
              e.value.state == DownloadState.failed,
        )
        .toList();
    terminal.sort((a, b) => b.value.createdAt.compareTo(a.value.createdAt));

    final toKeep = maxCompletedTasks;
    if (terminal.length <= toKeep) return;

    // Remove the oldest terminal tasks beyond the limit.
    for (var i = toKeep; i < terminal.length; i++) {
      // Skip if the task is still referenced by active operations.
      final id = terminal[i].key;
      if (_activeTasks.contains(id) || _taskOperations.containsKey(id)) {
        continue;
      }
      _tasks.remove(id);
      if (!_taskRemovedController.isClosed) _taskRemovedController.add(id);
      _splitters.remove(id);
      _downloaderSubscriptions.remove(id)?.cancel();
      _autoRetryAttempts.remove(id);
    }
  }

  Future<void> _publishCompletedTask(DownloadTask task) async {
    if (completedDownloadPublisher == null ||
        task.publicUri != null ||
        _publishingTasks.contains(task.id)) {
      return;
    }
    _publishingTasks.add(task.id);
    try {
      final published = await completedDownloadPublisher!.publishCompletedFile(
        task,
      );
      if (published != null) {
        task.publicUri = published.uri;
        task.publicPathLabel = published.pathLabel;
        task.publishErrorMessage = null;
        // Delete the internal copy — the file is now in public Downloads.
        try {
          final internalFile = File(task.savePath);
          if (await internalFile.exists()) {
            await internalFile.delete();
          }
        } catch (_) {
          // Non-fatal — file may be in use or already deleted.
        }
      }
    } catch (error) {
      task.publishErrorMessage = error.toString();
      AuroraLog.instance.error(
        'Failed to publish completed file: ${task.savePath.split("/").last}. Error: $error',
        category: LogCategory.download,
        screen: LogScreen.background,
        eventType: LogEventType.error,
        taskId: task.id,
      );
    } finally {
      _publishingTasks.remove(task.id);
      _emitTask(task);
    }
  }

  Future<void> dispose() async {
    _isDisposed = true;
    final activeIds = List<String>.from(_activeTasks);
    _executionQueue.clear();
    try {
      await Future.wait(activeIds.map(pauseTaskAsync));
    } catch (_) {
      // Continue cleanup even if pausing tasks fails.
    }
    try {
      await Future.wait(List<Future<void>>.from(_taskOperations.values));
    } catch (_) {
      // Continue cleanup even if pending operations fail.
    }

    for (final sub in _downloaderSubscriptions.values) {
      await sub.cancel();
    }
    _downloaderSubscriptions.clear();

    for (final downloader in _splitters.values) {
      await downloader.dispose();
    }
    _splitters.clear();

    _saveDebounceTimer?.cancel();
    if (!_taskUpdateController.isClosed) {
      await _taskUpdateController.close();
    }
    if (!_taskRemovedController.isClosed) {
      await _taskRemovedController.close();
    }
    if (!_warningController.isClosed) {
      await _warningController.close();
    }
    if (_ownsClient) {
      _client.close();
    }
  }

  Future<void> _runTaskOperation(
    String taskId,
    Future<void> Function() operation,
  ) {
    final previous = _taskOperations[taskId] ?? Future<void>.value();
    late final Future<void> next;
    if (_taskOperations.containsKey(taskId)) {
      next = previous
          .catchError((Object error, StackTrace stack) {
            _logError('Previous task operation failed', error, stack);
          })
          .then((_) => operation())
          .whenComplete(() {
            if (identical(_taskOperations[taskId], next)) {
              _taskOperations.remove(taskId);
            }
            _schedule();
          });
    } else {
      next = operation().whenComplete(() {
        if (identical(_taskOperations[taskId], next)) {
          _taskOperations.remove(taskId);
        }
        _schedule();
      });
    }
    _taskOperations[taskId] = next;
    return next;
  }

  Future<void> _pauseDownloader(
    BaseDownloader downloader,
    DownloadState targetState,
  ) async {
    await downloader.pause(targetState: targetState);
  }

  void emitTask(DownloadTask task) => _emitTask(task);

  void _emitTask(DownloadTask task) {
    if (_isLoading) return;
    if (!_taskUpdateController.isClosed) {
      _taskUpdateController.add(task);
    }
    if (queuePath != null && !_isLoading) {
      // Debounce saves to prevent I/O saturation — the speed timer in
      // DownloadSplitter fires every 500ms per active download, and each
      // save does jsonEncode + 3 file operations.
      final isTerminal = task.state == DownloadState.completed ||
          task.state == DownloadState.failed;
      if (isTerminal) {
        // Evict oldest completed/failed tasks to keep memory bounded.
        _evictOldCompletedTasks();
        // Persist immediately for terminal states so the queue survives
        // a crash right after completion.
        _saveDebounceTimer?.cancel();
        unawaited(saveToFile(queuePath!));
      } else {
        _saveDebounceTimer?.cancel();
        _saveDebounceTimer = Timer(const Duration(seconds: 1), () {
          unawaited(saveToFile(queuePath!));
        });
      }
    }
    // Update the foreground service notification on every task state
    // change (throttled to 1 s inside syncForegroundService).
    syncForegroundService();
  }

  void _warn(String warning) {
    if (!_warningController.isClosed) {
      _warningController.add(warning);
    }
  }

  /// Starts, updates, or stops the Android foreground service based on
  /// the current [activeTasks] count.  Called on state transitions and
  /// periodically via [emitTask].  Public so the host widget can force
  /// a sync on lifecycle events (e.g. app backgrounding).
  void syncForegroundService() {
    if (_activeTasks.isNotEmpty && !_fgServiceActive) {
      _fgServiceActive = true;
      unawaited(DownloadForegroundService.start(count: _activeTasks.length));
      _updateFgServiceNotification();
    } else if (_activeTasks.isEmpty && _fgServiceActive) {
      _fgServiceActive = false;
      unawaited(DownloadForegroundService.stop());
    } else if (_fgServiceActive) {
      // Throttle progress updates to at most once per second.
      final now = DateTime.now();
      if (now.difference(_lastFgUpdate).inMilliseconds >= 1000) {
        _lastFgUpdate = now;
        _updateFgServiceNotification();
      }
    }
  }

  /// Pushes an update to the foreground service notification showing the
  /// count, first active file name, and overall progress.
  void _updateFgServiceNotification() {
    final count = _activeTasks.length;
    String? fileName;
    int percent = 0;
    if (_activeTasks.isNotEmpty) {
      final firstId = _activeTasks.first;
      final task = _tasks[firstId];
      if (task != null) {
        fileName = task.savePath.split(RegExp(r'[/\\]')).last;
        if (task.totalBytes > 0) {
          percent = (task.downloadedBytes * 100 ~/ task.totalBytes).round();
        }
      }
    }
    unawaited(DownloadForegroundService.update(
      count: count,
      currentFileName: fileName,
      percent: percent,
    ));
  }

  Future<void> _preserveCorruptQueueFile(File file, String reason) async {
    _warn('Failed to restore download queue: $reason');
    try {
      if (!await file.exists()) return;
      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('.', '-');
      final corruptPath = '${file.path}.corrupt.$timestamp';
      await file.rename(corruptPath);
    } catch (e, s) {
      _logError('Failed to preserve corrupt queue file', e, s);
    }
  }

  Future<void> _recoverCorruptQueueFiles(String path) async {
    try {
      final file = File(path);
      final parentDir = file.parent;
      if (!await parentDir.exists()) return;
      final baseName = p.basename(path);
      final list = parentDir.list();
      int recoveredCount = 0;
      await for (final entity in list) {
        if (entity is File) {
          final name = p.basename(entity.path);
          if (name.startsWith('$baseName.corrupt.')) {
            try {
              final content = await entity.readAsString();
              final decoded = jsonDecode(content);
              if (decoded is List) {
                for (final item in decoded) {
                  if (item is! Map) continue;
                  try {
                    final task = DownloadTask.fromJson(Map<String, dynamic>.from(item));
                    if (!_tasks.containsKey(task.id)) {
                      if (task.state == DownloadState.downloading ||
                          task.state == DownloadState.paused) {
                        task.state = DownloadState.idle;
                      }
                      addTask(task);
                      recoveredCount++;
                    }
                  } catch (_) {}
                }
              }
              await entity.delete();
            } catch (_) {}
          }
        }
      }
      if (recoveredCount > 0 && !_isLoading) {
        debugPrint('[DownloadQueue] INFO: Successfully recovered $recoveredCount tasks from corrupt history backups.');
        AuroraLog.instance.info(
          'Successfully recovered $recoveredCount tasks from corrupt history backups.',
          category: LogCategory.download,
          screen: LogScreen.background,
          eventType: LogEventType.stateChange,
        );
        unawaited(saveToFile(path));
      }
    } catch (e, s) {
      _logError('Failed to run queue recovery', e, s);
    }
  }

  bool _isHlsTask(DownloadTask task) {
    final contentType = task.contentType?.toLowerCase().split(';').first.trim();
    if (contentType != null) {
      if (contentType == 'application/vnd.apple.mpegurl' ||
          contentType == 'application/x-mpegurl' ||
          contentType == 'application/dash+xml' ||
          contentType.contains('mpegurl')) {
        return true;
      }
      if (contentType.startsWith('video/') ||
          contentType.startsWith('audio/') ||
          contentType.startsWith('image/')) {
        return _hasExplicitPlaylistHint(task.url);
      }
    }

    return _hasExplicitPlaylistHint(task.url);
  }

  bool _hasExplicitPlaylistHint(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final path = uri.path.toLowerCase();
    // Explicit playlist extensions — definitely HLS/DASH
    if (path.endsWith('.m3u8') || path.endsWith('.mpd')) return true;
    // Path hints for disguised playlists (e.g. index.jpg under /hls/).
    // Checked BEFORE the known-direct-media list so that CDNs serving
    // playlists under non-.m3u8 URLs (e.g. .../hls/.../index.jpg) are
    // routed to the HLS downloader.  The HLS downloader will verify the
    // body starts with #EXTM3U and fail gracefully if it is not actually
    // an HLS playlist.
    final urlLower = url.toLowerCase();
    if (path.contains('/hls/') ||
        path.contains('/master') ||
        path.contains('/playlist') ||
        path.contains('/manifest') ||
        path.contains('/dash/') ||
        urlLower.contains('m3u8') ||
        urlLower.contains('mpd')) {
      return true;
    }
    // Known direct-media extensions — definitely not a playlist
    if (path.endsWith('.mp4') ||
        path.endsWith('.webm') ||
        path.endsWith('.mkv') ||
        path.endsWith('.avi') ||
        path.endsWith('.flv') ||
        path.endsWith('.mov') ||
        path.endsWith('.mp3') ||
        path.endsWith('.wav') ||
        path.endsWith('.aac') ||
        path.endsWith('.ogg') ||
        path.endsWith('.m4a') ||
        path.endsWith('.flac') ||
        path.endsWith('.jpg') ||
        path.endsWith('.jpeg') ||
        path.endsWith('.png') ||
        path.endsWith('.gif') ||
        path.endsWith('.pdf') ||
        path.endsWith('.zip') ||
        path.endsWith('.rar') ||
        path.endsWith('.7z') ||
        path.endsWith('.exe') ||
        path.endsWith('.apk')) {
      return false;
    }
    return false;
  }
}

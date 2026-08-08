import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../sniffer/worker_isolate_pool.dart';
import 'dart:math' as math;
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
import '../platform/download_foreground_service.dart';
import '../settings/download_settings.dart' show ProxyType;
import '../sniffer/sniffer_url_utils.dart';
import 'file_classifier.dart';
import 'filename_service.dart';
import 'media_file_types.dart';
import '../compliance/restricted_media_policy.dart';

void _logError(String context, Object error, [StackTrace? stack]) {
  debugPrint('[DownloadQueue] $context: $error');
  debugPrint('$context: $error');
  if (stack != null) {
    debugPrint('$context stack:\n$stack');
  }
}

/// Internal pair for relevance-scored search results used by
/// [DownloadQueue.searchTasks].
final class _ScoredTask {
  final DownloadTask task;
  final int score;
  const _ScoredTask({required this.task, required this.score});
}

class DownloadQueue {
  /// Engine hard ceilings. The app never lets the user pick above these, and
  /// the engine clamps defensively. Tier-aware UI caps (free 3/8, pro 16/32,
  /// ultra 64/64) live in [ProFeatures] and are applied in the app shell.
  static const int engineHardMaxConcurrent = 64;
  static const int engineHardMaxChunks = 64;

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

  /// HLS concurrent-segment cap (Key Decision: free/pro 8, ultra 16). Set via
  /// [configure] from the tier-aware [ProFeatures.hlsSegmentCapFor].
  int hlsSegmentCap = 8;
  final http.Client? httpClient;
  late http.Client _client;
  final bool _ownsClient;
  CompletedDownloadPublisher? completedDownloadPublisher;
  bool wifiOnly = false;
  bool autoClassifyEnabled = true;
  bool remuxTsToMp4 = true;
  /// Optional overrides: file extension → folder name (e.g. `.mp4` → `Movies`).
  Map<String, String> autoClassifyMappings = const {};
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

  String? queuePath;
  bool _isLoading = false;

  /// Chains queue writes so at most one save is in flight at a time and no
  /// save request is ever dropped. Each [saveToFile] call appends its write
  /// after the previous one's completion instead of busy-polling (replaces
  /// the old 50 ms `_waitAndSave` spin loop).
  Future<void>? _saveChain;

  /// When true, [_schedule] is a no-op. Used during queue file restore and
  /// for a short post-launch hold so Secure Folder cold start is not
  /// saturated by multi-connection HLS resume + headless WebViews while the
  /// browser UI is still mounting.
  bool _startupHold = false;
  Timer? _startupHoldTimer;

  /// How long to keep downloads paused after queue restore.
  static const Duration startupHoldDuration = Duration(seconds: 5);

  /// Debounce timer for persisting the queue to disk.  Without this the
  /// queue is written on every 500ms progress tick (from every active
  /// download), which saturates flash I/O and causes the UI progress bar
  /// to appear frozen.
  Timer? _saveDebounceTimer;

  /// Periodic flush (every 5 s) that closes the save-debounce durability
  /// gap: the 1 s debounce timer is reset on every emit, so during a long
  /// download the queue JSON would never be written. This timer flushes a
  /// dirty queue while downloads are active, so a crash loses at most ~5 s
  /// of progress instead of everything since the last terminal/pause save.
  /// Self-cancels once the queue is clean and nothing is downloading.
  Timer? _savePeriodicTimer;

  /// True when a state change since the last save has not been persisted.
  bool _queueDirty = false;

  /// Periodic timer that checks whether any scheduled tasks should start.
  /// Created on first [scheduleTask] call; cancelled in [dispose].
  Timer? _scheduleTimer;

  /// Throttles syncForegroundService calls so the method-channel is not
  /// flooded with start/stop/update calls during high-throughput downloads.
  Timer? _lastFgSyncTimer;

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

  /// Per-task progress notifiers (P1b): the queue page drives each card's
  /// live progress area with these instead of rebuilding the whole list on
  /// every tick. Created lazily on first emit; disposed on removal/close.
  final Map<String, ValueNotifier<DownloadTask>> _taskNotifiers = {};

  /// Bumped on every task emit. The queue page's header (aggregate speed /
  /// counts) listens to this instead of rebuilding the whole list per tick.
  final ValueNotifier<int> queueVersion = ValueNotifier<int>(0);

  /// Live per-task notifier, or null until the task first emits.
  ValueNotifier<DownloadTask>? taskNotifierFor(String taskId) =>
      _taskNotifiers[taskId];

  /// Set once [close] runs; stops [queueVersion] bumps after disposal.
  bool _notifiersClosed = false;

  void _disposeTaskNotifier(String taskId) {
    _taskNotifiers.remove(taskId)?.dispose();
  }
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
  ///
  /// Passes the full [newTask] so headers, cookies, and browser bridges
  /// (WebView fetch / token refresh) can be copied onto the existing task.
  /// Previously only the URL was passed, so "Update link" after restart
  /// left tasks without WAF-bypass bridges and they kept failing.
  void Function(String existingTaskId, DownloadTask newTask)?
      onResniffDuplicate;

  /// Optional host-provided binder that re-attaches runtime browser
  /// bridges (`fetchViaWebView`, `cookieProvider`, `onTokenExpired`, …)
  /// which cannot be persisted to JSON. Set by [SnifferScreen] while
  /// mounted. Called before every task start / retry / link update.
  void Function(DownloadTask task)? browserContextAttacher;

  /// Fired when [addTask] rejects a URL under [RestrictedMediaPolicy]
  /// (e.g. YouTube). UI should show [message] to the user.
  void Function(String message)? onRestrictedMediaBlocked;

  DownloadQueue({
    this.maxConcurrentDownloads = 3,
    this.enablePreemption = true,
    this.useNativeTorrentEngine = true,
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
      ..maxConnectionsPerHost = 64
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 15);

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
    // Direct assignment replaces the deferred initializer from the constructor
    // or overwrites the existing client. No explicit close needed here because
    // the old client (if it was constructed at all) is garbage-collected and
    // its underlying TCP connections time out naturally.
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
    int? hlsSegmentCap,
    CompletedDownloadPublisher? completedDownloadPublisher,
    bool? autoClassifyEnabled,
    bool? remuxTsToMp4,
    Map<String, String>? autoClassifyMappings,
    bool? autoRetry,
    int? retryLimit,
    int? minSpeedThresholdBytesPerSec,
    int? stallTimeoutSeconds,
    double? partialDownloadThreshold,
    int? minBytesBeforeFullRetry,
  }) {
    if (maxConcurrentDownloads != null) {
      this.maxConcurrentDownloads =
          maxConcurrentDownloads.clamp(1, engineHardMaxConcurrent).toInt();
    }
    if (numChunksPerTask != null) {
      this.numChunksPerTask =
          numChunksPerTask.clamp(1, engineHardMaxChunks).toInt();
    }
    if (hlsSegmentCap != null) {
      this.hlsSegmentCap = hlsSegmentCap.clamp(1, engineHardMaxChunks).toInt();
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
    if (autoClassifyMappings != null) {
      this.autoClassifyMappings = Map.unmodifiable(
        autoClassifyMappings.map(
          (k, v) => MapEntry(k.startsWith('.') ? k.toLowerCase() : '.${k.toLowerCase()}', v),
        ),
      );
    }
    if (autoRetry != null) {
      this.autoRetry = autoRetry;
    }
    if (retryLimit != null) {
      this.retryLimit = retryLimit.clamp(1, 24).toInt();
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

  /// Creates a periodic timer (every 30 s) that checks when scheduled
  /// tasks should transition to [DownloadState.idle] and start downloading.
  void _startScheduleTimer() {
    _scheduleTimer?.cancel();
    _scheduleTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _checkScheduledTasks();
    });
  }

  /// Scans all [DownloadState.scheduled] tasks whose [scheduledStartAt] has
  /// passed, moves them to [DownloadState.idle], adds them to the execution
  /// queue, and triggers [_schedule].
  void _checkScheduledTasks() {
    final now = DateTime.now();
    final ready = <DownloadTask>[];
    for (final task in _tasks.values) {
      if (task.state == DownloadState.scheduled &&
          task.scheduledStartAt != null &&
          !task.scheduledStartAt!.isAfter(now)) {
        ready.add(task);
      }
    }
    if (ready.isEmpty) {
      // Self-cancel: nothing became ready on this tick. If there are no
      // *remaining* scheduled tasks at all, stop the periodic 30 s timer —
      // it is re-armed lazily on the next scheduleTask / queue-restore path.
      final hasScheduledRemaining = _tasks.values.any(
        (t) => t.state == DownloadState.scheduled,
      );
      if (!hasScheduledRemaining) {
        _scheduleTimer?.cancel();
        _scheduleTimer = null;
      }
      return;
    }

    for (final task in ready) {
      task.state = DownloadState.idle;
      if (!_executionQueue.contains(task.id)) {
        _executionQueue.add(task.id);
      }
      _emitTask(task);
    }
    _schedule();
    // Persist the state change so it survives a crash.
    if (queuePath != null && !_isLoading) {
      unawaited(saveToFile(queuePath!));
    }
  }

  /// Schedules [task] to start at [startAt].  The task is persisted with
  /// [DownloadState.scheduled] and a periodic timer (started lazily) will
  /// move it to [DownloadState.idle] when the time arrives.
  void scheduleTask(DownloadTask task, DateTime startAt) {
    if (_isDisposed) return;
    if (RestrictedMediaPolicy.isBlocked(
      mediaUrl: task.url,
      sourcePageUrl: task.sourcePageUrl,
      headers: task.headers,
    )) {
      _warn(RestrictedMediaPolicy.userMessageRestricted);
      onRestrictedMediaBlocked?.call(RestrictedMediaPolicy.userMessageRestricted);
      return;
    }
    task.scheduledStartAt = startAt;
    task.state = DownloadState.scheduled;
    _tasks[task.id] = task;
    _startScheduleTimer();
    _emitTask(task);
    if (queuePath != null && !_isLoading) {
      unawaited(saveToFile(queuePath!));
    }
  }

  /// Host used by staged screenshot fixtures. `.invalid` is reserved by
  /// RFC 2606 and can never resolve, so a fixture that escapes into the
  /// download engine fails DNS rather than hitting a real server.
  static const String _fixtureHost = 'example.invalid';

  /// Ids seeded by [seedDisplayOnlyTasks]. Held so these tasks can be kept out
  /// of the persisted queue file — they live for the lifetime of the process
  /// and must never outlive it.
  final Set<String> _displayOnlyTaskIds = <String>{};

  /// True for a staged screenshot fixture, whether it was seeded this session
  /// or restored from a queue file written by an earlier screenshot build.
  bool _isDisplayOnlyTask(DownloadTask task) {
    if (_displayOnlyTaskIds.contains(task.id)) return true;
    return Uri.tryParse(task.url)?.host == _fixtureHost;
  }

  /// Inserts display-only tasks so the Queue UI has something to render during
  /// store-screenshot capture. See `lib/dev/screenshot_fixtures.dart`.
  ///
  /// These bypass scheduling (never added to `_executionQueue`), persistence
  /// (filtered out of [saveToFile]), and the restricted-media check. They exist
  /// only to be drawn.
  ///
  /// Persistence matters more than it looks: [saveToFile] writes every entry in
  /// `_tasks`, so without the filter these fixtures land in the queue file, and
  /// the next launch restores them as `downloading` → `idle` and hands them to
  /// the engine. They would then appear to "really download" — against a host
  /// that cannot resolve — in ordinary builds, long after the screenshot run.
  ///
  /// **No-op in release builds** — the screenshot build is compiled in profile
  /// mode, which is also what makes [ProEntitlement.setDebugTier] work.
  void seedDisplayOnlyTasks(List<DownloadTask> tasks) {
    if (kReleaseMode || _isDisposed) return;
    for (final task in tasks) {
      _displayOnlyTaskIds.add(task.id);
      _tasks[task.id] = task;
      _emitTask(task);
    }
  }

  void addTask(DownloadTask task, {bool force = false}) {
    if (_isDisposed) return;
    // Play compliance: never enqueue restricted platform media (Wave 1+).
    // (See lib/compliance/restricted_media_policy.dart.)
    if (RestrictedMediaPolicy.isBlocked(
      mediaUrl: task.url,
      sourcePageUrl: task.sourcePageUrl,
      headers: task.headers,
    )) {
      _warn(RestrictedMediaPolicy.userMessageRestricted);
      onRestrictedMediaBlocked?.call(RestrictedMediaPolicy.userMessageRestricted);
      return;
    }
    _autoRetryAttempts.remove(task.id);
    if (!force && !_isLoading) {
      // Duplicate prevention: skip if a task with the same URL is already
      // in the queue (idle, downloading, or paused). Completed/failed tasks
      // don't block re-downloading the same URL.
      // Guard with !_isLoading so the O(n) scan per task does not compound
      // to O(n²) during queue-file restore (the persisted file is
      // authoritative and should never contain duplicates).
      final normalizedUrl = _normalizeUrl(task.url);
      final existing = _tasks.values.where(
        (t) =>
            _normalizeUrl(t.url) == normalizedUrl &&
            (t.state == DownloadState.idle ||
                t.state == DownloadState.downloading ||
                t.state == DownloadState.paused),
      );
      if (existing.isNotEmpty) {
        // When resniff mode is active and the duplicate belongs to the
        // pending resniff task, delegate to the callback so the user can
        // choose "Update existing" or "Create new".
        if (resniffPendingTaskId != null &&
            onResniffDuplicate != null &&
            resniffPendingTaskId == existing.first.id) {
          onResniffDuplicate!(resniffPendingTaskId!, task);
          return;
        }
        _warn('Already in queue: ${task.url}');
        return;
      }
      // Resniff mode: a freshly sniffed URL that looks like the same media
      // as the pending task (same scheme/host/path, e.g. a token-refreshed
      // variant with a different query string) is routed to the resniff
      // dialog instead of being added as a silent new download. This is what
      // makes "Update Existing" actually receive a *new* URL rather than the
      // identical one already in the queue.
      if (resniffPendingTaskId != null && onResniffDuplicate != null) {
        final pending = _tasks[resniffPendingTaskId];
        if (pending != null && _isLikelySameMedia(pending.url, task.url)) {
          onResniffDuplicate!(resniffPendingTaskId!, task);
          return;
        }
      }
    }
    if (task.isBackupImport && task.state != DownloadState.completed) {
      task.state = DownloadState.paused;
    }
    _tasks[task.id] = task;

    // If the task has a future scheduledStartAt, put it into scheduled state
    // instead of idle.  The periodic schedule timer will move it to idle when
    // the time arrives.
    if (task.state != DownloadState.completed &&
        task.scheduledStartAt != null &&
        task.scheduledStartAt!.isAfter(DateTime.now())) {
      task.state = DownloadState.scheduled;
    }

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
      task.failureReason = DownloadFailure.urlInvalid;
      task.errorMessage =
          'Aurora can\'t download blob: URLs directly. '
          'Look for the .m3u8 or .mpd playlist URL in the captured media list instead.';
      _emitTask(task);
      return;
    }

    // Auto-classify: inject category subfolder into savePath.
    if (autoClassifyEnabled && task.state != DownloadState.completed) {
      _applyAutoClassification(task);
    }

    _ensureSplitter(task);

    if (task.state == DownloadState.idle) {
      if (!_executionQueue.contains(task.id)) {
        _executionQueue.add(task.id);
      }
    } else if (task.state == DownloadState.scheduled) {
      _startScheduleTimer();
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
      final type = await FileSystemEntity.type(task.savePath);
      if (type == FileSystemEntityType.file) {
        await File(task.savePath).delete();
      } else if (type == FileSystemEntityType.directory) {
        await Directory(task.savePath).delete(recursive: true);
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
    _disposeTaskNotifier(taskId);
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

    if (_isTorrentTask(task)) {
      // The native torrent engine writes pieces directly to its save dir —
      // there are never per-chunk files in tempDir to merge. Force merge
      // is a splitter/HTTP concept; for torrents, resume or redownload.
      debugPrint('Force merge refused for '
          '${task.savePath.split("/").last}: native torrent task.');
      task.failureReason = DownloadFailure.mergeFailed;
      task.errorMessage =
          'Torrent downloads are managed by the engine — resume or redownload instead.';
      _emitTask(task);
      return false;
    }

    if (task.state == DownloadState.downloading) {
      debugPrint('Force merge refused for '
        '${task.savePath.split("/").last}: task is still downloading.');
      task.failureReason = DownloadFailure.mergeFailed;
      task.errorMessage = 'Can\'t force merge while the task is still downloading.';
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
    task.totalBytes = _isHlsTask(task) ? -1 : task.chunks.length;
    _emitTask(task);

    try {
      final PartialMergeResult result;
      if (_isHlsTask(task)) {
        result = await FileCombiner.combineHlsPartial(
          tempDir: task.tempDir,
          destination: File(task.savePath),
          onProgress: (current, total) {
            task.downloadedBytes = current;
            task.totalBytes = total;
            _emitTask(task);
          },
        );
      } else {
        // Pull chunks from in-memory task (loaded from meta.json in _loadMeta
        // or already on the in-memory model).
        result = await FileCombiner.combinePartial(
          chunks: task.chunks,
          tempDir: task.tempDir,
          destination: File(task.savePath),
          onProgress: (chunkIndex, totalChunks) {
            task.downloadedBytes = chunkIndex;
            task.totalBytes = totalChunks;
            _emitTask(task);
          },
        );
      }

      if (!result.hasData) {
        task.state = DownloadState.failed;
        task.failureReason = DownloadFailure.mergeFailed;
        task.errorMessage =
            'Force merge had no data to work with. No partial chunks found on disk.';
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
      task.failureReason = DownloadFailure.mergeFailed;
      task.errorMessage = 'Force merge failed. Error: $e';
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
    final task = _tasks[taskId];
    if (task != null) {
      await prepareBrowserContext(task);
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

    // Re-attach WebView bridges lost across process death / JSON reload.
    await prepareBrowserContext(task);

    task.state = DownloadState.idle;
    if (!_executionQueue.contains(taskId) && !_activeTasks.contains(taskId)) {
      _executionQueue.add(taskId);
    }
    final pending = _taskOperations[taskId];
    if (pending != null) {
      await pending;
    }
    // Explicit resume always wins over the cold-start hold.
    if (!isAutoRetry) {
      releaseStartupHold();
    } else {
      _schedule();
    }
    if (queuePath != null && !_isLoading) {
      unawaited(saveToFile(queuePath!));
    }
  }

  /// Re-attach runtime browser bridges and refresh Cookie header.
  /// Safe to call repeatedly; no-ops when [browserContextAttacher] is null
  /// except for best-effort cookie refresh via an already-set cookieProvider.
  Future<void> prepareBrowserContext(DownloadTask task) async {
    try {
      browserContextAttacher?.call(task);
    } catch (e, s) {
      _logError('browserContextAttacher failed for ${task.id}', e, s);
    }
    // Prefer live cookies over the stale Cookie header saved in the queue JSON.
    if (task.cookieProvider != null) {
      try {
        final cookies = await task.cookieProvider!(task.url);
        if (cookies.isNotEmpty) {
          final merged = <String, String>{...?task.headers};
          cookies.forEach((k, v) {
            // Preserve original header casing if present.
            final existingKey = merged.keys.firstWhere(
              (key) => key.toLowerCase() == k.toLowerCase(),
              orElse: () => k,
            );
            merged[existingKey] = v;
          });
          task.headers = merged;
        }
      } catch (e, s) {
        _logError('cookie refresh failed for ${task.id}', e, s);
      }
    }
  }

  /// Apply a freshly sniffed [donor] (URL, headers, bridges) onto an
  /// existing queue task and restart it. Wipes temp segments when the
  /// media URL changes so old encrypted segments are not reused.
  Future<void> updateTaskFromDonor(
    String existingTaskId,
    DownloadTask donor, {
    bool wipeOnUrlChange = true,
  }) async {
    final existing = _tasks[existingTaskId];
    if (existing == null) return;

    final urlChanged = !_isLikelySameMedia(existing.url, donor.url) ||
        existing.url != donor.url;
    // Query-token change counts as a URL change for wipe purposes even when
    // path matches (signed CDN tokens).
    final tokenChanged = existing.url != donor.url;

    existing.url = donor.url;
    if (donor.headers != null && donor.headers!.isNotEmpty) {
      existing.headers = Map<String, String>.from(donor.headers!);
    }
    if (donor.contentType != null) {
      // contentType is final on some versions — check if mutable
    }
    // sourcePageUrl is final — cannot reassign; bridges use donor's page via
    // onTokenExpired closure which captures donor.sourcePageUrl when set.

    existing.copyBrowserBridgesFrom(donor);
    // Prefer donor's source page for token refresh if existing has none.
    // (sourcePageUrl is final — attach via bridge only)

    if (tokenChanged) {
      existing.downloadedBytes = 0;
      existing.totalBytes = donor.totalBytes > 0 ? donor.totalBytes : 0;
      if (wipeOnUrlChange) {
        await _wipeTaskTemp(existing);
      }
    }

    existing.failureReason = null;
    existing.errorMessage = null;
    existing.statusMessage = null;

    if (existing.state == DownloadState.failed ||
        existing.state == DownloadState.paused ||
        existing.state == DownloadState.completed) {
      existing.state = DownloadState.idle;
    }

    await prepareBrowserContext(existing);

    debugPrint('Updated task $existingTaskId from donor '
      '(urlChanged=$urlChanged tokenChanged=$tokenChanged '
      'bridges: fetch=${existing.fetchViaWebView != null} '
      'cookie=${existing.cookieProvider != null} '
      'token=${existing.onTokenExpired != null})');

    await resumeTaskAsync(existingTaskId);
  }

  Future<void> _wipeTaskTemp(DownloadTask task) async {
    try {
      final tempDir = Directory(task.tempDir);
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (e, s) {
      _logError('Failed to wipe temp for ${task.id}', e, s);
    }
    // Also drop any in-memory splitter so the next start is a clean resume
    // detection against an empty temp dir.
    final splitter = _splitters.remove(task.id);
    if (splitter != null) {
      try {
        await splitter.dispose();
      } catch (_) {}
    }
    final sub = _downloaderSubscriptions.remove(task.id);
    await sub?.cancel();
    // Re-create splitter on next add/schedule path — ensure it exists.
    _ensureSplitter(task);
  }

  void _ensureSplitter(DownloadTask task) {
    if (_splitters.containsKey(task.id)) return;
    if (task.state == DownloadState.completed) return;
    if (task.state == DownloadState.paused) return; // defer until resumed
    if (task.url.startsWith('blob:')) return;

    BaseDownloader downloader;
    if (_isTorrentTask(task)) {
      downloader = TorrentDownloader(
        task: task,
        client: _client,
        useNativeEngine: useNativeTorrentEngine,
      );
    } else if (_isHlsTask(task)) {
      downloader = HlsDownloader(
        task: task,
        client: _client,
        maxConcurrentSegments: math.min(numChunksPerTask, hlsSegmentCap),
        remuxTsToMp4: remuxTsToMp4,
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
    _downloaderSubscriptions[task.id] = downloader.onTaskUpdated.listen(
      _onDownloaderTaskUpdated,
    );
  }

  Future<void> _onDownloaderTaskUpdated(DownloadTask updatedTask) async {
    _emitTask(updatedTask);
    if (updatedTask.state != DownloadState.completed &&
        updatedTask.state != DownloadState.failed) {
      return;
    }

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
                debugPrint('Auto-classified completed file moved from $oldPath to $newPath');
              }
            } catch (e) {
              updatedTask.savePath = oldPath;
              debugPrint('Failed to move auto-classified file: $e');
            }
          }
        }
        unawaited(_publishCompletedTask(updatedTask));
      }
    }
    _schedule();

    if (updatedTask.state == DownloadState.failed) {
      debugPrint('Download failed: ${updatedTask.savePath.split("/").last}. Error: ${updatedTask.errorMessage}');
      if (autoRetry && !updatedTask.isBackupImport) {
        final isStallOrTruncation =
            updatedTask.failureReason == DownloadFailure.speedStall ||
            updatedTask.failureReason == DownloadFailure.partialDownload ||
            updatedTask.failureReason == DownloadFailure.chunkIncomplete;
        final alreadyDownloadedEnough =
            updatedTask.downloadedBytes >= minBytesBeforeFullRetry;
        if (isStallOrTruncation && alreadyDownloadedEnough) {
          debugPrint('Skipped auto-retry for '
            '${updatedTask.savePath.split("/").last}: '
            'already downloaded '
            '${(updatedTask.downloadedBytes / 1024 / 1024).toStringAsFixed(1)} MB. '
            'User can use Force Merge or manual retry.');
          final alreadyMb =
              (updatedTask.downloadedBytes / 1024 / 1024).toStringAsFixed(1);
          updatedTask.failureReason = DownloadFailure.partialDownload;
          updatedTask.errorMessage =
              'Download stalled at $alreadyMb MB. '
              'Try Force Merge to save what\'s downloaded, or tap Retry.';
          _emitTask(updatedTask);
          return;
        }
        final attempts = _autoRetryAttempts[updatedTask.id] ?? 0;
        if (attempts < retryLimit) {
          final nextAttempt = attempts + 1;
          _autoRetryAttempts[updatedTask.id] = nextAttempt;
          final originalError = updatedTask.errorMessage ?? 'Unknown error';
          final limitStr = '$retryLimit';
          updatedTask.errorMessage =
              'Retrying in 1s (attempt $nextAttempt/$limitStr). $originalError';
          _emitTask(updatedTask);

          Future.delayed(const Duration(seconds: 1), () {
            if (_tasks[updatedTask.id]?.state == DownloadState.failed) {
              retryHlsTaskWithRefresh(
                updatedTask.id,
                forceReload: false,
                isAutoRetry: true,
              );
            }
          });
        } else {
          debugPrint('Auto-retry limits exceeded for ${updatedTask.savePath.split("/").last}.');
          final originalError = updatedTask.errorMessage ?? 'Unknown error';
          final cleanError = originalError.replaceFirst(
            RegExp(r'^Retrying in [12]s \(attempt \d+/(?:\d+|∞)\)\. '),
            '',
          );
          updatedTask.errorMessage =
              'Auto-retry exhausted after $retryLimit attempts. $cleanError';
          _emitTask(updatedTask);
        }
      }
    }
  }

  void updatePriority(String taskId, DownloadPriority newPriority) {
    final task = _tasks[taskId];
    if (task == null) return;

    task.priority = newPriority;
    _schedule();
  }

  Future<void> saveToFile(String path) async {
    // Serialize writes: append this save after any in-flight or queued save
    // instead of busy-waiting for the previous one to finish. _writeQueue
    // never throws, so the chain only ever carries normal completions.
    final previous = _saveChain ?? Future<void>.value();
    final next = previous.then((_) => _writeQueue(path));
    _saveChain = next;
    try {
      await next;
    } finally {
      if (identical(_saveChain, next)) {
        _saveChain = null;
      }
    }
  }

  Future<void> _writeQueue(String path) async {
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
      // app restarts and ADB installs — except staged screenshot fixtures,
      // which must not outlive the process that seeded them.
      final data = _tasks.values
          .where((t) => !_isDisplayOnlyTask(t))
          .map((t) => t.toJson())
          .toList(growable: false);
      final jsonString = await WorkerIsolatePool.instance.execute(
        'jsonEncode',
        {'data': data},
      ) as String;
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
      final decoded = await WorkerIsolatePool.instance.execute(
        'jsonDecode',
        {'json': json},
      );
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
          final tempDirStr = item['tempDir'] as String? ?? '';
          if (tempDirStr.isNotEmpty) {
            final normalized = tempDirStr.replaceAll('\\', '/');
            if (!normalized.contains('downloads_tmp')) {
              // Extract basename (e.g. 'temp_1783417343907' or '1783417343907')
              final lastSlash = normalized.lastIndexOf('/');
              final basename = lastSlash != -1
                  ? normalized.substring(lastSlash + 1)
                  : normalized;
              item['tempDir'] =
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
          } else if (task.state == DownloadState.scheduled) {
            // If the scheduled time has already passed, start immediately.
            if (task.scheduledStartAt == null ||
                !task.scheduledStartAt!.isAfter(DateTime.now())) {
              task.state = DownloadState.idle;
            } else {
              // Still in the future — ensure the periodic checker is running.
              _startScheduleTimer();
            }
          } else if (task.state == DownloadState.merging) {
            task.state = DownloadState.failed;
            task.failureReason = DownloadFailure.mergeInterrupted;
            task.errorMessage = 'Merge was interrupted while combining saved parts. Tap Retry to re-merge.';
          }
          // Self-heal: drop staged screenshot fixtures written by an earlier
          // build before the persistence filter existed. Without this they
          // stay in the queue file forever and get retried on every launch
          // against a host that cannot resolve.
          if (_isDisplayOnlyTask(task)) {
            debugPrint(
              '[DownloadQueue] dropped stale screenshot fixture ${task.id}',
            );
            continue;
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
      // Tasks are already in _executionQueue as idle. Hold multi-connection
      // resume for a few seconds so browser/WebView cold start can finish.
      // Without this, Secure Folder freezes ~10–15s under HLS+GPU load.
      holdSchedulingForStartup();
    }

    // Recover any tasks from previous corrupt backups
    await _recoverCorruptQueueFiles(path);
  }

  /// Blocks automatic task starts for [duration] (default 5s), then runs
  /// [_schedule]. Call after cold-start queue restore so the UI can paint.
  void holdSchedulingForStartup([Duration? duration]) {
    _startupHold = true;
    _startupHoldTimer?.cancel();
    _startupHoldTimer = Timer(duration ?? startupHoldDuration, () {
      _startupHold = false;
      _startupHoldTimer = null;
      if (!_isDisposed) _schedule();
    });
  }

  /// Ends the startup hold early (e.g. user manually starts a download).
  void releaseStartupHold() {
    _startupHoldTimer?.cancel();
    _startupHoldTimer = null;
    if (_startupHold) {
      _startupHold = false;
      _schedule();
    }
  }

  void _schedule() {
    if (_isDisposed) return;
    // Do not start downloads while restoring the queue or during the
    // post-launch hold — that contention freezes Secure Folder cold start.
    if (_isLoading || _startupHold) return;
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
      final task = _tasks[taskId];
      if (task != null) {
        // Always rebind bridges + cookies before start (post-restart safety).
        await prepareBrowserContext(task);
        _ensureSplitter(task);
      }
      final splitter = _splitters[taskId];
      if (splitter == null) {
        // Task was cancelled/disposed between scheduling and start.
        // Remove from active set so it doesn't hang forever.
        _logError(
          'Splitter for task $taskId vanished before start (cancelled?)',
          '',
        );
        _activeTasks.remove(taskId);
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

  DownloadTask? getTaskByUrl(String url) {
    final normalized = _normalizeUrl(url);
    for (final task in _tasks.values) {
      if (_normalizeUrl(task.url) == normalized) {
        return task;
      }
    }
    return null;
  }

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

  /// Returns true if [a] and [b] point at the same media resource while
  /// ignoring query-string differences (e.g. a refreshed CDN token). Used by
  /// resniff mode to recognise a re-sniffed URL as the same media even when
  /// its query parameters changed, so the resniff dialog can offer to update
  /// the existing task with the new URL.
  static bool _isLikelySameMedia(String a, String b) {
    try {
      final ua = Uri.parse(a);
      final ub = Uri.parse(b);
      if (ua.scheme != ub.scheme || ua.host != ub.host) return false;
      final pa = ua.pathSegments.where((s) => s.isNotEmpty).toList();
      final pb = ub.pathSegments.where((s) => s.isNotEmpty).toList();
      if (pa.length != pb.length) return false;
      for (var i = 0; i < pa.length; i++) {
        if (pa[i] != pb[i]) return false;
      }
      return true;
    } catch (_) {
      return false;
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
      // Scheduled tasks don't block future downloads of the same URL.
      if (t.state == DownloadState.scheduled) return false;
      return true;
    });
  }

  /// True if a task with the same base filename AND same source page already
  /// exists in the queue.  Catches the case where two quality variants of the
  /// same video are sniffed from one page under different URLs.
  bool samePageFilenameExists(String filename, String? sourcePageUrl) {
    if (sourcePageUrl == null || sourcePageUrl.isEmpty) return false;
    final base = _stripUniqueSuffix(filename);
    final normalizedSource = _normalizeUrl(sourcePageUrl);
    return _tasks.values.any((t) {
      if (t.state == DownloadState.scheduled) return false;
      if (_normalizeUrl(t.sourcePageUrl ?? '') != normalizedSource) return false;
      final existingBase = _stripUniqueSuffix(
        p.basename(t.savePath),
      );
      return existingBase.toLowerCase() == base.toLowerCase();
    });
  }

  /// Strips ` (1)`, ` (2)`, … suffixes appended by [FilenameService.uniquePath].
  static String _stripUniqueSuffix(String filename) {
    final ext = p.extension(filename);
    final base = p.basenameWithoutExtension(filename);
    // Match "filename (N)" pattern where N is one or more digits.
    final match = RegExp(r'^(.*) \((\d+)\)$').firstMatch(base);
    final stripped = match != null ? match.group(1)! : base;
    return '$stripped$ext';
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
      int c = 0;
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
    return MediaFileTypes.extensionOf(url);
  }

  /// Deletes temp workspaces for failed tasks older than [maxAge].
  /// Keeps failed-task metadata in the queue so the user can still retry
  /// after a fresh re-sniff, but frees disk from abandoned segment trees.
  Future<int> purgeStaleFailedTemps({
    Duration maxAge = const Duration(days: 3),
  }) async {
    final cutoff = DateTime.now().subtract(maxAge);
    var purged = 0;
    for (final task in _tasks.values) {
      if (task.state != DownloadState.failed) continue;
      if (task.createdAt.isAfter(cutoff)) continue;
      if (_activeTasks.contains(task.id)) continue;
      try {
        final tempDir = Directory(task.tempDir);
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
          purged++;
          debugPrint('Purged stale failed temp for ${task.savePath.split("/").last}');
        }
      } catch (e, s) {
        _logError('Failed to purge temp for ${task.id}', e, s);
      }
    }
    return purged;
  }

  /// True for tasks handled by the native torrent engine (magnet links and
  /// `.torrent` URLs). The engine manages its own on-disk save directory
  /// (files may land under a torrent-name subdir), so the task model's
  /// savePath must stay stable — see [_applyAutoClassification].
  bool _isTorrentTask(DownloadTask task) =>
      task.url.startsWith('magnet:') ||
      task.url.toLowerCase().endsWith('.torrent');

  /// Applies auto-classification to [task.savePath], inserting a category
  /// subfolder (e.g. "Videos", "Documents") between `/completed/` and the
  /// filename. Honors [autoClassifyMappings] for per-extension folder overrides.
  /// No-op when the path already has a user-chosen subfolder or does not live
  /// under `/completed/`. Avoids on-disk collisions with ` (1)`, ` (2)`, …
  ///
  /// Torrent engine tasks are SKIPPED: re-classifying them mid-flight makes
  /// [DownloadTask.savePath] diverge from the engine's real on-disk
  /// directory — [FilenameService.uniquePath] appends a ` (1)` collision
  /// suffix because the engine's dir already exists, and the subsequent
  /// rename no-ops on a directory. Publishing then fails with
  /// "Couldn't publish — completed file not found".
  void _applyAutoClassification(DownloadTask task) {
    if (_isTorrentTask(task)) return;
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

    final label = FileClassifier.folderLabelFor(
      after,
      customMappings: autoClassifyMappings,
    );
    final base = task.savePath.substring(0, idx + sep.length - 1);
    final candidate = '$base/$label/$after';
    // Avoid clobbering an existing completed file with the same name.
    task.savePath = FilenameService.uniquePath(
      candidate,
      reservedPaths: _tasks.values
          .where((t) => t.id != task.id)
          .map((t) => t.savePath),
    );
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
      final task = _tasks[id];
      // Best-effort: free temp workspace when dropping a failed history row.
      if (task != null && task.state == DownloadState.failed) {
        unawaited(() async {
          try {
            final tempDir = Directory(task.tempDir);
            if (await tempDir.exists()) {
              await tempDir.delete(recursive: true);
            }
          } catch (_) {}
        }());
      }
      _tasks.remove(id);
      _disposeTaskNotifier(id);
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
        // (Directory savePaths — torrent engine outputs — are intentionally
        // kept: the engine may still seed from them.)
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
      debugPrint('Failed to publish completed file: ${task.savePath.split("/").last}. Error: $error');
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
    _savePeriodicTimer?.cancel();
    _scheduleTimer?.cancel();
    _startupHoldTimer?.cancel();
    _startupHold = false;
    _notifiersClosed = true;
    for (final notifier in _taskNotifiers.values) {
      notifier.dispose();
    }
    _taskNotifiers.clear();
    queueVersion.dispose();
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
    // P1b: per-task notifier for live card UI. Skip no-op notifications
    // (pure ticks where nothing the card renders changed).
    final notifier = _taskNotifiers[task.id];
    if (notifier != null) {
      final prev = notifier.value;
      if (prev.downloadedBytes != task.downloadedBytes ||
          prev.speed != task.speed ||
          prev.state != task.state ||
          prev.statusMessage != task.statusMessage) {
        notifier.value = task;
      }
    } else {
      _taskNotifiers[task.id] = ValueNotifier<DownloadTask>(task);
    }
    if (!_notifiersClosed) {
      queueVersion.value++;
    }
    if (queuePath != null && !_isLoading) {
      // Debounce saves to prevent I/O saturation — the speed timer in
      // DownloadSplitter fires every 500ms per active download, and each
      // save does jsonEncode + 3 file operations.
      final isTerminal = task.state == DownloadState.completed ||
          task.state == DownloadState.failed ||
          task.state == DownloadState.paused;
      if (isTerminal) {
        // Evict oldest completed/failed tasks to keep memory bounded.
        _evictOldCompletedTasks();
        // Persist immediately for terminal states (completed/failed/paused)
        // so the queue survives a crash right after the state change.
        _queueDirty = false;
        _saveDebounceTimer?.cancel();
        unawaited(saveToFile(queuePath!));
      } else {
        _queueDirty = true;
        _saveDebounceTimer?.cancel();
        _saveDebounceTimer = Timer(const Duration(seconds: 1), () {
          _queueDirty = false;
          unawaited(saveToFile(queuePath!));
        });
        // The 1 s debounce is reset on every emit, so a long download would
        // otherwise never write the queue. The periodic timer flushes the
        // dirty state at least every ~5 s while a download is active.
        _startPeriodicSaveTimer();
      }
    }
    // Update the foreground service notification on every task state
    // change (throttled to 1 s inside syncForegroundService).
    syncForegroundService();
  }

  /// Arms the periodic queue-flush timer if it is not already running.
  void _startPeriodicSaveTimer() {
    _savePeriodicTimer ??= Timer.periodic(
      const Duration(seconds: 5),
      _onPeriodicSaveTick,
    );
  }

  /// Flushes a dirty queue and self-cancels once the queue is clean and
  /// nothing is downloading.
  void _onPeriodicSaveTick(Timer timer) {
    if (_queueDirty) {
      _queueDirty = false;
      if (queuePath != null && !_isLoading) {
        unawaited(saveToFile(queuePath!));
      }
    }
    if (!_queueDirty && _activeTasks.isEmpty) {
      timer.cancel();
      if (identical(_savePeriodicTimer, timer)) {
        _savePeriodicTimer = null;
      }
    }
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
  ///
  /// Throttled with a 1s coalescing timer so that high-throughput segment
  /// downloads (200+ state changes per second) don't flood the method
  /// channel with redundant start/stop/update invocations.
  void syncForegroundService() {
    _lastFgSyncTimer?.cancel();
    _lastFgSyncTimer = Timer(const Duration(milliseconds: 200), _syncFgNow);
  }

  void _syncFgNow() {
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
        // Same source as Queue + system notifications (segments for HLS).
        percent = task.progressPercent;
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
        debugPrint('Successfully recovered $recoveredCount tasks from corrupt history backups.');
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
    if (path.endsWith('.m3u8') ||
        path.endsWith('.m3u') ||
        path.endsWith('.mpd')) return true;
    // Path hints for disguised playlists (e.g. index.jpg under /hls/).
    // Checked BEFORE the known-direct-media list so that CDNs serving
    // playlists under non-.m3u8 URLs (e.g. .../hls/.../index.jpg) are
    // routed to the HLS downloader.  The HLS downloader will verify the
    // body starts with #EXTM3U and fail gracefully if it is not actually
    // an HLS playlist.
    final urlLower = url.toLowerCase();
    if (isPlaylistPathHint(path) ||
        urlLower.contains('m3u8') ||
        urlLower.contains('m3u') ||
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

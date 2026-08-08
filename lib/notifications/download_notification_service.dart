import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../downloader/models.dart';

void _logError(String context, Object error, [StackTrace? stack]) {
  debugPrint('[DownloadNotification] $context: $error');
}

String _formatByteSize(double bytes) {
  if (bytes <= 0) return '0 B';
  const suffixes = ['B', 'KB', 'MB', 'GB'];
  var i = 0;
  var size = bytes;
  while (size >= 1024 && i < suffixes.length - 1) {
    size /= 1024;
    i++;
  }
  return '${size.toStringAsFixed(1)} ${suffixes[i]}';
}

String _formatEta(double bytesRemaining, double speedBytesPerSec) {
  if (speedBytesPerSec <= 0 || bytesRemaining <= 0) return '';
  final seconds = (bytesRemaining / speedBytesPerSec).round();
  if (seconds < 60) return '${seconds}s';
  if (seconds < 3600) return '${seconds ~/ 60}m ${seconds % 60}s';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  return '${h}h ${m}m';
}

/// System notifications for download progress / completion / failure, with
/// action buttons that map onto [DownloadQueue] controls.
///
/// Actions use [AndroidNotificationAction.showsUserInterface] so they always
/// land on the main isolate (where the queue lives). Tapping the notification
/// body opens the Queue tab.
///
/// **P10 richNotifications:** When [isProCallback] returns true, progress
/// notifications include download speed and ETA. Completed notifications
/// gain an "Extract Audio" action (P5 integration).
class DownloadNotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final Set<String> _activeLiveNotificationIds = {};

  /// Per-task throttle state for progress notifications. The queue emits
  /// task updates every 250 ms per active splitter (and per HLS segment);
  /// each emit used to re-`show()` the notification — a full platform
  /// channel round trip on the UI isolate, ~12×/s with 3 downloads. We only
  /// re-show when at least 1 s elapsed AND the visible percent moved ≥ 1.
  final Map<String, ({int percent, DateTime at})> _lastProgressShow = {};

  /// P10: Pro gate for rich notification body (speed/ETA).
  bool Function()? isProCallback;

  static const String _channelId = 'aurora_download_progress';
  static const String _channelName = 'Download progress';
  static const String _channelDescription =
      'Shows how far along each download is.';
  static const String _doneChannelId = 'aurora_download_done';
  static const String _doneChannelName = 'Download complete';
  static const String _doneChannelDescription =
      'Notifies you when a download finishes.';
  static const String _watcherChannelId = 'aurora_watcher';
  static const String _watcherChannelName = 'Aurora Watcher';
  static const String _watcherChannelDescription =
      'New items detected by your watch rules.';

  /// Fixed notification id for watcher alerts — new detections replace the
  /// previous one instead of stacking.
  static const int _watcherNotificationId = 9001;

  /// Action IDs returned via [NotificationResponse.actionId].
  static const String actionPause = 'pause';
  static const String actionResume = 'resume';
  static const String actionCancel = 'cancel';
  static const String actionRetry = 'retry';
  static const String actionOpen = 'open';
  static const String actionExtractAudio = 'extract_audio';

  /// Host wires these to [DownloadQueue] / open-file handlers.
  void Function(String taskId)? onPause;
  void Function(String taskId)? onResume;
  void Function(String taskId)? onCancel;
  void Function(String taskId)? onRetry;
  void Function(String taskId)? onOpen;

  /// Fired when the user taps the notification body (not an action button).
  void Function(String taskId)? onNotificationTap;

  /// P5 integration: user tapped "Extract Audio" on a completed download.
  void Function(String taskId)? onExtractAudio;

  StreamSubscription<DownloadTask>? _subscription;
  StreamSubscription<String>? _removedSubscription;

  Future<void> initialize() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );
    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: _onNotificationResponse,
    );
    await _createChannels();
  }

  Future<void> _createChannels() async {
    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin == null) return;

    await androidPlugin.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: _channelDescription,
        importance: Importance.low,
        playSound: false,
        enableVibration: false,
        showBadge: false,
      ),
    );
    await androidPlugin.createNotificationChannel(
      const AndroidNotificationChannel(
        _doneChannelId,
        _doneChannelName,
        description: _doneChannelDescription,
        importance: Importance.defaultImportance,
        playSound: true,
        enableVibration: true,
        showBadge: true,
      ),
    );
    await androidPlugin.createNotificationChannel(
      const AndroidNotificationChannel(
        _watcherChannelId,
        _watcherChannelName,
        description: _watcherChannelDescription,
        importance: Importance.defaultImportance,
        playSound: true,
        enableVibration: true,
        showBadge: true,
      ),
    );
  }

  /// Shows a non-download alert (e.g. Aurora Watcher found new items).
  /// Uses a fixed id so consecutive watcher alerts replace each other.
  Future<void> showWatcherNotification(String title, String body) async {
    try {
      await _plugin.show(
        id: _watcherNotificationId,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _watcherChannelId,
            _watcherChannelName,
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            playSound: true,
            enableVibration: true,
            onlyAlertOnce: true,
            autoCancel: true,
            showWhen: true,
          ),
        ),
      );
    } catch (e, s) {
      _logError('Failed to show watcher notification', e, s);
    }
  }

  void listenTo(
    Stream<DownloadTask> taskStream, {
    Stream<String>? taskRemovedStream,
  }) {
    _subscription?.cancel();
    _subscription = taskStream.listen(_onTaskUpdated);
    _removedSubscription?.cancel();
    if (taskRemovedStream != null) {
      _removedSubscription = taskRemovedStream.listen(cancelForTask);
    }
  }

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    _removedSubscription?.cancel();
    _removedSubscription = null;
    _activeLiveNotificationIds.clear();
    _lastProgressShow.clear();
  }

  /// Dismiss the system notification for [taskId] (e.g. after cancel).
  void cancelForTask(String taskId) {
    try {
      final id = _notificationIdFor(taskId);
      unawaited(_plugin.cancel(id: id));
      _activeLiveNotificationIds.remove(taskId);
      _lastProgressShow.remove(taskId);
    } catch (e, s) {
      _logError('Failed to cancel notification', e, s);
    }
  }

  void _onNotificationResponse(NotificationResponse response) {
    final taskId = response.payload;
    if (taskId == null || taskId.isEmpty) return;

    try {
      if (response.notificationResponseType ==
          NotificationResponseType.selectedNotification) {
        onNotificationTap?.call(taskId);
        return;
      }

      switch (response.actionId) {
        case actionPause:
          onPause?.call(taskId);
        case actionResume:
          onResume?.call(taskId);
        case actionCancel:
          onCancel?.call(taskId);
        case actionRetry:
          onRetry?.call(taskId);
        case actionOpen:
          onOpen?.call(taskId);
        case actionExtractAudio:
          onExtractAudio?.call(taskId);
        default:
          // Unknown action — treat like a body tap.
          onNotificationTap?.call(taskId);
      }
    } catch (e, s) {
      _logError('Failed to handle notification action', e, s);
    }
  }

  void _onTaskUpdated(DownloadTask task) {
    try {
      switch (task.state) {
        case DownloadState.downloading:
          _updateProgressNotification(task);
        case DownloadState.paused:
          _showPausedNotification(task);
        case DownloadState.completed:
          _showCompletedNotification(task);
        case DownloadState.failed:
          _showFailedNotification(task);
        case DownloadState.merging:
          _updateMergingNotification(task);
        case DownloadState.idle:
        case DownloadState.scheduled:
          // Drop progress-style live notifs when the task is no longer active.
          if (_activeLiveNotificationIds.contains(task.id)) {
            cancelForTask(task.id);
          }
      }
    } catch (e, s) {
      _logError('Failed to process task update', e, s);
    }
  }

  void _updateProgressNotification(DownloadTask task) {
    final id = _notificationIdFor(task.id);
    final progress = _progressPercent(task);

    // Throttle: the queue emits every 250 ms per active download (and once
    // per HLS segment); each show() is a platform-channel round trip that
    // also resets the notification's visual state. Re-show only when the
    // user-visible percent moved ≥ 1 point AND at least 1 s has passed.
    final now = DateTime.now();
    final last = _lastProgressShow[task.id];
    if (last != null &&
        now.difference(last.at).inMilliseconds < 1000 &&
        (progress - last.percent).abs() < 1) {
      return;
    }
    _lastProgressShow[task.id] = (percent: progress, at: now);

    final filename = _shortName(task.savePath);

    // P10: Pro+ gets speed/ETA in notification body.
    final isRich = isProCallback != null && isProCallback!();
    final body = isRich ? _richProgressBody(task, filename) : filename;

    _plugin.show(
      id: id,
      title: 'Downloading $progress%',
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          onlyAlertOnce: true,
          showProgress: true,
          maxProgress: 100,
          progress: progress,
          indeterminate: task.totalBytes <= 0 && task.chunks.isEmpty,
          ongoing: true,
          priority: Priority.low,
          showWhen: true,
          usesChronometer: true,
          // Pin the chronometer to the task's real start time. Without an
          // explicit `when`, Android re-defaults it to "now" on EVERY
          // show() call — and _updateProgressNotification re-shows the
          // notification on each queue tick, so the elapsed counter was
          // resetting to 0 every few seconds.
          when: (task.scheduledStartAt ?? task.createdAt)
              .millisecondsSinceEpoch,
          autoCancel: false,
          actions: const <AndroidNotificationAction>[
            AndroidNotificationAction(
              actionPause,
              'Pause',
              showsUserInterface: true,
              cancelNotification: false,
            ),
            AndroidNotificationAction(
              actionCancel,
              'Cancel',
              showsUserInterface: true,
              cancelNotification: true,
            ),
          ],
        ),
      ),
      payload: task.id,
    );
    _activeLiveNotificationIds.add(task.id);
  }

  void _showPausedNotification(DownloadTask task) {
    final id = _notificationIdFor(task.id);
    final progress = _progressPercent(task);
    final filename = _shortName(task.savePath);
    final body = progress > 0 ? '$filename · $progress%' : filename;

    _plugin.show(
      id: id,
      title: 'Paused',
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          onlyAlertOnce: true,
          showProgress: task.totalBytes > 0 || task.chunks.isNotEmpty,
          maxProgress: 100,
          progress: progress,
          ongoing: false,
          autoCancel: false,
          priority: Priority.low,
          showWhen: true,
          actions: const <AndroidNotificationAction>[
            AndroidNotificationAction(
              actionResume,
              'Resume',
              showsUserInterface: true,
              cancelNotification: false,
            ),
            AndroidNotificationAction(
              actionCancel,
              'Cancel',
              showsUserInterface: true,
              cancelNotification: true,
            ),
          ],
        ),
      ),
      payload: task.id,
    );
    _activeLiveNotificationIds.add(task.id);
  }

  void _updateMergingNotification(DownloadTask task) {
    final id = _notificationIdFor(task.id);
    final filename = _shortName(task.savePath);

    _plugin.show(
      id: id,
      title: 'Finishing…',
      body: filename,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          onlyAlertOnce: true,
          showProgress: true,
          maxProgress: 100,
          progress: 0,
          indeterminate: true,
          ongoing: true,
          autoCancel: false,
          priority: Priority.low,
          showWhen: true,
          // Merging can't safely pause; Cancel still stops the task.
          actions: const <AndroidNotificationAction>[
            AndroidNotificationAction(
              actionCancel,
              'Cancel',
              showsUserInterface: true,
              cancelNotification: true,
            ),
          ],
        ),
      ),
      payload: task.id,
    );
    _activeLiveNotificationIds.add(task.id);
  }

  void _showCompletedNotification(DownloadTask task) {
    final id = _notificationIdFor(task.id);
    final filename = _shortName(task.savePath);
    final isRich = isProCallback != null && isProCallback!();

    final actions = <AndroidNotificationAction>[
      const AndroidNotificationAction(
        actionOpen,
        'Open',
        showsUserInterface: true,
        cancelNotification: true,
      ),
    ];
    // P5 integration: Pro+ gets a "Convert to audio" action on completed
    // downloads. The actual transform is delegated via onExtractAudio.
    if (isRich) {
      actions.add(const AndroidNotificationAction(
        actionExtractAudio,
        'Extract Audio',
        showsUserInterface: true,
        cancelNotification: false,
      ));
    }

    _plugin.show(
      id: id,
      title: 'Done',
      body: filename,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _doneChannelId,
          _doneChannelName,
          importance: Importance.defaultImportance,
          priority: Priority.high,
          showWhen: true,
          autoCancel: true,
          actions: actions,
        ),
      ),
      payload: task.id,
    );
    _activeLiveNotificationIds.remove(task.id);
  }

  void _showFailedNotification(DownloadTask task) {
    final id = _notificationIdFor(task.id);
    final filename = _shortName(task.savePath);
    _plugin.show(
      id: id,
      title: "Couldn't download",
      body: '$filename. ${task.errorMessage ?? 'Something went wrong.'}',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _doneChannelId,
          _doneChannelName,
          importance: Importance.defaultImportance,
          priority: Priority.high,
          showWhen: true,
          autoCancel: true,
          actions: const <AndroidNotificationAction>[
            AndroidNotificationAction(
              actionRetry,
              'Retry',
              showsUserInterface: true,
              cancelNotification: true,
            ),
          ],
        ),
      ),
      payload: task.id,
    );
    _activeLiveNotificationIds.remove(task.id);
  }

  /// P10: builds rich body with speed and ETA for [task].
  String _richProgressBody(DownloadTask task, String filename) {
    final speedLabel = _formatByteSize(task.speed);
    if (speedLabel == '0 B') return filename;
    final remaining = task.totalBytes - task.downloadedBytes;
    final eta = _formatEta(remaining.toDouble(), task.speed);
    return eta.isNotEmpty
        ? '$filename · $speedLabel/s · ETA $eta'
        : '$filename · $speedLabel/s';
  }

  /// Same 0–100 as Queue: [DownloadTask.progressPercent]
  /// (HLS = segments done / total; else bytes or HTTP chunks).
  int _progressPercent(DownloadTask task) => task.progressPercent;

  int _notificationIdFor(String taskId) => taskId.hashCode.abs() % 100000 + 1;

  static String _shortName(String path) {
    try {
      return path.split(RegExp(r'[/\\]')).last;
    } catch (_) {
      return path;
    }
  }
}

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../downloader/models.dart';

void _logError(String context, Object error, [StackTrace? stack]) {
  debugPrint('[DownloadNotification] $context: $error');
}

/// System notifications for download progress / completion / failure, with
/// action buttons that map onto [DownloadQueue] controls.
///
/// Actions use [AndroidNotificationAction.showsUserInterface] so they always
/// land on the main isolate (where the queue lives). Tapping the notification
/// body opens the Queue tab.
class DownloadNotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final Set<String> _activeLiveNotificationIds = {};

  static const String _channelId = 'aurora_download_progress';
  static const String _channelName = 'Download progress';
  static const String _channelDescription =
      'Shows how far along each download is.';
  static const String _doneChannelId = 'aurora_download_done';
  static const String _doneChannelName = 'Download complete';
  static const String _doneChannelDescription =
      'Notifies you when a download finishes.';

  /// Action IDs returned via [NotificationResponse.actionId].
  static const String actionPause = 'pause';
  static const String actionResume = 'resume';
  static const String actionCancel = 'cancel';
  static const String actionRetry = 'retry';
  static const String actionOpen = 'open';

  /// Host wires these to [DownloadQueue] / open-file handlers.
  void Function(String taskId)? onPause;
  void Function(String taskId)? onResume;
  void Function(String taskId)? onCancel;
  void Function(String taskId)? onRetry;
  void Function(String taskId)? onOpen;

  /// Fired when the user taps the notification body (not an action button).
  void Function(String taskId)? onNotificationTap;

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
      settings,
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
  }

  /// Dismiss the system notification for [taskId] (e.g. after cancel).
  void cancelForTask(String taskId) {
    try {
      final id = _notificationIdFor(taskId);
      unawaited(_plugin.cancel(id));
      _activeLiveNotificationIds.remove(taskId);
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
    final filename = _shortName(task.savePath);

    _plugin.show(
      id,
      'Downloading $progress%',
      filename,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          onlyAlertOnce: true,
          showProgress: true,
          maxProgress: 100,
          progress: progress.clamp(0, 100),
          indeterminate: task.totalBytes <= 0 && task.chunks.isEmpty,
          ongoing: true,
          priority: Priority.low,
          showWhen: true,
          usesChronometer: true,
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
      id,
      'Paused',
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          onlyAlertOnce: true,
          showProgress: task.totalBytes > 0 || task.chunks.isNotEmpty,
          maxProgress: 100,
          progress: progress.clamp(0, 100),
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
      id,
      'Finishing…',
      filename,
      NotificationDetails(
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
    _plugin.show(
      id,
      'Done',
      filename,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _doneChannelId,
          _doneChannelName,
          importance: Importance.defaultImportance,
          priority: Priority.high,
          showWhen: true,
          autoCancel: true,
          actions: const <AndroidNotificationAction>[
            AndroidNotificationAction(
              actionOpen,
              'Open',
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

  void _showFailedNotification(DownloadTask task) {
    final id = _notificationIdFor(task.id);
    final filename = _shortName(task.savePath);
    _plugin.show(
      id,
      "Couldn't download",
      '$filename. ${task.errorMessage ?? 'Something went wrong.'}',
      NotificationDetails(
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

  int _progressPercent(DownloadTask task) {
    if (task.totalBytes > 0) {
      return (task.downloadedBytes / task.totalBytes * 100).round();
    }
    if (task.chunks.isNotEmpty) {
      return (task.chunks.where((c) => c.isCompleted).length /
              task.chunks.length *
              100)
          .round();
    }
    return 0;
  }

  int _notificationIdFor(String taskId) => taskId.hashCode.abs() % 100000 + 1;

  static String _shortName(String path) {
    try {
      return path.split(RegExp(r'[/\\]')).last;
    } catch (_) {
      return path;
    }
  }
}

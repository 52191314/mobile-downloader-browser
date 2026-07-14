import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../logging/aurora_log.dart';
import '../downloader/models.dart';

void _logError(String context, Object error, [StackTrace? stack]) {
  debugPrint('[DownloadNotification] $context: $error');
  AuroraLog.instance.error(
    '$context: $error',
    category: LogCategory.notification,
    screen: LogScreen.background,
    eventType: LogEventType.error,
    stackTrace: stack,
  );
}

class DownloadNotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final Set<String> _activeLiveNotificationIds = {};

  static const String _channelId = 'aurora_download_progress';
  static const String _channelName = 'Download Progress';
  static const String _channelDescription =
      'Shows progress for active downloads';
  static const String _doneChannelId = 'aurora_download_done';
  static const String _doneChannelName = 'Download Complete';
  static const String _doneChannelDescription =
      'Alerts when a download finishes';

  StreamSubscription<DownloadTask>? _subscription;

  Future<void> initialize() async {
    const androidSettings = AndroidInitializationSettings('ic_notification');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );
    await _plugin.initialize(settings);
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

  void listenTo(Stream<DownloadTask> taskStream) {
    _subscription?.cancel();
    _subscription = taskStream.listen(_onTaskUpdated);
  }

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    _activeLiveNotificationIds.clear();
  }

  void _onTaskUpdated(DownloadTask task) {
    try {
      switch (task.state) {
        case DownloadState.downloading:
          _updateProgressNotification(task);
        case DownloadState.completed:
          _showCompletedNotification(task);
        case DownloadState.failed:
          _showFailedNotification(task);
        case DownloadState.paused:
        case DownloadState.idle:
        case DownloadState.merging:
          break;
      }
    } catch (e, s) {
      _logError('Failed to process task update', e, s);
    }
  }

  void _updateProgressNotification(DownloadTask task) {
    final id = _notificationIdFor(task.id);
    final progress = task.totalBytes > 0
        ? (task.downloadedBytes / task.totalBytes * 100).round()
        : (task.chunks.isNotEmpty
            ? (task.chunks.where((c) => c.isCompleted).length /
                    task.chunks.length *
                    100)
                .round()
            : 0);
    final filename = _shortName(task.savePath);

    _plugin.show(
      id,
      'Downloading — $progress%',
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
        ),
      ),
    );
    _activeLiveNotificationIds.add(task.id);
  }

  void _showCompletedNotification(DownloadTask task) {
    final id = _notificationIdFor(task.id);
    final filename = _shortName(task.savePath);
    _plugin.show(
      id,
      'Download complete',
      filename,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _doneChannelId,
          _doneChannelName,
          importance: Importance.defaultImportance,
          priority: Priority.high,
          showWhen: true,
          autoCancel: true,
        ),
      ),
    );
    _activeLiveNotificationIds.remove(task.id);
  }

  void _showFailedNotification(DownloadTask task) {
    final id = _notificationIdFor(task.id);
    final filename = _shortName(task.savePath);
    _plugin.show(
      id,
      'Download failed',
      '${task.errorMessage ?? 'Unknown error'} — $filename',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _doneChannelId,
          _doneChannelName,
          importance: Importance.defaultImportance,
          priority: Priority.high,
          autoCancel: true,
        ),
      ),
    );
    _activeLiveNotificationIds.remove(task.id);
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

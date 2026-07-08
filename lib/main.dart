import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'downloader/downloader.dart';
import 'downloader/url_filename_resolver.dart';
import 'logging/aurora_log.dart';
import 'logging/log_settings_store.dart';
import 'notifications/download_notification_service.dart';
import 'platform/download_foreground_service.dart';
import 'platform/public_downloads_service.dart';
import 'settings/download_settings.dart';
import 'sniffer/browser_controller.dart';
import 'sniffer/sniffer_screen.dart';
import 'sync/sync.dart';
import 'theme/aurora_colors.dart';
import 'theme/aurora_glass_background.dart';
import 'ui/pages/queue_page.dart';
import 'ui/widgets/aurora_dock.dart';
import 'ui/notifications/aurora_snackbar.dart';
import 'ui/pages/settings_page.dart';

/// Browser User-Agent used for manually pasted download URLs. Mirrors the
/// same constant in sniffer_screen.dart so manually-pasted HLS requests look
/// like they come from a real Chrome/Android browser — surrit.com's CDN,
/// Cloudflare WAF, and most media CDNs require a browser-like UA.
const _snifferDownloadUserAgent =
    'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

/// Top-level notifier for the app theme mode.  Updated by [_AuroraHomeState]
/// whenever the user changes [DownloadSettings.darkModePreference].
final ValueNotifier<ThemeMode> appThemeModeNotifier =
    ValueNotifier(ThemeMode.system);

void main() {
  // Global error handlers: catch any uncaught Dart/async errors so a single
  // plugin failure does not silently kill the app (which Android reports as
  // a crash to the user).  On the S23 Ultra this is especially important
  // because Samsung's One UI aggressively kills apps that hit an uncaught
  // error during init.
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        AuroraLog.instance.error(
          '[FlutterError] ${details.exceptionAsString()}',
          category: LogCategory.app,
          screen: LogScreen.unknown,
          eventType: LogEventType.error,
          stackTrace: details.stack,
        );
        debugPrint('[AuroraFlutterError] ${details.exceptionAsString()}');
      };
      runApp(const MyApp());
    },
    (error, stack) {
      AuroraLog.instance.fatal(
        '[ZoneError] $error',
        category: LogCategory.app,
        screen: LogScreen.background,
        eventType: LogEventType.error,
        stackTrace: stack,
      );
      debugPrint('[AuroraZoneError] $error\n$stack');
    },
  );
}

class MyApp extends StatelessWidget {
  final SnifferBrowserController? browserController;
  final DownloadQueue? downloadQueue;
  final DriveSyncService? driveSyncService;
  final int initialTabIndex;

  const MyApp({
    super.key,
    this.browserController,
    this.downloadQueue,
    this.driveSyncService,
    this.initialTabIndex = 1,
  });

  @override
  Widget build(BuildContext context) {
    // ListenableBuilder watches the top-level theme-mode notifier so that
    // MaterialApp is rebuilt when the user changes dark/light/system preference
    // in Settings.  The home widget (AuroraHome) retains its State because it
    // stays at the same position in the tree with the same widget type.
    return ListenableBuilder(
      listenable: appThemeModeNotifier,
      builder: (context, _) => MaterialApp(
        title: 'Aurora Downloader',
        debugShowCheckedModeBanner: false,
        themeMode: appThemeModeNotifier.value,
        theme: _buildLightTheme(),
        darkTheme: _buildDarkTheme(isOled: false),
        home: AuroraHome(
          browserController: browserController,
          downloadQueue: downloadQueue,
          driveSyncService: driveSyncService,
          initialTabIndex: initialTabIndex,
        ),
      ),
    );
  }
}

/// Builds the light-mode theme (Nord-inspired inverted palette).
ThemeData _buildLightTheme() {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: AuroraColorsLight.accent,
    brightness: Brightness.light,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: AuroraColorsLight.background,
    appBarTheme: AppBarTheme(
      backgroundColor: AuroraColorsLight.surface,
      foregroundColor: AuroraColorsLight.text,
      centerTitle: false,
      elevation: 0,
      titleTextStyle: TextStyle(
        color: AuroraColorsLight.text,
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AuroraColorsLight.surfaceVariant,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
      hintStyle: TextStyle(color: AuroraColorsLight.mutedText),
    ),
    cardTheme: CardThemeData(
      color: AuroraColorsLight.glassSurface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: AuroraColorsLight.glassBorder, width: 1),
      ),
    ),
    bottomAppBarTheme: BottomAppBarThemeData(
      color: AuroraColorsLight.dockSurface,
      elevation: 0,
      shape: const CircularNotchedRectangle(),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: AuroraColorsLight.accent,
      linearTrackColor: AuroraColorsLight.surfaceVariant,
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: AuroraColorsLight.accent,
      inactiveTrackColor: AuroraColorsLight.surfaceVariant,
      thumbColor: AuroraColorsLight.accent,
      overlayColor: AuroraColorsLight.accent.withValues(alpha: 0.14),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: AuroraColorsLight.dockSurface,
      indicatorColor: colorScheme.primaryContainer,
    ),
  );
}

/// Builds the dark-mode theme (Nord Aurora Glass palette).
///
/// When [isOled] is true the scaffold background is pure black
/// for OLED power savings.
ThemeData _buildDarkTheme({bool isOled = false}) {
  final bg = isOled ? AuroraColors.oledBlack : AuroraColors.background;
  final colorScheme = ColorScheme.fromSeed(
    seedColor: AuroraColors.accent,
    brightness: Brightness.dark,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: bg,
    appBarTheme: AppBarTheme(
      backgroundColor: AuroraColors.surface,
      foregroundColor: AuroraColors.text,
      centerTitle: false,
      elevation: 0,
      titleTextStyle: TextStyle(
        color: AuroraColors.text,
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AuroraColors.surfaceVariant,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
      hintStyle: TextStyle(color: AuroraColors.mutedText),
    ),
    cardTheme: CardThemeData(
      color: AuroraColors.glassSurface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: AuroraColors.glassBorder, width: 1),
      ),
    ),
    bottomAppBarTheme: BottomAppBarThemeData(
      color: AuroraColors.dockSurface,
      elevation: 0,
      shape: const CircularNotchedRectangle(),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: AuroraColors.accent,
      linearTrackColor: AuroraColors.surfaceVariant,
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: AuroraColors.accent,
      inactiveTrackColor: AuroraColors.surfaceVariant,
      thumbColor: AuroraColors.accent,
      overlayColor: AuroraColors.accent.withValues(alpha: 0.14),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: AuroraColors.dockSurface,
      indicatorColor: colorScheme.primaryContainer,
    ),
  );
}

class AuroraHome extends StatefulWidget {
  final SnifferBrowserController? browserController;
  final DownloadQueue? downloadQueue;
  final DriveSyncService? driveSyncService;
  final int initialTabIndex;

  const AuroraHome({
    super.key,
    this.browserController,
    this.downloadQueue,
    this.driveSyncService,
    this.initialTabIndex = 1,
  });

  @override
  State<AuroraHome> createState() => _AuroraHomeState();
}

class _AuroraHomeState extends State<AuroraHome> with WidgetsBindingObserver {
  /// Static flag so the battery-optimisation exemption dialog is shown
  /// only once per process lifetime (on the first download start).
  static bool _batteryOptRequested = false;

  late final DownloadQueue _downloadQueue;
  late final DriveSyncService _driveSyncService;
  late final SnifferBrowserController _browserController;
  late final TextEditingController _urlController;
  late final TextEditingController _folderController;
  late final TextEditingController _adblockSourceController;
  late final TextEditingController _customSearchController;
  late final ValueNotifier<int> _libraryUpdateNotifier;
  final DownloadSettingsStore _settingsStore = const DownloadSettingsStore();
  final PublicDownloadsService _publicDownloadsService =
      const PublicDownloadsService();
  final DownloadNotificationService _notificationService =
      DownloadNotificationService();
  StreamSubscription<DownloadTask>? _queueSubscription;
  StreamSubscription<DriveSyncState>? _driveSubscription;
  DownloadSettings _settings = DownloadSettings.defaults();
  double _speedLimitKbps = 0;
  int _currentTabIndex = 1; // Start on Browser tab; overridden in initState

  /// Tracks which top-level tabs have been visited.  Only visited tabs are
  /// built — prevents creating QueuePage + SettingsPage at launch when the
  /// user starts on the Browser tab.  Populated in initState.
  final Set<int> _visitedMainTabs = <int>{};
  int _sniffedCount = 0;
  late final ValueNotifier<int> _sniffedCountNotifier;
  DateTime? _lastBackPress;
  Timer? _adblockRefreshTimer;
  Timer? _queueRebuildTimer;
  final Map<String, DownloadState> _prevTaskStates = {};
  bool _isDisposed = false;

  void _logError(String context, Object error, [StackTrace? stack]) {
    debugPrint('[AuroraHome] $context: $error');
    AuroraLog.instance.error(
      '$context: $error',
      category: LogCategory.app,
      screen: _currentScreen,
      eventType: LogEventType.error,
      stackTrace: stack,
    );
  }

  LogScreen get _currentScreen {
    switch (_currentTabIndex) {
      case 0:
        return LogScreen.queue;
      case 1:
        return LogScreen.browser;
      case 2:
        return LogScreen.settings;
      default:
        return LogScreen.unknown;
    }
  }

  @override
  void initState() {
    super.initState();
    _currentTabIndex = widget.initialTabIndex;
    _visitedMainTabs.add(widget.initialTabIndex);
    _downloadQueue =
        widget.downloadQueue ??
        DownloadQueue(
          useNativeTorrentEngine: true,
          completedDownloadPublisher: _publicDownloadsService,
        );
    _driveSyncService = widget.driveSyncService ?? DriveSyncService();
    _browserController = widget.browserController ?? _createBrowserController();
    _urlController = TextEditingController();
    _libraryUpdateNotifier = ValueNotifier<int>(0);
    try {
      _folderController = TextEditingController(
        text: _driveSyncService.state.destinationFolderName,
      );
    } catch (e, s) {
      _logError('DriveSync init', e, s);
      _folderController = TextEditingController(text: 'Aurora Downloads');
    }
    try {
      _driveSyncService.attachQueue(_downloadQueue);
    } catch (e, s) {
      _logError('DriveSync attachQueue', e, s);
    }
    _adblockSourceController = TextEditingController();
    _customSearchController = TextEditingController(
      text: _settings.searchEngine.id == 'custom'
          ? _settings.searchEngine.templateUrl
          : '',
    );
    _sniffedCountNotifier = ValueNotifier<int>(0);
    _startAdblockAutoRefresh();
    unawaited(_loadSettings());
    unawaited(_initNotifications());
    _queueSubscription = _downloadQueue.onTaskUpdated.listen((task) {
      // QueuePage listens to task updates and throttles its own rebuilds.
      // The shell only needs a rebuild for visible queue UI or when the queue
      // tab has not been constructed yet.
      final shouldRebuildShell =
          _currentTabIndex == 0 || !_visitedMainTabs.contains(0);
      if (shouldRebuildShell &&
          (_queueRebuildTimer == null || !_queueRebuildTimer!.isActive)) {
        _queueRebuildTimer = Timer(const Duration(milliseconds: 500), () {
          if (mounted) setState(() {});
        });
      }
      // Log download state transitions.
      final fileName = task.savePath.split('/').last;
      final prevState = _prevTaskStates[task.id];
      if (prevState != task.state) {
        _prevTaskStates[task.id] = task.state;
        if (!_isDisposed) {
          AuroraLog.instance.info(
            'Task "$fileName": ${prevState?.name ?? "new"} → ${task.state.name}',
            category: LogCategory.download,
            screen: _currentScreen,
            eventType: LogEventType.stateChange,
            taskId: task.id,
          );
        }
      }
      // Request battery-optimisation exemption on first download start
      // so Android does not kill the process during background downloads.
      // Uses a static flag so the system dialog is shown only once per
      // process lifetime.
      if (task.state == DownloadState.downloading) {
        _requestBatteryOptOnce();
      }
    });
    _initIntentChannel();
    WidgetsBinding.instance.addObserver(this);
  }

  Future<void> _initNotifications() async {
    try {
      await _notificationService.initialize();
      _notificationService.listenTo(_downloadQueue.onTaskUpdated);
    } catch (e, s) {
      _logError('Failed to init notifications', e, s);
    }
    // On Android 13+, request the POST_NOTIFICATIONS permission so the
    // foreground service notification is visible, which makes Android
    // less likely to kill the process during background downloads.
    unawaited(DownloadForegroundService.requestNotificationPermission());
    _driveSubscription = _driveSyncService.onStateChanged.listen((state) {
      if (mounted) {
        setState(() {
          _folderController.text = state.destinationFolderName;
        });
      }
    });
  }

  SnifferBrowserController _createBrowserController() {
    return SnifferWebViewControllerImpl();
  }

  /// Called on the first download-start event to request battery
  /// optimisation exemption.  On Android 6+ this shows a system dialog;
  /// the user must tap "Allow" to whitelist Aurora so doze / app-standby
  /// does not kill the process or throttle network during background
  /// downloads.
  static void _requestBatteryOptOnce() {
    if (_batteryOptRequested) return;
    _batteryOptRequested = true;
    unawaited(DownloadForegroundService.requestBatteryOptimizationExemption());
  }

  /// Switches the active main tab (Queue=0, Browser=1, Settings=2).
  /// Automatically pauses browser WebViews when leaving the Browser tab
  /// and resumes them when re-entering, so the Dart event loop is freed
  /// for download HTTP stream processing.
  void _selectTab(int index) {
    final previous = _currentTabIndex;
    setState(() {
      _currentTabIndex = index;
      _visitedMainTabs.add(index);
    });
    AuroraLog.instance.info(
      'Tab switch: $previous → $index',
      category: LogCategory.app,
      screen: LogScreen.settings,
      eventType: LogEventType.navigation,
    );
    AuroraLog.instance.info(
      'Tab switch: $previous → $index',
      category: LogCategory.app,
      screen: LogScreen.settings,
      eventType: LogEventType.navigation,
    );
  }

  @override
  void dispose() {
    _isDisposed = true;
    _adblockRefreshTimer?.cancel();
    _queueRebuildTimer?.cancel();
    _queueSubscription?.cancel();
    _driveSubscription?.cancel();
    _urlController.dispose();
    _sniffedCountNotifier.dispose();
    _libraryUpdateNotifier.dispose();
    _folderController.dispose();
    _adblockSourceController.dispose();
    _customSearchController.dispose();
    _notificationService.dispose();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_downloadQueue.dispose());
    unawaited(_driveSyncService.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // App going to background — log it so we can trace kills.
      debugPrint(
        '[AuroraHome] App backgrounded, active downloads: ${_downloadQueue.activeTasks.length}',
      );
      AuroraLog.instance.info(
        'App backgrounded, active downloads: ${_downloadQueue.activeTasks.length}',
        category: LogCategory.app,
        eventType: LogEventType.lifecycle,
      );
      // Pause browser WebViews to free resources for background downloads.
      unawaited(_browserController.pauseAllWebViews());
      // Force-sync the foreground service so Android sees the persistent
      // notification immediately and is less likely to kill us.
      _downloadQueue.syncForegroundService();
      // Persist the queue immediately so the latest state survives
      // any subsequent process kill.
      if (_downloadQueue.queuePath != null) {
        unawaited(_downloadQueue.saveToFile(_downloadQueue.queuePath!));
      }
    } else if (state == AppLifecycleState.resumed) {
      debugPrint('[AuroraHome] App resumed');
      AuroraLog.instance.info(
        'App resumed',
        category: LogCategory.app,
        eventType: LogEventType.lifecycle,
      );
      // Only resume WebViews if the user is on the Browser tab.
      if (_currentTabIndex == 1) {
        unawaited(_browserController.resumeActiveWebView());
      }
    } else if (state == AppLifecycleState.detached) {
      debugPrint('[AuroraHome] App detached — process likely being killed');
      AuroraLog.instance.warn(
        'App detached — process likely being killed',
        category: LogCategory.app,
        eventType: LogEventType.lifecycle,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Browser tab has its own bottom bar; Queue and Settings need dock padding.
    final needsDockPad = _currentTabIndex != 1;
    final bottomInset = needsDockPad
        ? MediaQuery.of(context).padding.bottom + 64.0
        : 0.0;
    return AuroraGlassBackground(
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          if (_currentTabIndex == 1) {
            // Browser tab: delegate to the active tab's controller via the
            // system-back handler registered by SnifferScreen.
            final handled = await _browserController.handleSystemBack();
            if (handled) return;
            // WebView is at history root → double-press-to-exit.
            final now = DateTime.now();
            if (_lastBackPress == null ||
                now.difference(_lastBackPress!) > const Duration(seconds: 2)) {
              _lastBackPress = now;
              _showSnack('Press back again to exit');
            } else {
              await SystemNavigator.pop();
            }
            return;
          }
          // Queue/Settings: exit the app immediately (Firefox/Samsung behavior).
          await SystemNavigator.pop();
        },
        child: Scaffold(
          body: Stack(
            children: [
              Padding(
                padding: EdgeInsets.only(bottom: bottomInset),
                child: Stack(
                  children: [
                    if (_visitedMainTabs.contains(0))
                      IgnorePointer(
                        ignoring: _currentTabIndex != 0,
                        child: AnimatedOpacity(
                          opacity: _currentTabIndex == 0 ? 1.0 : 0.0,
                          duration: const Duration(milliseconds: 150),
                          child: QueuePage(
                            key: const ValueKey('queue_tab'),
                            queue: _downloadQueue,
                            urlController: _urlController,
                            onAddDownload: _addDownloadFromUrl,
                            onOpenDownload: _openDownload,
                            onRetryTask: (task) async {
                              await _downloadQueue.retryHlsTaskWithRefreshAsync(
                                task.id,
                                forceReload: true,
                              );
                            },
                            onPauseTask: (task) =>
                                () => unawaited(
                                  _downloadQueue.pauseTaskAsync(task.id),
                                ),
                            onResumeTask: (task) =>
                                () => unawaited(
                                  _downloadQueue.resumeTaskAsync(task.id),
                                ),
                            onCancelTask: (task) =>
                                () => unawaited(
                                  _downloadQueue.cancelTaskAsync(task.id),
                                ),
                            onForceMergeTask: (task) =>
                                _downloadQueue.forceMergeTask(task.id),
                            speedLimitKbps: _speedLimitKbps,
                            onOpenUrlInBrowser: _openUrlInBrowser,
                            onResniffAuto: _resniffAuto,
                            onResniffManual: _resniffManual,
                          ),
                        ),
                      ),
                    if (_visitedMainTabs.contains(1))
                      IgnorePointer(
                        ignoring: _currentTabIndex != 1,
                        child: AnimatedOpacity(
                          opacity: _currentTabIndex == 1 ? 1.0 : 0.0,
                          duration: const Duration(milliseconds: 150),
                          child: SnifferScreen(
                            key: const ValueKey('browser_tab'),
                            controller: _browserController,
                            downloadQueue: _downloadQueue,
                            settings: _settings,
                            onSettingsChanged: _updateSettings,
                            libraryUpdateNotifier: _libraryUpdateNotifier,
                            onOpenQueue: () => _selectTab(0),
                            onOpenSettings: () => _selectTab(2),
                            onSniffedCountChanged: (count) {
                              if (_sniffedCount == count) return;
                              _sniffedCount = count;
                              if (mounted) {
                                _sniffedCountNotifier.value = count;
                              }
                            },
                          ),
                        ),
                      ),
                    if (_visitedMainTabs.contains(2))
                      IgnorePointer(
                        ignoring: _currentTabIndex != 2,
                        child: AnimatedOpacity(
                          opacity: _currentTabIndex == 2 ? 1.0 : 0.0,
                          duration: const Duration(milliseconds: 150),
                          child: SettingsPage(
                            key: const ValueKey('settings_tab'),
                            driveSyncService: _driveSyncService,
                            folderController: _folderController,
                            adblockSourceController: _adblockSourceController,
                            customSearchController: _customSearchController,
                            settings: _settings,
                            onSettingsChanged: _updateSettings,
                            downloadQueue: _downloadQueue,
                            libraryUpdateNotifier: _libraryUpdateNotifier,
                            speedLimitKbps: _speedLimitKbps,
                            onSpeedLimitChanged: (value) {
                              setState(() => _speedLimitKbps = value);
                              _downloadQueue.setSpeedLimit(value.round());
                              TorrentDownloader.setNativeDownloadLimit(
                                (value * 1024).round(),
                              );
                            },
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: MediaQuery.of(context).padding.bottom + 8,
                child: Offstage(
                  offstage: _currentTabIndex == 1, // hidden on browser tab
                  child: AuroraDock(
                    currentIndex: _currentTabIndex,
                    onTabSelected: (index) => _selectTab(index),
                    onAddPressed: _addDownloadFromUrl,
                    sniffedBadgeCountNotifier: _sniffedCountNotifier,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _addDownloadFromUrl() async {
    var rawUrl = _urlController.text.trim();
    while (rawUrl.startsWith('"') ||
        rawUrl.startsWith("'") ||
        rawUrl.startsWith('`')) {
      rawUrl = rawUrl.substring(1);
    }
    while (rawUrl.endsWith('"') ||
        rawUrl.endsWith("'") ||
        rawUrl.endsWith('`')) {
      rawUrl = rawUrl.substring(0, rawUrl.length - 1);
    }
    rawUrl = rawUrl.trim();
    rawUrl = rawUrl.replaceAll(' ', '%20');

    final uri = Uri.tryParse(rawUrl);
    if (uri == null || !uri.hasScheme) {
      _showSnack('Enter a valid URL.');
      return;
    }

    final baseDir = await _completedWorkspaceDirectory();
    final tempDir = await _tempWorkspaceDirectory();
    final isTorrent = rawUrl.startsWith('magnet:') || _isTorrentFileUrl(uri);
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final headers = _buildManualDownloadHeaders(rawUrl);

    if (isTorrent) {
      final task = DownloadTask(
        id: id,
        url: rawUrl,
        headers: headers,
        savePath: baseDir.path,
        tempDir: '${tempDir.path}/$id',
      );
      if (_downloadQueue.urlExists(rawUrl)) {
        if (!mounted) return;
        final skip = await _showDuplicatePrompt(context, 'Torrent');
        if (skip) {
          _urlController.clear();
          return;
        }
      }
      _downloadQueue.addTask(task);
      _urlController.clear();
      _showSnack('Added torrent to queue.');
      if (mounted) setState(() {});
      return;
    }

    // Probe the URL for a real filename, Content-Type, and size.
    final resolved = await resolveFilename(url: rawUrl, headers: headers);
    final fileName = resolved.name;
    final task = DownloadTask(
      id: id,
      url: rawUrl,
      headers: headers,
      savePath: '${baseDir.path}/$fileName',
      tempDir: '${tempDir.path}/$id',
      contentType: resolved.contentType,
      totalBytes: resolved.contentLength ?? -1,
    );
    bool force = false;
    if (_downloadQueue.urlExists(rawUrl)) {
      if (!mounted) return;
      final skip = await _showDuplicatePrompt(context, fileName);
      if (skip) {
        _urlController.clear();
        return;
      }
      force = true;
    }

    _downloadQueue.addTask(task, force: force);
    _urlController.clear();
    _showSnack('Added $fileName to queue.');
    if (mounted) setState(() {});
  }

  void _openUrlInBrowser(String url) {
    AuroraLog.instance.info(
      '_openUrlInBrowser("$url")',
      category: LogCategory.app,
      screen: LogScreen.queue,
      eventType: LogEventType.userAction,
    );
    _openUrlInBrowserAfterTabReady(url);
  }

  void _openUrlInBrowserAfterTabReady(String url) {
    if (_currentTabIndex != 1 || !_visitedMainTabs.contains(1)) {
      _selectTab(1);
    }
    _browserController.requestOpenUrl(url);
  }

  /// Auto-resniff: probe the download URL through the browser controller
  /// to check whether a fresher / token-refreshed variant is available.
  /// If a new URL is found and differs from the task's current URL, show
  /// a dialog asking the user whether to update or create a new download.
  Future<void> _resniffAuto(DownloadTask task) async {
    try {
      final sourcePage = task.sourcePageUrl;
      if (sourcePage != null && sourcePage.isNotEmpty) {
        if (_currentTabIndex != 1 || !_visitedMainTabs.contains(1)) {
          _selectTab(1);
        }
        final sourceUri = Uri.tryParse(sourcePage);
        if (sourceUri != null && sourceUri.hasScheme) {
          await _browserController.loadRequest(sourceUri, addToHistory: false);
          // Let page JS kick off player/playlist requests before probing.
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }

      // Try the HLS playlist refresh path first (handles token expiry).
      String? freshUrl = await _browserController.fetchFreshPlaylistUrl(
        task.url,
      );
      // Fall back to a head-fetch through the WebView's JS context.
      if (freshUrl == null || freshUrl == task.url) {
        final headers = await _browserController.fetchHeadersViaJavaScript(
          task.url,
        );
        // The URL itself hasn't changed; nothing to update.
        if (headers == null || headers.isEmpty) {
          if (mounted) {
            _showSnack('No updated link found — the URL is still valid.');
          }
          return;
        }
        freshUrl = task.url;
      }

      // If the fresh URL is the same, nothing to do.
      if (_normalizeForCompare(freshUrl) == _normalizeForCompare(task.url)) {
        if (mounted) _showSnack('The link is unchanged — no update needed.');
        return;
      }

      if (!mounted) return;
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Updated Link Found'),
          content: const Text(
            'A fresher download link was detected.\n\n'
            'Update the existing download with the new link, '
            'or create a separate new download?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('cancel'),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('new'),
              child: const Text('Create New'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop('update'),
              child: const Text('Update Existing'),
            ),
          ],
        ),
      );
      if (choice == 'update') {
        task.url = freshUrl;
        if (mounted) {
          _showSnack('Download link updated. You can retry the download.');
        }
        setState(() {});
      } else if (choice == 'new') {
        final newId = DateTime.now().microsecondsSinceEpoch.toString();
        final baseDir = await _completedWorkspaceDirectory();
        final tempDir = await _tempWorkspaceDirectory();
        final newTask = DownloadTask(
          id: newId,
          url: freshUrl,
          headers: task.headers,
          savePath: '${baseDir.path}/${_taskFileName(freshUrl)}',
          tempDir: '${tempDir.path}/$newId',
          contentType: task.contentType,
          sourcePageUrl: task.sourcePageUrl,
        );
        _downloadQueue.addTask(newTask, force: true);
        if (mounted) _showSnack('New download added with refreshed link.');
        setState(() {});
      }
    } catch (e, s) {
      _logError('Auto-resniff failed', e, s);
      if (mounted) _showSnack('Resniff failed: $e');
    }
  }

  /// Manual resniff: open the task's source page in the browser so the
  /// user can re-navigate and re-sniff the media URL manually.  Sets the
  /// queue into "resniff mode" so that duplicate URLs trigger a dialog
  /// instead of being silently skipped.
  Future<void> _resniffManual(DownloadTask task) async {
    _downloadQueue.resniffPendingTaskId = task.id;
    final target = task.sourcePageUrl ?? task.url;
    AuroraLog.instance.info(
      '_resniffManual: target="$target", sourcePageUrl=${task.sourcePageUrl}',
      category: LogCategory.app,
      screen: LogScreen.queue,
      eventType: LogEventType.userAction,
    );
    _openUrlInBrowserAfterTabReady(target);
    if (mounted) {
      _showSnack(
        'Opened source page — re-sniff the media. A dialog will appear if the link is detected as a duplicate.',
      );
    }
  }

  static String _normalizeForCompare(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.replace(queryParameters: {}).toString();
    } catch (_) {
      return url;
    }
  }

  static String _taskFileName(String url) {
    try {
      return Uri.parse(url).pathSegments.last;
    } catch (_) {
      return 'download_${DateTime.now().millisecondsSinceEpoch}';
    }
  }

  void _initIntentChannel() {
    const intentChannel = MethodChannel('aurora_downloader/intent');
    // Get initial URL (cold start)
    intentChannel.invokeMethod<String>('getInitialUrl').then((url) {
      if (url != null && url.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _handleIncomingUrl(url);
        });
      }
    });

    // Listen for new URLs (hot start)
    intentChannel.setMethodCallHandler((call) async {
      if (call.method == 'onNewUrl') {
        final String? url = call.arguments as String?;
        if (url != null && url.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _handleIncomingUrl(url);
          });
        }
      }
    });
  }

  void _handleIncomingUrl(String url) {
    if (url.startsWith('magnet:') || url.contains('.torrent')) {
      _urlController.text = url;
      unawaited(_addDownloadFromUrl());
    } else {
      _openUrlInBrowser(url);
    }
  }

  Future<Directory> _completedWorkspaceDirectory() async {
    try {
      final docs = await getApplicationSupportDirectory();
      final dir = Directory('${docs.path}/completed');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    } catch (_) {
      final dir = Directory('${Directory.systemTemp.path}/aurora_downloads');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    }
  }

  /// Returns a persistent directory for chunk/segment files.
  /// Uses [getApplicationSupportDirectory] instead of [getTemporaryDirectory]
  /// so that partial download bytes survive OS cache clearing (which can
  /// happen at any time under disk pressure even with unrestricted battery).
  ///
  /// The old cache-based temp dir is NOT cleaned up — in-progress downloads
  /// started before this change will see their chunk files missing (treated
  /// as 0 bytes on disk) and restart once, which is acceptable.
  Future<Directory> _tempWorkspaceDirectory() async {
    try {
      final docs = await getApplicationSupportDirectory();
      final dir = Directory('${docs.path}/downloads_tmp');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    } catch (_) {
      final dir = Directory('${Directory.systemTemp.path}/aurora_tmp');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    }
  }

  Future<void> _loadSettings() async {
    final loaded = await _settingsStore.load();
    if (!mounted) return;
    setState(() {
      _settings = loaded;
      _adblockSourceController.clear();
      _customSearchController.text = loaded.searchEngine.id == 'custom'
          ? loaded.searchEngine.templateUrl
          : '';
    });
    _applySettings(loaded);

    try {
      final docs = await getApplicationSupportDirectory();
      final path = docs.path;
      _downloadQueue.queuePath = '$path/download_queue.json';

      await Future.wait([
        _driveSyncService.loadSyncedTasks(path),
        LogSettingsStore.instance.load(path).then((verbosity) {
          return AuroraLog.instance.initialize(
            '$path/aurora_logs.json',
            verbosity: verbosity,
          );
        }),
        _downloadQueue.loadFromFile('$path/download_queue.json'),
      ]);
      if (mounted) setState(() {});
    } catch (e, s) {
      _logError('Failed to load download queue/logs', e, s);
    }
  }

  void _updateSettings(DownloadSettings settings) {
    setState(() => _settings = settings);
    _applySettings(settings);
    unawaited(_settingsStore.save(settings));
    AuroraLog.instance.info(
      'Settings updated',
      category: LogCategory.settings,
      screen: _currentScreen,
      eventType: LogEventType.userAction,
    );
  }

  void _applySettings(DownloadSettings settings) {
    _downloadQueue.configure(
      maxConcurrentDownloads: settings.maxConcurrentDownloads,
      numChunksPerTask: settings.chunksPerTask,
      completedDownloadPublisher: _publicDownloadsService,
      autoClassifyEnabled: settings.autoClassifyEnabled,
      remuxTsToMp4: settings.remuxTsToMp4,
      autoRetry: settings.autoRetry,
      retryLimit: settings.retryLimit,
      minSpeedThresholdBytesPerSec: settings.minSpeedThresholdKbps * 1024,
      stallTimeoutSeconds: settings.stallTimeoutSeconds,
      partialDownloadThreshold: settings.partialDownloadThreshold,
      minBytesBeforeFullRetry: 10 * 1024 * 1024,
    );
    final sources = settings.trackerBlockingEnabled
        ? AdblockFilterSource.trackerSourcesEnabled(
            settings.adblockFilterSources,
          )
        : settings.adblockFilterSources;
    unawaited(
      _browserController.configureAdBlock(
        enabled: settings.adblockEnabled,
        popupBlockingEnabled: settings.popupBlockingEnabled,
        filterSources: sources,
        manualRules: settings.manualAdBlockRules,
        cosmeticRules: settings.manualCosmeticRules,
      ),
    );
    // Apply proxy settings (recreates HTTP client if needed).
    _downloadQueue.applyProxySettings(
      settings.proxyType,
      settings.proxyHost,
      settings.proxyPort,
      settings.proxyUsername,
      settings.proxyPassword,
    );
    // Update the app theme mode based on the user's preference.
    appThemeModeNotifier.value = _themeModeFromPreference(
      settings.darkModePreference,
    );
  }

  /// Maps [DarkModePreference] to the Flutter [ThemeMode] used by MaterialApp.
  static ThemeMode _themeModeFromPreference(DarkModePreference pref) {
    return switch (pref) {
      DarkModePreference.system => ThemeMode.system,
      DarkModePreference.off => ThemeMode.light,
      DarkModePreference.forced => ThemeMode.dark,
    };
  }

  void _startAdblockAutoRefresh() {
    _adblockRefreshTimer?.cancel();
    _adblockRefreshTimer = Timer.periodic(const Duration(hours: 24), (_) {
      if (!_settings.adblockEnabled) return;
      unawaited(
        _browserController.configureAdBlock(
          enabled: _settings.adblockEnabled,
          popupBlockingEnabled: _settings.popupBlockingEnabled,
          filterSources: _settings.adblockFilterSources,
          manualRules: _settings.manualAdBlockRules,
          cosmeticRules: _settings.manualCosmeticRules,
        ),
      );
    });
  }

  Future<void> _openDownload(DownloadTask task) async {
    try {
      await _publicDownloadsService.open(task);
    } catch (error) {
      _showSnack('Could not open file: $error');
    }
  }

  bool _isTorrentFileUrl(Uri uri) {
    return uri.path.toLowerCase().endsWith('.torrent');
  }

  void _showSnack(String message) {
    if (!mounted) return;
    AuroraSnackbar.show(context, message);
  }

  /// Builds browser-like HTTP headers for a user-pasted URL so the HLS
  /// downloader's playlist and segment requests don't trigger Cloudflare
  /// WAF or surrit.com's 403 referer check.  Uses the URL's own origin
  /// as the Referer — this matches what a browser would send when the
  /// user navigates directly to the URL, and surrit.com's CDN accepts it.
  Map<String, String> _buildManualDownloadHeaders(String url) {
    final ua = _snifferDownloadUserAgent;
    final uri = Uri.tryParse(url);
    final origin = (uri != null && uri.host.isNotEmpty)
        ? '${uri.scheme}://${uri.host}'
        : null;
    return {
      'User-Agent': ua,
      if (origin != null) 'Referer': '$origin/',
      'Accept': '*/*',
      'Accept-Language': 'en-US,en;q=0.9',
      if (origin != null) 'Origin': origin,
      'Accept-Encoding': 'gzip, deflate, br',
      'Sec-Fetch-Dest': 'empty',
      'Sec-Fetch-Mode': 'cors',
      'Sec-Fetch-Site': 'same-origin',
    };
  }

  Future<bool> _showDuplicatePrompt(
    BuildContext context,
    String filename,
  ) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Duplicate Download'),
          content: Text(
            'The file "$filename" is already in your download queue/history.\n\n'
            'Do you want to skip downloading it again?',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Download Anyway'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Skip'),
            ),
          ],
        );
      },
    );
    return result ?? true;
  }
}

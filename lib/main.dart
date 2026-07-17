import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'downloader/download_rules.dart';
import 'downloader/downloader.dart';
import 'downloader/filename_service.dart';
import 'downloader/url_filename_resolver.dart';
import 'logging/aurora_log.dart';
import 'logging/log_settings_store.dart';
import 'utils/log_server.dart';
import 'notifications/download_notification_service.dart';
import 'platform/download_foreground_service.dart';
import 'platform/public_downloads_service.dart';
import 'settings/download_settings.dart';
import 'sniffer/browser_controller.dart';
import 'sniffer/browser_open_request.dart';
import 'sniffer/sniffer_screen.dart';
import 'sync/sync.dart';
import 'theme/aurora_glass_background.dart';
import 'theme/aurora_palette.dart';
import 'theme/aurora_theme.dart';
import 'ui/pages/queue_page.dart';
import 'ui/widgets/aurora_dock.dart';
import 'ui/notifications/aurora_snackbar.dart';
import 'ui/pages/settings_page.dart';
import 'backup/auto_backup_service.dart';
import 'premium/pro_entitlement.dart';
import 'premium/pro_features.dart';
import 'sniffer/worker_isolate_pool.dart';

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

/// Top-level notifier for OLED-optimised pure-black dark mode.
/// Set to `true` when [DarkModePreference.forced] is active (the setting
/// is labelled "Dark (OLED black)" in the UI).
final ValueNotifier<bool> appOledDarkNotifier = ValueNotifier(false);

enum BatteryOptChoice {
  openSettings,
  later,
  neverAskAgain,
}

void main() {
  // Global error handlers: catch any uncaught Dart/async errors so a single
  // plugin failure does not silently kill the app (which Android reports as
  // a crash to the user).  On the S23 Ultra this is especially important
  // because Samsung's One UI aggressively kills apps that hit an uncaught
  // error during init.
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      if (kDebugMode) {
        LogServer.start();
      }
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
    // Listen to both the theme-mode and OLED-dark notifiers. Wired via
    // Listenable.merge so a single rebuild handles both changes.
    return ListenableBuilder(
      listenable: Listenable.merge([appThemeModeNotifier, appOledDarkNotifier]),
      builder: (context, _) {
        final mode = appThemeModeNotifier.value;
        final isOled = appOledDarkNotifier.value;
        final isLight = _isLightFor(mode);
        return MaterialApp(
          title: 'Aurora Downloader',
          debugShowCheckedModeBanner: false,
          themeMode: mode,
          theme: buildLightTheme(),
          // OLED black: only when the user explicitly selected
          // "Dark (OLED black)" (forced). System-default and light mode
          // use the standard near-black slate background.
          darkTheme: buildDarkTheme(isOled: isOled),
          // Wrap the entire subtree with the palette so every descendant
          // resolves colors via `context.ac` regardless of brightness.
          builder: (ctx, child) => AuroraTheme(
            isLight: isLight,
            child: child ?? const SizedBox.shrink(),
          ),
          home: AuroraHome(
            browserController: browserController,
            downloadQueue: downloadQueue,
            driveSyncService: driveSyncService,
            initialTabIndex: initialTabIndex,
          ),
        );
      },
    );
  }

  /// Maps the active [ThemeMode] to a boolean for the [AuroraPalette].
  ///
  /// "System default" always resolves to **dark** — the app's historic
  /// identity is dark, and the vast majority of users expect it to stay
  /// dark unless they explicitly opt into "Light" via Settings.  This
  /// prevents the "inverted" appearance on devices in light mode (the
  /// default on Samsung phones).
  static bool _isLightFor(ThemeMode mode) {
    if (mode == ThemeMode.light) return true;
    // ThemeMode.system → always dark (preserves historic behaviour).
    // ThemeMode.dark   → always dark.
    return false;
  }
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
  final ProEntitlement _proEntitlement = ProEntitlement();
  final PublicDownloadsService _publicDownloadsService =
      PublicDownloadsService();
  final DownloadNotificationService _notificationService =
      DownloadNotificationService();
  late final AutoBackupService _autoBackupService = AutoBackupService(
    isProCallback: () => _proEntitlement.isPro,
  );
  StreamSubscription<DownloadTask>? _queueSubscription;
  StreamSubscription<DriveSyncState>? _driveSubscription;
  DownloadSettings _settings = DownloadSettings.defaults();
  DownloadRuleEngine? _ruleEngine;
  double _speedLimitKbps = 0;
  Future<void>? _loadSettingsFuture;
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
  Timer? _resniffModeTimer;
  final Map<String, DownloadState> _prevTaskStates = {};
  bool _isDisposed = false;

  /// Queue → Browser external URL opens (View source / Scan / intents).
  final BrowserOpenRequestBus _browserOpenRequestBus = BrowserOpenRequestBus();

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
      _folderController = TextEditingController(text: 'Aurora Downloader');
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
    _proEntitlement.addListener(_onProEntitlementChanged);
    _loadSettingsFuture = _loadSettings();
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
        unawaited(_requestBatteryOptOnce());
      }
    });
    _initIntentChannel();
    WidgetsBinding.instance.addObserver(this);
    // Request battery-optimisation exemption on app start (once), so the
    // user sees the prompt even if they browse without downloading yet.
    // The 2-second delay lets the UI settle first.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeRequestBatteryOptOnLaunch();
    });
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

  /// Called on the first battery-opt event (either app launch or first
  /// download start) to request battery optimisation exemption.
  /// On Android 6+ this shows a system dialog; the user must tap "Allow"
  /// to whitelist Aurora so doze / app-standby does not kill the process
  /// or throttle network during background downloads.
  /// If the manufacturer has additional autostart/background-activity
  /// settings (Xiaomi, Huawei, OPPO, Vivo, OnePlus, Samsung, etc.),
  /// also shows an OEM guidance dialog pointing the user to the right
  /// settings screen.
  Future<void> _requestBatteryOptOnce() async {
    try {
      if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    } catch (_) {}
    if (_loadSettingsFuture != null) {
      await _loadSettingsFuture;
    }
    if (_settings.neverAskBatteryOpt) return;
    if (_batteryOptRequested) return;
    _batteryOptRequested = true;

    // Open the standard AOSP battery-opt exemption dialog and detect OEM.
    final oemInfo =
        await DownloadForegroundService.requestBatteryOptimizationExemption();
    if (!mounted) return;

    final oem = oemInfo['oem'] as String?;
    if (oem != null) {
      _showOemGuidanceDialog(oem);
    }
  }

  Future<BatteryOptChoice?> _showBatteryOptRequestDialog() {
    return showDialog<BatteryOptChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Battery Optimization'),
        content: const Text(
          'Aurora Downloader requires background execution permission to ensure uninterrupted downloads.\n\n'
          'Would you like to exclude Aurora from battery optimization?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(BatteryOptChoice.neverAskAgain),
            child: const Text('Never ask again'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(BatteryOptChoice.later),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(BatteryOptChoice.openSettings),
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
  }

  /// Checks battery optimisation status shortly after app launch, and
  /// triggers the exemption request (once) if the app is not yet whitelisted.
  Future<void> _maybeRequestBatteryOptOnLaunch() async {
    try {
      if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    } catch (_) {}
    if (_loadSettingsFuture != null) {
      await _loadSettingsFuture;
    }
    if (_settings.neverAskBatteryOpt) return;
    if (_batteryOptRequested) return;

    // Brief pause so the initial UI is fully settled.
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;

    // Re-check after delay in case state changed
    if (_settings.neverAskBatteryOpt) return;
    if (_batteryOptRequested) return;

    if (await DownloadForegroundService.isIgnoringBatteryOptimizations()) {
      return;
    }

    final choice = await _showBatteryOptRequestDialog();
    if (!mounted) return;

    if (choice == BatteryOptChoice.neverAskAgain) {
      _updateSettings(_settings.copyWith(neverAskBatteryOpt: true));
    } else if (choice == BatteryOptChoice.openSettings) {
      await _requestBatteryOptOnce();
    }
  }

  /// Shows a dialog explaining the OEM-specific autostart / background-
  /// activity settings screen the user should also visit for full
  /// background download reliability.
  void _showOemGuidanceDialog(String oem) {
    final label = DownloadForegroundService.oemLabel(oem);
    final name = DownloadForegroundService.oemName(oem);
    if (label == null || name == null) return;

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Background downloads on $name'),
        content: Text(
          'Some $name devices also require enabling "$label" for Aurora '
          'to keep downloading in the background.\n\n'
          'Do you want to open the system settings?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              unawaited(DownloadForegroundService.openOemAutostartPage());
            },
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
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
    _resniffModeTimer?.cancel();
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
    _autoBackupService.dispose();
    WorkerIsolatePool.instance.dispose();
    _browserOpenRequestBus.dispose();
    _proEntitlement.removeListener(_onProEntitlementChanged);
    _proEntitlement.dispose();
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
              _showSnack('Press back once more to close');
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
                            onShareDownload: _shareDownload,
                            onExportDownload: _exportCompletedFile,
                            onOpenBrowser: () => _selectTab(1),
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
                            openRequestBus: _browserOpenRequestBus,
                            isProCallback: () => _proEntitlement.isPro,
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
                            autoBackupService: _autoBackupService,
                            proEntitlement: _proEntitlement,
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
      _showSnack('Enter a valid URL and try again.');
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
        final choice = await _showDuplicatePrompt(context, 'Torrent');
        if (choice == DuplicateChoice.skip) {
          _urlController.clear();
          return;
        }
        if (choice == DuplicateChoice.updateExisting) {
          final existing = _downloadQueue.getTaskByUrl(rawUrl);
          if (existing != null) {
            final urlChanged = existing.url != rawUrl;
            existing.url = rawUrl;
            existing.headers = task.headers;
            if (urlChanged) {
              existing.downloadedBytes = 0;
              existing.totalBytes = 0;
            }
            if (existing.state == DownloadState.failed ||
                existing.state == DownloadState.paused ||
                existing.state == DownloadState.completed) {
              existing.state = DownloadState.idle;
            }
            existing.failureReason = null;
            existing.errorMessage = null;
            await _downloadQueue.resumeTaskAsync(existing.id);
            _urlController.clear();
            _showSnack('Done — Link updated. Torrent will retry.');
            if (mounted) setState(() {});
            return;
          }
        }
      }
      _downloadQueue.addTask(task);
      _urlController.clear();
      _showSnack('Done \u2014 torrent added to queue.');
      if (mounted) setState(() {});
      return;
    }

    // Probe the URL for a real filename, Content-Type, and size.
    final resolved = await resolveFilename(url: rawUrl, headers: headers);
    final fileName = FilenameService.truncate(
      FilenameService.sanitize(resolved.name),
    );
    final savePath = FilenameService.uniquePath(
      '${baseDir.path}/$fileName',
      reservedPaths: _downloadQueue.allTasks.map((t) => t.savePath),
    );
    final task = DownloadTask(
      id: id,
      url: rawUrl,
      headers: headers,
      savePath: savePath,
      tempDir: '${tempDir.path}/$id',
      contentType: resolved.contentType,
      totalBytes: resolved.contentLength ?? -1,
    );
    bool force = false;
    if (_downloadQueue.urlExists(rawUrl)) {
      if (!mounted) return;
      final choice = await _showDuplicatePrompt(context, fileName);
      if (choice == DuplicateChoice.skip) {
        _urlController.clear();
        return;
      }
      if (choice == DuplicateChoice.updateExisting) {
        final existing = _downloadQueue.getTaskByUrl(rawUrl);
        if (existing != null) {
          await _downloadQueue.updateTaskFromDonor(existing.id, task);
          _urlController.clear();
          _showSnack('Done — Link updated. Download will retry.');
          if (mounted) setState(() {});
          return;
        }
      }
      force = true;
    }

    _downloadQueue.addTask(task, force: force);
    _urlController.clear();
    _showSnack('Done \u2014 $fileName added to queue.');
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

  /// Switch to the Browser tab and navigate to [url].
  ///
  /// Uses [BrowserOpenRequestBus] so SnifferScreen handles the load on the
  /// **active tab's live WebView** (same reliability as History open-all /
  /// address bar). The old `openUrlInNewTab` controller callback was a no-op
  /// in practice (logs showed the call from main with no page load).
  void _openUrlInBrowserAfterTabReady(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;

    final firstVisitToBrowser = !_visitedMainTabs.contains(1);
    if (_currentTabIndex != 1 || firstVisitToBrowser) {
      _selectTab(1);
    }

    void publish() {
      if (!mounted) return;
      AuroraLog.instance.info(
        'browserOpenRequestBus.request("$trimmed") '
        '(firstVisit=$firstVisitToBrowser, browserMounted='
        '${_visitedMainTabs.contains(1)})',
        category: LogCategory.app,
        screen: LogScreen.queue,
        eventType: LogEventType.navigation,
      );
      // Primary path: ChangeNotifier bus → SnifferScreen listener.
      _browserOpenRequestBus.request(trimmed);
      // Fallback if bus listener was not yet attached (first frame after
      // first Browser visit): keep controller pending queue as well.
      if (firstVisitToBrowser) {
        _browserController.openUrlInNewTab(trimmed);
      }
    }

    // Wait one frame so SnifferScreen is in the tree on first visit and
    // popup menus have dismissed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (firstVisitToBrowser) {
        WidgetsBinding.instance.addPostFrameCallback((_) => publish());
      } else {
        publish();
      }
    });
  }

  /// Auto-resniff: probe the download URL through the browser controller
  /// to check whether a fresher / token-refreshed variant is available.
  /// If a new URL is found and differs from the task's current URL, show
  /// a dialog asking the user whether to update or create a new download.
  Future<void> _resniffAuto(DownloadTask task) async {
    try {
      final sourcePage = task.sourcePageUrl;
      if (sourcePage != null && sourcePage.isNotEmpty) {
        // Open the source page in a real browser tab (same path as
        // "Scan in browser" / "View source page"). Loading via
        // `_browserController.loadRequest` only hits the shared first-tab
        // controller, which is often not the active WebView — so the
        // Browser screen appeared without the source page.
        _openUrlInBrowserAfterTabReady(sourcePage);
        // Let the page JS kick off player/playlist requests before probing.
        await Future<void>.delayed(const Duration(seconds: 3));
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
            _showSnack('Link is still valid. No update needed.');
          }
          return;
        }
        freshUrl = task.url;
      }

      // If the fresh URL is the same, nothing to do.
      if (_normalizeForCompare(freshUrl) == _normalizeForCompare(task.url)) {
        if (mounted) _showSnack('Link is unchanged. No update needed.');
        return;
      }

      if (!mounted) return;
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('New Link Detected'),
          content: const Text(
            'A fresher link is available for this download. '
            'Update the current one or start a separate download.',
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
              child: const Text('Update Link'),
            ),
          ],
        ),
      );
      if (choice == 'update') {
        // Build a donor with the fresh URL so updateTaskFromDonor can rebind
        // bridges, refresh cookies, and wipe stale segments when the token
        // changed. Plain URL swap left restored tasks without WebView context.
        final donor = DownloadTask(
          id: 'donor_${task.id}',
          url: freshUrl,
          headers: task.headers,
          savePath: task.savePath,
          tempDir: task.tempDir,
          contentType: task.contentType,
          sourcePageUrl: task.sourcePageUrl,
        );
        donor.copyBrowserBridgesFrom(task);
        await _downloadQueue.updateTaskFromDonor(task.id, donor);
        if (mounted) {
          _showSnack('Link updated. Download will retry.');
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
        newTask.copyBrowserBridgesFrom(task);
        _downloadQueue.addTask(newTask, force: true);
        if (mounted) _showSnack('Done \u2014 new download created with refreshed link.');
        setState(() {});
      }
    } catch (e, s) {
      _logError('Auto-resniff failed', e, s);
      if (mounted) _showSnack('Link refresh failed. $e');
    }
  }

  /// Manual resniff: open the task's source page in the browser so the
  /// user can re-navigate and re-sniff the media URL manually.  Sets the
  /// queue into "resniff mode" so that duplicate URLs trigger a dialog
  /// instead of being silently skipped.
  Future<void> _resniffManual(DownloadTask task) async {
    _downloadQueue.resniffPendingTaskId = task.id;
    // Auto-expire resniff mode so a stale pending task doesn't surprise the
    // user with a dialog later if they never re-sniff a matching URL.
    _resniffModeTimer?.cancel();
    _resniffModeTimer = Timer(const Duration(minutes: 5), () {
      if (_downloadQueue.resniffPendingTaskId == task.id) {
        _downloadQueue.resniffPendingTaskId = null;
      }
    });
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
        'Source page opened. Tap the media to refresh the link.',
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

    // Load download rules.
    try {
      final rules = await const DownloadRulesStore().load();
      if (mounted) {
        setState(() => _ruleEngine = DownloadRuleEngine(rules));
      }
    } catch (e, s) {
      _logError('Failed to load download rules', e, s);
    }

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
      // Free disk from abandoned failed-task segment trees older than 3 days.
      unawaited(_downloadQueue.purgeStaleFailedTemps());
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

  void _onProEntitlementChanged() {
    // Re-apply current settings so caps (concurrent, chunks, proxy, etc.)
    // reflect the new Pro status immediately.
    if (mounted) _applySettings(_settings);
  }

  void _applySettings(DownloadSettings settings) {
    final isPro = _proEntitlement.isPro;

    // Keep public publish root in sync with Settings → Download Defaults.
    final dest = DownloadSettings.normalizeDownloadDestination(
      settings.downloadDestination,
    );
    _publicDownloadsService.rootRelativePath =
        DownloadSettings.mediaStoreRelativeFromDisplay(dest);

    unawaited(_autoBackupService.configure(settings));
    _downloadQueue.wifiOnly = settings.wifiOnly;
    _downloadQueue.configure(
      maxConcurrentDownloads: settings.maxConcurrentDownloads.clamp(
        1,
        isPro ? ProFeatures.maxConcurrentPro : ProFeatures.maxConcurrentFree,
      ),
      numChunksPerTask: settings.chunksPerTask.clamp(
        1,
        isPro ? ProFeatures.chunksPerTaskPro : ProFeatures.chunksPerTaskFree,
      ),
      completedDownloadPublisher: _publicDownloadsService,
      autoClassifyEnabled: settings.autoClassifyEnabled,
      remuxTsToMp4: settings.remuxTsToMp4,
      autoClassifyMappings: settings.autoClassifyMappings,
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
    // Apply proxy settings (Pro only; free users get no proxy).
    if (isPro) {
      _downloadQueue.applyProxySettings(
        settings.proxyType,
        settings.proxyHost,
        settings.proxyPort,
        settings.proxyUsername,
        settings.proxyPassword,
      );
    } else {
      _downloadQueue.applyProxySettings(
        ProxyType.none, '', 0, '', '',
      );
    }
    // Update the app theme mode and OLED-dark flag based on the user's
    // preference.  "Dark (OLED black)" → forced → OLED pure black.
    appThemeModeNotifier.value = _themeModeFromPreference(
      settings.darkModePreference,
    );
    appOledDarkNotifier.value =
        settings.darkModePreference == DarkModePreference.forced;
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
      _showSnack('Couldn\u2019t open the file. $error');
    }
  }

  Future<void> _shareDownload(DownloadTask task) async {
    try {
      await PublicDownloadsService.shareFile(task.savePath);
    } catch (error) {
      _showSnack('Couldn\u2019t share the file. $error');
    }
  }

  Future<void> _exportCompletedFile(DownloadTask task) async {
    try {
      final displayName = task.savePath.split('/').last;
      final mimeType = PublicDownloadsService.mimeTypeForName(task.savePath);
      final success = await _publicDownloadsService.exportFile(
        sourcePath: task.savePath,
        displayName: displayName,
        mimeType: mimeType,
      );
      if (!mounted) return;
      if (success) {
        _showSnack('Done \u2014 file exported.');
      } else {
        _showSnack('Export cancelled.');
      }
    } catch (error) {
      _showSnack('Couldn\u2019t export the file. $error');
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

  Future<DuplicateChoice> _showDuplicatePrompt(
    BuildContext context,
    String filename,
  ) async {
    final result = await showDialog<DuplicateChoice>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Already in Queue'),
          content: const Text(
            'This download link has already been added to your queue.\n\n'
            'The URL may have changed (token refresh). Update the existing download with the new link, or create a separate one.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(DuplicateChoice.skip),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(DuplicateChoice.downloadAgain),
              child: const Text('Create New'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(DuplicateChoice.updateExisting),
              child: const Text('Update Existing'),
            ),
          ],
        );
      },
    );
    return result ?? DuplicateChoice.skip;
  }
}

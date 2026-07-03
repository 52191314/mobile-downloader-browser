import 'dart:async';
import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'downloader/downloader.dart';
import 'notifications/download_notification_service.dart';
import 'platform/public_downloads_service.dart';
import 'settings/download_settings.dart';
import 'sniffer/browser_controller.dart';
import 'sniffer/sniffer_screen.dart';
import 'sync/sync.dart';
import 'theme/aurora_colors.dart';
import 'theme/aurora_glass_background.dart';
import 'ui/pages/queue_page.dart';
import 'ui/widgets/aurora_dock.dart';
import 'ui/pages/settings_page.dart';

/// Browser User-Agent used for manually pasted download URLs. Mirrors the
/// same constant in sniffer_screen.dart so manually-pasted HLS requests look
/// like they come from a real Chrome/Android browser — surrit.com's CDN,
/// Cloudflare WAF, and most media CDNs require a browser-like UA.
const _snifferDownloadUserAgent =
    'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

void main() {
  // Global error handlers: catch any uncaught Dart/async errors so a single
  // plugin failure does not silently kill the app (which Android reports as
  // a crash to the user).  On the S23 Ultra this is especially important
  // because Samsung's One UI aggressively kills apps that hit an uncaught
  // error during init.
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      debugPrint('[AuroraFlutterError] ${details.exceptionAsString()}');
    };
    runApp(const MyApp());
  }, (error, stack) {
    debugPrint('[AuroraZoneError] $error\n$stack');
  });
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
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        return MaterialApp(
          title: 'Aurora Downloader',
          debugShowCheckedModeBanner: false,
          theme: _buildTheme(),
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
}

ThemeData _buildTheme() {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: AuroraColors.accent,
    brightness: Brightness.dark,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: AuroraColors.background,
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
      color: colorScheme.primary,
      linearTrackColor: AuroraColors.surfaceVariant,
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: colorScheme.primary,
      inactiveTrackColor: AuroraColors.surfaceVariant,
      thumbColor: colorScheme.primary,
      overlayColor: colorScheme.primary.withValues(alpha: 0.14),
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
  late final DownloadQueue _downloadQueue;
  late final DriveSyncService _driveSyncService;
  late final SnifferBrowserController _browserController;
  late final TextEditingController _urlController;
  late final TextEditingController _folderController;
  late final TextEditingController _adblockSourceController;
  late final TextEditingController _customSearchController;
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
  DateTime? _lastBackPress;
  Timer? _adblockRefreshTimer;
  Timer? _queueRebuildTimer;

  void _logError(String context, Object error, [StackTrace? stack]) {
    debugPrint('[AuroraHome] $context: $error');
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
    _startAdblockAutoRefresh();
    unawaited(_loadSettings());
    unawaited(_initNotifications());
    _queueSubscription = _downloadQueue.onTaskUpdated.listen((task) {
      if (_queueRebuildTimer == null || !_queueRebuildTimer!.isActive) {
        _queueRebuildTimer = Timer(const Duration(milliseconds: 500), () {
          if (mounted) setState(() {});
        });
      }
    });
    WidgetsBinding.instance.addObserver(this);
  }

  Future<void> _initNotifications() async {
    try {
      await _notificationService.initialize();
      _notificationService.listenTo(_downloadQueue.onTaskUpdated);
    } catch (e, s) {
      _logError('Failed to init notifications', e, s);
    }
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

  @override
  void dispose() {
    _adblockRefreshTimer?.cancel();
    _queueRebuildTimer?.cancel();
    _queueSubscription?.cancel();
    _driveSubscription?.cancel();
    _urlController.dispose();
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
      debugPrint('[AuroraHome] App backgrounded, active downloads: ${_downloadQueue.activeTasks.length}');
      // Force-sync the foreground service so Android sees the persistent
      // notification immediately and is less likely to kill us.
      _downloadQueue.syncForegroundService();
    } else if (state == AppLifecycleState.resumed) {
      debugPrint('[AuroraHome] App resumed');
    } else if (state == AppLifecycleState.detached) {
      debugPrint('[AuroraHome] App detached — process likely being killed');
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
            final canGoBack = await _browserController.canGoBack();
            if (canGoBack) {
              await _browserController.goBack();
              return;
            }
          }
          if (_currentTabIndex != 1) {
            setState(() {
              _currentTabIndex = 1;
              _visitedMainTabs.add(1);
            });
            return;
          }
          final now = DateTime.now();
          if (_lastBackPress == null ||
              now.difference(_lastBackPress!) > const Duration(seconds: 2)) {
            _lastBackPress = now;
            _showSnack('Press back again to exit');
          }
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
                            onShareDownload: _shareDownload,
                            onExportDownload: _exportCompletedFile,
                            onRetryTask: (task) async {
                              await _downloadQueue.retryHlsTaskWithRefreshAsync(
                                task.id,
                                forceReload: true,
                              );
                            },
                            onPauseTask: (task) =>
                                () => unawaited(_downloadQueue.pauseTaskAsync(task.id)),
                            onResumeTask: (task) =>
                                () => unawaited(_downloadQueue.resumeTaskAsync(task.id)),
                            onCancelTask: (task) =>
                                () => unawaited(_downloadQueue.cancelTaskAsync(task.id)),
                            onForceMergeTask: (task) =>
                                _downloadQueue.forceMergeTask(task.id),
                            speedLimitKbps: _speedLimitKbps,
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
                            onOpenQueue: () =>
                                setState(() { _currentTabIndex = 0; _visitedMainTabs.add(0); }),
                            onOpenSettings: () =>
                                setState(() { _currentTabIndex = 2; _visitedMainTabs.add(2); }),
                            onSniffedCountChanged: (count) =>
                                setState(() => _sniffedCount = count),
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
                            speedLimitKbps: _speedLimitKbps,
                            onSpeedLimitChanged: (value) {
                              setState(() => _speedLimitKbps = value);
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
                    onTabSelected: (index) =>
                        setState(() { _currentTabIndex = index; _visitedMainTabs.add(index); }),
                    onAddPressed: _addDownloadFromUrl,
                    sniffedBadgeCount: _sniffedCount,
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
    final fileName = isTorrent ? '' : _safeFileName(uri);
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final headers = _buildManualDownloadHeaders(rawUrl);
    final task = DownloadTask(
      id: id,
      url: rawUrl,
      headers: headers,
      savePath: isTorrent ? baseDir.path : '${baseDir.path}/$fileName',
      tempDir: '${tempDir.path}/$id',
    );
    bool force = false;
    if (_downloadQueue.urlExists(rawUrl)) {
      if (!mounted) return;
      final skip = await _showDuplicatePrompt(context, isTorrent ? 'Torrent' : fileName);
      if (skip) {
        _urlController.clear();
        return;
      }
      force = true;
    }

    _downloadQueue.addTask(task, force: force);
    _urlController.clear();
    _showSnack(
      isTorrent ? 'Added torrent to queue.' : 'Added $fileName to queue.',
    );
    if (mounted) setState(() {});
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
      final lPath = '${docs.path}/download_logs.json';
      await DownloadLogger.instance.initialize(lPath);

      final qPath = '${docs.path}/download_queue.json';
      _downloadQueue.queuePath = qPath;
      await _downloadQueue.loadFromFile(qPath);
      if (mounted) setState(() {});
    } catch (e, s) {
      _logError('Failed to load download queue/logs', e, s);
    }
  }

  void _updateSettings(DownloadSettings settings) {
    setState(() => _settings = settings);
    _applySettings(settings);
    unawaited(_settingsStore.save(settings));
  }

  void _applySettings(DownloadSettings settings) {
    _downloadQueue.configure(
      maxConcurrentDownloads: settings.maxConcurrentDownloads,
      numChunksPerTask: settings.chunksPerTask,
      completedDownloadPublisher: _publicDownloadsService,
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

  Future<void> _shareDownload(DownloadTask task) async {
    try {
      await _publicDownloadsService.share(task);
    } catch (error) {
      _showSnack('Could not share file: $error');
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
        _showSnack('File exported successfully.');
      } else {
        _showSnack('Export cancelled.');
      }
    } catch (error) {
      _showSnack('Could not export file: $error');
    }
  }

  String _safeFileName(Uri uri) {
    final lastSegment = uri.pathSegments.isNotEmpty
        ? uri.pathSegments.last
        : 'aurora-download.bin';
    final decoded = Uri.decodeComponent(lastSegment);
    final sanitized = decoded.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return sanitized.isEmpty ? 'aurora-download.bin' : sanitized;
  }

  bool _isTorrentFileUrl(Uri uri) {
    return uri.path.toLowerCase().endsWith('.torrent');
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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

  Future<bool> _showDuplicatePrompt(BuildContext context, String filename) async {
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

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'l10n/app_localizations.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'analytics/aurora_analytics_service.dart';
import 'dev/screenshot_fixtures.dart';
import 'downloader/download_rules.dart';
import 'downloader/downloader.dart';
import 'notifications/download_notification_service.dart';
import 'platform/download_foreground_service.dart';
import 'platform/public_downloads_service.dart';
import 'settings/download_settings.dart';
import 'settings/engagement_prompt_service.dart';
import 'sniffer/browser_controller.dart';
import 'sniffer/browser_open_request.dart';
import 'sniffer/sniffer_screen.dart';
import 'sniffer/sniffer_url_utils.dart';
import 'theme/aurora_glass_background.dart';
import 'theme/aurora_palette.dart';
import 'theme/aurora_theme.dart';
import 'theme/aurora_tokens.dart';
import 'ui/pages/queue_page.dart';
import 'ui/widgets/aurora_dock.dart';
import 'ui/notifications/aurora_snackbar.dart';
import 'ui/pages/settings_page.dart';
import 'ui/settings_open_request.dart';
import 'backup/auto_backup_service.dart';
import 'premium/premium_flags.dart';
import 'premium/build_channel.dart';
import 'premium/ffmpeg/ffmpeg_module_loader.dart';
import 'sync/sync.dart';
import 'premium/license/license_service.dart';
import 'premium/pro_entitlement.dart';
import 'premium/pro_features.dart';
import 'premium/play_billing_service.dart';
import 'premium/pro_upsell_sheet.dart';
import 'premium/send_to_pc_sheet.dart';
import 'premium/audio_extract_platform.dart';
import 'premium/phase2_caps.dart';
import 'premium/accent_pack.dart';
import 'premium/vault_service.dart';
import 'sniffer/token_refresh_service.dart';
import 'sniffer/sheets/duplicate_download_dialog.dart';

import 'compliance/restricted_media_policy.dart';
import 'sniffer/worker_isolate_pool.dart';
import 'premium/watcher/watcher_service.dart';
import 'premium/automation/automation_api_service.dart';
import 'settings/onboarding_experiment.dart';
import 'ui/widgets/onboarding_spotlight.dart';
import 'platform/app_update_service.dart';

/// Browser User-Agent used for manually pasted download URLs. Mirrors the
/// same constant in sniffer_screen.dart so manually-pasted HLS requests look
/// like they come from a real Chrome/Android browser — surrit.com's CDN,
/// Cloudflare WAF, and most media CDNs require a browser-like UA.
const _snifferDownloadUserAgent =
    'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

/// Top-level notifier for the app theme mode.  Updated by [_AuroraHomeState]
/// whenever the user changes [DownloadSettings.darkModePreference].
final ValueNotifier<ThemeMode> appThemeModeNotifier = ValueNotifier(
  ThemeMode.system,
);

/// Top-level notifier for OLED-optimised pure-black dark mode.
/// Set to `true` when [DarkModePreference.forced] is active (the setting
/// is labelled "Dark (OLED black)" in the UI).
final ValueNotifier<bool> appOledDarkNotifier = ValueNotifier(false);

/// Top-level notifier for the app display language (locale).
/// Updated by [_AuroraHomeState] whenever the user changes [DownloadSettings.appLanguageCode].
final ValueNotifier<Locale?> appLocaleNotifier = ValueNotifier(null);

enum BatteryOptChoice { openSettings, later, neverAskAgain }

/// Firebase Analytics event name for a download state transition, or null
/// when the state has no funnel event (Play-only analytics).
String? analyticsEventNameFor(DownloadState state) => switch (state) {
  DownloadState.downloading => 'download_started',
  DownloadState.completed => 'download_completed',
  DownloadState.failed => 'download_failed',
  _ => null,
};

void main() {
  // Global error handlers: catch any uncaught Dart/async errors so a single
  // plugin failure does not silently kill the app (which Android reports as
  // a crash to the user).  On the S23 Ultra this is especially important
  // because Samsung's One UI aggressively kills apps that hit an uncaught
  // error during init.
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      // Firebase Analytics (Play-only repo). Fail-open: analytics must never
      // block startup — if init fails, log and continue without it.
      try {
        await Firebase.initializeApp();
      } catch (e, s) {
        debugPrint('[FirebaseInitError] $e\n$s');
      }
      try {
        await loadSavedAccentPack();
      } catch (e, s) {
        debugPrint('[AccentPackInitError] $e\n$s');
      }
      try {
        await initSystemUserAgent();
      } catch (e, s) {
        debugPrint('[InitSystemUAError] $e\n$s');
      }
      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        debugPrint('[FlutterError] ${details.exceptionAsString()}');
        if (details.silent) return;
        // Crashlytics (fail-open, same rule as Analytics): record the fatal
        // Flutter error, but a crash-reporting failure must never break the
        // existing handler.
        unawaited(
          FirebaseCrashlytics.instance.recordFlutterFatalError(details).catchError(
                (Object e) => debugPrint('[CrashlyticsError] $e'),
              ),
        );
      };
      // Engine-level errors (platform-channel exceptions etc.) don't reach
      // FlutterError.onError or the zone handler — route them to Crashlytics
      // as fatal and swallow (return true) so the app keeps running.
      PlatformDispatcher.instance.onError = (error, stack) {
        unawaited(
          FirebaseCrashlytics.instance.recordError(error, stack, fatal: true).catchError(
                (Object e) => debugPrint('[CrashlyticsPlatformError] $e'),
              ),
        );
        return true;
      };
      // In release mode, ErrorWidget shows a blank grey box by default
      // (invisible on a white/dark background). Override it so any build()
      // exception surfaces a visible diagnostic instead of a silent
      // white screen.
      if (!kDebugMode) {
        ErrorWidget.builder = (FlutterErrorDetails details) {
          return MaterialApp(
            home: Scaffold(
              backgroundColor: const Color(0xFF0A0F14),
              body: SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Aurora startup error:\n\n'
                    '${details.exceptionAsString()}\n\n'
                    '${details.stack?.toString().split('\n').take(15).join('\n') ?? ''}',
                    style: const TextStyle(
                      color: Color(0xFFFF6B6B),
                      fontSize: 13,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
            ),
          );
        };
      }
      try {
        runApp(const MyApp());
      } catch (e, s) {
        debugPrint('[AuroraFatalStartup] $e\n$s');
        // Show a minimal diagnostic app so the screen isn't blank.
        runApp(
          MaterialApp(
            home: Scaffold(
              backgroundColor: const Color(0xFF0A0F14),
              body: SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Aurora failed to start:\n\n$e\n\n'
                    '${s.toString().split('\n').take(20).join('\n')}',
                    style: const TextStyle(
                      color: Color(0xFFFF6B6B),
                      fontSize: 13,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }
    },
    (error, stack) {
      debugPrint('[ZoneError] $error');
      debugPrint('[AuroraZoneError] $error\n$stack');
      // Crashlytics (fail-open): zone errors are non-fatal by default (the
      // app keeps running after most of them), so record without terminating.
      unawaited(
        FirebaseCrashlytics.instance.recordError(error, stack).catchError(
              (Object e) => debugPrint('[CrashlyticsZoneError] $e'),
            ),
      );
    },
  );
}

class MyApp extends StatelessWidget {
  final SnifferBrowserController? browserController;
  final DownloadQueue? downloadQueue;
  final int initialTabIndex;

  const MyApp({
    super.key,
    this.browserController,
    this.downloadQueue,
    this.initialTabIndex = 1,
  });

  @override
  Widget build(BuildContext context) {
    // Listen to theme-mode, OLED-dark, and accent-pack notifiers so a single
    // rebuild keeps Material ThemeData and AuroraPalette in lockstep.
    return ListenableBuilder(
      listenable: Listenable.merge([
        appThemeModeNotifier,
        appOledDarkNotifier,
        appAccentPackNotifier,
        appLocaleNotifier,
      ]),
      builder: (context, _) {
        final mode = appThemeModeNotifier.value;
        final isOled = appOledDarkNotifier.value;
        final locale = appLocaleNotifier.value;
        // Accent packs must paint both Material ThemeData (sliders, nav,
        // progress) and the AuroraPalette InheritedWidget.  Build both
        // palettes once so light/dark ThemeData stay consistent with
        // context.ac after a pack change.
        final lightColors = _colorsForBrightness(isLight: true);
        final darkColors = _colorsForBrightness(isLight: false);
        return MaterialApp(
          title: 'Aurora Downloader',
          debugShowCheckedModeBanner: false,
          navigatorKey: FeatureModuleLoader.navigatorKey,
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          themeMode: mode,
          theme: buildLightTheme(colors: lightColors),
          // OLED black: only when the user explicitly selected
          // "Dark (OLED black)" (forced). System-default and light mode
          // use the standard near-black slate background.
          darkTheme: buildDarkTheme(isOled: isOled, colors: darkColors),
          // Resolve brightness from the Theme MaterialApp just applied.
          // ThemeMode.system must follow the platform — never hardcode
          // dark for the palette while Material goes light (or vice
          // versa). That dual-source mismatch inverted text/surfaces.
          builder: (ctx, child) {
            final isLight = Theme.of(ctx).brightness == Brightness.light;
            return AuroraTheme(
              isLight: isLight,
              paletteOverride: isLight ? lightColors : darkColors,
              child: child ?? const SizedBox.shrink(),
            );
          },
          home: AuroraHome(
            browserController: browserController,
            downloadQueue: downloadQueue,
            initialTabIndex: initialTabIndex,
          ),
        );
      },
    );
  }

  /// Base light/dark [AColors] with the active accent pack fully applied
  /// (accents, media chips, tab groups, subtle surface tint).
  static AColors _colorsForBrightness({required bool isLight}) {
    return colorsForAccentPack(activeAccentPack(), isLight: isLight);
  }
}

class AuroraHome extends StatefulWidget {
  final SnifferBrowserController? browserController;
  final DownloadQueue? downloadQueue;
  final int initialTabIndex;

  const AuroraHome({
    super.key,
    this.browserController,
    this.downloadQueue,
    this.initialTabIndex = 1,
  });

  @override
  State<AuroraHome> createState() => _AuroraHomeState();
}

class _AuroraHomeState extends State<AuroraHome> with WidgetsBindingObserver {
  /// Soft/system battery-opt prompt already handled this process lifetime
  /// (user allowed, dismissed, or tapped Later).
  static bool _batteryOptRequested = false;

  /// Guards concurrent soft dialogs if launch + first download race.
  static bool _batteryOptDialogShowing = false;

  final GlobalKey _urlInputKey = GlobalKey();
  final GlobalKey _browserTabKey = GlobalKey();
  final GlobalKey _browserMenuKey = GlobalKey();
  final GlobalKey _browserSnifferKey = GlobalKey();
  final GlobalKey _browserTabsKey = GlobalKey();
  final GlobalKey _queueTabKey = GlobalKey();

  /// True while the spotlight tour is on-screen (prevents stacking).
  bool _onboardingTourVisible = false;

  /// Hard gate for notification / battery prompts.
  ///
  /// Starts **false** so nothing can race ahead of the first-launch tour.
  /// Flipped to true only when:
  /// - the tour is finished or skipped, or
  /// - launch decides the tour is not needed (already completed / disabled).
  bool _permissionPromptsAllowed = false;

  void _showOnboardingSpotlight() {
    if (!mounted || _onboardingTourVisible) return;
    _onboardingTourVisible = true;
    // Hold every soft/system permission dialog until dismiss.
    _permissionPromptsAllowed = false;
    // Steps 1–2 stay on Queue so shell dock keys stay mounted.
    // Steps 3–5 switch to Browser so primary-bar keys (sniffer / tabs / ⋯) exist.
    // No Queue-tab spotlight: that icon only exists on the Queue shell bar.
    final l = AppLocalizations.of(context);
    OnboardingSpotlightOverlay.show(
      context,
      steps: [
        SpotlightStep(
          targetKey: _urlInputKey,
          title: l?.onboardingStep1Title ?? 'Link & URL Input',
          description:
              l?.onboardingStep1Desc ??
              'Paste media URLs or stream links here to start a download without opening the browser.',
          icon: Icons.link_rounded,
          onStepEntered: () => _selectTab(0),
        ),
        SpotlightStep(
          targetKey: _browserTabKey,
          title: l?.onboardingStep2Title ?? 'Media Sniffer Browser',
          description:
              l?.onboardingStep2Desc ??
              'Open the built-in browser to browse sites and auto-detect streams, HLS playlists, and audio.',
          icon: Icons.language_rounded,
          onStepEntered: () => _selectTab(0),
        ),
        SpotlightStep(
          targetKey: _browserSnifferKey,
          title: l?.onboardingStep3Title ?? 'Sniffed Media (Radar)',
          description:
              l?.onboardingStep3Desc ??
              'When the radar lights up, tap it to review detected media and add items to the queue.',
          icon: Icons.radar,
          onStepEntered: () => _selectTab(1),
        ),
        SpotlightStep(
          targetKey: _browserTabsKey,
          title: l?.onboardingStep4Title ?? 'Browser Tabs',
          description:
              l?.onboardingStep4Desc ??
              'Manage multiple pages at once — open, switch, or close tabs from this control.',
          icon: Icons.tab_rounded,
          onStepEntered: () => _selectTab(1),
        ),
        SpotlightStep(
          targetKey: _browserMenuKey,
          title: l?.onboardingStep5Title ?? 'Menu Popup (⋯)',
          description:
              l?.onboardingStep5Desc ??
              'Opens Settings and Tools. Important destinations: User Guide, Adblock, Download Rules, Private Vault, and WebDAV Backup.',
          icon: Icons.more_vert_rounded,
          onStepEntered: () => _selectTab(1),
        ),
      ],
      onDismissed: () {
        _onboardingTourVisible = false;
        // Unlock + request only after finish / skip.
        _permissionPromptsAllowed = true;
        unawaited(_requestPostOnboardingPermissions());
        unawaited(
          EngagementPromptService.instance.recordAppOpen(
            context,
            proEntitlement: _proEntitlement,
          ),
        );
        unawaited(
          AppUpdateService.instance.checkAndPromptAutoUpdate(
            context,
            currentBuildCode: 87,
          ),
        );
      },
    );
  }

  /// Displays the first-launch language selector dialog before the onboarding tour.
  /// Pre-selects the user's detected system language by default.
  Future<void> _showFirstLaunchLanguageSheetIfNeeded() async {
    if (!mounted) return;
    String selectedCode = _settings.appLanguageCode;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final ac = context.ac;
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            final l = AppLocalizations.of(dialogCtx);
            return AlertDialog(
              backgroundColor: ac.surfaceCard,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: ac.glassBorder),
              ),
              title: Row(
                children: [
                  Icon(Icons.language_rounded, color: ac.accentFrost, size: 24),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      l?.onboardingWelcomeTitle ?? 'App Language',
                      style: TextStyle(
                        color: ac.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l?.onboardingWelcomeDesc ??
                            'Select your display language for Aurora Downloader interface:',
                        style: TextStyle(
                          color: ac.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 16),
                      ...kAppSupportedLanguages.map((lang) {
                        final isSelected = selectedCode == lang.code;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Material(
                            color: isSelected
                                ? ac.accentFrost.withValues(alpha: 0.15)
                                : ac.surfaceElevated,
                            borderRadius: BorderRadius.circular(8),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                              side: BorderSide(
                                color: isSelected
                                    ? ac.accentFrost
                                    : ac.borderHairline,
                              ),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: () {
                                setDialogState(() => selectedCode = lang.code);
                                _updateSettings(
                                  _settings.copyWith(appLanguageCode: lang.code),
                                );
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      isSelected
                                          ? Icons.radio_button_checked
                                          : Icons.radio_button_off,
                                      color: isSelected
                                          ? ac.accentFrost
                                          : ac.textTertiary,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        lang.name,
                                        style: TextStyle(
                                          color: isSelected
                                              ? ac.textPrimary
                                              : ac.textSecondary,
                                          fontWeight: isSelected
                                              ? FontWeight.bold
                                              : FontWeight.normal,
                                          fontSize: 14,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ),
              actions: [
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: ac.accentFrost,
                    foregroundColor:
                        Theme.of(dialogCtx).brightness == Brightness.dark
                            ? Colors.black
                            : Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: () => Navigator.of(dialogCtx).pop(),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Text(
                      l?.onboardingContinue ?? 'Continue',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// Whether soft/system permission dialogs may show right now.
  bool get _canPromptPermissions =>
      _permissionPromptsAllowed && !_onboardingTourVisible;

  /// Notification then battery — only after the tour is done (or not needed).
  Future<void> _requestPostOnboardingPermissions() async {
    if (!mounted || !_canPromptPermissions) return;
    // Sequential so system sheets do not stack on top of each other.
    await _requestNotificationPermissionIfNeeded();
    if (!mounted || !_canPromptPermissions) return;
    await Future.delayed(const Duration(milliseconds: 350));
    if (!mounted || !_canPromptPermissions) return;
    await _promptBatteryOptIfNeeded();
  }

  late final DownloadQueue _downloadQueue;
  late final SnifferBrowserController _browserController;
  late final TextEditingController _urlController;
  late final TextEditingController _adblockSourceController;
  late final TextEditingController _customSearchController;
  late final TextEditingController _folderController;
  late final DriveSyncService _driveSyncService = DriveSyncService(
    getTierCallback: () => _proEntitlement.tier,
  );
  StreamSubscription<DriveSyncState>? _driveSubscription;
  late final ValueNotifier<int> _libraryUpdateNotifier;
  final DownloadSettingsStore _settingsStore = const DownloadSettingsStore();
  final ProEntitlement _proEntitlement = ProEntitlement();

  /// Last clipboard text we prompted for (clipboardCatch dedup).
  String? _lastCheckedClipboard;
  late final LicenseService _licenseService = LicenseService(
    entitlement: _proEntitlement,
  );
  late final PlayBillingService _playBilling = PlayBillingService(
    _proEntitlement,
    licenseService: _licenseService,
  );
  final PublicDownloadsService _publicDownloadsService =
      PublicDownloadsService();
  final VaultService _vaultService = VaultService();
  final DownloadNotificationService _notificationService =
      DownloadNotificationService();
  late final AutoBackupService _autoBackupService = AutoBackupService(
    isProCallback: () => _proEntitlement.isPro,
  );
  late final WatcherService _watcherService = WatcherService(
    onEnqueue: (url, {label}) async {
      _urlController.text = url;
      await _addDownloadFromUrl();
    },
    onNewItems: (message) {
      unawaited(
        _notificationService.showWatcherNotification('Aurora Watcher', message),
      );
    },
  );
  late final AutomationApiService _automationApiService = AutomationApiService(
    proEntitlement: _proEntitlement,
    onQueueChanged: () {
      if (mounted) setState(() {});
    },
    downloadQueue: _downloadQueue,
    completedDirProvider: () =>
        _completedWorkspaceDirectory().then((d) => d.path),
    tempDirProvider: () => _tempWorkspaceDirectory().then((d) => d.path),
  );
  StreamSubscription<DownloadTask>? _queueSubscription;
  StreamSubscription<String>? _resniffSuggestedSubscription;
  final Set<String> _resniffPromptedTaskIds = <String>{};
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
  Timer? _resniffModeTimer;
  final Map<String, DownloadState> _prevTaskStates = {};
  bool _isDisposed = false;

  /// Queue → Browser external URL opens (View source / Scan / intents).
  final BrowserOpenRequestBus _browserOpenRequestBus = BrowserOpenRequestBus();

  void _logError(String context, Object error, [StackTrace? stack]) {
    debugPrint('[AuroraHome] $context: $error');
  }

  @override
  void initState() {
    super.initState();
    // Prewarm the worker-isolate pool so the first queue/log restore that
    // needs an isolate doesn't stall on 3 sequential Isolate.spawns.
    unawaited(WorkerIsolatePool.instance.ensureInitialized());
    _currentTabIndex = widget.initialTabIndex.clamp(0, 1);
    _visitedMainTabs.add(_currentTabIndex);
    _downloadQueue =
        widget.downloadQueue ??
        DownloadQueue(
          useNativeTorrentEngine: true,
          completedDownloadPublisher: _publicDownloadsService,
        );
    _browserController = widget.browserController ?? _createBrowserController();
    _urlController = TextEditingController();
    _libraryUpdateNotifier = ValueNotifier<int>(0);
    _adblockSourceController = TextEditingController();
    _customSearchController = TextEditingController(
      text: _settings.searchEngine.id == 'custom'
          ? _settings.searchEngine.templateUrl
          : '',
    );
    _folderController = TextEditingController(text: 'Aurora Downloader');
    if (kDriveSyncEnabled) {
      try {
        _folderController.text = _driveSyncService.state.destinationFolderName;
      } catch (e, s) {
        _logError('DriveSync init', e, s);
      }
      try {
        _driveSyncService.attachQueue(_downloadQueue);
      } catch (e, s) {
        _logError('DriveSync attachQueue', e, s);
      }
      _driveSubscription = _driveSyncService.onStateChanged.listen((state) {
        if (mounted) {
          setState(() {
            _folderController.text = state.destinationFolderName;
          });
        }
      });
    }
    _sniffedCountNotifier = ValueNotifier<int>(0);
    _startAdblockAutoRefresh();
    _proEntitlement.addListener(_onProEntitlementChanged);
    _loadSettingsFuture = _loadSettings();
    unawaited(_initNotifications());
    proUpsellBilling = _playBilling;
    proUpsellEntitlement = _proEntitlement;
    unawaited(_startEntitlementServices());
    _downloadQueue.onRestrictedMediaBlocked = (message) {
      if (mounted) _showSnack(message);
    };
    _queueSubscription = _downloadQueue.onTaskUpdated.listen((task) {
      // QueuePage subscribes to the same stream and throttles its own
      // rebuilds (500 ms); the dock badge is ValueNotifier-driven. The
      // shell therefore does NOT need to rebuild on progress ticks — a
      // per-tick setState here would double every queue-page rebuild
      // (2026-08-07 optimization research, P2).
      // Log download state transitions.
      final fileName = task.savePath.split('/').last;
      final prevState = _prevTaskStates[task.id];
      if (prevState != task.state) {
        _prevTaskStates[task.id] = task.state;
        if (!_isDisposed) {
          debugPrint(
            'Task "$fileName": ${prevState?.name ?? "new"} → ${task.state.name}',
          );
        }
        // Keep state in cache so subsequent emissions for the same state
        // (e.g. error updates, auto-retry ticks) do not re-trigger analytics.
        // Cap map size defensively to avoid unbounded growth over long sessions.
        if (_prevTaskStates.length > 500) {
          final activeKeys = _downloadQueue.allTasks.map((t) => t.id).toSet();
          _prevTaskStates.removeWhere((k, _) => !activeKeys.contains(k));
          if (_prevTaskStates.length > 500) {
            final keysToRemove = _prevTaskStates.keys.take(100).toList();
            for (final k in keysToRemove) {
              _prevTaskStates.remove(k);
            }
          }
        }
        // Firebase Analytics funnel: download start / completion / failure.
        // Fire-and-forget; analytics failures must never affect the queue.
        unawaited(_logDownloadAnalytics(task));
      }
      // Soft battery-opt prompt on first download if launch path has not
      // already handled it this session (Later / never / already exempt).
      // Hard-gated until the first-launch tour finishes or is skipped.
      if (task.state == DownloadState.downloading) {
        unawaited(_promptBatteryOptIfNeeded());
      }
    });
    _resniffSuggestedSubscription =
        _downloadQueue.onResniffSuggested.listen((taskId) {
      final task = _downloadQueue.getTask(taskId);
      if (task == null || !mounted) return;
      if (_resniffPromptedTaskIds.contains(taskId)) return;
      _resniffPromptedTaskIds.add(taskId);
      Future.delayed(const Duration(milliseconds: 300), () {
        _resniffPromptedTaskIds.remove(taskId);
      });
      unawaited(_showResniffSuggestedDialog(task));
    });
    _initIntentChannel();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_watcherService.initialize());
    // Automation API is default OFF (SECURITY_AUDIT §5.1): only auto-start
    // after the user explicitly enabled it (persisted preference), and only
    // for Ultra. The in-app toggle also persists this flag.
    unawaited(_startAutomationApiIfEnabled());
    // First install: tour first. Permissions stay locked (_permissionPromptsAllowed
    // = false) until finish/skip. Returning users unlock immediately.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      try {
        if (Platform.environment.containsKey('FLUTTER_TEST')) return;
      } catch (_) {}
      final showTour = await OnboardingExperiment.shouldAutoShowTour();
      debugPrint('[OnboardingCheck] shouldAutoShowTour=$showTour');
      if (showTour) {
        // Keep _permissionPromptsAllowed false for the whole tour.
        await _showFirstLaunchLanguageSheetIfNeeded();
        if (!mounted) return;
        _showOnboardingSpotlight();
        return;
      }
      _permissionPromptsAllowed = true;
      unawaited(_requestPostOnboardingPermissions());
      unawaited(
        EngagementPromptService.instance.recordAppOpen(
          context,
          proEntitlement: _proEntitlement,
        ),
      );
      unawaited(
        AppUpdateService.instance.checkAndPromptAutoUpdate(
          context,
          currentBuildCode: 87,
        ),
      );
    });
  }

  Future<void> _initNotifications() async {
    try {
      // Action buttons on progress / paused / done / failed notifications.
      _notificationService.onPause = (taskId) {
        unawaited(_downloadQueue.pauseTaskAsync(taskId));
      };
      _notificationService.onResume = (taskId) {
        unawaited(_downloadQueue.resumeTaskAsync(taskId));
      };
      _notificationService.onCancel = (taskId) {
        unawaited(_downloadQueue.cancelTaskAsync(taskId));
      };
      _notificationService.onRetry = (taskId) {
        unawaited(
          _downloadQueue.retryHlsTaskWithRefreshAsync(
            taskId,
            forceReload: true,
          ),
        );
      };
      _notificationService.onOpen = (taskId) {
        final task = _downloadQueue.getTask(taskId);
        if (task != null) unawaited(_openDownload(task));
      };
      _notificationService.onNotificationTap = (taskId) {
        if (!mounted) return;
        _selectTab(0);
      };
      _notificationService.isProCallback = () => _proEntitlement.isPro;
      _notificationService.onExtractAudio = (taskId) {
        final task = _downloadQueue.getTask(taskId);
        if (task == null) return;
        final tier = proUpsellEntitlement?.tier ?? EntitlementTier.free;
        unawaited(AudioExtractPlatform.extract(task: task, tier: tier));
      };

      await _notificationService.initialize();
      _notificationService.listenTo(
        _downloadQueue.onTaskUpdated,
        taskRemovedStream: _downloadQueue.onTaskRemoved,
      );
    } catch (e, s) {
      _logError('Failed to init notifications', e, s);
    }
    // POST_NOTIFICATIONS is requested only after the first-launch tour is
    // finished/skipped (or when the tour was already completed) — see
    // [_requestPostOnboardingPermissions]. Init here must not prompt.
  }

  SnifferBrowserController _createBrowserController() {
    return SnifferWebViewControllerImpl();
  }

  /// Requests [POST_NOTIFICATIONS] once per install unless already granted.
  /// After the first system prompt we persist [notificationPermissionAsked]
  /// so a deny is not re-prompted on every cold start (OS permanent-deny is
  /// still respected if the user later enables notifications in Settings).
  ///
  /// Blocked until [_permissionPromptsAllowed] (tour finished/skipped or
  /// not required this session).
  Future<void> _requestNotificationPermissionIfNeeded() async {
    try {
      if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    } catch (_) {}
    if (!_canPromptPermissions) return;
    if (_loadSettingsFuture != null) {
      await _loadSettingsFuture;
    }
    if (!_canPromptPermissions) return;
    if (await DownloadForegroundService.areNotificationsEnabled()) {
      return;
    }
    if (_settings.notificationPermissionAsked) {
      return;
    }
    await DownloadForegroundService.requestNotificationPermission();
    if (!mounted) return;
    _updateSettings(_settings.copyWith(notificationPermissionAsked: true));
  }

  /// Soft battery-opt prompt used by launch and first-download paths.
  ///
  /// - Hard-gated by [_permissionPromptsAllowed] until the app tour ends.
  /// - Skips when already exempt, user chose never-ask, or this process
  ///   already handled the prompt (including **Later** session suppress).
  /// - Always shows the soft dialog first; only "Open settings" opens the
  ///   system exemption intent + optional OEM guidance.
  Future<void> _promptBatteryOptIfNeeded({
    Duration delay = Duration.zero,
  }) async {
    // Play channel: never prompt unsolicited. Google treats proactive
    // REQUEST_IGNORE_BATTERY_OPTIMIZATIONS prompts as a policy-friction signal,
    // and downloads already survive via the dataSync foreground service — the
    // exemption is a reliability nicety, not a requirement. Play users reach it
    // on demand through the Battery optimisation tile in Settings instead.
    if (BuildChannel.isPlay) return;
    try {
      if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    } catch (_) {}
    // Never interrupt the spotlight tour (or pre-tour launch window).
    if (!_canPromptPermissions) return;
    if (_loadSettingsFuture != null) {
      await _loadSettingsFuture;
    }
    if (!_canPromptPermissions) return;
    if (_settings.neverAskBatteryOpt) return;
    if (_batteryOptRequested || _batteryOptDialogShowing) return;

    // Claim the dialog slot BEFORE any await: two concurrent triggers
    // (launch + first-download listener) can both pass the guard above and
    // reach the await before either sets the flag, stacking two dialogs.
    _batteryOptDialogShowing = true;
    try {
      if (delay > Duration.zero) {
        await Future.delayed(delay);
        if (!mounted) return;
        // Re-check after delay — tour may have started or re-locked prompts.
        if (!_canPromptPermissions) return;
        if (_settings.neverAskBatteryOpt) return;
        if (_batteryOptRequested || _batteryOptDialogShowing) return;
      }

      if (await DownloadForegroundService.isIgnoringBatteryOptimizations()) {
        _batteryOptRequested = true;
        return;
      }

      if (!_canPromptPermissions) return;

      final choice = await _showBatteryOptRequestDialog();
      if (!mounted) return;

      if (choice == BatteryOptChoice.neverAskAgain) {
        _batteryOptRequested = true;
        _updateSettings(_settings.copyWith(neverAskBatteryOpt: true));
      } else if (choice == BatteryOptChoice.openSettings) {
        await _openBatteryOptSystemDialog();
      } else {
        // Later, or dialog dismissed — suppress for this process only.
        // Next cold start may ask again (by design).
        _batteryOptRequested = true;
      }
    } finally {
      _batteryOptDialogShowing = false;
    }
  }

  /// Opens the AOSP battery-opt exemption intent (and OEM guidance when
  /// relevant). Marks the process as handled so we do not re-prompt.
  Future<void> _openBatteryOptSystemDialog() async {
    if (_settings.neverAskBatteryOpt) return;

    if (await DownloadForegroundService.isIgnoringBatteryOptimizations()) {
      _batteryOptRequested = true;
      return;
    }

    _batteryOptRequested = true;

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
            onPressed: () =>
                Navigator.of(ctx).pop(BatteryOptChoice.neverAskAgain),
            child: const Text('Never ask again'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(BatteryOptChoice.later),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(ctx).pop(BatteryOptChoice.openSettings),
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
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

  /// Switches the active main tab (Queue=0, Browser=1).
  /// Settings sub-pages are full-screen routes, not a third tab.
  ///
  /// Browser pause/resume is driven by [SnifferScreen.isShellVisible]
  /// (set from `_currentTabIndex == 1`), not by the shell
  /// [_browserController] — that instance has no attached platform WebView.
  void _selectTab(int index) {
    final clamped = index.clamp(0, 1);
    if (clamped == _currentTabIndex) {
      // Still mark visited so lazy tab children stay mounted if needed.
      if (!_visitedMainTabs.contains(clamped)) {
        setState(() => _visitedMainTabs.add(clamped));
      }
      return;
    }
    final previous = _currentTabIndex;
    setState(() {
      _currentTabIndex = clamped;
      _visitedMainTabs.add(clamped);
    });
    debugPrint('Tab switch: $previous → $clamped');
  }

  /// Opens a Settings sub-page over the shell (usually Browser).
  /// Completes when the route is popped (menu does not auto-reopen).
  Future<void> _openSettingsSection(SettingsSection section) async {
    if (!mounted) return;
    await Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SettingsPage(
          driveSyncService: kDriveSyncEnabled ? _driveSyncService : null,
          folderController: kDriveSyncEnabled ? _folderController : null,
          adblockSourceController: _adblockSourceController,
          customSearchController: _customSearchController,
          settings: _settings,
          onSettingsChanged: _updateSettings,
          downloadQueue: _downloadQueue,
          libraryUpdateNotifier: _libraryUpdateNotifier,
          autoBackupService: _autoBackupService,
          watcherService: _watcherService,
          automationApiService: _automationApiService,
          proEntitlement: _proEntitlement,
          playBilling: _playBilling,
          vaultService: _vaultService,
          onRulesChanged: _reloadRules,
          launchSection: section,
          onOpenUrlInBrowser: _openUrlInBrowser,
          onImportTabs: (urls) => _browserController.openUrlsInNewTabs(urls),
          speedLimitKbps: _speedLimitKbps,
          onSpeedLimitChanged: (value) {
            setState(() => _speedLimitKbps = value);
            _downloadQueue.setSpeedLimit(value.round());
            TorrentDownloader.setNativeDownloadLimit((value * 1024).round());
          },
        ),
      ),
    );
    // Returning from Settings after "Show app tour" (reset completion).
    if (await OnboardingExperiment.shouldAutoShowTour()) {
      if (mounted) {
        await Future.delayed(const Duration(milliseconds: 300));
        _showOnboardingSpotlight();
      }
    }
  }

  /// Cold-start entitlement bring-up, in a fixed order:
  ///
  /// 1. Read the cached owned-products file, so the license service can tell
  ///    whether this install already owned Pro/Ultra before licensing shipped.
  /// 2. Validate the cached license offline — this decides the tier the UI
  ///    shows on first frame, with no network round trip.
  /// 3. Start Play Billing, which reconciles ownership and (on the Play
  ///    channel) trades purchase tokens for a fresh license.
  Future<void> _startEntitlementServices() async {
    _licenseService.onReactivationNeeded = () =>
        _playBilling.reconcileEntitlements(reason: 'license_reactivate');
    try {
      await _proEntitlement.loadCachedEntitlement();
      await _licenseService.load();
      await _playBilling.init();
    } catch (e) {
      // Never block startup on entitlement; gates fail closed to free.
      debugPrint('[AuroraHome] license/billing load failed: $e');
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _adblockRefreshTimer?.cancel();
    _resniffModeTimer?.cancel();
    _queueSubscription?.cancel();
    _resniffSuggestedSubscription?.cancel();
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
    if (kDriveSyncEnabled) {
      unawaited(_driveSyncService.dispose());
    }
    _autoBackupService.dispose();
    WorkerIsolatePool.instance.dispose();
    _browserOpenRequestBus.dispose();
    _proEntitlement.removeListener(_onProEntitlementChanged);
    unawaited(_playBilling.dispose());
    _licenseService.dispose();
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
      debugPrint(
        'App backgrounded, active downloads: ${_downloadQueue.activeTasks.length}',
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
      // Trigger background auto backup if enabled.
      unawaited(_autoBackupService.performBackgroundBackup());
    } else if (state == AppLifecycleState.resumed) {
      debugPrint('[AuroraHome] App resumed');
      debugPrint('App resumed');
      // Only resume WebViews if the user is on the Browser tab.
      if (_currentTabIndex == 1) {
        unawaited(_browserController.resumeActiveWebView());
      }
      // P9 clipboardCatch: Pro+ auto-prompt on resume if clipboard holds a
      // downloadable URL.
      unawaited(_checkClipboardForUrl());
      // Re-verify entitlement roughly daily. Self-throttling and silent on
      // failure — an unreachable host never downgrades a paying user.
      unawaited(_licenseService.refreshIfDue());
    } else if (state == AppLifecycleState.detached) {
      debugPrint('[AuroraHome] App detached — process likely being killed');
      debugPrint('App detached — process likely being killed');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Always-visible shell nav (Queue · Browser · Settings). Scaffold's
    // bottomNavigationBar insets the body, so Browser chrome sits above it.
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
              if (_visitedMainTabs.contains(0))
                IgnorePointer(
                  ignoring: _currentTabIndex != 0,
                  child: AnimatedOpacity(
                    opacity: _currentTabIndex == 0 ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 150),
                    child: QueuePage(
                      key: const ValueKey('queue_tab'),
                      urlInputKey: _urlInputKey,
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
                          () =>
                              unawaited(_downloadQueue.pauseTaskAsync(task.id)),
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
                      onSendToPc: _sendToPc,
                      onMoveToVault: _moveToVault,
                      onRedownload: _redownloadTask,
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
                      menuKey: _browserMenuKey,
                      snifferKey: _browserSnifferKey,
                      tabsKey: _browserTabsKey,
                      controller: _browserController,
                      downloadQueue: _downloadQueue,
                      settings: _settings,
                      onSettingsChanged: _updateSettings,
                      libraryUpdateNotifier: _libraryUpdateNotifier,
                      openRequestBus: _browserOpenRequestBus,
                      isProCallback: () => _proEntitlement.isPro,
                      ruleEngine: _ruleEngine,
                      // Drive pause/resume when leaving/entering Browser
                      // so platform views do not freeze under opacity 0.
                      isShellVisible: _currentTabIndex == 1,
                      onOpenQueue: () => _selectTab(0),
                      onOpenSettings: () =>
                          _openSettingsSection(SettingsSection.about),
                      onOpenSettingsSection: _openSettingsSection,
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
            ],
          ),
          // Browser: own toolbar. Queue: slim Queue | Browser switcher only.
          bottomNavigationBar: _currentTabIndex == 1
              ? null
              : AuroraDock(
                  currentIndex: _currentTabIndex,
                  onTabSelected: (index) => _selectTab(index),
                  sniffedBadgeCountNotifier: _sniffedCountNotifier,
                  queueKey: _queueTabKey,
                  browserKey: _browserTabKey,
                ),
        ),
      ),
    );
  }

  /// Checks the system clipboard on app resume for a downloadable URL and
  /// offers to add it to the queue (P9 clipboardCatch — Pro+ only).
  Future<void> _checkClipboardForUrl() async {
    // Gate: Pro+ only; free never sees clipboard listener.
    if (!ProFeatures.allows(
      ProFeature.clipboardCatch,
      proUpsellEntitlement?.tier ?? EntitlementTier.free,
    )) {
      return;
    }
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;
      if (text == null || text.isEmpty) return;
      // Avoid re-prompting for unchanged clipboard content.
      if (text == _lastCheckedClipboard) return;
      _lastCheckedClipboard = text;

      // Quick-validate: must be an http(s) URL.
      final uri = Uri.tryParse(text.trim());
      if (uri == null || !uri.hasScheme || !uri.hasAuthority) return;
      if (uri.scheme != 'http' && uri.scheme != 'https') return;

      // Skip blocked/restricted URLs.
      if (RestrictedMediaPolicy.isBlocked(mediaUrl: text)) return;

      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(
        SnackBar(
          content: const Text('Link found in clipboard. Add to queue?'),
          duration: const Duration(seconds: 8),
          action: SnackBarAction(
            label: 'Add',
            onPressed: () {
              _urlController.text = text;
              unawaited(_addDownloadFromUrl());
            },
          ),
        ),
      );
    } catch (_) {
      // Clipboard read may fail on some platforms — silently ignore.
    }
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

    if (RestrictedMediaPolicy.isBlocked(mediaUrl: rawUrl)) {
      _showSnack(RestrictedMediaPolicy.userMessageRestricted);
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
        // Task-scoped save dir: the engine writes the torrent content into
        // this directory (possibly under a torrent-name subdir). Sharing the
        // completed workspace root as savePath would make the folder
        // publisher mirror EVERY completed download into public storage.
        savePath: FilenameService.uniquePath(
          '${baseDir.path}/${_torrentTaskName(rawUrl)}',
          reservedPaths: _downloadQueue.allTasks.map((t) => t.savePath),
        ),
        tempDir: '${tempDir.path}/$id',
      );
      if (_downloadQueue.urlExists(rawUrl)) {
        if (!mounted) return;
        final result = await _showDuplicatePrompt(context, 'Torrent');
        if (result.choice == DuplicateChoice.skip) {
          _urlController.clear();
          return;
        }
        if (result.choice == DuplicateChoice.replace) {
          final existing = _downloadQueue.getTaskByUrl(rawUrl);
          if (existing != null) {
            await _downloadQueue.cancelTaskAsync(existing.id);
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
    var fileName = FilenameService.truncate(
      FilenameService.sanitize(resolved.name),
    );

    var targetDir = baseDir.path;
    DownloadRule? matchedRule;
    if (_ruleEngine != null) {
      matchedRule = _ruleEngine!.matchRule(
        rawUrl,
        mediaType: resolved.contentType,
        pageHost: uri.host,
      );
      if (matchedRule?.renameTemplate != null &&
          matchedRule!.renameTemplate!.isNotEmpty) {
        fileName = _ruleEngine!.applyRename(matchedRule, fileName);
      }
      final ruleDest = _ruleEngine!.getDestinationFolder(matchedRule);
      if (ruleDest != null && ruleDest.isNotEmpty) {
        targetDir = p.join(baseDir.path, ruleDest);
      }
    }

    final savePath = FilenameService.uniquePath(
      '$targetDir/$fileName',
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
      final result = await _showDuplicatePrompt(context, fileName);
      if (result.choice == DuplicateChoice.skip) {
        _urlController.clear();
        return;
      }
      if (result.choice == DuplicateChoice.replace) {
        final existing = _downloadQueue.getTaskByUrl(rawUrl);
        if (existing != null) {
          await _downloadQueue.cancelTaskAsync(existing.id);
        }
      }
      force = true;
    }

    if (matchedRule != null &&
        matchedRule.timeWindowStartHour != null &&
        matchedRule.timeWindowEndHour != null) {
      final now = DateTime.now();
      final currentHour = now.hour;
      final startH = matchedRule.timeWindowStartHour!;
      final endH = matchedRule.timeWindowEndHour!;
      final inWindow = startH <= endH
          ? (currentHour >= startH && currentHour < endH)
          : (currentHour >= startH || currentHour < endH);
      if (!inWindow) {
        var schedDate = DateTime(now.year, now.month, now.day, startH);
        if (schedDate.isBefore(now)) {
          schedDate = schedDate.add(const Duration(days: 1));
        }
        _downloadQueue.scheduleTask(task, schedDate);
        _urlController.clear();
        _showSnack('Scheduled $fileName for time window start.');
        if (mounted) setState(() {});
        return;
      }
    }

    _downloadQueue.addTask(task, force: force);
    _urlController.clear();
    _showSnack('Done \u2014 $fileName added to queue.');
    if (mounted) setState(() {});
  }

  void _openUrlInBrowser(String url) {
    debugPrint('_openUrlInBrowser("$url")');
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
      debugPrint(
        'browserOpenRequestBus.request("$trimmed") '
        '(firstVisit=$firstVisitToBrowser, browserMounted='
        '${_visitedMainTabs.contains(1)})',
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
      // P4: use the headless TokenRefreshService instead of opening a visible
      // browser tab. The user never sees the source page load; revival runs in
      // a background WebView. Manual refresh stays free for everyone.
      String? freshUrl = await TokenRefreshService.refresh(task);
      if (freshUrl == null || freshUrl == task.url) {
        if (mounted) {
          _showSnack('Link is still valid. No update needed.');
        }
        return;
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
          setState(() {});
        }
      } else if (choice == 'new') {
        final newId = DateTime.now().microsecondsSinceEpoch.toString();
        final baseDir = await _completedWorkspaceDirectory();
        final tempDir = await _tempWorkspaceDirectory();
        final newSavePath = FilenameService.uniquePath(
          p.join(baseDir.path, _taskFileName(freshUrl)),
          reservedPaths: _downloadQueue.allTasks.map((t) => t.savePath),
        );
        final newTask = DownloadTask(
          id: newId,
          url: freshUrl,
          headers: task.headers,
          savePath: newSavePath,
          tempDir: '${tempDir.path}/$newId',
          contentType: task.contentType,
          sourcePageUrl: task.sourcePageUrl,
        );
        newTask.copyBrowserBridgesFrom(task);
        _downloadQueue.addTask(newTask, force: true);
        if (mounted) {
          _showSnack('Done \u2014 new download created with refreshed link.');
          setState(() {});
        }
      }
    } catch (e, s) {
      _logError('Auto-resniff failed', e, s);
      if (mounted) _showSnack('Link refresh failed. $e');
    }
  }

  /// Shown when a link exhausts auto-retries (attempts >= retryLimit).
  /// Offers auto-resniff, manual resniff, and dismiss.
  Future<void> _showResniffSuggestedDialog(DownloadTask task) async {
    if (!mounted) return;
    final name = task.savePath.split('/').last;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Link keeps failing'),
        content: Text(
          '"$name" failed 3 times. The link may have expired. '
          'Refresh it from the source page?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('dismiss'),
            child: const Text('Dismiss'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('manual'),
            child: const Text('Open source page'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop('auto'),
            child: const Text('Refresh automatically'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'auto') {
      await _resniffAuto(task);
    } else if (choice == 'manual') {
      await _resniffManual(task);
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
    debugPrint(
      '_resniffManual: target="$target", sourcePageUrl=${task.sourcePageUrl}',
    );
    _openUrlInBrowserAfterTabReady(target);
    if (mounted) {
      _showSnack('Source page opened. Tap the media to refresh the link.');
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

  /// Starts the Automation API server only when the user previously enabled
  /// it (persisted preference, default off) AND the tier allows it.
  Future<void> _startAutomationApiIfEnabled() async {
    if (!_automationApiService.isAllowed) return;
    final enabled = await _automationApiService.loadEnabledPreference();
    if (!enabled) return;
    try {
      await _automationApiService.start();
    } catch (e) {
      if (kDebugMode) debugPrint('[AutomationApi] Auto-start failed: $e');
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

  Future<void> _reloadRules() async {
    try {
      final rules = await const DownloadRulesStore().load();
      if (mounted) {
        setState(() => _ruleEngine = DownloadRuleEngine(rules));
      }
    } catch (e, s) {
      _logError('Failed to load download rules', e, s);
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

    await _reloadRules();

    try {
      final docs = await getApplicationSupportDirectory();
      final path = docs.path;
      _downloadQueue.queuePath = '$path/download_queue.json';

      await Future.wait([
        if (kDriveSyncEnabled) _driveSyncService.loadSyncedTasks(path),
        _downloadQueue.loadFromFile('$path/download_queue.json'),
      ]);
      // Free disk from abandoned failed-task segment trees older than 3 days.
      unawaited(_downloadQueue.purgeStaleFailedTemps());

      // Store-screenshot staging. No-op unless built with
      // --dart-define=AURORA_SCREENSHOT_MODE=true, and always a no-op in
      // release. Seeded after the real queue loads so a clean install shows
      // fixtures only. See lib/dev/screenshot_fixtures.dart.
      ScreenshotFixtures.apply(
        queue: _downloadQueue,
        entitlement: _proEntitlement,
      );

      if (mounted) setState(() {});
    } catch (e, s) {
      _logError('Failed to load download queue/logs', e, s);
    }
  }

  void _updateSettings(DownloadSettings settings) {
    setState(() => _settings = settings);
    _applySettings(settings);
    unawaited(_settingsStore.save(settings));
    debugPrint('Settings updated');
  }

  /// Logs download lifecycle events to Firebase Analytics and LocalFunnelStore.
  /// Fire-and-forget; analytics must never affect the queue or the app.
  Future<void> _logDownloadAnalytics(DownloadTask task) async {
    final eventName = analyticsEventNameFor(task.state);
    if (eventName == null) return;
    try {
      // Determine protocol / engine type
      final String protocol;
      if (task.url.startsWith('magnet:') ||
          task.url.toLowerCase().endsWith('.torrent') ||
          task.contentType == 'application/x-bittorrent') {
        protocol = 'torrent';
      } else {
        final ct = task.contentType?.toLowerCase().split(';').first.trim();
        final path = Uri.tryParse(task.url)?.path.toLowerCase() ?? '';
        if (ct == 'application/vnd.apple.mpegurl' ||
            ct == 'application/x-mpegurl' ||
            ct == 'application/dash+xml' ||
            (ct != null && ct.contains('mpegurl')) ||
            path.endsWith('.m3u8') ||
            path.endsWith('.m3u') ||
            path.endsWith('.mpd')) {
          protocol = 'hls';
        } else {
          protocol = 'direct';
        }
      }

      final host = AuroraAnalyticsService.sanitizeHost(task.url);

      if (task.state == DownloadState.downloading) {
        await AuroraAnalyticsService.instance.logDownloadStarted(
          protocol: protocol,
          host: host,
          contentType: task.contentType,
        );
      } else if (task.state == DownloadState.completed) {
        await AuroraAnalyticsService.instance.logDownloadCompleted(
          protocol: protocol,
          totalBytes: task.totalBytes,
        );
      } else if (task.state == DownloadState.failed) {
        await AuroraAnalyticsService.instance.logDownloadFailed(
          protocol: protocol,
          failureReason: task.failureReason?.name ?? 'unknown',
          errorSnippet: task.errorMessage,
        );
      }
    } catch (e) {
      debugPrint('[AnalyticsEventError] $e');
    }
  }

  void _onProEntitlementChanged() {
    // Re-apply current settings so caps (concurrent, chunks, proxy, etc.)
    // reflect the new Pro status immediately.
    if (mounted) _applySettings(_settings);
  }

  void _applySettings(DownloadSettings settings) {
    final tier = _proEntitlement.tier;

    // Keep public publish root in sync with Settings → Download Defaults.
    final dest = DownloadSettings.normalizeDownloadDestination(
      settings.downloadDestination,
    );
    _publicDownloadsService.rootRelativePath =
        DownloadSettings.mediaStoreRelativeFromDisplay(dest);

    unawaited(_autoBackupService.configure(settings));
    _downloadQueue.wifiOnly = settings.wifiOnly;
    // Dual clamp order: userSetting → tierMax → engineHardMax.
    final tierClampedConcurrent = settings.maxConcurrentDownloads.clamp(
      1,
      ProFeatures.maxConcurrentFor(tier),
    );
    final tierClampedChunks = settings.chunksPerTask.clamp(
      1,
      ProFeatures.chunksFor(tier),
    );
    // The user's explicit settings are authoritative. Turbo previously
    // overrode them to the tier max for Pro+ (a user-set 4 silently became
    // 64 concurrent downloads, starving every task to 0 KB/s). Removed
    // 2026-08-11; if tier-max throughput is wanted again it must be an
    // explicit opt-in toggle, not a silent override.
    final effectiveConcurrent = tierClampedConcurrent.clamp(
      1,
      DownloadQueue.engineHardMaxConcurrent,
    );
    final effectiveChunks = tierClampedChunks.clamp(
      1,
      DownloadQueue.engineHardMaxChunks,
    );
    _downloadQueue.configure(
      maxConcurrentDownloads: effectiveConcurrent,
      numChunksPerTask: effectiveChunks,
      hlsSegmentCap: ProFeatures.hlsSegmentCapFor(tier),
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
    if (tier.isAtLeastPro) {
      _downloadQueue.applyProxySettings(
        settings.proxyType,
        settings.proxyHost,
        settings.proxyPort,
        settings.proxyUsername,
        settings.proxyPassword,
      );
    } else {
      _downloadQueue.applyProxySettings(ProxyType.none, '', 0, '', '');
    }
    // Update the app theme mode and OLED-dark flag based on the user's
    // preference.  "Dark (OLED black)" → forced → OLED pure black.
    appThemeModeNotifier.value = _themeModeFromPreference(
      settings.darkModePreference,
    );
    appOledDarkNotifier.value =
        settings.darkModePreference == DarkModePreference.forced;
    appLocaleNotifier.value = _localeFromLanguageCode(settings.appLanguageCode);
  }

  static Locale? _localeFromLanguageCode(String code) {
    if (code == 'system' || code.isEmpty) return null;
    return Locale(code);
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

  /// Source for share/export after completion.
  ///
  /// On success the queue **deletes** the private `.../data/com.../completed/`
  /// copy and keeps only [DownloadTask.publicUri] (MediaStore content URI).
  /// Callers must never require the private path when [publicUri] is set.
  Future<String?> _resolvedCompletedSource(DownloadTask task) async {
    final publicUri = task.publicUri?.trim();
    if (publicUri != null && publicUri.isNotEmpty) {
      return publicUri;
    }

    final path = task.savePath;
    if (await File(path).exists()) {
      return path;
    }

    // Private copy already gone and no URI — cannot recover without re-download.
    return null;
  }

  /// Enqueue a fresh download of the same URL (new task id / temp / save path).
  /// Differs from Retry (which resumes partial work on the same task).
  Future<void> _redownloadTask(DownloadTask task) async {
    try {
      if (task.url.startsWith('magnet:') || task.url.startsWith('blob:')) {
        if (mounted) {
          _showSnack('Can\u2019t redownload this type of link from the queue.');
        }
        return;
      }
      final baseDir = await _completedWorkspaceDirectory();
      final tempDir = await _tempWorkspaceDirectory();
      final newId = DateTime.now().microsecondsSinceEpoch.toString();
      final baseName = p.basename(task.savePath);
      final savePath = FilenameService.uniquePath(
        p.join(baseDir.path, baseName.isEmpty ? 'download' : baseName),
        reservedPaths: _downloadQueue.allTasks.map((t) => t.savePath),
      );
      final newTask = DownloadTask(
        id: newId,
        url: task.url,
        headers: task.headers != null
            ? Map<String, String>.from(task.headers!)
            : null,
        savePath: savePath,
        tempDir: p.join(tempDir.path, newId),
        contentType: task.contentType,
        sourcePageUrl: task.sourcePageUrl,
        expectedHash: task.expectedHash,
      );
      newTask.copyBrowserBridgesFrom(task);
      // Redownload of a failed entry replaces it — otherwise the queue shows
      // two rows for the same URL (old `failed` + new `downloading`).
      if (task.state == DownloadState.failed) {
        await _downloadQueue.cancelTaskAsync(task.id);
      }
      _downloadQueue.addTask(newTask, force: true);
      if (mounted) {
        _showSnack('Redownload started.');
        setState(() {});
      }
    } catch (error) {
      _showSnack('Couldn\u2019t redownload. $error');
    }
  }

  Future<void> _shareDownload(DownloadTask task) async {
    try {
      final mime = PublicDownloadsService.mimeTypeForName(task.savePath);
      final title = p.basename(task.savePath);
      final source = await _resolvedCompletedSource(task);

      if (source == null) {
        if (!mounted) return;
        _showSnack(
          'Couldn\u2019t share — the file is not available. '
          'It may still be publishing to Downloads, or was removed.',
        );
        return;
      }

      if (source.startsWith('content:')) {
        await PublicDownloadsService.shareContentUri(
          source,
          mimeType: mime,
          title: title,
        );
        return;
      }

      // Still on private disk (not published yet) — share via native path.
      await PublicDownloadsService.shareFile(source, mimeType: mime);
    } catch (error) {
      _showSnack('Couldn’t share the file. $error');
    }
  }

  /// Materializes a completed task to a real filesystem path if its private
  /// copy was deleted after publishing to MediaStore.
  Future<String?> _materializeSourceForTask(DownloadTask task) async {
    final path = task.savePath;
    if (await File(path).exists()) return path;

    final uri = task.publicUri?.trim();
    if (uri != null && uri.isNotEmpty) {
      try {
        final docs = await getApplicationDocumentsDirectory();
        final dir = Directory(p.join(docs.path, 'temp_sources'));
        if (!dir.existsSync()) await dir.create(recursive: true);
        var baseName = p.basename(task.savePath);
        if (baseName.isEmpty || baseName == '.') baseName = 'download';
        final dest = p.join(dir.path, baseName);
        final copied = await const MethodChannel(
          'aurora_downloader/public_downloads',
        ).invokeMethod<String>('copyContentUriToFile', {
          'uri': uri,
          'destPath': dest,
        });
        if (copied != null && copied.isNotEmpty && File(copied).existsSync()) {
          return copied;
        }
      } catch (e) {
        debugPrint('[Main] Failed to materialize source: $e');
      }
    }
    return null;
  }

  /// P6 — Send the completed download to a PC over the local network.
  Future<void> _sendToPc(DownloadTask task) async {
    try {
      final source = await _materializeSourceForTask(task);
      if (source == null) {
        if (!mounted) return;
        _showSnack('Couldn’t send — the file isn’t available locally.');
        return;
      }
      final tier = _proEntitlement.tier;
      final ctx = context;
      if (!mounted) return;
      await SendToPcSheet.show(ctx, filePaths: [source], tier: tier);
    } catch (error) {
      if (!mounted) return;
      _showSnack('Couldn’t start Send to PC. $error');
    }
  }

  bool _isTorrentFileUrl(Uri uri) {
    return uri.path.toLowerCase().endsWith('.torrent');
  }

  /// Derives a filesystem-safe task name for a pasted magnet / .torrent URL
  /// (the media-picker flow uses the sniffer item name instead). Falls back
  /// to "torrent" when nothing usable can be extracted.
  String _torrentTaskName(String rawUrl) {
    final uri = Uri.tryParse(rawUrl);
    if (uri != null && uri.scheme == 'magnet') {
      final dn = uri.queryParameters['dn'];
      if (dn != null && dn.trim().isNotEmpty) {
        final clean = FilenameService.sanitize(dn);
        if (clean.isNotEmpty && clean != '.') return clean;
      }
      return 'torrent';
    }
    final path = uri?.path ?? rawUrl;
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.isNotEmpty) {
      final clean = FilenameService.sanitize(segments.last);
      if (clean.isNotEmpty && clean != '.') return clean;
    }
    return 'torrent';
  }

  void _showSnack(String message) {
    if (!mounted) return;
    AuroraSnackbar.show(context, message);
  }

  Future<void> _moveToVault(DownloadTask task) async {
    final tier = proUpsellEntitlement?.tier ?? EntitlementTier.free;
    if (!ProFeatures.allows(ProFeature.privateVault, tier)) {
      showProUpsell(context, ProFeature.privateVault);
      return;
    }
    if (!await _vaultService.canAccept(tier)) {
      _showSnack(
        'Vault is full (max ${Phase2Caps.maxFreeVaultItems} for free). '
        'Delete items or upgrade to Pro+.',
      );
      return;
    }
    // Deleting the source file out from under an unfinished download would
    // corrupt the download (e.g. a seeding torrent or a paused/partial file).
    if (task.state != DownloadState.completed) {
      _showSnack('Only completed downloads can be moved to the vault.');
      return;
    }
    final sourcePath = await _materializeSourceForTask(task);
    if (sourcePath == null) {
      _showSnack('File not found: ${task.savePath}');
      return;
    }
    final file = File(sourcePath);
    final vaultName = await _vaultService.store(file, tier: tier);
    if (vaultName != null) {
      try {
        await file.delete();
      } catch (_) {
        // Deletion failed but file is encrypted in vault — no plaintext leak
      }
      _showSnack('Moved to vault.');
    } else {
      final fail = _vaultService.lastAuthFailureMessage;
      _showSnack(fail ?? 'Failed to move to vault.');
    }
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

  Future<DuplicateDialogResult> _showDuplicatePrompt(
    BuildContext context,
    String filename,
  ) {
    return showDuplicateDownloadDialog(context: context, filename: filename);
  }
}

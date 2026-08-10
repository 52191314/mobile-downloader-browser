import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'worker_isolate_pool.dart';

import 'package:http/http.dart' as http;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../l10n/app_localizations.dart';
import 'models/site_profile.dart';
import 'package:path_provider/path_provider.dart';

import '../compliance/restricted_media_policy.dart';
import '../downloader/downloader.dart';
import '../downloader/download_rules.dart';
import '../platform/network_binding_service.dart';
import '../premium/free_taste.dart';
import '../premium/pro_entitlement.dart';
import '../premium/pro_features.dart';
import '../premium/premium_flags.dart';
import '../premium/upsell_controller.dart';
import 'video_library.dart';
import '../downloader/headless_webview_fetcher.dart';
import '../ui/notifications/aurora_snackbar.dart';
import '../platform/public_downloads_service.dart';
import '../settings/download_settings.dart';
import 'ad_block_engine_native.dart';
import 'browser_controller.dart';
import 'browser_library.dart';
import 'browser_open_request.dart';
import 'player/playback_engine.dart';
import '../premium/pro_upsell_sheet.dart';
import 'controllers/address_bar_controller.dart';
import 'controllers/element_picker_controller.dart';
import 'controllers/library_controller.dart';
import 'controllers/media_catch_controller.dart';
import 'controllers/site_profile_runtime.dart';
import 'controllers/sniff_intake_controller.dart';
import 'controllers/tab_lifecycle_controller.dart';
import 'controllers/tab_callback_binder.dart';
import 'controllers/tab_manager.dart';
import 'browser_widget.dart';
import 'hls_playlist_cache_lookup.dart';
import 'media_sniffer_engine.dart';
import 'models/address_suggestion.dart';
import 'models/browser_tab.dart';
import 'models/favorite_selection.dart';
import 'models/page_meta.dart';
import 'models/sniffed_media.dart';
import 'reader_mode_widget.dart';
import 'session_recovery.dart';
import 'autofill_store.dart';
import 'safe_browsing_service.dart';
import 'sniffer_url_utils.dart';
import 'sniffer_url_utils.dart' as url_utils;
import 'listing_page_crawler.dart';
import 'native_html_media_extractor.dart';
import 'cct_browser.dart';
import 'sheets/download_prompt_sheet.dart';
import '../theme/aurora_palette.dart';

import 'actions/autofill_action.dart';
import 'actions/context_menu_action.dart';
import 'capture_sort.dart';
import 'enqueue_download.dart';
import 'external_scheme.dart';
import 'sheets/external_app_prompt_sheet.dart';
import 'headless_resniffer.dart';
import 'token_refresh_service.dart';
import 'hls_variant_fetcher.dart';
import 'playback_quality.dart';
import 'sheets/duplicate_download_dialog.dart';
import 'sheets/favorite_dialogs.dart';
import 'sheets/phishing_warning_dialog.dart';
import 'sheets/browser_overflow_popup.dart';
import '../ui/settings_open_request.dart';
import 'sheets/favorites_sheet.dart';
import 'sheets/group_actions_sheet.dart' show showGroupActionsSheet, GroupActionsCallbacks;
import 'sheets/history_sheet.dart';
import 'sheets/media_info_sheet.dart';
import 'sheets/media_preview_sheet.dart';
import 'sheets/saved_pages_sheet.dart';
import 'sheets/sniffed_media_sheet.dart';
import 'sheets/strict_redirect_prompt.dart';
import 'sheets/tabs_sheet.dart';
import 'sniffer_formatters.dart';
import 'widgets/capture_widgets.dart';
import 'widgets/floating_player_overlay.dart';
import 'widgets/find_in_page_bar.dart';
import 'widgets/picker_cancel_chip.dart';
import 'widgets/add_queue_dialog.dart' show showAddQueueDialog;
import 'widgets/address_suggestion_panel.dart';
import 'widgets/tab_strip.dart';

/// Filter options for the rich catch sheet segmented control are defined
/// in `sheets/sniffed_media_sheet.dart` (re-declared so the file is
/// self-contained). The state class uses the same enum via
/// `import 'sheets/sniffed_media_sheet.dart' show MediaFilter;`.

class SnifferScreen extends StatefulWidget {
  final SnifferBrowserController? controller;
  final DownloadQueue? downloadQueue;
  final MediaSnifferEngine? snifferEngine;
  final DownloadSettings settings;
  final ValueChanged<DownloadSettings>? onSettingsChanged;
  final VoidCallback? onOpenQueue;
  final VoidCallback? onOpenSettings;
  /// Deep-open a Settings sub-page (from overflow Settings segment).
  /// Completes when the user leaves that page (back) so the menu can reopen.
  final Future<void> Function(SettingsSection section)? onOpenSettingsSection;
  final ValueChanged<int>? onSniffedCountChanged;
  final BrowserLibraryStore libraryStore;
  final SnifferBrowserController Function()? debugControllerFactory;
  final SafeBrowsingService safeBrowsing;
  final ValueNotifier<int>? libraryUpdateNotifier;

  /// Queue / intent external open requests (preferred over controller callback).
  final BrowserOpenRequestBus? openRequestBus;

  /// Callback for Pro entitlement check — used to gate tab group count
  /// and auto-host features for free users.
  final bool Function()? isProCallback;

  /// Download rule engine used to match filename renames, folder routing, and
  /// time-window constraints on direct downloads.
  final DownloadRuleEngine? ruleEngine;

  /// Whether the main shell is currently showing the Browser tab.
  /// When false (Queue/Settings visible), WebViews are paused so switching
  /// main tabs does not leave a frozen compositor under opacity 0.
  final bool isShellVisible;

  /// GlobalKeys for browser chrome (spotlight coachmark).
  final GlobalKey? menuKey;
  final GlobalKey? snifferKey;
  final GlobalKey? tabsKey;

  SnifferScreen({
    super.key,
    this.controller,
    this.downloadQueue,
    this.snifferEngine,
    DownloadSettings? settings,
    this.onSettingsChanged,
    this.onOpenQueue,
    this.onOpenSettings,
    this.onOpenSettingsSection,
    this.onSniffedCountChanged,
    BrowserLibraryStore? libraryStore,
    this.debugControllerFactory,
    SafeBrowsingService? safeBrowsing,
    this.libraryUpdateNotifier,
    this.openRequestBus,
    this.isProCallback,
    this.ruleEngine,
    this.isShellVisible = true,
    this.menuKey,
    this.snifferKey,
    this.tabsKey,
  }) : settings = settings ?? DownloadSettings.defaults(),
       libraryStore = libraryStore ?? const BrowserLibraryStore(),
       safeBrowsing =
           safeBrowsing ??
           (isRunningInTest()
               ? FakeSafeBrowsingService()
               : SafeBrowsingService());

  static String normalizeMenuEntryKey(String label) {
    if (label.startsWith('Stealth Mode:')) return 'Stealth Mode';
    if (label.startsWith('Incognito:')) return 'Incognito';
    if (label.startsWith('Adblock:')) return 'Adblock';
    if (label == 'Ads allowed') return 'Adblock';
    return label;
  }

  @override
  State<SnifferScreen> createState() => _SnifferScreenState();
}

class _SnifferScreenState extends State<SnifferScreen>
    with WidgetsBindingObserver
    implements TabLifecycleHost, TabCallbackHost {
  late final DownloadQueue _downloadQueue;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  /// Core tab state management.
  late final TabManager _tabManager;

  /// Address bar input and suggestion management.
  late final AddressBarController _addressBarController;

  /// Convenience accessors delegated to [_tabManager].
  List<BrowserTab> get _tabs => _tabManager.tabs;
  int get _activeTabIndex => _tabManager.activeTabIndex;
  BrowserTab get _activeTab => _tabManager.activeTab;
  Set<String> get _fetchedIframeSrcs => _tabManager.fetchedIframeSrcs;

  late final MediaCatchController _mediaCatchController;
  late final ElementPickerController _elementPickerController;
  late final LibraryController _libraryController;

  /// Captured-URL intake pipeline (sniffing, headers, cookies, save
  /// scheduling). Initialized in `initState` after `_tabManager` and
  /// `_downloadQueue` are available.
  late final SniffIntakeController _sniffIntakeController;

  /// Tab lifecycle (load/save/open/close/reopen tabs, video poll).
  /// Initialized in `initState` after [_tabManager] and
  /// [_sniffIntakeController] are available.
  late final TabLifecycleController _tabLifecycleController;

  /// Wires all WebView callbacks (navigation, sniffing, download, play,
  /// JS channels) onto a [BrowserTab].  Replaces the old in-State
  /// `_setupTabCallbacks` body.  Initialized in `initState`.
  late final TabCallbackBinder _tabCallbackBinder;

  bool get _addressExpanded => _addressBarController.addressExpanded;
  set _addressExpanded(bool v) => _addressBarController.addressExpanded = v;

  /// Focus node for the address bar TextField. Used to detect focus loss
  /// (tap-outside-to-collapse) and to programmatically request focus /
  /// select-all when the address bar is expanded from a tap.
  final FocusNode _addressFocusNode = FocusNode(debugLabel: 'AddressBar');

  // --- Library delegates ---
  BrowserLibrary get _library => _libraryController.library;

  /// Write-through setter for [_isSavingPage].
  set _isSavingPage(bool v) {
    _libraryController.isSavingPage = v;
  }

  // --- Media catch delegates ---
  set _captureShowAllMedia(bool v) =>
      _mediaCatchController.captureShowAllMedia = v;

  bool _findVisible = false;
  final TextEditingController _findController = TextEditingController();
  int _findMatchCount = 0;
  int _findCurrentMatch = 0;

  bool _desktopMode = false;
  bool _privateMode = false;
  bool get _elementPickerActive => _elementPickerController.isActive;

  List<AddressSuggestion> get _addressSuggestions =>
      _addressBarController.suggestions;

  final SessionRecovery _sessionRecovery = const SessionRecovery();

  final AutofillStore _autofillStore = const AutofillStore();
  List<AutofillProfile> _autofillProfiles = const [];

  late final SafeBrowsingService _safeBrowsing;

  double _lastScrollY = 0.0;
  int _lastBarsToggleAtMs = 0;
  bool _barsVisible = true;
  bool _isContextMenuShowing = false;
  /// True while the Samsung-style Menu (⋯) general dialog is on the stack.
  /// Used to dismiss it when leaving the Browser shell so it is not sticky.
  bool _browserOverflowOpen = false;
  final ValueNotifier<int> _progressNotifier = ValueNotifier<int>(0);

  /// Debounce timer for navigation callbacks ([onUrlChanged], [onPageStarted],
  /// [onPageFinished]) so rapid back-to-back navigation events (e.g. redirect
  /// chains) trigger only one `setState` instead of three per step.
  Timer? _navSetStateDebounce;

  /// Best sniffed video for the **current active tab only**.
  /// Must never retain a stream from another tab (float was opening the
  /// wrong page's video). Refreshed on tab switch and page navigation.
  SniffedMedia? _latestVideoMedia;

  /// Debounce for auto-open player when site `play()` is intercepted.
  bool _playerOpening = false;
  DateTime? _lastAuroraPlayAt;

  /// Page URL for which the user long-pressed dismiss on the float button.
  String? _floatingPlayerDismissedForUrl;

  /// Largest visible `<video>` rect from [VideoFloatChannel], in CSS pixels
  /// relative to the WebView viewport (top-left origin).
  Rect? _videoFloatRect;

  /// Set of tab IDs whose WebViews have already been built (lazy creation).
  /// Only tabs in this set get a real [BrowserWidget] — others render an empty
  /// placeholder to avoid creating expensive native WebViews at launch.
  /// Set of tab IDs whose WebViews have already been built (lazy creation).
  /// Only tabs in this set get a real [BrowserWidget] — others render an empty
  /// placeholder to avoid creating expensive native WebViews at launch.
  final Set<String> _builtWebViewTabIds = {};

  /// Tracks which tab group headers are expanded in the tabs sheet.
  final Set<String> _expandedGroups = {};

  /// Maximum number of native WebViews to keep alive simultaneously.
  /// Tabs beyond this limit are evicted (their WebView is destroyed) using
  /// LRU order. When the user switches back, the WebView is recreated and
  /// the saved URL is reloaded.
  ///
  /// Increased from 5 to 10 on 2026-07-07 to reduce eviction frequency,
  /// keeping more tabs' back-forward caches alive so back/forward navigation
  /// stays instant (matching Chrome/Firefox mobile behavior).
  static const int _maxLiveWebViews = 4;

  /// LRU activation order — most recently activated tab ID is at the front.
  /// Used to decide which tabs to evict when `_builtWebViewTabIds.length`
  /// exceeds [_maxLiveWebViews].
  final List<String> _tabActivationOrder = [];

  /// Whether `_loadTabsAndMedia` has finished restoring tabs.
  /// When `false`, the lazy Stack shows an empty placeholder for real WebViews
  /// so that the default blank tab (created in `initState`) does not trigger an
  /// expensive native WebView that would be immediately disposed.  Mock
  /// (test) controllers always build immediately regardless of this flag.
  bool _tabsLoaded = false;
  /// External open requests (Queue "View source page", "Scan in browser",
  /// share intents, etc.) that arrived before tab restore finished.
  /// List (not a single slot) so concurrent opens are not dropped.
  final List<String> _pendingOpenUrlsAfterTabsLoaded = [];

  /// Imported-session URLs waiting for tab restore to finish (backup import
  /// live-restore; flushed in [markTabsLoaded] as new tabs, not navigations).
  final List<String> _pendingImportTabUrls = [];

  static const Duration _strictRedirectPromptCooldown = Duration(seconds: 8);
  final Set<String> _activeStrictRedirectPrompts = {};

  /// True while ANY strict-redirect dialog is on screen. The set above
  /// dedups by promptKey; this guards against two DIFFERENT redirects
  /// (e.g. a redirect chain A→B) presenting simultaneously and stacking
  /// dialogs on the root navigator.
  bool _strictRedirectDialogShowing = false;

  /// True while the Cloudflare-block bottom sheet is on screen — guards
  /// against repeated onCloudflareBlockDetected emissions stacking sheets.
  bool _cloudflareBlockSheetShowing = false;
  final Map<String, int> _recentStrictRedirectPrompts = {};
  /// Redirect prompts blocked while the source tab was not visible.
  /// Keyed by [BrowserTab.id]; flushed when that tab becomes active again.
  final Map<String, List<PendingStrictRedirectPrompt>>
      _pendingStrictRedirectByTabId = {};
  /// Tab id currently presenting deferred redirect dialogs (re-entry guard).
  String? _flushingStrictRedirectTabId;

  // Cookie cache is owned by [_sniffIntakeController] (see
  // `SniffIntakeController.cookieCache`). Cleared on each page
  // navigation by calling `_sniffIntakeController.clearCookieCache()`
  // in the WebView's `onPageStarted` callback.

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Websites that try to open apps (tg:, intent://, …) confirm here first.
    externalAppPromptHandler = ({
      required Uri uri,
      required String appKey,
      required String displayName,
      String? pageHost,
    }) async {
      if (!mounted) return ExternalAppPromptResult.denyOnce;
      return showExternalAppPromptSheet(
        context: context,
        displayName: displayName,
        uri: uri,
        pageHost: pageHost,
        onOpenSettings: () {
          final sectionHandler = widget.onOpenSettingsSection;
          if (sectionHandler != null) {
            unawaited(sectionHandler(SettingsSection.externalApps));
          } else {
            widget.onOpenSettings?.call();
          }
        },
      );
    };
    _safeBrowsing = widget.safeBrowsing;
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );
    _downloadQueue = widget.downloadQueue ?? DownloadQueue();
    // Re-attach WebView bridges on every start/retry after process death.
    // Closures cannot be JSON-persisted, so without this, restored HLS tasks
    // lose cookie/fetch/token-refresh and fail with 403 after app restart.
    _downloadQueue.browserContextAttacher = _attachBrowserContextToTask;
    _tabManager = TabManager(
      isProCallback: widget.isProCallback ?? (() => false),
    )
      ..onRebuild = () {
        if (mounted) setState(() {});
      };
    _addressBarController = AddressBarController();
    _mediaCatchController = MediaCatchController();
    final isPro = widget.isProCallback?.call() ?? false;
    _elementPickerController = ElementPickerController(
      activeTabGetter: () => _activeTab,
      onSettingsChanged: widget.onSettingsChanged,
      showSnack: _showSnack,
      maxRules: isPro ? null : ProFeatures.maxFreeCosmeticRules,
    );
    _libraryController = LibraryController(libraryStore: widget.libraryStore)
      ..onLibraryChanged = () {
        if (mounted) setState(() {});
      };
    _sniffIntakeController = SniffIntakeController(
      tabManager: _tabManager,
      settings: widget.settings,
      downloadQueue: _downloadQueue,
      baseDir: _baseDir,
      setState: (fn) {
        if (mounted) setState(fn);
      },
      isMounted: () => mounted,
      onSniffedCountChanged: widget.onSniffedCountChanged == null
          ? null
          : (count) => widget.onSniffedCountChanged!(count ?? 0),
      uaForProfile: uaForProfile,
      downloadUserAgent: downloadUserAgent,
      baseRequestHeaders: _baseRequestHeaders,
      normalizeHeadersForUrl: normalizeHeadersForUrl,
      firstNonEmpty: firstNonEmpty,
    );
    _tabLifecycleController = TabLifecycleController(
      host: this,
      tabManager: _tabManager,
      settings: widget.settings,
      safeBrowsing: _safeBrowsing,
      sessionRecovery: _sessionRecovery,
      injectedController: widget.controller,
      debugControllerFactory: widget.debugControllerFactory,
      injectedSnifferEngine: widget.snifferEngine,
    );
    _tabCallbackBinder = TabCallbackBinder(
      host: this,
      sniffIntakeController: _sniffIntakeController,
    );
    widget.controller?.setOnOpenUrlRequest(_handleExternalOpenUrl);
    widget.controller?.setOnOpenUrlInNewTab(_handleExternalOpenUrl);
    widget.controller?.setOnOpenUrlsInNewTabs(_handleOpenUrlsInNewTabs);
    widget.openRequestBus?.addListener(_onOpenRequestBus);
    // Consume any request published before SnifferScreen mounted.
    _onOpenRequestBus();
    widget.controller?.setOnSystemBackRequested(() async {
      if (!mounted) return false;
      final tab = _activeTab;
      if (tab.controller.historyIndex > 0) {
        await tab.controller.goBack();
        _updateTabNavState(tab);
        return true;
      }
      return false;
    });
    _desktopMode = widget.settings.desktopMode;
    _privateMode = widget.settings.privateMode;
    _mediaCatchController.captureShowAllMedia =
        widget.settings.captureShowAllMedia;
    // Tap-outside-to-collapse: when the address bar loses focus, collapse it.
    _addressFocusNode.addListener(() {
      if (!_addressFocusNode.hasFocus && _addressExpanded) {
        setState(() => _addressExpanded = false);
      }
    });
    _tabLifecycleController.openNewTab();
    unawaited(_initPaths().then((_) => _libraryController.load()));
    unawaited(_loadAutofillProfiles());
    widget.libraryUpdateNotifier?.addListener(_onLibraryUpdate);
  }

  void _onLibraryUpdate() {
    if (mounted) {
      unawaited(_libraryController.load());
    }
  }

  Future<void> _loadAutofillProfiles() async {
    final profiles = await _autofillStore.load();
    if (mounted) {
      setState(() => _autofillProfiles = profiles);
    }
  }

  @override
  void didUpdateWidget(covariant SnifferScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings.captureShowAllMedia !=
        widget.settings.captureShowAllMedia) {
      _captureShowAllMedia = widget.settings.captureShowAllMedia;
    }
    if (oldWidget.settings.adblockEnabled != widget.settings.adblockEnabled ||
        oldWidget.settings.popupBlockingEnabled !=
            widget.settings.popupBlockingEnabled ||
        oldWidget.settings.invisibleRedirectBlockingEnabled !=
            widget.settings.invisibleRedirectBlockingEnabled ||
        oldWidget.settings.adblockFilterSources !=
            widget.settings.adblockFilterSources ||
        oldWidget.settings.manualAdBlockRules !=
            widget.settings.manualAdBlockRules ||
        oldWidget.settings.manualCosmeticRules !=
            widget.settings.manualCosmeticRules) {
      _updateAllTabAdblock();
    }
    if (oldWidget.settings.adblockAllowlist !=
        widget.settings.adblockAllowlist) {
      _updateAllTabAdblockAllowlist();
    }
    if (oldWidget.settings.alwaysBlockedRedirectHosts !=
        widget.settings.alwaysBlockedRedirectHosts) {
      for (final tab in _tabs) {
        tab.controller.setAlwaysBlockedRedirectHosts(
          widget.settings.alwaysBlockedRedirectHosts,
        );
      }
    }
    if (oldWidget.settings.customVideoHosts !=
        widget.settings.customVideoHosts) {
      _updateAllTabCustomVideoHosts();
    }
    if (oldWidget.settings.desktopMode != widget.settings.desktopMode) {
      _desktopMode = widget.settings.desktopMode;
      if (_desktopMode) {
        for (final tab in _tabs) {
          tab.controller.setUserAgent(uaForProfile('desktop_chrome'));
        }
      }
    }
    if (oldWidget.settings.userAgentProfile !=
            widget.settings.userAgentProfile ||
        oldWidget.settings.customUserAgent !=
            widget.settings.customUserAgent) {
      final ua = uaForProfile(widget.settings.userAgentProfile);
      for (final tab in _tabs) {
        tab.controller.setUserAgent(ua);
      }
    }
    if (oldWidget.settings.maxDetectedMedia !=
            widget.settings.maxDetectedMedia ||
        oldWidget.settings.disabledMediaTypes !=
            widget.settings.disabledMediaTypes) {
      for (final tab in _tabs) {
        tab.snifferEngine.maxDetectedMedia = widget.settings.maxDetectedMedia;
        tab.snifferEngine.disabledMediaTypes =
            widget.settings.disabledMediaTypes;
      }
    }
    if (oldWidget.settings.privateMode != widget.settings.privateMode) {
      _privateMode = widget.settings.privateMode;
      for (final tab in _tabs) {
        unawaited(tab.controller.setIncognito(widget.settings.privateMode));
      }
    }
    if (oldWidget.settings.replaceSitePlayer !=
        widget.settings.replaceSitePlayer) {
      for (final tab in _tabs) {
        unawaited(
          tab.controller.setReplaceSitePlayer(
            widget.settings.replaceSitePlayer,
          ),
        );
      }
      // Auto-replace on → hide float; float mode on → clear stale dismiss.
      if (widget.settings.replaceSitePlayer) {
        _videoFloatRect = null;
      } else {
        _floatingPlayerDismissedForUrl = null;
      }
    }
    // Main-shell Queue/Settings vs Browser: pause/resume platform WebViews so
    // leaving Browser cannot leave a frozen compositor under opacity 0.
    if (oldWidget.isShellVisible != widget.isShellVisible) {
      if (widget.isShellVisible) {
        unawaited(_resumeBrowserShell());
        // Prompts deferred while user was on Queue / Settings.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !widget.isShellVisible) return;
          unawaited(_flushPendingStrictRedirectPrompts(_activeTab));
        });
      } else {
        // Leave Browser (Queue / other shell) → drop the Menu popup so it
        // does not float over the next screen or reappear later.
        _dismissBrowserOverflowPopup();
        unawaited(_pauseBrowserShell());
      }
    }
  }

  void _updateAllTabAdblock() {
    for (final tab in _tabs) {
      unawaited(_configureTabAdblock(tab));
    }
  }

  /// Pushes the current per-site allowlist to every tab controller. Called
  /// whenever [widget.settings.adblockAllowlist] changes so that each tab's
  /// in-memory allowlist stays in sync with the global settings.
  void _updateAllTabAdblockAllowlist() {
    final list = widget.settings.adblockAllowlist;
    for (final tab in _tabs) {
      tab.controller.updateAdblockAllowlist(list);
    }
  }

  /// Pushes custom video hosts to every tab controller so the extensionless
  /// URL probe (G1) also checks user-configured domains. Called when
  /// [widget.settings.customVideoHosts] changes.
  void _updateAllTabCustomVideoHosts() {
    final hosts = widget.settings.customVideoHosts;
    for (final tab in _tabs) {
      tab.controller.updateCustomVideoHosts(hosts);
      tab.snifferEngine.setCustomVideoHosts(hosts.toSet());
    }
  }

  Future<void> _configureTabAdblock(BrowserTab tab) async {
    await tab.controller.configureAdBlock(
      enabled: widget.settings.adblockEnabled,
      popupBlockingEnabled: widget.settings.popupBlockingEnabled,
      filterSources: widget.settings.adblockFilterSources,
      manualRules: widget.settings.manualAdBlockRules,
      cosmeticRules: widget.settings.manualCosmeticRules,
    );
    tab.controller.updateAdblockAllowlist(widget.settings.adblockAllowlist);
    tab.controller.updateCustomVideoHosts(widget.settings.customVideoHosts);
    await tab.controller.setInvisibleRedirectBlocking(
      widget.settings.invisibleRedirectBlockingEnabled,
    );
    tab.controller.setAlwaysBlockedRedirectHosts(
      widget.settings.alwaysBlockedRedirectHosts,
    );
    await tab.controller.setReplaceSitePlayer(
      widget.settings.replaceSitePlayer,
    );
    await tab.controller.setCloudflareStealthEnabled(
      widget.settings.cloudflareStealthEnabled,
    );
    tab.controller.setOnCloudflareBlockDetected((host, retrying) {
      if (!mounted) return;
      if (retrying) {
        AuroraSnackbar.show(
          context,
          'Cloudflare block detected on $host — re-applying stealth & retrying...',
        );
      } else {
        _showCloudflareBlockSheet(host, tab.currentUrl);
      }
    });
  }

  void _showCloudflareBlockSheet(String host, String? currentUrl) {
    if (!mounted) return;
    // Re-entry guard: onCloudflareBlockDetected can fire repeatedly (each
    // stealth retry that fails re-emits), which would stack sheets.
    if (_cloudflareBlockSheetShowing) return;
    _cloudflareBlockSheetShowing = true;
    final targetUrl = currentUrl ?? 'https://$host';
    // If the user already chose "always open in CCT" for this host, don't
    // re-show the sheet — the CCT should already be open. Re-prompting here
    // creates the "xchina.co → CCT → sheet → CCT" loop.
    final lowerHost = host.toLowerCase();
    final alreadyExternal = widget.settings.externalBrowserHosts
        .map((e) => e.toLowerCase())
        .contains(lowerHost);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1E1E2C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.shield_outlined, color: Colors.orangeAccent, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Cloudflare Blocked $host',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'This site blocks in-app Android WebViews (same engine class as 1DM). '
                'Full browsers like Chrome or UC Browser bypass this block.',
                style: TextStyle(color: Colors.grey[300], fontSize: 14, height: 1.4),
              ),
              const SizedBox(height: 20),
              // When the host is already marked external-only, only show a
              // "done" row — re-opening CCT again is the loop the user sees.
              if (alreadyExternal) ...[
                Text(
                  'This site is set to always open in Chrome Custom Tab.',
                  style: TextStyle(color: Colors.grey[400], fontSize: 13),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.check_rounded),
                  label: const Text('Close'),
                  onPressed: () => Navigator.pop(context),
                ),
              ] else ...[
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  icon: const Icon(Icons.tab),
                  label: const Text('Open in Chrome Custom Tab'),
                  onPressed: () {
                    Navigator.pop(context);
                    unawaited(CctBrowser.openCustomTab(targetUrl));
                  },
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open in System Browser'),
                  onPressed: () {
                    Navigator.pop(context);
                    unawaited(PublicDownloadsService.openUrlInChrome(targetUrl, preferChrome: false));
                  },
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.orangeAccent,
                  ),
                  icon: const Icon(Icons.star_outline),
                  label: Text('Always open $host in Custom Tab'),
                  onPressed: () {
                    Navigator.pop(context);
                    final updatedHosts = List<String>.from(widget.settings.externalBrowserHosts);
                    final lowerHost = host.toLowerCase();
                    if (!updatedHosts.contains(lowerHost)) {
                      updatedHosts.add(lowerHost);
                      final updated = widget.settings.copyWith(externalBrowserHosts: updatedHosts);
                      widget.onSettingsChanged?.call(updated);
                    }
                    unawaited(CctBrowser.openCustomTab(targetUrl));
                  },
                ),
              ),
            ],
          ],
        ),
      );
      },
    ).whenComplete(() => _cloudflareBlockSheetShowing = false);
  }

  void _cancelPickerIfActive() {
    if (_elementPickerActive) _cancelElementPicker(autoCancelled: true);
  }

  void _switchToActiveTab(int index) {
    if (_tabs.isEmpty) return;
    _fetchedIframeSrcs.clear();
    _cancelPickerIfActive();
    _tabManager.switchToActiveTab(index);
    _addressExpanded = false;
    _barsVisible = true;
    _lastScrollY = 0.0;
    _clearAddressSuggestions();
    // Floating player / auto-replace must use THIS tab's streams only.
    _resyncPlaybackMediaForActiveTab();
    // Wake deferred restore work only after tabs are loaded. During bulk
    // restore switchToActiveTab runs before markTabsLoaded — ensure is
    // scheduled separately with a delay so WebView/downloads do not thrash.
    if (_tabsLoaded) {
      unawaited(_ensureTabStartupReady(_activeTab));
    }
    _startVideoPoll(_activeTab);

    // --- LRU tracking & WebView eviction ---
    final activeId = _activeTab.id;
    _tabActivationOrder.remove(activeId);
    _tabActivationOrder.insert(0, activeId);
    _evictStaleTabs();
    _updateBuiltTabIds();
    _progressNotifier.value = _activeTab.progress;
    setState(() {});
    // Tab-aware redirect prompts: only surface after this tab is visible.
    _pruneStalePendingStrictRedirects();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_flushPendingStrictRedirectPrompts(_activeTab));
    });
  }

  /// Completes cold-start work that [openNewTab] deferred for bulk restore.
  /// Idempotent via [BrowserTab.startupReady].
  Future<void> _ensureTabStartupReady(BrowserTab tab) async {
    if (tab.startupReady) return;
    tab.startupReady = true;

    // Lazy headless: only allocate when a playlist fetch actually needs it
    // (avoids a second Chromium process on every cold start).
    tab.snifferEngine.fetchPlaylistBodyViaHeadlessWebView = (url) {
      tab.headlessFetcher ??= HeadlessWebViewFetcher();
      return tab.headlessFetcher!.fetchText(url);
    };

    // Adblock for this tab only — unawaited so first paint is not blocked.
    unawaited(_configureTabAdblock(tab));

    // Media cache can be large on Secure Folder; load off the critical path.
    final base = _baseDir;
    if (base != null) {
      unawaited(
        tab.snifferEngine.loadDetectedMedia(
          '$base/sniffed_media_cache_${tab.id}.json',
        ),
      );
    }

    final url = (tab.currentUrl ?? tab.addressController.text).trim();
    if (url.isEmpty || url == 'about:blank') {
      tab.canSeedWebViewUrl = true;
      return;
    }

    // Mount blank WebView first (canSeed still false), then navigate.
    // Contends far less with queue resume / GPU init on Knox dual-user.
    tab.canSeedWebViewUrl = true;
    if (mounted) setState(() {});

    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!mounted || !_tabs.contains(tab)) return;

    unawaited(
      _loadUrlWithHostSettings(
        tab,
        Uri.parse(url),
        addToHistory: false,
      ),
    );
    unawaited(() async {
      try {
        final ua = await tab.controller.evaluateJavaScript(
          'navigator.userAgent',
        );
        if (ua is String && ua.isNotEmpty) {
          tab.userAgent = ua.startsWith('"') && ua.endsWith('"')
              ? ua.substring(1, ua.length - 1)
              : ua;
        }
      } catch (_) {}
    }());
  }

  /// Ensures the active tab (and any preview-built tab) is in
  /// [_builtWebViewTabIds]. Called from tab-switch and lifecycle paths
  /// instead of mutating the set inside [build].
  void _updateBuiltTabIds() {
    if (_tabs.isEmpty) return;
    // Always keep the active tab built when tabs are loaded.
    if (_tabsLoaded || _activeTab.controller is! SnifferWebViewControllerImpl) {
      _builtWebViewTabIds.add(_activeTab.id);
    }
    // During cold-start restore (before _tabsLoaded), keep the set empty so
    // the default blank tab's native WebView is never created (it will be
    // immediately disposed when saved tabs restore).
    if (!_tabsLoaded && _activeTab.controller is SnifferWebViewControllerImpl) {
      _builtWebViewTabIds.clear();
    }
  }

  /// Evict the least-recently-used tabs' native WebViews when the number
  /// of live WebViews exceeds [_maxLiveWebViews]. Evicted tabs become
  /// `SizedBox.shrink()` placeholders; their URL is preserved in
  /// `tab.currentUrl` and reloaded on re-activation.
  void _evictStaleTabs() {
    if (_builtWebViewTabIds.length <= _maxLiveWebViews) return;
    // Build a set of tab IDs that should stay alive (the N most recent).
    final keep = _tabActivationOrder
        .where((id) => _builtWebViewTabIds.contains(id))
        .take(_maxLiveWebViews)
        .toSet();
    final toEvict = _builtWebViewTabIds.difference(keep);
    if (toEvict.isEmpty) return;
    debugPrint('[TabEviction] Evicting ${toEvict.length} WebView(s): $toEvict');
    _builtWebViewTabIds.removeAll(toEvict);
    // No need to explicitly dispose controllers — removing the tab ID from
    // _builtWebViewTabIds causes the build method to render SizedBox.shrink()
    // instead of BrowserWidget, which tears down the native WebView widget.
  }

  // ---------------------------------------------------------------------------
  // TabLifecycleHost implementation — the parent state satisfies the
  // [TabLifecycleHost] interface so [TabLifecycleController] can drive
  // tabs without taking a direct dependency on `State` internals.
  // ---------------------------------------------------------------------------

  @override
  bool get isMounted => mounted;

  @override
  DownloadSettings get settings => widget.settings;

  @override
  String? get baseDir => _baseDir;

  @override
  void markNeedsBuild() {
    if (mounted) setState(() {});
  }

  @override
  String uaForProfile(String profile) =>
      url_utils.uaForProfile(profile, customUserAgent: widget.settings.customUserAgent);

  @override
  Future<void> loadUrlWithHostSettings(
    BrowserTab tab,
    Uri uri, {
    bool addToHistory = true,
    bool forceInApp = false,
  }) => _loadUrlWithHostSettings(
        tab,
        uri,
        addToHistory: addToHistory,
        forceInApp: forceInApp,
      );

  @override
  Future<void> configureTabAdblock(BrowserTab tab) => _configureTabAdblock(tab);

  @override
  Future<void> refreshPageInfo(BrowserTab tab, {bool recordHistory = false}) =>
      _refreshPageInfo(tab, recordHistory: recordHistory);

  @override
  void applyZoomForPage(BrowserTab tab, String url) =>
      _applyZoomForPage(tab, url);

  @override
  Future<void> applyDarkModeForPage(BrowserTab tab, String url) =>
      _applyDarkModeForPage(tab, url);

  @override
  void switchToActiveTab(int index) => _switchToActiveTab(index);

  @override
  void cancelPickerIfActive() => _cancelPickerIfActive();

  @override
  void updateTabNavState(BrowserTab tab) =>
      _tabLifecycleController.updateTabNavState(tab);

  @override
  void showSnack(String message) => _showSnack(message);

  @override
  String titleForUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri != null && uri.host.isNotEmpty) return uri.host;
    return url.isEmpty ? 'Page' : url;
  }

  @override
  void startVideoPoll(BrowserTab tab) => _startVideoPoll(tab);

  @override
  void setupTabCallbacks(BrowserTab tab) => _setupTabCallbacks(tab);

  @override
  Set<String> get builtWebViewTabIds => _builtWebViewTabIds;

  List<String> get tabActivationOrder => _tabActivationOrder;

  @override
  SniffIntakeController get sniffIntakeController => _sniffIntakeController;

  @override
  void markTabsLoaded() {
    if (!_tabsLoaded) {
      _tabsLoaded = true;
      _updateBuiltTabIds();
      debugPrint('markTabsLoaded: tabs=${_tabs.length} '
        'flushing ${_pendingOpenUrlsAfterTabsLoaded.length} '
        'pending external open(s)');
      // Rebuild so the active tab's real WebView mounts (restore left
      // _tabsLoaded false during switchToActiveTab's earlier setState).
      if (mounted) setState(() {});
      final pending = List<String>.from(_pendingOpenUrlsAfterTabsLoaded);
      _pendingOpenUrlsAfterTabsLoaded.clear();
      if (pending.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          for (final url in pending) {
            _navigateActiveTabToExternalUrl(url);
          }
        });
      }
      // Imported-session tabs open as NEW tabs beside the current one.
      final importPending = List<String>.from(_pendingImportTabUrls);
      _pendingImportTabUrls.clear();
      if (importPending.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _openTabsAfterActive(importPending);
        });
      }
      // Also drain the bus in case a request arrived while restoring tabs.
      _onOpenRequestBus();
    }
  }

  @override
  Future<void> ensureTabStartupReady(BrowserTab tab) =>
      _ensureTabStartupReady(tab);

  int _lastHandledOpenSeq = 0;

  void _onOpenRequestBus() {
    final bus = widget.openRequestBus;
    if (bus == null) return;
    final url = bus.url;
    final seq = bus.seq;
    if (url == null || url.isEmpty) return;
    if (seq == _lastHandledOpenSeq) return;
    _lastHandledOpenSeq = seq;
    debugPrint('openRequestBus consumed seq=$seq url="$url" tabsLoaded=$_tabsLoaded');
    _handleExternalOpenUrl(url);
  }

  /// Handles Queue / intent "open this URL in the browser" requests.
  /// Queues until tab restore finishes so we never open into a tab list
  /// that loadTabsAndMedia is about to dispose and replace.
  void _handleExternalOpenUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;
    debugPrint('_handleExternalOpenUrl("$trimmed") tabsLoaded=$_tabsLoaded '
      'tabs=${_tabs.length} active=${_tabs.isEmpty ? -1 : _activeTabIndex}');
    if (!_tabsLoaded || _tabs.isEmpty) {
      _pendingOpenUrlsAfterTabsLoaded.add(trimmed);
      return;
    }
    _navigateActiveTabToExternalUrl(trimmed);
  }

  /// Backup-import live restore: open [urls] as new tabs immediately to the
  /// right of the current tab, without switching to them.
  void _handleOpenUrlsInNewTabs(List<String> urls) {
    final trimmed = urls.map((u) => u.trim()).where((u) => u.isNotEmpty).toList();
    if (trimmed.isEmpty) return;
    debugPrint('_handleOpenUrlsInNewTabs(${trimmed.length}) '
      'tabsLoaded=$_tabsLoaded tabs=${_tabs.length}');
    if (!_tabsLoaded || _tabs.isEmpty) {
      _pendingImportTabUrls.addAll(trimmed);
      return;
    }
    _openTabsAfterActive(trimmed);
  }

  /// Inserts each URL as a new background tab right after the active one,
  /// preserving order. Each insert lands at the same relative position.
  void _openTabsAfterActive(List<String> urls) {
    if (!mounted || _tabs.isEmpty || urls.isEmpty) return;
    var insertAt = _activeTabIndex + 1;
    for (final url in urls) {
      _tabLifecycleController.openNewTab(
        url: url,
        switchToTab: false,
        insertAtIndex: insertAt,
      );
      insertAt++;
    }
    if (mounted) setState(() {});
  }

  /// Load [url] in the **current active browser tab** (not a brand-new tab).
  ///
  /// Creating a fresh tab + WebView from outside the Browser main-tab often
  /// failed silently (controller callback / dispose races). The active tab
  /// already has a live WebView after the user has browsed; navigating it is
  /// the same reliable path as typing a URL in the address bar.
  void _navigateActiveTabToExternalUrl(String url) {
    if (!mounted || _tabs.isEmpty) {
      _pendingOpenUrlsAfterTabsLoaded.add(url);
      return;
    }
    final tab = _activeTab;
    final uri = Uri.tryParse(url);
    final host = uri?.host.toLowerCase() ?? '';

    // If this host is configured to open in CCT (WAF-blocked), do NOT
    // load the page into the internal WebView — that just hard-blocks and
    // loops. Instead only run the native HTML sniffer intake and notify.
    final routeToCct = host.isNotEmpty &&
        widget.settings.externalBrowserHosts.contains(host);
    if (routeToCct) {
      debugPrint('_navigateActiveTabToExternalUrl: host=$host is external-only, '
        'running native intake only (no WebView load)');
      tab.addressController.text = url;
      tab.currentUrl = url;
      if (mounted) setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_tabs.contains(tab)) return;
        unawaited(() async {
          final mediaUrls =
              await NativeHtmlMediaExtractor.extractMediaFromUrl(url);
          if (!mounted || mediaUrls.isEmpty) return;
          for (final mediaUrl in mediaUrls) {
            tab.snifferEngine.sniff(
              mediaUrl,
              sourcePageUrl: url,
              pageTitle: tab.title,
              sniffSource: SniffSource.javascript,
            );
          }
          if (mounted && mediaUrls.isNotEmpty) {
            AuroraSnackbar.show(
              context,
              'Found ${mediaUrls.length} stream(s) from $host — tap the capture FAB to download.',
            );
          }
        }());
      });
      return;
    }

    // Ensure this tab's WebView is in the live set before loadRequest.
    _builtWebViewTabIds.add(tab.id);
    tab.addressController.text = url;
    tab.currentUrl = url;
    _addressExpanded = false;
    if (mounted) setState(() {});
    debugPrint('_navigateActiveTabToExternalUrl tab=${tab.id} url="$url"');
    // Post-frame so setState rebuild creates BrowserWidget if it was
    // previously evicted, then loadUrl awaits _ready.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_tabs.contains(tab)) return;
      unawaited(() async {
        // Run native HTML extraction in parallel via native HttpURLConnection
        // to bypass Cloudflare WAF WebView blocks on incoming shared URLs.
        unawaited(
          NativeHtmlMediaExtractor.extractMediaFromUrl(url).then((mediaUrls) {
            if (!mounted || mediaUrls.isEmpty) return;
            for (final mediaUrl in mediaUrls) {
              tab.snifferEngine.sniff(
                mediaUrl,
                sourcePageUrl: url,
                pageTitle: tab.title,
                sniffSource: SniffSource.javascript,
              );
            }
          }),
        );

        try {
          await tab.controller.resumeWebView();
        } catch (_) {}
        try {
          await _loadUrlWithHostSettings(tab, Uri.parse(url), forceInApp: true);
          debugPrint('external open loadRequest finished for "$url"');
        } catch (e) {
          debugPrint('external open loadRequest failed for "$url": $e');
        }
      }());
    });
  }

  @override
  bool get isDesktopMode => _desktopMode;

  @override
  BrowserTab get activeTab => _activeTab;

  // ---------------------------------------------------------------------------
  // Thin wrappers — the methods below are still referenced from
  // other private methods on this state class (e.g. `_switchToActiveTab`,
  // `_setupTabCallbacks`) and from the legacy `getCookiesForUrl`
  // `getCookiesForUrl:` callbacks, so we keep 1-line wrappers that
  // delegate to [_tabLifecycleController]. External callers should call
  // the [TabLifecycleHost] methods directly.
  // ---------------------------------------------------------------------------

  void _updateTabNavState(BrowserTab tab) =>
      _tabLifecycleController.updateTabNavState(tab);

  Future<void> _saveTabs() => _tabLifecycleController.saveTabs();

  void _openNewTab({
    String? url,
    bool switchToTab = true,
    String? restoredId,
    List<String>? restoredHistory,
    int restoredHistoryIndex = -1,
  }) => _tabLifecycleController.openNewTab(
    url: url,
    switchToTab: switchToTab,
    restoredId: restoredId,
    restoredHistory: restoredHistory,
    restoredHistoryIndex: restoredHistoryIndex,
  );

  void _startVideoPoll(BrowserTab tab) =>
      _tabLifecycleController.startVideoPoll(tab);

  void _closeTab(int index) {
    if (index >= 0 && index < _tabs.length) {
      _discardPendingStrictRedirectsForTab(_tabs[index].id);
    }
    _tabLifecycleController.closeTab(index);
  }

  @override
  void dispose() {
    externalAppPromptHandler = null;
    if (identical(
      _downloadQueue.browserContextAttacher,
      _attachBrowserContextToTask,
    )) {
      _downloadQueue.browserContextAttacher = null;
    }
    _pendingStrictRedirectByTabId.clear();
    _activeStrictRedirectPrompts.clear();
    _progressNotifier.dispose();
    WidgetsBinding.instance.removeObserver(this);
    widget.libraryUpdateNotifier?.removeListener(_onLibraryUpdate);
    _tabManager.mediaRebuildTimer?.cancel();
    _tabManager.mediaSaveTimer?.cancel();
    _navSetStateDebounce?.cancel();
    unawaited(_sessionRecovery.markClean());
    _addressFocusNode.dispose();
    _addressBarController.dispose();
    _mediaCatchController.dispose();
    _elementPickerController.dispose();
    _libraryController.dispose();
    _safeBrowsing.dispose();
    _findController.dispose();
    if (_baseDir != null) {
      for (final tab in _tabs) {
        unawaited(
          tab.snifferEngine.saveDetectedMedia(
            '$_baseDir/sniffed_media_cache_${tab.id}.json',
          ),
        );
      }
    }
    for (final tab in _tabs) {
      tab.detachAddressListener(_onAddressChanged);
    }
    widget.controller?.setOnOpenUrlRequest(null);
    widget.controller?.setOnOpenUrlInNewTab(null);
    widget.controller?.setOnOpenUrlsInNewTabs(null);
    widget.openRequestBus?.removeListener(_onOpenRequestBus);
    _tabManager.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      debugPrint(
        '[SnifferScreen] App backgrounded — pausing WebViews and timers',
      );
      unawaited(_pauseBrowserShell(includeGlobalTimers: true));
    } else if (state == AppLifecycleState.resumed) {
      debugPrint(
        '[SnifferScreen] App resumed — resuming active WebView and timers',
      );
      // Only resume if the Browser shell is the visible main tab.
      if (widget.isShellVisible) {
        unawaited(_resumeBrowserShell());
      }
    }
  }

  /// Pause every built WebView's render pipeline. Optionally pause process-
  /// global timers once (app background / leave Browser shell).
  ///
  /// Critical: never call process-global pauseTimers *after* resuming the
  /// active tab — that freezes the visible page while the scrollbar still
  /// moves (Android compositor stuck).
  Future<void> _pauseBrowserShell({bool includeGlobalTimers = true}) async {
    // Backgrounding is the point at which Android may kill the process, so a
    // coalesced history write cannot be left waiting on its timer.
    try {
      await _libraryController.flushPendingSave();
    } catch (_) {}
    for (final tab in _tabs) {
      tab.videoPollTimer?.cancel();
      tab.videoPollTimer = null;
      if (!Platform.isAndroid || !_builtWebViewTabIds.contains(tab.id)) {
        continue;
      }
      try {
        await tab.controller.suspendTab();
      } catch (_) {}
    }
    if (includeGlobalTimers) {
      // Prefer a controller that already has a live platform WebView so the
      // process-global pauseTimers channel call is not a no-op.
      SnifferBrowserController? timerCtrl;
      for (final tab in _tabs) {
        if (_builtWebViewTabIds.contains(tab.id)) {
          timerCtrl = tab.controller;
          break;
        }
      }
      timerCtrl ??= _tabs.isNotEmpty ? _activeTab.controller : null;
      try {
        await timerCtrl?.pauseAllWebViews();
      } catch (_) {}
    }
  }

  /// Resume process timers + active tab only; keep background tabs suspended
  /// with per-view pause (never global pauseTimers on those).
  Future<void> _resumeBrowserShell() async {
    if (_tabs.isEmpty) return;
    final active = _activeTab;
    try {
      await active.controller.resumeWebView();
    } catch (_) {}
    for (final tab in _tabs) {
      if (!_builtWebViewTabIds.contains(tab.id)) continue;
      if (identical(tab, active)) continue;
      try {
        await tab.controller.suspendTab();
      } catch (_) {}
    }
    _startVideoPoll(active);
  }

  @override
  void didHaveMemoryPressure() {
    debugPrint(
      '[SnifferScreen] Low memory warning — evicting oldest background WebViews',
    );
    // Keep up to 3 tabs' WebViews alive even under memory pressure so the
    // user can immediately go back/forward to the most recent pages.
    const int keepCount = 3;
    if (_builtWebViewTabIds.length > keepCount) {
      final keep = _tabActivationOrder
          .where((id) => _builtWebViewTabIds.contains(id))
          .take(keepCount)
          .toSet();
      final toEvict = _builtWebViewTabIds.difference(keep);
      if (toEvict.isNotEmpty) {
        debugPrint('[MemoryPressure] Evicting background WebViews: $toEvict');
        _builtWebViewTabIds.removeAll(toEvict);
        setState(() {});
      }
    }
  }


  Future<void> _initPaths() async {
    try {
      final baseDir = (await getApplicationSupportDirectory()).path;
      // Use persistent storage for temp files so partial download bytes
      // survive OS cache clearing (matching _tempWorkspaceDirectory in main.dart).
      final downloadsTmpDir = Directory('$baseDir/downloads_tmp');
      if (!await downloadsTmpDir.exists()) {
        await downloadsTmpDir.create(recursive: true);
      }
      final baseTemp = downloadsTmpDir.path;
      if (mounted) {
        setState(() {
          _baseDir = baseDir;
          _baseTemp = baseTemp;
        });
        unawaited(_tabLifecycleController.loadTabsAndMedia());
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _baseDir = Directory.systemTemp.path;
          _baseTemp = Directory.systemTemp.path;
        });
        unawaited(_tabLifecycleController.loadTabsAndMedia());
      }
    }
  }

  String? _baseDir;
  String? _baseTemp;

  /// Saves a played video to the Videos subpage of Favorites.
  ///
  /// The free inventory cap lives in [VideoLibrary]; this only turns its
  /// verdict into feedback. A capped save must say so — silently doing nothing
  /// after the user taps a star reads as a broken button.
  Future<void> _saveVideoFavorite(SniffedMedia media) async {
    final tier = proUpsellEntitlement?.tier ?? EntitlementTier.free;
    final result = await VideoLibrary.addFavorite(
      library: _library,
      tier: tier,
      url: media.url,
      title: media.pageTitle?.trim().isNotEmpty == true
          ? media.pageTitle!.trim()
          : media.name,
      thumbnailUrl: media.thumbnailUrl,
      sourcePageUrl: media.sourcePageUrl,
    );
    if (!mounted) return;

    switch (result.outcome) {
      case VideoSaveOutcome.saved:
        await _saveLibrary(result.library);
        if (mounted) _showSnack('Saved to Favorites → Videos');
      case VideoSaveOutcome.duplicate:
        _showSnack('Already in your saved videos');
      case VideoSaveOutcome.capped:
        unawaited(
          UpsellController.show(
            context,
            feature: ProFeature.videoLibrary,
            userTier: tier,
          ),
        );
    }
  }

  /// Appends a playback to the Videos subpage of History. Fire-and-forget:
  /// failing to record a watch must never interrupt playback.
  void _recordVideoPlay(SniffedMedia media) {
    final tier = proUpsellEntitlement?.tier ?? EntitlementTier.free;
    final updated = VideoLibrary.recordPlay(
      library: _library,
      tier: tier,
      url: media.url,
      title: media.pageTitle?.trim().isNotEmpty == true
          ? media.pageTitle!.trim()
          : media.name,
      thumbnailUrl: media.thumbnailUrl,
      sourcePageUrl: media.sourcePageUrl,
    );
    unawaited(_saveLibrary(updated));
  }

  Future<void> _saveLibrary(BrowserLibrary newLibrary) =>
      _libraryController.save(newLibrary);

  Future<void> _refreshPageInfo(
    BrowserTab tab, {
    required bool recordHistory,
  }) async {
    String? title;
    String? url;
    try {
      title = await tab.controller.pageTitle();
      url = await tab.controller.currentUrl();
    } on MissingPluginException {
      // WebView was evicted (e.g. LRU background eviction). Bail out gracefully.
      return;
    }
    if (!mounted) return;
    setState(() {
      tab.title = cleanTitle(title, url);
      tab.currentUrl = url;
      if (url != null && url.isNotEmpty) {
        _addressExpanded = false;
      }
    });
    if (recordHistory &&
        url != null &&
        url.isNotEmpty &&
        !url.startsWith('file:')) {
      await _recordHistory(url, tab.title ?? titleForUrl(url));
    }
  }

  void _findNext(bool forward) {
    if (_findMatchCount <= 0) return;
    if (forward) {
      _findCurrentMatch = _findCurrentMatch + 1 >= _findMatchCount
          ? 0
          : _findCurrentMatch + 1;
    } else {
      _findCurrentMatch = _findCurrentMatch - 1 < 0
          ? _findMatchCount - 1
          : _findCurrentMatch - 1;
    }
    _activeTab.controller.findNext(forward, _findController.text);
    setState(() {});
  }

  /// Runs the find cycle for a new query and syncs the match counter into the
  /// UI (the counter previously stayed at its dead-initial 0, so Next/Prev
  /// clamped against -1 and threw on every press).
  Future<void> _updateFindCount(String value) async {
    final count = await _activeTab.controller.findAllAsync(value);
    if (!mounted) return;
    setState(() {
      _findMatchCount = count;
      _findCurrentMatch = 0;
    });
  }

  void _dismissFind() {
    setState(() {
      _findVisible = false;
      _findMatchCount = 0;
      _findCurrentMatch = 0;
    });
  }

  /// Debounced [setState] for navigation callbacks. Cancels any pending
  /// timer and schedules a rebuild 100ms after the last navigation event,
  /// so rapid redirect chains fire only one rebuild instead of one per step.
  void _debouncedNavSetState() {
    _navSetStateDebounce?.cancel();
    _navSetStateDebounce = Timer(const Duration(milliseconds: 100), () {
      if (mounted) setState(() {});
    });
  }

  void _onScroll(double x, double y) {
    if (!mounted) return;
    if (_findVisible) {
      if (!_barsVisible) {
        setState(() => _barsVisible = true);
      }
      return;
    }
    // Ignore small jitters
    if ((y - _lastScrollY).abs() < 5) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastBarsToggleAtMs < 180) return;

    if (y > _lastScrollY && y > 80) {
      if (_barsVisible) {
        _lastBarsToggleAtMs = now;
        setState(() {
          _barsVisible = false;
        });
      }
    } else if (y < _lastScrollY || y <= 15) {
      if (!_barsVisible) {
        _lastBarsToggleAtMs = now;
        setState(() {
          _barsVisible = true;
        });
      }
    }
    _lastScrollY = y;
  }

  void _showTabsSheet() => showTabsSheet(
    context,
    tabs: _tabs,
    activeTabIndex: _activeTabIndex,
    onCloseTab: (index) {
      _closeTab(index);
      setState(() {});
    },
    onReopenLastClosedTab: () {
      // No-op: closed tabs are not persisted.
    },
    onOpenNewTab: ({String? url, bool? switchToTab}) {
      _openNewTab(url: url, switchToTab: switchToTab ?? true);
      setState(() {});
    },
    onSwitchToActiveTab: (index) {
      _switchToActiveTab(index);
      setState(() {});
    },
    getTabLabel: _tabLabel,
    onCloseAllTabs: () {
      _pendingStrictRedirectByTabId.clear();
      _activeStrictRedirectPrompts.clear();
      _tabLifecycleController.closeAllTabs();
      setState(() {});
    },
    builtWebViewTabIds: _builtWebViewTabIds,
    onDropOnGroup: (draggedTabId, groupName) {
      final idx = _tabManager.indexOfTabId(draggedTabId);
      if (idx >= 0) {
        _tabManager.moveTabToGroup(
          _tabs[idx],
          groupName: groupName,
          onCapExceeded: () => showProUpsell(context, ProFeature.unlimitedTabGroups),
        );
        setState(() {});
      }
    },
    onGroupLongPress: _showGroupActionsSheet,
    colorIndexForGroup: (name) {
      return _tabManager.groupByName(name)?.colorIndex ?? -1;
    },
    isGroupExpanded: (name) => _expandedGroups.contains(name),
    onToggleGroup: (name) {
      if (_expandedGroups.contains(name)) {
        _expandedGroups.remove(name);
      } else {
        _expandedGroups.add(name);
      }
    },
  );

  void _showGroupActionsSheet(String groupName) {
    final group = _tabManager.groupByName(groupName);
    if (group == null) return;
    showGroupActionsSheet(
      context,
      groupName: groupName,
      memberCount: _tabManager.tabsInGroup(groupName).length,
      currentAutoHost: group.autoHost,
      currentColorIndex: group.colorIndex,
      callbacks: GroupActionsCallbacks(
        onRename: (oldName, newName) {
          final ok = _tabManager.renameGroup(oldName, newName);
          if (ok) setState(() {});
          return ok;
        },
        onSetColor: (name, colorIndex) {
          _tabManager.setGroupColor(name, colorIndex);
          setState(() {});
        },
        onSetAutoHost: (name, host) {
          _tabManager.setGroupAutoHost(name, host);
          setState(() {});
        },
        onCloseAll: (name) {
          _tabManager.closeGroup(name);
          setState(() {});
        },
        onDisband: (name) {
          _tabManager.disbandGroup(name);
          setState(() {});
        },
      ),
    );
  }

  /// Delegates so the dedupe rule, the cap and the debounce live in exactly one
  /// place. This used to be a second, immediate-write copy of
  /// [LibraryController.recordHistory] that had neither a cap nor coalescing.
  Future<void> _recordHistory(String url, String title) =>
      _libraryController.recordHistory(url, title, privateMode: _privateMode);

  void _setupTabCallbacks(BrowserTab tab) => _tabCallbackBinder.attach(tab);

  // ---- TabCallbackHost implementation (forwarding to private methods) ----
  // markNeedsBuild, updateTabNavState, showSnack, startVideoPoll are
  // already public via TabLifecycleHost — no forwarding needed.

  void debouncedNavSetState() => _debouncedNavSetState();
  void onScroll(double x, double y) => _onScroll(x, y);

  ValueNotifier<int> get progressNotifier => _progressNotifier;
  VoidCallback get onAddressChanged => _onAddressChanged;
  bool isDifferentPage(String? a, String? b) =>
      _isDifferentPage(a ?? '', b ?? '');

  // Mutable bookkeeping
  double get lastScrollY => _lastScrollY;
  set lastScrollY(double v) => _lastScrollY = v;
  bool get barsVisible => _barsVisible;
  set barsVisible(bool v) => _barsVisible = v;
  Set<String> get fetchedIframeSrcs => _tabManager.fetchedIframeSrcs;
  SniffedMedia? get latestVideoMedia => _latestVideoMedia;
  set latestVideoMedia(SniffedMedia? v) => _latestVideoMedia = v;
  Rect? get videoFloatRect => _videoFloatRect;
  set videoFloatRect(Rect? v) => _videoFloatRect = v;
  String? get floatingPlayerDismissedForUrl => _floatingPlayerDismissedForUrl;
  set floatingPlayerDismissedForUrl(String? v) => _floatingPlayerDismissedForUrl = v;

  // Popup / redirect / picker
  void handleNativeStrictRedirect(BrowserTab tab, Object event) =>
      _handleNativeStrictRedirect(tab, event as dynamic);
  void handlePopupEvent(BrowserTab tab, String message) =>
      _handlePopupEvent(tab, message);
  void handleInvisibleRedirect(BrowserTab tab, String message) =>
      _handleInvisibleRedirect(tab, message);
  Future<void> handlePickedElement(BrowserTab tab, String message) =>
      _handlePickedElement(tab, message);

  // NB: showLinkContextMenu delegates to the private _showElementContextMenu
  // which internally calls the external showElementContextMenu from
  // context_menu_action.dart.  Avoids name shadowing.
  void showLinkContextMenu(String message) =>
      _showElementContextMenu(message);

  // Player / float
  Future<void> handleAuroraPlayRequest(String message) =>
      _handleAuroraPlayRequest(message);
  void handleVideoFloatMessage(String message) =>
      _handleVideoFloatMessage(message);
  void showComplianceNotice() {
    AuroraSnackbar.show(context, RestrictedMediaPolicy.pageNoticeRestricted);
  }

  // JS / sniffing
  Future<Map?> decodeJsInBackground(String message) =>
      _decodeJsInBackground(message);
  void sniffIframeContent(BrowserTab tab, String url) =>
      _sniffIframeContent(tab, url);

  // Download — avoid shadowing external functions from enqueue_download.dart
  Future<void> handleEnqueueDownload(
    BrowserTab tab,
    String url,
    String? suggestedFilename,
  ) => _enqueueDirectDownload(tab, url, suggestedFilename);
  void handleDownloadPrompt(
    BrowserTab tab,
    String url,
    String? suggestedFilename,
  ) => _showDownloadBehaviorPrompt(tab, url, suggestedFilename);

  // Page lifecycle (some already from TabLifecycleHost)
  Future<void> saveTabs() => _saveTabs();

  // Media / playback
  bool mediaBelongsToActiveTab(SniffedMedia media) =>
      _mediaBelongsToActiveTab(media);
  bool shouldReplaceVideo(SniffedMedia incoming) =>
      _shouldReplaceVideo(incoming);

  /// Drop any cached float/auto-replace media that is not from the active
  /// tab, then re-pick the best stream from that tab's sniffer only.
  void _resyncPlaybackMediaForActiveTab() {
    _videoFloatRect = null;
    final best = _bestDetectedVideoForPlayback();
    _latestVideoMedia = best;
  }

  /// True when [media] was sniffed for the active tab's page (not another
  /// tab's leftover URL).
  bool _mediaBelongsToActiveTab(SniffedMedia media) {
    final engine = _activeTab.snifferEngine;
    if (engine.detectedMedia.any((m) => m.url == media.url)) {
      return true;
    }
    final page = (media.sourcePageUrl ?? '').trim();
    final active = (_activeTab.currentUrl ?? _activeTab.addressController.text)
        .trim();
    if (page.isEmpty || active.isEmpty) return false;
    final a = Uri.tryParse(page);
    final b = Uri.tryParse(active);
    if (a == null || b == null || a.host.isEmpty || b.host.isEmpty) {
      return false;
    }
    return a.host.toLowerCase() == b.host.toLowerCase();
  }

  /// Stream to open from the float / auto-replace — never another tab's.
  SniffedMedia? _videoForActiveTabPlayback() {
    final best = _bestDetectedVideoForPlayback();
    if (best != null) return best;
    final latest = _latestVideoMedia;
    if (latest != null && _mediaBelongsToActiveTab(latest)) return latest;
    return null;
  }


  /// Returns `true` if [incoming] should replace the current [_latestVideoMedia]
  /// used for auto-replace playback. Keeps the best candidate: HLS > large > other.
  bool _shouldReplaceVideo(SniffedMedia incoming) {
    final current = _latestVideoMedia;
    if (current == null || !_mediaBelongsToActiveTab(current)) return true;

    final incomingIsHls = _isHlsUrl(incoming.url);
    final currentIsHls = _isHlsUrl(current.url);

    // HLS always beats non-HLS.
    if (incomingIsHls && !currentIsHls) return true;
    if (!incomingIsHls && currentIsHls) return false;

    // Among same type, prefer larger content length (avoid short previews).
    final incomingSize = incoming.contentLengthBytes ?? 0;
    final currentSize = current.contentLengthBytes ?? 0;
    if (incomingSize > 0 && currentSize > 0) {
      // Only replace if incoming is significantly larger (>2x) or current is tiny.
      if (incomingSize > currentSize * 2) return true;
      if (currentSize < 500 * 1024 && incomingSize > currentSize) return true;
      if (incomingSize < 500 * 1024 && currentSize >= 500 * 1024) return false;
    }

    // If current has no size info and incoming does, prefer incoming.
    if (currentSize <= 0 && incomingSize > 0) return true;
    if (incomingSize <= 0 && currentSize > 0) return false;

    // Prefer videos with non-null content-type (more likely a real stream vs ad).
    if (incoming.contentType != null && current.contentType == null) return true;
    if (incoming.contentType == null && current.contentType != null) return false;

    return false; // Keep current by default.
  }

  /// Returns `true` if [url] is an HLS playlist URL.
  static bool _isHlsUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('.m3u8') || lower.contains('mpegurl');
  }

  // The intake pipeline (`_sniffBrowserUrl`, `_sniffWithLiveHeaders`,
  // `_getCookiesForUrl`, `_getCachedCookiesForUrl`, `_cookieCacheKey`,
  // `_autoSaveTabMedia`, `_scheduleMediaRebuild`, `_scheduleMediaSave`)
  // is now implemented in `SniffIntakeController` (see
  // `controllers/sniff_intake_controller.dart`). The state class holds a
  // `late final SniffIntakeController _sniffIntakeController` field and
  // delegates every intake call to it.
  //
  // `_looksLikeMediaUrl` and `_mediaFastPathRegExp` were also moved into
  // the controller as static helpers.

  /// Fetch iframe content via Dart HTTP to find media URLs in cross-origin iframes.
  static final RegExp _iframeUrlMediaRegExp = RegExp(
    // .ts is excluded so HLS fragments do not flood the sniffer.
    r'((?:https?://)[^\s"'
    "'"
    r'`<>]+?(?:'
    r'\.(?:mp4|m3u8|webm|mkv|avi|flv|mov|mp3|wav|aac|ogg|m4a|flac|mpd|f4m)'
    r'|/(?:hls|seg|chunk|video|stream|playlist|master|manifest|dash|media)/'
    r')'
    r'(?:[^\s"'
    "'"
    r'`<>]*))',
    caseSensitive: false,
  );

  static final RegExp _iframeAllUrlsRegExp = RegExp(
    r'(https?://[^\s"'
    "'"
    r'`<>\]]+)',
    caseSensitive: false,
  );

  Future<void> _sniffIframeContent(BrowserTab tab, String iframeSrcUrl) async {
    if (_fetchedIframeSrcs.contains(iframeSrcUrl)) return;
    if (iframeSrcUrl.startsWith('data:') ||
        iframeSrcUrl.startsWith('blob:') ||
        iframeSrcUrl.startsWith('about:')) {
      return;
    }
    _fetchedIframeSrcs.add(iframeSrcUrl);

    try {
      final pageUrl = tab.addressController.text;
      final cookieHeaders = await _sniffIntakeController.getCookiesForUrl(
        iframeSrcUrl,
      );
      final headers = <String, String>{
        ...tab.controller.currentHeaders,
        ...cookieHeaders,
        if (pageUrl.isNotEmpty) 'Referer': pageUrl,
      };
      final response = await http.get(
        Uri.parse(iframeSrcUrl),
        headers: headers,
      );
      if (response.statusCode >= 200 && response.statusCode < 400) {
        final body = response.body;
        final matches = _iframeUrlMediaRegExp.allMatches(body);
        for (final match in matches) {
          final mediaUrl = match.group(1);
          if (mediaUrl != null && mediaUrl.isNotEmpty) {
            _sniffIntakeController.sniffBrowserUrl(
              tab,
              mediaUrl,
              sourcePageUrl: iframeSrcUrl,
            );
          }
        }

        // Also extract all https?:// URLs and probe extensionless candidates
        final allUrls = _iframeAllUrlsRegExp.allMatches(body);
        final Set<String> seen = {};
        var headProbeCount = 0;
        for (final m in allUrls) {
          final url = m.group(1);
          if (url == null || url.isEmpty || seen.contains(url)) continue;
          seen.add(url);
          final uri = Uri.tryParse(url);
          if (uri == null) continue;
          final path = uri.path.toLowerCase();
          // Only probe URLs with CDN-like paths (skip CSS/JS/fonts/images/icons)
          if (!path.contains('/hls/') &&
              !path.contains('/seg/') &&
              !path.contains('/chunk/') &&
              !path.contains('/video/') &&
              !path.contains('/stream/') &&
              !path.contains('/playlist/') &&
              !path.contains('/master/') &&
              !path.contains('/dash/') &&
              !path.contains('/media/') &&
              !path.contains('/cdn/')) {
            continue;
          }
          // Skip obvious non-media extensions
          if (path.endsWith('.css') ||
              path.endsWith('.js') ||
              path.endsWith('.html') ||
              path.endsWith('.png') ||
              path.endsWith('.jpg') ||
              path.endsWith('.gif') ||
              path.endsWith('.svg') ||
              path.endsWith('.ico') ||
              path.endsWith('.woff2') ||
              path.endsWith('.ttf') ||
              path.endsWith('.eot')) {
            continue;
          }
          // HEAD request to verify content-type
          if (headProbeCount >= 10) break;
          try {
            final headResp = await http.head(uri, headers: headers);
            headProbeCount++;
            final ct = headResp.headers['content-type'] ?? '';
            if (ct.contains('video/') ||
                ct.contains('audio/') ||
                ct.contains('application/vnd.apple.mpegurl') ||
                ct.contains('application/dash+xml') ||
                ct.contains('application/x-mpegurl')) {
              _sniffIntakeController.sniffBrowserUrl(
                tab,
                url,
                sourcePageUrl: iframeSrcUrl,
                contentType: ct,
              );
            }
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('Iframe content fetch failed for $iframeSrcUrl: $e');
    }
  }

  void _loadAddress([String? _]) {
    final address = _activeTab.addressController.text.trim();
    if (address.isEmpty) return;
    _addressBarController.loadAddress(
      address,
      tab: _activeTab,
      searchEngine: widget.settings.searchEngine,
      loadUrl: (tab, uri) {
        unawaited(_loadUrlWithHostSettings(tab, uri));
      },
      onRebuild: () => setState(() {}),
    );
  }

  void _clearAddressSuggestions() {
    _addressBarController.clearSuggestions();
  }

  void _onAddressChanged() {
    // Only the active tab drives the suggestion panel; other tabs still
    // have listeners so switching mid-type is consistent, but we ignore
    // non-active edits (should not happen while typing).
    if (!_addressExpanded) {
      _addressBarController.clearSuggestions();
      return;
    }
    _addressBarController.onAddressChanged(
      tab: _activeTab,
      library: _library,
      searchEngine: widget.settings.searchEngine,
      rebuild: () {
        if (mounted) setState(() {});
      },
    );
  }

  void _acceptSuggestion(AddressSuggestion suggestion) {
    _addressBarController.acceptSuggestion(
      suggestion,
      tab: _activeTab,
      loadUrl: (tab, uri) {
        unawaited(_loadUrlWithHostSettings(tab, uri));
      },
      onRebuild: () => setState(() {}),
    );
  }

  Future<void> _loadUrlWithHostSettings(
    BrowserTab tab,
    Uri uri, {
    Map<String, String>? extraHeaders,
    bool addToHistory = true,
    bool forceInApp = false,
  }) async {
    // App deep links (tg:, intent://, mailto:, magnet:, …) never enter
    // Chromium — controller.loadRequest routes them externally / to queue.
    // skipExternalPrompt: user typed/chose this URL (address bar, favorites).
    if (isExternalAppUri(uri)) {
      await tab.controller.loadRequest(
        uri,
        addToHistory: false,
        skipExternalPrompt: true,
      );
      return;
    }

    final host = uri.host.toLowerCase();
    if (!forceInApp && host.isNotEmpty && widget.settings.externalBrowserHosts.contains(host)) {
      unawaited(CctBrowser.openCustomTab(uri.toString()));
      return;
    }

    // Trigger native HTML media extraction in background (bypasses Cloudflare WAF on WebView)
    unawaited(
      NativeHtmlMediaExtractor.extractMediaFromUrl(uri.toString()).then((mediaUrls) {
        if (!mounted || mediaUrls.isEmpty) return;
        for (final mediaUrl in mediaUrls) {
          tab.snifferEngine.sniff(
            mediaUrl,
            sourcePageUrl: uri.toString(),
            pageTitle: tab.title,
            sniffSource: SniffSource.javascript,
          );
        }
      }),
    );
    SafeBrowsingResult safety;
    try {
      safety = await _safeBrowsing.check(uri.toString());
    } catch (e) {
      debugPrint('Safe browsing check failed: $e');
      safety = const SafeBrowsingResult(verdict: SafeBrowsingVerdict.safe);
    }
    if (safety.verdict == SafeBrowsingVerdict.malicious) {
      if (!mounted) return;
      final proceed = await _showPhishingWarning(uri, safety);
      if (proceed != true) return;
    } else if (safety.verdict == SafeBrowsingVerdict.suspicious) {
      _showSnack(
        'Heads up: ${safety.reason ?? "suspicious URL"}',
        actionLabel: 'Whitelist',
        onAction: () async {
          await _safeBrowsing.whitelistHost(host);
          _showSnack('Whitelisted $host.');
        },
      );
    }
    // --- Site profile overrides (take precedence over global settings) ---
    final profiles = await loadProfiles();
    final profileOverride = navOverrideFor(uri.toString(), profiles);

    // UA: profile > per-site map > desktop mode > global profile
    String? ua;
    if (profileOverride?.userAgent != null) {
      ua = uaForProfile(profileOverride!.userAgent!);
    } else if (profileOverride?.desktopMode == true) {
      // Profile forces desktop → use desktop Chrome UA.
      ua = uaForProfile('desktop_chrome');
    } else if (profileOverride?.desktopMode == false) {
      // Profile forces mobile → reset to mobile (null means default).
      ua = null;
    } else {
      ua = _effectiveUserAgentFor(host);
    }
    if (ua != null) {
      await tab.controller.setUserAgent(ua);
    }

    // Adblock: profile override toggles per-tab.
    if (profileOverride?.adblockEnabled != null) {
      await tab.controller.configureAdBlock(
        enabled: profileOverride!.adblockEnabled!,
        filterSources: widget.settings.adblockFilterSources,
        manualRules: widget.settings.manualAdBlockRules,
      );
    }

    // Site-player replace: profile override > global setting.
    final replacePlayer = profileOverride?.replaceSitePlayer ??
        widget.settings.replaceSitePlayer;
    try {
      await tab.controller.setReplaceSitePlayer(replacePlayer);
    } catch (_) {
      // Best-effort; some WebView backends may not support this yet.
    }

    final headers = <String, String>{
      ..._baseRequestHeaders(),
      if (extraHeaders != null) ...extraHeaders,
    };
    try {
      if (headers.isEmpty) {
        await tab.controller.loadRequest(uri, addToHistory: addToHistory);
      } else {
        await tab.controller.loadRequest(
          uri,
          headers: headers,
          addToHistory: addToHistory,
        );
      }
    } on MissingPluginException {
      // WebView was evicted (LRU or memory pressure). Navigation will be
      // retried when the tab is re-activated and a new WebView is created.
      return;
    }
    final zoom = _effectiveZoomFor(host);
    if ((zoom - 1.0).abs() > 0.01) {
      unawaited(tab.controller.setZoomScale(zoom));
    }
  }

  Future<bool?> _showPhishingWarning(Uri uri, SafeBrowsingResult result) {
    return showPhishingWarningDialog(
      context: context,
      uri: uri,
      result: result,
    );
  }

  void _applyZoomForPage(BrowserTab tab, String url) {
    final host = (Uri.tryParse(url)?.host ?? '').toLowerCase();
    if (host.isEmpty) return;
    final zoom = _effectiveZoomFor(host);
    if ((zoom - 1.0).abs() > 0.01) {
      unawaited(tab.controller.setZoomScale(zoom));
    }
  }

  // OLED dark: tint page chrome only. Never invert media — a prior
  // invert+hue-rotate on video/iframe/canvas made players look negative
  // (e.g. povpow.com and other site players). System theme skips this overlay.
  static const String _darkModeCssOverlay = r'''
(function(){
  if (window.__auroraDarkModeActive) {
    var old = document.getElementById('aurora-dark-mode-style');
    if (old) old.remove();
  }
  var style = document.createElement('style');
  style.id = 'aurora-dark-mode-style';
  style.textContent = `
    html.aurora-dark, html.aurora-dark body {
      background-color: #0a0a0a !important;
      color: #E5E9F0 !important;
      color-scheme: dark !important;
    }
    /* Media must keep true colors — never invert / hue-rotate. */
    html.aurora-dark video,
    html.aurora-dark audio,
    html.aurora-dark iframe,
    html.aurora-dark canvas,
    html.aurora-dark img,
    html.aurora-dark picture,
    html.aurora-dark svg,
    html.aurora-dark embed,
    html.aurora-dark object,
    html.aurora-dark [style*="background-image"] {
      filter: none !important;
      -webkit-filter: none !important;
    }
  `;
  (document.head || document.documentElement).appendChild(style);
  document.documentElement.classList.add('aurora-dark');
  window.__auroraDarkModeActive = true;
})();
''';

  static const String _darkModeCssRemove = r'''
(function(){
  var old = document.getElementById('aurora-dark-mode-style');
  if (old) old.remove();
  document.documentElement.classList.remove('aurora-dark');
  window.__auroraDarkModeActive = false;
})();
''';

  bool get _darkModeForced =>
      widget.settings.darkModePreference == DarkModePreference.forced;

  Future<void> _applyDarkModeForPage(BrowserTab tab, String url) async {
    final host = (Uri.tryParse(url)?.host ?? '').toLowerCase();
    if (host.isEmpty) return;
    final forced = _darkModeForced;
    if (forced) {
      await tab.controller.evaluateJavaScript(_darkModeCssOverlay);
    } else {
      await tab.controller.evaluateJavaScript(_darkModeCssRemove);
    }
  }

  void _handlePopupEvent(BrowserTab tab, String rawMessage) {
    Map<String, dynamic> data = {};
    try {
      final decoded = jsonDecode(rawMessage);
      if (decoded is Map) data = Map<String, dynamic>.from(decoded);
    } catch (_) {}
    final playSuppress = data['reason'] == 'play-ad-suppress';
    if (!playSuppress && !widget.settings.popupBlockingEnabled) return;
    if (!mounted) return;
    final event = BlockedPopupEvent.fromJson(data);
    final url = event.url?.trim();
    tab.controller.incrementBlockedPopups();
    setState(() {});
    if (url == null || url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return;
    // App deep links in window.open / target=_blank / external-app reason:
    // open outside immediately (no "Popup blocked" dialog).
    if (isExternalAppUri(uri) || event.reason == 'external-app') {
      if (isExternalAppUri(uri)) {
        unawaited(tab.controller.loadRequest(uri, addToHistory: false));
      }
      return;
    }
    _suppressBlockedRedirectNoise(
      tab,
      url,
      reason: playSuppress ? 'play ad popup' : 'popup ad',
      userInitiated: event.userInitiated,
    );
    // Silent during play open — keep the player UX clean.
    if (playSuppress) return;
    unawaited(
      _showStrictRedirectPrompt(
        tab: tab,
        uri: uri,
        title: 'Popup blocked by Aurora',
        method: event.reason,
        sourcePageUrl: event.sourcePageUrl,
      ),
    );
  }

  void _handleInvisibleRedirect(BrowserTab tab, String rawMessage) {
    Map<String, dynamic> data = {};
    try {
      final decoded = jsonDecode(rawMessage);
      if (decoded is Map) data = Map<String, dynamic>.from(decoded);
    } catch (_) {}
    final suppressedDuringPlay = data['suppressedDuringPlay'] == true;
    // During play-ad suppress we always accept the cancel (even if the
    // global setting is off) so the video page is not stolen.
    if (!suppressedDuringPlay &&
        !widget.settings.invisibleRedirectBlockingEnabled) {
      return;
    }
    if (!mounted) return;
    final url = (data['url'] as String?)?.trim();
    if (url == null || url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return;
    // Scripted tg: / intent:// / mailto: — open the app, don't "block redirect".
    if (isExternalAppUri(uri) && !suppressedDuringPlay) {
      unawaited(tab.controller.loadRequest(uri, addToHistory: false));
      return;
    }
    final userInitiated = data['userInitiated'] as bool? ?? false;
    tab.controller.incrementBlockedInvisibleRedirects();
    setState(() {});
    _suppressBlockedRedirectNoise(
      tab,
      url,
      reason: suppressedDuringPlay ? 'play ad redirect' : 'invisible redirect',
      userInitiated: userInitiated,
    );
    // Silent during play open — dialog would stack under the player.
    if (suppressedDuringPlay) return;
    unawaited(
      _showStrictRedirectPrompt(
        tab: tab,
        uri: uri,
        title: 'Redirect blocked by Aurora',
        method: data['method'] as String? ?? 'script',
        sourcePageUrl: data['sourcePageUrl'] as String?,
      ),
    );
  }

  void _handleNativeStrictRedirect(BrowserTab tab, StrictRedirectEvent event) {
    if (!mounted || !widget.settings.invisibleRedirectBlockingEnabled) return;
    final uri = Uri.tryParse(event.url);
    if (uri == null || !uri.hasScheme) return;
    if (isExternalAppUri(uri)) {
      unawaited(tab.controller.loadRequest(uri, addToHistory: false));
      return;
    }
    tab.controller.incrementBlockedInvisibleRedirects();
    setState(() {});
    _suppressBlockedRedirectNoise(
      tab,
      event.url,
      reason: event.isRedirect ? 'http redirect' : 'invisible redirect',
      userInitiated: event.userInitiated,
    );
    unawaited(
      _showStrictRedirectPrompt(
        tab: tab,
        uri: uri,
        title: 'Redirect blocked by Aurora',
        method: event.method,
        sourcePageUrl: event.sourceUrl,
      ),
    );
  }

  void _suppressBlockedRedirectNoise(
    BrowserTab tab,
    String url, {
    required String reason,
    required bool userInitiated,
  }) {
    if (tab.controller.shouldBlockUrl(url) ||
        AdBlockEngine.looksLikeAdMediaUrl(url) ||
        !userInitiated) {
      tab.snifferEngine.suppress(url, reason);
    }
  }

  Future<void> _showStrictRedirectPrompt({
    required BrowserTab tab,
    required Uri uri,
    required String title,
    required String method,
    String? sourcePageUrl,
  }) async {
    final url = uri.toString();
    final promptKey = '${tab.id}|$title|$url';
    final now = DateTime.now().millisecondsSinceEpoch;
    _recentStrictRedirectPrompts.removeWhere(
      (_, value) => now - value > _strictRedirectPromptCooldown.inMilliseconds,
    );
    if (_activeStrictRedirectPrompts.contains(promptKey)) return;
    final lastPromptAt = _recentStrictRedirectPrompts[promptKey];
    if (lastPromptAt != null &&
        now - lastPromptAt < _strictRedirectPromptCooldown.inMilliseconds) {
      return;
    }
    final alreadyQueued = _pendingStrictRedirectByTabId[tab.id]
            ?.any((p) => p.promptKey == promptKey) ??
        false;
    if (alreadyQueued) return;

    _recentStrictRedirectPrompts[promptKey] = now;
    if (!mounted || !_tabs.contains(tab)) return;

    // Tab-aware: never interrupt another tab (or Queue shell). Queue until
    // the source tab is active and the browser shell is visible.
    final sourceIsVisible =
        widget.isShellVisible && identical(tab, _activeTab);
    if (!sourceIsVisible) {
      _enqueuePendingStrictRedirect(
        tabId: tab.id,
        uri: uri,
        title: title,
        method: method,
        sourcePageUrl: sourcePageUrl,
        promptKey: promptKey,
      );
      return;
    }

    await _presentStrictRedirectPrompt(
      tab: tab,
      uri: uri,
      title: title,
      method: method,
      sourcePageUrl: sourcePageUrl,
      promptKey: promptKey,
    );
  }

  void _enqueuePendingStrictRedirect({
    required String tabId,
    required Uri uri,
    required String title,
    required String method,
    required String promptKey,
    String? sourcePageUrl,
  }) {
    final list = _pendingStrictRedirectByTabId.putIfAbsent(tabId, () => []);
    list.removeWhere((p) => p.promptKey == promptKey);
    list.add(
      PendingStrictRedirectPrompt(
        uri: uri,
        title: title,
        method: method,
        sourcePageUrl: sourcePageUrl,
        promptKey: promptKey,
      ),
    );
  }

  void _discardPendingStrictRedirectsForTab(String tabId) {
    _pendingStrictRedirectByTabId.remove(tabId);
    _activeStrictRedirectPrompts.removeWhere((k) => k.startsWith('$tabId|'));
  }

  void _pruneStalePendingStrictRedirects() {
    if (_pendingStrictRedirectByTabId.isEmpty) return;
    final liveIds = _tabs.map((t) => t.id).toSet();
    _pendingStrictRedirectByTabId.removeWhere((id, _) => !liveIds.contains(id));
  }

  /// Surfaces deferred redirect prompts for [tab] when it is the active tab.
  Future<void> _flushPendingStrictRedirectPrompts(BrowserTab tab) async {
    if (!mounted || !widget.isShellVisible) return;
    if (!_tabs.contains(tab) || !identical(tab, _activeTab)) return;
    if (_flushingStrictRedirectTabId == tab.id) return;

    _flushingStrictRedirectTabId = tab.id;
    try {
      while (mounted &&
          widget.isShellVisible &&
          _tabs.contains(tab) &&
          identical(tab, _activeTab)) {
        final list = _pendingStrictRedirectByTabId[tab.id];
        if (list == null || list.isEmpty) {
          _pendingStrictRedirectByTabId.remove(tab.id);
          return;
        }
        final pending = list.removeAt(0);
        if (list.isEmpty) {
          _pendingStrictRedirectByTabId.remove(tab.id);
        }
        // Don't present while a redirect dialog from another source is up;
        // leave it queued and re-flush on the next activation.
        if (_strictRedirectDialogShowing) {
          _enqueuePendingStrictRedirect(
            tabId: tab.id,
            uri: pending.uri,
            title: pending.title,
            method: pending.method,
            sourcePageUrl: pending.sourcePageUrl,
            promptKey: pending.promptKey,
          );
          break;
        }
        await _presentStrictRedirectPrompt(
          tab: tab,
          uri: pending.uri,
          title: pending.title,
          method: pending.method,
          sourcePageUrl: pending.sourcePageUrl,
          promptKey: pending.promptKey,
        );
      }
    } finally {
      if (_flushingStrictRedirectTabId == tab.id) {
        _flushingStrictRedirectTabId = null;
      }
    }
  }

  Future<void> _presentStrictRedirectPrompt({
    required BrowserTab tab,
    required Uri uri,
    required String title,
    required String method,
    required String promptKey,
    String? sourcePageUrl,
  }) async {
    // Re-check visibility: user may have switched between enqueue and present.
    if (!mounted || !_tabs.contains(tab)) return;
    if (!widget.isShellVisible || !identical(tab, _activeTab)) {
      _enqueuePendingStrictRedirect(
        tabId: tab.id,
        uri: uri,
        title: title,
        method: method,
        sourcePageUrl: sourcePageUrl,
        promptKey: promptKey,
      );
      return;
    }
    if (_activeStrictRedirectPrompts.contains(promptKey)) return;
    // Global guard: if ANY redirect dialog is already up (different
    // promptKey — redirect chain A→B, or a new redirect arriving mid-
    // prompt), requeue instead of stacking a second dialog.
    if (_strictRedirectDialogShowing) {
      _enqueuePendingStrictRedirect(
        tabId: tab.id,
        uri: uri,
        title: title,
        method: method,
        sourcePageUrl: sourcePageUrl,
        promptKey: promptKey,
      );
      return;
    }

    final url = uri.toString();
    _activeStrictRedirectPrompts.add(promptKey);
    _strictRedirectDialogShowing = true;
    try {
      final sourceHost = Uri.tryParse(sourcePageUrl ?? '')?.host;
      final targetHost = uri.host.isNotEmpty ? uri.host : url;
      final decision = await showStrictRedirectPromptDialog(
        context: context,
        title: title,
        targetHost: targetHost,
        sourceHost: sourceHost,
      );
      if (!mounted || !_tabs.contains(tab)) return;

      // Actions always target the *source* tab, not whatever is active now.
      final tabIndex = _tabs.indexOf(tab);
      final insertAt = tabIndex >= 0 ? tabIndex + 1 : _activeTabIndex + 1;

      switch (decision) {
        case RedirectPromptAction.foreground:
        case RedirectPromptAction.background:
        case RedirectPromptAction.currentTab:
          // App schemes (tg:, intent://, …) always leave the WebView.
          if (isExternalAppUri(uri)) {
            unawaited(tab.controller.loadRequest(uri, addToHistory: false));
            break;
          }
          if (decision == RedirectPromptAction.foreground) {
            _tabLifecycleController.openNewTab(
              url: url,
              insertAtIndex: insertAt,
            );
          } else if (decision == RedirectPromptAction.background) {
            _tabLifecycleController.openNewTab(
              url: url,
              switchToTab: false,
              insertAtIndex: insertAt,
              buildImmediately: true,
            );
            _showSnack('Opened in background: $targetHost');
          } else {
            // Explicit allow so the invisible-redirect / ad-nav gate does not
            // re-prompt the same destination after the user confirmed.
            unawaited(tab.controller.allowNextCrossOriginNavigation(url));
            unawaited(_loadUrlWithHostSettings(tab, uri));
          }
          break;
        case RedirectPromptAction.alwaysBlock:
          // Persist a per-source-site block: future redirects from this
          // source host to the target are cancelled silently. The controller
          // enforces it (browser_controller.shouldOverrideUrlLoadingCallback);
          // settings persistence flows through onSettingsChanged.
          if (sourceHost != null && sourceHost.isNotEmpty) {
            final lowerSource = sourceHost.toLowerCase();
            final lowerTarget = targetHost.toLowerCase();
            final existing = Map<String, List<String>>.from(
              widget.settings.alwaysBlockedRedirectHosts,
            );
            final targets = List<String>.from(existing[lowerSource] ?? const []);
            if (!targets.contains(lowerTarget)) {
              targets.add(lowerTarget);
              existing[lowerSource] = targets;
              final updated = widget.settings
                  .copyWith(alwaysBlockedRedirectHosts: existing);
              widget.onSettingsChanged?.call(updated);
              // Apply to every tab immediately so the rule holds even before
              // settings propagate through the widget tree.
              for (final t in _tabs) {
                t.controller.setAlwaysBlockedRedirectHosts(existing);
              }
            }
            _showSnack(
              'Redirects from $sourceHost to $targetHost will always be blocked.',
            );
          }
          break;
        case RedirectPromptAction.ignore:
        case null:
          _showSnack('Ignored redirect to $targetHost');
          break;
      }
    } finally {
      _activeStrictRedirectPrompts.remove(promptKey);
      _strictRedirectDialogShowing = false;
    }
  }

  Future<void> _startElementPicker() async {
    await _elementPickerController.startPicker();
    _showPickerSnack(
      'Tap any ad or element to block it. Tap Stop when you are done.',
      onCancel: () => _cancelElementPicker(),
    );
  }

  Future<void> _cancelElementPicker({bool autoCancelled = false}) async {
    await _elementPickerController.cancelPicker(autoCancelled: autoCancelled);
    if (mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
    }
  }

  Future<void> _handlePickedElement(BrowserTab tab, String rawMessage) async {
    final previousSettings = widget.settings;
    final updatedSettings = await _elementPickerController.handlePickedElement(
      tab,
      rawMessage,
      widget.settings,
    );
    // Apply the new rule immediately so the user sees the element disappear.
    if (updatedSettings != null && mounted) {
      await tab.controller.configureAdBlock(
        enabled: widget.settings.adblockEnabled,
        popupBlockingEnabled: widget.settings.popupBlockingEnabled,
        filterSources: widget.settings.adblockFilterSources,
        manualRules: updatedSettings.manualAdBlockRules,
        cosmeticRules: updatedSettings.manualCosmeticRules,
      );
      // Same-host (cosmetic) rules only reach the page through the per-page
      // injection; without this the picked element stayed visible until a
      // reload. Re-inject so it disappears now.
      final url = await tab.controller.currentUrl();
      if (url != null && url.isNotEmpty) {
        await tab.controller.reapplyCosmeticRules(url);
      }
    }
    // Undo snackbar — only when a rule was actually applied. The controller
    // already surfaced specific reasons (already blocked / limit reached /
    // parse failure) with its own snackbar, so don't fake a success here.
    if (mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      if (updatedSettings == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Element blocked. Undo?'),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: 'Undo',
            // Explicit color so the Undo button is visible on any theme.
            textColor: Colors.lightBlueAccent,
            onPressed: () {
              widget.onSettingsChanged?.call(previousSettings);
              unawaited(
                tab.controller
                    .configureAdBlock(
                      enabled: widget.settings.adblockEnabled,
                      popupBlockingEnabled:
                          widget.settings.popupBlockingEnabled,
                      filterSources: widget.settings.adblockFilterSources,
                      manualRules: previousSettings.manualAdBlockRules,
                      cosmeticRules: previousSettings.manualCosmeticRules,
                    )
                    .then((_) async {
                      // Un-hide cosmetic elements now, not only after reload.
                      final undoUrl = await tab.controller.currentUrl();
                      if (undoUrl != null && undoUrl.isNotEmpty) {
                        await tab.controller.reapplyCosmeticRules(undoUrl);
                      }
                    }),
              );
            },
          ),
        ),
      );
    }
  }

  Future<void> _resetPageElementBlocks() =>
      _elementPickerController.resetPageElementBlocks(widget.settings);

  Future<void> _rescanPageMedia() async {
    await _activeTab.controller.rescanPage();
    // Clear the dedup cache so the DOM re-scan's postUrl calls are not
    // silently dropped as duplicates.
    _activeTab.snifferEngine.clearDedupOnly();
    // Re-enqueue HLS items for enrichment.  The hlsPlaylistCache still
    // holds the master playlist body, so the enricher can re-parse it
    // and regenerate variant items.
    _reEnrichHlsItems();
    _showSnack('Page re-scanned for media');
  }

  /// Fetches [url]'s HTML for the listing crawler. Tries the WebView's JS
  /// network stack first (rides the browser's WAF-bypass + cookies), then
  /// falls back to the native HttpURLConnection fetch (TLS fingerprint).
  ///
  /// The controller is captured from [tab] so a mid-crawl tab switch cannot
  /// swap the transport under the crawler.
  Future<String?> _fetchHtmlForCrawl(BrowserTab tab, String url) async {
    final viaWebView = await tab.controller.fetchViaJavaScript(url);
    if (viaWebView != null && viaWebView.isNotEmpty) return viaWebView;
    final native = await NetworkBindingService.fetchUrl(url);
    final body = native?['body'];
    return body is String && body.isNotEmpty ? body : null;
  }

  /// Crawls the active tab's page for every linked video and enqueues them
  /// all in one batch (Tools → "Download all on this page").
  ///
  /// Follows pagination on the listing page and fetches each detail page to
  /// find its real media URL, so a whole channel/tag/user page downloads in
  /// one tap instead of one-at-a-time.
  Future<void> _runListingBatchDownload() async {
    final tab = _activeTab;
    final listingUrl = tab.currentUrl ?? tab.addressController.text;
    if (listingUrl.isEmpty || !listingUrl.startsWith('http')) {
      _showSnack('No page URL to scan');
      return;
    }

    // --- Progress dialog with cancel ---
    var cancelled = false;
    final progressText = ValueNotifier<String>('Scanning page…');
    final dialogContext = context;
    if (dialogContext.mounted) {
      showDialog<void>(
        context: dialogContext,
        barrierDismissible: false,
        useRootNavigator: true,
        builder: (ctx) => ValueListenableBuilder<String>(
          valueListenable: progressText,
          builder: (ctx, text, _) {
            return AlertDialog(
              title: const Text('Download all on this page'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(text, style: const TextStyle(fontSize: 13)),
                  const SizedBox(height: 14),
                  const LinearProgressIndicator(),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    cancelled = true;
                  },
                  child: const Text('Cancel'),
                ),
              ],
            );
          },
        ),
      );
    }

    final crawler = ListingPageCrawler(
      fetchHtml: (url) => _fetchHtmlForCrawl(tab, url),
      isCancelled: () => cancelled,
      onProgress: (p) {
        progressText.value =
            'Page ${p.pagesScanned} scanned — ${p.totalMediaFound} video(s) found';
      },
    );

    final result = await crawler.crawlListing(listingUrl);

    // Close the progress dialog.
    progressText.dispose();
    if (dialogContext.mounted) {
      Navigator.of(dialogContext, rootNavigator: true).pop();
    }

    if (!mounted) return;

    if (result.cancelled) {
      _showSnack('Scan cancelled — nothing added');
      return;
    }
    if (result.media.isEmpty) {
      _showSnack('No videos found on this page or its linked pages');
      return;
    }

    // --- Free-taste gate, same as the capture sheet's batch download ---
    final tier = proUpsellEntitlement?.tier ?? EntitlementTier.free;
    final decision = await FreeTaste.evaluate(
      feature: ProFeature.batchCapture,
      tier: tier,
      actionSize: result.media.length,
    );
    if (!decision.allowed) {
      if (mounted) {
        unawaited(
          UpsellController.show(
            context,
            feature: ProFeature.batchCapture,
            userTier: tier,
          ),
        );
      }
      return;
    }

    var toEnqueue = result.media;
    if (decision.allowedCount != null &&
        decision.allowedCount! < result.media.length) {
      toEnqueue = result.media.take(decision.allowedCount!).toList();
      if (mounted) {
        unawaited(
          UpsellController.show(
            context,
            feature: ProFeature.batchCapture,
            userTier: tier,
          ),
        );
      }
    }

    // --- Enqueue all, skipping anything already queued ---
    var added = 0;
    var skipped = 0;
    for (final media in toEnqueue) {
      if (!mounted) break;
      if (RestrictedMediaPolicy.isBlocked(
        mediaUrl: media.url,
        sourcePageUrl: media.sourcePageUrl,
      )) {
        skipped++;
        continue;
      }
      if (_downloadQueue.urlExists(media.url)) {
        skipped++;
        continue;
      }
      final pageUri = Uri.tryParse(media.sourcePageUrl);
      await enqueueDirectDownload(
        context: context,
        tab: tab,
        url: media.url,
        suggestedFilename: media.pageTitle,
        downloadQueue: _downloadQueue,
        settings: widget.settings,
        baseDir: _baseDir,
        baseTemp: _baseTemp,
        getCookiesForUrl: _sniffIntakeController.getCookiesForUrl,
        showSnack: _showSnack,
        isMounted: () => mounted,
        ruleEngine: widget.ruleEngine,
        pageHost: pageUri?.host,
        silent: true,
      );
      if (_downloadQueue.urlExists(media.url)) {
        added++;
      } else {
        skipped++;
      }
    }

    if (!mounted) return;
    final summary = added > 0
        ? 'Added $added video(s) to the queue'
        : 'Nothing new to add';
    final skipNote = skipped > 0 ? ' ($skipped already queued)' : '';
    _showSnack('$summary$skipNote');
  }

  /// Re-enqueues HLS playlist items in the active tab's sniffer engine
  /// for enrichment.  The [MediaEnricher] checks [hlsPlaylistCache] first
  /// (which is preserved across navigations), so variants can be
  /// regenerated from the cached master playlist body without a new
  /// network request.
  void _reEnrichHlsItems() {
    final engine = _activeTab.snifferEngine;
    for (final item in engine.detectedMedia) {
      final uri = Uri.tryParse(item.url);
      if (uri == null || !uri.hasScheme) continue;
      final isHls =
          uri.path.toLowerCase().endsWith('.m3u8') ||
          (item.contentType?.toLowerCase().contains('mpegurl') ?? false);
      if (isHls) {
        engine.enricher.enqueue(item);
      }
    }
  }

  /// Returns true when [newUrl] points to a different logical page than
  /// [oldUrl] (different scheme, host, or path).  Same-URL reloads and
  /// query-only changes (e.g. analytics params) are NOT considered
  /// different pages, so the media cache is preserved.
  bool _isDifferentPage(String? oldUrl, String newUrl) {
    if (oldUrl == null || oldUrl.isEmpty) return true;
    final oldUri = Uri.tryParse(oldUrl);
    final newUri = Uri.tryParse(newUrl);
    if (oldUri == null || newUri == null) return oldUrl != newUrl;
    return oldUri.scheme != newUri.scheme ||
        oldUri.host != newUri.host ||
        oldUri.path != newUri.path;
  }

  String _tabLabel(BrowserTab tab) {
    final title = tab.title;
    if (title != null && title.trim().isNotEmpty) return title.trim();
    final raw = tab.addressController.text.trim();
    if (raw.isNotEmpty) {
      final uri = Uri.tryParse(raw);
      if (uri != null && uri.host.isNotEmpty) return uri.host;
      return raw;
    }
    return 'New Tab';
  }

  Widget _buildSuggestionPanel({required bool allowScroll}) {
    return AddressSuggestionPanel(
      suggestions: _addressSuggestions,
      onAccept: _acceptSuggestion,
      searchEngineName: widget.settings.searchEngine.name,
      allowScroll: allowScroll,
    );
  }

  Widget _buildTabStrip() {
    return TabStrip(
      tabs: _tabs,
      activeIndex: _activeTabIndex,
      isPrivateMode: _privateMode,
      onSwitch: _switchToActiveTab,
      onClose: _closeTab,
      onNewTab: () => _tabLifecycleController.openNewTab(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tab = _activeTab;

    // Top bar: only the find bar. Suggestions overlay the main Stack above
    // the bottom chrome (not inside the short bottom-bar Stack, which
    // previously clipped the panel to ~one row).
    final double topHeight = _findVisible ? 54.0 : 0.0;
    final screenH = MediaQuery.sizeOf(context).height;
    // Compact typeahead: a few rows above the chrome, not half the screen.
    final maxSuggestionH = screenH * 0.32;
    final rawSuggestionH = _addressSuggestions.isEmpty
        ? 0.0
        : _addressSuggestions.length * AddressSuggestionPanel.rowHeight + 8.0;
    final suggestionHeight = rawSuggestionH.clamp(0.0, maxSuggestionH);
    final suggestionNeedsScroll = rawSuggestionH > maxSuggestionH + 0.5;

    final topBar = AnimatedPositioned(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      top: _barsVisible ? 0 : -topHeight,
      left: 0,
      right: 0,
      height: topHeight,
      child: Material(
        elevation: 4,
        color: context.ac.overlay,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [if (_findVisible) _buildFindBar()],
        ),
      ),
    );

    // Bottom bar: tab strip + address bar + toolbar.
    // The suggestion panel is rendered as a Stack overlay above the address
    // bar pill, anchored to the bottom-bar container.
    const double tabStripHeight = 34.0;
    const double addressBarHeight = 48.0;
    const double toolbarHeight = 44.0;
    // Add padding for address bar vertical + toolbar natural height
    final double bottomHeight =
        tabStripHeight + addressBarHeight + toolbarHeight + 16;

    final bottomBar = AnimatedPositioned(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      bottom: _barsVisible ? 0 : -(bottomHeight + 20),
      left: 0,
      right: 0,
      height: bottomHeight,
      child: Material(
        elevation: 8,
        color: context.ac.dockSurface,
        child: Stack(
          children: [
            // The main bottom bar content (tab strip + address bar + toolbar)
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Tab carousel (compact pill strip)
                _buildTabStrip(),
                // Address bar pill
                Container(
                  height: addressBarHeight,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: context.ac.glassSurface,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: context.ac.glassBorder),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: Stack(
                        children: [
                          // Address pill: lock · text · star · reload/stop.
                          // Star = add/remove this page (Samsung-style).
                          // Bookmarks list icon lives on the primary strip
                          // (right of Radar). Keyboard Go submits the URL.
                          Row(
                            children: [
                              const SizedBox(width: 12),
                              GestureDetector(
                                onTap: () {
                                  final url = tab.currentUrl;
                                  if (url != null && url.isNotEmpty) {
                                    final host = Uri.tryParse(url)?.host ?? '';
                                    showDialog<bool>(
                                      context: context,
                                      builder: (ctx) => AlertDialog(
                                        title: const Text('Site Data'),
                                        content: Text(
                                          host.isNotEmpty
                                              ? 'Clear cookies, localStorage, and cache for $host?'
                                              : 'Clear cookies, localStorage, and cache for this site?',
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(ctx, false),
                                            child: const Text('Cancel'),
                                          ),
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(ctx, true),
                                            child: const Text(
                                              'Clear',
                                              style: TextStyle(
                                                color: Colors.red,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ).then((confirmed) {
                                      if (confirmed == true && mounted) {
                                        unawaited(_clearDataForSite(url));
                                      }
                                    });
                                  }
                                },
                                child: Icon(
                                  Icons.lock,
                                  size: 12,
                                  color: context.ac.textSecondary,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _addressExpanded
                                    ? TextField(
                                        key: const Key('sniffer_address_bar'),
                                        controller: tab.addressController,
                                        focusNode: _addressFocusNode,
                                        autofocus: true,
                                        decoration: const InputDecoration(
                                          isDense: true,
                                          hintText: 'Type a URL or search term',
                                          border: InputBorder.none,
                                          contentPadding: EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 8,
                                          ),
                                        ),
                                        keyboardType: TextInputType.url,
                                        textInputAction: TextInputAction.go,
                                        onSubmitted: _loadAddress,
                                      )
                                    : GestureDetector(
                                        key: const Key('browser_address_chip'),
                                        onTap: () {
                                          setState(
                                            () => _addressExpanded = true,
                                          );
                                          // Select all text and focus the field after
                                          // the TextField has been built in the current
                                          // frame so the user can immediately overwrite
                                          // the URL.
                                          WidgetsBinding.instance
                                              .addPostFrameCallback((_) {
                                                if (!mounted) return;
                                                tab
                                                    .addressController
                                                    .selection = TextSelection(
                                                  baseOffset: 0,
                                                  extentOffset: tab
                                                      .addressController
                                                      .text
                                                      .length,
                                                );
                                                _addressFocusNode
                                                    .requestFocus();
                                                // Seed suggestions for the current
                                                // text so the panel appears on open.
                                                _onAddressChanged();
                                              });
                                        },
                                        child: Container(
                                          height: 36,
                                          alignment: Alignment.centerLeft,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                          ),
                                          child: Text(
                                            _addressLabel().isEmpty
                                                ? 'Type a URL or search term'
                                                : _addressLabel(),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: context.ac.textPrimary,
                                              fontSize: 13,
                                            ),
                                          ),
                                        ),
                                      ),
                              ),
                              // Star: toggle favorite for the current page.
                              Builder(
                                builder: (context) {
                                  final starred = _isCurrentPageFavorited();
                                  return IconButton(
                                    key: const Key('browser_address_star_button'),
                                    tooltip: starred
                                        ? 'Remove bookmark'
                                        : 'Add bookmark',
                                    icon: Icon(
                                      starred
                                          ? Icons.star_rounded
                                          : Icons.star_border_rounded,
                                      size: 20,
                                      color: starred
                                          ? context.ac.accentAmber
                                          : context.ac.textSecondary,
                                    ),
                                    onPressed: _toggleFavorite,
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(
                                      minWidth: 36,
                                      minHeight: 36,
                                    ),
                                  );
                                },
                              ),
                              tab.isLoading
                                  ? IconButton(
                                      icon: const Icon(Icons.close, size: 18),
                                      onPressed: () => tab.controller.stop(),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(
                                        minWidth: 36,
                                        minHeight: 36,
                                      ),
                                    )
                                  : IconButton(
                                      key: const Key('sniffer_reload_button'),
                                      icon: const Icon(Icons.refresh, size: 18),
                                      onPressed: () => tab.controller.reload(),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(
                                        minWidth: 36,
                                        minHeight: 36,
                                      ),
                                    ),
                            ],
                          ),
                          Positioned(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            child: ValueListenableBuilder<int>(
                              valueListenable: _progressNotifier,
                              builder: (context, progress, _) {
                                if (!tab.isLoading || progress <= 0 || progress >= 100) {
                                  return const SizedBox.shrink();
                                }
                                return RepaintBoundary(
                                  child: LinearProgressIndicator(
                                    value: progress / 100.0,
                                    minHeight: 2,
                                    backgroundColor: Colors.transparent,
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // Unified bottom strip — browser nav + app nav in one row
                _buildConsolidatedStrip(tab, toolbarHeight),
              ],
            ),
          ],
        ),
      ),
    );

    // WebView is Positioned.fill so its layout NEVER changes when toolbars
    // hide/show — only the toolbars slide over it.  Previously AnimatedPositioned
    // resized the WebView (top/bottom changed), triggering expensive layout passes
    // on every scroll >5px → scroll jank.  Fix D.
    final webView = Positioned.fill(
      child: Stack(
        children: [
          // Lazy IndexedStack — only builds the active tab's WebView to avoid
          // creating N native Android WebViews simultaneously at launch.
          // Non-active tabs get a placeholder until first activated, then their
          // WebView stays alive across tab switches.
          // Until _loadTabsAndMedia finishes (_tabsLoaded == false), ALL tabs
          // show a placeholder so the default blank tab's WebView is never
          // created (it would be immediately disposed when saved tabs restore).
          Stack(
            children: _tabs.map((t) {
              final isActive = t.id == _activeTab.id;
              // In tests, the controller is a mock (not SnifferWebViewControllerImpl),
              // and the resulting BrowserWidget renders a cheap Container placeholder
              // instead of a real InAppWebView.  Always build mock WebViews immediately
              // so widget tests see their expected content.
              // For real WebViews, defer until _tabsLoaded so the default blank tab
              // never triggers an expensive native WebView creation.
              // _builtWebViewTabIds is maintained by _updateBuiltTabIds()
              // called from _switchToActiveTab, _loadTabsAndMedia, and
              // lifecycle methods — not mutated inside build().
              final shouldBuild = _builtWebViewTabIds.contains(t.id);
              // Seed first paint from address bar / committed URL so external
              // opens (Queue source page) navigate even if loadRequest races.
              // Restored cold-start tabs keep canSeedWebViewUrl false until
              // ensureTabStartupReady so we mount a blank WebView first.
              final seedUrl = () {
                if (!t.canSeedWebViewUrl) return null;
                final fromAddress = t.addressController.text.trim();
                if (fromAddress.isNotEmpty) return fromAddress;
                final fromCurrent = t.currentUrl?.trim();
                if (fromCurrent != null && fromCurrent.isNotEmpty) {
                  return fromCurrent;
                }
                return null;
              }();
              return Positioned.fill(
                child: RepaintBoundary(
                  child: Offstage(
                    offstage: !isActive,
                    child: shouldBuild
                        ? BrowserWidget(
                            key: ValueKey(t.id),
                            controller: t.controller,
                            initialUrl: seedUrl,
                            userAgent: t.userAgent ??
                                uaForProfile(widget.settings.userAgentProfile),
                            onSwipeForward: () {
                              // Forward navigation via right-edge swipe.
                              // No debounce needed — there is only one forward
                              // detector (the right-edge GestureDetector) now.
                              unawaited(t.controller.goForward());
                            },
                            onRefresh: () => t.controller.reload(),
                          )
                        : const SizedBox.shrink(),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );

    return PopScope(
      canPop: !_elementPickerActive,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _elementPickerActive) {
          _cancelElementPicker();
        }
      },
      child: Scaffold(
        key: _scaffoldKey,
        body: SafeArea(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              webView,
              // IDM-style floating play control over the largest <video>
              // (or bottom-right of the page when no rect yet).
              if (_shouldShowFloatingPlayerButton)
                _buildFloatingPlayerOverlay(toolbarHeight),
              topBar,
              bottomBar,
              // Compact typeahead above the bottom chrome.
              if (_addressExpanded &&
                  _addressSuggestions.isNotEmpty &&
                  suggestionHeight > 0)
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: _barsVisible ? bottomHeight + 4 : 8,
                  height: suggestionHeight,
                  child: Material(
                    elevation: 16,
                    shadowColor: Colors.black54,
                    color: context.ac.overlay,
                    borderRadius: BorderRadius.circular(16),
                    clipBehavior: Clip.antiAlias,
                    child: _buildSuggestionPanel(
                      allowScroll: suggestionNeedsScroll,
                    ),
                  ),
                ),
              if (_elementPickerActive) _buildPickerCancelButton(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPickerCancelButton() {
    return Positioned(
      top: 12,
      left: 0,
      right: 0,
      child: Center(
        child: PickerCancelChip(
          key: const Key('cancel_picker_button'),
          onCancel: () => _cancelElementPicker(),
        ),
      ),
    );
  }

  /// Samsung-shape primary strip:
  /// Back · Forward · Queue · Radar · Bookmarks menu · Tabs · Menu.
  /// Star (add/remove this page) is on the address bar.
  Widget _buildConsolidatedStrip(BrowserTab tab, double height) {
    final badge = tab.snifferEngine.detectedMedia.length;
    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 2, 4, 4),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: context.ac.overlaySurface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: context.ac.borderStrong),
          ),
          child: BrowserPrimaryBar(
            tab: tab,
            sniffedBadgeCount: badge,
            onSniffer: _showSniffedMediaSheet,
            onTabs: _showTabsSheet,
            onMenu: _showBrowserOverflowPopup,
            onQueue: widget.onOpenQueue,
            onBookmarksMenu: _showFavoritesSheet,
            menuKey: widget.menuKey,
            snifferKey: widget.snifferKey,
            tabsKey: widget.tabsKey,
          ),
        ),
      ),
    );
  }

  /// Popup that shows the current adblock state for the active tab and lets
  /// the user add/remove the current host from the per-site allowlist.
  void _showAdblockPopup(BrowserTab tab) {
    final settings = widget.settings;
    final host = Uri.tryParse(tab.currentUrl ?? '')?.host ?? '';
    if (host.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Open a page first to adjust adblock settings.')));
      return;
    }
    final isAllowlisted = settings.adblockAllowlist.contains(host);
    final blocked = tab.controller.blockedRequestCount;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.shield, color: Colors.green),
            const SizedBox(width: 8),
            const Text('Adblock on this site'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(host, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              settings.adblockEnabled
                  ? (isAllowlisted
                        ? 'Adblock is paused — ads may show on this site.'
                        : 'Adblock is protecting this page.')
                  : 'Adblock is turned off globally.',
            ),
            const SizedBox(height: 4),
            Text('Blocked $blocked requests on this page'),
            const Divider(),
            SwitchListTile(
              title: Text(
                isAllowlisted ? 'Resume adblock on $host' : 'Pause adblock on $host',
              ),
              subtitle: Text(
                isAllowlisted
                    ? 'Block ads and trackers on this site again.'
                    : 'Let this site show ads. Use this when a page breaks because adblock blocked something it needs.',
              ),
              value: !isAllowlisted,
              contentPadding: EdgeInsets.zero,
              onChanged: (v) {
                final List<String> updated = v
                    ? settings.adblockAllowlist.where((h) => h != host).toList()
                    : [...settings.adblockAllowlist, host];
                final newSettings = settings.copyWith(
                  adblockAllowlist: updated,
                );
                widget.onSettingsChanged?.call(newSettings);
                tab.controller.updateAdblockAllowlist(updated);
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  // ARCHIVED: The bottom download queue strip was here (removed 2026-06-27).

  String _addressLabel() => _addressBarController.addressLabel(_activeTab);

  Widget _buildFindBar() {
    return FindInPageBar(
      controller: _findController,
      matchCount: _findMatchCount,
      currentMatch: _findCurrentMatch,
      onQueryChanged: (value) {
        unawaited(_updateFindCount(value));
      },
      onFindNext: () => _findNext(true),
      onFindPrevious: () => _findNext(false),
      onClose: _dismissFind,
    );
  }

  void _showElementContextMenu(String rawMessage) => showElementContextMenu(
    context,
    rawMessage,
    activeTab: _activeTab,
    isContextMenuShowing: _isContextMenuShowing,
    onContextMenuShowingChanged: (value) {
      if (_isContextMenuShowing != value) {
        setState(() {
          _isContextMenuShowing = value;
        });
      }
    },
    onHandlePickedElement: (message) =>
        _handlePickedElement(_activeTab, message),
    onCopyText: (value, message) => _copyText(value, message),
    onOpenNewTab: ({String? url, bool switchToTab = true}) {
      // Background opens insert right after the current tab.
      final insertAtIndex = !switchToTab ? _activeTabIndex + 1 : null;
      _tabLifecycleController.openNewTab(
        url: url,
        switchToTab: switchToTab,
        insertAtIndex: insertAtIndex,
      );
    },
    onCopyCurrentUrl: _copyCurrentUrl,
    onToggleFavorite: _toggleFavorite,
    onSaveCurrentPage: _saveCurrentPage,
    onShowSnack: _showSnack,
    onLoadUrl: (uri) => _loadUrlWithHostSettings(_activeTab, uri),
    onAddToQueue: (targetUrl, label) =>
        _addContextTargetToQueue(targetUrl, label),
    onTranslateText: _translateSelectedText,
    onSearchText: _searchSelectedText,
    isCurrentPageFavorited: _isCurrentPageFavorited(),
    isMounted: mounted,
  );

  Future<void> _copyText(String value, String message) async {
    await Clipboard.setData(ClipboardData(text: value));
    _showSnack(message);
  }

  void _addContextTargetToQueue(String targetUrl, String? label) =>
      addContextTargetToQueue(
        context,
        targetUrl,
        label,
        activeTab: _activeTab,
        baseDir: _baseDir,
        baseTemp: _baseTemp,
        downloadFilenameFor: _downloadFilenameFor,
        getCookiesForUrl: _sniffIntakeController.getCookiesForUrl,
        downloadQueue: _downloadQueue,
        showDuplicatePrompt: _showDuplicatePrompt,
        showSnack: _showSnack,
        isMounted: mounted,
      );

  /// Wire live WebView bridges onto [task] (cookies, JS fetch, token refresh).
  /// Called by [DownloadQueue.browserContextAttacher] before every start/retry
  /// so queue rows restored from JSON after app restart regain WAF bypass.
  void _attachBrowserContextToTask(DownloadTask task) {
    if (_tabs.isEmpty) return;
    final tab = _findTabForTask(task) ?? _activeTab;


    // Same playlist body path as MediaEnricher/sniffer (not generic
    // fetchViaJavaScript — that path was returning null/network error while
    // fetchPlaylistBodyViaJavaScript still got real #EXTM3U from missav tabs).
    task.fetchViaWebView = (fetchUrl, {Map<String, String>? headers}) =>
        tab.controller.fetchPlaylistBodyViaJavaScript(fetchUrl);
    task.fetchBinaryViaWebView =
        (binaryUrl) => tab.controller.fetchBinaryViaJavaScript(binaryUrl);
    task.hlsPlaylistCache =
        (cacheUrl) => lookupHlsPlaylistCache(tab.hlsPlaylistCache, cacheUrl);
    task.cookieProvider =
        (url) => tab.controller.getCookiesForDomain(url: url);
    task.onTokenExpired = TokenRefreshService.gatedClosure(
      task,
      ({bool forceReload = false}) => TokenRefreshService.refresh(task),
    );
  }

  /// Prefer a tab whose address matches the task's source page host.
  BrowserTab? _findTabForTask(DownloadTask task) {
    final src = task.sourcePageUrl ?? task.url;
    final host = Uri.tryParse(src)?.host.toLowerCase();
    if (host == null || host.isEmpty) return null;
    for (final tab in _tabs) {
      final tabHost =
          Uri.tryParse(tab.addressController.text)?.host.toLowerCase();
      if (tabHost != null &&
          (tabHost == host ||
              tabHost.endsWith('.$host') ||
              host.endsWith('.$tabHost'))) {
        return tab;
      }
    }
    return null;
  }

  Future<String?> _reloadForFreshUrl(
    BrowserTab tab,
    String? sourcePageUrl, {
    bool forceReload = false,
  }) async {
    // Strategy 1: Query the current page's DOM for any .m3u8 URL
    // (no reload needed — works for sites where the player refreshed its
    // manifest but our captured URL is stale).
    if (!forceReload) {
      final fromCurrent = await _queryHlsFromPage(tab);
      if (fromCurrent != null) return fromCurrent;
    }

    // Strategy 2: Headless page resniff — navigates to the source page in
    // an invisible WebView, queries its DOM for a fresh playlist URL, and
    // disposes itself.  Never touches the user's visible tab.
    final srcUrl = sourcePageUrl ?? tab.addressController.text;
    if (srcUrl.startsWith('http')) {
      final resniffer = HeadlessPageResniffer();
      final fromHeadless = await resniffer.resniff(
        srcUrl,
        mustMatchPathOf: tab.currentUrl,
      );
      if (fromHeadless != null) return fromHeadless;
    }

    // Strategy 3: Wait for the sniffer's MediaSnifferDataChannel handler
    // (in case the page's JS sets the src after a longer delay).
    try {
      final media = await tab.snifferEngine.onMediaDetected
          .firstWhere((m) =>
              m.url.contains('.m3u8') &&
              !m.url.contains('ping.m3u8') &&
              !m.url.contains('/ping'))
          .timeout(const Duration(seconds: 10));
      return media.url;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _queryHlsFromPage(BrowserTab tab) async {
    try {
      final result = await tab.controller.evaluateJavaScript(kHlsDomQueryJs);
      if (result is String &&
          result.isNotEmpty &&
          result.contains('.m3u8') &&
          !result.contains('ping.m3u8') &&
          !result.contains('/ping')) {
        return result;
      }
    } catch (_) {}
    return null;
  }

  String _downloadFilenameFor(String? label, String targetUrl) {
    return FilenameService.downloadFilenameFor(
      label: label,
      targetUrl: targetUrl,
      includeQualitySuffix: widget.settings.includeQualitySuffix,
    );
  }

  Future<void> _toggleFavorite() async {
    final tab = _activeTab;
    final url = await tab.controller.currentUrl();
    if (url == null || url.isEmpty || url.startsWith('file:')) return;
    if (!mounted) return;
    final existing = _library.favorites.where(
      (favorite) => favorite.url == url,
    );
    if (existing.isNotEmpty) {
      await _saveLibrary(
        _library.copyWith(
          favorites: _library.favorites
              .where((favorite) => favorite.url != url)
              .toList(growable: false),
        ),
      );
      if (mounted) _showSnack('Bookmark removed.');
      return;
    }

    final title = cleanTitle(await tab.controller.pageTitle(), url);
    if (!mounted) return;
    final selection = await _promptFavoriteFolder();
    if (selection == null || !mounted) return;
    final favorite = BrowserFavorite(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: title,
      url: url,
      createdAt: DateTime.now(),
      folderId: selection.folderId,
      tags: selection.tags,
    );
    await _saveLibrary(
      _library.copyWith(
        favorites: [favorite, ..._library.favorites],
        folders: selection.updatedFolders ?? _library.folders,
      ),
    );
    if (mounted) {
      _showSnack(
        selection.folderId == null
            ? 'Favorite added.'
            : 'Favorite added to ${selection.folderName ?? 'folder'}.',
      );
    }
  }

  Future<FavoriteSelection?> _promptFavoriteFolder() async {
    return showPromptFavoriteFolderDialog(
      context: context,
      folders: _library.folders,
    );
  }

  Future<void> _saveCurrentPage() async {
    final tab = _activeTab;
    final url = await tab.controller.currentUrl();
    if (url == null || url.isEmpty || url.startsWith('file:')) return;
    setState(() => _isSavingPage = true);
    try {
      final title = cleanTitle(await tab.controller.pageTitle(), url);
      // Chunked capture: pulling outerHTML through a single evaluateJavascript
      // freezes the tab on real pages (multi-MB platform-channel message).
      final htmlRaw = await tab.controller.capturePageHtml();
      if (htmlRaw == null) {
        _showSnack('Could not save this page: page too large or unreadable.');
        return;
      }
      final html = _injectBaseTag(htmlRaw, url);
      final id = DateTime.now().microsecondsSinceEpoch.toString();
      final dir = await widget.libraryStore.savedPagesDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}$id.html');
      await file.writeAsString(html);
      final savedPage = SavedPage(
        id: id,
        title: title,
        sourceUrl: url,
        localPath: file.path,
        savedAt: DateTime.now(),
      );
      await _saveLibrary(
        _library.copyWith(savedPages: [savedPage, ..._library.savedPages]),
      );
      _showSnack('Page saved offline.');
    } catch (error) {
      _showSnack('Could not save this page: $error');
    } finally {
      if (mounted) setState(() => _isSavingPage = false);
    }
  }

  Future<void> _copyCurrentUrl({String message = 'URL copied.'}) async {
    final url = await _activeTab.controller.currentUrl();
    if (url == null || url.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: url));
    _showSnack(message);
  }

  double _effectiveZoomFor(String host) {
    return widget.settings.siteZoomLevels[host.toLowerCase()] ?? 1.0;
  }

  String? _effectiveUserAgentFor(String host) {
    final mapped = widget.settings.siteUserAgents[host.toLowerCase()];
    if (mapped != null && mapped.isNotEmpty) return mapped;
    // If desktopMode is true (legacy setting) use desktop Chrome UA.
    if (_desktopMode) return uaForProfile('desktop_chrome');
    // Otherwise, respect the full profile when there is no per-site override.
    final profile = widget.settings.userAgentProfile;
    if (profile != 'mobile') return uaForProfile(profile);
    return null;
  }

  Map<String, String> _baseRequestHeaders() {
    if (!widget.settings.doNotTrackEnabled) return const {};
    return const {'DNT': '1', 'Sec-GPC': '1'};
  }

  BookmarkFolder get _unsortedFolder => BookmarkFolder(
    id: '__unsorted__',
    name: 'Unsorted',
    createdAt: DateTime.fromMillisecondsSinceEpoch(0),
  );

  void _showFavoritesSheet() => showFavoritesSheet(
    context,
    activeTab: _activeTab,
    library: _library,
    unsortedFolder: _unsortedFolder,
    isCurrentPageFavorited: (_) => _isCurrentPageFavorited(),
    onSaveLibrary: _saveLibrary,
    onLoadUrl: (url) => _loadUrlWithHostSettings(_activeTab, Uri.parse(url)),
    onFavoriteToggled: () => setState(() {}),
    onNewFolderCreated: () async {
      if (mounted) {
        setState(() {});
      }
    },
    onEditFavorite: (favorite) => _editFavoriteFolder(favorite),
    onPlayVideo: (favorite) => _playLibraryVideo(
      url: favorite.url,
      title: favorite.title,
      sourcePageUrl: favorite.sourcePageUrl,
      thumbnailUrl: favorite.thumbnailUrl,
    ),
  );

  /// Replays a video stored in Favorites or History.
  ///
  /// The stored URL is a CDN link that has very likely expired, so this goes
  /// through the normal preview path — which re-resolves cookies and Referer
  /// from the tab — rather than handing the raw URL straight to the player.
  Future<void> _playLibraryVideo({
    required String url,
    required String title,
    String? sourcePageUrl,
    String? thumbnailUrl,
  }) async {
    final media = SniffedMedia(
      url: url,
      name: title,
      type: MediaType.video,
      sourcePageUrl: sourcePageUrl,
      pageTitle: title,
      thumbnailUrl: thumbnailUrl,
      sniffSource: SniffSource.session,
    );
    await _showMediaPreview(media);
  }

  Future<BrowserLibrary?> _editFavoriteFolder(BrowserFavorite favorite) async {
    final edit = await showEditFavoriteDialog(
      context: context,
      favorite: favorite,
      folders: _library.folders,
    );
    if (edit == null) return null;
    final updatedLib = applyFavoriteEdit(_library, favorite, edit);
    await _saveLibrary(updatedLib);
    return updatedLib;
  }

  void _showSavedPagesSheet() => showSavedPagesSheet(
    context,
    activeTab: _activeTab,
    library: _library,
    onSaveLibrary: _saveLibrary,
    onLoadUrl: (url) => _loadUrlWithHostSettings(_activeTab, Uri.parse(url)),
    onSaveCurrentPage: _saveCurrentPage,
    onReopen: () => _showSavedPagesSheet(),
  );

  /// Closes the Menu (⋯) dialog if it is currently showing.
  void _dismissBrowserOverflowPopup() {
    if (!_browserOverflowOpen || !mounted) return;
    Navigator.of(context, rootNavigator: true).maybePop();
  }

  void _showBrowserOverflowPopup() {
    // One instance only — re-tap while open dismisses instead of stacking.
    if (_browserOverflowOpen) {
      _dismissBrowserOverflowPopup();
      return;
    }
    if (!widget.isShellVisible) return;

    final settings = widget.settings;
    final host = Uri.tryParse(_activeTab.currentUrl ?? '')?.host ?? '';
    final isAllowlisted =
        host.isNotEmpty && settings.adblockAllowlist.contains(host);
    final ac = context.ac;
    final pageUrl = _activeTab.currentUrl;
    final pageTitle = _activeTab.title;

    Future<void> openSection(SettingsSection section) async {
      // Remember Settings segment for the next intentional open; do not
      // auto-reopen the menu after the settings page closes.
      OverflowMenuSegmentStore.last = OverflowMenuSegment.settings;
      final handler = widget.onOpenSettingsSection;
      if (handler != null) {
        await handler(section);
      } else {
        widget.onOpenSettings?.call();
      }
    }

    final l = AppLocalizations.of(context);

    // NOTE: When adding or updating a Settings entry, update both settings_page.dart (_buildSettingsHub) and sniffer_screen.dart (rawSettingsEntries).
    final rawSettingsEntries = [
      // 1. Downloads & Core Behavior
      OverflowMenuEntry(
        icon: Icons.download_rounded,
        label: l?.menuDefaults ?? 'Defaults',
        onTap: () => unawaited(openSection(SettingsSection.defaults)),
      ),
      OverflowMenuEntry(
        icon: Icons.wifi_rounded,
        label: l?.menuNetwork ?? 'Network',
        onTap: () => unawaited(openSection(SettingsSection.network)),
      ),
      OverflowMenuEntry(
        icon: Icons.rule_rounded,
        label: l?.menuRules ?? 'Rules',
        onTap: () => unawaited(openSection(SettingsSection.rules)),
      ),
      OverflowMenuEntry(
        icon: Icons.schedule_rounded,
        label: l?.menuSchedule ?? 'Schedule',
        onTap: () => unawaited(openSection(SettingsSection.schedule)),
      ),
      // 2. Security, Privacy & Sniffing
      OverflowMenuEntry(
        icon: Icons.shield_rounded,
        label: l?.menuAdblock ?? 'Adblock',
        onTap: () => unawaited(openSection(SettingsSection.adblock)),
      ),
      OverflowMenuEntry(
        icon: Icons.search_rounded,
        label: l?.menuSearchPrivacy ?? 'Search & Privacy',
        onTap: () => unawaited(openSection(SettingsSection.search)),
      ),
      OverflowMenuEntry(
        icon: Icons.tune_rounded,
        label: l?.menuSniffer ?? 'Sniffer',
        onTap: () => unawaited(openSection(SettingsSection.sniffer)),
      ),
      // 3. Customization & Profiles
      OverflowMenuEntry(
        icon: Icons.palette_outlined,
        label: l?.menuTheme ?? 'Theme',
        onTap: () => unawaited(openSection(SettingsSection.appearance)),
      ),
      OverflowMenuEntry(
        icon: Icons.people_outline_rounded,
        label: l?.menuProfiles ?? 'Profiles',
        onTap: () => unawaited(openSection(SettingsSection.profiles)),
      ),
      OverflowMenuEntry(
        icon: Icons.open_in_new_rounded,
        label: l?.menuExternalApps ?? 'External apps',
        onTap: () => unawaited(openSection(SettingsSection.externalApps)),
      ),
      // 4. Sync & Backup
      OverflowMenuEntry(
        icon: Icons.backup_rounded,
        label: l?.menuBackup ?? 'Backup',
        onTap: () => unawaited(openSection(SettingsSection.backup)),
      ),
      if (kDriveSyncEnabled)
        OverflowMenuEntry(
          icon: Icons.cloud_outlined,
          label: l?.menuGoogleDrive ?? 'Google Drive',
          onTap: () => unawaited(openSection(SettingsSection.drive)),
        ),
      OverflowMenuEntry(
        icon: Icons.cloud_outlined,
        label: l?.menuWebdavBackup ?? 'WebDAV Backup',
        onTap: () => unawaited(openSection(SettingsSection.webdav)),
      ),
      OverflowMenuEntry(
        icon: Icons.shield_outlined,
        label: l?.menuPrivateVault ?? 'Private Vault',
        onTap: () => unawaited(openSection(SettingsSection.vault)),
      ),
      // 5. Advanced & Automation
      OverflowMenuEntry(
        icon: Icons.auto_awesome,
        label: l?.menuProUltra ?? 'Aurora Pro & Ultra',
        color: ac.accentAmber,
        onTap: () => unawaited(openSection(SettingsSection.pro)),
      ),
      OverflowMenuEntry(
        icon: Icons.rss_feed,
        label: l?.menuWatcher ?? 'Aurora Watcher',
        onTap: () => unawaited(openSection(SettingsSection.watcher)),
      ),
      OverflowMenuEntry(
        icon: Icons.api,
        label: l?.menuAutomationApi ?? 'Automation API',
        onTap: () => unawaited(openSection(SettingsSection.automation)),
      ),
      // 6. Help & Info
      OverflowMenuEntry(
        icon: Icons.menu_book_rounded,
        label: l?.menuUserGuide ?? 'User Guide',
        color: ac.accentFrost,
        onTap: () => unawaited(openSection(SettingsSection.userGuide)),
      ),
      OverflowMenuEntry(
        icon: Icons.info_outline_rounded,
        label: l?.menuAbout ?? 'About',
        onTap: () => unawaited(openSection(SettingsSection.about)),
      ),
    ];

    final rawToolEntries = [
      OverflowMenuEntry(
        icon: settings.cloudflareStealthEnabled
            ? Icons.security_rounded
            : Icons.security_outlined,
        label: settings.cloudflareStealthEnabled
            ? (l?.toolStealthOn ?? 'Stealth Mode: On')
            : (l?.toolStealthOff ?? 'Stealth Mode: Off'),
        color: settings.cloudflareStealthEnabled
            ? ac.accentFrost
            : ac.textPrimary,
        onTap: _toggleStealthMode,
      ),
      OverflowMenuEntry(
        icon: _privateMode ? Icons.security_rounded : Icons.shield_outlined,
        label: _privateMode
            ? (l?.toolIncognitoOn ?? 'Incognito: On')
            : (l?.toolIncognitoOff ?? 'Incognito: Off'),
        color: _privateMode ? Colors.purpleAccent : ac.textPrimary,
        onTap: _toggleIncognitoMode,
      ),
      OverflowMenuEntry(
        icon: Icons.tab_rounded,
        label: l?.toolCustomTab ?? 'Open in Custom Tab',
        color: ac.accentFrost,
        onTap: () {
          final url = _activeTab.currentUrl;
          if (url != null && url.isNotEmpty) {
            unawaited(CctBrowser.openCustomTab(url));
          }
        },
      ),
      OverflowMenuEntry(
        icon: Icons.history_rounded,
        label: l?.toolHistory ?? 'History',
        onTap: _showHistorySheet,
      ),
      OverflowMenuEntry(
        icon: Icons.star_rounded,
        label: l?.toolFavorites ?? 'Favorites',
        color: ac.accentAmber,
        onTap: _showFavoritesSheet,
      ),
      OverflowMenuEntry(
        icon: Icons.offline_pin_rounded,
        label: l?.toolSavedPages ?? 'Saved pages',
        onTap: _showSavedPagesSheet,
      ),
      OverflowMenuEntry(
        icon: Icons.save_alt_rounded,
        label: l?.toolSavePage ?? 'Save page',
        onTap: () => unawaited(_saveCurrentPage()),
      ),
      OverflowMenuEntry(
        icon: Icons.find_in_page_rounded,
        label: l?.toolFindOnPage ?? 'Find on page',
        onTap: () => setState(() => _findVisible = true),
      ),
      OverflowMenuEntry(
        icon: Icons.assignment_ind_rounded,
        label: l?.toolAutofill ?? 'Autofill',
        onTap: () => unawaited(_showAutofillMenu()),
      ),
      OverflowMenuEntry(
        icon: Icons.chrome_reader_mode_rounded,
        label: l?.toolReaderMode ?? 'Reader mode',
        onTap: () => unawaited(_showReaderMode()),
      ),
      OverflowMenuEntry(
        icon: !settings.adblockEnabled
            ? Icons.shield
            : (isAllowlisted ? Icons.shield_outlined : Icons.shield),
        label: !settings.adblockEnabled
            ? (l?.toolAdblockOff ?? 'Adblock: Off')
            : (isAllowlisted
                ? (l?.toolAdsAllowed ?? 'Ads allowed')
                : (l?.toolAdblockOn ?? 'Adblock: On')),
        color: !settings.adblockEnabled
            ? Colors.redAccent
            : (isAllowlisted ? ac.textSecondary : Colors.green),
        onTap: () => _showAdblockPopup(_activeTab),
      ),
      OverflowMenuEntry(
        icon: Icons.ads_click,
        label: l?.toolBlockElement ?? 'Block element',
        onTap: () => unawaited(_startElementPicker()),
      ),
      OverflowMenuEntry(
        icon: Icons.undo,
        label: l?.toolResetBlocks ?? 'Reset blocks',
        onTap: _resetPageElementBlocks,
      ),
      OverflowMenuEntry(
        icon: Icons.refresh_rounded,
        label: l?.toolRescanMedia ?? 'Re-scan media',
        onTap: () => unawaited(_rescanPageMedia()),
      ),
      OverflowMenuEntry(
        icon: Icons.playlist_add_rounded,
        label: l?.toolBatchDownload ?? 'Download all on this page',
        color: ac.accentFrost,
        onTap: () => unawaited(_runListingBatchDownload()),
      ),
      OverflowMenuEntry(
        icon: Icons.cookie_rounded,
        label: l?.toolClearCookies ?? 'Clear cookies',
        color: Colors.redAccent,
        onTap: () {
          unawaited(
            _activeTab.controller.currentUrl().then((url) {
              if (url != null && url.isNotEmpty) {
                unawaited(_clearDataForSite(url));
              }
            }),
          );
        },
      ),
    ];

    _browserOverflowOpen = true;
    unawaited(
      showBrowserOverflowPopup(
        context,
        pageTitle: pageTitle,
        pageUrl: pageUrl,
        settingsEntries: _sortOverflowEntries(
          rawSettingsEntries,
          settings.menuSettingsOrder,
        ),
        toolEntries: _sortOverflowEntries(
          rawToolEntries,
          settings.menuToolOrder,
        ),
        onReorderSettings: (newOrder) {
          final normalizedOrder = newOrder.map(_menuEntryKey).toList();
          widget.onSettingsChanged?.call(
            widget.settings.copyWith(menuSettingsOrder: normalizedOrder),
          );
        },
        onReorderTools: (newOrder) {
          final normalizedOrder = newOrder.map(_menuEntryKey).toList();
          widget.onSettingsChanged?.call(
            widget.settings.copyWith(menuToolOrder: normalizedOrder),
          );
        },
      ).whenComplete(() {
        _browserOverflowOpen = false;
      }),
    );
  }

  String _menuEntryKey(String label) => SnifferScreen.normalizeMenuEntryKey(label);

  List<OverflowMenuEntry> _sortOverflowEntries(
    List<OverflowMenuEntry> entries,
    List<String> order,
  ) {
    if (order.isEmpty) return entries;
    final sorted = <OverflowMenuEntry>[];
    final map = <String, OverflowMenuEntry>{};
    for (final e in entries) {
      final key = _menuEntryKey(e.label);
      map[key] = e;
    }
    for (final key in order) {
      final normKey = _menuEntryKey(key);
      final entry = map.remove(normKey);
      if (entry != null) {
        sorted.add(entry);
      }
    }
    sorted.addAll(map.values);
    return sorted;
  }

  void _toggleIncognitoMode() {
    final nextState = !_privateMode;
    setState(() {
      _privateMode = nextState;
    });
    for (final tab in _tabs) {
      unawaited(tab.controller.setIncognito(nextState));
    }
    final updated = widget.settings.copyWith(privateMode: nextState);
    widget.onSettingsChanged?.call(updated);
  }

  void _toggleStealthMode() {
    final nextState = !widget.settings.cloudflareStealthEnabled;
    final updated = widget.settings.copyWith(cloudflareStealthEnabled: nextState);
    widget.onSettingsChanged?.call(updated);
    for (final tab in _tabs) {
      unawaited(tab.controller.setCloudflareStealthEnabled(nextState));
    }
    AuroraSnackbar.show(
      context,
      nextState
          ? 'Cloudflare Stealth Mode: ON'
          : 'Cloudflare Stealth Mode: OFF',
    );
    unawaited(_activeTab.controller.reload());
  }

  void _showHistorySheet() => showHistorySheet(
    context,
    activeTab: _activeTab,
    library: _library,
    onSaveLibrary: _saveLibrary,
    onLoadUrl: (url) => _loadUrlWithHostSettings(_activeTab, Uri.parse(url)),
    onOpenUrlsInNewTabs: (urls) async {
      // Open each URL in its own background tab without switching away
      // from the current tab.
      for (final url in urls) {
        _openNewTab(url: url, switchToTab: false);
      }
    },
    onPlayVideo: (entry) => _playLibraryVideo(
      url: entry.url,
      title: entry.title,
      sourcePageUrl: entry.sourcePageUrl,
      thumbnailUrl: entry.thumbnailUrl,
    ),
  );

  /// Opens the Aurora player with CDN-aware cookies/headers. When multiple
  /// HLS variants are available (from the enricher, capture group, or a live
  /// master fetch), they are passed into the player for an in-UI quality picker.
  Future<void> _openVideoPlayer(
    SniffedMedia media, {
    List<SniffedMedia> groupVariants = const [],
  }) async {
    final qualities = await _resolvePlaybackQualities(
      media,
      groupVariants: groupVariants,
    );
    final start = pickStartQuality(media, qualities);
    if (!mounted) return;
    await _showMediaPreview(start, qualityVariants: qualities);
  }

  /// Collects alternate renditions for [media]: capture-group siblings,
  /// enricher siblings, then a live master-playlist fetch (same path as
  /// the download dialog).
  Future<List<SniffedMedia>> _resolvePlaybackQualities(
    SniffedMedia media, {
    List<SniffedMedia> groupVariants = const [],
  }) async {
    final detected = _activeTab.snifferEngine.detectedMedia;
    final lower = media.url.toLowerCase();
    final looksHls =
        lower.contains('.m3u8') || lower.contains('mpegurl') || isPlaylistPathHint(
          Uri.tryParse(media.url)?.path.toLowerCase() ?? '',
        );

    // Capture-group siblings (progressive multi-quality rows).
    final fromGroup = groupVariants
        .where(
          (m) =>
              m.type == MediaType.video ||
              m.type == MediaType.playlist ||
              m.type == MediaType.audio,
        )
        .toList();
    if (fromGroup.length >= 2) {
      return sortQualityMedia(fromGroup);
    }

    List<SniffedMedia> fromDetected(String master) {
      return detected
          .where(
            (m) =>
                m.masterUrl == master &&
                (m.type == MediaType.video ||
                    m.type == MediaType.playlist ||
                    m.type == MediaType.audio),
          )
          .toList();
    }

    // Case 1: [media] is a variant — gather siblings under the same master.
    final masterUrl = media.masterUrl;
    if (masterUrl != null && masterUrl.isNotEmpty) {
      final siblings = fromDetected(masterUrl);
      if (siblings.length >= 2) {
        return sortQualityMedia(siblings);
      }
    }

    // Case 2: [media] is the master — children already expanded by enricher.
    final children = fromDetected(media.url);
    if (children.length >= 2) {
      return sortQualityMedia(children);
    }

    // Case 3: Live-fetch the master (or this URL) for variants. Reuses the
    // download-dialog path (cache → Dart HTTP → WebView JS → native).
    if (looksHls || (masterUrl != null && masterUrl.isNotEmpty)) {
      final candidates = <String>[
        if (masterUrl != null && masterUrl.isNotEmpty) masterUrl,
        media.url,
        ...children.map((c) => c.masterUrl).whereType<String>(),
        ...fromGroup.map((c) => c.masterUrl).whereType<String>(),
      ];
      final seen = <String>{};
      for (final candidate in candidates) {
        if (!seen.add(candidate)) continue;
        final fetched = await _fetchMasterPlaylistVariants(candidate);
        if (fetched.isEmpty) continue;
        final master = masterUrl ?? candidate;
        return sortQualityMedia(
          fetched
              .map(
                (v) => v.copyWith(
                  masterUrl: master,
                  sourcePageUrl: media.sourcePageUrl ?? v.sourcePageUrl,
                  pageTitle: media.pageTitle ?? v.pageTitle,
                ),
              )
              .toList(),
        );
      }
    }

    // Merge sparse sources (group + children + media) when ≥2 unique URLs.
    final sparse = <SniffedMedia>[media, ...fromGroup, ...children];
    if (masterUrl != null) {
      sparse.addAll(fromDetected(masterUrl));
    }
    final sorted = sortQualityMedia(sparse);
    if (sorted.length >= 2) return sorted;

    return const [];
  }

  /// Updates the floating button position from [VideoFloatChannel] (JS).
  void _handleVideoFloatMessage(String message) {
    if (!mounted || widget.settings.replaceSitePlayer) {
      if (_videoFloatRect != null) {
        setState(() => _videoFloatRect = null);
      }
      return;
    }
    Map<String, dynamic>? data;
    try {
      final decoded = jsonDecode(message);
      if (decoded is Map) {
        data = Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      data = null;
    }
    if (data == null || data['hasVideo'] != true) {
      if (_videoFloatRect != null && mounted) {
        setState(() => _videoFloatRect = null);
      }
      return;
    }
    final left = (data['left'] as num?)?.toDouble();
    final top = (data['top'] as num?)?.toDouble();
    final width = (data['width'] as num?)?.toDouble();
    final height = (data['height'] as num?)?.toDouble();
    if (left == null || top == null || width == null || height == null) {
      return;
    }
    final next = Rect.fromLTWH(left, top, width, height);
    final prev = _videoFloatRect;
    // Ignore sub-pixel jitter to avoid rebuild thrash while scrolling.
    if (prev != null &&
        (prev.left - next.left).abs() < 2 &&
        (prev.top - next.top).abs() < 2 &&
        (prev.width - next.width).abs() < 2 &&
        (prev.height - next.height).abs() < 2) {
      return;
    }
    setState(() => _videoFloatRect = next);
  }

  /// Whether the IDM-style float should paint on the active browser tab.
  bool get _shouldShowFloatingPlayerButton {
    if (widget.settings.replaceSitePlayer) return false;
    if (_playerOpening) return false;
    final media = _videoForActiveTabPlayback();
    if (media == null) return false;
    final pageUrl = _activeTab.addressController.text.trim();
    if (pageUrl.isNotEmpty &&
        _floatingPlayerDismissedForUrl != null &&
        _floatingPlayerDismissedForUrl == pageUrl) {
      return false;
    }
    return true;
  }

  Future<void> _openFloatingPlayer() async {
    if (_playerOpening) return;
    // Always re-resolve from the active tab at tap time (never a stale
    // _latestVideoMedia from a previous tab).
    final media = _videoForActiveTabPlayback();
    if (media == null) {
      if (mounted) {
        _showSnack(
          'No playable stream found on this tab yet. Wait a moment or open the capture tray.',
        );
      }
      return;
    }
    _playerOpening = true;
    try {
      await _openVideoPlayer(media);
    } finally {
      _playerOpening = false;
    }
  }

  /// Positions [FloatingVideoButton] on the largest video rect from JS, or
  /// falls back to the lower-right of the WebView (above the bottom strip).
  Widget _buildFloatingPlayerOverlay(double toolbarHeight) {
    return buildFloatingPlayerOverlay(
      toolbarHeight: toolbarHeight,
      media: _videoForActiveTabPlayback(),
      videoFloatRect: _videoFloatRect,
      onTap: () => unawaited(_openFloatingPlayer()),
      onDismiss: () {
        final pageUrl = _activeTab.addressController.text.trim();
        setState(() {
          _floatingPlayerDismissedForUrl =
              pageUrl.isEmpty ? '__dismissed__' : pageUrl;
        });
      },
    );
  }

  /// Handles JS [AuroraPlayChannel] when replace-site-player is on.
  Future<void> _handleAuroraPlayRequest(String message) async {
    if (!mounted || !widget.settings.replaceSitePlayer) return;
    if (_playerOpening) return;
    final now = DateTime.now();
    if (_lastAuroraPlayAt != null &&
        now.difference(_lastAuroraPlayAt!) < const Duration(milliseconds: 1500)) {
      return;
    }

    // Keep the tab on the video page while ads try to navigate away on the
    // same click that started play (MissAV and similar).
    _activeTab.controller.armPlayNavigationSuppress();

    Map<String, dynamic>? data;
    try {
      final decoded = jsonDecode(message);
      if (decoded is Map) {
        data = Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      data = null;
    }

    final rawUrl = (data?['url'] as String?)?.trim() ?? '';
    final needsSniffed = data?['needsSniffed'] == true ||
        rawUrl.isEmpty ||
        rawUrl.startsWith('blob:') ||
        rawUrl.startsWith('data:');
    final isVideo = data?['isVideo'] != false;

    SniffedMedia? media;
    if (!needsSniffed && rawUrl.isNotEmpty) {
      final detected = _activeTab.snifferEngine.detectedMedia;
      for (final m in detected) {
        if (m.url == rawUrl ||
            m.url.contains(rawUrl) ||
            rawUrl.contains(m.url)) {
          media = m;
          break;
        }
      }
      final segs = Uri.tryParse(rawUrl)?.pathSegments;
      final fallbackName = (segs != null && segs.isNotEmpty)
          ? segs.last
          : 'Video';
      media ??= SniffedMedia(
        url: rawUrl,
        name: fallbackName.isEmpty ? 'Video' : fallbackName,
        type: isVideo ? MediaType.video : MediaType.audio,
        sourcePageUrl: _activeTab.addressController.text,
        sniffSource: SniffSource.javascript,
      );
      // Also register so capture tray shows it.
      unawaited(
        Future(() {
          _sniffIntakeController.sniffBrowserUrl(
            _activeTab,
            rawUrl,
            sourcePageUrl: _activeTab.addressController.text,
          );
        }),
      );
    } else {
      media = _videoForActiveTabPlayback();
    }

    if (media == null) {
      if (mounted) {
        _showSnack(
          'No playable stream found on this tab yet. Wait a moment or open the capture tray.',
        );
      }
      return;
    }

    _playerOpening = true;
    _lastAuroraPlayAt = now;
    try {
      await _openVideoPlayer(media);
    } finally {
      _playerOpening = false;
    }
  }

  /// Picks the best sniffed video/playlist for the **active tab only**.
  /// Does not fall back to another tab's cached stream.
  /// Uses decorate–sort–undecorate to avoid calling Uri.tryParse inside the
  /// sort comparator (which would run O(n·log n) parses instead of O(n)).
  SniffedMedia? _bestDetectedVideoForPlayback() {
    final pageUrl =
        (_activeTab.currentUrl ?? _activeTab.addressController.text).trim();
    final pageHost = Uri.tryParse(pageUrl)?.host.toLowerCase() ?? '';

    // W1: Build candidate list — prefer video/playlist candidates first;
    // only include audio when no video or playlist exists (prevents the
    // custom player from silently opening an audio-only DASH track).
    final hasVideoOrPlaylist = _activeTab.snifferEngine.detectedMedia.any(
      (m) => m.type == MediaType.video || m.type == MediaType.playlist,
    );
    final items = _activeTab.snifferEngine.detectedMedia
        .where(
          (m) =>
              m.type == MediaType.video ||
              m.type == MediaType.playlist ||
              (!hasVideoOrPlaylist && m.type == MediaType.audio),
        )
        .toList();
    if (items.isEmpty) return null;

    // Precompute scores once (decorate), sort, then undecorate.
    final scored = items.map((m) {
      var s = 0;
      final u = m.url.toLowerCase();

      // Type bonus
      if (u.contains('.m3u8') || u.contains('mpegurl')) s += 100;
      if (m.type == MediaType.video) s += 20;
      if (m.type == MediaType.playlist) s += 40;

      // Size bonus (capped at 50 MB equivalent)
      if ((m.contentLengthBytes ?? 0) > 0) {
        s += ((m.contentLengthBytes! / (1024 * 1024)).clamp(0, 50)).toInt();
      }

      // Resolution bonus
      if (m.height != null && m.height! >= 720) s += 10;

      // W3: Bandwidth sanity — reward reasonable bitrates, penalise
      // absurd resolution-per-bitrate (e.g. 4K@500kbps).
      final bw = m.bandwidth;
      if (bw != null && bw > 0) {
        s += (bw / 1e6).clamp(0, 20).round(); // up to +20
        if (m.height != null) {
          if (m.height! >= 2160 && bw < 5e6) s -= 40;
          if (m.height! >= 1080 && bw < 2e6) s -= 20;
        }
      }

      // W2: Codec-awareness — prefer h264 over AV1 on Android.
      final codec = (m.videoCodec ?? '').toLowerCase();
      if (codec.contains('avc1') || codec.contains('h264')) s += 30;
      else if (codec.contains('hev1') ||
          codec.contains('hvc1') ||
          codec.contains('h265')) s += 15;
      else if (codec.contains('vp09') || codec.contains('vp9')) s += 10;
      else if (codec.contains('av01') || codec.contains('av1')) s += 5;
      final aCodec = (m.audioCodec ?? '').toLowerCase();
      if (aCodec.contains('mp4a') || aCodec.contains('aac')) s += 10;
      else if (aCodec.contains('mp3')) s += 8;
      else if (aCodec.contains('opus')) s += 5;

      // W5: Live streams penalised for file-download context
      // (they are infinite; player can still open them, but rank lower).
      if (m.isLive == true) s -= 25;

      // Page-host match bonus
      final src = (m.sourcePageUrl ?? '').trim();
      if (pageHost.isNotEmpty && src.isNotEmpty) {
        final sh = Uri.tryParse(src)?.host.toLowerCase() ?? '';
        if (sh == pageHost) s += 50;
      }

      return _ScoredMedia(media: m, score: s);
    }).toList();

    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.first.media;
  }

  Future<void> _showMediaPreview(
    SniffedMedia media, {
    List<SniffedMedia> qualityVariants = const [],
  }) =>
      showMediaPreview(
        context,
        media,
        activeTab: _activeTab,
        isMounted: () => mounted,
        getCookiesForUrl: _sniffIntakeController.getCookiesForUrl,
        getPlaybackCookies: ({required String mediaUrl, String? pageUrl}) =>
            _sniffIntakeController.getPlaybackCookies(
              mediaUrl: mediaUrl,
              pageUrl: pageUrl,
            ),
        buildSniffedDownloadHeaders:
            ({
              required BrowserTab tab,
              required SniffedMedia media,
              required Map<String, String> cookieHeaders,
              String? currentUrl,
            }) =>
                buildSniffedDownloadHeaders(
                  tab: tab,
                  media: media,
                  cookieHeaders: cookieHeaders,
                  currentUrl: currentUrl,
                ),
        refreshM3u8IfNeeded: _refreshM3u8IfNeeded,
        onAddToQueue: (m) async => _showAddQueueDialog(context, m),
        qualityVariants: qualityVariants,
        onSaveVideoFavorite: _saveVideoFavorite,
        onRecordVideoPlay: _recordVideoPlay,
        engine: switch (widget.settings.playbackEngine) {
          PlaybackEngineSetting.videoPlayer => PlaybackEngineKind.videoPlayer,
          PlaybackEngineSetting.mediaKit => PlaybackEngineKind.mediaKit,
        },
        onEngineChanged: (kind) {
          // The player offers the switch when a stream will not start; make it
          // stick so the next video opens on whichever one worked.
          widget.onSettingsChanged?.call(
            widget.settings.copyWith(
              playbackEngine: switch (kind) {
                PlaybackEngineKind.videoPlayer =>
                  PlaybackEngineSetting.videoPlayer,
                PlaybackEngineKind.mediaKit => PlaybackEngineSetting.mediaKit,
              },
            ),
          );
        },
      );

  Future<String> _refreshM3u8IfNeeded(
    String url,
    Map<String, String> headers,
  ) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final path = uri.path.toLowerCase();
    if (!path.endsWith('.m3u8') && !isPlaylistPathHint(path)) {
      return url;
    }

    // Skip the pre-flight fetch if the URL carries a signed token.
    // CDNs (beeg24, yd-hls.ofpcif.cn, etc.) invalidate it on first use.
    final queryKeys = uri.queryParameters.keys
        .map((k) => k.toLowerCase())
        .toSet();
    final hasSignedToken =
        queryKeys.contains('token') ||
        queryKeys.contains('policy') ||
        queryKeys.contains('signature') ||
        queryKeys.contains('expires') ||
        queryKeys.contains('hmac') ||
        queryKeys.contains('exp') ||
        queryKeys.contains('acl') ||
        queryKeys.contains('auth_key') ||
        queryKeys.contains('auth') ||
        queryKeys.contains('sign') ||
        queryKeys.contains('secure') ||
        queryKeys.contains('hash');
    if (hasSignedToken) {
      return url;
    }

    try {
      final response = await http
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final playlist = HlsPlaylistParser.parse(response.body, uri);
        if (playlist.isMaster && playlist.variants.isNotEmpty) {
          final variants = [...playlist.variants]
            ..sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
          return variants.first.uri.toString();
        }
        // Media playlist — use as-is
        return url;
      } else if (response.statusCode == 403 || response.statusCode == 401) {
        // 403/401: CDN may require webview session context to refresh the
        // stream URL.  Ask the active tab to re-sniff any video src/XHR
        // matching the same path pattern so we get a fresh signed URL.
        final freshUrl = await _reSniffFromPage(url);
        if (freshUrl != null && freshUrl != url) return freshUrl;
      }
    } catch (_) {
      // If error occurs, fall back to the original URL
    }
    return url;
  }

  /// Fetches the HLS master playlist at [url] and returns all variant streams
  /// as [SniffedMedia] with bandwidth, width, and height populated from the
  /// EXT-X-STREAM-INF attributes. Returns an empty list if the URL is not an
  /// .m3u8 master playlist or if the fetch/parse fails.
  Future<List<SniffedMedia>> _fetchMasterPlaylistVariants(String url) async {
    return HlsVariantFetcher.fetch(
      url,
      tab: _activeTab,
      sniffIntakeController: _sniffIntakeController,
      doNotTrackEnabled: widget.settings.doNotTrackEnabled,
    );
  }

  /// Asks the webview to re-evaluate the page's media sources and returns the
  /// first m3u8 URL matching the same host/path prefix as [staleUrl].
  Future<String?> _reSniffFromPage(String staleUrl) async {
    try {
      final staleUri = Uri.tryParse(staleUrl);
      if (staleUri == null) return null;
      // Trigger a fresh scan of network requests in the page by forcing a
      // video element re-load (if present).
      await _activeTab.controller.evaluateJavaScript(
        "(function() { "
        "  var vids = document.querySelectorAll('video'); "
        "  for (var i = 0; i < vids.length; i++) { "
        "    var src = vids[i].src || (vids[i].querySelector('source') && vids[i].querySelector('source').src); "
        "    if (src && src.indexOf('.m3u8') !== -1) { "
        "      try { MediaSnifferChannel.postMessage(src); } catch(_) {} "
        "    } "
        "  } "
        "})();",
      );
      // Wait briefly for new sniff events to arrive
      await Future.delayed(const Duration(seconds: 2));
      // Look in sniffed media for a recently-updated URL from the same host
      final candidates = _activeTab.snifferEngine.detectedMedia
          .where(
            (m) =>
                m.url.contains('.m3u8') &&
                Uri.tryParse(m.url)?.host == staleUri.host &&
                m.url != staleUrl,
          )
          .toList();
      if (candidates.isNotEmpty) {
        candidates.sort((a, b) => b.sniffedAt.compareTo(a.sniffedAt));
        return candidates.first.url;
      }
    } catch (_) {}
    return null;
  }

  void _showMediaInfoSheet(BuildContext context, SniffedMedia item) =>
      showMediaInfoSheet(
        context,
        item,
        formatSize: formatByteSize,
      );

  void _showSniffedMediaSheet() => showSniffedMediaSheet(
    context,
    activeTab: _activeTab,
    mediaCatchController: _mediaCatchController,
    settings: widget.settings,
    onSettingsChanged: widget.onSettingsChanged,
    isMounted: mounted,
    onChanged: () => setState(() {}),
    sortMedia: _sortedMedia,
    // Same CDN-aware open path as the floating / replace-site player
    // (cookies + headers + quality resolution).
    onPreview: (media, {List<SniffedMedia> variants = const []}) =>
        unawaited(_openVideoPlayer(media, groupVariants: variants)),
    onInfo: (ctx, item) => _showMediaInfoSheet(ctx, item),
    onAddToQueue: (ctx, media, {List<SniffedMedia> variants = const []}) async =>
        _showAddQueueDialog(ctx, media, variants: variants),
    onRescan: () => unawaited(_activeTab.controller.rescanPage()),
  );

  /// Directly enqueue a download from a captured URL without showing
  /// the "Add to Queue" dialog.
  Future<void> _enqueueDirectDownload(
    BrowserTab tab,
    String url,
    String? suggestedFilename,
  ) async {
    final currentUrl = await tab.controller.currentUrl() ?? '';
    final pageUri = Uri.tryParse(currentUrl);
    final media = tab.snifferEngine.detectedMedia
        .where((m) => m.url == url)
        .lastOrNull;

    await enqueueDirectDownload(
      context: context,
      tab: tab,
      url: url,
      suggestedFilename: suggestedFilename,
      downloadQueue: _downloadQueue,
      settings: widget.settings,
      baseDir: _baseDir,
      baseTemp: _baseTemp,
      getCookiesForUrl: _sniffIntakeController.getCookiesForUrl,
      showSnack: _showSnack,
      isMounted: () => mounted,
      ruleEngine: widget.ruleEngine,
      pageHost: pageUri?.host,
      mediaTypeForRule: media?.contentType,
    );
  }

  /// Shows a modern Firefox-style bottom sheet when a download link is triggered.
  void _showDownloadBehaviorPrompt(
    BrowserTab tab,
    String url,
    String? suggestedFilename,
  ) async {
    final media = tab.snifferEngine.detectedMedia.firstWhereOrNull((m) => m.url == url);
    final rawName = (suggestedFilename != null && suggestedFilename.trim().isNotEmpty)
        ? suggestedFilename.trim()
        : (media?.name ?? url.split('/').last.split('?').first);
    final filename = rawName.isNotEmpty ? rawName : 'download';
    final sourceHost = (tab.addressController.text.trim().isNotEmpty
            ? Uri.tryParse(tab.addressController.text.trim())?.host
            : Uri.tryParse(url)?.host) ??
        '';

    final result = await showDownloadPromptSheet(
      context: context,
      url: url,
      suggestedFilename: filename,
      contentLengthBytes: media?.contentLengthBytes,
      contentType: media?.contentType,
      sourceHost: sourceHost.isNotEmpty ? sourceHost : null,
    );

    if (result == null || result.action == DownloadPromptAction.cancel) {
      return;
    }

    if (result.rememberHost && sourceHost.isNotEmpty) {
      final store = const SiteProfileStore();
      final profiles = List<SiteProfile>.from(await store.load());
      final existingIndex = profiles.indexWhere((p) => p.hostPattern == sourceHost);
      final updatedProfile = (existingIndex >= 0
              ? profiles[existingIndex]
              : SiteProfile(
                  id: DateTime.now().millisecondsSinceEpoch.toString(),
                  name: sourceHost,
                  hostPattern: sourceHost,
                  createdAt: DateTime.now(),
                  updatedAt: DateTime.now(),
                ))
          .copyWith(downloadLinkBehavior: 'autoDownload');

      if (existingIndex >= 0) {
        profiles[existingIndex] = updatedProfile;
      } else {
        profiles.add(updatedProfile);
      }
      await store.save(profiles);
    }

    if (result.action == DownloadPromptAction.downloadAndOpen) {
      await _enqueueDirectDownload(tab, url, filename);
      final existingTask = _downloadQueue.getTaskByUrl(url);
      if (existingTask != null) {
        StreamSubscription? sub;
        sub = _downloadQueue.onTaskUpdated.listen((updated) {
          if (updated.id == existingTask.id && updated.state == DownloadState.completed) {
            sub?.cancel();
            PublicDownloadsService().open(updated).catchError((_) {});
          } else if (updated.id == existingTask.id && updated.state == DownloadState.failed) {
            sub?.cancel();
          }
        });
      }
    } else if (result.action == DownloadPromptAction.download) {
      await _enqueueDirectDownload(tab, url, filename);
    }
  }

  /// Returns `true` when the user confirmed enqueue (or link update),
  /// `false` when cancelled / dismissed. Capture batch download stops on
  /// `false` so remaining sequential dialogs are not opened.
  Future<bool> _showAddQueueDialog(
    BuildContext context,
    SniffedMedia media, {
    List<SniffedMedia> variants = const [],
  }) async {
    final tab = _activeTab;
    // Refresh live page title so long descriptive names (MissAV etc.) are
    // available even if PageMetaChannel raced behind the download tap.
    try {
      final live = await tab.controller.pageTitle();
      if (live != null && live.trim().isNotEmpty) {
        final cleaned = live.trim();
        if (tab.pageMeta.title.trim().isEmpty) {
          tab.pageMeta = PageMeta(
            title: cleaned,
            videoWidth: tab.pageMeta.videoWidth,
            videoHeight: tab.pageMeta.videoHeight,
            structuredName: tab.pageMeta.structuredName,
          );
        }
        if (tab.title == null || tab.title!.trim().isEmpty) {
          tab.title = cleaned;
        }
      }
    } catch (_) {}
    final suggestedName = _buildSuggestedFilename(
      media.name,
      mediaUrl: media.url,
      media: media,
    );
    final currentUrl = await tab.controller.currentUrl();

    if (!context.mounted) return false;

    return showAddQueueDialog(
      context,
      media: media,
      variants: variants,
      tab: tab,
      currentUrl: currentUrl,
      suggestedName: suggestedName,
      baseDir: _baseDir,
      baseTemp: _baseTemp,
      getCookiesForUrl: _sniffIntakeController.getCookiesForUrl,
      downloadQueue: _downloadQueue,
      fetchMasterPlaylistVariants: _fetchMasterPlaylistVariants,
      onTokenExpired: ({bool forceReload = false}) => _reloadForFreshUrl(
        tab,
        media.sourcePageUrl,
        forceReload: forceReload,
      ),
    );
  }

  String _buildSuggestedFilename(
    String mediaName, {
    String? mediaUrl,
    SniffedMedia? media,
  }) {
    return buildSuggestedFilenameForTab(
      tab: _activeTab,
      mediaName: mediaName,
      mediaUrl: mediaUrl,
      media: media,
      settings: widget.settings,
    );
  }

  List<SniffedMedia> _sortedMedia(List<SniffedMedia> media) {
    return sortSniffedMedia(media, widget.settings.sniffedMediaSort);
  }

  bool _isCurrentPageFavorited() {
    final url = _activeTab.addressController.text.trim();
    return url.isNotEmpty &&
        _library.favorites.any((favorite) => favorite.url == url);
  }

  /// Decodes a JSON string off the UI isolate via the persistent worker pool.
  /// Returns a [Map] on success, null on parse failure.
  Future<Map?> _decodeJsInBackground(String message) async {
    try {
      if (isRunningInTest()) {
        final decoded = jsonDecode(message);
        if (decoded is Map) return decoded;
        return <String, dynamic>{};
      }
      final result = await WorkerIsolatePool.instance.execute(
        'jsonDecode',
        {'json': message},
      );
      if (result is Map) return result;
      return <String, dynamic>{};
    } catch (_) {
      return null;
    }
  }

  String _injectBaseTag(String html, String url) {
    final escaped = const HtmlEscape(HtmlEscapeMode.attribute).convert(url);
    final base = '<base href="$escaped">';
    final headIndex = html.toLowerCase().indexOf('<head>');
    if (headIndex != -1) {
      return html.replaceRange(headIndex + 6, headIndex + 6, base);
    }
    return '<!doctype html><html><head>$base</head><body>$html</body></html>';
  }

  Future<void> _showReaderMode() async {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReaderModeWidget(controller: _activeTab.controller),
      ),
    );
  }

  Future<void> _translateSelectedText(String text) async {
    final target = translateLanguageById(widget.settings.translateTargetLang);
    final url = Uri.parse(
      'https://translate.google.com/translate?sl=auto&tl=${target.id}&text='
      '${Uri.encodeQueryComponent(text)}',
    );
    unawaited(_loadUrlWithHostSettings(_activeTab, url));
  }

  Future<void> _searchSelectedText(String text) async {
    final url = Uri.parse(widget.settings.searchEngine.buildSearchUrl(text));
    unawaited(_loadUrlWithHostSettings(_activeTab, url));
  }

  Future<void> _clearDataForSite(String url) async {
    final tab = _activeTab;
    final host = (Uri.tryParse(url)?.host ?? '').toLowerCase();
    if (host.isEmpty) {
      _showSnack('Open a page first to clear its data.');
      return;
    }
    try {
      await tab.controller.clearSiteData(url);
      await tab.controller.reload();
      _showSnack('Cleared data for $host.');
    } catch (error) {
      _showSnack('Could not clear data for this page: $error');
    }
  }

  Future<void> _showAutofillMenu() async {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'Autofill form',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
              if (_autofillProfiles.isEmpty)
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('No profiles yet'),
                  subtitle: const Text(
                    'Add one via Settings → Autofill to begin',
                  ),
                )
              else
                for (final profile in _autofillProfiles)
                  ListTile(
                    leading: const Icon(Icons.contact_page),
                    title: Text(profile.label),
                    subtitle: Text(_profileSubtitle(profile)),
                    onTap: () {
                      Navigator.pop(ctx);
                      unawaited(_fillWithProfile(profile));
                    },
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        final updated = List<AutofillProfile>.from(
                          _autofillProfiles,
                        )..removeWhere((p) => p.id == profile.id);
                        await _autofillStore.save(updated);
                        if (mounted) {
                          setState(() => _autofillProfiles = updated);
                        }
                      },
                    ),
                  ),
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('New profile'),
                onTap: () {
                  Navigator.pop(ctx);
                  unawaited(_editAutofillProfile(null));
                },
              ),
            ],
          ),
        );
      },
    );
  }

  String _profileSubtitle(AutofillProfile profile) {
    final parts = <String>[];
    if (profile.email.isNotEmpty) parts.add(profile.email);
    if (profile.phone.isNotEmpty) parts.add(profile.phone);
    if (parts.isEmpty && profile.fullName.isNotEmpty) {
      return profile.fullName;
    }
    return parts.join(' · ');
  }

  Future<void> _fillWithProfile(AutofillProfile profile) async {
    final values = <String, String>{
      if (profile.fullName.isNotEmpty) 'fullName': profile.fullName,
      if (profile.email.isNotEmpty) 'email': profile.email,
      if (profile.phone.isNotEmpty) 'phone': profile.phone,
      if (profile.addressLine1.isNotEmpty) 'addressLine1': profile.addressLine1,
      if (profile.addressLine2.isNotEmpty) 'addressLine2': profile.addressLine2,
      if (profile.city.isNotEmpty) 'city': profile.city,
      if (profile.state.isNotEmpty) 'state': profile.state,
      if (profile.postalCode.isNotEmpty) 'postalCode': profile.postalCode,
      if (profile.country.isNotEmpty) 'country': profile.country,
      if (profile.includeCard) ...{
        if (profile.cardName.isNotEmpty) 'cardName': profile.cardName,
        if (profile.cardNumber.isNotEmpty) 'cardNumber': profile.cardNumber,
        if (profile.cardExpiry.isNotEmpty) 'cardExpiry': profile.cardExpiry,
      },
    };
    final filled = await _activeTab.controller.fillForm(values);
    if (filled == 0) {
      _showSnack('No matching fields found on this page.');
    } else {
      _showSnack('Filled $filled field${filled == 1 ? '' : 's'}.');
    }
  }

  Future<void> _editAutofillProfile(AutofillProfile? existing) =>
      editAutofillProfile(
        context,
        existing: existing,
        autofillStore: _autofillStore,
        autofillProfiles: _autofillProfiles,
        activeTab: _activeTab,
        isMounted: mounted,
        onProfilesChanged: (profiles) {
          setState(() {
            _autofillProfiles = profiles;
          });
        },
      );

  void _showSnack(
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    if (!mounted) return;
    if (!widget.settings.showSnackbars) return;
    final media = MediaQuery.of(context);
    final topPadding = media.padding.top;
    final screenHeight = media.size.height;
    final bottomMargin = (screenHeight - topPadding - 90).clamp(
      0.0,
      screenHeight,
    );

    AuroraSnackbar.show(
      context,
      message,
      actionLabel: actionLabel,
      onAction: onAction,
      builder: (text) => SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.only(bottom: bottomMargin, left: 16, right: 16),
        duration: const Duration(milliseconds: 1500),
        dismissDirection: DismissDirection.up,
        action: actionLabel != null && onAction != null
            ? SnackBarAction(label: actionLabel, onPressed: onAction)
            : null,
      ),
    );
  }

  void _showPickerSnack(String message, {required VoidCallback onCancel}) {
    if (!mounted) return;
    final media = MediaQuery.of(context);
    final topPadding = media.padding.top;
    final screenHeight = media.size.height;
    final bottomMargin = (screenHeight - topPadding - 90).clamp(
      0.0,
      screenHeight,
    );

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.only(bottom: bottomMargin, left: 16, right: 16),
        duration: const Duration(seconds: 30),
        dismissDirection: DismissDirection.up,
        action: SnackBarAction(label: 'Cancel', onPressed: onCancel),
      ),
    );
  }

  Future<DuplicateChoice> _showDuplicatePrompt(
    BuildContext context,
    String filename,
  ) {
    return showDuplicateDownloadDialog(
      context: context,
      filename: filename,
    );
  }
}

/// Pair of a sniffed media item with its precomputed playback score.
/// Used by [_SnifferScreenState._bestDetectedVideoForPlayback] for
/// decorate–sort–undecorate sorting.
final class _ScoredMedia {
  final SniffedMedia media;
  final int score;
  const _ScoredMedia({required this.media, required this.score});
}

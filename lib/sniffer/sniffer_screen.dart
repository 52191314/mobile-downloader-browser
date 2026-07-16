import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'worker_isolate_pool.dart';

import 'package:http/http.dart' as http;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../downloader/downloader.dart';
import '../logging/aurora_log.dart';
import '../platform/network_binding_service.dart';
import '../ui/notifications/aurora_snackbar.dart';
import '../platform/public_downloads_service.dart';
import '../settings/download_settings.dart';
import 'ad_block_engine_native.dart';
import 'browser_controller.dart';
import 'browser_library.dart';
import 'browser_open_request.dart';
import 'controllers/address_bar_controller.dart';
import 'controllers/element_picker_controller.dart';
import 'controllers/library_controller.dart';
import 'controllers/media_catch_controller.dart';
import 'controllers/sniff_intake_controller.dart';
import 'controllers/tab_lifecycle_controller.dart';
import 'controllers/tab_manager.dart';
import 'idm_backup_parser.dart';
import 'browser_search.dart';
import 'browser_widget.dart';
import 'media_capture_analyzer.dart';
import 'media_sniffer_engine.dart';
import 'models/address_suggestion.dart';
import 'models/browser_tab.dart';
import 'models/favorite_selection.dart';
import 'models/page_meta.dart';
import 'models/sniffed_media.dart';
import 'reader_mode_widget.dart';
import 'search_suggestion_service.dart';
import 'session_recovery.dart';
import 'autofill_store.dart';
import 'safe_browsing_service.dart';
import 'sniffer_url_utils.dart';
import '../theme/aurora_palette.dart';

import 'actions/autofill_action.dart';
import 'actions/context_menu_action.dart';
import 'actions/translate_action.dart';
import 'sheets/favorites_sheet.dart';
import 'sheets/group_actions_sheet.dart' show showGroupActionsSheet, GroupActionsCallbacks;
import 'sheets/history_sheet.dart';
import 'sheets/library_sheet.dart';
import 'sheets/media_info_sheet.dart';
import 'sheets/media_preview_sheet.dart';
import 'sheets/saved_pages_sheet.dart';
import 'sheets/sniffed_media_sheet.dart';
import 'sheets/tabs_sheet.dart';
import 'models/tab_group.dart' show TabGroup;
import 'widgets/draggable_tab_card.dart' show DraggableTabCard, TabListDropSlot;
import 'widgets/group_drop_zone.dart' show GroupDropZone;
import 'widgets/tab_grid_view.dart' show TabGridView;
import 'tab_groups/tab_group_palette.dart' show TabGroupPalette;
part 'widgets/capture_widgets.dart';
part 'widgets/add_queue_dialog.dart';
part 'widgets/folder_selector.dart';
part 'widgets/rename_file_dialog.dart';

/// Predefined User-Agent profiles keyed by [DownloadSettings.userAgentProfile].
const _uaProfiles = <String, String>{
  'mobile':
      'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
  'desktop_chrome':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36',
  'desktop_firefox':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:127.0) '
      'Gecko/20100101 Firefox/127.0',
  'safari':
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 '
      '(KHTML, like Gecko) Version/17.5 Safari/605.1.15',
};

/// Human-readable label for each profile key.
const _uaProfileLabels = <String, String>{
  'mobile': 'Mobile Chrome',
  'desktop_chrome': 'Desktop Chrome',
  'desktop_firefox': 'Desktop Firefox',
  'safari': 'Safari (macOS)',
};

const _snifferDownloadUserAgent =
    'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

String _cleanUserAgent(String? ua) {
  if (ua == null) return _snifferDownloadUserAgent;
  return ua
      .replaceAll(RegExp(r';\s*wv', caseSensitive: false), '')
      .replaceAll(RegExp(r'\bwv\b', caseSensitive: false), '')
      .replaceAll(RegExp(r'Version/4\.0\s*', caseSensitive: false), '');
}

/// Returns the User-Agent string for a given profile key, falling back
/// to the mobile Chrome UA for unknown keys.
String _uaForProfile(String profile) =>
    _uaProfiles[profile] ?? _snifferDownloadUserAgent;

/// Returns the User-Agent to use for downloading [targetUrl].
///
/// For surrit.com and any host behind Cloudflare's WAF, the raw WebView
/// User-Agent (containing `; wv` and `Version/4.0`) MUST be preserved so
/// that the `cf_clearance` cookie (cryptographically bound to the exact
/// UA that earned it) remains valid.  Using a cleaned UA with the same
/// `cf_clearance` cookie triggers 403 from Cloudflare.
///
/// For all other hosts returns the cleaned UA to avoid CDN throttling
/// that some servers apply to WebView/`wv` signatures.
String _downloadUserAgent(String targetUrl, BrowserTab tab) {
  final raw = tab.userAgent;
  if (raw == null || raw.isEmpty) return _snifferDownloadUserAgent;
  if (targetUrl.toLowerCase().contains('surrit.com')) {
    return raw; // Must match the UA that earned Cloudflare clearance.
  }
  return _cleanUserAgent(raw);
}

Map<String, String> _normalizeHeadersForUrl(
  Map<String, String> headers,
  String targetUrl, {
  String? currentUrl,
  String? addressText,
  String? sourcePageUrl,
}) {
  final targetLower = targetUrl.toLowerCase();
  if (targetLower.contains('surrit.com')) {
    String? refererKey;
    for (final key in headers.keys) {
      if (key.toLowerCase() == 'referer') {
        refererKey = key;
        break;
      }
    }

    String? currentReferer = refererKey != null ? headers[refererKey] : null;

    // 1. Always fix missav.com -> missav.ws domain migration if present.
    if (currentReferer != null &&
        currentReferer.toLowerCase().contains('missav.com')) {
      currentReferer = currentReferer.replaceAll(
        RegExp(r'missav\.com', caseSensitive: false),
        'missav.ws',
      );
      if (refererKey != null) {
        headers.remove(refererKey);
      }
      headers['Referer'] = currentReferer;
      _ensureOriginHeader(headers, currentReferer);
      return headers;
    }

    // 2. If the referer is already set to a surrit.com URL and the target is
    //    also surrit.com, keep the same-origin referer.  surrit.com's CDN
    //    needs the surrit.com iframe page URL as referer — replacing it with
    //    missav.ws causes 403.
    if (currentReferer != null &&
        currentReferer.toLowerCase().contains('surrit.com')) {
      _ensureOriginHeader(headers, currentReferer);
      return headers;
    }

    // 3. No referer (or empty) — build a fallback.
    if (currentReferer == null || currentReferer.isEmpty) {
      final candidate = _firstNonEmpty([
        sourcePageUrl,
        currentUrl,
        addressText,
      ]);
      if (candidate != null &&
          !candidate.toLowerCase().contains('surrit.com')) {
        currentReferer = candidate;
      } else {
        // When the target is surrit.com, use the target URL's own origin
        // (scheme + host) as the referer.  surrit.com's CDN rejects
        // missav.ws and any non-surrit.com referer; it also rejects
        // requests with no referer at all (403 / "blocked").
        final targetUri = Uri.tryParse(targetUrl);
        if (targetUri != null && targetUri.host.isNotEmpty) {
          currentReferer = '${targetUri.scheme}://${targetUri.host}/';
        } else {
          currentReferer = 'https://missav.ws/';
        }
      }
    }

    if (!currentReferer.startsWith('http://') &&
        !currentReferer.startsWith('https://')) {
      // Same fallback logic: prefer the target origin over the hard-coded
      // missav.ws default when the URL provides a valid host.
      final targetUri = Uri.tryParse(targetUrl);
      if (targetUri != null && targetUri.host.isNotEmpty) {
        currentReferer = '${targetUri.scheme}://${targetUri.host}/';
      } else {
        currentReferer = 'https://missav.ws/';
      }
    }

    if (refererKey != null) {
      headers.remove(refererKey);
    }
    headers['Referer'] = currentReferer;
    _ensureOriginHeader(headers, currentReferer);
  }
  return headers;
}

/// If the [headers] map does not already contain an `Origin` header, add one
/// derived from [referer] (scheme + host).  Some CDNs require Origin for
/// cross-origin playlist requests.
void _ensureOriginHeader(Map<String, String> headers, String referer) {
  if (_hasHeader(headers, 'Origin')) return;
  final uri = Uri.tryParse(referer);
  if (uri != null && uri.host.isNotEmpty && uri.scheme.isNotEmpty) {
    headers['Origin'] = '${uri.scheme}://${uri.host}';
  }
}

Map<String, String> _buildSniffedDownloadHeaders({
  required BrowserTab tab,
  required SniffedMedia media,
  required Map<String, String> cookieHeaders,
  String? currentUrl,
}) {
  final headers = <String, String>{
    'User-Agent': _downloadUserAgent(media.url, tab),
  };
  _mergeHeaders(headers, tab.controller.currentHeaders);
  _mergeHeaders(headers, sanitizeSniffedMediaHeaders(media.headers));

  if (!_hasHeader(headers, 'Referer')) {
    final referer = _firstNonEmpty([
      media.sourcePageUrl,
      currentUrl,
      tab.addressController.text,
    ]);
    if (referer != null) {
      headers['Referer'] = referer;
    }
  }

  _mergeHeaders(headers, cookieHeaders);

  // Re-add Authorization header from the sniff-time cache (it was sanitized
  // out of media.headers for security, but we captured it in authHeaderCache).
  final cachedAuth = tab.authHeaderCache[media.url];
  if (cachedAuth != null &&
      cachedAuth.isNotEmpty &&
      !_hasHeader(headers, 'Authorization')) {
    headers['Authorization'] = cachedAuth;
  }

  _normalizeHeadersForUrl(
    headers,
    media.url,
    currentUrl: currentUrl,
    addressText: tab.addressController.text,
    sourcePageUrl: media.sourcePageUrl,
  );

  return headers;
}

void _mergeHeaders(Map<String, String> target, Map<String, String> source) {
  for (final entry in source.entries) {
    target.removeWhere(
      (key, _) => key.toLowerCase() == entry.key.toLowerCase(),
    );
    target[entry.key] = entry.value;
  }
}

bool _hasHeader(Map<String, String> headers, String name) {
  return headers.keys.any((key) => key.toLowerCase() == name.toLowerCase());
}

String? _firstNonEmpty(Iterable<String?> values) {
  for (final value in values) {
    final trimmed = value?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      return trimmed;
    }
  }
  return null;
}

enum _RedirectPromptAction { foreground, background, currentTab, ignore }

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

  SnifferScreen({
    super.key,
    this.controller,
    this.downloadQueue,
    this.snifferEngine,
    DownloadSettings? settings,
    this.onSettingsChanged,
    this.onOpenQueue,
    this.onOpenSettings,
    this.onSniffedCountChanged,
    BrowserLibraryStore? libraryStore,
    this.debugControllerFactory,
    SafeBrowsingService? safeBrowsing,
    this.libraryUpdateNotifier,
    this.openRequestBus,
    this.isProCallback,
  }) : settings = settings ?? DownloadSettings.defaults(),
       libraryStore = libraryStore ?? const BrowserLibraryStore(),
       safeBrowsing =
           safeBrowsing ??
           (isRunningInTest()
               ? FakeSafeBrowsingService()
               : SafeBrowsingService());

  @override
  State<SnifferScreen> createState() => _SnifferScreenState();
}

class _SnifferScreenState extends State<SnifferScreen>
    with WidgetsBindingObserver
    implements TabLifecycleHost {
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

  bool get _addressExpanded => _addressBarController.addressExpanded;
  set _addressExpanded(bool v) => _addressBarController.addressExpanded = v;

  /// Focus node for the address bar TextField. Used to detect focus loss
  /// (tap-outside-to-collapse) and to programmatically request focus /
  /// select-all when the address bar is expanded from a tap.
  final FocusNode _addressFocusNode = FocusNode(debugLabel: 'AddressBar');

  // --- Library delegates ---
  BrowserLibrary get _library => _libraryController.library;
  bool get _isSavingPage => _libraryController.isSavingPage;

  /// Write-through setter for [_isSavingPage].
  set _isSavingPage(bool v) {
    _libraryController.isSavingPage = v;
  }

  // --- Media catch delegates ---
  bool get _captureShowAllMedia => _mediaCatchController.captureShowAllMedia;
  set _captureShowAllMedia(bool v) =>
      _mediaCatchController.captureShowAllMedia = v;
  MediaType? get _activeFilter => _mediaCatchController.activeFilter;
  set _activeFilter(MediaType? v) => _mediaCatchController.activeFilter = v;
  Set<int> get _selectedIndices => _mediaCatchController.selectedIndices;
  MediaCaptureAnalyzer get _captureAnalyzer =>
      _mediaCatchController.captureAnalyzer;

  bool _findVisible = false;
  final TextEditingController _findController = TextEditingController();
  final int _findMatchCount = 0;
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
  final ValueNotifier<int> _progressNotifier = ValueNotifier<int>(0);

  /// Debounce timer for navigation callbacks ([onUrlChanged], [onPageStarted],
  /// [onPageFinished]) so rapid back-to-back navigation events (e.g. redirect
  /// chains) trigger only one `setState` instead of three per step.
  Timer? _navSetStateDebounce;

  /// Best sniffed video on the active page (HLS > large MP4 > other).
  /// Used when site play is intercepted but `src` is blob/MSE — Aurora
  /// falls back to this sniffed URL for the in-app player.
  SniffedMedia? _latestVideoMedia;

  /// Debounce for auto-open player when site `play()` is intercepted.
  bool _playerOpening = false;
  DateTime? _lastAuroraPlayAt;

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
  static const int _maxLiveWebViews = 10;

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
  static const Duration _strictRedirectPromptCooldown = Duration(seconds: 8);
  final Set<String> _activeStrictRedirectPrompts = {};
  final Map<String, int> _recentStrictRedirectPrompts = {};

  // Cookie cache is owned by [_sniffIntakeController] (see
  // `SniffIntakeController.cookieCache`). Cleared on each page
  // navigation by calling `_sniffIntakeController.clearCookieCache()`
  // in the WebView's `onPageStarted` callback.

  /// Desktop Chrome UA, kept for backward compatibility.
  static const _desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
      maxRules: isPro ? null : 10,
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
      uaForProfile: _uaForProfile,
      downloadUserAgent: downloadUserAgent,
      baseRequestHeaders: _baseRequestHeaders,
      normalizeHeadersForUrl: _normalizeHeadersForUrl,
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
    widget.controller?.setOnOpenUrlRequest(_handleExternalOpenUrl);
    widget.controller?.setOnOpenUrlInNewTab(_handleExternalOpenUrl);
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
    if (oldWidget.settings.desktopMode != widget.settings.desktopMode) {
      _desktopMode = widget.settings.desktopMode;
      if (_desktopMode) {
        for (final tab in _tabs) {
          tab.controller.setUserAgent(_uaForProfile('desktop_chrome'));
        }
      }
    }
    if (oldWidget.settings.userAgentProfile !=
        widget.settings.userAgentProfile) {
      final ua = _uaForProfile(widget.settings.userAgentProfile);
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

  Future<void> _configureTabAdblock(BrowserTab tab) async {
    await tab.controller.configureAdBlock(
      enabled: widget.settings.adblockEnabled,
      popupBlockingEnabled: widget.settings.popupBlockingEnabled,
      filterSources: widget.settings.adblockFilterSources,
      manualRules: widget.settings.manualAdBlockRules,
      cosmeticRules: widget.settings.manualCosmeticRules,
    );
    tab.controller.updateAdblockAllowlist(widget.settings.adblockAllowlist);
    await tab.controller.setInvisibleRedirectBlocking(
      widget.settings.invisibleRedirectBlockingEnabled,
    );
    await tab.controller.setReplaceSitePlayer(
      widget.settings.replaceSitePlayer,
    );
    await _applyCosmeticRules(tab);
  }

  void _cancelPickerIfActive({String reason = 'tab change'}) {
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
    _startVideoPoll(_activeTab);

    // --- LRU tracking & WebView eviction ---
    final activeId = _activeTab.id;
    _tabActivationOrder.remove(activeId);
    _tabActivationOrder.insert(0, activeId);
    _evictStaleTabs();
    _progressNotifier.value = _activeTab.progress;
    setState(() {});
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
  String uaForProfile(String profile) => _uaForProfile(profile);

  @override
  Future<void> loadUrlWithHostSettings(
    BrowserTab tab,
    Uri uri, {
    bool addToHistory = true,
  }) => _loadUrlWithHostSettings(tab, uri, addToHistory: addToHistory);

  @override
  Future<void> applyCosmeticRules([BrowserTab? tab]) =>
      _applyCosmeticRules(tab!);

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
  String titleForUrl(String url) => _titleForUrl(url);

  @override
  void startVideoPoll(BrowserTab tab) => _startVideoPoll(tab);

  @override
  void setupTabCallbacks(BrowserTab tab) => _setupTabCallbacks(tab);

  @override
  Set<String> get builtWebViewTabIds => _builtWebViewTabIds;

  @override
  List<String> get tabActivationOrder => _tabActivationOrder;

  @override
  SniffIntakeController get sniffIntakeController => _sniffIntakeController;

  @override
  void markTabsLoaded() {
    if (!_tabsLoaded) {
      _tabsLoaded = true;
      AuroraLog.instance.info(
        'markTabsLoaded: flushing ${_pendingOpenUrlsAfterTabsLoaded.length} '
        'pending external open(s)',
        category: LogCategory.browser,
        screen: LogScreen.browser,
        eventType: LogEventType.navigation,
      );
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
      // Also drain the bus in case a request arrived while restoring tabs.
      _onOpenRequestBus();
    }
  }

  int _lastHandledOpenSeq = 0;

  void _onOpenRequestBus() {
    final bus = widget.openRequestBus;
    if (bus == null) return;
    final url = bus.url;
    final seq = bus.seq;
    if (url == null || url.isEmpty) return;
    if (seq == _lastHandledOpenSeq) return;
    _lastHandledOpenSeq = seq;
    AuroraLog.instance.info(
      'openRequestBus consumed seq=$seq url="$url" tabsLoaded=$_tabsLoaded',
      category: LogCategory.browser,
      screen: LogScreen.browser,
      eventType: LogEventType.navigation,
    );
    _handleExternalOpenUrl(url);
  }

  /// Handles Queue / intent "open this URL in the browser" requests.
  /// Queues until tab restore finishes so we never open into a tab list
  /// that loadTabsAndMedia is about to dispose and replace.
  void _handleExternalOpenUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;
    AuroraLog.instance.info(
      '_handleExternalOpenUrl("$trimmed") tabsLoaded=$_tabsLoaded '
      'tabs=${_tabs.length} active=${_tabs.isEmpty ? -1 : _activeTabIndex}',
      category: LogCategory.browser,
      screen: LogScreen.browser,
      eventType: LogEventType.navigation,
    );
    if (!_tabsLoaded || _tabs.isEmpty) {
      _pendingOpenUrlsAfterTabsLoaded.add(trimmed);
      return;
    }
    _navigateActiveTabToExternalUrl(trimmed);
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
    // Ensure this tab's WebView is in the live set before loadRequest.
    _builtWebViewTabIds.add(tab.id);
    tab.addressController.text = url;
    tab.currentUrl = url;
    _addressExpanded = false;
    if (mounted) setState(() {});
    AuroraLog.instance.info(
      '_navigateActiveTabToExternalUrl tab=${tab.id} url="$url"',
      category: LogCategory.browser,
      screen: LogScreen.browser,
      eventType: LogEventType.navigation,
    );
    // Post-frame so setState rebuild creates BrowserWidget if it was
    // previously evicted, then loadUrl awaits _ready.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_tabs.contains(tab)) return;
      unawaited(() async {
        try {
          await tab.controller.resumeWebView();
        } catch (_) {}
        try {
          await _loadUrlWithHostSettings(tab, Uri.parse(url));
          AuroraLog.instance.info(
            'external open loadRequest finished for "$url"',
            category: LogCategory.browser,
            screen: LogScreen.browser,
            eventType: LogEventType.navigation,
          );
        } catch (e, s) {
          AuroraLog.instance.error(
            'external open loadRequest failed for "$url": $e',
            category: LogCategory.browser,
            screen: LogScreen.browser,
            eventType: LogEventType.error,
            stackTrace: s,
          );
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

  Future<void> _loadTabsAndMedia() =>
      _tabLifecycleController.loadTabsAndMedia();

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

  void _closeTab(int index) => _tabLifecycleController.closeTab(index);

  void _reopenLastClosedTab() => _tabLifecycleController.reopenLastClosedTab();

  @override
  void dispose() {
    if (identical(
      _downloadQueue.browserContextAttacher,
      _attachBrowserContextToTask,
    )) {
      _downloadQueue.browserContextAttacher = null;
    }
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
      for (final tab in _tabs) {
        tab.videoPollTimer?.cancel();
        tab.videoPollTimer = null;
        if (Platform.isAndroid && _builtWebViewTabIds.contains(tab.id)) {
          unawaited(tab.controller.freeze());
          unawaited(tab.controller.pauseWebView());
        }
      }
    } else if (state == AppLifecycleState.resumed) {
      debugPrint(
        '[SnifferScreen] App resumed — resuming active WebView and timers',
      );
      for (final tab in _tabs) {
        if (tab == _activeTab) {
          if (Platform.isAndroid && _builtWebViewTabIds.contains(tab.id)) {
            unawaited(tab.controller.thaw());
            unawaited(tab.controller.resumeWebView());
          }
          _startVideoPoll(tab);
        } else {
          if (Platform.isAndroid && _builtWebViewTabIds.contains(tab.id)) {
            unawaited(tab.controller.freeze());
            unawaited(tab.controller.pauseWebView());
          }
        }
      }
    }
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

  Future<void> _loadLibrary() => _libraryController.load();

  Future<void> _saveLibrary(BrowserLibrary newLibrary) =>
      _libraryController.save(newLibrary);

  Future<void> _exportLibrary() async {
    bool exportFavorites = true;
    bool exportHistory = true;
    bool exportSavedPages = true;
    bool exportQueue = true;
    bool exportSettings = true;
    bool exportTabs = true;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.file_upload_outlined,
                            color: context.ac.accentFrost,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Export your data',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: context.ac.textPrimary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      SwitchListTile(
                        activeColor: context.ac.accentFrost,
                        title: Text(
                          'Favorites',
                          style: TextStyle(color: context.ac.textPrimary),
                        ),
                        subtitle: Text(
                          '${_library.favorites.length} favorites, ${_library.folders.length} folders',
                          style: TextStyle(color: context.ac.textSecondary),
                        ),
                        value: exportFavorites,
                        onChanged: (val) =>
                            setModalState(() => exportFavorites = val),
                      ),
                      SwitchListTile(
                        activeColor: context.ac.accentFrost,
                        title: Text(
                          'Web History',
                          style: TextStyle(color: context.ac.textPrimary),
                        ),
                        subtitle: Text(
                          '${_library.history.length} history entries',
                          style: TextStyle(color: context.ac.textSecondary),
                        ),
                        value: exportHistory,
                        onChanged: (val) =>
                            setModalState(() => exportHistory = val),
                      ),
                      SwitchListTile(
                        activeColor: context.ac.accentFrost,
                        title: Text(
                          'Saved Pages',
                          style: TextStyle(color: context.ac.textPrimary),
                        ),
                        subtitle: Text(
                          '${_library.savedPages.length} offline pages',
                          style: TextStyle(color: context.ac.textSecondary),
                        ),
                        value: exportSavedPages,
                        onChanged: (val) =>
                            setModalState(() => exportSavedPages = val),
                      ),
                      SwitchListTile(
                        activeColor: context.ac.accentFrost,
                        title: Text(
                          'Download History',
                          style: TextStyle(color: context.ac.textPrimary),
                        ),
                        subtitle: Text(
                          '${_downloadQueue.allTasks.length} tasks',
                          style: TextStyle(color: context.ac.textSecondary),
                        ),
                        value: exportQueue,
                        onChanged: (val) =>
                            setModalState(() => exportQueue = val),
                      ),
                      SwitchListTile(
                        activeColor: context.ac.accentFrost,
                        title: Text(
                          'App Settings',
                          style: TextStyle(color: context.ac.textPrimary),
                        ),
                        subtitle: Text(
                          'Toggles, concurrent limits, search engine defaults',
                          style: TextStyle(color: context.ac.textSecondary),
                        ),
                        value: exportSettings,
                        onChanged: (val) =>
                            setModalState(() => exportSettings = val),
                      ),
                      SwitchListTile(
                        activeColor: context.ac.accentFrost,
                        title: Text(
                          'Open Tabs',
                          style: TextStyle(color: context.ac.textPrimary),
                        ),
                        subtitle: Text(
                          '${_tabs.length} open tab(s)',
                          style: TextStyle(color: context.ac.textSecondary),
                        ),
                        value: exportTabs,
                        onChanged: (val) =>
                            setModalState(() => exportTabs = val),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: Text(
                              'Cancel',
                              style: TextStyle(color: context.ac.textSecondary),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            key: const Key('confirm_export_button'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: context.ac.accentFrost,
                              foregroundColor: context.ac.surfaceField,
                            ),
                          onPressed:
                              (!exportFavorites &&
                                  !exportHistory &&
                                  !exportSavedPages &&
                                  !exportQueue &&
                                  !exportSettings &&
                                  !exportTabs)
                              ? null
                              : () {
                                  Navigator.pop(ctx);
                                  unawaited(
                                    _performExport(
                                      exportFavorites: exportFavorites,
                                      exportHistory: exportHistory,
                                      exportSavedPages: exportSavedPages,
                                      exportQueue: exportQueue,
                                      exportSettings: exportSettings,
                                      exportTabs: exportTabs,
                                    ),
                                  );
                                },
                          child: const Text('Export'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _performExport({
    required bool exportFavorites,
    required bool exportHistory,
    required bool exportSavedPages,
    required bool exportQueue,
    required bool exportSettings,
    required bool exportTabs,
  }) async {
    try {
      final List<Map<String, dynamic>>? downloadQueueJson = exportQueue
          ? _downloadQueue.allTasks.map((t) => t.toJson()).toList()
          : null;
      final Map<String, dynamic>? settingsJson = exportSettings
          ? widget.settings.toJson()
          : null;
      final List<Map<String, dynamic>>? tabsJson = exportTabs
          ? _tabs.asMap().entries.map((e) => {
                'id': e.value.id,
                'url': e.value.addressController.text.trim(),
                'title': e.value.title,
                'active': e.key == _activeTabIndex,
              }).toList()
          : null;

      final file = await widget.libraryStore.exportToFile(
        exportFavorites: exportFavorites,
        exportHistory: exportHistory,
        exportSavedPages: exportSavedPages,
        downloadQueueJson: downloadQueueJson,
        settingsJson: settingsJson,
        tabsJson: tabsJson,
      );
      await PublicDownloadsService.shareFile(file.path);
    } catch (error) {
      _showSnack('Export failed: $error');
    }
  }

  Future<void> _importLibrary() async {
    try {
      // Ensure download paths are resolved before import processes queue tasks
      if (_baseDir == null) {
        await _initPaths();
      }

      final filePath = await PublicDownloadsService.pickImportFile();
      if (filePath == null) return;

      final Map<String, dynamic> decoded;
      if (filePath.toLowerCase().endsWith('.1dmbak')) {
        decoded = await IdmBackupParser.parse(filePath);
      } else {
        decoded = await widget.libraryStore.readImportMap(filePath);
      }

      final hasFavorites =
          decoded.containsKey('favorites') &&
          (decoded['favorites'] is List) &&
          (decoded['favorites'] as List).isNotEmpty;
      final hasHistory =
          decoded.containsKey('history') &&
          (decoded['history'] is List) &&
          (decoded['history'] as List).isNotEmpty;
      final hasSavedPages =
          decoded.containsKey('savedPages') &&
          (decoded['savedPages'] is List) &&
          (decoded['savedPages'] as List).isNotEmpty;
      final hasQueue =
          decoded.containsKey('downloadQueue') &&
          (decoded['downloadQueue'] is List) &&
          (decoded['downloadQueue'] as List).isNotEmpty;
      final hasSettings = decoded.containsKey('settings');

      final isLegacy =
          decoded.containsKey('favorites') ||
          decoded.containsKey('history') ||
          decoded.containsKey('savedPages') ||
          (!decoded.containsKey('settings') &&
              !decoded.containsKey('downloadQueue') &&
              decoded.isNotEmpty &&
              !decoded.containsKey('favorites') &&
              !decoded.containsKey('history') &&
              !decoded.containsKey('savedPages'));

      bool importFavorites = hasFavorites || isLegacy;
      bool importHistory = hasHistory || isLegacy;
      bool importSavedPages = hasSavedPages || isLegacy;
      bool importQueue = hasQueue;
      bool importSettings = hasSettings;

      if (!hasFavorites && !isLegacy) importFavorites = false;
      if (!hasHistory && !isLegacy) importHistory = false;
      if (!hasSavedPages && !isLegacy) importSavedPages = false;

      bool proceed = false;
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (context, setModalState) {
              return SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.file_download_outlined,
                            color: context.ac.accentFrost,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Import your data',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: context.ac.textPrimary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      SwitchListTile(
                        activeColor: context.ac.accentFrost,
                        title: Text(
                          'Favorites / Bookmarks',
                          style: TextStyle(color: context.ac.textPrimary),
                        ),
                        value: importFavorites,
                        onChanged: (hasFavorites || isLegacy)
                            ? (val) =>
                                  setModalState(() => importFavorites = val)
                            : null,
                      ),
                      SwitchListTile(
                        activeColor: context.ac.accentFrost,
                        title: Text(
                          'Web History',
                          style: TextStyle(color: context.ac.textPrimary),
                        ),
                        value: importHistory,
                        onChanged: (hasHistory || isLegacy)
                            ? (val) => setModalState(() => importHistory = val)
                            : null,
                      ),
                      SwitchListTile(
                        activeColor: context.ac.accentFrost,
                        title: Text(
                          'Saved Pages',
                          style: TextStyle(color: context.ac.textPrimary),
                        ),
                        value: importSavedPages,
                        onChanged: (hasSavedPages || isLegacy)
                            ? (val) =>
                                  setModalState(() => importSavedPages = val)
                            : null,
                      ),
                      SwitchListTile(
                        activeColor: context.ac.accentFrost,
                        title: Text(
                          'Download History (Queue)',
                          style: TextStyle(color: context.ac.textPrimary),
                        ),
                        value: importQueue,
                        onChanged: hasQueue
                            ? (val) => setModalState(() => importQueue = val)
                            : null,
                      ),
                      SwitchListTile(
                        activeColor: context.ac.accentFrost,
                        title: Text(
                          'App Settings',
                          style: TextStyle(color: context.ac.textPrimary),
                        ),
                        value: importSettings,
                        onChanged: hasSettings
                            ? (val) => setModalState(() => importSettings = val)
                            : null,
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: Text(
                              'Cancel',
                              style: TextStyle(color: context.ac.textSecondary),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: context.ac.accentFrost,
                              foregroundColor: context.ac.surfaceField,
                            ),
                            onPressed:
                                (!importFavorites &&
                                    !importHistory &&
                                    !importSavedPages &&
                                    !importQueue &&
                                    !importSettings)
                                ? null
                                : () {
                                    proceed = true;
                                    Navigator.pop(ctx);
                                  },
                            child: const Text('Import'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );

      if (!proceed) return;

      int importedFavoritesCount = 0;
      int importedHistoryCount = 0;
      int importedSavedPagesCount = 0;
      int importedQueueCount = 0;
      bool importedSettings = false;

      BrowserLibrary updatedLibrary = _library;

      // 1. App Settings
      if (importSettings && decoded.containsKey('settings')) {
        final settingsMap = decoded['settings'];
        if (settingsMap is Map) {
          final imported = DownloadSettings.fromJson(
            Map<String, dynamic>.from(settingsMap),
          );
          widget.onSettingsChanged?.call(imported);
          importedSettings = true;
        }
      }

      // 2. Download Queue
      if (importQueue && decoded.containsKey('downloadQueue')) {
        final queueList = decoded['downloadQueue'];
        if (queueList is List) {
          for (final item in queueList) {
            if (item is! Map) continue;
            try {
              final taskMap = Map<String, dynamic>.from(item);

              // Dynamic re-basing of savePath to the current base directory
              String savePath = taskMap['savePath'] as String? ?? '';
              final normalized = savePath.replaceAll('\\', '/');
              final completedIndex = normalized.lastIndexOf('/completed/');
              if (completedIndex != -1) {
                final relativePart = normalized.substring(
                  completedIndex + '/completed/'.length,
                );
                taskMap['savePath'] =
                    '$_baseDir${Platform.pathSeparator}completed${Platform.pathSeparator}${relativePart.replaceAll('/', Platform.pathSeparator)}';
              } else if (savePath.startsWith('completed/') ||
                  savePath.startsWith('completed\\')) {
                final relativePart = savePath.substring('completed/'.length);
                taskMap['savePath'] =
                    '$_baseDir${Platform.pathSeparator}completed${Platform.pathSeparator}${relativePart.replaceAll('/', Platform.pathSeparator).replaceAll('\\', Platform.pathSeparator)}';
              } else {
                final filename = p.basename(savePath);
                taskMap['savePath'] =
                    '$_baseDir${Platform.pathSeparator}completed${Platform.pathSeparator}$filename';
              }

              // Dynamic re-basing of tempDir to the current base temp directory
              String tempDir = taskMap['tempDir'] as String? ?? '';
              final normalizedTemp = tempDir.replaceAll('\\', '/');
              final tempIndex = normalizedTemp.lastIndexOf('/temp_');
              if (tempIndex != -1) {
                final relativePart = normalizedTemp.substring(tempIndex);
                taskMap['tempDir'] = '$_baseTemp$relativePart';
              } else {
                taskMap['tempDir'] =
                    '$_baseTemp${Platform.pathSeparator}temp_${DateTime.now().millisecondsSinceEpoch}_$importedQueueCount';
              }

              final task = DownloadTask.fromJson(taskMap);
              _downloadQueue.addTask(task);
              importedQueueCount++;
            } catch (_) {}
          }
        }
      }

      // 3. Browser Library - Favorites / Folders
      if (importFavorites && decoded.containsKey('favorites')) {
        final importedFolders = decoded.containsKey('folders')
            ? (decoded['folders'] as List? ?? const [])
                  .whereType<Map>()
                  .map(
                    (item) => BookmarkFolder.fromJson(
                      Map<String, dynamic>.from(item),
                    ),
                  )
                  .toList()
            : _library.folders;
        final known = {for (final folder in importedFolders) folder.id};
        final importedFavorites = (decoded['favorites'] as List? ?? const [])
            .whereType<Map>()
            .map(
              (item) =>
                  BrowserFavorite.fromJson(Map<String, dynamic>.from(item)),
            )
            .map((favorite) {
              if (favorite.folderId != null &&
                  !known.contains(favorite.folderId)) {
                return favorite.copyWith(clearFolder: true);
              }
              return favorite;
            })
            .toList();

        updatedLibrary = updatedLibrary.copyWith(
          favorites: importedFavorites,
          folders: importedFolders,
        );
        importedFavoritesCount = importedFavorites.length;
      }

      // 4. Browser Library - History
      if (importHistory && decoded.containsKey('history')) {
        final importedHistory = (decoded['history'] as List? ?? const [])
            .whereType<Map>()
            .map(
              (item) =>
                  BrowserHistoryEntry.fromJson(Map<String, dynamic>.from(item)),
            )
            .toList();
        updatedLibrary = updatedLibrary.copyWith(history: importedHistory);
        importedHistoryCount = importedHistory.length;
      }

      // 5. Browser Library - Saved Pages
      if (importSavedPages && decoded.containsKey('savedPages')) {
        final importedSavedPages = (decoded['savedPages'] as List? ?? const [])
            .whereType<Map>()
            .map((item) => SavedPage.fromJson(Map<String, dynamic>.from(item)))
            .toList();
        updatedLibrary = updatedLibrary.copyWith(
          savedPages: importedSavedPages,
        );
        importedSavedPagesCount = importedSavedPages.length;
      }

      if (importFavorites || importHistory || importSavedPages) {
        if (!decoded.containsKey('favorites') &&
            !decoded.containsKey('history') &&
            !decoded.containsKey('savedPages')) {
          final legacyLib = BrowserLibrary.fromJson(decoded);
          List<BrowserFavorite>? favs;
          List<BookmarkFolder>? folders;
          List<BrowserHistoryEntry>? hist;
          List<SavedPage>? saved;

          if (importFavorites) {
            favs = legacyLib.favorites;
            folders = legacyLib.folders;
            importedFavoritesCount = legacyLib.favorites.length;
          }
          if (importHistory) {
            hist = legacyLib.history;
            importedHistoryCount = legacyLib.history.length;
          }
          if (importSavedPages) {
            saved = legacyLib.savedPages;
            importedSavedPagesCount = legacyLib.savedPages.length;
          }

          updatedLibrary = updatedLibrary.copyWith(
            favorites: favs,
            folders: folders,
            history: hist,
            savedPages: saved,
          );
        }
        await _saveLibrary(updatedLibrary);
      }

      final List<String> summary = [];
      if (importedFavoritesCount > 0)
        summary.add('$importedFavoritesCount favorites');
      if (importedHistoryCount > 0)
        summary.add('$importedHistoryCount history entries');
      if (importedSavedPagesCount > 0)
        summary.add('$importedSavedPagesCount saved pages');
      if (importedQueueCount > 0)
        summary.add('$importedQueueCount download tasks');
      if (importedSettings) summary.add('app settings');

      if (summary.isEmpty) {
        _showSnack('Import completed (no new items found).');
      } else {
        _showSnack('Imported: ${summary.join(", ")}.');
      }
    } catch (error, stack) {
      debugPrint('[ImportLibrary] $error\n$stack');
      _showSnack('Import failed: $error');
    }
  }

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
      tab.title = _cleanTitle(title, url);
      tab.currentUrl = url;
      if (url != null && url.isNotEmpty) {
        _addressExpanded = false;
      }
    });
    if (recordHistory &&
        url != null &&
        url.isNotEmpty &&
        !url.startsWith('file:')) {
      await _recordHistory(url, tab.title ?? _titleForUrl(url));
    }
  }

  void _findNext(bool forward) {
    _findCurrentMatch = forward
        ? (_findCurrentMatch + 1).clamp(0, _findMatchCount - 1)
        : (_findCurrentMatch - 1).clamp(0, _findMatchCount - 1);
    _activeTab.controller.findNext(forward);
    if (_findCurrentMatch == 0 && !forward) {
      _findCurrentMatch = _findMatchCount - 1;
    }
    setState(() {});
  }

  void _dismissFind() {
    setState(() => _findVisible = false);
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
      _tabLifecycleController.closeAllTabs();
      setState(() {});
    },
    builtWebViewTabIds: _builtWebViewTabIds,
    onDropOnGroup: (draggedTabId, groupName) {
      final idx = _tabManager.indexOfTabId(draggedTabId);
      if (idx >= 0) {
        _tabManager.moveTabToGroup(_tabs[idx], groupName: groupName);
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

  Widget _buildTabCard(
    BuildContext ctx,
    BrowserTab tab,
    int originalIndex,
    void Function(void Function()) setTabsState,
  ) => buildTabCard(
    ctx,
    tab,
    originalIndex,
    setTabsState,
    tabs: _tabs,
    activeTabIndex: _activeTabIndex,
    onCloseTab: (index) {
      _tabLifecycleController.closeTab(index);
      setState(() {});
    },
    onSwitchToActiveTab: (index) {
      _switchToActiveTab(index);
      setState(() {});
    },
    getTabLabel: _tabLabel,
    builtWebViewTabIds: _builtWebViewTabIds,
  );

  void _showTabGroupMenu(
    BuildContext ctx,
    BrowserTab tab,
    void Function(void Function()) setTabsState,
  ) => showTabGroupMenu(
    context,
    tabs: _tabs,
    tab: tab,
    setTabsState: setTabsState,
    onSetState: () => setState(() {}),
    onShowCreateGroupDialog: (innerCtx, innerTab, innerSetState) =>
        _showCreateTabGroupDialog(innerCtx, innerTab, innerSetState),
    getTabLabel: _tabLabel,
  );

  void _showCreateTabGroupDialog(
    BuildContext ctx,
    BrowserTab tab,
    void Function(void Function()) setTabsState,
  ) => showCreateTabGroupDialog(
    ctx,
    tab: tab,
    setTabsState: setTabsState,
    onSetState: () => setState(() {}),
  );

  Future<void> _recordHistory(String url, String title) async {
    if (_privateMode) return;
    final existing = _library.history.where((entry) => entry.url != url);
    final history = [
      BrowserHistoryEntry(title: title, url: url, visitedAt: DateTime.now()),
      ...existing,
    ].toList();
    await _saveLibrary(_library.copyWith(history: history));
  }

  void _setupTabCallbacks(BrowserTab tab) {
    tab.controller.setOnUrlChanged((url) {
      if (!mounted) return;
      final changed =
          tab.currentUrl != url || tab.addressController.text != url;
      if (!changed) return;
      tab.addressController.text = url;
      tab.currentUrl = url;
      _sniffIntakeController.sniffBrowserUrl(tab, url, sourcePageUrl: url);
      _updateTabNavState(tab);
      if (mounted && tab == _activeTab) _debouncedNavSetState();
    });
    tab.controller.setOnPageStarted((url) {
      if (!mounted) return;
      tab.isLoading = true;
      tab.progress = 0;
      if (tab == _activeTab) {
        _progressNotifier.value = 0;
      }
      _lastScrollY = 0.0;
      if (!_barsVisible) {
        _barsVisible = true;
      }
      _fetchedIframeSrcs.clear();
      AuroraLog.instance.info(
        'Page started: $url',
        category: LogCategory.browser,
        screen: LogScreen.browser,
        eventType: LogEventType.navigation,
      );
      tab.authHeaderCache.clear();
      final navHost = Uri.tryParse(url)?.host;
      if (navHost != null) {
        _sniffIntakeController.clearCookieCacheForHost(navHost);
      }
      // Only clear the media cache when navigating to a genuinely different
      // page. The authority is the last *fully-loaded* main-frame URL
      // (`committedMainFrameUrl`, updated on onPageFinished), NOT the raw
      // onLoadStart url. Invisible JS navigations (ad insertion, analytics
      // `location.href` reassignments) and SPA `pushState` route changes
      // fire onLoadStart but never reach onPageFinished, so they keep the
      // previous committed URL and the cache is preserved. Same-URL reloads
      // also keep the cache. `_isDifferentPage` is an AND-guard against
      // WebView versions where onPageFinished timing is unreliable.
      final previousUrl = tab.committedMainFrameUrl;
      if (url != tab.committedMainFrameUrl &&
          _isDifferentPage(tab.currentUrl, url)) {
        AuroraLog.instance.debug(
          'Navigation: clearing media cache ($previousUrl -> $url)',
          category: LogCategory.sniffer,
          screen: LogScreen.browser,
          eventType: LogEventType.sniff,
        );
        tab.snifferEngine.clearCache();
        if (tab == _activeTab) {
          _latestVideoMedia = null;
        }
      } else {
        AuroraLog.instance.debug(
          'Same-page navigation ($url) — keeping media cache '
          '(${tab.snifferEngine.detectedMedia.length} items)',
          category: LogCategory.sniffer,
          screen: LogScreen.browser,
          eventType: LogEventType.sniff,
        );
      }
      _sniffIntakeController.sniffBrowserUrl(tab, url, sourcePageUrl: url);
      _updateTabNavState(tab);
      // Debounce setState — onPageStarted may fire for background tabs too.
      if (tab == _activeTab) {
        _debouncedNavSetState();
      }
    });
    tab.controller.setOnPageFinished((url) {
      if (!mounted) return;
      tab.isLoading = false;
      tab.progress = 0;
      // Record the last fully-loaded main-frame URL. This is the authority
      // used by setOnPageStarted to decide cache clearing — invisible JS
      // navigations never reach here, so they keep the previous value.
      tab.committedMainFrameUrl = url;
      _debouncedNavSetState();
      AuroraLog.instance.info(
        'Page finished: $url',
        category: LogCategory.browser,
        screen: LogScreen.browser,
        eventType: LogEventType.navigation,
      );
      _sniffIntakeController.sniffBrowserUrl(tab, url, sourcePageUrl: url);
      _updateTabNavState(tab);
      unawaited(_refreshPageInfo(tab, recordHistory: true));
      unawaited(_applyCosmeticRules(tab));
      unawaited(_saveTabs());
      _startVideoPoll(tab);
      _applyZoomForPage(tab, url);
      unawaited(_applyDarkModeForPage(tab, url));
      // Re-apply after guard/page scripts so the flag survives reinjection.
      unawaited(
        tab.controller.setReplaceSitePlayer(widget.settings.replaceSitePlayer),
      );
    });
    tab.controller.setOnProgressChanged((progress) {
      if (!mounted) return;
      tab.progress = progress;
      if (tab == _activeTab) {
        _progressNotifier.value = progress;
      }
    });
    tab.controller.setOnScrollPositionChange((x, y) {
      if (tab == _activeTab) {
        _onScroll(x, y);
      }
    });
    tab.controller.setOnRecreated(() {
      final url = tab.currentUrl ?? tab.addressController.text;
      if (url.isNotEmpty && url != 'about:blank') {
        unawaited(
          _loadUrlWithHostSettings(tab, Uri.parse(url), addToHistory: false),
        );
      }
    });
    // Synchronous nav-state callback — fires whenever the controller's
    // historyIndex changes, so the toolbar back/forward buttons update
    // instantly without an async round-trip to the WebView.
    tab.controller.setOnNavStateChanged(() {
      if (!mounted) return;
      final prevBack = tab.canGoBack;
      final prevForward = tab.canGoForward;
      tab.canGoBack = tab.controller.historyIndex > 0;
      tab.canGoForward =
          tab.controller.historyIndex < tab.controller.historyUrls.length - 1;
      if (tab.canGoBack != prevBack || tab.canGoForward != prevForward) {
        if (mounted) setState(() {});
      }
    });
    tab.controller.setOnStrictRedirectDetected((event) {
      _handleNativeStrictRedirect(tab, event);
    });
    tab.controller.addJavaScriptChannel(
      'MediaSnifferChannel',
      onMessageReceived: (message) {
        final url = message.trim();
        _sniffIntakeController.sniffBrowserUrl(
          tab,
          url,
          sourcePageUrl: tab.addressController.text,
        );
      },
    );
    tab.controller.addJavaScriptChannel(
      'MediaSniffer',
      onMessageReceived: (message) {
        final url = message.trim();
        _sniffIntakeController.sniffBrowserUrl(
          tab,
          url,
          sourcePageUrl: tab.addressController.text,
        );
      },
    );
    tab.controller.addJavaScriptChannel(
      'AdBlockerChannel',
      onMessageReceived: (message) {
        if (message == 'popup_blocked' &&
            mounted &&
            widget.settings.popupBlockingEnabled) {
          tab.controller.incrementBlockedPopups();
          if (mounted) setState(() {});
        }
      },
    );
    tab.controller.addJavaScriptChannel(
      'PopupBlockerChannel',
      onMessageReceived: (message) {
        _handlePopupEvent(tab, message);
      },
    );
    tab.controller.addJavaScriptChannel(
      'InvisibleRedirectChannel',
      onMessageReceived: (message) {
        _handleInvisibleRedirect(tab, message);
      },
    );
    tab.controller.addJavaScriptChannel(
      'ElementPickerChannel',
      onMessageReceived: (message) {
        unawaited(_handlePickedElement(tab, message));
      },
    );
    tab.controller.addJavaScriptChannel(
      'LinkContextChannel',
      onMessageReceived: (message) {
        _showElementContextMenu(message);
      },
    );
    tab.controller.addJavaScriptChannel(
      'AuroraPlayChannel',
      onMessageReceived: (message) {
        if (tab != _activeTab) return;
        unawaited(_handleAuroraPlayRequest(message));
      },
    );
    tab.controller.addJavaScriptChannel(
      'MediaMetaChannel',
      onMessageReceived: (message) {
        final capturedTab = tab;
        final pageUrl = capturedTab.addressController.text;
        _decodeJsInBackground(message).then((data) {
          if (data == null || !mounted) return;
          final src = data['src'] as String?;
          if (src != null && src.isNotEmpty) {
            _sniffIntakeController.sniffBrowserUrl(
              capturedTab,
              src,
              sourcePageUrl: pageUrl,
            );
          }
        });
      },
    );
    tab.controller.addJavaScriptChannel(
      'MediaSnifferDataChannel',
      onMessageReceived: (message) {
        final capturedTab = tab;
        final pageUrl = capturedTab.addressController.text;
        _decodeJsInBackground(message).then((data) {
          if (data == null || !mounted) return;
          final url = data['url'] as String?;
          final ct = data['contentType'] as String?;
          final clStr = data['contentLength'] as String?;
          final cl = (clStr != null && clStr.isNotEmpty)
              ? int.tryParse(clStr)
              : null;
          if (url != null && url.isNotEmpty) {
            _sniffIntakeController.sniffBrowserUrl(
              capturedTab,
              url,
              sourcePageUrl: pageUrl,
              contentType: ct,
              contentLength: cl,
            );
          }
        });
      },
    );
    tab.controller.addJavaScriptChannel(
      'PageMetaChannel',
      onMessageReceived: (message) {
        final capturedTab = tab;
        _decodeJsInBackground(message).then((data) {
          if (data == null || !mounted) return;
          final ogTitle = data['ogTitle'] as String?;
          final twitterTitle = data['twitterTitle'] as String?;
          final h1Title = data['h1Title'] as String?;
          final ldName = data['ldName'] as String?;
          final docTitle = data['title'] as String? ?? '';
          // Prefer the longest usable source. Playwright study of MissAV:
          // document.title is truncated (~55 chars); og:title / h1 / twitter
          // hold the full descriptive name (~273 chars).
          final resolvedTitle = FilenameService.pickBestTitle([
                ogTitle,
                twitterTitle,
                h1Title,
                ldName,
                docTitle,
              ]) ??
              '';
          capturedTab.pageMeta = PageMeta(
            title: resolvedTitle,
            videoWidth: int.tryParse((data['ogVideoWidth'] as String?) ?? ''),
            videoHeight: int.tryParse((data['ogVideoHeight'] as String?) ?? ''),
            structuredName: ldName,
          );
          // Backfill (or upgrade truncated) pageTitle on already-sniffed
          // media so downloads get the full title instead of URL slug /
          // short document.title.
          if (resolvedTitle.trim().isNotEmpty) {
            final title = resolvedTitle.trim();
            final media = capturedTab.snifferEngine.detectedMedia;
            for (var i = 0; i < media.length; i++) {
              final m = media[i];
              final existing = m.pageTitle?.trim() ?? '';
              if (existing.isEmpty || existing.length + 20 < title.length) {
                media[i] = m.copyWith(pageTitle: title);
              }
            }
          }
          if (mounted) setState(() {});
        });
      },
    );
    tab.controller.addJavaScriptChannel(
      'IframeSrcChannel',
      onMessageReceived: (message) {
        final url = message.trim();
        if (url.isNotEmpty) {
          _sniffIframeContent(tab, url);
        }
      },
    );

    tab.controller.addJavaScriptChannel(
      'HlsPlaylistChannel',
      onMessageReceived: (message) {
        final capturedTab = tab;
        _decodeJsInBackground(message)
            .then((data) {
              if (data == null || !mounted) return;
              final url = data['url'] as String?;
              final body = data['body'] as String?;
              if (url != null &&
                  body != null &&
                  url.isNotEmpty &&
                  body.isNotEmpty) {
                capturedTab.hlsPlaylistCache[url] = body;
                AuroraLog.instance.debug(
                  'HlsPlaylistChannel cached body for $url (${body.length} chars, cache size=${capturedTab.hlsPlaylistCache.length})',
                  category: LogCategory.sniffer,
                  screen: LogScreen.browser,
                  eventType: LogEventType.sniff,
                );
              }
            })
            .catchError((e) {
              AuroraLog.instance.error(
                'HlsPlaylistChannel error: $e',
                category: LogCategory.sniffer,
                screen: LogScreen.browser,
                eventType: LogEventType.error,
              );
            });
      },
    );
    tab.controller.setOnIframeMediaDetected((url) {
      _sniffIntakeController.sniffBrowserUrl(
        tab,
        url,
        sourcePageUrl: tab.addressController.text,
      );
    });
    // Capture native HLS playlist bodies (when the page uses Android WebView's
    // built-in HLS player, browser_guard.js can't see the request). Store the
    // body in the per-tab cache so the downloader uses the real playlist.
    tab.controller.setOnHlsPlaylistIntercepted((url, body) async {
      tab.hlsPlaylistCache[url] = body;
      AuroraLog.instance.debug(
        'Captured native HLS playlist body for $url (${body.length} chars)',
        category: LogCategory.hls,
        screen: LogScreen.browser,
        eventType: LogEventType.network,
      );
    });
    tab.controller.setOnDownloadStartRequest((url, suggestedFilename) async {
      // Always sniff the URL to capture browser context (cookies,
      // Referer, User-Agent), even when auto-downloading or prompting.
      await _sniffIntakeController.sniffWithLiveHeaders(
        tab,
        url,
        sourcePageUrl: tab.addressController.text,
      );

      if (!mounted) return;

      switch (widget.settings.downloadLinkBehavior) {
        case DownloadLinkBehavior.capture:
          // Default: sniff and show a snackbar so the user opens the
          // capture sheet to review and add to queue.
          _showSnack(
            suggestedFilename != null
                ? 'Captured $suggestedFilename — open the capture tray to add it to the queue.'
                : 'URL captured — open the capture tray to add it to the queue.',
          );
        case DownloadLinkBehavior.autoDownload:
          // Add directly to the download queue without prompting.
          await _enqueueDirectDownload(tab, url, suggestedFilename);
        case DownloadLinkBehavior.ask:
          // Show a dialog asking what to do.
          _showDownloadBehaviorPrompt(tab, url, suggestedFilename);
        case DownloadLinkBehavior.block:
          // Silently ignore — no snack, no queue entry.
          break;
      }

      _sniffIntakeController.scheduleMediaRebuild();
      _sniffIntakeController.scheduleMediaSave(tab);
    });

    // Track best video candidate for auto-replace when site play uses
    // blob/MSE (no direct URL). No floating button — toggle in Settings.
    tab.mediaSubscription?.cancel();
    tab.mediaSubscription = tab.snifferEngine.onMediaDetected.listen((media) {
      if (!mounted) return;
      if (media.type != MediaType.video && media.type != MediaType.playlist) {
        return;
      }
      if (tab != _activeTab) return;
      if (_shouldReplaceVideo(media)) {
        _latestVideoMedia = media;
      }
    });
  }

  /// Returns `true` if [incoming] should replace the current [_latestVideoMedia]
  /// used for auto-replace playback. Keeps the best candidate: HLS > large > other.
  bool _shouldReplaceVideo(SniffedMedia incoming) {
    final current = _latestVideoMedia;
    if (current == null) return true;

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

  static final RegExp _mediaFastPathRegExp = RegExp(
    r'\.(mp4|m3u8|webm|mkv|avi|flv|mov|3gp|ogv|wmv|m4v|f4v|mpeg|mpg|mts|m2ts|hevc|'
    r'mp3|wav|aac|ogg|m4a|flac|opus|wma|mid|midi|aiff|alac|'
    r'jpg|jpeg|png|gif|webp|bmp|svg|ico|avif|tiff|tif|heic|heif|psd|'
    r'pdf|epub|mobi|docx?|xlsx?|pptx?|txt|csv|tsv|rtf|'
    r'zip|rar|7z|tar|gz|bz2|xz|iso|cab|arj|lzh|ace|dmg|'
    r'srt|vtt|ass|ssa|sub|idx|exe|msi|apk|deb|rpm|AppImage|mpd|f4m|smil|m3u)'
    r'|/(?:hls|master|playlist|manifest|dash|media|stream|video|seg|chunk)/',
    caseSensitive: false,
  );

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
      AuroraLog.instance.error(
        'Iframe content fetch failed for $iframeSrcUrl: $e',
        category: LogCategory.sniffer,
        screen: LogScreen.browser,
        eventType: LogEventType.error,
      );
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
    _addressBarController.onAddressChanged(
      tab: _activeTab,
      library: _library,
      searchEngine: widget.settings.searchEngine,
      rebuild: () => setState(() {}),
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
  }) async {
    final host = uri.host.toLowerCase();
    SafeBrowsingResult safety;
    try {
      safety = await _safeBrowsing.check(uri.toString());
    } catch (e) {
      AuroraLog.instance.error(
        'Safe browsing check failed: $e',
        category: LogCategory.sniffer,
        screen: LogScreen.browser,
        eventType: LogEventType.error,
      );
      safety = const SafeBrowsingResult(verdict: SafeBrowsingVerdict.safe);
    }
    if (safety.verdict == SafeBrowsingVerdict.malicious) {
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
    final ua = _effectiveUserAgentFor(host);
    if (ua != null) {
      await tab.controller.setUserAgent(ua);
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
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber, color: Colors.redAccent),
            SizedBox(width: 8),
            Text('Phishing suspected'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(uri.toString()),
            const SizedBox(height: 8),
            Text(
              result.reason ?? 'This site is flagged as unsafe. Only open it if you are sure it is legitimate.',
              style: const TextStyle(fontSize: 12),
            ),
            if (result.source != null)
              Text(
                'Source: ${result.source}',
                style: TextStyle(
                  fontSize: 11,
                  color: ctx.ac.textSecondary,
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Stay safe'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Continue anyway'),
          ),
        ],
      ),
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
      background-color: #111418 !important;
      color: #E5E9F0 !important;
    }
    html.aurora-dark video,
    html.aurora-dark iframe,
    html.aurora-dark canvas {
      filter: invert(0.92) hue-rotate(180deg) !important;
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
    if (!mounted || !widget.settings.popupBlockingEnabled) return;
    Map<String, dynamic> data = {};
    try {
      final decoded = jsonDecode(rawMessage);
      if (decoded is Map) data = Map<String, dynamic>.from(decoded);
    } catch (_) {}
    final event = BlockedPopupEvent.fromJson(data);
    final url = event.url?.trim();
    tab.controller.incrementBlockedPopups();
    setState(() {});
    if (url == null || url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return;
    _suppressBlockedRedirectNoise(
      tab,
      url,
      reason: 'popup ad',
      userInitiated: event.userInitiated,
    );
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
    if (!mounted || !widget.settings.invisibleRedirectBlockingEnabled) return;
    Map<String, dynamic> data = {};
    try {
      final decoded = jsonDecode(rawMessage);
      if (decoded is Map) data = Map<String, dynamic>.from(decoded);
    } catch (_) {}
    final url = (data['url'] as String?)?.trim();
    if (url == null || url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return;
    final userInitiated = data['userInitiated'] as bool? ?? false;
    tab.controller.incrementBlockedInvisibleRedirects();
    setState(() {});
    _suppressBlockedRedirectNoise(
      tab,
      url,
      reason: 'invisible redirect',
      userInitiated: userInitiated,
    );
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
    _activeStrictRedirectPrompts.add(promptKey);
    _recentStrictRedirectPrompts[promptKey] = now;
    try {
      if (!mounted) return;
      final sourceHost = Uri.tryParse(sourcePageUrl ?? '')?.host;
      final targetHost = uri.host.isNotEmpty ? uri.host : url;
      final decision = await showDialog<_RedirectPromptAction>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) => AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.block, color: Colors.redAccent),
              const SizedBox(width: 8),
              Expanded(child: Text(title)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                targetHost,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (sourceHost != null && sourceHost.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  'From $sourceHost',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                method,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.of(ctx).pop(_RedirectPromptAction.ignore),
              child: const Text('Ignore'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(ctx).pop(_RedirectPromptAction.background),
              child: const Text('Background'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(ctx).pop(_RedirectPromptAction.currentTab),
              child: const Text('Current tab'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(ctx).pop(_RedirectPromptAction.foreground),
              child: const Text('New page'),
            ),
          ],
        ),
      );
      if (!mounted || !_tabs.contains(tab)) return;
      switch (decision) {
        case _RedirectPromptAction.foreground:
          _tabLifecycleController.openNewTab(
            url: url,
            insertAtIndex: _activeTabIndex + 1,
          );
          break;
        case _RedirectPromptAction.background:
          _tabLifecycleController.openNewTab(
            url: url,
            switchToTab: false,
            insertAtIndex: _activeTabIndex + 1,
            buildImmediately: true,
          );
          _showSnack('Opened in background: $targetHost');
          break;
        case _RedirectPromptAction.currentTab:
          unawaited(_loadUrlWithHostSettings(tab, uri));
          break;
        case _RedirectPromptAction.ignore:
        case null:
          _showSnack('Ignored redirect to $targetHost');
          break;
      }
    } finally {
      _activeStrictRedirectPrompts.remove(promptKey);
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
      // Check whether we added a cosmetic rule vs a network rule.
      final hasNewCosmeticRule =
          updatedSettings.manualCosmeticRules.length >
          previousSettings.manualCosmeticRules.length;
      final hasNewNetworkRule =
          updatedSettings.manualAdBlockRules.length >
          previousSettings.manualAdBlockRules.length;

      if (hasNewCosmeticRule) {
        // Inject CSS to hide the element right away.
        await _applyCosmeticRules(tab, settings: updatedSettings);
      }
      if (hasNewNetworkRule) {
        // Reconfigure the adblock engine to block the new domain.
        await tab.controller.configureAdBlock(
          enabled: widget.settings.adblockEnabled,
          popupBlockingEnabled: widget.settings.popupBlockingEnabled,
          filterSources: widget.settings.adblockFilterSources,
          manualRules: updatedSettings.manualAdBlockRules,
          cosmeticRules: updatedSettings.manualCosmeticRules,
        );
      }
    }
    // Undo snackbar
    if (mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Element blocked. Undo?'),
          duration: const Duration(seconds: 3),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () {
              widget.onSettingsChanged?.call(previousSettings);
              unawaited(_applyCosmeticRules(tab, settings: previousSettings));
            },
          ),
        ),
      );
    }
  }

  Future<void> _applyCosmeticRules(
    BrowserTab tab, {
    DownloadSettings? settings,
  }) => _elementPickerController.applyCosmeticRules(
    tab,
    settings: settings ?? widget.settings,
  );

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

  Widget _buildSuggestionPanel() {
    return ListView.builder(
      key: const Key('address_suggestion_panel'),
      padding: EdgeInsets.zero,
      itemCount: _addressSuggestions.length,
      itemBuilder: (context, i) {
        final suggestion = _addressSuggestions[i];
        final icon = switch (suggestion.kind) {
          AddressSuggestionKind.favorite => Icons.star,
          AddressSuggestionKind.history => Icons.history,
          AddressSuggestionKind.search => Icons.search,
        };
        return InkWell(
          onTap: () => _acceptSuggestion(suggestion),
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: context.ac.surfaceElevated,
                  width: 0.5,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(icon, size: 16, color: context.ac.accentFrost),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    suggestion.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: context.ac.textPrimary,
                    ),
                  ),
                ),
                Text(
                  suggestion.url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: context.ac.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTabStrip() {
    final ac = context.ac;
    final activeColor = _privateMode
        ? ac.accentPurple
        : ac.accentFrost;
    return Container(
      key: const Key('browser_tab_strip'),
      height: 34,
      color: ac.dockSurface,
      child: Row(
        children: [
          if (_privateMode)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Center(
                child: Icon(
                  Icons.visibility_off_outlined,
                  size: 12,
                  color: ac.accentPurple,
                ),
              ),
            ),
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _tabs.length,
              itemBuilder: (_, i) {
                final tab = _tabs[i];
                final isActive = i == _activeTabIndex;
                return GestureDetector(
                  onTap: () => _switchToActiveTab(i),
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 120),
                    margin: const EdgeInsets.symmetric(
                      horizontal: 2,
                      vertical: 4,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: isActive
                          ? activeColor.withOpacity(0.15)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            TabManager.tabLabel(tab),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: isActive
                                  ? activeColor
                                  : ac.textSecondary,
                            ),
                          ),
                        ),
                        if (_tabs.length > 1)
                          GestureDetector(
                            key: Key('browser_tab_close_$i'),
                            onTap: () => _tabLifecycleController.closeTab(i),
                              child: Padding(
                                padding: const EdgeInsets.only(left: 4),
                                child: Icon(
                                  Icons.close,
                                  size: 12,
                                  color: ac.textSecondary,
                                ),
                              ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          IconButton(
            icon: Icon(
              Icons.add,
              size: 16,
              color: ac.textSecondary,
            ),
            onPressed: () => _tabLifecycleController.openNewTab(),
            tooltip: 'New tab',
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tab = _activeTab;
    final sniffedCount = tab.snifferEngine.detectedMedia.length;
    final suggestionHeight = _addressExpanded && _addressSuggestions.isNotEmpty
        ? (_addressSuggestions.length * 44.0 + 8.0).clamp(0.0, 280.0)
        : 0.0;
    // Top bar: only the find bar. Suggestions are now rendered as an overlay
    // above the address bar in the bottom bar so they sit next to the field
    // they belong to.
    final double topHeight = _findVisible ? 54.0 : 0.0;

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
                          Row(
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(left: 12),
                                child: IconButton(
                                  key: const Key('browser_star_button'),
                                  icon: Icon(
                                    _isCurrentPageFavorited()
                                        ? Icons.star
                                        : Icons.star_border,
                                    color: _isCurrentPageFavorited()
                                        ? context.ac.accentAmber
                                        : context.ac.textSecondary,
                                    size: 18,
                                  ),
                                  onPressed: _toggleFavorite,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 32,
                                    minHeight: 32,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
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
                              if (_addressExpanded)
                                IconButton(
                                  key: const Key('sniffer_go_button'),
                                  icon: const Icon(
                                    Icons.arrow_forward,
                                    size: 18,
                                  ),
                                  onPressed: () => _loadAddress(),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 36,
                                    minHeight: 36,
                                  ),
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
            // Suggestion panel overlay above the address bar pill
            if (_addressExpanded && _addressSuggestions.isNotEmpty)
              Positioned(
                bottom: addressBarHeight + tabStripHeight + 16,
                left: 8,
                right: 8,
                height: suggestionHeight,
                child: Material(
                  elevation: 12,
                  color: context.ac.overlay,
                  borderRadius: BorderRadius.circular(16),
                  child: _buildSuggestionPanel(),
                ),
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
              final isRealWebView =
                  t.controller is SnifferWebViewControllerImpl;
              if (isActive && (_tabsLoaded || !isRealWebView)) {
                _builtWebViewTabIds.add(t.id);
              }
              if (!_tabsLoaded && isRealWebView) {
                _builtWebViewTabIds.clear();
              }
              final shouldBuild = _builtWebViewTabIds.contains(t.id);
              // Seed first paint from address bar / committed URL so external
              // opens (Queue source page) navigate even if loadRequest races.
              final seedUrl = () {
                final fromAddress = t.addressController.text.trim();
                if (fromAddress.isNotEmpty) return fromAddress;
                final fromCurrent = t.currentUrl?.trim();
                if (fromCurrent != null && fromCurrent.isNotEmpty) {
                  return fromCurrent;
                }
                return null;
              }();
              return Positioned.fill(
                child: Offstage(
                  offstage: !isActive,
                  child: shouldBuild
                      ? BrowserWidget(
                          key: ValueKey(t.id),
                          controller: t.controller,
                          initialUrl: seedUrl,
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
            children: [
              webView,
              topBar,
              bottomBar,
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
        child: _PickerCancelChip(
          key: const Key('cancel_picker_button'),
          onCancel: () => _cancelElementPicker(),
        ),
      ),
    );
  }

  /// Unified bottom strip — browser nav (back/forward/tabs) +
  /// Unified bottom strip — a two-slide browser dock.
  ///
  /// Slide 1: Backward · Forward · Sniffer · Download · Tab
  /// Slide 2: Browser Tools · Settings
  /// Swipe horizontally to switch slides.
  Widget _buildConsolidatedStrip(BrowserTab tab, double height) {
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
          child: _BrowserDock(
            tab: tab,
            onSniffer: _showSniffedMediaSheet,
            onDownload: () => widget.onOpenQueue?.call(),
            onTab: _showTabsSheet,
            onBrowserTools: _showBrowserMenuSheet,
            onSettings: () => widget.onOpenSettings?.call(),
            onHistory: _showHistorySheet,
            onBookmarks: _showFavoritesSheet,
          ),
        ),
      ),
    );
  }

  /// Builds the adblock shield icon shown in the consolidated nav strip.
  /// - Green shield + blocked-count badge: adblock active and current site
  ///   is not in the per-site allowlist.
  /// - Grey outlined shield: current site is in the per-site allowlist
  ///   (adblock bypassed for this host only).
  /// - Red shield: adblock is globally disabled in settings.
  ///
  /// Tapping the shield opens a popup where the user can add or remove the
  /// current host from the per-site allowlist.
  Widget _buildAdblockShieldButton(BrowserTab tab) {
    final settings = widget.settings;
    final host = Uri.tryParse(tab.currentUrl ?? '')?.host ?? '';
    final isAllowlisted =
        host.isNotEmpty && settings.adblockAllowlist.contains(host);
    final blocked = tab.controller.blockedRequestCount;
    final IconData icon;
    final Color color;
    if (!settings.adblockEnabled) {
      icon = Icons.shield;
      color = Colors.redAccent;
    } else if (isAllowlisted) {
      icon = Icons.shield_outlined;
      color = context.ac.textSecondary;
    } else {
      icon = Icons.shield;
      color = Colors.green;
    }
    return Material(
      key: const Key('browser_adblock_shield'),
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _showAdblockPopup(tab),
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: context.ac.glassSurface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: context.ac.glassBorder),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(icon, size: 20, color: color),
              if (blocked > 0)
                Positioned(
                  right: -6,
                  top: -4,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: Colors.red,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 14,
                      minHeight: 14,
                    ),
                    child: Text(
                      blocked > 99 ? '99+' : '$blocked',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 8,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
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
    return SizedBox(
      height: 54.0,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: context.ac.overlaySurface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: context.ac.borderStrong),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _findController,
                    autofocus: true,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Find in page',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixText: _findMatchCount > 0
                          ? '${_findCurrentMatch + 1}/$_findMatchCount'
                          : null,
                    ),
                    onChanged: (value) {
                      _activeTab.controller.findAllAsync(value);
                    },
                    onSubmitted: (value) {
                      _findNext(true);
                    },
                  ),
                ),
                IconButton(
                  tooltip: 'Previous',
                  icon: const Icon(Icons.keyboard_arrow_up),
                  onPressed: () => _findNext(false),
                ),
                IconButton(
                  tooltip: 'Next',
                  icon: const Icon(Icons.keyboard_arrow_down),
                  onPressed: () => _findNext(true),
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close),
                  onPressed: _dismissFind,
                ),
              ],
            ),
          ),
        ),
      ),
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

  String? _contextString(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  void _openContextTarget(BrowserTab tab, String targetUrl) {
    openContextTarget(
      context,
      tab: tab,
      targetUrl: targetUrl,
      onLoadUrl: (uri) => _loadUrlWithHostSettings(tab, uri),
      onShowSnack: _showSnack,
      isMounted: mounted,
    );
  }

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
        reloadForFreshUrl: (tab, sourcePageUrl, {bool forceReload = false}) =>
            _reloadForFreshUrl(tab, sourcePageUrl, forceReload: forceReload),
        isMounted: mounted,
      );

  /// Wire live WebView bridges onto [task] (cookies, JS fetch, token refresh).
  /// Called by [DownloadQueue.browserContextAttacher] before every start/retry
  /// so queue rows restored from JSON after app restart regain WAF bypass.
  void _attachBrowserContextToTask(DownloadTask task) {
    if (_tabs.isEmpty) return;
    final tab = _findTabForTask(task) ?? _activeTab;
    final sourcePage = task.sourcePageUrl ?? tab.addressController.text;

    task.fetchViaWebView = (fetchUrl, {Map<String, String>? headers}) =>
        tab.controller.fetchViaJavaScript(fetchUrl, headers: headers);
    task.fetchBinaryViaWebView =
        (binaryUrl) => tab.controller.fetchBinaryViaJavaScript(binaryUrl);
    task.hlsPlaylistCache = (cacheUrl) => tab.hlsPlaylistCache[cacheUrl];
    task.cookieProvider =
        (url) => tab.controller.getCookiesForDomain(url: url);
    task.onTokenExpired = ({bool forceReload = false}) =>
        _reloadForFreshUrl(tab, sourcePage, forceReload: forceReload);
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

    // Strategy 2: Reload the page, give JS time to run, then query the DOM
    final srcUrl = sourcePageUrl ?? tab.addressController.text;
    if (!srcUrl.startsWith('http')) return null;
    await tab.controller.loadRequest(Uri.parse(srcUrl));

    // Give the page time to load and execute the JS that sets video src
    await Future.delayed(const Duration(seconds: 3));

    final fromReloaded = await _queryHlsFromPage(tab);
    if (fromReloaded != null) return fromReloaded;

    // Strategy 3: Wait for the sniffer's MediaSnifferDataChannel handler
    // (in case the page's JS sets the src after a longer delay)
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
      final result = await tab.controller.evaluateJavaScript('''
        (() => {
          function findHls(root) {
            if (!root || !root.querySelectorAll) return '';
            const sources = root.querySelectorAll('source[src]');
            for (const s of sources) {
              const src = s.src || s.getAttribute('src') || '';
              if (src && src.indexOf('.m3u8') !== -1 && src.indexOf('ping.m3u8') === -1 && src.indexOf('/ping') === -1) return src;
            }
            const medias = root.querySelectorAll('video, audio');
            for (const m of medias) {
              const src = m.currentSrc || m.src || '';
              if (src && src.indexOf('.m3u8') !== -1 && src.indexOf('ping.m3u8') === -1 && src.indexOf('/ping') === -1) return src;
            }
            const scripts = root.querySelectorAll('script');
            for (const sc of scripts) {
              const text = sc.textContent || '';
              const match = text.match(/https?:\\/\\/[^"\\\\s]+\\.m3u8[^"\\\\s]*/);
              if (match) {
                const u = match[0];
                if (u.indexOf('ping.m3u8') === -1 && u.indexOf('/ping') === -1) return u;
              }
            }
            return '';
          }
          let url = findHls(document);
          if (url) return url;
          const iframes = document.querySelectorAll('iframe');
          for (const iframe of iframes) {
            try {
              url = findHls(iframe.contentDocument);
              if (url) return url;
            } catch (e) {}
          }
          return '';
        })()
      ''');
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

  String _truncateFilename(
    String name, {
    int maxLength = FilenameService.defaultMaxFileNameBytes,
  }) {
    return FilenameService.truncate(name, maxBytes: maxLength);
  }

  static String truncateFilename(
    String name, {
    int maxLength = FilenameService.defaultMaxFileNameBytes,
  }) {
    return FilenameService.truncate(name, maxBytes: maxLength);
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
      _showSnack('Bookmark removed.');
      return;
    }

    final title = _cleanTitle(await tab.controller.pageTitle(), url);
    final selection = await _promptFavoriteFolder();
    if (selection == null) return;
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
    _showSnack(
      selection.folderId == null
          ? 'Favorite added.'
          : 'Favorite added to ${selection.folderName ?? 'folder'}.',
    );
  }

  Future<FavoriteSelection?> _promptFavoriteFolder() async {
    final folders = List<BookmarkFolder>.from(_library.folders);
    String? folderId;
    final tagsController = TextEditingController();
    final newFolderController = TextEditingController();
    final result = await showDialog<FavoriteSelection>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Add to favorites'),
          content: StatefulBuilder(
            builder: (ctx, setLocal) {
              return SizedBox(
                width: 320,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Folder', style: TextStyle(fontSize: 12)),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String?>(
                      value: folderId,
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: 'Unsorted',
                      ),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('Unsorted'),
                        ),
                        for (final folder in folders)
                          DropdownMenuItem<String?>(
                            value: folder.id,
                            child: Text(folder.name),
                          ),
                      ],
                      onChanged: (value) => setLocal(() => folderId = value),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: newFolderController,
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: 'Create new folder',
                        prefixIcon: Icon(Icons.create_new_folder_outlined),
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextButton.icon(
                      onPressed: () {
                        final name = newFolderController.text.trim();
                        if (name.isEmpty) return;
                        final newFolder = BookmarkFolder(
                          id: DateTime.now().microsecondsSinceEpoch.toString(),
                          name: name,
                          createdAt: DateTime.now(),
                        );
                        folders.add(newFolder);
                        folderId = newFolder.id;
                        newFolderController.clear();
                        setLocal(() {});
                      },
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Add folder'),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: tagsController,
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: 'Tags (comma separated)',
                        prefixIcon: Icon(Icons.label_outline),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                final tags = tagsController.text
                    .split(',')
                    .map((tag) => tag.trim())
                    .where((tag) => tag.isNotEmpty)
                    .toList(growable: false);
                Navigator.of(ctx).pop(
                  FavoriteSelection(
                    folderId: folderId,
                    folderName: folderId == null
                        ? null
                        : folders
                              .where((folder) => folder.id == folderId)
                              .map((folder) => folder.name)
                              .firstOrNull,
                    tags: tags,
                    updatedFolders: folders,
                  ),
                );
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    tagsController.dispose();
    newFolderController.dispose();
    return result;
  }

  Future<void> _saveCurrentPage() async {
    final tab = _activeTab;
    final url = await tab.controller.currentUrl();
    if (url == null || url.isEmpty || url.startsWith('file:')) return;
    setState(() => _isSavingPage = true);
    try {
      final title = _cleanTitle(await tab.controller.pageTitle(), url);
      final result = await tab.controller.evaluateJavaScript(
        'document.documentElement.outerHTML',
      );
      final html = _injectBaseTag(_normalizeJsString(result), url);
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

  Future<void> _shareCurrentUrlViaSystem() async {
    final url = await _activeTab.controller.currentUrl();
    if (url == null || url.isEmpty) {
      _showSnack('Nothing to share — no page is loaded.');
      return;
    }
    try {
      await PublicDownloadsService.shareUrl(url);
    } catch (error) {
      _showSnack('Could not share this page: $error');
    }
  }

  double _effectiveZoomFor(String host) {
    return widget.settings.siteZoomLevels[host.toLowerCase()] ?? 1.0;
  }

  String? _effectiveUserAgentFor(String host) {
    final mapped = widget.settings.siteUserAgents[host.toLowerCase()];
    if (mapped != null && mapped.isNotEmpty) return mapped;
    // If desktopMode is true (legacy setting) use desktop Chrome UA.
    if (_desktopMode) return _uaForProfile('desktop_chrome');
    // Otherwise, respect the full profile when there is no per-site override.
    final profile = widget.settings.userAgentProfile;
    if (profile != 'mobile') return _uaForProfile(profile);
    return null;
  }

  Map<String, String> _baseRequestHeaders() {
    if (!widget.settings.doNotTrackEnabled) return const {};
    return const {'DNT': '1', 'Sec-GPC': '1'};
  }

  void _persistSiteZoom(String host, double scale) {
    final clamped = scale.clamp(0.5, 3.0).toDouble();
    final updated = Map<String, double>.from(widget.settings.siteZoomLevels);
    if ((clamped - 1.0).abs() < 0.01) {
      updated.remove(host.toLowerCase());
    } else {
      updated[host.toLowerCase()] = double.parse(clamped.toStringAsFixed(2));
    }
    widget.onSettingsChanged?.call(
      widget.settings.copyWith(siteZoomLevels: updated),
    );
  }

  Future<void> _adjustCurrentZoom(double delta) async {
    final tab = _activeTab;
    final currentUrl = await tab.controller.currentUrl();
    if (currentUrl == null || currentUrl.isEmpty) {
      _showSnack('Open a page to zoom.');
      return;
    }
    final host = (Uri.tryParse(currentUrl)?.host ?? '').toLowerCase();
    if (host.isEmpty) {
      _showSnack('Could not detect the current site to zoom.');
      return;
    }
    final newScale = (_effectiveZoomFor(host) + delta).clamp(0.5, 3.0);
    await tab.controller.setZoomScale(newScale);
    _persistSiteZoom(host, newScale);
  }

  Future<void> _resetCurrentZoom() async {
    final tab = _activeTab;
    final currentUrl = await tab.controller.currentUrl();
    final host = (Uri.tryParse(currentUrl ?? '')?.host ?? '').toLowerCase();
    await tab.controller.setZoomScale(1.0);
    if (host.isNotEmpty) _persistSiteZoom(host, 1.0);
  }

  /// Shows a dialog to pick the global User-Agent profile.  The selection
  /// is persisted in [DownloadSettings.userAgentProfile] and applied
  /// immediately to all browser tabs.  Use _editSiteUserAgent for per-site
  /// overrides.
  Future<void> _showUserAgentSelector() async {
    final current = widget.settings.userAgentProfile;
    final profiles = _uaProfiles.keys.toList();
    final labels = profiles.map((k) => _uaProfileLabels[k] ?? k).toList();

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Select User-Agent'),
        backgroundColor: context.ac.surfacePanel,
        children: [
          for (var i = 0; i < profiles.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            RadioListTile<String>(
              title: Text(labels[i]),
              value: profiles[i],
              groupValue: current,
              onChanged: (value) {
                Navigator.of(ctx).pop(value);
              },
            ),
          ],
          const Divider(height: 1),
          // Also offer the per-site custom override editor
          TextButton.icon(
            icon: const Icon(Icons.edit, size: 18),
            label: const Text('Custom per-site…'),
            onPressed: () {
              Navigator.of(ctx).pop('__custom__');
            },
          ),
        ],
      ),
    );
    if (result == null || result == current) return;

    if (result == '__custom__') {
      final currentUrl = _activeTab.addressController.text.trim();
      if (currentUrl.isNotEmpty) {
        unawaited(_editSiteUserAgent(currentUrl));
      } else {
        _showSnack('Open a page first to set a custom user agent.');
      }
      return;
    }

    widget.onSettingsChanged?.call(
      widget.settings.copyWith(userAgentProfile: result),
    );

    // Apply the new UA to all tabs immediately
    final ua = _uaForProfile(result);
    for (final tab in _tabs) {
      await tab.controller.setUserAgent(ua);
    }
    if (_activeTab.addressController.text.isNotEmpty) {
      await _activeTab.controller.reload();
    }
    _showSnack('UA switched to ${_uaProfileLabels[result] ?? result}.');
  }

  Future<void> _editSiteUserAgent(String currentUrl) async {
    final host = (Uri.tryParse(currentUrl)?.host ?? '').toLowerCase();
    if (host.isEmpty) {
      _showSnack('Open a page first to set a custom UA.');
      return;
    }
    final existing = widget.settings.siteUserAgents[host] ?? '';
    final controller = TextEditingController(text: existing);
    final next = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('User agent for $host'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          minLines: 1,
          decoration: const InputDecoration(
            hintText:
                'Mozilla/5.0 ... (leave empty to use default / desktop UA)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (next == null) return;
    final updated = Map<String, String>.from(widget.settings.siteUserAgents);
    if (next.isEmpty) {
      updated.remove(host);
    } else {
      updated[host] = next;
    }
    widget.onSettingsChanged?.call(
      widget.settings.copyWith(siteUserAgents: updated),
    );
    final ua = _effectiveUserAgentFor(host);
    if (ua != null) {
      await _activeTab.controller.setUserAgent(ua);
    }
    await _activeTab.controller.reload();
    _showSnack('Custom UA saved for $host.');
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
  );

  Widget _buildFavoritesFolderList(
    BrowserTab tab,
    BookmarkFolder folder,
    List<BrowserFavorite> items,
  ) => buildFavoritesFolderList(
    context,
    tab,
    folder,
    items,
    library: _library,
    unsortedFolder: _unsortedFolder,
    isCurrentPageFavorited: (_) => _isCurrentPageFavorited(),
    onSaveLibrary: _saveLibrary,
    onLoadUrl: (url) => _loadUrlWithHostSettings(tab, Uri.parse(url)),
    onFavoriteToggled: () => setState(() {}),
    onNewFolderCreated: () async {
      if (mounted) {
        setState(() {});
      }
    },
    onEditFavorite: (favorite) => _editFavoriteFolder(favorite),
  );

  Future<BrowserLibrary?> _editFavoriteFolder(BrowserFavorite favorite) async {
    final folders = List<BookmarkFolder>.from(_library.folders);
    String? folderId = favorite.folderId;
    final tagsController = TextEditingController(
      text: favorite.tags.join(', '),
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit favorite'),
        content: StatefulBuilder(
          builder: (ctx, setLocal) => SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Folder', style: TextStyle(fontSize: 12)),
                const SizedBox(height: 6),
                DropdownButtonFormField<String?>(
                  value: folderId,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'Unsorted',
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('Unsorted'),
                    ),
                    for (final folder in folders)
                      DropdownMenuItem<String?>(
                        value: folder.id,
                        child: Text(folder.name),
                      ),
                  ],
                  onChanged: (value) => setLocal(() => folderId = value),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: tagsController,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'Tags (comma separated)',
                    prefixIcon: Icon(Icons.label_outline),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved != true) {
      tagsController.dispose();
      return null;
    }
    final tags = tagsController.text
        .split(',')
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty)
        .toList(growable: false);
    tagsController.dispose();
    final updatedLib = _library.copyWith(
      favorites: _library.favorites
          .map(
            (fav) => fav.id == favorite.id
                ? fav.copyWith(
                    folderId: folderId,
                    clearFolder: folderId == null,
                    tags: tags,
                  )
                : fav,
          )
          .toList(growable: false),
    );
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

  void _showBrowserMenuSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      backgroundColor: context.ac.overlay,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final settings = widget.settings;
        final host = Uri.tryParse(_activeTab.currentUrl ?? '')?.host ?? '';
        final isAllowlisted = host.isNotEmpty && settings.adblockAllowlist.contains(host);
        return SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Browser Tools',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: ctx.ac.textPrimary,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Blocked popups: ${_activeTab.controller.blockedPopupsCount}',
                    style: TextStyle(
                      fontSize: 12,
                      color: ctx.ac.textSecondary,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  GridView.count(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisCount: 3,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 1.1,
                    children: [
                      _buildMenuItem(
                        icon: Icons.star_rounded,
                        label: 'Favorites',
                        color: ctx.ac.accentAmber,
                        onTap: () {
                          Navigator.pop(ctx);
                          _showFavoritesSheet();
                        },
                      ),
                      _buildMenuItem(
                        icon: Icons.offline_pin_rounded,
                        label: 'Saved Pages',
                        color: Colors.green,
                        onTap: () {
                          Navigator.pop(ctx);
                          _showSavedPagesSheet();
                        },
                      ),
                      _buildMenuItem(
                        icon: Icons.save_alt_rounded,
                        label: 'Save Page',
                        color: Colors.green,
                        onTap: () {
                          Navigator.pop(ctx);
                          unawaited(_saveCurrentPage());
                        },
                      ),
                      _buildMenuItem(
                        icon: Icons.history_rounded,
                        label: 'History',
                        color: Colors.blue,
                        onTap: () {
                          Navigator.pop(ctx);
                          _showHistorySheet();
                        },
                      ),
                      _buildMenuItem(
                        icon: Icons.find_in_page_rounded,
                        label: 'Find in Page',
                        color: Colors.purple,
                        onTap: () {
                          Navigator.pop(ctx);
                          setState(() => _findVisible = true);
                        },
                      ),
                      _buildMenuItem(
                        icon: Icons.assignment_ind_rounded,
                        label: 'Autofill',
                        color: Colors.teal,
                        onTap: () {
                          Navigator.pop(ctx);
                          unawaited(_showAutofillMenu());
                        },
                      ),
                      _buildMenuItem(
                        icon: Icons.chrome_reader_mode_rounded,
                        label: 'Reader Mode',
                        color: Colors.orange,
                        onTap: () {
                          Navigator.pop(ctx);
                          unawaited(_showReaderMode());
                        },
                      ),
                      _buildMenuItem(
                        icon: Icons.ads_click,
                        label: 'Block Element',
                        color: Colors.redAccent,
                        onTap: () {
                          Navigator.pop(ctx);
                          unawaited(_startElementPicker());
                        },
                      ),
                      _buildMenuItem(
                        icon: Icons.undo,
                        label: 'Reset Blocks',
                        color: ctx.ac.textSecondary,
                        onTap: () {
                          Navigator.pop(ctx);
                          _resetPageElementBlocks();
                        },
                      ),
                      _buildMenuItem(
                        icon: !settings.adblockEnabled
                            ? Icons.shield
                            : (isAllowlisted ? Icons.shield_outlined : Icons.shield),
                        label: !settings.adblockEnabled
                            ? 'Adblock: Off'
                            : (isAllowlisted ? 'Ads Allowed' : 'Adblock: On'),
                        color: !settings.adblockEnabled
                            ? Colors.redAccent
                            : (isAllowlisted ? ctx.ac.textSecondary : Colors.green),
                        onTap: () {
                          Navigator.pop(ctx);
                          _showAdblockPopup(_activeTab);
                        },
                      ),
                      _buildMenuItem(
                        icon: Icons.refresh_rounded,
                        label: 'Re-scan',
                        color: Colors.cyanAccent,
                        onTap: () {
                          Navigator.pop(ctx);
                          unawaited(_rescanPageMedia());
                        },
                      ),
                      _buildMenuItem(
                        icon: Icons.cookie_rounded,
                        label: 'Clear Cookies',
                        color: Colors.redAccent,
                        onTap: () {
                          Navigator.pop(ctx);
                          unawaited(
                            _activeTab.controller.currentUrl().then((url) {
                              if (url != null && url.isNotEmpty) {
                                unawaited(_clearDataForSite(url));
                              }
                            }),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildMenuItem({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.white.withOpacity(0.05),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 22),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                style: TextStyle(
                  color: context.ac.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
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
  );

  void _showLibrarySheet<T>({
    required String title,
    required String emptyText,
    required List<T> items,
    required String Function(T item) titleFor,
    required String Function(T item) subtitleFor,
    required IconData Function(T item) iconFor,
    required FutureOr<void> Function(T item) onOpen,
    required FutureOr<void> Function(T item) onDelete,
  }) => showLibrarySheet<T>(
    context,
    title: title,
    emptyText: emptyText,
    items: items,
    titleFor: titleFor,
    subtitleFor: subtitleFor,
    iconFor: iconFor,
    onOpen: onOpen,
    onDelete: onDelete,
  );

  /// Opens the Aurora player, showing a quality picker if the detected
  /// video is an HLS master playlist with variants.
  Future<void> _openVideoPlayer(SniffedMedia media) async {
    if (media.url.contains('.m3u8') || media.url.contains('mpegurl')) {
      // Check for enriched variants from the same master.
      final variants = _activeTab.snifferEngine.detectedMedia
          .where((m) => m.masterUrl == media.url && m.type == MediaType.video)
          .toList();
      if (variants.isNotEmpty) {
        final selected = await _showHlsQualityPicker(context, variants);
        if (selected == null || !mounted) return;
        await _showMediaPreview(selected);
        return;
      }
    }
    await _showMediaPreview(media);
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
      media = _latestVideoMedia ?? _bestDetectedVideoForPlayback();
    }

    if (media == null) {
      if (mounted) {
        _showSnack(
          'No playable stream found yet. Wait a moment or open the capture tray.',
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

  /// Picks the best sniffed video/playlist for auto-replace when the site
  /// only exposes a blob/MSE element.
  SniffedMedia? _bestDetectedVideoForPlayback() {
    final items = _activeTab.snifferEngine.detectedMedia
        .where(
          (m) =>
              m.type == MediaType.video ||
              m.type == MediaType.playlist ||
              m.type == MediaType.audio,
        )
        .toList();
    if (items.isEmpty) return _latestVideoMedia;
    items.sort((a, b) {
      int score(SniffedMedia m) {
        var s = 0;
        final u = m.url.toLowerCase();
        if (u.contains('.m3u8') || u.contains('mpegurl')) s += 100;
        if (m.type == MediaType.video) s += 20;
        if (m.type == MediaType.playlist) s += 40;
        if ((m.contentLengthBytes ?? 0) > 0) {
          s += ((m.contentLengthBytes! / (1024 * 1024)).clamp(0, 50)).toInt();
        }
        if (m.height != null && m.height! >= 720) s += 10;
        return s;
      }

      return score(b).compareTo(score(a));
    });
    return items.first;
  }

  /// Shows a bottom sheet listing HLS variant qualities. Returns the selected
  /// variant, or `null` if the user cancels.
  Future<SniffedMedia?> _showHlsQualityPicker(
    BuildContext context,
    List<SniffedMedia> variants,
  ) async {
    final sorted = List<SniffedMedia>.from(variants)
      ..sort((a, b) => (b.height ?? 0).compareTo(a.height ?? 0));

    return showModalBottomSheet<SniffedMedia>(
      context: context,
      backgroundColor: context.ac.surfacePanel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    'Select quality',
                    style: TextStyle(
                      color: ctx.ac.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                ...sorted.map((variant) {
                  final resolution = variant.width != null && variant.height != null
                      ? '${variant.height}p'
                      : 'Auto';
                  final bandwidth = variant.bandwidth != null
                      ? ' (${_formatBandwidth(variant.bandwidth!)})'
                      : '';
                  return ListTile(
                    leading: Icon(Icons.high_quality_rounded,
                        color: ctx.ac.accentFrost, size: 20),
                    title: Text(
                      '$resolution$bandwidth',
                      style: TextStyle(color: ctx.ac.textPrimary),
                    ),
                    subtitle: variant.name.isNotEmpty
                        ? Text(
                            variant.name,
                            style: TextStyle(
                                color: ctx.ac.textSecondary, fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          )
                        : null,
                    onTap: () => Navigator.pop(ctx, variant),
                  );
                }),
                if (sorted.length != variants.length)
                  ListTile(
                    leading: Icon(Icons.link_rounded,
                        color: ctx.ac.textSecondary, size: 20),
                    title: Text(
                      'Master playlist',
                      style: TextStyle(color: ctx.ac.textSecondary),
                    ),
                    onTap: () => Navigator.pop(ctx, variants.firstWhere(
                      (v) => v.masterUrl == null,
                      orElse: () => variants.first,
                    )),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  static String _formatBandwidth(int bps) {
    if (bps >= 1_000_000) return '${(bps / 1_000_000).toStringAsFixed(1)} Mbps';
    if (bps >= 1_000) return '${(bps / 1_000).toStringAsFixed(0)} Kbps';
    return '$bps bps';
  }

  Future<void> _showMediaPreview(SniffedMedia media) => showMediaPreview(
    context,
    media,
    activeTab: _activeTab,
    isMounted: mounted,
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
        }) => _buildSniffedDownloadHeaders(
          tab: tab,
          media: media,
          cookieHeaders: cookieHeaders,
          currentUrl: currentUrl,
        ),
    refreshM3u8IfNeeded: _refreshM3u8IfNeeded,
    onAddToQueue: (m) async => _showAddQueueDialog(context, m),
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
    final uri = Uri.tryParse(url);
    final path = uri?.path.toLowerCase() ?? '';
    if (uri == null || (!path.endsWith('.m3u8') && !isPlaylistPathHint(path))) {
      return [];
    }

    // 0th attempt: browser-captured playlist body (no Cloudflare, exact body).
    final cached = _activeTab.hlsPlaylistCache[url];
    if (cached != null && cached.isNotEmpty) {
      try {
        final playlist = HlsPlaylistParser.parse(cached, uri);
        if (playlist.isMaster && playlist.variants.isNotEmpty) {
          AuroraLog.instance.debug(
            'Using cached playlist body for $url '
            '(${playlist.variants.length} variants)',
            category: LogCategory.sniffer,
            screen: LogScreen.browser,
            eventType: LogEventType.sniff,
          );
          return playlist.variants.map((v) {
            int? w;
            int? h;
            if (v.resolution != null) {
              final m = RegExp(r'^(\d+)x(\d+)$').firstMatch(v.resolution!);
              if (m != null) {
                w = int.tryParse(m.group(1)!);
                h = int.tryParse(m.group(2)!);
              }
            }
            final resLabel = h != null ? '${h}p ' : '';
            return SniffedMedia(
              url: v.uri.toString(),
              name: '$resLabel${MediaSnifferEngine.bandwidthLabel(v.bandwidth)}'.trim(),
              type: MediaType.video,
              bandwidth: v.bandwidth,
              width: w,
              height: h,
            );
          }).toList();
        }
      } catch (_) {}
    }

    // Build auth headers similar to _buildSniffedDownloadHeaders.
    final headers = <String, String>{
      'User-Agent': _downloadUserAgent(url, _activeTab),
    };
    try {
      final cookies = await _sniffIntakeController.getCookiesForUrl(url);
      headers.addAll(cookies);
    } catch (_) {}
    if (!_hasHeader(headers, 'Referer')) {
      final pageUrl = _activeTab.addressController.text;
      if (pageUrl.isNotEmpty) headers['Referer'] = pageUrl;
    }
    _normalizeHeadersForUrl(
      headers,
      url,
      currentUrl: await _activeTab.controller.currentUrl(),
      addressText: _activeTab.addressController.text,
    );
    headers.addAll(_baseRequestHeaders());

    try {
      var response = await http
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 15));

      // If Dart HTTP client hits Cloudflare WAF (403 / block page), try
      // fetching through the WebView's JavaScript engine (which has the
      // full browser context with Cloudflare clearance cookies), then fall
      // back to Android's native HttpURLConnection.
      if (response.statusCode != 200) {
        AuroraLog.instance.debug(
          '_fetchMasterPlaylistVariants Dart client returned '
          '${response.statusCode}, trying WebView JS fetch…',
          category: LogCategory.sniffer,
          screen: LogScreen.browser,
          eventType: LogEventType.sniff,
        );
        // 1st fallback: WebView JavaScript fetch() — it sends cookies and
        // has Cloudflare clearance from the page session.
        String? jsBody;
        try {
          jsBody = await _activeTab.controller.fetchViaJavaScript(
            url,
            headers: headers,
          );
        } catch (e) {
          AuroraLog.instance.error(
            'JS fetch error: $e',
            category: LogCategory.sniffer,
            screen: LogScreen.browser,
            eventType: LogEventType.error,
          );
        }
        if (jsBody != null && jsBody.isNotEmpty) {
          response = http.Response(
            jsBody,
            200,
            request: http.Request('GET', uri),
          );
          AuroraLog.instance.debug(
            'WebView JS fetch succeeded for variant fetch',
            category: LogCategory.sniffer,
            screen: LogScreen.browser,
            eventType: LogEventType.sniff,
          );
        } else {
          AuroraLog.instance.debug(
            'WebView JS fetch failed, trying native Android HTTP…',
            category: LogCategory.sniffer,
            screen: LogScreen.browser,
            eventType: LogEventType.sniff,
          );
          // 2nd fallback: Android native HttpURLConnection
          try {
            final nativeResult = await NetworkBindingService.fetchUrl(
              url,
              headers: headers,
            );
            if (nativeResult != null) {
              final sc = nativeResult['statusCode'] as int? ?? 0;
              final body = nativeResult['body'] as String? ?? '';
              if (sc >= 200 && sc < 300 && body.isNotEmpty) {
                response = http.Response(
                  body,
                  sc,
                  request: http.Request('GET', uri),
                );
                AuroraLog.instance.debug(
                  'Native fallback succeeded for variant fetch '
                  '(status $sc)',
                  category: LogCategory.sniffer,
                  screen: LogScreen.browser,
                  eventType: LogEventType.sniff,
                );
              }
            }
          } catch (e) {
            AuroraLog.instance.error(
              'Native fallback error: $e',
              category: LogCategory.sniffer,
              screen: LogScreen.browser,
              eventType: LogEventType.error,
            );
          }
        }
      }

      if (response.statusCode != 200) return [];
      final playlist = HlsPlaylistParser.parse(response.body, uri);
      if (!playlist.isMaster || playlist.variants.isEmpty) return [];
      return playlist.variants.map((v) {
        int? w;
        int? h;
        if (v.resolution != null) {
          final m = RegExp(r'^(\d+)x(\d+)$').firstMatch(v.resolution!);
          if (m != null) {
            w = int.tryParse(m.group(1)!);
            h = int.tryParse(m.group(2)!);
          }
        }
        return SniffedMedia(
          url: v.uri.toString(),
          name: MediaSnifferEngine.bandwidthLabel(v.bandwidth),
          type: MediaType.video,
          bandwidth: v.bandwidth,
          width: w,
          height: h,
        );
      }).toList();
    } catch (_) {
      return [];
    }
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
        formatSize: (int bytes, {bool isEstimated = false}) =>
            _formatSize(bytes, isEstimated: isEstimated),
      );

  String _formatSize(int bytes, {bool isEstimated = false}) {
    if (bytes <= 0) return 'Unknown';
    const suffixes = ['B', 'KB', 'MB', 'GB'];
    var i = 0;
    double size = bytes.toDouble();
    while (size >= 1024 && i < suffixes.length - 1) {
      size /= 1024;
      i++;
    }
    final formatted = '${size.toStringAsFixed(1)} ${suffixes[i]}';
    return isEstimated ? '$formatted (est.)' : formatted;
  }

  void _showSniffedMediaSheet() => showSniffedMediaSheet(
    context,
    activeTab: _activeTab,
    mediaCatchController: _mediaCatchController,
    settings: widget.settings,
    onSettingsChanged: widget.onSettingsChanged,
    isMounted: mounted,
    onChanged: () => setState(() {}),
    sortMedia: _sortedMedia,
    onPreview: (media) => _showMediaPreview(media),
    onInfo: (ctx, item) => _showMediaInfoSheet(ctx, item),
    onAddToQueue: (ctx, media, {List<SniffedMedia> variants = const []}) =>
        _showAddQueueDialog(ctx, media, variants: variants),
    onRescan: () => unawaited(_activeTab.controller.rescanPage()),
  );

  /// Header row shown above the segmented filter in the rich catch sheet.
  Widget _buildCatchSheetHeader(
    BuildContext ctx,
    void Function(void Function()) setSheetState,
    int totalShown,
    int selectedCount,
  ) => buildCatchSheetHeader(
    ctx,
    setSheetState,
    totalShown: totalShown,
    selectedCount: selectedCount,
    onSelectBest: () {
      setSheetState(() {
        _mediaCatchController.clearSelection();
        _mediaCatchController.selectedIndices.addAll(
          _recommendedCaptureIndices(
            _mediaCatchController.filteredGroups(
              _mediaCatchController
                  .analyze(_sortedMedia(_activeTab.snifferEngine.detectedMedia))
                  .groups,
            ),
          ),
        );
      });
    },
    onClearCaptured: () {
      setSheetState(() {
        _activeTab.snifferEngine.clearCache();
        _mediaCatchController.clearSelection();
      });
    },
    onRescan: () => unawaited(_activeTab.controller.rescanPage()),
  );

  Widget _compactFilterChip(
    String label,
    MediaFilter value,
    IconData icon,
    MediaFilter current,
    ValueChanged<MediaFilter> onSelected,
  ) => compactFilterChip(context, label, value, icon, current, onSelected);

  _filteredGroups(List<CaptureGroup> groups) =>
      _mediaCatchController.filteredGroups(groups);

  List<SniffedMedia> _selectedGroups(List<CaptureGroup> groups) =>
      _mediaCatchController.selectedGroups(groups);

  Set<int> _recommendedCaptureIndices(List<CaptureGroup> groups) =>
      _mediaCatchController.recommendedCaptureIndices(groups);

  String _captureMetadataLabel(CaptureGroup group) =>
      _mediaCatchController.captureMetadataLabel(group);

  /// Directly enqueue a download from a captured URL without showing
  /// the "Add to Queue" dialog.
  Future<void> _enqueueDirectDownload(
    BrowserTab tab,
    String url,
    String? suggestedFilename,
  ) async {
    final media = tab.snifferEngine.detectedMedia
        .where((m) => m.url == url)
        .lastOrNull;
    final currentUrl = await tab.controller.currentUrl() ?? '';

    // Determine the filename, preferring the extension from the URL path
    // over the server-suggested one (many servers send a generic .bin).
    final urlExt = extensionFromUrlPath(url);
    String suggestedName;
    if (suggestedFilename != null) {
      if (urlExt.isNotEmpty) {
        // Strip any extension from the suggested name and reapply the
        // URL path extension, which is more likely to be correct.
        final base = suggestedFilename.replaceAll(RegExp(r'\.[^.]+$'), '');
        suggestedName = '$base$urlExt';
      } else {
        suggestedName = suggestedFilename;
      }
    } else {
      // No suggested filename — derive one from the URL or sniffed media.
      final parsed = Uri.tryParse(url);
      final nameFromUrl = parsed != null
          ? parsed.path
                .split('/')
                .lastWhere((s) => s.isNotEmpty, orElse: () => '')
          : url.split('/').last;
      suggestedName = _buildSuggestedFilename(
        media?.name ?? (nameFromUrl.isNotEmpty ? nameFromUrl : 'download'),
        mediaUrl: url,
        media: media,
      );
    }
    if (suggestedName.isEmpty) return;

    // Build download headers from the sniffed context.
    final cookieHeaders = await _sniffIntakeController.getCookiesForUrl(url);
    final headerMap = <String, String>{
      'User-Agent': _downloadUserAgent(url, tab),
    };
    _mergeHeaders(headerMap, tab.controller.currentHeaders);
    if (media != null) {
      _mergeHeaders(headerMap, sanitizeSniffedMediaHeaders(media.headers));
    }
    if (!_hasHeader(headerMap, 'Referer')) {
      final ref = _firstNonEmpty([
        media?.sourcePageUrl,
        currentUrl,
        tab.addressController.text,
      ]);
      if (ref != null) headerMap['Referer'] = ref;
    }
    _mergeHeaders(headerMap, cookieHeaders);
    // Re-add Authorization header from the sniff-time cache.
    final cachedAuth = tab.authHeaderCache[url];
    if (cachedAuth != null &&
        cachedAuth.isNotEmpty &&
        !_hasHeader(headerMap, 'Authorization')) {
      headerMap['Authorization'] = cachedAuth;
    }

    _normalizeHeadersForUrl(
      headerMap,
      url,
      currentUrl: currentUrl,
      addressText: tab.addressController.text,
      sourcePageUrl: media?.sourcePageUrl,
    );

    // When the URL has no path extension, probe the server for a real
    // filename and Content-Type (the WebView often sends a generic .bin).
    String? resolvedContentType;
    if (urlExt.isEmpty) {
      final resolved = await resolveFilename(
        url: url,
        headers: headerMap,
        suggestedFilename: suggestedFilename,
      );
      if (resolved.name.isNotEmpty) {
        suggestedName = resolved.name;
      }
      resolvedContentType = resolved.contentType;
    }

    final taskId = DateTime.now().millisecondsSinceEpoch.toString();
    final saveDir = '$_baseDir${Platform.pathSeparator}completed';
    final task = DownloadTask(
      id: taskId,
      url: url,
      sourcePageUrl: media?.sourcePageUrl ?? currentUrl,
      savePath: '$saveDir${Platform.pathSeparator}$suggestedName',
      tempDir: '$_baseTemp${Platform.pathSeparator}temp_$taskId',
      priority: DownloadPriority.medium,
      contentType: resolvedContentType ?? media?.contentType,
      headers: headerMap,
      totalBytes: media?.contentLengthBytes ?? -1,
    );
    // Wire up the WebView JS fetch bridge for HLS / Cloudflare.
    task.fetchViaWebView = (fetchUrl, {Map<String, String>? headers}) =>
        tab.controller.fetchViaJavaScript(fetchUrl, headers: headers);
    task.hlsPlaylistCache = (cacheUrl) => tab.hlsPlaylistCache[cacheUrl];
    task.fetchBinaryViaWebView = (binaryUrl) =>
        tab.controller.fetchBinaryViaJavaScript(binaryUrl);
    task.cookieProvider = (url) => tab.controller.getCookiesForDomain(url: url);
    task.onTokenExpired = ({bool forceReload = false}) => _reloadForFreshUrl(
      tab,
      media?.sourcePageUrl ?? currentUrl,
      forceReload: forceReload,
    );

    // Check for duplicates.
    bool force = false;
    if (_downloadQueue.urlExists(url)) {
      final choice = await _showDuplicatePrompt(context, suggestedName);
      if (choice == DuplicateChoice.skip) return;
      if (choice == DuplicateChoice.updateExisting) {
        final existing = _downloadQueue.getTaskByUrl(url);
        if (existing != null) {
          await _downloadQueue.updateTaskFromDonor(existing.id, task);
          if (mounted) {
            _showSnack('Done — Link updated. Download will retry.');
          }
          return;
        }
      }
      force = true;
    }
    _downloadQueue.addTask(task, force: force);

    if (mounted) {
      _showSnack('Started downloading $suggestedName');
    }
  }

  /// Shows a dialog when the user clicks a download link in [ask] mode.
  void _showDownloadBehaviorPrompt(
    BrowserTab tab,
    String url,
    String? suggestedFilename,
  ) {
    final name = suggestedFilename ?? url.split('/').last;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Start download?'),
        content: Text(name.isNotEmpty ? 'File: $name' : 'URL: $url'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              // Add to queue (ask once).
              unawaited(_enqueueDirectDownload(tab, url, suggestedFilename));
            },
            child: const Text('Download'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              // Block this specific download silently.
            },
            child: const Text('Skip'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddQueueDialog(
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

    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return _AddQueueDialogContent(
          media: media,
          variants: variants,
          tab: tab,
          currentUrl: currentUrl,
          suggestedName: suggestedName,
          baseDir: _baseDir,
          baseTemp: _baseTemp,
          getCookiesForUrl: _sniffIntakeController.getCookiesForUrl,
          downloadQueue: _downloadQueue,
          refreshM3u8IfNeeded: _refreshM3u8IfNeeded,
          fetchMasterPlaylistVariants: _fetchMasterPlaylistVariants,
          onTokenExpired: ({bool forceReload = false}) => _reloadForFreshUrl(
            tab,
            media.sourcePageUrl,
            forceReload: forceReload,
          ),
        );
      },
    );
  }

  String _buildSuggestedFilename(
    String mediaName, {
    String? mediaUrl,
    SniffedMedia? media,
  }) {
    final metaTitle = _activeTab.pageMeta.title.trim();
    final structured = _activeTab.pageMeta.structuredName?.trim() ?? '';
    final tabTitle = _activeTab.title?.trim() ?? '';
    // pickBestTitle prefers the longest usable descriptive title (and
    // titles that look like product codes such as LULU-172).
    final bestTitle = FilenameService.pickBestTitle([
      metaTitle,
      structured,
      tabTitle,
      media?.pageTitle,
    ]);

    // Prefer capture-analyzer quality when available (resolution / bandwidth).
    String? explicitQuality;
    if (media != null) {
      final h = media.height;
      final w = media.width;
      if (h != null || w != null) {
        explicitQuality = FilenameService.qualityLabelFrom(
          height: h,
          width: w,
          bandwidth: media.bandwidth,
        );
        if (explicitQuality != null) explicitQuality = '${explicitQuality}p';
      }
    }

    return FilenameService.buildSuggestedFilename(
      mediaName: mediaName,
      mediaUrl: mediaUrl,
      pageTitle: bestTitle,
      mediaPageTitle: media?.pageTitle,
      structuredName: structured.isNotEmpty ? structured : null,
      sourcePageUrl: media?.sourcePageUrl ??
          _activeTab.addressController.text,
      width: media?.width,
      height: media?.height,
      bandwidth: media?.bandwidth,
      explicitQuality: explicitQuality,
      includeQualitySuffix: widget.settings.includeQualitySuffix,
      defaultMp4ForVideoHosts:
          mediaUrl != null && isVideoHostingUrl(mediaUrl),
      isPlaylist: media?.type == MediaType.playlist,
    );
  }

  List<SniffedMedia> _sortedMedia(List<SniffedMedia> media) {
    final list = [...media];
    switch (widget.settings.sniffedMediaSort) {
      case SniffedMediaSort.newest:
        list.sort((a, b) => b.sniffedAt.compareTo(a.sniffedAt));
        break;
      case SniffedMediaSort.name:
        list.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
        break;
      case SniffedMediaSort.type:
        list.sort((a, b) => a.type.name.compareTo(b.type.name));
        break;
      case SniffedMediaSort.size:
        list.sort(
          (a, b) => (b.contentLengthBytes ?? -1).compareTo(
            a.contentLengthBytes ?? -1,
          ),
        );
        break;
      case SniffedMediaSort.duration:
        list.sort(
          (a, b) => (b.duration?.inMilliseconds ?? -1).compareTo(
            a.duration?.inMilliseconds ?? -1,
          ),
        );
        break;
    }
    return list;
  }

  bool _isCurrentPageFavorited() {
    final url = _activeTab.addressController.text.trim();
    return url.isNotEmpty &&
        _library.favorites.any((favorite) => favorite.url == url);
  }

  String _metadataLabel(SniffedMedia item) {
    final parts = <String>[];
    switch (widget.settings.sniffedMediaDisplayMode) {
      case SniffedMediaDisplayMode.size:
        parts.add(_sizeLabel(
          item.contentLengthBytes,
          isEstimated: item.isSizeEstimated,
        ));
        break;
      case SniffedMediaDisplayMode.duration:
        parts.add(_durationLabel(item.duration));
        break;
      case SniffedMediaDisplayMode.both:
        parts.add(_sizeLabel(
          item.contentLengthBytes,
          isEstimated: item.isSizeEstimated,
        ));
        parts.add(_durationLabel(item.duration));
        break;
    }
    if (item.contentType != null) parts.add(item.contentType!);
    if (item.sourcePageUrl != null && item.sourcePageUrl!.isNotEmpty) {
      parts.add(item.sourcePageUrl!);
    }
    parts.add(item.url);
    return parts.where((part) => part.isNotEmpty).join(' | ');
  }

  String _sizeLabel(int? bytes, {bool isEstimated = false}) {
    if (bytes == null || bytes < 0) return '';
    final suffix = isEstimated ? ' (est.)' : '';
    if (bytes < 1024) return '$bytes B$suffix';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB$suffix';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB$suffix';
  }

  String _durationLabel(Duration? duration) {
    if (duration == null || duration == Duration.zero) return '';
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  int _totalKnownBytes(List<SniffedMedia> media) {
    return media.fold<int>(
      0,
      (total, item) => total + (item.contentLengthBytes ?? 0),
    );
  }

  IconData _mediaIcon(MediaType type) {
    return switch (type) {
      MediaType.video => Icons.movie,
      MediaType.audio => Icons.audiotrack,
      MediaType.image => Icons.image,
      MediaType.document => Icons.description,
      MediaType.archive => Icons.archive,
      MediaType.torrent => Icons.hub,
      MediaType.subtitle => Icons.subtitles,
      MediaType.executable => Icons.insert_drive_file,
      MediaType.playlist => Icons.queue_music,
    };
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

  /// Returns true when [title] is a known Android WebView error page title
  /// or a generic interstitial placeholder. Such titles should not be used
  /// as download filenames — fall back to the URL-derived name instead.
  static bool _isErrorPageTitle(String title) {
    return FilenameService.isUnusableTitle(title);
  }

  String _cleanTitle(String? title, String? url) {
    final trimmed = title?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    return _titleForUrl(url ?? '');
  }

  String _titleForUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri != null && uri.host.isNotEmpty) return uri.host;
    return url.isEmpty ? 'Page' : url;
  }

  String _normalizeJsString(Object? value) {
    if (value == null) return '<html><body></body></html>';
    final raw = value.toString();
    if (raw.startsWith('"') && raw.endsWith('"')) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is String) return decoded;
      } catch (_) {}
    }
    return raw;
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

  Future<void> _translatePage() => translatePage(
    context,
    activeTab: _activeTab,
    currentSettings: widget.settings,
    onSettingsChanged: widget.onSettingsChanged ?? (_) {},
    onLoadUrl: (uri) => _loadUrlWithHostSettings(_activeTab, uri),
    onShowSnack: _showSnack,
    isMounted: mounted,
  );

  Future<void> _showOriginalPage() async {
    final tab = _activeTab;
    final url = await tab.controller.currentUrl();
    if (url == null || url.isEmpty) return;
    final original = _extractOriginalFromTranslateUrl(url);
    if (original == null) {
      _showSnack('Could not find the original page URL.');
      return;
    }
    unawaited(_loadUrlWithHostSettings(tab, original));
  }

  Uri? _extractOriginalFromTranslateUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    if (!uri.host.contains('translate.google.com')) return null;
    final inner = uri.queryParameters['u'];
    if (inner == null || inner.isEmpty) return null;
    return Uri.tryParse(inner);
  }

  Future<void> _saveAsPdf() async {
    final tab = _activeTab;
    final url = await tab.controller.currentUrl();
    if (url == null || url.isEmpty) return;
    try {
      await tab.controller.evaluateJavaScript('window.print()');
    } catch (_) {
      _showSnack('This page does not support print to PDF.');
    }
  }

  Future<void> _forwardToUcBrowser() async {
    final url = await _activeTab.controller.currentUrl();
    if (url == null || url.isEmpty) return;
    try {
      await PublicDownloadsService.openUrl(url);
    } catch (_) {
      _showSnack('Could not open this page in UC Browser.');
    }
  }

  Future<void> _clearBrowserCookies() async {
    try {
      await _activeTab.controller.clearCookies();
      _showSnack('Browser cache and cookies cleared.');
    } catch (error) {
      _showSnack('Could not clear cookies: $error');
    }
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

/// Cancel picker floating chip with a 30-second countdown ring.
class _PickerCancelChip extends StatefulWidget {
  final VoidCallback onCancel;

  const _PickerCancelChip({super.key, required this.onCancel});

  @override
  State<_PickerCancelChip> createState() => _PickerCancelChipState();
}

class _PickerCancelChipState extends State<_PickerCancelChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 30),
    )..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return SizedBox(
          width: 100,
          height: 56,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Padding(
                padding: const EdgeInsets.all(3),
                child: CircularProgressIndicator(
                  value: 1.0 - _controller.value,
                  strokeWidth: 3.0,
                  color: context.ac.accentFrost,
                  backgroundColor: context.ac.surfaceElevated,
                ),
              ),
              Material(
                color: context.ac.overlaySurface,
                elevation: 8,
                borderRadius: BorderRadius.circular(20),
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: widget.onCancel,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.close, size: 18, color: context.ac.textPrimary),
                        const SizedBox(width: 6),
                        Text(
                          'Cancel',
                          style: TextStyle(color: context.ac.textPrimary),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

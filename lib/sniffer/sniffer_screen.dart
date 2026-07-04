import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../downloader/downloader.dart';
import '../downloader/url_filename_resolver.dart';
import '../logging/aurora_log.dart';
import '../platform/network_binding_service.dart';
import '../platform/public_downloads_service.dart';
import '../settings/download_settings.dart';
import 'ad_block_engine_native.dart';
import 'browser_controller.dart';
import 'browser_library.dart';
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
import '../theme/aurora_colors.dart';

import 'actions/autofill_action.dart';
import 'actions/context_menu_action.dart';
import 'actions/translate_action.dart';
import 'sheets/favorites_sheet.dart';
import 'sheets/history_sheet.dart';
import 'sheets/library_sheet.dart';
import 'sheets/media_info_sheet.dart';
import 'sheets/media_preview_sheet.dart';
import 'sheets/saved_pages_sheet.dart';
import 'sheets/sniffed_media_sheet.dart';
import 'sheets/tabs_sheet.dart';

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
  bool get _isLoading => _tabManager.isLoading;
  set _isLoading(bool v) => _tabManager.isLoading = v;
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
  bool get _hideShortClips => _mediaCatchController.hideShortClips;
  set _hideShortClips(bool v) => _mediaCatchController.hideShortClips = v;
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

  String? _selectedText;
  bool _selectionToolbarVisible = false;

  final AutofillStore _autofillStore = const AutofillStore();
  List<AutofillProfile> _autofillProfiles = const [];

  late final SafeBrowsingService _safeBrowsing;

  double _lastScrollY = 0.0;
  bool _barsVisible = true;
  bool _isContextMenuShowing = false;

  /// Set of tab IDs whose WebViews have already been built (lazy creation).
  /// Only tabs in this set get a real [BrowserWidget] — others render an empty
  /// placeholder to avoid creating expensive native WebViews at launch.
  /// Set of tab IDs whose WebViews have already been built (lazy creation).
  /// Only tabs in this set get a real [BrowserWidget] — others render an empty
  /// placeholder to avoid creating expensive native WebViews at launch.
  final Set<String> _builtWebViewTabIds = {};

  /// Whether `_loadTabsAndMedia` has finished restoring tabs.
  /// When `false`, the lazy Stack shows an empty placeholder for real WebViews
  /// so that the default blank tab (created in `initState`) does not trigger an
  /// expensive native WebView that would be immediately disposed.  Mock
  /// (test) controllers always build immediately regardless of this flag.
  bool _tabsLoaded = false;

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
    _tabManager = TabManager()
      ..onRebuild = () {
        if (mounted) setState(() {});
      };
    _addressBarController = AddressBarController();
    _mediaCatchController = MediaCatchController();
    _elementPickerController = ElementPickerController(
      activeTabGetter: () => _activeTab,
      onSettingsChanged: widget.onSettingsChanged,
      showSnack: _showSnack,
    );
    _libraryController = LibraryController(
      libraryStore: widget.libraryStore,
    )..onLibraryChanged = () {
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
    widget.controller?.setOnOpenUrlRequest((url) {
      _tabLifecycleController.openNewTab(url: url);
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
    _initPaths();
    unawaited(_libraryController.load());
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
    setState(() {});
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
  }) =>
      _loadUrlWithHostSettings(tab, uri, addToHistory: addToHistory);

  @override
  Future<void> applyCosmeticRules([BrowserTab? tab]) =>
      _applyCosmeticRules(tab!);

  @override
  Future<void> configureTabAdblock(BrowserTab tab) => _configureTabAdblock(tab);

  @override
  Future<void> refreshPageInfo(
    BrowserTab tab, {
    bool recordHistory = false,
  }) =>
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
  SniffIntakeController get sniffIntakeController => _sniffIntakeController;

  @override
  void markTabsLoaded() {
    if (!_tabsLoaded) {
      _tabsLoaded = true;
    }
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
    widget.libraryUpdateNotifier?.removeListener(_onLibraryUpdate);
    _tabManager.mediaRebuildTimer?.cancel();
    _tabManager.mediaSaveTimer?.cancel();
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
    _tabManager.dispose();
    super.dispose();
  }

  Future<void> _initPaths() async {
    try {
      final baseDir = (await getApplicationSupportDirectory()).path;
      final baseTemp = (await getTemporaryDirectory()).path;
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
                    const Row(
                      children: [
                        Icon(
                          Icons.file_upload_outlined,
                          color: AuroraColors.accent,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Export Library',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: AuroraColors.text,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    SwitchListTile(
                      activeColor: AuroraColors.accent,
                      title: const Text(
                        'Favorites',
                        style: TextStyle(color: AuroraColors.text),
                      ),
                      subtitle: Text(
                        '${_library.favorites.length} favorites, ${_library.folders.length} folders',
                        style: const TextStyle(color: AuroraColors.mutedText),
                      ),
                      value: exportFavorites,
                      onChanged: (val) =>
                          setModalState(() => exportFavorites = val),
                    ),
                    SwitchListTile(
                      activeColor: AuroraColors.accent,
                      title: const Text(
                        'Web History',
                        style: TextStyle(color: AuroraColors.text),
                      ),
                      subtitle: Text(
                        '${_library.history.length} history entries',
                        style: const TextStyle(color: AuroraColors.mutedText),
                      ),
                      value: exportHistory,
                      onChanged: (val) =>
                          setModalState(() => exportHistory = val),
                    ),
                    SwitchListTile(
                      activeColor: AuroraColors.accent,
                      title: const Text(
                        'Saved Pages',
                        style: TextStyle(color: AuroraColors.text),
                      ),
                      subtitle: Text(
                        '${_library.savedPages.length} offline pages',
                        style: const TextStyle(color: AuroraColors.mutedText),
                      ),
                      value: exportSavedPages,
                      onChanged: (val) =>
                          setModalState(() => exportSavedPages = val),
                    ),
                    SwitchListTile(
                      activeColor: AuroraColors.accent,
                      title: const Text(
                        'Download History',
                        style: TextStyle(color: AuroraColors.text),
                      ),
                      subtitle: Text(
                        '${_downloadQueue.allTasks.length} tasks',
                        style: const TextStyle(color: AuroraColors.mutedText),
                      ),
                      value: exportQueue,
                      onChanged: (val) =>
                          setModalState(() => exportQueue = val),
                    ),
                    SwitchListTile(
                      activeColor: AuroraColors.accent,
                      title: const Text(
                        'App Settings',
                        style: TextStyle(color: AuroraColors.text),
                      ),
                      subtitle: const Text(
                        'Toggles, concurrent limits, search engine defaults',
                        style: TextStyle(color: AuroraColors.mutedText),
                      ),
                      value: exportSettings,
                      onChanged: (val) =>
                          setModalState(() => exportSettings = val),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text(
                            'Cancel',
                            style: TextStyle(color: AuroraColors.mutedText),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          key: const Key('confirm_export_button'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AuroraColors.accent,
                            foregroundColor: AuroraColors.background,
                          ),
                          onPressed:
                              (!exportFavorites &&
                                  !exportHistory &&
                                  !exportSavedPages &&
                                  !exportQueue &&
                                  !exportSettings)
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
  }) async {
    try {
      final List<Map<String, dynamic>>? downloadQueueJson = exportQueue
          ? _downloadQueue.allTasks.map((t) => t.toJson()).toList()
          : null;
      final Map<String, dynamic>? settingsJson = exportSettings
          ? widget.settings.toJson()
          : null;

      final file = await widget.libraryStore.exportToFile(
        exportFavorites: exportFavorites,
        exportHistory: exportHistory,
        exportSavedPages: exportSavedPages,
        downloadQueueJson: downloadQueueJson,
        settingsJson: settingsJson,
      );
      await PublicDownloadsService.shareFile(file.path);
    } catch (error) {
      _showSnack('Export failed: $error');
    }
  }

  Future<void> _importLibrary() async {
    try {
      final filePath = await PublicDownloadsService.pickImportFile();
      if (filePath == null) return;

      final Map<String, dynamic> decoded;
      if (filePath.toLowerCase().endsWith('.1dmbak')) {
        decoded = await IdmBackupParser.parse(filePath);
      } else {
        decoded = await widget.libraryStore.readImportMap(filePath);
      }

      final hasFavorites = decoded.containsKey('favorites') && (decoded['favorites'] is List) && (decoded['favorites'] as List).isNotEmpty;
      final hasHistory = decoded.containsKey('history') && (decoded['history'] is List) && (decoded['history'] as List).isNotEmpty;
      final hasSavedPages = decoded.containsKey('savedPages') && (decoded['savedPages'] is List) && (decoded['savedPages'] as List).isNotEmpty;
      final hasQueue = decoded.containsKey('downloadQueue') && (decoded['downloadQueue'] is List) && (decoded['downloadQueue'] as List).isNotEmpty;
      final hasSettings = decoded.containsKey('settings');

      final isLegacy = decoded.containsKey('favorites') ||
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
                      const Row(
                        children: [
                          Icon(
                            Icons.file_download_outlined,
                            color: AuroraColors.accent,
                          ),
                          SizedBox(width: 8),
                          Text(
                            'Import Library',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: AuroraColors.text,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      SwitchListTile(
                        activeColor: AuroraColors.accent,
                        title: const Text('Favorites / Bookmarks', style: TextStyle(color: AuroraColors.text)),
                        value: importFavorites,
                        onChanged: (hasFavorites || isLegacy)
                            ? (val) => setModalState(() => importFavorites = val)
                            : null,
                      ),
                      SwitchListTile(
                        activeColor: AuroraColors.accent,
                        title: const Text('Web History', style: TextStyle(color: AuroraColors.text)),
                        value: importHistory,
                        onChanged: (hasHistory || isLegacy)
                            ? (val) => setModalState(() => importHistory = val)
                            : null,
                      ),
                      SwitchListTile(
                        activeColor: AuroraColors.accent,
                        title: const Text('Saved Pages', style: TextStyle(color: AuroraColors.text)),
                        value: importSavedPages,
                        onChanged: (hasSavedPages || isLegacy)
                            ? (val) => setModalState(() => importSavedPages = val)
                            : null,
                      ),
                      SwitchListTile(
                        activeColor: AuroraColors.accent,
                        title: const Text('Download History (Queue)', style: TextStyle(color: AuroraColors.text)),
                        value: importQueue,
                        onChanged: hasQueue
                            ? (val) => setModalState(() => importQueue = val)
                            : null,
                      ),
                      SwitchListTile(
                        activeColor: AuroraColors.accent,
                        title: const Text('App Settings', style: TextStyle(color: AuroraColors.text)),
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
                            child: const Text('Cancel', style: TextStyle(color: AuroraColors.mutedText)),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AuroraColors.accent,
                              foregroundColor: AuroraColors.background,
                            ),
                            onPressed: (!importFavorites &&
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
    } catch (error) {
      _showSnack('Import failed: $error');
    }
  }

  Future<void> _refreshPageInfo(
    BrowserTab tab, {
    required bool recordHistory,
  }) async {
    final title = await tab.controller.pageTitle();
    final url = await tab.controller.currentUrl();
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

    if (y > _lastScrollY && y > 80) {
      if (_barsVisible) {
        setState(() {
          _barsVisible = false;
        });
      }
    } else if (y < _lastScrollY || y <= 15) {
      if (!_barsVisible) {
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
  );

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
    ].take(100).toList(growable: false);
    await _saveLibrary(_library.copyWith(history: history));
  }

  void _setupTabCallbacks(BrowserTab tab) {
    tab.controller.setOnUrlChanged((url) {
      if (!mounted) return;
      tab.addressController.text = url;
      tab.currentUrl = url;
      _sniffIntakeController.sniffBrowserUrl(tab, url, sourcePageUrl: url);
      _updateTabNavState(tab);
      if (mounted) setState(() {});
    });
    tab.controller.setOnPageStarted((url) {
      if (!mounted) return;
      setState(() => _isLoading = true);
      _lastScrollY = 0.0;
      if (!_barsVisible) {
        setState(() => _barsVisible = true);
      }
      _fetchedIframeSrcs.clear();
      AuroraLog.instance.info(
        'Page started: $url',
        category: LogCategory.browser,
        screen: LogScreen.browser,
        eventType: LogEventType.navigation,
      );
      tab.authHeaderCache.clear();
      _sniffIntakeController.clearCookieCache();
      tab.snifferEngine.clearCache();
      _sniffIntakeController.sniffBrowserUrl(tab, url, sourcePageUrl: url);
    });
    tab.controller.setOnPageFinished((url) {
      if (!mounted) return;
      setState(() => _isLoading = false);
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
    });
    tab.controller.setOnScrollPositionChange((x, y) {
      if (tab == _activeTab) {
        _onScroll(x, y);
      }
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
      'MediaMetaChannel',
      onMessageReceived: (message) {
        try {
          final data = jsonDecode(message) as Map;
          final src = data['src'] as String?;
          if (src != null && src.isNotEmpty) {
            _sniffIntakeController.sniffBrowserUrl(
              tab,
              src,
              sourcePageUrl: tab.addressController.text,
            );
          }
        } catch (_) {}
      },
    );
    tab.controller.addJavaScriptChannel(
      'MediaSnifferDataChannel',
      onMessageReceived: (message) {
        try {
          final data = jsonDecode(message) as Map;
          final url = data['url'] as String?;
          final ct = data['contentType'] as String?;
          final clStr = data['contentLength'] as String?;
          final cl = (clStr != null && clStr.isNotEmpty)
              ? int.tryParse(clStr)
              : null;
          if (url != null && url.isNotEmpty) {
            _sniffIntakeController.sniffBrowserUrl(
              tab,
              url,
              sourcePageUrl: tab.addressController.text,
              contentType: ct,
              contentLength: cl,
            );
          }
        } catch (_) {}
      },
    );
    tab.controller.addJavaScriptChannel(
      'PageMetaChannel',
      onMessageReceived: (message) {
        try {
          final data = Map<String, dynamic>.from(jsonDecode(message));
          final ogTitle = data['ogTitle'] as String?;
          final ldName = data['ldName'] as String?;
          tab.pageMeta = PageMeta(
            title: (ogTitle != null && ogTitle.trim().isNotEmpty)
                ? ogTitle.trim()
                : (data['title'] as String? ?? ''),
            videoWidth: int.tryParse((data['ogVideoWidth'] as String?) ?? ''),
            videoHeight: int.tryParse((data['ogVideoHeight'] as String?) ?? ''),
            structuredName: ldName,
          );
          if (mounted) setState(() {});
        } catch (_) {}
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
      'TextSelectionChannel',
      onMessageReceived: (message) {
        final text = message.trim();
        if (text.isNotEmpty) {
          _onWebPageTextSelected(text);
        }
      },
    );
    tab.controller.addJavaScriptChannel(
      'HlsPlaylistChannel',
      onMessageReceived: (message) {
        try {
          final data = jsonDecode(message) as Map;
          final url = data['url'] as String?;
          final body = data['body'] as String?;
          if (url != null &&
              body != null &&
              url.isNotEmpty &&
              body.isNotEmpty) {
            tab.hlsPlaylistCache[url] = body;
            AuroraLog.instance.debug(
    'HlsPlaylistChannel cached body for $url (${body.length} chars, cache size=${tab.hlsPlaylistCache.length})',
            category: LogCategory.sniffer, screen: LogScreen.browser, eventType: LogEventType.sniff);
          }
        } catch (e) {
          AuroraLog.instance.error('HlsPlaylistChannel error: $e', category: LogCategory.sniffer, screen: LogScreen.browser, eventType: LogEventType.error);
        }
      },
      );
      tab.controller.addJavaScriptChannel(
      'NavigationSwipeChannel',
      onMessageReceived: (message) {
        // JS-based edge swipe detector fired. Debounce to prevent
        // double-navigation when the Flutter-side GestureDetector
        // in the edge overlay also fires and wins the race.
        final now = DateTime.now();
        if (message == 'back') {
          if (tab.lastSwipeBack != null &&
              now.difference(tab.lastSwipeBack!).inMilliseconds < 500) {
            return;
          }
          tab.lastSwipeBack = now;
          unawaited(tab.controller.goBack());
        } else if (message == 'forward') {
          if (tab.lastSwipeForward != null &&
              now.difference(tab.lastSwipeForward!).inMilliseconds < 500) {
            return;
          }
          tab.lastSwipeForward = now;
          unawaited(tab.controller.goForward());
        }
      },
    );
    tab.controller.setOnIframeMediaDetected((url) {
      _sniffIntakeController.sniffBrowserUrl(
        tab,
        url,
        sourcePageUrl: tab.addressController.text,
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
                ? 'Download captured: $suggestedFilename — tap the capture badge to add to queue.'
                : 'Download URL captured — tap the capture badge to add to queue.',
          );
        case DownloadLinkBehavior.autoDownload:
          // Add directly to the download queue without prompting.
          await _enqueueDirectDownload(
            tab,
            url,
            suggestedFilename,
          );
        case DownloadLinkBehavior.ask:
          // Show a dialog asking what to do.
          _showDownloadBehaviorPrompt(
            tab,
            url,
            suggestedFilename,
          );
        case DownloadLinkBehavior.block:
          // Silently ignore — no snack, no queue entry.
          break;
      }

      _sniffIntakeController.scheduleMediaRebuild();
      _sniffIntakeController.scheduleMediaSave(tab);
    });
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
      final cookieHeaders = await _sniffIntakeController.getCookiesForUrl(iframeSrcUrl);
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
      category: LogCategory.sniffer, screen: LogScreen.browser, eventType: LogEventType.error);
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
      AuroraLog.instance.error('Safe browsing check failed: $e', category: LogCategory.sniffer, screen: LogScreen.browser, eventType: LogEventType.error);
      safety = const SafeBrowsingResult(verdict: SafeBrowsingVerdict.safe);
    }
    if (safety.verdict == SafeBrowsingVerdict.malicious) {
      final proceed = await _showPhishingWarning(uri, safety);
      if (proceed != true) return;
    } else if (safety.verdict == SafeBrowsingVerdict.suspicious) {
      _showSnack('Heads up: ${safety.reason ?? "suspicious URL"}');
    }
    final ua = _effectiveUserAgentFor(host);
    if (ua != null) {
      await tab.controller.setUserAgent(ua);
    }
    final headers = <String, String>{
      ..._baseRequestHeaders(),
      if (extraHeaders != null) ...extraHeaders,
    };
    if (headers.isEmpty) {
      await tab.controller.loadRequest(uri, addToHistory: addToHistory);
    } else {
      await tab.controller.loadRequest(
        uri,
        headers: headers,
        addToHistory: addToHistory,
      );
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
              result.reason ?? 'This URL appears on a phishing blocklist.',
              style: const TextStyle(fontSize: 12),
            ),
            if (result.source != null)
              Text(
                'Source: ${result.source}',
                style: const TextStyle(
                  fontSize: 11,
                  color: AuroraColors.mutedText,
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
    html.aurora-dark img,
    html.aurora-dark picture,
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
    if (url != null &&
        url.isNotEmpty &&
        (tab.controller.shouldBlockUrl(url) ||
            AdBlockEngine.looksLikeAdMediaUrl(url) ||
            !event.userInitiated)) {
      tab.snifferEngine.suppress(url, 'popup ad');
    }
    tab.controller.incrementBlockedPopups();
    setState(() {});
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          url == null || url.isEmpty ? 'Popup blocked.' : 'Popup blocked.',
        ),
        action: url == null || url.isEmpty
            ? null
            : SnackBarAction(
                label: 'Open once',
                onPressed: () {
                  final uri = Uri.tryParse(url);
                  if (uri != null && uri.hasScheme) {
                    unawaited(_loadUrlWithHostSettings(tab, uri));
                  }
                },
              ),
      ),
    );
  }

  Future<void> _startElementPicker() async {
    await _elementPickerController.startPicker();
    _showPickerSnack(
      'Tap an ad or page element to block. Press Back to cancel.',
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
          content: const Text('Blocked. Undo?'),
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
  }) =>
      _elementPickerController.applyCosmeticRules(
        tab,
        settings: settings ?? widget.settings,
      );

  Future<void> _resetPageElementBlocks() =>
      _elementPickerController.resetPageElementBlocks(widget.settings);

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
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: AuroraColors.surfaceVariant,
                  width: 0.5,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(icon, size: 16, color: AuroraColors.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    suggestion.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AuroraColors.text,
                    ),
                  ),
                ),
                Text(
                  suggestion.url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AuroraColors.mutedDeep,
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
    final activeColor = _privateMode
        ? AuroraColors.accentPurple
        : AuroraColors.accent;
    return Container(
      key: const Key('browser_tab_strip'),
      height: 34,
      color: AuroraColors.dockSurface,
      child: Row(
        children: [
          if (_privateMode)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Center(
                child: Icon(
                  Icons.visibility_off_outlined,
                  size: 12,
                  color: AuroraColors.accentPurple,
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
                        horizontal: 2, vertical: 4),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: isActive
                          ? activeColor.withValues(alpha: 0.15)
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
                                  : AuroraColors.mutedText,
                            ),
                          ),
                        ),
                        if (_tabs.length > 1)
                          GestureDetector(
                            key: Key('browser_tab_close_$i'),
                            onTap: () => _tabLifecycleController.closeTab(i),
                            child: const Padding(
                              padding: EdgeInsets.only(left: 4),
                              child: Icon(
                                Icons.close,
                                size: 12,
                                color: AuroraColors.mutedTextAlt,
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
            icon: const Icon(
              Icons.add,
              size: 16,
              color: AuroraColors.mutedText,
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
        color: AuroraColors.overlay,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_findVisible) _buildFindBar(),
          ],
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
        color: AuroraColors.dockSurface,
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: AuroraColors.glassSurface,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: AuroraColors.glassBorder),
                    ),
                    child: Row(
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
                                  ? AuroraColors.accentAmber
                                  : AuroraColors.mutedText,
                              size: 18,
                            ),
                            onPressed: _toggleFavorite,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minWidth: 32, minHeight: 32),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Icon(Icons.lock, size: 12,
                            color: AuroraColors.mutedText),
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
                                    hintText: 'Search or enter URL',
                                    border: InputBorder.none,
                                    contentPadding: EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 8),
                                  ),
                                  keyboardType: TextInputType.url,
                                  textInputAction: TextInputAction.go,
                                  onSubmitted: _loadAddress,
                                )
                              : GestureDetector(
                                  key: const Key('browser_address_chip'),
                                  onTap: () {
                                    setState(() => _addressExpanded = true);
                                    // Select all text and focus the field after
                                    // the TextField has been built in the current
                                    // frame so the user can immediately overwrite
                                    // the URL.
                                    WidgetsBinding.instance
                                        .addPostFrameCallback((_) {
                                      if (!mounted) return;
                                      tab.addressController.selection =
                                          TextSelection(
                                        baseOffset: 0,
                                        extentOffset:
                                            tab.addressController.text.length,
                                      );
                                      _addressFocusNode.requestFocus();
                                    });
                                  },
                                  child: Container(
                                    height: 36,
                                    alignment: Alignment.centerLeft,
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8),
                                    child: Text(
                                      _addressLabel().isEmpty
                                          ? 'Search or enter URL'
                                          : _addressLabel(),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: AuroraColors.text,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                ),
                        ),
                        if (_addressExpanded)
                          IconButton(
                            key: const Key('sniffer_go_button'),
                            icon: const Icon(Icons.arrow_forward, size: 18),
                            onPressed: () => _loadAddress(),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minWidth: 36, minHeight: 36),
                          ),
                        IconButton(
                          icon: const Icon(Icons.refresh, size: 18),
                          onPressed: () => tab.controller.reload(),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 36, minHeight: 36),
                        ),
                      ],
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
                  color: AuroraColors.overlay,
                  borderRadius: BorderRadius.circular(16),
                  child: _buildSuggestionPanel(),
                ),
              ),
          ],
        ),
      ),
    );

    final webView = AnimatedPositioned(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      top: _barsVisible ? topHeight : 0,
      bottom: _barsVisible ? bottomHeight : 0,
      left: 0,
      right: 0,
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
              return Positioned.fill(
                child: Offstage(
                  offstage: !isActive,
                  child: shouldBuild
                      ? BrowserWidget(
                          key: ValueKey(t.id),
                          controller: t.controller,
                          onSwipeBack: () => t.controller.goBack(),
                          onSwipeForward: () => t.controller.goForward(),
                          onRefresh: () => t.controller.reload(),
                        )
                      : const SizedBox.shrink(),
                ),
              );
            }).toList(),
          ),
          if (_isLoading)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(
                minHeight: 2,
                backgroundColor: Colors.grey[300],
              ),
            ),
        ],
      ),
    );

    final selectionToolbar = AnimatedPositioned(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeInOut,
      bottom: _selectionToolbarVisible ? 56.0 : -120.0,
      left: 16,
      right: 16,
      child: _buildSelectionToolbar(),
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
              selectionToolbar,
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

  /// Unified bottom strip — browser nav (back/forward/home/tabs) +
  /// app nav (Queue/capture FAB/Settings) in one row.
  Widget _buildConsolidatedStrip(BrowserTab tab, double height) {
    final badgeCount = tab.snifferEngine.detectedMedia.length;
    final homeUrl = widget.settings.searchEngine.id == 'custom'
        ? widget.settings.searchEngine.templateUrl.replaceAll('%s', '')
        : 'https://www.google.com';

    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 2, 4, 4),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AuroraColors.overlaySurface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AuroraColors.border),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                const SizedBox(width: 2),
                // Browser navigation
                _CompactNavButton(
                  key: const Key('sniffer_back_button'),
                  icon: Icons.arrow_back_ios_new,
                  enabled: tab.canGoBack,
                  onTap: tab.canGoBack ? () => tab.controller.goBack() : null,
                ),
                _CompactNavButton(
                  key: const Key('sniffer_forward_button'),
                  icon: Icons.arrow_forward_ios,
                  enabled: tab.canGoForward,
                  onTap: tab.canGoForward
                      ? () => tab.controller.goForward()
                      : null,
                ),
                _CompactNavButton(
                  key: const Key('browser_home_button'),
                  icon: Icons.home_outlined,
                  enabled: true,
                  onTap: () => unawaited(
                      _loadUrlWithHostSettings(tab, Uri.parse(homeUrl))),
                ),
                _CompactNavButton(
                  key: const Key('browser_tabs_button'),
                  icon: Icons.tab,
                  enabled: true,
                  onTap: _showTabsSheet,
                ),
                _buildAdblockShieldButton(tab),
                const SizedBox(width: 8),
                // App nav
                _miniDockTab(
                  key: const Key('mini_dock_queue'),
                  icon: Icons.download_rounded,
                  label: 'Queue',
                  compact: true,
                  onTap: () => widget.onOpenQueue?.call(),
                ),
                const SizedBox(width: 6),
                // Capture FAB (morphing)
                Material(
                  key: const Key('sniffer_fab'),
                  elevation: 4,
                  shape: const CircleBorder(),
                  color: badgeCount > 0
                      ? AuroraColors.accentAmber
                      : AuroraColors.accent,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: _showSniffedMediaSheet,
                    child: Container(
                      width: 40,
                      height: 40,
                      alignment: Alignment.center,
                      child: Icon(
                        badgeCount > 0 ? Icons.radar : Icons.add,
                        size: 22,
                        color: AuroraColors.background,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                _miniDockTab(
                  key: const Key('mini_dock_settings'),
                  icon: Icons.tune_rounded,
                  label: 'Settings',
                  compact: true,
                  onTap: () => widget.onOpenSettings?.call(),
                ),
                const SizedBox(width: 6),
                _miniDockTab(
                  key: const Key('mini_dock_menu'),
                  icon: Icons.menu_rounded,
                  label: 'Menu',
                  compact: true,
                  onTap: _showBrowserMenuSheet,
                ),
                const SizedBox(width: 2),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _miniDockTab({
    Key? key,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool compact = false,
  }) {
    return Material(
      key: key,
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: compact
              ? const EdgeInsets.all(8)
              : const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: AuroraColors.glassSurface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AuroraColors.glassBorder),
          ),
          child: compact
              ? Icon(icon, size: 20, color: AuroraColors.mutedText)
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 18, color: AuroraColors.mutedText),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: TextStyle(
                          fontSize: 12,
                          color: AuroraColors.mutedText),
                    ),
                  ],
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
    final isAllowlisted = host.isNotEmpty && settings.adblockAllowlist.contains(host);
    final blocked = tab.controller.blockedRequestCount;
    final IconData icon;
    final Color color;
    if (!settings.adblockEnabled) {
      icon = Icons.shield;
      color = Colors.redAccent;
    } else if (isAllowlisted) {
      icon = Icons.shield_outlined;
      color = AuroraColors.mutedText;
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
            color: AuroraColors.glassSurface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AuroraColors.glassBorder),
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
                        minWidth: 14, minHeight: 14),
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No site loaded')),
      );
      return;
    }
    final isAllowlisted = settings.adblockAllowlist.contains(host);
    final blocked = tab.controller.blockedRequestCount;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          const Icon(Icons.shield, color: Colors.green),
          const SizedBox(width: 8),
          const Text('Adblock'),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(host,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(settings.adblockEnabled
                ? (isAllowlisted
                    ? 'Status: disabled for this site'
                    : 'Status: active')
                : 'Status: globally disabled'),
            const SizedBox(height: 4),
            Text('Blocked: $blocked requests on this page'),
            const Divider(),
            SwitchListTile(
              title: Text(isAllowlisted
                  ? 'Block ads on $host'
                  : 'Allow ads on $host'),
              subtitle: Text(isAllowlisted
                  ? 'Re-enable adblock for this site'
                  : 'Temporarily disable adblock for this site'),
              value: !isAllowlisted,
              contentPadding: EdgeInsets.zero,
              onChanged: (v) {
                final List<String> updated = v
                    ? settings.adblockAllowlist
                        .where((h) => h != host)
                        .toList()
                    : [...settings.adblockAllowlist, host];
                final newSettings =
                    settings.copyWith(adblockAllowlist: updated);
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

  Widget _buildSelectionToolbar() {
    final text = _selectedText;
    if (text == null) return const SizedBox.shrink();
    return Material(
      color: AuroraColors.overlaySurface,
      elevation: 8,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            const Icon(Icons.text_fields, size: 18, color: AuroraColors.accent),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: AuroraColors.text),
              ),
            ),
            IconButton(
              tooltip: 'Translate',
              icon: const Icon(Icons.translate, size: 18),
              onPressed: _selectionActionTranslate,
            ),
            IconButton(
              tooltip: 'Search',
              icon: const Icon(Icons.search, size: 18),
              onPressed: _selectionActionSearch,
            ),
            IconButton(
              tooltip: 'Copy',
              icon: const Icon(Icons.copy, size: 18),
              onPressed: _selectionActionCopy,
            ),
            IconButton(
              tooltip: 'Share',
              icon: const Icon(Icons.ios_share, size: 18),
              onPressed: _selectionActionShare,
            ),
            IconButton(
              tooltip: 'Close',
              icon: const Icon(Icons.close, size: 18),
              onPressed: _closeSelectionToolbar,
            ),
          ],
        ),
      ),
    );
  }

  // ARCHIVED: The bottom download queue strip was here (removed 2026-06-27).

  String _addressLabel() =>
      _addressBarController.addressLabel(_activeTab);

  Widget _buildFindBar() {
    return SizedBox(
      height: 54.0,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AuroraColors.overlaySurface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AuroraColors.border),
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
      final insertAtIndex =
          !switchToTab ? _activeTabIndex + 1 : null;
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
        urlExists: (url) => _downloadQueue.urlExists(url),
        addTask: (task, {bool force = false}) =>
            _downloadQueue.addTask(task, force: force),
        showDuplicatePrompt: _showDuplicatePrompt,
        showSnack: _showSnack,
        reloadForFreshUrl: (
          tab,
          sourcePageUrl, {
          bool forceReload = false,
        }) =>
            _reloadForFreshUrl(
          tab,
          sourcePageUrl,
          forceReload: forceReload,
        ),
        isMounted: mounted,
      );

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
          .firstWhere((m) => m.url.contains('.m3u8'))
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
              if (src && src.indexOf('.m3u8') !== -1) return src;
            }
            const medias = root.querySelectorAll('video, audio');
            for (const m of medias) {
              const src = m.currentSrc || m.src || '';
              if (src && src.indexOf('.m3u8') !== -1) return src;
            }
            const scripts = root.querySelectorAll('script');
            for (const sc of scripts) {
              const text = sc.textContent || '';
              const match = text.match(/https?:\\/\\/[^"\\\\s]+\\.m3u8[^"\\\\s]*/);
              if (match) return match[0];
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
      if (result is String && result.isNotEmpty && result.contains('.m3u8')) {
        return result;
      }
    } catch (_) {}
    return null;
  }

  String _downloadFilenameFor(String? label, String targetUrl) {
    // Extract quality label from URL pattern like "1080p.mp4" or "1080p"
    final qualityMatch = RegExp(r'(\d+)p').firstMatch(targetUrl);
    final qualityLabel = qualityMatch != null
        ? ' (${qualityMatch.group(1)}p)'
        : '';

    final uri = Uri.tryParse(targetUrl);
    final segments =
        uri?.pathSegments
            .where((segment) => segment.trim().isNotEmpty)
            .toList(growable: false) ??
        const <String>[];
    var filename = label?.trim();
    if (filename == null || filename.isEmpty) {
      filename = segments.isNotEmpty ? segments.last : uri?.host ?? 'download';
    }
    // For HLS URLs, strip the extension — the downloader picks the final one
    final lowFilename = filename.toLowerCase();
    if (lowFilename.endsWith('.m3u8')) {
      filename = filename.substring(0, filename.length - 5);
    }
    filename = filename
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .trim();
    if (filename.isEmpty) filename = 'download';
    if (!filename.contains('.') && segments.isEmpty) {
      filename = '$filename.html';
    }
    return '$filename$qualityLabel';
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
      _showSnack('Favorite removed.');
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
      _showSnack('Page saved.');
    } catch (error) {
      _showSnack('Could not save page: $error');
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
      _showSnack('No URL to share.');
      return;
    }
    try {
      await PublicDownloadsService.shareUrl(url);
    } catch (error) {
      _showSnack('Could not share: $error');
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
      _showSnack('Open a page first.');
      return;
    }
    final host = (Uri.tryParse(currentUrl)?.host ?? '').toLowerCase();
    if (host.isEmpty) {
      _showSnack('No host for zoom.');
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
        backgroundColor: AuroraColors.surface,
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
        _showSnack('Open a page first to set a per-site UA.');
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
    _showSnack('User-Agent set to ${_uaProfileLabels[result] ?? result}.');
  }

  Future<void> _editSiteUserAgent(String currentUrl) async {
    final host = (Uri.tryParse(currentUrl)?.host ?? '').toLowerCase();
    if (host.isEmpty) {
      _showSnack('No host for UA override.');
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
    _showSnack('Saved UA for $host.');
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
      Navigator.of(context).pop();
      _showFavoritesSheet();
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
    onNewFolderCreated: () async => _showFavoritesSheet(),
    onEditFavorite: (favorite) => _editFavoriteFolder(favorite),
  );

  Future<void> _editFavoriteFolder(BrowserFavorite favorite) async {
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
      return;
    }
    final tags = tagsController.text
        .split(',')
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty)
        .toList(growable: false);
    tagsController.dispose();
    await _saveLibrary(
      _library.copyWith(
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
      ),
    );
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
      backgroundColor: AuroraColors.overlay,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Browser Tools',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
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
                      color: AuroraColors.accentAmber,
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
                      color: AuroraColors.mutedText,
                      onTap: () {
                        Navigator.pop(ctx);
                        _resetPageElementBlocks();
                      },
                    ),
                  ],
                ),
              ],
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
      color: Colors.white.withValues(alpha: 0.05),
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
                  color: color.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 22),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white70,
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

  Future<void> _showMediaPreview(SniffedMedia media) => showMediaPreview(
    context,
    media,
    activeTab: _activeTab,
    isMounted: mounted,
          getCookiesForUrl: _sniffIntakeController.getCookiesForUrl,
    buildSniffedDownloadHeaders: ({
      required BrowserTab tab,
      required SniffedMedia media,
      required Map<String, String> cookieHeaders,
      String? currentUrl,
    }) =>
        _buildSniffedDownloadHeaders(
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
    if (!path.endsWith('.m3u8') &&
        !path.contains('/hls/') &&
        !path.contains('/master') &&
        !path.contains('/playlist') &&
        !path.contains('/manifest') &&
        !path.contains('/dash/')) {
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
    if (uri == null ||
        (!path.endsWith('.m3u8') &&
            !path.contains('/hls/') &&
            !path.contains('/master') &&
            !path.contains('/playlist') &&
            !path.contains('/manifest') &&
            !path.contains('/dash/'))) {
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
          category: LogCategory.sniffer, screen: LogScreen.browser, eventType: LogEventType.sniff);
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
        category: LogCategory.sniffer, screen: LogScreen.browser, eventType: LogEventType.sniff);
        // 1st fallback: WebView JavaScript fetch() — it sends cookies and
        // has Cloudflare clearance from the page session.
        String? jsBody;
        try {
          jsBody = await _activeTab.controller.fetchViaJavaScript(
            url,
            headers: headers,
          );
        } catch (e) {
          AuroraLog.instance.error('JS fetch error: $e', category: LogCategory.sniffer, screen: LogScreen.browser, eventType: LogEventType.error);
        }
        if (jsBody != null && jsBody.isNotEmpty) {
          response = http.Response(
            jsBody,
            200,
            request: http.Request('GET', uri),
          );
          AuroraLog.instance.debug(
    'WebView JS fetch succeeded for variant fetch',
          category: LogCategory.sniffer, screen: LogScreen.browser, eventType: LogEventType.sniff);
        } else {
          AuroraLog.instance.debug(
    'WebView JS fetch failed, trying native Android HTTP…',
          category: LogCategory.sniffer, screen: LogScreen.browser, eventType: LogEventType.sniff);
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
                category: LogCategory.sniffer, screen: LogScreen.browser, eventType: LogEventType.sniff);
              }
            }
          } catch (e) {
            AuroraLog.instance.error('Native fallback error: $e', category: LogCategory.sniffer, screen: LogScreen.browser, eventType: LogEventType.error);
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
        formatSize: (
          int bytes, {
          bool isEstimated = false,
        }) =>
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
    onAddToQueue: (
      ctx,
      media, {
      List<SniffedMedia> variants = const [],
    }) =>
        _showAddQueueDialog(ctx, media, variants: variants),
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
              _mediaCatchController.analyze(
                _sortedMedia(_activeTab.snifferEngine.detectedMedia),
              ).groups,
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
  );

  Widget _compactFilterChip(
    String label,
    MediaFilter value,
    IconData icon,
    MediaFilter current,
    ValueChanged<MediaFilter> onSelected,
  ) => compactFilterChip(label, value, icon, current, onSelected);

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
  /// Extracts the file extension from a URL's path (e.g. `.conf` from
  /// `https://example.com/wireguard/client.conf`). Returns empty string
  /// if the path has no extension.
  String _extensionFromUrlPath(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return '';
    final path = uri.path;
    // Strip trailing slashes, then find last segment.
    final segments = path.endsWith('/') ? path.substring(0, path.length - 1).split('/') : path.split('/');
    final last = segments.last;
    final dot = last.lastIndexOf('.');
    if (dot <= 0 || dot >= last.length - 1) return '';
    return last.substring(dot);
  }

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
    final urlExt = _extensionFromUrlPath(url);
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
          ? parsed.path.split('/').lastWhere((s) => s.isNotEmpty, orElse: () => '')
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

    // Check for duplicates.
    bool force = false;
    if (_downloadQueue.urlExists(url)) {
      final skip = await _showDuplicatePrompt(context, suggestedName);
      if (skip ?? true) return;
      force = true;
    }
    _downloadQueue.addTask(task, force: force);

    if (mounted) {
      _showSnack('Download started: $suggestedName');
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
        title: const Text('Download detected'),
        content: Text(
          name.isNotEmpty ? 'File: $name' : 'URL: $url',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              // Add to queue (ask once).
              unawaited(_enqueueDirectDownload(tab, url, suggestedFilename));
            },
            child: const Text('Add to Queue'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              // Block this specific download silently.
            },
            child: const Text('Block'),
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
    final tabTitle = _activeTab.title?.trim() ?? '';
    final bestTitle = metaTitle.isNotEmpty ? metaTitle : tabTitle;

    var ext = mediaName.contains('.') ? '.${mediaName.split('.').last}' : '';
    if (ext.toLowerCase() == '.m3u8') {
      ext = ''; // Let the HLS downloader pick .ts/.mp4/.m4a
    } else if (ext.toLowerCase() == '.mpd') {
      ext = ''; // Let the DASH downloader pick the output extension
    } else if (media != null && media.type == MediaType.playlist) {
      ext = ''; // Disguised playlist (e.g. index.jpg with #EXTM3U body)
    }

    String qualityLabel = '';
    if (mediaUrl != null) {
      final qMatch = RegExp(r'(\d+)p').firstMatch(mediaUrl);
      if (qMatch != null) qualityLabel = qMatch.group(1)!;
    }

    final base = mediaName.replaceAll(RegExp(r'\.[^.]+$'), '').trim();

    if (bestTitle.isNotEmpty) {
      final sanitized = bestTitle
          .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
          .trim();
      if (sanitized.isNotEmpty) {
        if (qualityLabel.isNotEmpty) {
          return '$sanitized (${qualityLabel}p)$ext';
        }
        // Append base name when title is generic (e.g., domain)
        final baseSuffix = base.isNotEmpty && base != sanitized ? '_$base' : '';
        return '$sanitized$baseSuffix$ext';
      }
    }

    if (qualityLabel.isNotEmpty) {
      final qBase = base.isNotEmpty ? base : 'video';
      return '${qBase}_${qualityLabel}p$ext';
    }
    return base.isNotEmpty ? '$base$ext' : 'download$ext';
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
        parts.add(_sizeLabel(item.contentLengthBytes, isEstimated: false));
        break;
      case SniffedMediaDisplayMode.duration:
        parts.add(_durationLabel(item.duration));
        break;
      case SniffedMediaDisplayMode.both:
        parts.add(_sizeLabel(item.contentLengthBytes, isEstimated: false));
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
      _showSnack('No original URL detected.');
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
      _showSnack('Print to PDF not supported on this page.');
    }
  }

  Future<void> _forwardToUcBrowser() async {
    final url = await _activeTab.controller.currentUrl();
    if (url == null || url.isEmpty) return;
    try {
      await PublicDownloadsService.openUrl(url);
    } catch (_) {
      _showSnack('Could not open UC Browser.');
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

  void _onWebPageTextSelected(String text) {
    if (!mounted) return;
    setState(() {
      _selectedText = text;
      _selectionToolbarVisible = true;
    });
  }

  void _closeSelectionToolbar() {
    if (!mounted) return;
    setState(() {
      _selectionToolbarVisible = false;
      _selectedText = null;
    });
  }

  Future<void> _selectionActionTranslate() async {
    final text = _selectedText;
    if (text == null || text.isEmpty) return;
    final target = translateLanguageById(widget.settings.translateTargetLang);
    final url = Uri.parse(
      'https://translate.google.com/translate?sl=auto&tl=${target.id}&text='
      '${Uri.encodeQueryComponent(text)}',
    );
    unawaited(_loadUrlWithHostSettings(_activeTab, url));
    _closeSelectionToolbar();
  }

  Future<void> _selectionActionSearch() async {
    final text = _selectedText;
    if (text == null || text.isEmpty) return;
    final url = Uri.parse(widget.settings.searchEngine.buildSearchUrl(text));
    unawaited(_loadUrlWithHostSettings(_activeTab, url));
    _closeSelectionToolbar();
  }

  Future<void> _selectionActionCopy() async {
    final text = _selectedText;
    if (text == null || text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    _showSnack('Selection copied.');
    _closeSelectionToolbar();
  }

  Future<void> _selectionActionShare() async {
    final text = _selectedText;
    if (text == null || text.isEmpty) return;
    try {
      final url = await _activeTab.controller.currentUrl() ?? '';
      final payload = url.isEmpty ? text : '"$text"\n\n— $url';
      await PublicDownloadsService.shareUrl(payload);
    } catch (error) {
      _showSnack('Could not share: $error');
    }
    _closeSelectionToolbar();
  }

  Future<void> _clearDataForSite(String url) async {
    final tab = _activeTab;
    final host = (Uri.tryParse(url)?.host ?? '').toLowerCase();
    if (host.isEmpty) {
      _showSnack('No host to clear.');
      return;
    }
    try {
      await tab.controller.clearSiteData(url);
      await tab.controller.reload();
      _showSnack('Cleared cookies, storage and cache for $host.');
    } catch (error) {
      _showSnack('Could not clear data: $error');
    }
  }

  Future<void> _showAutofillMenu() async {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
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

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _showPickerSnack(String message, {required VoidCallback onCancel}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 30),
        action: SnackBarAction(label: 'Cancel', onPressed: onCancel),
      ),
    );
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
                  color: AuroraColors.accent,
                  backgroundColor: AuroraColors.surfaceVariant,
                ),
              ),
              Material(
                color: AuroraColors.overlaySurface,
                elevation: 8,
                borderRadius: BorderRadius.circular(20),
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: widget.onCancel,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.close, size: 18, color: AuroraColors.text),
                        SizedBox(width: 6),
                        Text(
                          'Cancel',
                          style: TextStyle(color: AuroraColors.text),
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
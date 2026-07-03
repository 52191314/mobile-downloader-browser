import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../settings/download_settings.dart';
import '../browser_controller.dart';
import '../media_sniffer_engine.dart';
import '../models/browser_tab.dart';
import '../safe_browsing_service.dart';
import '../session_recovery.dart';
import 'sniff_intake_controller.dart';
import 'tab_manager.dart';

/// Host interface that [TabLifecycleController] uses to drive the
/// owning [SnifferScreen] state. Each member is a callback or getter
/// the host state must satisfy; this keeps the controller free of any
/// direct `State` reference and unit-testable in isolation.
abstract class TabLifecycleHost {
  /// Whether the host widget is currently mounted. Used to guard
  /// post-async `setState` and timer-driven UI rebuilds.
  bool get isMounted;

  /// Whether the host is in desktop mode (forces Desktop Chrome UA on
  /// every newly opened tab).
  bool get isDesktopMode;

  /// Active tab reference — the controller uses this only in
  /// `startVideoPoll` to skip non-active tabs.
  BrowserTab get activeTab;

  /// The current download settings (max detected media, disabled
  /// media types, adblock flags, user-agent profile, …).
  DownloadSettings get settings;

  /// The base directory used for tab persistence and sniffed-media
  /// caches. May be `null` until `_initPaths` completes.
  String? get baseDir;

  /// Triggers a [State.setState] rebuild on the host. Called whenever
  /// the tab list or active-tab index changes.
  void markNeedsBuild();

  /// Resolve the user-agent string for a profile key
  /// (e.g. `mobile`, `desktop_chrome`).
  String uaForProfile(String profile);

  /// Loads [uri] into [tab]'s WebView with safe-browsing checks, host
  /// overrides, and per-host zoom applied.
  Future<void> loadUrlWithHostSettings(
    BrowserTab tab,
    Uri uri, {
    bool addToHistory,
  });

  /// Re-runs the cosmetic CSS for the tab.
  Future<void> applyCosmeticRules([BrowserTab? tab]);

  /// Configures adblock rules and cosmetic CSS for the tab.
  Future<void> configureTabAdblock(BrowserTab tab);

  /// Refreshes the page meta (title, structured data) for [tab].
  Future<void> refreshPageInfo(BrowserTab tab, {bool recordHistory});

  /// Applies the per-host zoom to [tab]'s WebView for [url].
  void applyZoomForPage(BrowserTab tab, String url);

  /// Injects / removes the Aurora dark-mode CSS for [tab]'s WebView.
  Future<void> applyDarkModeForPage(BrowserTab tab, String url);

  /// Switches the active tab to the one at [index]. Cleans up address
  /// bar, suggestions, scroll position, and starts the video poll.
  void switchToActiveTab(int index);

  /// Cancels the element picker (if active). Called before closing a
  /// tab or switching tabs so the picker state does not leak.
  void cancelPickerIfActive();

  /// Re-evaluates the active tab's back/forward state and rebuilds the
  /// UI.
  void updateTabNavState(BrowserTab tab);

  /// Shows a snackbar message. Used to inform the user about reopen
  /// success/failure.
  void showSnack(String message);

  /// Returns a human-readable title for a URL (used for the "Reopened
  /// `<title>`" snackbar).
  String titleForUrl(String url);

  /// Starts the 15-second video / audio src poll for the active tab.
  void startVideoPoll(BrowserTab tab);

  /// Wires the WebView controller callbacks (onUrlChanged, JS channels)
  /// and registers the [HlsPlaylistChannel], [MediaSnifferChannel], etc.
  void setupTabCallbacks(BrowserTab tab);

  /// Reads / writes the set of tab IDs whose WebViews have been built
  /// (lazy creation).
  Set<String> get builtWebViewTabIds;

  /// Sniff intake controller — used to schedule media saves after
  /// navigation.
  SniffIntakeController get sniffIntakeController;

  /// Mark that [loadTabsAndMedia] has finished restoring the tab list
  /// from disk. The host uses this to decide whether the lazy
  /// `BrowserWidget` stack should render real WebViews.
  void markTabsLoaded();
}

/// Owns the browser-tab lifecycle: loading saved tabs, opening new
/// tabs, closing tabs, reopening the last-closed tab, persisting tab
/// state, running the 15-second video poll, and the per-tab UI state
/// (back/forward buttons, loading spinner).
///
/// All host actions that depend on the parent [State] (safe-browsing,
/// cosmetic rules, dark mode, per-host UA, page info, …) are surfaced
/// as callbacks on [TabLifecycleHost] so this class has no compile-time
/// dependency on the parent widget.
class TabLifecycleController {
  final TabLifecycleHost host;
  final TabManager tabManager;
  final DownloadSettings settings;
  final SafeBrowsingService safeBrowsing;
  final SessionRecovery sessionRecovery;

  /// Pre-built controller for the first tab (test injection).
  final SnifferBrowserController? injectedController;

  /// Factory for the test/mock browser controller.
  final SnifferBrowserController Function()? debugControllerFactory;

  /// Pre-built sniffer engine for the first tab (test injection).
  final MediaSnifferEngine? injectedSnifferEngine;

  TabLifecycleController({
    required this.host,
    required this.tabManager,
    required this.settings,
    required this.safeBrowsing,
    required this.sessionRecovery,
    this.injectedController,
    this.debugControllerFactory,
    this.injectedSnifferEngine,
  });

  String? get baseDir => host.baseDir;

  /// Convenience accessor for the active tab.
  BrowserTab get _activeTab => tabManager.activeTab;
  List<BrowserTab> get _tabs => tabManager.tabs;

  // ---------------------------------------------------------------------------
  // Tab nav state
  // ---------------------------------------------------------------------------

  void updateTabNavState(BrowserTab tab) {
    () async {
      tab.canGoBack = await tab.controller.canGoBack();
      tab.canGoForward = await tab.controller.canGoForward();
      if (host.isMounted) host.markNeedsBuild();
    }();
  }

  // ---------------------------------------------------------------------------
  // Persist + restore
  // ---------------------------------------------------------------------------

  Future<void> loadTabsAndMedia() async {
    if (baseDir == null) return;
    final file = File('$baseDir/browser_tabs.json');
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is List && decoded.isNotEmpty) {
          // Dispose the default blank tab created in initState, then
          // restore saved tabs from the browser_tabs.json.
          for (final tab in _tabs.toList()) {
            tab.dispose();
            _tabs.remove(tab);
          }
          int activeIdx = 0;
          for (var i = 0; i < decoded.length; i++) {
            final entry = decoded[i];
            if (entry is Map) {
              final url = entry['url'] as String?;
              final tabId = entry['id'] as String?;
              final isActive = entry['active'] as bool? ?? false;
              final history = (entry['history'] as List?)
                  ?.whereType<String>()
                  .toList(growable: false);
              final historyIndex =
                  (entry['historyIndex'] as num?)?.round() ?? -1;
              openNewTab(
                url: url,
                switchToTab: false,
                restoredId: tabId,
                restoredHistory: history,
                restoredHistoryIndex: historyIndex,
              );
              if (isActive) activeIdx = _tabs.length - 1;
            }
          }
          if (_tabs.isEmpty) openNewTab();
          host.switchToActiveTab(activeIdx.clamp(0, _tabs.length - 1));
          host.markTabsLoaded();
          return;
        }
      } catch (_) {}
    }
    // No saved tabs — the default blank tab from initState is already there.
    // Load its sniffed media cache.
    if (baseDir != null) {
      unawaited(
        _activeTab.snifferEngine.loadDetectedMedia(
          '$baseDir/sniffed_media_cache_${_activeTab.id}.json',
        ),
      );
    }
    host.markTabsLoaded();
  }

  Future<void> saveTabs() async {
    if (baseDir == null) return;
    try {
      final dir = Directory(baseDir!);
      if (!await dir.exists()) await dir.create(recursive: true);
      final list = _tabs
          .asMap()
          .entries
          .map(
            (e) => {
              'id': e.value.id,
              'url': e.value.addressController.text.trim(),
              'active': e.key == tabManager.activeTabIndex,
              'history': e.value.controller.historyUrls,
              'historyIndex': e.value.controller.historyIndex,
            },
          )
          .toList(growable: false);
      final file = File('$baseDir/browser_tabs.json');
      await file.writeAsString(jsonEncode(list));
      unawaited(
        sessionRecovery.updateTabs(
          list
              .where((e) => (e['url'] as String? ?? '').isNotEmpty)
              .map(
                (e) => SessionTab(
                  id: e['id'] as String? ?? '',
                  url: e['url'] as String? ?? '',
                ),
              )
              .toList(growable: false),
        ),
      );
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Open / close / reopen
  // ---------------------------------------------------------------------------

  void openNewTab({
    String? url,
    bool switchToTab = true,
    String? restoredId,
    List<String>? restoredHistory,
    int restoredHistoryIndex = -1,
    /// When non-null, the new tab is inserted at this index instead of
    /// appended to the end.  Used for "Open in Background Tab" which
    /// should place the new tab right after the current one.
    int? insertAtIndex,
  }) {
    final useInjectedController =
        _tabs.isEmpty && injectedController != null;
    final controller = useInjectedController
        ? injectedController!
        : debugControllerFactory?.call() ??
              SnifferWebViewControllerImpl();
    final injectedEngine = injectedSnifferEngine;
    final snifferEngine =
        injectedEngine ??
        MediaSnifferEngine(
          maxDetectedMedia: settings.maxDetectedMedia,
          disabledMediaTypes: settings.disabledMediaTypes,
        );
    final addressController = TextEditingController();
    final tabId =
        restoredId ?? DateTime.now().millisecondsSinceEpoch.toString();
    final tab = BrowserTab(
      id: tabId,
      controller: controller,
      snifferEngine: snifferEngine,
      addressController: addressController,
      ownsEngine: injectedEngine == null,
    );
    // Fetch and cache the browser's user agent
    unawaited(() async {
      try {
        final ua = await controller.evaluateJavaScript('navigator.userAgent');
        if (ua is String && ua.isNotEmpty) {
          tab.userAgent = ua.startsWith('"') && ua.endsWith('"')
              ? ua.substring(1, ua.length - 1)
              : ua;
        }
      } catch (_) {}
    }());
    tab.mediaSubscription = tab.snifferEngine.onMediaChanged.listen((_) {
      host.sniffIntakeController.scheduleMediaSave(tab);
    });
    tab.snifferEngine.cookieProvider = ({String? url}) async {
      // Use the native cookie manager via getCookiesForDomain(), which reads the
      // full system cookie jar including HttpOnly tokens. When a media URL is
      // provided, fetch cookies for that URL's domain instead of the page domain.
      return tab.controller.getCookiesForDomain(url: url);
    };
    tab.snifferEngine.fetchViaWebView = (url) =>
        tab.controller.fetchHeadersViaJavaScript(url);
    // Wire fetchPlaylistBodyViaWebView so HLS playlists behind Cloudflare/WAF
    // that are not in the JS-intercepted cache can still be fetched through the
    // WebView's authenticated session. CORS may block cross-origin reads, but
    // same-origin playlists will work and it's better than no fallback.
    tab.snifferEngine.fetchPlaylistBodyViaWebView = (url) =>
        tab.controller.fetchPlaylistBodyViaJavaScript(url);
    tab.snifferEngine.hlsPlaylistCache = (url) => tab.hlsPlaylistCache[url];
    host.setupTabCallbacks(tab);
    unawaited(host.configureTabAdblock(tab));
    if (baseDir != null) {
      unawaited(
        tab.snifferEngine.loadDetectedMedia(
          '$baseDir/sniffed_media_cache_${tab.id}.json',
        ),
      );
    }
    // Apply the global User-Agent profile when it is not the default mobile UA.
    final uaProfile = settings.userAgentProfile;
    if (host.isDesktopMode) {
      final ua = host.uaForProfile('desktop_chrome');
      tab.controller.setUserAgent(ua);
      tab.userAgent = ua;
    } else if (uaProfile != 'mobile') {
      final ua = host.uaForProfile(uaProfile);
      tab.controller.setUserAgent(ua);
      tab.userAgent = ua;
    }
    if (insertAtIndex != null && insertAtIndex <= _tabs.length) {
      _tabs.insert(insertAtIndex, tab);
    } else {
      _tabs.add(tab);
    }
    if (restoredHistory != null && restoredHistory.isNotEmpty) {
      tab.controller.restoreHistory(restoredHistory, restoredHistoryIndex);
    }
    if (url != null) {
      addressController.text = url;
      unawaited(
        host.loadUrlWithHostSettings(
          tab,
          Uri.parse(url),
          addToHistory: restoredHistory == null,
        ),
      );
    }
    unawaited(host.refreshPageInfo(tab, recordHistory: false));
    if (switchToTab) {
      final newIndex = insertAtIndex ?? _tabs.length - 1;
      host.switchToActiveTab(newIndex);
    } else if (host.isMounted) {
      host.markNeedsBuild();
    }
    unawaited(saveTabs());
  }

  void startVideoPoll(BrowserTab tab) {
    // Only run the video poll on the active tab. Without this guard every
    // tab's timer would run simultaneously and waste resources.
    if (tab != _activeTab) return;
    tab.videoPollTimer?.cancel();
    // Slowed from 2s → 5s. installBrowserGuards() is called on navigation
    // events, not here, to prevent the expensive DOM scan from causing FPS
    // drops.
    tab.videoPollTimer = Timer.periodic(const Duration(seconds: 15), (
      timer,
    ) async {
      if (!host.isMounted || !_tabs.contains(tab)) {
        timer.cancel();
        if (identical(tab.videoPollTimer, timer)) {
          tab.videoPollTimer = null;
        }
        return;
      }
      try {
        // Only poll for video/audio src — no guard reinstall, no innerHTML
        // scan here.
        final result = await tab.controller.evaluateJavaScript('''
(function() {
  var found = [];
  function add(u) { if(u && !found.includes(u)) found.push(u); }
  // .ts is excluded so HLS fragments do not flood the sniffer.
  var re = /\\.(mp4|m3u8|webm|mkv|avi|flv|mov|3gp|ogv|wmv|m4v|f4v|mpeg|mpg|mts|m2ts|mp3|wav|aac|ogg|m4a|flac)(\\?|\$)/i;
  // 1. Main window video/audio elements
  var els = document.querySelectorAll("video,audio");
  for(var i=0;i<els.length;i++){
    var src=els[i].currentSrc||els[i].src||"";
    if(src) add(src);
  }
  // 2. Same-origin iframes
  var ifs = document.querySelectorAll("iframe");
  for(var i=0;i<ifs.length;i++) try {
    var d = ifs[i].contentDocument;
    if(d){
      var ivids = d.querySelectorAll("video,audio");
      for(var j=0;j<ivids.length;j++){ var s=ivids[j].currentSrc||ivids[j].src||""; if(s) add(s); }
    }
  } catch(e) {}
  // NOTE: performance.getEntriesByType('resource') removed — the
  // PerformanceObserver in installBrowserGuards already catches these.
  // Scanning hundreds of resource entries every 15s caused UI freezes.
  return found.join("|||");
})()
''');
        if (result is String && result.trim().isNotEmpty) {
          final urls = result.split('|||');
          for (final url in urls) {
            final trimmed = url.trim();
            if (trimmed.isNotEmpty) {
              host.sniffIntakeController.sniffBrowserUrl(
                tab,
                trimmed,
                sourcePageUrl: tab.addressController.text,
              );
            }
          }
        }
      } catch (_) {}
    });
  }

  void closeTab(int index) {
    if (_tabs.isEmpty) return;
    final removedTabId = index < _tabs.length ? _tabs[index].id : null;
    tabManager.fetchedIframeSrcs.clear();
    host.cancelPickerIfActive();
    final wasSingleton = _tabs.length <= 1;
    tabManager.closeTab(index);
    if (removedTabId != null) {
      host.builtWebViewTabIds.remove(removedTabId);
    }
    if (wasSingleton) {
      openNewTab(switchToTab: false);
    }
    tabManager.mediaRebuildTimer?.cancel();
    tabManager.mediaSaveTimer?.cancel();
    if (host.isMounted) host.markNeedsBuild();
    unawaited(saveTabs());
  }

  /// Close all tabs, then open a single fresh blank tab so the
  /// browser is never empty.
  void closeAllTabs() {
    if (tabManager.tabs.isEmpty) return;
    host.cancelPickerIfActive();
    tabManager.closeAllTabs();
    host.builtWebViewTabIds.clear();
    openNewTab(switchToTab: false);
    host.switchToActiveTab(0);
    unawaited(saveTabs());
  }

  void reopenLastClosedTab() {
    final url = tabManager.reopenLastClosedTab();
    if (url == null) {
      host.showSnack('No recently closed tabs.');
      return;
    }
    openNewTab(url: url);
    host.showSnack('Reopened ${host.titleForUrl(url)}.');
  }
}

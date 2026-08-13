import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../downloader/headless_webview_fetcher.dart';
import '../../settings/download_settings.dart';
import '../browser_controller.dart';
import '../hls_playlist_cache_lookup.dart';
import '../media_sniffer_engine.dart';
import '../models/browser_tab.dart';
import '../safe_browsing_service.dart';
import '../session_recovery.dart';
import 'sniff_intake_controller.dart';
import 'tab_manager.dart';

import '../models/tab_group.dart';

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
    bool forceInApp,
  });

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

  /// Runs deferred cold-start work for [tab] once (adblock, media cache,
  /// initial URL). Safe to call repeatedly; no-ops when already ready.
  Future<void> ensureTabStartupReady(BrowserTab tab);
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

  /// Synchronously updates [tab.canGoBack] and [tab.canGoForward] from the
  /// controller's [historyIndex], which is kept in sync with the WebView's
  /// actual navigation stack via [onUpdateVisitedHistory] and the new
  /// [onNavStateChanged] callback. This avoids an async round-trip to the
  /// WebView's native `canGoBack()` / `canGoForward()` on every navigation.
  ///
  /// An async reconciliation with the WebView's own history is also available
  /// via [reconcileNavStateAsync] for safety.
  void updateTabNavState(BrowserTab tab) {
    tab.canGoBack = tab.controller.historyIndex > 0;
    tab.canGoForward =
        tab.controller.historyIndex < tab.controller.historyUrls.length - 1;
    if (host.isMounted) host.markNeedsBuild();
  }

  /// Async reconciliation with the WebView's native back/forward state.
  /// Called as a backup to [updateTabNavState] when there is reason to
  /// distrust the controller's [`historyIndex`] (e.g. after JS-triggered
  /// navigations that might not have fired [onUpdateVisitedHistory]).
  Future<void> reconcileNavStateAsync(BrowserTab tab) async {
    tab.canGoBack = await tab.controller.canGoBack();
    tab.canGoForward = await tab.controller.canGoForward();
    if (host.isMounted) host.markNeedsBuild();
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
          // Defer adblock / media-cache / URL load for every restored tab,
          // then only wake the active one. Large Secure Folder tab lists
          // previously froze cold start for 10–15s doing this N times.
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
              final groupName = entry['groupName'] as String?;
              final groupColorIndex = entry['groupColorIndex'] as int?;
              final autoGrouped = entry['autoGrouped'] as bool? ?? false;
              openNewTab(
                url: url,
                switchToTab: false,
                restoredId: tabId,
                restoredHistory: history,
                restoredHistoryIndex: historyIndex,
                restoredGroupName: groupName,
                restoredColorIndex: groupColorIndex,
                restoredAutoGrouped: autoGrouped,
                deferStartupWork: true,
                persist: false,
              );
              if (isActive) activeIdx = _tabs.length - 1;
            }
          }
          loadGroups();
          if (_tabs.isEmpty) openNewTab();
          final idx = activeIdx.clamp(0, _tabs.length - 1);
          host.switchToActiveTab(idx);
          // Mount WebViews only after the first frame so chrome paints first.
          // Navigation for the active tab is delayed further inside
          // ensureTabStartupReady (blank WebView → then load URL).
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!host.isMounted) return;
            host.markTabsLoaded();
            // Give the blank WebView / GPU a moment before heavy page load.
            Future<void>.delayed(const Duration(milliseconds: 700), () {
              if (!host.isMounted || idx >= _tabs.length) return;
              unawaited(host.ensureTabStartupReady(_tabs[idx]));
            });
          });
          // Single persist after bulk restore (openNewTab skipped N writes).
          unawaited(saveTabs());
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
    unawaited(host.ensureTabStartupReady(_activeTab));
    host.markTabsLoaded();
  }

  Future<void> saveTabs() async {
    if (baseDir == null) return;
    try {
      final dir = Directory(baseDir!);
      if (!await dir.exists()) await dir.create(recursive: true);
      final list = _tabs
          .where((t) => !t.isPreview)
          .toList(growable: false)
          .asMap()
          .entries
          .map(
            (e) => {
              'id': e.value.id,
              'url': e.value.addressController.text.trim(),
              'active': e.key == tabManager.activeTabIndex,
              'history': e.value.controller.historyUrls,
              'historyIndex': e.value.controller.historyIndex,
              'groupName': e.value.groupName,
              'groupColorIndex': e.value.groupColorIndex,
              'autoGrouped': e.value.autoGrouped,
            },
          )
          .toList(growable: false);
      final file = File('$baseDir/browser_tabs.json');
      final encoded = jsonEncode(list);
      final tempFile = File('${file.path}.tmp');
      await tempFile.writeAsString(encoded, flush: true);
      try {
        await tempFile.rename(file.path);
      } catch (_) {
        await tempFile.copy(file.path);
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      }
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
      unawaited(saveGroups());
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Group persistence
  // ---------------------------------------------------------------------------

  Future<void> loadGroups() async {
    if (baseDir == null) return;
    try {
      final file = File('$baseDir/tab_groups.json');
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is List) {
          final groups = decoded
              .whereType<Map>()
              .map((e) => TabGroup.fromJson(Map<String, dynamic>.from(e)))
              .toList();
          tabManager.replaceGroups(groups);
        }
      }
    } catch (_) {}
  }

  Future<void> saveGroups() async {
    if (baseDir == null) return;
    try {
      final dir = Directory(baseDir!);
      if (!await dir.exists()) await dir.create(recursive: true);
      final data = tabManager.tabGroups.map((g) => g.toJson()).toList();
      final file = File('$baseDir/tab_groups.json');
      final encoded = jsonEncode(data);
      final tempFile = File('${file.path}.tmp');
      await tempFile.writeAsString(encoded, flush: true);
      try {
        await tempFile.rename(file.path);
      } catch (_) {
        await tempFile.copy(file.path);
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      }
    } catch (_) {}
  }

  void _applyAutoGroupFor(BrowserTab tab) {
    if (tab.autoGrouped) return;
    final hostStr = Uri.tryParse(tab.addressController.text)?.host;
    if (hostStr == null || hostStr.isEmpty) return;
    for (final group in tabManager.tabGroups) {
      if (group.autoHost != null && hostStr.contains(group.autoHost!)) {
        tabManager.moveTabToGroup(tab, groupName: group.name);
        tab.autoGrouped = true;
        return;
      }
    }
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
    String? restoredGroupName,
    int? restoredColorIndex,
    bool restoredAutoGrouped = false,

    /// When non-null, the new tab is inserted at this index instead of
    /// appended to the end.  Used for "Open in Background Tab" which
    /// should place the new tab right after the current one.
    int? insertAtIndex,

    /// When true, build the WebView even if the tab is opened in the
    /// background so its page can start loading immediately.
    bool buildImmediately = false,

    /// Skip adblock configure, media-cache load, and URL navigation until
    /// [TabLifecycleHost.ensureTabStartupReady] (used for bulk tab restore).
    bool deferStartupWork = false,

    /// When false, skip [saveTabs] (bulk restore writes once at the end).
    bool persist = true,
  }) {
    final useInjectedController = _tabs.isEmpty && injectedController != null;
    final controller = useInjectedController
        ? injectedController!
        : debugControllerFactory?.call() ?? SnifferWebViewControllerImpl();
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
      ownsController: !useInjectedController,
    );
    if (restoredGroupName != null) tab.groupName = restoredGroupName;
    if (restoredColorIndex != null) tab.groupColorIndex = restoredColorIndex;
    tab.autoGrouped = restoredAutoGrouped;
    // Restored shells must not auto-navigate the first WebView paint.
    if (deferStartupWork) {
      tab.canSeedWebViewUrl = false;
    }
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
    // Wire the headless-WebView fetcher as the last-resort tier for HLS/DASH
    // playlist body fetching. Created lazily and reuses a per-tab headless
    // WebView navigated to the CDN origin (same-origin XHR bypasses both CORS
    // and Cloudflare WAF). Disposed automatically via [BrowserTab.dispose].
    // Only allocate for tabs that will actually load soon — deferred tabs
    // create it on first ensureTabStartupReady to cut Secure Folder cold start.
    if (!deferStartupWork) {
      tab.headlessFetcher = HeadlessWebViewFetcher();
      tab.snifferEngine.fetchPlaylistBodyViaHeadlessWebView = (url) =>
          tab.headlessFetcher!.fetchText(url);
    }
    tab.snifferEngine.hlsPlaylistCache =
        (url) => lookupHlsPlaylistCache(tab.hlsPlaylistCache, url);
    host.setupTabCallbacks(tab);

    if (!deferStartupWork) {
      unawaited(host.configureTabAdblock(tab));
      if (baseDir != null) {
        unawaited(
          tab.snifferEngine.loadDetectedMedia(
            '$baseDir/sniffed_media_cache_${tab.id}.json',
          ),
        );
      }
      tab.startupReady = true;
      // Fetch UA only when the WebView may exist soon (not for deferred tabs).
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
    if (buildImmediately) {
      host.builtWebViewTabIds.add(tab.id);
    }
    if (restoredHistory != null && restoredHistory.isNotEmpty) {
      tab.controller.restoreHistory(restoredHistory, restoredHistoryIndex);
    }
    if (url != null) {
      final trimmed = url.trim();
      addressController.text = trimmed;
      // So BrowserWidget.initialUrl / setOnRecreated see the target even
      // before the first loadRequest completes.
      if (trimmed.isNotEmpty) {
        tab.currentUrl = trimmed;
      }
    }
    // Only refresh page info for blank/restored tabs.  When a URL is being
    // loaded, refreshPageInfo's currentUrl() races with loadRequest below and
    // can overwrite tab.currentUrl with "about:blank" before the WebView loads.
    if (url == null && !deferStartupWork) {
      unawaited(host.refreshPageInfo(tab, recordHistory: false));
    }
    if (switchToTab) {
      final newIndex = insertAtIndex ?? _tabs.length - 1;
      host.switchToActiveTab(newIndex);
      if (deferStartupWork) {
        unawaited(host.ensureTabStartupReady(tab));
      }
    } else if (host.isMounted) {
      host.markNeedsBuild();
    }
    // Defer URL load until after the build phase so the new tab's WebView
    // is created before loadRequest runs, avoiding any race between
    // _ready.future and onWebViewCreated.
    // BrowserWidget also seeds initialUrlRequest from address/currentUrl as a
    // backup when the platform view is first created (Queue external opens).
    // Restored background tabs skip this — ensureTabStartupReady loads on
    // first activation only.
    if (!deferStartupWork && url != null && url.trim().isNotEmpty) {
      final loadUrl = url.trim();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (host.isMounted && _tabs.contains(tab)) {
          unawaited(
            host.loadUrlWithHostSettings(
              tab,
              Uri.parse(loadUrl),
              addToHistory: restoredHistory == null,
            ),
          );
        }
      });
    }
    if (restoredGroupName == null) {
      _applyAutoGroupFor(tab);
    }
    if (persist) {
      unawaited(saveTabs());
    }
  }

  void startVideoPoll(BrowserTab tab) {
    // Only run the video poll on the active tab.
    if (tab != _activeTab) return;
    tab.videoPollTimer?.cancel();
    // Play: no video/audio src polling on restricted sites (hard-off).
    if (!tab.sniffingEnabled) return;
    int emptyPollCount = 0;
    // Poll interval tuned to 5s (was 3s).
    tab.videoPollTimer = Timer.periodic(const Duration(seconds: 5), (
      timer,
    ) async {
      if (!host.isMounted || !_tabs.contains(tab)) {
        timer.cancel();
        if (identical(tab.videoPollTimer, timer)) {
          tab.videoPollTimer = null;
        }
        return;
      }
      if (!tab.sniffingEnabled) {
        timer.cancel();
        if (identical(tab.videoPollTimer, timer)) {
          tab.videoPollTimer = null;
        }
        return;
      }
      try {
        // Only poll for video/audio src
        final result = await tab.controller.evaluateJavaScript('''
  (function() {
    var found = [];
    function add(u) { if(u && !found.includes(u)) found.push(u); }
    // .ts excluded so HLS fragments do not flood the sniffer.
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
    return found.join("|||");
  })()
  ''');
        if (result is String && result.trim().isNotEmpty) {
          emptyPollCount = 0;
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
        } else {
          emptyPollCount++;
          if (emptyPollCount >= 3) {
            timer.cancel();
            if (identical(tab.videoPollTimer, timer)) {
              tab.videoPollTimer = null;
            }
          }
        }
      } catch (_) {}
    });
  }

  void closeTab(int index) {
    if (_tabs.isEmpty) return;
    final removedTabId = index < _tabs.length ? _tabs[index].id : null;
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
  /// browser is never empty. The blank tab is created synchronously in the
  /// same microtask as the clear — no `await` sits between
  /// [TabManager.closeAllTabs] and [openNewTab] — so no async callback,
  /// timer, or media event can observe an empty tab list.
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
      host.showSnack('No tabs to reopen.');
      return;
    }
    openNewTab(url: url);
    host.showSnack('Reopened ${host.titleForUrl(url)} tab.');
  }

  // ---------------------------------------------------------------------------
  // Group delegation — thin wrappers that persist after mutation.
  // ---------------------------------------------------------------------------

  void moveTabToGroup(String tabId, String? groupName) {
    final idx = tabManager.indexOfTabId(tabId);
    if (idx < 0) return;
    tabManager.moveTabToGroup(tabManager.tabs[idx], groupName: groupName);
    unawaited(saveTabs());
    unawaited(saveGroups());
  }

  void renameGroup(String oldName, String newName) {
    tabManager.renameGroup(oldName, newName);
    unawaited(saveTabs());
    unawaited(saveGroups());
  }

  void setGroupColor(String name, int? colorIndex) {
    tabManager.setGroupColor(name, colorIndex);
    unawaited(saveGroups());
  }

  void setGroupAutoHost(String name, String? host) {
    tabManager.setGroupAutoHost(name, host);
    unawaited(saveGroups());
  }

  void closeGroup(String name) {
    final closedIds = tabManager.closeGroup(name);
    host.builtWebViewTabIds.removeAll(closedIds);
    // Closing a group can remove the last tab (e.g. a single group holding
    // every tab). Re-add a blank tab synchronously so the list is never
    // observably empty and the active tab's media subscription is restored.
    if (tabManager.tabs.isEmpty) {
      openNewTab(switchToTab: false);
      host.switchToActiveTab(0);
    }
    unawaited(saveTabs());
    unawaited(saveGroups());
    if (host.isMounted) host.markNeedsBuild();
  }

  void disbandGroup(String name) {
    tabManager.disbandGroup(name);
    unawaited(saveTabs());
    unawaited(saveGroups());
  }
}

import 'dart:async';

import 'package:flutter/material.dart';

import '../models/browser_tab.dart';
import '../models/closed_tab_snapshot.dart';

/// Manages the list of browser tabs, active tab state, and basic
/// open/close/switch lifecycle.
///
/// Fields are intentionally public during the incremental extraction
/// so the parent [State] can gradually migrate from direct field access
/// to managed methods.
class TabManager {
  final List<BrowserTab> tabs = [];
  int activeTabIndex = 0;
  bool isLoading = false;
  final List<ClosedTabSnapshot> recentlyClosedTabs = [];
  static const int maxRecentlyClosed = 12;

  /// Subscription to the active tab's media-changed stream.
  StreamSubscription<dynamic>? snifferSubscription;

  /// Timers for throttled media rebuild/save.
  Timer? mediaRebuildTimer;
  Timer? mediaSaveTimer;

  /// Set of iframe source URLs already fetched (used to avoid duplicates).
  final Set<String> fetchedIframeSrcs = {};

  /// Callback invoked after any state change that needs a [State.setState].
  VoidCallback? onRebuild;

  TabManager();

  // ---------------------------------------------------------------------------
  // Computed accessors
  // ---------------------------------------------------------------------------

  BrowserTab get activeTab => tabs[activeTabIndex];

  // ---------------------------------------------------------------------------
  // Tab lifecycle
  // ---------------------------------------------------------------------------

  /// Switch to the tab at [index].
  ///
  /// Returns the previous index, or -1 if the list is empty.
  int switchToActiveTab(int index) {
    if (tabs.isEmpty) return -1;
    final previous = activeTabIndex;
    activeTabIndex = index.clamp(0, tabs.length - 1);

    snifferSubscription?.cancel();
    snifferSubscription = activeTab.snifferEngine.onMediaChanged.listen((_) {
      onRebuild?.call();
    });

    for (var i = 0; i < tabs.length; i++) {
      final t = tabs[i];
      if (t == activeTab) {
        if (i != previous) unawaited(t.controller.thaw());
      } else {
        t.videoPollTimer?.cancel();
        if (i != previous) unawaited(t.controller.freeze());
      }
    }

    onRebuild?.call();
    return previous;
  }

  /// Close the tab at [index], returning it if actually removed.
  BrowserTab? closeTab(int index) {
    if (tabs.isEmpty) return null;

    BrowserTab? removed;
    if (tabs.length <= 1) {
      removed = tabs.removeAt(0);
      activeTabIndex = 0;
    } else {
      removed = tabs.removeAt(index);
      if (activeTabIndex >= tabs.length) {
        activeTabIndex = tabs.length - 1;
      }
    }

    removed.dispose();
    snifferSubscription?.cancel();
    if (tabs.isNotEmpty) {
      snifferSubscription = activeTab.snifferEngine.onMediaChanged.listen((_) {
        onRebuild?.call();
      });
    }
    onRebuild?.call();
    return removed;
  }

  /// Close all tabs.  Disposes each tab, clears the list, and resets
  /// the active index to 0.  The caller should create a new blank tab
  /// after this so the browser is never empty.
  void closeAllTabs() {
    snifferSubscription?.cancel();
    for (final tab in tabs) {
      tab.dispose();
    }
    tabs.clear();
    activeTabIndex = 0;
    fetchedIframeSrcs.clear();
    mediaRebuildTimer?.cancel();
    mediaSaveTimer?.cancel();
    onRebuild?.call();
  }

  /// Remember a closed tab for possible reopening.
  void rememberClosedTab(BrowserTab tab) {
    final url = tab.currentUrl ?? tab.addressController.text.trim();
    if (url.isEmpty || url.startsWith('about:')) return;
    recentlyClosedTabs.removeWhere((snap) => snap.url == url);
    recentlyClosedTabs.insert(
      0,
      ClosedTabSnapshot(url: url, title: tab.title ?? _titleForUrl(url)),
    );
    while (recentlyClosedTabs.length > maxRecentlyClosed) {
      recentlyClosedTabs.removeLast();
    }
  }

  /// Pop the most recently closed tab URL, or null.
  String? reopenLastClosedTab() {
    if (recentlyClosedTabs.isEmpty) return null;
    final snap = recentlyClosedTabs.removeAt(0);
    return snap.url;
  }

  /// Human-readable label for a tab (used in the tab strip).
  static String tabLabel(BrowserTab tab) {
    if (tab.title != null && tab.title!.isNotEmpty) return tab.title!;
    final url = tab.currentUrl ?? tab.addressController.text;
    if (url.isEmpty || url == 'about:blank') return 'New Tab';
    final uri = Uri.tryParse(url);
    if (uri != null && uri.host.isNotEmpty) return uri.host;
    return url.length > 40 ? '${url.substring(0, 40)}…' : url;
  }

  static String _titleForUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri != null && uri.host.isNotEmpty) return uri.host;
    return url.length > 40 ? '${url.substring(0, 40)}…' : url;
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  void dispose() {
    snifferSubscription?.cancel();
    mediaRebuildTimer?.cancel();
    mediaSaveTimer?.cancel();
    for (final tab in tabs) {
      tab.dispose();
    }
    tabs.clear();
  }
}

import 'dart:async';

import 'package:flutter/material.dart';

import '../../premium/pro_features.dart';
import '../models/browser_tab.dart';
import '../models/closed_tab_snapshot.dart';
import '../models/tab_group.dart';
import '../tab_groups/tab_group_palette.dart';

/// Default `isProCallback` — always returns false.
bool _defaultIsPro() => false;

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
  static const int maxTabs = 20;

  /// Maximum tab groups for free users (single-sourced from [ProFeatures]).
  static const int maxFreeTabGroups = ProFeatures.maxFreeTabGroups;

  /// Persistent tab groups, ordered by [TabGroup.sortOrder] ascending.
  /// Tabs reference groups by case-insensitive name through
  /// [BrowserTab.groupName]; the explicit list here stores
  /// group-level metadata (color override, auto-host) that doesn't
  /// belong on every individual tab.
  final List<TabGroup> tabGroups = [];

  /// Subscription to the active tab's media-changed stream.
  StreamSubscription<dynamic>? snifferSubscription;

  /// Timers for throttled media rebuild/save.
  Timer? mediaRebuildTimer;
  Timer? mediaSaveTimer;

  /// Set of iframe source URLs already fetched (used to avoid duplicates).
  final Set<String> fetchedIframeSrcs = {};

  /// Callback invoked after any state change that needs a [State.setState].
  VoidCallback? onRebuild;

  /// Callback that returns whether the user has Pro entitlement.
  /// Used to gate tab group count and auto-host for free users.
  bool Function() isProCallback;

  TabManager({this.isProCallback = _defaultIsPro});

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
    final next = index.clamp(0, tabs.length - 1);
    if (previous == next && snifferSubscription != null) {
      return previous;
    }
    activeTabIndex = next;

    snifferSubscription?.cancel();
    snifferSubscription = activeTab.snifferEngine.onMediaChanged.listen((_) {
      onRebuild?.call();
    });

    if (previous != activeTabIndex && previous >= 0 && previous < tabs.length) {
      final oldActive = tabs[previous];
      oldActive.videoPollTimer?.cancel();
      // Per-WebView render pause only. Do NOT call pauseTimers / freeze here:
      // - pauseTimers is process-global; if it completes after the new tab's
      //   resume, the active page freezes (scrollbar may still move).
      // - freeze() sets visibility:hidden via JS; if thaw races or fails the
      //   user sees a permanent blank/stale surface.
      unawaited(oldActive.controller.suspendTab());
    }

    final newActive = activeTab;
    // Sequential resume so resumeTimers always wins over any prior pause.
    unawaited(_activateTabWebView(newActive));

    onRebuild?.call();
    return previous;
  }

  /// Brings [tab]'s WebView back to a live render + timer state.
  Future<void> _activateTabWebView(BrowserTab tab) async {
    try {
      await tab.controller.resumeWebView();
    } catch (_) {}
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

  // ---------------------------------------------------------------------------
  // Tab groups
  // ---------------------------------------------------------------------------

  /// Look up a [TabGroup] by case-insensitive name. Returns `null` when
  /// no group exists with that name.
  TabGroup? groupByName(String? name) {
    if (name == null) return null;
    final needle = name.trim().toLowerCase();
    if (needle.isEmpty) return null;
    for (final g in tabGroups) {
      if (g.name.toLowerCase() == needle) return g;
    }
    return null;
  }

  /// Visible color for a tab, given an explicit [colorIndex] override
  /// (from [BrowserTab.groupColorIndex]) and the group name. The
  /// override always wins; otherwise the palette derives a stable hue
  /// from the name.
  Color groupColorFor({int? colorIndex, required String? groupName}) {
    return TabGroupPalette.colorFor(
      colorIndex: colorIndex,
      groupName: groupName,
    );
  }

  /// Assign [tab] to a group, optionally with an explicit color-index
  /// override. Creates the group if it doesn't exist. Setting
  /// [groupName] to `null` or empty removes the tab from any group.
  ///
  /// When the move empties a group (no remaining member tabs), the
  /// group is also removed from [tabGroups] to keep the persisted
  /// list tidy.
  bool moveTabToGroup(
    BrowserTab tab, {
    String? groupName,
    int? colorIndex,
    void Function()? onCapExceeded,
  }) {
    final newName = (groupName ?? '').trim();
    if (newName.isEmpty) {
      // Removing from group.
      tab.groupName = null;
      tab.groupColorIndex = null;
      tab.autoGrouped = false;
    } else {
      // If this is a new group, enforce free cap.
      final existingGroup = groupByName(newName);
      final isExistingGroup = existingGroup != null;
      if (!isExistingGroup && !isProCallback()) {
        // Free users limited to maxFreeTabGroups.
        final currentGroupCount = tabGroups.length;
        if (currentGroupCount >= maxFreeTabGroups) {
          onCapExceeded?.call();
          return false;
        }
      }
      tab.groupName = newName;
      tab.groupColorIndex = colorIndex;
      tab.autoGrouped = false;
      _ensureGroupExists(newName, colorIndex: colorIndex);
    }
    _pruneEmptyGroups();
    onRebuild?.call();
    return true;
  }

  /// Reorder the [tabs] list by moving the entry at [oldIndex] to the
  /// position currently occupied by [newIndex]. Indices are
  /// post-removal, matching [ReorderableListView.onReorder]'s contract.
  void reorderTab(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= tabs.length) return;
    final adjusted = newIndex > oldIndex ? newIndex - 1 : newIndex;
    if (adjusted < 0 || adjusted > tabs.length - 1) return;
    if (oldIndex == adjusted) return;
    final tab = tabs.removeAt(oldIndex);
    tabs.insert(adjusted, tab);
    if (activeTabIndex == oldIndex) {
      activeTabIndex = adjusted;
    } else if (activeTabIndex > oldIndex && activeTabIndex <= adjusted) {
      activeTabIndex -= 1;
    } else if (activeTabIndex < oldIndex && activeTabIndex >= adjusted) {
      activeTabIndex += 1;
    }
    if (activeTabIndex < 0) activeTabIndex = 0;
    if (activeTabIndex > tabs.length - 1) activeTabIndex = tabs.length - 1;
    onRebuild?.call();
  }

  /// Rename a group everywhere it is referenced. Returns `true` on
  /// success, `false` if [newName] is empty or already used by another
  /// group.
  bool renameGroup(String oldName, String newName) {
    final trimmedOld = oldName.trim();
    final trimmedNew = newName.trim();
    if (trimmedOld.isEmpty || trimmedNew.isEmpty) return false;
    if (trimmedOld.toLowerCase() == trimmedNew.toLowerCase()) return true;
    // Reject collisions.
    final clash = groupByName(trimmedNew);
    if (clash != null) return false;

    final group = groupByName(trimmedOld);
    if (group != null) {
      final idx = tabGroups.indexOf(group);
      tabGroups[idx] = group.copyWith(name: trimmedNew);
      _resortGroups();
    }
    for (final tab in tabs) {
      if ((tab.groupName ?? '').toLowerCase() == trimmedOld.toLowerCase()) {
        tab.groupName = trimmedNew;
      }
    }
    onRebuild?.call();
    return true;
  }

  /// Apply or clear a group's color-index override.
  void setGroupColor(String name, int? colorIndex) {
    final group = groupByName(name);
    if (group == null) return;
    final idx = tabGroups.indexOf(group);
    final clamped = colorIndex == null
        ? TabGroup.unassignedColorIndex
        : colorIndex.clamp(0, TabGroupPalette.swatchCount - 1);
    tabGroups[idx] = group.copyWith(colorIndex: clamped);
    // Cascade to every member tab so the explicit override wins
    // even after the tab is reloaded.
    for (final tab in tabs) {
      if ((tab.groupName ?? '').toLowerCase() == name.toLowerCase()) {
        tab.groupColorIndex = clamped == TabGroup.unassignedColorIndex
            ? null
            : clamped;
      }
    }
    onRebuild?.call();
  }

  /// Set or clear the [TabGroup.autoHost] for a group. When non-null,
  /// [TabLifecycleController.openNewTab] uses it to auto-add tabs that
  /// share the same URL host.
  void setGroupAutoHost(String name, String? host) {
    if (host != null && !isProCallback()) return; // Pro-gated feature
    final group = groupByName(name);
    if (group == null) return;
    final idx = tabGroups.indexOf(group);
    final normalized =
        (host == null || host.trim().isEmpty) ? null : host.trim().toLowerCase();
    tabGroups[idx] = group.copyWith(autoHost: normalized);
    onRebuild?.call();
  }

  /// Close every member tab in [name]. Returns the list of closed
  /// tab IDs in close order so callers can wire undo / analytics.
  List<String> closeGroup(String name) {
    final needle = name.trim().toLowerCase();
    // Snapshot indices so we close from highest to lowest and don't
    // invalidate as we mutate.
    final indices = <int>[];
    for (var i = 0; i < tabs.length; i++) {
      if ((tabs[i].groupName ?? '').toLowerCase() == needle) {
        indices.add(i);
      }
    }
    final closed = <String>[];
    for (var i = indices.length - 1; i >= 0; i--) {
      final idx = indices[i];
      final removed = closeTab(idx);
      if (removed != null) closed.add(removed.id);
    }
    _pruneEmptyGroups();
    onRebuild?.call();
    return closed;
  }

  /// Remove [name] from [tabGroups] and clear `groupName` on every
  /// member tab — but keep the tabs open.
  void disbandGroup(String name) {
    final needle = name.trim().toLowerCase();
    tabGroups.removeWhere(
      (g) => g.name.toLowerCase() == needle,
    );
    for (final tab in tabs) {
      if ((tab.groupName ?? '').toLowerCase() == needle) {
        tab.groupName = null;
        tab.groupColorIndex = null;
        tab.autoGrouped = false;
      }
    }
    onRebuild?.call();
  }

  /// Member tabs of a group, in current tab-list order.
  List<BrowserTab> tabsInGroup(String name) {
    final needle = name.trim().toLowerCase();
    return tabs
        .where((t) => (t.groupName ?? '').toLowerCase() == needle)
        .toList(growable: false);
  }

  /// Active index inside [tabs] of a tab with [id], or `-1` if not
  /// present. Used by drag-drop dispatch when the dragged tab's index
  /// has shifted between drag start and drop.
  int indexOfTabId(String id) {
    for (var i = 0; i < tabs.length; i++) {
      if (tabs[i].id == id) return i;
    }
    return -1;
  }

  /// Replace the [tabGroups] list with [groups] and re-sort. Used by
  /// the persistence loader.
  void replaceGroups(List<TabGroup> groups) {
    tabGroups
      ..clear()
      ..addAll(groups);
    _resortGroups();
  }

  // -- private helpers --------------------------------------------------------

  void _ensureGroupExists(String name, {int? colorIndex}) {
    if (groupByName(name) != null) {
      // If the caller supplied a color override and the existing
      // group doesn't have one, adopt it (preserves the user's intent
      // when a tab is dragged into a brand-new group name).
      if (colorIndex != null) {
        final g = groupByName(name)!;
        if (!g.hasExplicitColor) {
          final idx = tabGroups.indexOf(g);
          tabGroups[idx] = g.copyWith(colorIndex: colorIndex);
          for (final tab in tabs) {
            if ((tab.groupName ?? '').toLowerCase() == name.toLowerCase()) {
              tab.groupColorIndex = colorIndex;
            }
          }
        }
      }
      return;
    }
    final sortOrder = tabGroups.isEmpty
        ? 0
        : (tabGroups.map((g) => g.sortOrder).reduce((a, b) => a > b ? a : b) +
            1);
    tabGroups.add(
      TabGroup(
        name: name,
        colorIndex: colorIndex ?? TabGroup.unassignedColorIndex,
        sortOrder: sortOrder,
        createdAt: DateTime.now(),
      ),
    );
    _resortGroups();
  }

  /// Drop any group from [tabGroups] whose name is no longer
  /// referenced by any tab.
  void _pruneEmptyGroups() {
    final referenced = <String>{};
    for (final tab in tabs) {
      final n = tab.groupName?.trim();
      if (n != null && n.isNotEmpty) referenced.add(n.toLowerCase());
    }
    tabGroups.removeWhere((g) => !referenced.contains(g.name.toLowerCase()));
  }

  void _resortGroups() {
    tabGroups.sort((a, b) {
      final c = a.sortOrder.compareTo(b.sortOrder);
      if (c != 0) return c;
      return a.createdAt.compareTo(b.createdAt);
    });
  }
}

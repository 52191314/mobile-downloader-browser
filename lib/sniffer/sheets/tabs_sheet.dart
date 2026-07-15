import 'package:flutter/material.dart';

import '../models/browser_tab.dart';
import '../../theme/aurora_palette.dart';

/// Shows the bottom sheet that lists all open browser tabs grouped by
/// their `groupName`, with controls to add a new tab, switch to an
/// existing tab, close a tab, or manage the group assignment for a
/// specific tab.
///
/// Standalone library — all state-mutating side effects are delegated
/// via callbacks so this function can be unit-tested in isolation.
void showTabsSheet(
  BuildContext context, {
  required List<BrowserTab> tabs,
  required int activeTabIndex,
  required void Function(int index) onCloseTab,
  required void Function() onReopenLastClosedTab,
  required void Function({String? url, bool? switchToTab}) onOpenNewTab,
  required void Function(int index) onSwitchToActiveTab,
  required String Function(BrowserTab) getTabLabel,
  required VoidCallback onCloseAllTabs,
  required Set<String> builtWebViewTabIds,
}) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AuroraPalette.of(context).surfaceField,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setTabsState) {
          final groupNames = tabs
              .map((t) => t.groupName)
              .where((n) => n != null && n.trim().isNotEmpty)
              .cast<String>()
              .toSet()
              .toList();

          final ungroupedTabs = tabs
              .where(
                (t) => t.groupName == null || t.groupName!.trim().isEmpty,
              )
              .toList();

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Tabs (${tabs.length})',
                        style: TextStyle(
                          color: ctx.ac.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.layers_clear_outlined,
                          color: ctx.ac.textSecondary,
                        ),
                        tooltip: 'Close all tabs',
                        onPressed: () {
                          onCloseAllTabs();
                          Navigator.pop(ctx);
                        },
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.add,
                          color: ctx.ac.accentFrost,
                        ),
                        onPressed: () {
                          onOpenNewTab();
                          Navigator.pop(ctx);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView(
                      children: [
                        // 1. Grouped Tabs (Collapsible Sections)
                        for (final groupName in groupNames) ...[
                          Theme(
                            data: Theme.of(
                              context,
                            ).copyWith(dividerColor: Colors.transparent),
                            child: ExpansionTile(
                              key: PageStorageKey<String>(
                                'tab_group_$groupName',
                              ),
                              title: Text(
                                '$groupName (${tabs.where((t) => t.groupName == groupName).length})',
                                style: TextStyle(
                                  color: ctx.ac.accentFrost,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                              iconColor: ctx.ac.accentFrost,
                              collapsedIconColor: ctx.ac.textSecondary,
                              childrenPadding: const EdgeInsets.only(left: 8),
                              children: [
                                for (final tab in tabs.where(
                                  (t) => t.groupName == groupName,
                                ))
                                  buildTabCard(
                                    ctx,
                                    tab,
                                    tabs.indexOf(tab),
                                    setTabsState,
                                    tabs: tabs,
                                    activeTabIndex: activeTabIndex,
                                    onCloseTab: onCloseTab,
                                    onSwitchToActiveTab: onSwitchToActiveTab,
                                    getTabLabel: getTabLabel,
                                    builtWebViewTabIds: builtWebViewTabIds,
                                  ),
                              ],
                            ),
                          ),
                        ],

                        // 2. Ungrouped Tabs (Direct List at the Bottom)
                        if (ungroupedTabs.isNotEmpty) ...[
                          if (groupNames.isNotEmpty) ...[
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              child: Text(
                                'Ungrouped Tabs',
                                style: TextStyle(
                                  color: ctx.ac.textSecondary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                          for (final tab in ungroupedTabs)
                            buildTabCard(
                              ctx,
                              tab,
                              tabs.indexOf(tab),
                              setTabsState,
                              tabs: tabs,
                              activeTabIndex: activeTabIndex,
                              onCloseTab: onCloseTab,
                              onSwitchToActiveTab: onSwitchToActiveTab,
                              getTabLabel: getTabLabel,
                              builtWebViewTabIds: builtWebViewTabIds,
                            ),
                        ],
                      ],
                    ),
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

/// Builds a single tab card row used inside the tab switcher sheet.
/// Standalone library — all state-mutating side effects are delegated
/// via callbacks so this function can be unit-tested in isolation.
Widget buildTabCard(
  BuildContext ctx,
  BrowserTab tab,
  int originalIndex,
  void Function(void Function()) setTabsState, {
  required List<BrowserTab> tabs,
  required int activeTabIndex,
  required void Function(int index) onCloseTab,
  required void Function(int index) onSwitchToActiveTab,
  required String Function(BrowserTab) getTabLabel,
  required Set<String> builtWebViewTabIds,
}) {
  final isActive = originalIndex == activeTabIndex;
  return Card(
    color: isActive ? ctx.ac.surfaceElevated : ctx.ac.surfacePanel,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
      side: BorderSide(
        color: isActive ? ctx.ac.accentFrost : Colors.transparent,
        width: 1.5,
      ),
    ),
    child: ListTile(
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              getTabLabel(tab),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: ctx.ac.textPrimary,
                fontWeight: isActive ? FontWeight.bold : null,
              ),
            ),
          ),
          if (!isActive && !builtWebViewTabIds.contains(tab.id)) ...[
            const SizedBox(width: 6),
            Icon(
              Icons.snooze_outlined,
              size: 14,
              color: ctx.ac.textSecondary,
            ),
          ],
        ],
      ),
      subtitle: Text(
        tab.addressController.text.trim().isEmpty
            ? 'Search or enter URL'
            : tab.addressController.text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: ctx.ac.textSecondary),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(
              Icons.more_vert,
              size: 18,
              color: ctx.ac.textSecondary,
            ),
            onPressed: () {
              showTabGroupMenu(
                ctx,
                tabs: tabs,
                tab: tab,
                setTabsState: setTabsState,
                onSetState: () {},
                onShowCreateGroupDialog: (innerCtx, innerTab, innerSetState) =>
                    showCreateTabGroupDialog(
                  innerCtx,
                  tab: innerTab,
                  setTabsState: innerSetState,
                  onSetState: () {},
                ),
                getTabLabel: getTabLabel,
              );
            },
          ),
          if (tabs.length > 1)
            IconButton(
              icon: Icon(
                Icons.close,
                size: 18,
                color: ctx.ac.textSecondary,
              ),
              onPressed: () {
                setTabsState(() {
                  onCloseTab(originalIndex);
                });
              },
            ),
        ],
      ),
      onTap: () {
        onSwitchToActiveTab(originalIndex);
        Navigator.pop(ctx);
      },
    ),
  );
}

/// Shows the bottom sheet that lets the user remove [tab] from its
/// current group, create a new group for it, or move it to an
/// existing group.
///
/// Standalone library — all state-mutating side effects are delegated
/// via callbacks so this function can be unit-tested in isolation.
void showTabGroupMenu(
  BuildContext context, {
  required List<BrowserTab> tabs,
  required BrowserTab tab,
  required void Function(void Function()) setTabsState,
  required VoidCallback onSetState,
  required void Function(
    BuildContext ctx,
    BrowserTab tab,
    void Function(void Function()) setTabsState,
  )
      onShowCreateGroupDialog,
  required String Function(BrowserTab) getTabLabel,
}) {
  final existingGroups = tabs
      .map((t) => t.groupName)
      .where((n) => n != null && n.trim().isNotEmpty)
      .cast<String>()
      .toSet()
      .toList();

  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (menuCtx) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
              child: Text(
                'Move or regroup',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: menuCtx.ac.textPrimary,
                ),
              ),
            ),
            if (tab.groupName != null)
              ListTile(
                leading: const Icon(Icons.link_off, color: Colors.redAccent),
                title: Text(
                  'Remove from this group',
                  style: TextStyle(color: menuCtx.ac.textPrimary),
                ),
                onTap: () {
                  setTabsState(() {
                    tab.groupName = null;
                  });
                  onSetState();
                  Navigator.pop(menuCtx);
                },
              ),
            ListTile(
              leading: Icon(
                Icons.create_new_folder_outlined,
                color: menuCtx.ac.accentFrost,
              ),
                title: Text(
                  'New group...',
                  style: TextStyle(color: menuCtx.ac.textPrimary),
                ),
              onTap: () {
                Navigator.pop(menuCtx);
                onShowCreateGroupDialog(context, tab, setTabsState);
              },
            ),
            if (existingGroups.isNotEmpty) ...[
              const Divider(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text(
                  'Move to existing group:',
                  style: TextStyle(
                    fontSize: 12,
                    color: menuCtx.ac.textSecondary,
                  ),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: existingGroups.length,
                  itemBuilder: (context, index) {
                    final group = existingGroups[index];
                    if (group == tab.groupName)
                      return const SizedBox.shrink();
                    return ListTile(
                      leading: Icon(
                        Icons.folder_open,
                        color: menuCtx.ac.accentFrost,
                      ),
                      title: Text(
                        group,
                        style: TextStyle(color: menuCtx.ac.textPrimary),
                      ),
                      onTap: () {
                        setTabsState(() {
                          tab.groupName = group;
                        });
                        onSetState();
                        Navigator.pop(menuCtx);
                      },
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      );
    },
  );
}

/// Shows a dialog that asks the user for a new group name and assigns
/// it to [tab] when confirmed.
///
/// Standalone library — all state-mutating side effects are delegated
/// via callbacks so this function can be unit-tested in isolation.
void showCreateTabGroupDialog(
  BuildContext context, {
  required BrowserTab tab,
  required void Function(void Function()) setTabsState,
  required VoidCallback onSetState,
}) {
  final controller = TextEditingController();
  showDialog<void>(
    context: context,
    builder: (dialogCtx) {
      return AlertDialog(
        backgroundColor: dialogCtx.ac.surfacePanel,
        title: Text(
          'New group',
          style: TextStyle(color: dialogCtx.ac.textPrimary),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: dialogCtx.ac.textPrimary),
          decoration: InputDecoration(
            hintText: 'Enter group name (e.g. Work, Shopping)',
            hintStyle: TextStyle(color: dialogCtx.ac.textSecondary),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: dialogCtx.ac.borderStrong),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: dialogCtx.ac.accentFrost),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: Text(
              'Cancel',
              style: TextStyle(color: dialogCtx.ac.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                setTabsState(() {
                  tab.groupName = name;
                });
                onSetState();
              }
              Navigator.pop(dialogCtx);
            },
            child: Text(
              'Create',
              style: TextStyle(color: dialogCtx.ac.accentFrost),
            ),
          ),
        ],
      );
    },
  );
}

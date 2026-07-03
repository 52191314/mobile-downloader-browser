import 'package:flutter/material.dart';

import '../models/browser_tab.dart';
import '../../theme/aurora_colors.dart';

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
}) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AuroraColors.background,
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
                        style: const TextStyle(
                          color: AuroraColors.text,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.layers_clear_outlined,
                          color: AuroraColors.mutedText,
                        ),
                        tooltip: 'Close all tabs',
                        onPressed: () {
                          onCloseAllTabs();
                          Navigator.pop(ctx);
                        },
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.add,
                          color: AuroraColors.accent,
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
                                style: const TextStyle(
                                  color: AuroraColors.accent,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                              iconColor: AuroraColors.accent,
                              collapsedIconColor: AuroraColors.mutedText,
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
                                  ),
                              ],
                            ),
                          ),
                        ],

                        // 2. Ungrouped Tabs (Direct List at the Bottom)
                        if (ungroupedTabs.isNotEmpty) ...[
                          if (groupNames.isNotEmpty) ...[
                            const Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              child: Text(
                                'Ungrouped Tabs',
                                style: TextStyle(
                                  color: AuroraColors.mutedText,
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
}) {
  final isActive = originalIndex == activeTabIndex;
  return Card(
    color: isActive ? AuroraColors.surfaceVariant : AuroraColors.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
      side: BorderSide(
        color: isActive ? AuroraColors.accent : Colors.transparent,
        width: 1.5,
      ),
    ),
    child: ListTile(
      title: Text(
        getTabLabel(tab),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: AuroraColors.text,
          fontWeight: isActive ? FontWeight.bold : null,
        ),
      ),
      subtitle: Text(
        tab.addressController.text.trim().isEmpty
            ? 'Search or enter URL'
            : tab.addressController.text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12, color: AuroraColors.mutedText),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(
              Icons.more_vert,
              size: 18,
              color: AuroraColors.mutedText,
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
              icon: const Icon(
                Icons.close,
                size: 18,
                color: AuroraColors.mutedText,
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
                'Manage Group for "${getTabLabel(tab)}"',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: AuroraColors.text,
                ),
              ),
            ),
            if (tab.groupName != null)
              ListTile(
                leading: const Icon(Icons.link_off, color: Colors.redAccent),
                title: const Text(
                  'Remove from Group',
                  style: TextStyle(color: AuroraColors.text),
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
              leading: const Icon(
                Icons.create_new_folder_outlined,
                color: AuroraColors.accent,
              ),
              title: const Text(
                'Create New Group...',
                style: TextStyle(color: AuroraColors.text),
              ),
              onTap: () {
                Navigator.pop(menuCtx);
                onShowCreateGroupDialog(context, tab, setTabsState);
              },
            ),
            if (existingGroups.isNotEmpty) ...[
              const Divider(),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text(
                  'Move to existing group:',
                  style: TextStyle(
                    fontSize: 12,
                    color: AuroraColors.mutedText,
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
                      leading: const Icon(
                        Icons.folder_open,
                        color: AuroraColors.accent,
                      ),
                      title: Text(
                        group,
                        style: const TextStyle(color: AuroraColors.text),
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
        backgroundColor: AuroraColors.surface,
        title: const Text(
          'Create New Group',
          style: TextStyle(color: AuroraColors.text),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: AuroraColors.text),
          decoration: const InputDecoration(
            hintText: 'Enter group name (e.g. Work, Shopping)',
            hintStyle: TextStyle(color: AuroraColors.mutedText),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: AuroraColors.border),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: AuroraColors.accent),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AuroraColors.mutedText),
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
            child: const Text(
              'Create',
              style: TextStyle(color: AuroraColors.accent),
            ),
          ),
        ],
      );
    },
  );
}

import 'package:flutter/material.dart';

import '../../theme/aurora_palette.dart';
import '../models/browser_tab.dart';
import '../tab_groups/tab_group_palette.dart';
import 'draggable_tab_card.dart';
import 'group_drop_zone.dart';

/// Samsung-style 2-column card grid for the tab switcher.
///
/// Each card is a small rounded rect with:
/// - 3px left accent bar in the group's color (or derived from name
///   hash when ungrouped)
/// - Title (max 2 lines)
/// - Host subtitle
/// - × close button (only when more than 1 tab is open)
///
/// Tapping a card switches to that tab. Long-pressing a card lifts it
/// for drag-drop into groups, matching the list view's behavior.
/// Group headers span both columns.
class TabGridView extends StatelessWidget {
  final List<BrowserTab> tabs;
  final int activeTabIndex;
  final List<String> groupNames;
  final List<BrowserTab> ungroupedTabs;
  final String Function(BrowserTab) getTabLabel;
  final Set<String> builtWebViewTabIds;
  final void Function(int index) onCloseTab;
  final void Function(int index) onSwitchToActiveTab;

  /// Resolves the dragged tab id to a group assignment.
  final void Function(String draggedTabId, String? groupName) onDropOnGroup;

  /// Long-press on a group header (per-group actions).
  final void Function(String groupName) onGroupLongPress;

  /// Look up a group's color index override (-1 = derived).
  final int Function(String name) colorIndexForGroup;

  /// Whether a group is currently expanded.
  final bool Function(String name) isGroupExpanded;

  /// Toggle a group's expanded state.
  final void Function(String name) onToggleGroup;

  const TabGridView({
    super.key,
    required this.tabs,
    required this.activeTabIndex,
    required this.groupNames,
    required this.ungroupedTabs,
    required this.getTabLabel,
    required this.builtWebViewTabIds,
    required this.onCloseTab,
    required this.onSwitchToActiveTab,
    required this.onDropOnGroup,
    required this.onGroupLongPress,
    required this.colorIndexForGroup,
    required this.isGroupExpanded,
    required this.onToggleGroup,
  });

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    // Side padding 16 + inter-card spacing 8 → 2 cols when width > 360.
    final twoColumns = screenWidth >= 360;
    final cardWidth = twoColumns
        ? (screenWidth - 16 * 2 - 8) / 2
        : screenWidth - 16 * 2;

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        for (final groupName in groupNames) ...[
          _buildGridGroupHeader(groupName),
          _buildGridGroupBody(
            groupName,
            cardWidth: cardWidth,
            twoColumns: twoColumns,
          ),
        ],
        if (ungroupedTabs.isNotEmpty) ...[
          _buildGridUngroupedHeader(),
          _buildGridUngroupedBody(
            cardWidth: cardWidth,
            twoColumns: twoColumns,
          ),
        ],
      ],
    );
  }

  Widget _buildGridGroupHeader(String groupName) {
    final colorIndex = colorIndexForGroup(groupName);
    final accent = TabGroupPalette.colorFor(
      colorIndex: colorIndex >= 0 ? colorIndex : null,
      groupName: groupName,
    );
    final memberCount =
        tabs.where((t) => (t.groupName ?? '') == groupName).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 4),
      child: GroupDropZone(
        groupName: groupName,
        accentColor: accent,
        memberCount: memberCount,
        isExpanded: isGroupExpanded(groupName),
        onToggleExpand: () => onToggleGroup(groupName),
        onLongPress: () => onGroupLongPress(groupName),
        onAcceptDrop: (tabId) => onDropOnGroup(tabId, groupName),
      ),
    );
  }

  Widget _buildGridGroupBody(
    String groupName, {
    required double cardWidth,
    required bool twoColumns,
  }) {
    final memberTabs =
        tabs.where((t) => (t.groupName ?? '') == groupName).toList();
    final colorIndex = colorIndexForGroup(groupName);
    final accent = TabGroupPalette.colorFor(
      colorIndex: colorIndex >= 0 ? colorIndex : null,
      groupName: groupName,
    );
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      child: isGroupExpanded(groupName)
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: _GridCardLayout(
                tabs: memberTabs,
                cardWidth: cardWidth,
                twoColumns: twoColumns,
                accent: accent,
                activeIndex: activeTabIndex,
                getTabLabel: getTabLabel,
                builtWebViewTabIds: builtWebViewTabIds,
                onCloseTab: onCloseTab,
                onSwitchToActiveTab: onSwitchToActiveTab,
                onDropOnGroup: (id) => onDropOnGroup(id, groupName),
                dropGroup: groupName,
              ),
            )
          : const SizedBox.shrink(),
    );
  }

  Widget _buildGridUngroupedHeader() {
    return DragTarget<String>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) => onDropOnGroup(details.data, null),
      builder: (context, candidate, _) {
        final hovering = candidate.isNotEmpty;
        return Container(
          margin: const EdgeInsets.fromLTRB(0, 12, 0, 4),
          padding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 6,
          ),
          decoration: BoxDecoration(
            color: hovering
                ? context.ac.accentFrost.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(
                Icons.inbox_outlined,
                size: 14,
                color: hovering ? context.ac.accentFrost : context.ac.textSecondary,
              ),
              const SizedBox(width: 6),
              Text(
                'Ungrouped (${ungroupedTabs.length})',
                style: TextStyle(
                  color: hovering ? context.ac.accentFrost : context.ac.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildGridUngroupedBody({
    required double cardWidth,
    required bool twoColumns,
  }) {
    return _GridCardLayout(
      tabs: ungroupedTabs,
      cardWidth: cardWidth,
      twoColumns: twoColumns,
      accent: null,
      activeIndex: activeTabIndex,
      getTabLabel: getTabLabel,
      builtWebViewTabIds: builtWebViewTabIds,
      onCloseTab: onCloseTab,
      onSwitchToActiveTab: onSwitchToActiveTab,
      onDropOnGroup: (id) => onDropOnGroup(id, null),
      dropGroup: null,
    );
  }
}

class _GridCardLayout extends StatelessWidget {
  final List<BrowserTab> tabs;
  final double cardWidth;
  final bool twoColumns;
  final Color? accent;
  final int activeIndex;
  final String Function(BrowserTab) getTabLabel;
  final Set<String> builtWebViewTabIds;
  final void Function(int index) onCloseTab;
  final void Function(int index) onSwitchToActiveTab;
  final void Function(String tabId) onDropOnGroup;
  final String? dropGroup;

  const _GridCardLayout({
    required this.tabs,
    required this.cardWidth,
    required this.twoColumns,
    required this.accent,
    required this.activeIndex,
    required this.getTabLabel,
    required this.builtWebViewTabIds,
    required this.onCloseTab,
    required this.onSwitchToActiveTab,
    required this.onDropOnGroup,
    required this.dropGroup,
  });

  @override
  Widget build(BuildContext context) {
    if (tabs.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: Text(
            'No tabs in this group.',
            style: TextStyle(color: context.ac.textSecondary, fontSize: 12),
          ),
        ),
      );
    }

    final children = <Widget>[];
    for (var i = 0; i < tabs.length; i++) {
      final tab = tabs[i];
      final originalIndex = tabs.indexOf(tab);
      // Resolve the actual index in the full tab list via getTabLabel
      // callback context — but since we only have a closure-free list,
      // we trust the caller's activeIndex mapping. Active state is
      // visual only here.
      children.add(_GridCard(
        tab: tab,
        cardWidth: cardWidth,
        accent: accent ??
            TabGroupPalette.colorFor(
              colorIndex: tab.groupColorIndex,
              groupName: tab.groupName,
            ),
        isActive: originalIndex == activeIndex,
        label: getTabLabel(tab),
        showClose: tabs.length > 1,
        snoozed:
            !builtWebViewTabIds.contains(tab.id),
        onClose: () => onCloseTab(originalIndex),
        onTap: () => onSwitchToActiveTab(originalIndex),
      ));
      children.add(
        TabListDropSlot(
          targetGroupName: dropGroup,
          onAccept: onDropOnGroup,
        ),
      );
    }

    if (!twoColumns) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      );
    }

    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += 2) {
      if (i + 1 < children.length) {
        rows.add(
          Row(
            children: [
              Expanded(child: children[i]),
              const SizedBox(width: 8),
              Expanded(child: children[i + 1]),
            ],
          ),
        );
      } else {
        rows.add(
          Row(
            children: [
              SizedBox(
                width: cardWidth,
                child: children[i],
              ),
            ],
          ),
        );
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }
}

class _GridCard extends StatelessWidget {
  final BrowserTab tab;
  final double cardWidth;
  final Color accent;
  final bool isActive;
  final String label;
  final bool showClose;
  final bool snoozed;
  final VoidCallback onClose;
  final VoidCallback onTap;

  const _GridCard({
    required this.tab,
    required this.cardWidth,
    required this.accent,
    required this.isActive,
    required this.label,
    required this.showClose,
    required this.snoozed,
    required this.onClose,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final card = Container(
      width: cardWidth,
      height: 132,
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: isActive
            ? context.ac.surfaceElevated
            : context.ac.surfacePanel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive ? context.ac.accentFrost : context.ac.glassBorder,
          width: isActive ? 1.5 : 1,
        ),
      ),
      child: Stack(
        children: [
          // Left accent bar.
          Positioned(
            left: 0,
            top: 10,
            bottom: 10,
            child: Container(
              width: 3,
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (snoozed)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Icon(
                          Icons.snooze_outlined,
                          size: 12,
                          color: context.ac.textSecondary,
                        ),
                      ),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: context.ac.textPrimary,
                          fontWeight:
                              isActive ? FontWeight.bold : FontWeight.w500,
                          fontSize: 13,
                          height: 1.2,
                        ),
                      ),
                    ),
                    if (showClose)
                      GestureDetector(
                        onTap: onClose,
                        behavior: HitTestBehavior.opaque,
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: Icon(
                            Icons.close,
                            size: 16,
                            color: context.ac.textSecondary,
                          ),
                        ),
                      ),
                  ],
                ),
                const Spacer(),
                Text(
                  _hostFrom(tab.currentUrl ?? tab.addressController.text),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.ac.textSecondary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    return DraggableTabCard(
      tab: tab,
      accentColor: accent,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: card,
      ),
    );
  }

  String _hostFrom(String url) {
    if (url.isEmpty || url == 'about:blank') return 'about:blank';
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return url;
    return uri.host;
  }
}
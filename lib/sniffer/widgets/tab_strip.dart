import 'package:flutter/material.dart';

import '../../theme/aurora_palette.dart';
import '../controllers/tab_manager.dart';
import '../models/browser_tab.dart';

/// Compact horizontal tab strip shown at the top of the bottom chrome.
/// Each tab renders as a pill with its title and a close button.
///
/// Extracted from `_SnifferScreenState._buildTabStrip`.
class TabStrip extends StatelessWidget {
  final List<BrowserTab> tabs;
  final int activeIndex;
  final bool isPrivateMode;
  final void Function(int index) onSwitch;
  final void Function(int index) onClose;
  final VoidCallback onNewTab;

  const TabStrip({
    super.key,
    required this.tabs,
    required this.activeIndex,
    this.isPrivateMode = false,
    required this.onSwitch,
    required this.onClose,
    required this.onNewTab,
  });

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final activeColor = isPrivateMode ? ac.accentPurple : ac.accentFrost;
    return Container(
      key: const Key('browser_tab_strip'),
      height: 34,
      color: ac.dockSurface,
      child: Row(
        children: [
          if (isPrivateMode)
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
              itemCount: tabs.length,
              itemBuilder: (_, i) {
                final tab = tabs[i];
                final isActive = i == activeIndex;
                return GestureDetector(
                  onTap: () => onSwitch(i),
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
                              color: isActive ? activeColor : ac.textSecondary,
                            ),
                          ),
                        ),
                        if (tabs.length > 1)
                          GestureDetector(
                            key: Key('browser_tab_close_$i'),
                            onTap: () => onClose(i),
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
            onPressed: onNewTab,
            tooltip: 'New tab',
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/aurora_palette.dart';

/// Slim shell bar on Queue only: Queue | Browser (Settings are full-screen routes).
class AuroraDock extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTabSelected;
  final ValueNotifier<int> sniffedBadgeCountNotifier;
  final GlobalKey? queueKey;
  final GlobalKey? browserKey;

  const AuroraDock({
    super.key,
    required this.currentIndex,
    required this.onTabSelected,
    required this.sniffedBadgeCountNotifier,
    this.queueKey,
    this.browserKey,
  });

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final isLight = context.isLight;
    final l = AppLocalizations.of(context);

    return Material(
      color: ac.dockSurface,
      elevation: isLight ? 0 : 6,
      shadowColor: Colors.black.withValues(alpha: 0.35),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: ac.glassBorder, width: 1),
          ),
        ),
        child: SafeArea(
          top: false,
          child: ValueListenableBuilder<int>(
            valueListenable: sniffedBadgeCountNotifier,
            builder: (context, badgeCount, _) {
              return SizedBox(
                height: 56,
                child: Row(
                  children: [
                    _NavItem(
                      key: queueKey ?? const Key('dock_tab_queue'),
                      icon: Icons.download_outlined,
                      selectedIcon: Icons.download_rounded,
                      label: l?.tabQueue ?? 'Queue',
                      selected: currentIndex == 0,
                      onTap: () => onTabSelected(0),
                    ),
                    _NavItem(
                      key: browserKey ?? const Key('dock_tab_browser'),
                      icon: Icons.language_outlined,
                      selectedIcon: Icons.language_rounded,
                      label: l?.tabBrowser ?? 'Browser',
                      selected: currentIndex == 1,
                      badgeCount: badgeCount,
                      onTap: () => onTabSelected(1),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final int badgeCount;
  final VoidCallback onTap;

  const _NavItem({
    super.key,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    this.badgeCount = 0,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final color = selected ? ac.accentFrost : ac.textSecondary;
    Widget iconWidget = Icon(
      selected ? selectedIcon : icon,
      size: 24,
      color: color,
    );
    if (badgeCount > 0) {
      iconWidget = Badge(
        label: Text(
          badgeCount > 99 ? '99+' : '$badgeCount',
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 10,
            fontWeight: FontWeight.bold,
            color: ac.surfaceField,
          ),
        ),
        backgroundColor: ac.accentAmber,
        child: iconWidget,
      );
    }

    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            iconWidget,
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 11,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

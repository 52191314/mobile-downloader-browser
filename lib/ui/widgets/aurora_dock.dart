import 'package:flutter/material.dart';

import '../../theme/aurora_colors.dart';

/// Floating pill-shaped navigation dock with spring animation.
///
/// Three tab icons + a central FAB for the global "Add" action.
/// Active tab scales to 1.1× with a teal glow; inactive icons are
/// rendered at 40% opacity.
class AuroraDock extends StatefulWidget {
  final int currentIndex;
  final ValueChanged<int> onTabSelected;
  final VoidCallback onAddPressed;
  final int sniffedBadgeCount;

  const AuroraDock({
    super.key,
    required this.currentIndex,
    required this.onTabSelected,
    required this.onAddPressed,
    this.sniffedBadgeCount = 0,
  });

  @override
  State<AuroraDock> createState() => _AuroraDockState();
}

class _AuroraDockState extends State<AuroraDock>
    with SingleTickerProviderStateMixin {
  late final AnimationController _springController;
  int _previousIndex = 0;

  @override
  void initState() {
    super.initState();
    _springController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _previousIndex = widget.currentIndex;
  }

  @override
  void didUpdateWidget(covariant AuroraDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex) {
      _previousIndex = oldWidget.currentIndex;
      _springController.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _springController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const tabSize = 44.0;
    const dockHeight = 56.0;

    return Container(
      height: dockHeight,
      alignment: Alignment.topCenter,
      child: GestureDetector(
        onHorizontalDragEnd: (details) {
          // Swipe left → next tab, swipe right → previous tab
          if (details.primaryVelocity != null) {
            final newIndex = details.primaryVelocity! < 0
                ? (widget.currentIndex + 1).clamp(0, 2)
                : (widget.currentIndex - 1).clamp(0, 2);
            if (newIndex != widget.currentIndex) {
              widget.onTabSelected(newIndex);
            }
          }
        },
        child: Container(
          height: tabSize,
          constraints: const BoxConstraints(maxWidth: 280),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: AuroraColors.dockSurface,
            borderRadius: BorderRadius.circular(tabSize / 2),
            border: Border.all(
              color: widget.sniffedBadgeCount > 0
                  ? AuroraColors.accent.withValues(alpha: 0.4)
                  : AuroraColors.glassBorder,
            ),
            boxShadow: widget.sniffedBadgeCount > 0
                ? [
                    BoxShadow(
                      color: AuroraColors.accent.withValues(alpha: 0.15),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _DockTab(
              key: const Key('dock_tab_queue'),
              icon: Icons.download_rounded,
              label: 'Queue',
              isActive: widget.currentIndex == 0,
              springValue: widget.currentIndex == 0
                  ? _springController
                  : null,
              onTap: () => widget.onTabSelected(0),
            ),
            const SizedBox(width: 4),
            _DockFab(
              key: const Key('dock_fab_add'),
              onTap: widget.onAddPressed,
              badgeCount: widget.sniffedBadgeCount,
            ),
            const SizedBox(width: 4),
            _DockTab(
              key: const Key('dock_tab_browser'),
              icon: Icons.language_rounded,
              label: 'Browser',
              isActive: widget.currentIndex == 1,
              springValue: widget.currentIndex == 1
                  ? _springController
                  : null,
              onTap: () => widget.onTabSelected(1),
            ),
            const SizedBox(width: 4),
            _DockTab(
              key: const Key('dock_tab_settings'),
              icon: Icons.tune_rounded,
              label: 'Settings',
              isActive: widget.currentIndex == 2,
              springValue: widget.currentIndex == 2
                  ? _springController
                  : null,
              onTap: () => widget.onTabSelected(2),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

class _DockTab extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final Animation<double>? springValue;
  final VoidCallback onTap;

  const _DockTab({
    super.key,
    required this.icon,
    required this.label,
    required this.isActive,
    this.springValue,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scale = isActive
        ? (springValue != null
            ? CurvedAnimation(
                parent: springValue!,
                curve: Curves.elasticOut,
              ).drive(Tween(begin: 1.0, end: 1.1))
            : const AlwaysStoppedAnimation(1.1))
        : const AlwaysStoppedAnimation(1.0);

    return AnimatedBuilder(
      animation: scale,
      builder: (context, _) {
        return Transform.scale(
          scale: scale.value,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(24),
              onTap: onTap,
              child: Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                child: Icon(
                  icon,
                  size: 20,
                  color: isActive
                      ? AuroraColors.accent
                      : AuroraColors.mutedText.withValues(alpha: 0.4),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DockFab extends StatelessWidget {
  final VoidCallback onTap;
  final int badgeCount;

  const _DockFab({
    super.key,
    required this.onTap,
    required this.badgeCount,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Material(
            elevation: 4,
            shape: const CircleBorder(),
            color: AuroraColors.accent,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
                child: Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: Icon(
                    badgeCount > 0
                        ? Icons.radar
                        : Icons.add,
                    key: ValueKey(
                        badgeCount > 0 ? 'catch' : 'add'),
                    size: 22,
                    color: AuroraColors.background,
                  ),
                ),
              ),
            ),
          ),
          if (badgeCount > 0)
            Positioned(
              right: -2,
              top: -2,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(
                  color: AuroraColors.accentAmber,
                  shape: BoxShape.circle,
                ),
                constraints: const BoxConstraints(
                  minWidth: 20,
                  minHeight: 20,
                ),
                child: Text(
                  '$badgeCount',
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: AuroraColors.background,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../theme/aurora_palette.dart';

/// Floating pill-shaped navigation dock with spring animation.
///
/// Three tab icons + a central FAB for the global "Add" action.
/// Active tab scales to 1.1× with a teal glow; inactive icons are
/// rendered at 40% opacity.
class AuroraDock extends StatefulWidget {
  final int currentIndex;
  final ValueChanged<int> onTabSelected;
  final VoidCallback onAddPressed;
  final ValueNotifier<int> sniffedBadgeCountNotifier;

  const AuroraDock({
    super.key,
    required this.currentIndex,
    required this.onTabSelected,
    required this.onAddPressed,
    required this.sniffedBadgeCountNotifier,
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
      _springController.animateWith(
        SpringSimulation(
          const SpringDescription(mass: 1, stiffness: 300, damping: 15),
          0, // from
          1, // to
          0, // initial velocity
        ),
      );
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
    final ac = context.ac;
    final isLight = context.isLight;

    return Container(
      height: dockHeight,
      alignment: Alignment.topCenter,
      child: GestureDetector(
        onHorizontalDragEnd: (details) {
          if (details.primaryVelocity != null) {
            final newIndex = details.primaryVelocity! < 0
                ? (widget.currentIndex + 1).clamp(0, 2)
                : (widget.currentIndex - 1).clamp(0, 2);
            if (newIndex != widget.currentIndex) {
              widget.onTabSelected(newIndex);
            }
          }
        },
        child: ValueListenableBuilder<int>(
          valueListenable: widget.sniffedBadgeCountNotifier,
          builder: (context, badgeCount, _) {
            return Container(
              height: tabSize,
              constraints: const BoxConstraints(maxWidth: 280),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: ac.dockSurface,
                borderRadius: BorderRadius.circular(tabSize / 2),
                border: Border.all(
                  color: badgeCount > 0
                      ? ac.accentFrost.withValues(alpha: 0.4)
                      : ac.glassBorder,
                ),
                // Hairline + faint accent glow — no Material shadow in light
                // mode (the frost-line hairline carries separation).
                boxShadow: badgeCount > 0
                    ? [
                        BoxShadow(
                          color: ac.accentFrost.withValues(alpha: isLight ? 0.10 : 0.15),
                          blurRadius: isLight ? 6 : 8,
                          spreadRadius: 1,
                        ),
                      ]
                    : (isLight
                        ? null
                        : [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.35),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ]),
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
                    badgeCount: badgeCount,
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
            );
          },
        ),
      ),
    );
  }
}

class _DockTab extends StatelessWidget {
  static const double tabSize = 44.0;

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
            ? springValue!.drive(Tween(begin: 1.0, end: 1.1))
            : const AlwaysStoppedAnimation(1.1))
        : const AlwaysStoppedAnimation(1.0);

    return AnimatedBuilder(
      animation: scale,
      builder: (context, _) {
        return Semantics(
          label: label,
          button: true,
          selected: isActive,
          child: Transform.scale(
            scale: scale.value,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => onTap(),
                child: Container(
                  width: tabSize,
                  height: tabSize,
                  alignment: Alignment.center,
                  child: Icon(
                    icon,
                    size: 20,
                    color: isActive
                        ? context.ac.accentFrost
                        : context.ac.textSecondary.withValues(alpha: 0.5),
                  ),
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
    final ac = context.ac;
    return SizedBox(
      width: 44,
      height: 44,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Material(
            // Restraint: drop elevation in light mode. The frost-line hairline
            // around the dock carries separation; a 4dp shadow on white feels
            // generic.
            elevation: context.isLight ? 0 : 4,
            shape: const CircleBorder(),
            color: ac.accentFrost,
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
                    color: ac.surfaceField,
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
                decoration: BoxDecoration(
                  color: ac.accentAmber,
                  shape: BoxShape.circle,
                ),
                constraints: const BoxConstraints(
                  minWidth: 20,
                  minHeight: 20,
                ),
                child: Text(
                  '$badgeCount',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: ac.surfaceField,
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


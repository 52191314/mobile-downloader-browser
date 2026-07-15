import 'package:flutter/material.dart';

import '../../theme/aurora_palette.dart';
import '../models/browser_tab.dart';

/// Wraps a tab card so it can be long-press-lifted and dragged into a
/// group header or between-tab slot.
///
/// - Tap: propagates to the child (switches tabs).
/// - Long-press 400ms: lifts the card with a spring scale + tilt and
///   starts dragging. Data payload is `tab.id` so drop targets can
///   resolve back to the original tab.
///
/// Standalone library — no state mutation; the caller owns the
/// onDragStarted/onDragEnd callbacks and the drag-drop wiring.
class DraggableTabCard extends StatefulWidget {
  /// Tab being rendered. Used for the drag payload (`tab.id`).
  final BrowserTab tab;
  final Widget child;
  final VoidCallback? onDragStarted;
  final VoidCallback? onDragEnded;

  /// Optional accent color shown as a 3px left bar on the card body.
  /// Typically the group's color from `TabGroupPalette`.
  final Color? accentColor;

  /// When true, the drag handle affordance is hidden but the
  /// long-press lift is still active (used when the sheet is in
  /// "view" mode rather than edit mode).
  final bool enabled;

  const DraggableTabCard({
    super.key,
    required this.tab,
    required this.child,
    this.onDragStarted,
    this.onDragEnded,
    this.accentColor,
    this.enabled = true,
  });

  @override
  State<DraggableTabCard> createState() => _DraggableTabCardState();
}

class _DraggableTabCardState extends State<DraggableTabCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _lift;

  @override
  void initState() {
    super.initState();
    _lift = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      lowerBound: 0.0,
      upperBound: 1.0,
    );
  }

  @override
  void dispose() {
    _lift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.accentColor;
    final body = Stack(
      children: [
        if (accent != null)
          Positioned(
            left: 0,
            top: 6,
            bottom: 6,
            child: Container(
              width: 3,
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        Padding(
          padding: EdgeInsets.only(left: accent != null ? 8 : 0),
          child: widget.child,
        ),
      ],
    );
    if (!widget.enabled) return body;
    return LongPressDraggable<String>(
      data: widget.tab.id,
      delay: const Duration(milliseconds: 400),
      hapticFeedbackOnStart: true,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      onDragStarted: () {
        _lift.forward();
        widget.onDragStarted?.call();
      },
      onDraggableCanceled: (_, __) => _reset(),
      onDragEnd: (_) {
        _reset();
        widget.onDragEnded?.call();
      },
      feedback: AnimatedBuilder(
        animation: _lift,
        builder: (_, child) {
          final t = Curves.easeOutBack.transform(_lift.value.clamp(0.0, 1.0));
          return Transform.scale(
            scale: 1.0 + 0.06 * t,
            child: Transform.rotate(
              angle: -0.02 * t,
              child: Material(
                color: Colors.transparent,
                elevation: 12,
                shadowColor: context.ac.accentFrost.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(12),
                child: child,
              ),
            ),
          );
        },
        child: Opacity(
          opacity: 0.96,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 320),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: context.ac.accentFrost.withValues(alpha: 0.35),
                  blurRadius: 18,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Stack(
              children: [
                if (accent != null)
                  Positioned(
                    left: 0,
                    top: 6,
                    bottom: 6,
                    child: Container(
                      width: 3,
                      decoration: BoxDecoration(
                        color: accent,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                Padding(
                  padding: EdgeInsets.only(left: accent != null ? 8 : 0),
                  child: widget.child,
                ),
              ],
            ),
          ),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: 0.35,
        child: body,
      ),
      child: body,
    );
  }

  void _reset() {
    if (!mounted) return;
    _lift.reverse();
  }
}

/// A thin 6px tall `DragTarget` rendered between tab cards. Dropping
/// here inserts the dragged tab at this position. Renders a horizontal
/// cyan rule when a draggable hovers over it.
class TabListDropSlot extends StatelessWidget {
  /// When non-null, only drops onto this slot will be accepted (used
  /// to enforce group membership). When null, the slot accepts any
  /// tab (the ungrouped section).
  final String? targetGroupName;
  final void Function(String draggedTabId) onAccept;

  const TabListDropSlot({
    super.key,
    required this.targetGroupName,
    required this.onAccept,
  });

  @override
  Widget build(BuildContext context) {
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => true,
      onAcceptWithDetails: (details) => onAccept(details.data),
      builder: (context, candidate, _) {
        final hovering = candidate.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: hovering ? 18 : 6,
          margin: EdgeInsets.symmetric(vertical: hovering ? 2 : 1),
          decoration: BoxDecoration(
            color: hovering
                ? context.ac.accentFrost.withValues(alpha: 0.35)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(3),
          ),
        );
      },
    );
  }
}
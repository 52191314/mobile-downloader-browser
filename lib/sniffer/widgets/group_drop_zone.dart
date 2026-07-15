import 'package:flutter/material.dart';

import '../../theme/aurora_palette.dart';

/// Wraps a group header so it doubles as a `DragTarget` for adding
/// tabs to a group. The header remains tappable (toggle collapse) and
/// is also long-pressable (group actions).
///
/// Drop behavior: when a tab is dropped onto the header the tab is
/// assigned to this group. If the tab is already in this group the
/// drop is a no-op (callback can short-circuit).
///
/// Standalone library — purely presentational.
class GroupDropZone extends StatelessWidget {
  /// Display name of the group this header represents. Used only for
  /// the visual hint; the caller owns the actual move logic.
  final String groupName;

  /// Accent color of the group (the small bar + hover background).
  final Color accentColor;

  /// Number of tabs in the group — shown in the header chip.
  final int memberCount;

  /// Whether the expansion tile is currently expanded.
  final bool isExpanded;

  /// Tap toggles the expansion.
  final VoidCallback onToggleExpand;

  /// Long-press opens the group actions sheet.
  final VoidCallback onLongPress;

  /// Drop callback: receives the dragged tab id. The caller resolves
  /// it to a `BrowserTab` and calls `moveTabToGroup`.
  final void Function(String draggedTabId) onAcceptDrop;

  /// Optional custom title widget. When null, renders the default
  /// colored-dot + group-name + member-count chip.
  final Widget? titleOverride;

  const GroupDropZone({
    super.key,
    required this.groupName,
    required this.accentColor,
    required this.memberCount,
    required this.isExpanded,
    required this.onToggleExpand,
    required this.onLongPress,
    required this.onAcceptDrop,
    this.titleOverride,
  });

  @override
  Widget build(BuildContext context) {
    final header = titleOverride ?? _buildDefaultHeader(context);
    return DragTarget<String>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) => onAcceptDrop(details.data),
      builder: (context, candidate, _) {
        final hovering = candidate.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.symmetric(vertical: 2),
          decoration: BoxDecoration(
            color: hovering
                ? accentColor.withValues(alpha: 0.18)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: hovering
                ? Border.all(color: accentColor, width: 1.2)
                : Border.all(color: Colors.transparent, width: 1.2),
          ),
          child: ListTile(
            key: Key('group_header_$groupName'),
            dense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 0,
            ),
            onTap: onToggleExpand,
            title: header,
            trailing: AnimatedRotation(
              turns: isExpanded ? 0.5 : 0.0,
              duration: const Duration(milliseconds: 180),
              child: Icon(
                isExpanded
                    ? Icons.keyboard_arrow_down_rounded
                    : Icons.keyboard_arrow_right_rounded,
                color: hovering ? accentColor : context.ac.textSecondary,
                size: 18,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDefaultHeader(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 18,
          decoration: BoxDecoration(
            color: accentColor,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            groupName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: context.ac.textPrimary,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: accentColor.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '$memberCount',
            style: TextStyle(
              color: accentColor,
              fontWeight: FontWeight.w600,
              fontSize: 11,
            ),
          ),
        ),
        const Spacer(),
        // Long-press hint badge — gives users a visible cue that
        // long-press is the gesture for group actions.
        GestureDetector(
          onLongPress: onLongPress,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Icon(
              Icons.more_horiz,
              size: 18,
              color: context.ac.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}
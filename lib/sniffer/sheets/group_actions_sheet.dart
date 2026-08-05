import 'package:flutter/material.dart';

import '../../theme/aurora_palette.dart';
import '../tab_groups/tab_group_palette.dart';

/// Action callbacks consumed by [showGroupActionsSheet]. Each callback
/// performs its own persistence; the sheet is purely presentational so
/// it can be unit-tested in isolation.
class GroupActionsCallbacks {
  /// Rename [oldName] to [newName]. Return `false` if the new name is
  /// already taken by another group (the sheet shows a snackbar in
  /// that case).
  final bool Function(String oldName, String newName) onRename;

  /// Apply or clear the group's color override (palette index 0..7
  /// or `null` to revert to the name-derived hue).
  final void Function(String name, int? colorIndex) onSetColor;

  /// Set or clear the group's auto-host. Pass `null` to disable.
  final void Function(String name, String? host) onSetAutoHost;

  /// Close every member tab.
  final void Function(String name) onCloseAll;

  /// Disband the group but keep its tabs open.
  final void Function(String name) onDisband;

  const GroupActionsCallbacks({
    required this.onRename,
    required this.onSetColor,
    required this.onSetAutoHost,
    required this.onCloseAll,
    required this.onDisband,
  });
}

/// Shows the group-level action bottom sheet — Samsung-style menu
/// invoked by long-pressing a group header in the tab switcher.
void showGroupActionsSheet(
  BuildContext context, {
  required String groupName,
  required int memberCount,
  required String? currentAutoHost,
  required int currentColorIndex,
  required GroupActionsCallbacks callbacks,
}) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AuroraPalette.of(context).surfaceField,
    builder: (ctx) => _GroupActionsBody(
      groupName: groupName,
      memberCount: memberCount,
      currentAutoHost: currentAutoHost,
      currentColorIndex: currentColorIndex,
      callbacks: callbacks,
      onDismiss: () => Navigator.pop(ctx),
    ),
  );
}

class _GroupActionsBody extends StatelessWidget {
  final String groupName;
  final int memberCount;
  final String? currentAutoHost;
  final int currentColorIndex;
  final GroupActionsCallbacks callbacks;
  final VoidCallback onDismiss;

  const _GroupActionsBody({
    required this.groupName,
    required this.memberCount,
    required this.currentAutoHost,
    required this.currentColorIndex,
    required this.callbacks,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final groupColor = TabGroupPalette.colorFor(
      colorIndex: currentColorIndex >= 0 ? currentColorIndex : null,
      groupName: groupName,
    );
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header: colored swatch + name + member count.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 16, 12),
              child: Row(
                children: [
                  Container(
                    width: 14,
                    height: 28,
                    decoration: BoxDecoration(
                      color: groupColor,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          groupName,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: context.ac.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '$memberCount ${memberCount == 1 ? "tab" : "tabs"}',
                          style: TextStyle(
                            fontSize: 12,
                            color: context.ac.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: context.ac.borderStrong),

            // Color picker (8 swatches + Auto).
            _SectionHeader(label: 'Group color'),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 6,
              ),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _AutoSwatch(
                    selected: currentColorIndex < 0,
                    onTap: () {
                      callbacks.onSetColor(groupName, null);
                      onDismiss();
                    },
                  ),
                  for (var i = 0; i < TabGroupPalette.swatchCount; i++)
                    _ColorSwatch(
                      colorIndex: i,
                      selected: currentColorIndex == i,
                      onTap: () {
                        callbacks.onSetColor(groupName, i);
                        onDismiss();
                      },
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),

            // Auto-group toggle.
            SwitchListTile(
              key: Key('group_auto_host_$groupName'),
              secondary: Icon(
                Icons.auto_awesome_outlined,
                color: currentAutoHost == null
                    ? context.ac.textSecondary
                    : context.ac.accentFrost,
              ),
              title: Text(
                'Auto-add from same host',
                style: TextStyle(color: context.ac.textPrimary),
              ),
              subtitle: Text(
                currentAutoHost == null
                    ? 'Off — new tabs only join when you drag them in.'
                    : 'New tabs to $currentAutoHost will join this group.',
                style: TextStyle(
                  color: context.ac.textSecondary,
                  fontSize: 12,
                ),
              ),
              value: currentAutoHost != null,
              activeThumbColor: context.ac.accentFrost,
              onChanged: (val) {
                if (val) {
                  // Enable: persist current host. Caller (state
                  // class) is responsible for resolving the host from
                  // the active tab when this toggle is flipped on.
                  callbacks.onSetAutoHost(groupName, currentAutoHost ?? '');
                  onDismiss();
                } else {
                  callbacks.onSetAutoHost(groupName, null);
                  onDismiss();
                }
              },
            ),

            Divider(height: 1, color: context.ac.borderStrong),

            // Rename / Close all / Disband.
            ListTile(
              key: Key('group_rename_$groupName'),
              leading: Icon(
                Icons.edit_outlined,
                color: context.ac.textSecondary,
              ),
              title: Text(
                'Rename group…',
                style: TextStyle(color: context.ac.textPrimary),
              ),
              onTap: () {
                Navigator.pop(context);
                _showRenameDialog(
                  context,
                  oldName: groupName,
                  onSubmit: (newName) {
                    final ok = callbacks.onRename(groupName, newName);
                    if (!ok && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'A group named "$newName" already exists. Choose a different name.',
                        ),
                      ),
                    );
                    }
                  },
                );
              },
            ),
            ListTile(
              key: Key('group_close_all_$groupName'),
              leading: Icon(
                Icons.close,
                color: context.ac.textSecondary,
              ),
              title: Text(
                'Close all $memberCount tabs',
                style: TextStyle(color: context.ac.textPrimary),
              ),
              onTap: () {
                Navigator.pop(context);
                _confirmThen(
                  context,
                  message:
                      'Close all $memberCount tabs in "$groupName"? You can reopen them from the Recently Closed list.',
                  onConfirm: () => callbacks.onCloseAll(groupName),
                );
              },
            ),
            ListTile(
              key: Key('group_disband_$groupName'),
              leading: const Icon(
                Icons.folder_off_outlined,
                color: Colors.redAccent,
              ),
              title: const Text(
                'Disband group',
                style: TextStyle(color: Colors.redAccent),
              ),
              subtitle: Text(
                'Keep tabs open, remove the group.',
                style: TextStyle(
                  color: context.ac.textSecondary,
                  fontSize: 12,
                ),
              ),
              onTap: () {
                Navigator.pop(context);
                _confirmThen(
                  context,
                  message: 'Disband "$groupName"? Tabs will remain open.',
                  onConfirm: () => callbacks.onDisband(groupName),
                );
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  void _showRenameDialog(
    BuildContext context, {
    required String oldName,
    required void Function(String newName) onSubmit,
  }) {
    final controller = TextEditingController(text: oldName);
    showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: dialogCtx.ac.surfacePanel,
        title: Text(
          'Rename group',
          style: TextStyle(color: dialogCtx.ac.textPrimary),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          style: TextStyle(color: dialogCtx.ac.textPrimary),
          decoration: InputDecoration(
            hintText: 'Group name',
            hintStyle: TextStyle(color: dialogCtx.ac.textSecondary),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: dialogCtx.ac.borderStrong),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: dialogCtx.ac.accentFrost),
            ),
          ),
          onSubmitted: (val) {
            final trimmed = val.trim();
            if (trimmed.isNotEmpty && trimmed != oldName) onSubmit(trimmed);
            Navigator.pop(dialogCtx);
          },
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
              final trimmed = controller.text.trim();
              if (trimmed.isNotEmpty && trimmed != oldName) {
                onSubmit(trimmed);
              }
              Navigator.pop(dialogCtx);
            },
            child: Text(
              'Rename',
              style: TextStyle(color: dialogCtx.ac.accentFrost),
            ),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  void _confirmThen(
    BuildContext context, {
    required String message,
    required VoidCallback onConfirm,
  }) {
    showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: dialogCtx.ac.surfacePanel,
        title: Text(
          'Are you sure?',
          style: TextStyle(color: dialogCtx.ac.textPrimary),
        ),
        content: Text(
          message,
          style: TextStyle(color: dialogCtx.ac.textPrimary),
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
              Navigator.pop(dialogCtx);
              onConfirm();
            },
            child: const Text(
              'Yes',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: context.ac.textSecondary,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.1,
        ),
      ),
    );
  }
}

class _ColorSwatch extends StatelessWidget {
  final int colorIndex;
  final bool selected;
  final VoidCallback onTap;

  const _ColorSwatch({
    required this.colorIndex,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = TabGroupPalette.swatches[colorIndex];
    return Tooltip(
      message: TabGroupPalette.labelFor(colorIndex),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected
                  ? context.ac.textPrimary
                  : context.ac.glassBorder,
              width: selected ? 2.5 : 1,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: color.withValues(alpha: 0.45),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: selected
              ? Icon(
                  Icons.check,
                  color: context.ac.surfaceField,
                  size: 18,
                )
              : null,
        ),
      ),
    );
  }
}

class _AutoSwatch extends StatelessWidget {
  final bool selected;
  final VoidCallback onTap;

  const _AutoSwatch({required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Auto — color from group name',
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: context.ac.surfacePanel,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected
                  ? context.ac.accentFrost
                  : context.ac.glassBorder,
              width: selected ? 2.5 : 1,
            ),
          ),
          child: Icon(
            Icons.shuffle_outlined,
            color: selected ? context.ac.accentFrost : context.ac.textSecondary,
            size: 16,
          ),
        ),
      ),
    );
  }
}

/// End of group actions sheet.
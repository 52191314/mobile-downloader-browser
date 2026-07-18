import 'package:flutter/material.dart';

import '../../theme/aurora_palette.dart';

/// One tile in the browser tools grid.
class BrowserMenuAction {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const BrowserMenuAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });
}

/// Shows the "Browser Tools" grid bottom sheet.
void showBrowserMenuSheet(
  BuildContext context, {
  required int blockedPopupsCount,
  required List<BrowserMenuAction> actions,
}) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    backgroundColor: context.ac.overlay,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      return SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Browser Tools',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: ctx.ac.textPrimary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                Text(
                  'Blocked popups: $blockedPopupsCount',
                  style: TextStyle(
                    fontSize: 12,
                    color: ctx.ac.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                GridView.count(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount: 3,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.1,
                  children: [
                    for (final action in actions)
                      _BrowserMenuItem(
                        icon: action.icon,
                        label: action.label,
                        color: action.color,
                        onTap: () {
                          Navigator.pop(ctx);
                          action.onTap();
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _BrowserMenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _BrowserMenuItem({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 22),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                style: TextStyle(
                  color: context.ac.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

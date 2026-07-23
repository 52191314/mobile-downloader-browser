import 'package:flutter/material.dart';

import '../../theme/aurora_palette.dart';

/// One row in the Samsung-style browser overflow menu.
class BrowserMenuAction {
  final IconData icon;
  final String label;
  final Color? color;
  final VoidCallback onTap;

  /// When true, rendered in the primary block (Downloads / Settings style).
  final bool primary;

  const BrowserMenuAction({
    required this.icon,
    required this.label,
    this.color,
    required this.onTap,
    this.primary = false,
  });
}

/// Samsung Browser–style overflow menu: site header, then a vertical list
/// with Downloads / Settings near the top, then page tools.
void showBrowserMenuSheet(
  BuildContext context, {
  String? pageTitle,
  String? pageUrl,
  required int blockedPopupsCount,
  required List<BrowserMenuAction> primaryActions,
  required List<BrowserMenuAction> toolActions,
}) {
  final host = () {
    final raw = pageUrl?.trim() ?? '';
    if (raw.isEmpty) return '';
    return Uri.tryParse(raw)?.host ?? raw;
  }();
  final title = (pageTitle != null && pageTitle.trim().isNotEmpty)
      ? pageTitle.trim()
      : (host.isNotEmpty ? host : 'Current page');

  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: context.ac.overlay,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) {
      final ac = ctx.ac;
      final maxH = MediaQuery.sizeOf(ctx).height * 0.78;
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxH),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Site card (Samsung-style header)
                  Container(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    decoration: BoxDecoration(
                      color: ac.surfaceElevated,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: ac.glassBorder),
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 18,
                          backgroundColor:
                              ac.accentFrost.withValues(alpha: 0.15),
                          child: Text(
                            host.isNotEmpty ? host[0].toUpperCase() : 'A',
                            style: TextStyle(
                              color: ac.accentFrost,
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: ac.textPrimary,
                                ),
                              ),
                              if (host.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Row(
                                  children: [
                                    Icon(
                                      Icons.lock_outline,
                                      size: 12,
                                      color: ac.textTertiary,
                                    ),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: Text(
                                        host,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: ac.textSecondary,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Primary destinations (Downloads, Settings, …)
                  _MenuGroup(
                    children: [
                      for (final action in primaryActions)
                        _MenuRow(
                          icon: action.icon,
                          label: action.label,
                          color: action.color ?? ac.textPrimary,
                          onTap: () {
                            Navigator.pop(ctx);
                            action.onTap();
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Page tools
                  _MenuGroup(
                    children: [
                      for (final action in toolActions)
                        _MenuRow(
                          icon: action.icon,
                          label: action.label,
                          color: action.color ?? ac.textPrimary,
                          onTap: () {
                            Navigator.pop(ctx);
                            action.onTap();
                          },
                        ),
                    ],
                  ),
                  if (blockedPopupsCount > 0) ...[
                    const SizedBox(height: 10),
                    Text(
                      'Blocked popups: $blockedPopupsCount',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        color: ac.textTertiary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _MenuGroup extends StatelessWidget {
  final List<Widget> children;

  const _MenuGroup({required this.children});

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      decoration: BoxDecoration(
        color: ac.surfaceElevated,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ac.glassBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 1,
                indent: 52,
                color: ac.borderHairline,
              ),
            children[i],
          ],
        ],
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _MenuRow({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(
            children: [
              Icon(icon, size: 22, color: color),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: ac.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

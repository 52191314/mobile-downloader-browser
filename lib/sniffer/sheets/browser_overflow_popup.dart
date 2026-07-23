import 'package:flutter/material.dart';

import '../../theme/aurora_palette.dart';

/// One row in the Samsung-style overflow popup (Settings or Tools).
class OverflowMenuEntry {
  final IconData icon;
  final String label;
  final Color? color;
  final VoidCallback onTap;

  const OverflowMenuEntry({
    required this.icon,
    required this.label,
    this.color,
    required this.onTap,
  });
}

enum OverflowMenuSegment { settings, tools }

/// Remembers last Settings | Tools choice for the next menu open.
class OverflowMenuSegmentStore {
  static OverflowMenuSegment last = OverflowMenuSegment.settings;
}

/// Right-bottom floating card (partial width/height) with Settings | Tools.
///
/// Matches Samsung Browser overflow geometry — not a full-width bottom sheet.
Future<void> showBrowserOverflowPopup(
  BuildContext context, {
  String? pageTitle,
  String? pageUrl,
  required List<OverflowMenuEntry> settingsEntries,
  required List<OverflowMenuEntry> toolEntries,
  OverflowMenuSegment? initialSegment,
  ValueChanged<List<String>>? onReorderSettings,
  ValueChanged<List<String>>? onReorderTools,
}) {
  final segment = initialSegment ?? OverflowMenuSegmentStore.last;
  final host = () {
    final raw = pageUrl?.trim() ?? '';
    if (raw.isEmpty) return '';
    return Uri.tryParse(raw)?.host ?? raw;
  }();
  final title = (pageTitle != null && pageTitle.trim().isNotEmpty)
      ? pageTitle.trim()
      : (host.isNotEmpty ? host : 'Current page');

  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss menu',
    barrierColor: Colors.black.withValues(alpha: 0.35),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (ctx, anim, secondary) {
      return const SizedBox.shrink();
    },
    transitionBuilder: (ctx, anim, secondary, child) {
      final size = MediaQuery.sizeOf(ctx);
      final pad = MediaQuery.paddingOf(ctx);
      final maxW = (size.width * 0.48).clamp(240.0, 320.0);
      final maxH = size.height * 0.62;
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);

      return Stack(
        children: [
          Positioned(
            right: 10,
            bottom: pad.bottom + 56,
            child: FadeTransition(
              opacity: curved,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.92, end: 1).animate(curved),
                alignment: Alignment.bottomRight,
                child: Material(
                  color: Colors.transparent,
                  child: _OverflowCard(
                    maxWidth: maxW,
                    maxHeight: maxH,
                    title: title,
                    host: host,
                    settingsEntries: settingsEntries,
                    toolEntries: toolEntries,
                    initialSegment: segment,
                    onReorderSettings: onReorderSettings,
                    onReorderTools: onReorderTools,
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

class _OverflowCard extends StatefulWidget {
  final double maxWidth;
  final double maxHeight;
  final String title;
  final String host;
  final List<OverflowMenuEntry> settingsEntries;
  final List<OverflowMenuEntry> toolEntries;
  final OverflowMenuSegment initialSegment;
  final ValueChanged<List<String>>? onReorderSettings;
  final ValueChanged<List<String>>? onReorderTools;

  const _OverflowCard({
    required this.maxWidth,
    required this.maxHeight,
    required this.title,
    required this.host,
    required this.settingsEntries,
    required this.toolEntries,
    required this.initialSegment,
    this.onReorderSettings,
    this.onReorderTools,
  });

  @override
  State<_OverflowCard> createState() => _OverflowCardState();
}

class _OverflowCardState extends State<_OverflowCard> {
  late OverflowMenuSegment _segment;
  late List<OverflowMenuEntry> _settingsEntries;
  late List<OverflowMenuEntry> _toolEntries;

  @override
  void initState() {
    super.initState();
    _segment = widget.initialSegment;
    _settingsEntries = List.from(widget.settingsEntries);
    _toolEntries = List.from(widget.toolEntries);
  }

  @override
  void didUpdateWidget(covariant _OverflowCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settingsEntries != widget.settingsEntries) {
      _settingsEntries = List.from(widget.settingsEntries);
    }
    if (oldWidget.toolEntries != widget.toolEntries) {
      _toolEntries = List.from(widget.toolEntries);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final entries = _segment == OverflowMenuSegment.settings
        ? _settingsEntries
        : _toolEntries;

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: widget.maxWidth,
        maxHeight: widget.maxHeight,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: ac.overlay,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: ac.glassBorder),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Site header
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 16,
                      backgroundColor: ac.accentFrost.withValues(alpha: 0.15),
                      child: Text(
                        widget.host.isNotEmpty
                            ? widget.host[0].toUpperCase()
                            : 'A',
                        style: TextStyle(
                          color: ac.accentFrost,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: ac.textPrimary,
                            ),
                          ),
                          if (widget.host.isNotEmpty)
                            Text(
                              widget.host,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: ac.textSecondary,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // Settings | Tools segments
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: ac.surfaceElevated,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      _SegChip(
                        label: 'Settings',
                        selected: _segment == OverflowMenuSegment.settings,
                        onTap: () => setState(() {
                          _segment = OverflowMenuSegment.settings;
                          OverflowMenuSegmentStore.last = _segment;
                        }),
                      ),
                      _SegChip(
                        label: 'Tools',
                        selected: _segment == OverflowMenuSegment.tools,
                        onTap: () => setState(() {
                          _segment = OverflowMenuSegment.tools;
                          OverflowMenuSegmentStore.last = _segment;
                        }),
                      ),
                    ],
                  ),
                ),
              ),
              Flexible(
                child: ReorderableListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 8),
                  itemCount: entries.length,
                  onReorder: (oldIndex, newIndex) {
                    setState(() {
                      if (oldIndex < newIndex) {
                        newIndex -= 1;
                      }
                      final item = entries.removeAt(oldIndex);
                      entries.insert(newIndex, item);
                      final newOrder = entries.map((e) => e.label).toList();
                      if (_segment == OverflowMenuSegment.settings) {
                        widget.onReorderSettings?.call(newOrder);
                      } else {
                        widget.onReorderTools?.call(newOrder);
                      }
                    });
                  },
                  itemBuilder: (context, i) {
                    final e = entries[i];
                    return Material(
                      key: ValueKey('${_segment.name}_${e.label}'),
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () {
                          Navigator.of(context).pop();
                          e.onTap();
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                e.icon,
                                size: 20,
                                color: e.color ?? ac.textPrimary,
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Text(
                                  e.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: ac.textPrimary,
                                  ),
                                ),
                              ),
                              Icon(
                                Icons.reorder_rounded,
                                size: 16,
                                color: ac.textTertiary.withValues(alpha: 0.4),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SegChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SegChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Expanded(
      child: Material(
        color: selected
            ? ac.accentFrost.withValues(alpha: 0.18)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? ac.accentFrost : ac.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

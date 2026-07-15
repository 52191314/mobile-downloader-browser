part of '../sniffer_screen.dart';

class _CompactNavButton extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback? onTap;

  const _CompactNavButton({
    super.key,
    required this.icon,
    this.enabled = true,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      height: 36,
      child: IconButton(
        padding: EdgeInsets.zero,
        icon: Icon(icon, size: 18),
        color: enabled ? context.ac.textPrimary : context.ac.textDisabled,
        onPressed: enabled ? onTap : null,
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final IconData? icon;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.selected,
    this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Text(label),
        selected: selected,
        avatar: icon != null ? Icon(icon, size: 18) : null,
        onSelected: (_) => onTap(),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final int count;

  const _Badge({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.error,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$count',
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _CaptureStatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;

  const _CaptureStatChip({required this.icon, required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    final chipColor = color ?? context.ac.textTertiary;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Container(
        decoration: BoxDecoration(
          color: chipColor.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: chipColor.withValues(alpha: 0.3)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: chipColor),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: chipColor,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniPill extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MiniPill({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.ac.surfaceCard,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: context.ac.glassBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: context.ac.textSecondary),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: context.ac.textSecondary,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CaptureMediaTile extends StatelessWidget {
  final SniffedMedia item;
  final bool selected;
  final IconData icon;
  final String metadata;
  final String? qualityLabel;
  final int variantCount;
  final String? hiddenReason;
  final bool recommended;
  final ValueChanged<bool> onSelected;
  final VoidCallback? onPreview;
  final VoidCallback onDownload;
  final VoidCallback onInfo;
  final Key previewKey;
  final Key downloadKey;
  final Key infoKey;

  const _CaptureMediaTile({
    super.key,
    required this.item,
    required this.selected,
    required this.icon,
    required this.metadata,
    this.qualityLabel,
    this.variantCount = 1,
    this.hiddenReason,
    this.recommended = false,
    required this.onSelected,
    required this.onPreview,
    required this.onDownload,
    required this.onInfo,
    required this.previewKey,
    required this.downloadKey,
    required this.infoKey,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    final Color accentColor;
    String extLabel = 'FILE';
    try {
      final uri = Uri.tryParse(item.url);
      if (uri != null) {
        final path = uri.path.toLowerCase();
        if (path.contains('.m3u8')) {
          extLabel = 'HLS';
        } else {
          final segments = uri.pathSegments;
          if (segments.isNotEmpty && segments.last.contains('.')) {
            final ext = segments.last.split('.').last.toUpperCase();
            if (ext.length <= 4) {
              extLabel = ext;
            } else {
              extLabel = ext.substring(0, 4);
            }
          }
        }
      }
    } catch (_) {}
    if (extLabel == 'FILE' && item.type == MediaType.video) extLabel = 'MP4';
    if (extLabel == 'FILE' && item.type == MediaType.audio) extLabel = 'MP3';

    if (item.url.contains('.m3u8') || extLabel == 'HLS') {
      accentColor = Colors.orange;
    } else if (item.type == MediaType.video) {
      accentColor = Colors.blue;
    } else if (item.type == MediaType.audio) {
      accentColor = Colors.purple;
    } else if (item.type == MediaType.image) {
      accentColor = Colors.green;
    } else {
      accentColor = Colors.teal;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 3, 12, 3),
      child: IntrinsicHeight(
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [context.ac.gradientMid, context.ac.surfacePanel],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? colors.primary
                  : context.ac.glassBorder,
              width: selected ? 2.0 : 1.0,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: colors.primary.withValues(alpha: 0.3),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(11),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onInfo,
                child: Row(
                  children: [
                    Container(width: 6, color: accentColor),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 6,
                          horizontal: 4,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    item.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                      color: Colors.white,
                                      height: 1.2,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (item.sourcePageUrl != null &&
                                item.sourcePageUrl!.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Row(
                                children: [
                                  const Icon(
                                    Icons.public,
                                    size: 11,
                                    color: Colors.white24,
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      Uri.tryParse(item.sourcePageUrl!)?.host ??
                                          item.sourcePageUrl!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Colors.white38,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                            const SizedBox(height: 4),
                            Wrap(
                              spacing: 4,
                              runSpacing: 4,
                              children: [
                                Container(
                                  decoration: BoxDecoration(
                                    color: accentColor.withValues(
                                      alpha: 0.15,
                                    ),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: accentColor.withValues(
                                        alpha: 0.3,
                                      ),
                                    ),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  child: Text(
                                    extLabel,
                                    style: TextStyle(
                                      color: accentColor,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                if (recommended)
                                  const _MiniPill(
                                    icon: Icons.auto_awesome,
                                    label: 'Best quality',
                                  ),
                                if (qualityLabel != null && qualityLabel != 'HLS')
                                  _MiniPill(
                                    icon: Icons.high_quality,
                                    label: qualityLabel!,
                                  ),
                                if (hiddenReason != null)
                                  _MiniPill(
                                    icon: Icons.visibility_off,
                                    label: hiddenReason!,
                                  ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              metadata,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.white54,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: 6.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            key: infoKey,
                            tooltip: 'View details',
                            icon: const Icon(
                              Icons.info_outline,
                              color: Colors.white70,
                              size: 18,
                            ),
                            visualDensity: VisualDensity.compact,
                            onPressed: onInfo,
                          ),
                          if (onPreview != null)
                            IconButton(
                              key: previewKey,
                              tooltip: 'Play preview',
                              icon: Icon(
                                Icons.play_circle,
                                color: colors.primary,
                                size: 20,
                              ),
                              visualDensity: VisualDensity.compact,
                              onPressed: onPreview,
                            ),
                          IconButton(
                            key: downloadKey,
                            tooltip: 'Download this item',
                            icon: const Icon(
                              Icons.download,
                              color: Colors.tealAccent,
                              size: 20,
                            ),
                            visualDensity: VisualDensity.compact,
                            onPressed: onDownload,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CaptureActionBar extends StatelessWidget {
  final int selectedCount;
  final int totalCount;
  final VoidCallback? onSelectAll;
  final VoidCallback? onDownloadSelected;

  const _CaptureActionBar({
    required this.selectedCount,
    required this.totalCount,
    required this.onSelectAll,
    required this.onDownloadSelected,
  });

  @override
  Widget build(BuildContext context) {
    final allSelected = totalCount > 0 && selectedCount == totalCount;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          children: [
            TextButton.icon(
              key: const Key('capture_select_all_button'),
              icon: Icon(allSelected ? Icons.check_box : Icons.select_all),
              label: Text(allSelected ? 'Clear' : 'All'),
              onPressed: onSelectAll,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                selectedCount == 0
                    ? '$totalCount items ready'
                    : '$selectedCount selected',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Opacity(
              opacity: onDownloadSelected == null ? 0.5 : 1.0,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: onDownloadSelected == null
                        ? [context.ac.surfaceElevated, context.ac.surfacePanel]
                        : [context.ac.accentFrost, const Color(0xFF5E81AC)],
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: onDownloadSelected != null
                      ? [
                          BoxShadow(
                            color: context.ac.accentFrost.withValues(alpha: 0.3),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ]
                      : null,
                ),
                child: ElevatedButton.icon(
                  key: const Key('batch_download_btn'),
                  icon: const Icon(Icons.download, color: Colors.white),
                  label: const Text(
                    'Download selected items',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                  onPressed: onDownloadSelected,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SniffedMediaControls extends StatelessWidget {
  final DownloadSettings settings;
  final ValueChanged<DownloadSettings>? onSettingsChanged;

  const _SniffedMediaControls({
    required this.settings,
    required this.onSettingsChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<SniffedMediaSort>(
              value: settings.sniffedMediaSort,
              decoration: const InputDecoration(labelText: 'Sort by'),
              isExpanded: true,
              items: SniffedMediaSort.values
                  .map(
                    (sort) =>
                        DropdownMenuItem(value: sort, child: Text(sort.name)),
                  )
                  .toList(),
              onChanged: (value) {
                if (value == null) return;
                onSettingsChanged?.call(
                  settings.copyWith(sniffedMediaSort: value),
                );
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonFormField<SniffedMediaDisplayMode>(
              value: settings.sniffedMediaDisplayMode,
              decoration: const InputDecoration(labelText: 'Show type'),
              isExpanded: true,
              items: SniffedMediaDisplayMode.values
                  .map(
                    (mode) =>
                        DropdownMenuItem(value: mode, child: Text(mode.name)),
                  )
                  .toList(),
              onChanged: (value) {
                if (value == null) return;
                onSettingsChanged?.call(
                  settings.copyWith(sniffedMediaDisplayMode: value),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Two-slide browser dock shown in the Sniffer screen's bottom strip.
///
/// Slide 1: Backward · Forward · Sniffer · Download · Tab
/// Slide 2: Browser Tools · Settings
///
/// Swipe horizontally to move between slides. Icons are flat (no circle
/// outline). A small pill indicator shows the active slide.
class _BrowserDock extends StatefulWidget {
  final BrowserTab tab;
  final VoidCallback onSniffer;
  final VoidCallback onDownload;
  final VoidCallback onTab;
  final VoidCallback onBrowserTools;
  final VoidCallback onSettings;

  const _BrowserDock({
    required this.tab,
    required this.onSniffer,
    required this.onDownload,
    required this.onTab,
    required this.onBrowserTools,
    required this.onSettings,
  });

  @override
  State<_BrowserDock> createState() => _BrowserDockState();
}

class _BrowserDockState extends State<_BrowserDock> {
  final PageController _pageController = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tab = widget.tab;
    final badgeCount = tab.snifferEngine.detectedMedia.length;

    final slide1 = <Widget>[
      _CompactNavButton(
        key: const Key('sniffer_back_button'),
        icon: Icons.arrow_back_ios_new,
        enabled: tab.canGoBack,
        onTap: tab.canGoBack ? () => tab.controller.goBack() : null,
      ),
      _CompactNavButton(
        key: const Key('sniffer_forward_button'),
        icon: Icons.arrow_forward_ios,
        enabled: tab.canGoForward,
        onTap: tab.canGoForward ? () => tab.controller.goForward() : null,
      ),
      _CompactNavButton(
        key: const Key('sniffer_sniffer_button'),
        icon: badgeCount > 0 ? Icons.radar : Icons.add,
        enabled: true,
        onTap: widget.onSniffer,
      ),
      _CompactNavButton(
        key: const Key('mini_dock_queue'),
        icon: Icons.download_rounded,
        enabled: true,
        onTap: widget.onDownload,
      ),
      _CompactNavButton(
        key: const Key('browser_tabs_button'),
        icon: Icons.tab,
        enabled: true,
        onTap: widget.onTab,
      ),
    ];

    final slide2 = <Widget>[
      _CompactNavButton(
        key: const Key('mini_dock_menu'),
        icon: Icons.menu_rounded,
        enabled: true,
        onTap: widget.onBrowserTools,
      ),
      _CompactNavButton(
        key: const Key('mini_dock_settings'),
        icon: Icons.tune_rounded,
        enabled: true,
        onTap: widget.onSettings,
      ),
    ];

    return Column(
      children: [
        Expanded(
          child: PageView(
            controller: _pageController,
            onPageChanged: (index) => setState(() => _page = index),
            children: [
              _dockSlide(slide1),
              _dockSlide(slide2),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _DockDot(active: _page == 0),
              const SizedBox(width: 6),
              _DockDot(active: _page == 1),
            ],
          ),
        ),
      ],
    );
  }

  Widget _dockSlide(List<Widget> children) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: children,
      );
}

class _DockDot extends StatelessWidget {
  final bool active;
  const _DockDot({required this.active});

  @override
  Widget build(BuildContext context) => Container(
        width: 14,
        height: 4,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(2),
          color: active
              ? context.ac.accentFrost
              : context.ac.textSecondary.withValues(alpha: 0.4),
        ),
      );
}

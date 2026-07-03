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
        color: enabled ? AuroraColors.text : AuroraColors.disabledText,
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
    final chipColor = color ?? Colors.grey;
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
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: Colors.white70),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white70,
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
            gradient: const LinearGradient(
              colors: [AuroraColors.gradientMid, AuroraColors.surface],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? colors.primary
                  : Colors.white.withValues(alpha: 0.08),
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
                                    label: 'Best',
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
                            tooltip: 'Info',
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
                              tooltip: 'Preview',
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
                            tooltip: 'Download',
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
                    ? '$totalCount ready to capture'
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
                        ? [Colors.grey.shade700, Colors.grey.shade800]
                        : [Colors.teal, Colors.blue],
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: onDownloadSelected != null
                      ? [
                          BoxShadow(
                            color: Colors.teal.withValues(alpha: 0.3),
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
                    'Download selected',
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
              decoration: const InputDecoration(labelText: 'Sort'),
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
              decoration: const InputDecoration(labelText: 'Show'),
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

import 'package:flutter/material.dart';

import 'package:aurora_downloader/settings/download_settings.dart';
import 'package:aurora_downloader/sniffer/capture/media_accent.dart';
import 'package:aurora_downloader/sniffer/media_capture_analyzer.dart';
import 'package:aurora_downloader/sniffer/models/sniffed_media.dart';
import 'package:aurora_downloader/theme/aurora_palette.dart';

/// One capture-group row with selection, type well, metadata, and actions.
///
/// Download is not per-row — use checkbox multi-select + header Download.
/// Density strategy (KD18): default 40dp action targets; when width &lt; 360,
/// Preview/Info collapse into a trailing [PopupMenuButton].
class CaptureMediaRow extends StatelessWidget {
  const CaptureMediaRow({
    super.key,
    required this.index,
    required this.group,
    required this.selected,
    required this.onSelectedChanged,
    required this.onPreview,
    required this.onInfo,
    this.displayMode = SniffedMediaDisplayMode.both,
  });

  final int index;
  final CaptureGroup group;
  final bool selected;
  final ValueChanged<bool> onSelectedChanged;
  final VoidCallback? onPreview;
  final VoidCallback onInfo;

  /// Controls size/duration richness in the subtitle (PR5 / KD25).
  final SniffedMediaDisplayMode displayMode;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final isLight = context.isLight;
    final item = group.primary.media;
    final hls = isHlsMedia(item);
    final accent = mediaAccentFor(ac, item, isHls: hls);
    final qualityLabel = group.primary.qualityLabel;
    final showQuality = qualityLabel != null &&
        qualityLabel.isNotEmpty &&
        qualityLabel != 'HLS';
    final recommended = group.isRecommended;
    final subtitle = buildCaptureSubtitle(
      item,
      group,
      hls: hls,
      displayMode: displayMode,
    );
    final canPreview = onPreview != null &&
        (item.type == MediaType.video ||
            item.type == MediaType.audio ||
            item.type == MediaType.image);

    final borderColor = selected ? ac.accentFrost : ac.borderHairline;
    final borderWidth = selected ? 2.0 : 1.0;
    final glowAlpha = isLight ? 0.12 : 0.20;
    final glowBlur = isLight ? 6.0 : 8.0;

    final BoxDecoration decoration;
    if (isLight) {
      decoration = BoxDecoration(
        color: ac.surfaceCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: borderWidth),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: ac.accentFrost.withValues(alpha: glowAlpha),
                  blurRadius: glowBlur,
                ),
              ]
            : null,
      );
    } else {
      decoration = BoxDecoration(
        gradient: LinearGradient(
          colors: [ac.gradientMid, ac.surfacePanel],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: borderWidth),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: ac.accentFrost.withValues(alpha: glowAlpha),
                  blurRadius: glowBlur,
                ),
              ]
            : null,
      );
    }

    // Do NOT nest LayoutBuilder under IntrinsicHeight (layout crash).
    final narrow = MediaQuery.sizeOf(context).width < 360;
    // Compact trailing actions so title keeps horizontal room.
    const actionSize = 32.0;

    return Padding(
      key: Key('sniffed_item_$index'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Container(
        decoration: decoration,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(11),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onInfo,
              // Left-leaning inset (wall gone) — pull checkbox/icon left.
              child: Padding(
                padding: const EdgeInsets.fromLTRB(2, 8, 2, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 36,
                      height: 36,
                      child: Checkbox(
                        value: selected,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                        fillColor: WidgetStateProperty.resolveWith((s) {
                          if (s.contains(WidgetState.selected)) {
                            return ac.accentFrost;
                          }
                          return null;
                        }),
                        checkColor: context.auroraColorScheme.onPrimary,
                        onChanged: (v) {
                          if (v != null) onSelectedChanged(v);
                        },
                      ),
                    ),
                    const SizedBox(width: 2),
                    // Type icon + quality tag stacked under it.
                    SizedBox(
                      width: 40,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(
                              mediaTypeIcon(item.type),
                              color: accent,
                              size: 20,
                            ),
                          ),
                          if (showQuality) ...[
                            const SizedBox(height: 3),
                            _QualityPill(
                              label: qualityLabel,
                              color: accent,
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  item.name.isNotEmpty
                                      ? item.name
                                      : 'Unknown media',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: ac.textPrimary,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              if (recommended) ...[
                                const SizedBox(width: 4),
                                const _BestPill(),
                              ],
                            ],
                          ),
                          if (subtitle.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              subtitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: ac.textSecondary,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    // Tight cluster — no extra gap before actions.
                    if (narrow)
                      _OverflowActions(
                        index: index,
                        canPreview: canPreview,
                        onPreview: onPreview,
                        onInfo: onInfo,
                        actionSize: actionSize,
                      )
                    else
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (canPreview)
                            _ActionIcon(
                              key: Key('preview_item_$index'),
                              icon: Icons.play_circle_outline,
                              color: ac.accentFrost,
                              tooltip: 'Preview item',
                              size: actionSize,
                              onPressed: onPreview!,
                            ),
                          _ActionIcon(
                            key: Key('info_item_$index'),
                            icon: Icons.info_outline,
                            color: ac.textSecondary,
                            tooltip: 'Details',
                            size: actionSize,
                            onPressed: onInfo,
                          ),
                        ],
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

/// Ordered metadata recipe: size (~ if estimated) · res · duration · HLS/type · variants.
///
/// [displayMode] gates size/duration only; resolution, HLS/content-type, and
/// variant count remain eligible whenever present.
@visibleForTesting
String buildCaptureSubtitle(
  SniffedMedia item,
  CaptureGroup group, {
  required bool hls,
  SniffedMediaDisplayMode displayMode = SniffedMediaDisplayMode.both,
}) {
  final parts = <String>[];
  final includeSize = displayMode == SniffedMediaDisplayMode.size ||
      displayMode == SniffedMediaDisplayMode.both;
  final includeDuration = displayMode == SniffedMediaDisplayMode.duration ||
      displayMode == SniffedMediaDisplayMode.both;

  if (includeSize) {
    final size = formatCaptureBytes(
      item.contentLengthBytes,
      estimated: item.isSizeEstimated,
    );
    if (size.isNotEmpty) parts.add(size);
  }
  if (item.width != null && item.height != null) {
    parts.add('${item.width}x${item.height}');
  }
  if (includeDuration &&
      item.duration != null &&
      item.duration!.inSeconds > 0) {
    parts.add(formatCaptureDuration(item.duration!));
  }
  if (hls) {
    parts.add('HLS');
  } else if (item.contentType != null && item.contentType!.isNotEmpty) {
    parts.add(item.contentType!.split(';').first.trim());
  }
  if (group.variantCount > 1) {
    parts.add('${group.variantCount} variants');
  }
  return parts.join(' \u00B7 ');
}

class _QualityPill extends StatelessWidget {
  const _QualityPill({
    required this.label,
    required this.color,
  });

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _BestPill extends StatelessWidget {
  const _BestPill();

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: ac.accentAmber.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome, size: 10, color: ac.accentAmber),
          const SizedBox(width: 2),
          Text(
            'Best',
            style: TextStyle(
              color: ac.accentAmber,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionIcon extends StatelessWidget {
  const _ActionIcon({
    super.key,
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.size,
    required this.onPressed,
  });

  final IconData icon;
  final Color color;
  final String tooltip;
  final double size;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        minimumSize: Size(size, size),
        maximumSize: Size(size, size),
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
      ),
      constraints: BoxConstraints.tightFor(width: size, height: size),
      icon: Icon(icon, size: 18),
      color: color,
      onPressed: onPressed,
    );
  }
}

/// Narrow-width overflow: Preview / Details only (download is header multi-select).
class _OverflowActions extends StatelessWidget {
  const _OverflowActions({
    required this.index,
    required this.canPreview,
    required this.onPreview,
    required this.onInfo,
    required this.actionSize,
  });

  final int index;
  final bool canPreview;
  final VoidCallback? onPreview;
  final VoidCallback onInfo;
  final double actionSize;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PopupMenuButton<String>(
          tooltip: 'More actions',
          icon: Icon(Icons.more_vert, color: ac.textSecondary, size: 20),
          padding: EdgeInsets.zero,
          constraints: BoxConstraints(
            minWidth: actionSize,
            minHeight: actionSize,
          ),
          onSelected: (value) {
            switch (value) {
              case 'preview':
                onPreview?.call();
              case 'info':
                onInfo();
            }
          },
          itemBuilder: (context) => [
            if (canPreview)
              const PopupMenuItem(
                value: 'preview',
                child: Text('Preview'),
              ),
            const PopupMenuItem(
              value: 'info',
              child: Text('Details'),
            ),
          ],
        ),
        // Preserve action keys for finders even when UI collapses into menu.
        Offstage(
          child: SizedBox(
            width: 0,
            height: 0,
            child: Row(
              children: [
                if (canPreview)
                  IconButton(
                    key: Key('preview_item_$index'),
                    icon: const Icon(Icons.play_circle_outline),
                    onPressed: onPreview,
                  ),
                IconButton(
                  key: Key('info_item_$index'),
                  icon: const Icon(Icons.info_outline),
                  onPressed: onInfo,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

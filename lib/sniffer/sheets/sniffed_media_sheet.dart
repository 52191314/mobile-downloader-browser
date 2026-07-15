// Standalone library — extracted from `sniffer_screen.dart` during Phase 5 of
// the refactorization. Provides the "rich" caught-media bottom sheet
// (`showSniffedMediaSheet`) plus the two widget helpers it depends on
// (`buildCatchSheetHeader`, `compactFilterChip`).
//
// All state-mutating side effects that used to live on
// `_SnifferScreenState` are exposed as named callbacks. The two private
// widget helpers (`_CaptureStatChip`, `_MediaSheetReBuilder`) that used
// to be `part of` files have been inlined into this file so the sheet
// can be a self-contained library without needing the original
// `sniffer_screen.dart` "part of" hierarchy.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:aurora_downloader/settings/download_settings.dart';
import 'package:aurora_downloader/sniffer/controllers/media_catch_controller.dart';
import 'package:aurora_downloader/sniffer/models/browser_tab.dart';
import 'package:aurora_downloader/sniffer/models/sniffed_media.dart';
import 'package:aurora_downloader/theme/aurora_palette.dart';

/// Filter options for the rich catch sheet segmented control.
/// Mirrors the `MediaFilter` enum that previously lived at the top of
/// `sniffer_screen.dart`. Re-declared here so this file is self-contained
/// (the screen-level enum was moved into the same library as the sheet).
enum MediaFilter { all, video, audio, hls, torrent, image }

/// Small inline pill chip used in the catch-sheet stats row. Inlined from
/// `widgets/capture_widgets.dart` (a `part of` file in the original
/// layout) so the sheet does not need the part-of hierarchy.
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

/// Lightweight StatefulWidget that subscribes to a [Stream<SniffedMedia>]
/// and triggers a rebuild of the outer [StatefulBuilder] (via the
/// provided [onChanged] callback) whenever the stream emits.
///
/// Inlined from the previous top-of-`sniffer_screen.dart` class so the
/// sheet can be a self-contained library.
class _MediaSheetReBuilder extends StatefulWidget {
  final Stream<SniffedMedia> stream;
  final VoidCallback onChanged;
  final Widget child;

  const _MediaSheetReBuilder({
    required this.stream,
    required this.onChanged,
    required this.child,
  });

  @override
  State<_MediaSheetReBuilder> createState() => _MediaSheetReBuilderState();
}

class _MediaSheetReBuilderState extends State<_MediaSheetReBuilder> {
  StreamSubscription<SniffedMedia>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.stream.listen((_) {
      if (mounted) widget.onChanged();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Header row shown above the segmented filter in the rich catch sheet.
///
/// Replaces the body of `_SnifferScreenState._buildCatchSheetHeader`.
/// `onSelectBest` is invoked when the user taps the "Best" button; the
/// caller is responsible for mutating [MediaCatchController.selectedIndices]
/// (typically via a captured `setSheetState`).
Widget buildCatchSheetHeader(
  BuildContext ctx,
  void Function(void Function()) setSheetState, {
  required int totalShown,
  required int selectedCount,
  required VoidCallback onSelectBest,
  required VoidCallback onClearCaptured,
  required VoidCallback onRescan,
}) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
    child: Row(
      children: [
        const Icon(Icons.filter_alt, color: Colors.tealAccent, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Media on this page',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
              Text(
                totalShown == 0
                    ? 'Browse to find downloadable media'
                    : '$selectedCount selected from $totalShown shown',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Rescan page for new media',
          icon: const Icon(Icons.refresh_rounded, color: Colors.cyanAccent),
          onPressed: onRescan,
        ),
        TextButton.icon(
          key: const Key('capture_select_best_button'),
          icon: const Icon(Icons.auto_awesome, size: 16, color: Colors.amber),
          label: const Text(
            'Best',
            style: TextStyle(
              color: Colors.amber,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
          onPressed: totalShown == 0 ? null : onSelectBest,
        ),
        IconButton(
          tooltip: 'Clear all detected media',
          icon: const Icon(Icons.delete_sweep, color: Colors.redAccent),
          onPressed: totalShown == 0 ? null : onClearCaptured,
        ),
      ],
    ),
  );
}

/// Compact pill-style filter chip used in the rich catch sheet.
///
/// Replaces the body of `_SnifferScreenState._compactFilterChip`.
Widget compactFilterChip(
  BuildContext context,
  String label,
  MediaFilter value,
  IconData icon,
  MediaFilter current,
  ValueChanged<MediaFilter> onSelected,
) {
  final isSelected = current == value;
  return GestureDetector(
    onTap: () => onSelected(value),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: isSelected
            ? context.ac.accentFrost.withValues(alpha: 0.2)
            : context.ac.glassSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isSelected ? context.ac.accentFrost : context.ac.glassBorder,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: isSelected ? context.ac.accentFrost : context.ac.textSecondary,
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              color: isSelected ? context.ac.accentFrost : context.ac.textSecondary,
            ),
          ),
        ],
      ),
    ),
  );
}

/// Icon mapping for each [MediaType] (mirrors the helper of the same name
/// on `_SnifferScreenState`).
IconData _mediaIcon(MediaType type) {
  return switch (type) {
    MediaType.video => Icons.movie,
    MediaType.audio => Icons.audiotrack,
    MediaType.image => Icons.image,
    MediaType.document => Icons.description,
    MediaType.archive => Icons.archive,
    MediaType.torrent => Icons.hub,
    MediaType.subtitle => Icons.subtitles,
    MediaType.executable => Icons.insert_drive_file,
    MediaType.playlist => Icons.queue_music,
  };
}

/// Accent color for a [SniffedMedia] row. HLS streams always use orange.
Color _accentFor(SniffedMedia item, bool isHls) {
  if (isHls) return Colors.orange;
  return switch (item.type) {
    MediaType.video => Colors.blue,
    MediaType.audio => Colors.purple,
    MediaType.image => Colors.green,
    MediaType.torrent => Colors.amber,
    _ => Colors.teal,
  };
}

/// Short label for a byte count, used in the stats row of the catch sheet.
String _sizeText(int? bytes) {
  if (bytes == null || bytes <= 0) return '';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Formats duration into a readable format (e.g. MM:SS or HH:MM:SS)
String _formatDuration(Duration d) {
  final hrs = d.inHours;
  final mins = d.inMinutes % 60;
  final secs = d.inSeconds % 60;
  if (hrs > 0) {
    return '$hrs:${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }
  return '$mins:${secs.toString().padLeft(2, '0')}';
}

/// True when the media looks like an HLS stream (URL or content-type).
bool _isHlsItem(SniffedMedia m) {
  return m.url.contains('.m3u8') ||
      (m.contentType?.contains('m3u8') ?? false) ||
      (m.contentType?.contains('apple/mpegurl') ?? false);
}

/// Sum of known content lengths across a list of media.
int _totalBytes(Iterable<SniffedMedia> list) {
  return list.fold<int>(0, (s, m) => s + (m.contentLengthBytes ?? 0));
}

/// Maps the segmented control's [MediaFilter] to the corresponding
/// [MediaType] stored on the [MediaCatchController]. HLS has no
/// [MediaType] match so it returns `null`.
MediaType? _mediaTypeForFilter(MediaFilter filter) {
  return switch (filter) {
    MediaFilter.all => null,
    MediaFilter.video => MediaType.video,
    MediaFilter.audio => MediaType.audio,
    MediaFilter.torrent => MediaType.torrent,
    MediaFilter.image => MediaType.image,
    MediaFilter.hls => null,
  };
}

/// Inverse of [_mediaTypeForFilter] — used to seed the segmented control
/// from the controller's persisted `activeFilter`.
MediaFilter _filterForMediaType(MediaType? mt) {
  return switch (mt) {
    null => MediaFilter.all,
    MediaType.video => MediaFilter.video,
    MediaType.audio => MediaFilter.audio,
    MediaType.torrent => MediaFilter.torrent,
    MediaType.image => MediaFilter.image,
    _ => MediaFilter.all,
  };
}

/// Shows the rich caught-media bottom sheet for [activeTab]. Replaces the
/// body of `_SnifferScreenState._showSniffedMediaSheet`.
///
/// The function deliberately takes a wide parameter list (all dependencies
/// on `_SnifferScreenState` are surfaced as named callbacks) so it can be
/// unit-tested in isolation and so the state class no longer has to
/// absorb the entire sheet logic.
void showSniffedMediaSheet(
  BuildContext context, {
  required BrowserTab activeTab,
  required MediaCatchController mediaCatchController,
  required DownloadSettings settings,
  required ValueChanged<DownloadSettings>? onSettingsChanged,
  required bool isMounted,
  required VoidCallback onChanged,
  required List<SniffedMedia> Function(List<SniffedMedia> media) sortMedia,
  required void Function(SniffedMedia media) onPreview,
  required void Function(BuildContext context, SniffedMedia item) onInfo,
  required void Function(
    BuildContext context,
    SniffedMedia media, {
    List<SniffedMedia> variants,
  }) onAddToQueue,
  required VoidCallback onRescan,
}) {
  if (!isMounted) return;
  final parentContext = context;
  final tab = activeTab;
  mediaCatchController.clearSelection();

  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) {
      // Local filter state for the segmented control (persists in closure).
      // We sync [MediaCatchController.activeFilter] for standard types.
      MediaFilter currentSegment = _filterForMediaType(
        mediaCatchController.activeFilter,
      );

      return StatefulBuilder(
        builder: (ctx, setSheetState) {
          return _MediaSheetReBuilder(
            stream: tab.snifferEngine.onMediaChanged,
            onChanged: () {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (ctx.mounted) setSheetState(() {});
              });
            },
            child: Builder(
              builder: (innerCtx) {
                // --- Gather & analyse media ---
                final allMedia = sortMedia(tab.snifferEngine.detectedMedia)
                    .where(
                      (m) => !m.isShortClip,
                    )
                    .toList();

                final captureResult = mediaCatchController.analyze(allMedia);

                // Sync controller filter with segment selection.
                mediaCatchController.activeFilter =
                    _mediaTypeForFilter(currentSegment);

                var filteredGroups = mediaCatchController.filteredGroups(
                  captureResult.groups,
                );

                if (currentSegment == MediaFilter.hls) {
                  filteredGroups = filteredGroups
                      .where(
                        (g) =>
                            _isHlsItem(g.primary.media) ||
                            g.candidates.any((c) => _isHlsItem(c.media)),
                      )
                      .toList(growable: false);
                }

                final selectedCount = mediaCatchController.selectedCount(
                  filteredGroups.length,
                );
                final totalBytesResult = _totalBytes(allMedia);

                return DraggableScrollableSheet(
                  initialChildSize: 0.90,
                  minChildSize: 0.30,
                  maxChildSize: 1.0,
                  snap: true,
                  snapSizes: const [0.3, 0.5, 0.9, 1.0],
                  expand: false,
                  builder: (scrollCtx, scrollController) {
                    return CustomScrollView(
                      key: const Key('sniffer_drawer'),
                      controller: scrollController,
                      physics: const ClampingScrollPhysics(),
                      slivers: [
                        SliverToBoxAdapter(
                          child: buildCatchSheetHeader(
                            ctx,
                            setSheetState,
                            totalShown: filteredGroups.length,
                            selectedCount: selectedCount,
                            onSelectBest: () {
                              setSheetState(() {
                                mediaCatchController.clearSelection();
                                mediaCatchController.selectedIndices.addAll(
                                  mediaCatchController.recommendedCaptureIndices(
                                    mediaCatchController.filteredGroups(
                                      mediaCatchController.analyze(
                                        sortMedia(
                                          activeTab.snifferEngine.detectedMedia,
                                        ),
                                      ).groups,
                                    ),
                                  ),
                                );
                              });
                            },
                            onClearCaptured: () {
                              setSheetState(() {
                                activeTab.snifferEngine.clearCache();
                                mediaCatchController.clearSelection();
                              });
                            },
                            onRescan: onRescan,
                          ),
                        ),
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  compactFilterChip(
                                    ctx,
                                    'All',
                                    MediaFilter.all,
                                    Icons.all_inclusive,
                                    currentSegment,
                                    (v) {
                                      setSheetState(() {
                                        currentSegment = v;
                                        mediaCatchController.clearSelection();
                                      });
                                    },
                                  ),
                                  const SizedBox(width: 6),
                                  compactFilterChip(
                                    ctx,
                                    'Video',
                                    MediaFilter.video,
                                    Icons.movie,
                                    currentSegment,
                                    (v) {
                                      setSheetState(() {
                                        currentSegment = v;
                                        mediaCatchController.clearSelection();
                                      });
                                    },
                                  ),
                                  const SizedBox(width: 6),
                                  compactFilterChip(
                                    ctx,
                                    'Audio',
                                    MediaFilter.audio,
                                    Icons.audiotrack,
                                    currentSegment,
                                    (v) {
                                      setSheetState(() {
                                        currentSegment = v;
                                        mediaCatchController.clearSelection();
                                      });
                                    },
                                  ),
                                  const SizedBox(width: 6),
                                  compactFilterChip(
                                    ctx,
                                    'HLS',
                                    MediaFilter.hls,
                                    Icons.queue_music,
                                    currentSegment,
                                    (v) {
                                      setSheetState(() {
                                        currentSegment = v;
                                        mediaCatchController.clearSelection();
                                      });
                                    },
                                  ),
                                  const SizedBox(width: 6),
                                  compactFilterChip(
                                    ctx,
                                    'Torrent',
                                    MediaFilter.torrent,
                                    Icons.hub,
                                    currentSegment,
                                    (v) {
                                      setSheetState(() {
                                        currentSegment = v;
                                        mediaCatchController.clearSelection();
                                      });
                                    },
                                  ),
                                  const SizedBox(width: 6),
                                  compactFilterChip(
                                    ctx,
                                    'Image',
                                    MediaFilter.image,
                                    Icons.image,
                                    currentSegment,
                                    (v) {
                                      setSheetState(() {
                                        currentSegment = v;
                                        mediaCatchController.clearSelection();
                                      });
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        SliverToBoxAdapter(
                          child: SwitchListTile(
                            key: const Key('capture_show_all_switch'),
                            dense: true,
                            secondary: const Icon(Icons.tune, size: 20),
                            title: const Text(
                              'Show all captured media',
                              style: TextStyle(fontSize: 13),
                            ),
                            subtitle: Text(
                              mediaCatchController.captureShowAllMedia
                                  ? 'Show every detected URL, including non-media assets'
                                  : 'Show only URLs that look like playable media',
                              style: const TextStyle(fontSize: 11),
                            ),
                            value: mediaCatchController.captureShowAllMedia,
                            onChanged: (value) {
                              setSheetState(() {
                                mediaCatchController.captureShowAllMedia = value;
                                mediaCatchController.clearSelection();
                              });
                              onSettingsChanged?.call(
                                settings.copyWith(captureShowAllMedia: value),
                              );
                            },
                          ),
                        ),
                        const SliverToBoxAdapter(child: SizedBox(height: 4)),
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  _CaptureStatChip(
                                    icon: Icons.link,
                                    label: '${allMedia.length} found',
                                    color: Colors.teal,
                                  ),
                                  _CaptureStatChip(
                                    icon: Icons.movie,
                                    label:
                                        '${allMedia.where((m) => m.type == MediaType.video).length} video',
                                    color: Colors.blue,
                                  ),
                                  _CaptureStatChip(
                                    icon: Icons.audiotrack,
                                    label:
                                        '${allMedia.where((m) => m.type == MediaType.audio).length} audio',
                                    color: Colors.purple,
                                  ),
                                  if (totalBytesResult > 0)
                                    _CaptureStatChip(
                                      icon: Icons.storage,
                                      label: _sizeText(totalBytesResult),
                                      color: Colors.blueGrey,
                                    ),
                                  _CaptureStatChip(
                                    icon: Icons.visibility_off,
                                    label: '${captureResult.hiddenCount} filtered',
                                    color: Colors.grey,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SliverToBoxAdapter(child: SizedBox(height: 12)),
                        if (filteredGroups.isEmpty)
                          SliverFillRemaining(
                            hasScrollBody: false,
                            child: Center(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text(
                                  'No media detected on this page.\nTry playing a video or scrolling further.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: ctx.ac.textSecondary,
                                  ),
                                ),
                              ),
                            ),
                          )
                        else
                          SliverPadding(
                            padding: const EdgeInsets.only(bottom: 80),
                            sliver: SliverList(
                              delegate: SliverChildBuilderDelegate(
                                (context, index) {
                                  final group = filteredGroups[index];
                                  final item = group.primary.media;
                                  final isSelected = mediaCatchController
                                      .selectedIndices
                                      .contains(index);
                                  final hls = _isHlsItem(item);
                                  final accentColor = _accentFor(item, hls);
                                  final qLabel = group.primary.qualityLabel;
                                  final sizeLabel =
                                      _sizeText(item.contentLengthBytes);
                                  final subtitleParts = <String>[];
                                  if (sizeLabel.isNotEmpty) {
                                    subtitleParts.add(sizeLabel);
                                  }
                                  if (item.width != null && item.height != null) {
                                    subtitleParts.add('${item.width}x${item.height}');
                                  }
                                  if (item.duration != null && item.duration!.inSeconds > 0) {
                                    subtitleParts.add(_formatDuration(item.duration!));
                                  }
                                  if (hls) {
                                    subtitleParts.add('HLS');
                                  } else if (item.contentType != null && item.contentType!.isNotEmpty) {
                                    subtitleParts.add(item.contentType!.split(';').first.trim());
                                  }
                                  final subtitleText = subtitleParts.join(' \u00B7 ');

                                  return Padding(
                                    key: Key('sniffed_item_$index'),
                                    padding: const EdgeInsets.fromLTRB(
                                      12,
                                      3,
                                      12,
                                      3,
                                    ),
                                    child: Container(
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          colors: [
                                            context.ac.gradientMid,
                                            context.ac.surfacePanel,
                                          ],
                                          begin: Alignment.topLeft,
                                          end: Alignment.bottomRight,
                                        ),
                                        borderRadius:
                                            BorderRadius.circular(12),
                                        border: Border.all(
                                          color: isSelected
                                              ? context.ac.accentFrost
                                              : context.ac.glassBorder,
                                          width: isSelected ? 2.0 : 1.0,
                                        ),
                                        boxShadow: isSelected
                                            ? [
                                                BoxShadow(
                                                  color: context.ac.accentFrost
                                                      .withValues(alpha: 0.25),
                                                  blurRadius: 6,
                                                ),
                                              ]
                                            : null,
                                      ),
                                      child: ClipRRect(
                                        borderRadius:
                                            BorderRadius.circular(11),
                                        child: Material(
                                          color: Colors.transparent,
                                          child: InkWell(
                                            onTap: () => onInfo(
                                              parentContext,
                                              item,
                                            ),
                                            child: Padding(
                                              padding:
                                                  const EdgeInsets.all(8),
                                              child: Row(
                                                children: [
                                                  Checkbox(
                                                    value: isSelected,
                                                    activeColor: Colors.teal,
                                                    checkColor:
                                                        Colors.white,
                                                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                                    visualDensity: VisualDensity.compact,
                                                    onChanged: (v) {
                                                      setSheetState(() {
                                                        mediaCatchController
                                                            .toggleSelection(
                                                          index,
                                                        );
                                                      });
                                                    },
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Container(
                                                    width: 40,
                                                    height: 40,
                                                    decoration:
                                                        BoxDecoration(
                                                      color: accentColor
                                                          .withValues(
                                                        alpha: 0.15,
                                                      ),
                                                      borderRadius:
                                                          BorderRadius
                                                              .circular(10),
                                                    ),
                                                    child: Icon(
                                                      _mediaIcon(item.type),
                                                      color: accentColor,
                                                      size: 22,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 12),
                                                  Expanded(
                                                    child: Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      children: [
                                                        Row(
                                                          children: [
                                                            Flexible(
                                                              child: Text(
                                                                item.name
                                                                        .isNotEmpty
                                                                    ? item
                                                                        .name
                                                                    : 'Unknown media',
                                                                maxLines: 1,
                                                                overflow:
                                                                    TextOverflow
                                                                        .ellipsis,
                                                                  style:
                                                                      TextStyle(
                                                                    color: context
                                                                        .ac
                                                                        .textPrimary,
                                                                    fontSize:
                                                                        13,
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .w600,
                                                                  ),
                                                              ),
                                                            ),
                                                            const SizedBox(
                                                                width: 6),
                                                            if (qLabel !=
                                                                    null &&
                                                                qLabel
                                                                    .isNotEmpty &&
                                                                qLabel != 'HLS')
                                                              Container(
                                                                padding: const EdgeInsets
                                                                    .symmetric(
                                                                  horizontal:
                                                                      5,
                                                                  vertical:
                                                                      1,
                                                                ),
                                                                decoration:
                                                                    BoxDecoration(
                                                                  color: Colors
                                                                      .tealAccent
                                                                      .withValues(
                                                                          alpha:
                                                                              0.15),
                                                                  borderRadius:
                                                                      BorderRadius
                                                                          .circular(
                                                                              4),
                                                                ),
                                                                child: Text(
                                                                  qLabel,
                                                                  style:
                                                                      const TextStyle(
                                                                    color: Colors
                                                                        .tealAccent,
                                                                    fontSize:
                                                                        10,
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .bold,
                                                                  ),
                                                                ),
                                                              ),
                                                          ],
                                                        ),
                                                        const SizedBox(
                                                            height: 4),
                                                        if (subtitleText.isNotEmpty)
                                                          Text(
                                                            subtitleText,
                                                            style: TextStyle(
                                                                color: context
                                                                    .ac
                                                                    .textSecondary,
                                                                fontSize: 11),
                                                          ),
                                                      ],
                                                    ),
                                                  ),
                                                  const SizedBox(width: 4),
                                                  if (item.type ==
                                                          MediaType.video ||
                                                      item.type ==
                                                          MediaType.audio ||
                                                      item.type ==
                                                          MediaType.image) ...[
                                                    IconButton(
                                                      key: Key(
                                                          'preview_item_$index'),
                                                      padding: EdgeInsets.zero,
                                                      constraints: const BoxConstraints(
                                                        minWidth: 28,
                                                        minHeight: 28,
                                                      ),
                                                      visualDensity: VisualDensity.compact,
                                                      icon: const Icon(
                                                        Icons
                                                            .play_circle_outline,
                                                        size: 18,
                                                      ),
                                                      color: context
                                                          .ac
                                                          .accentFrost,
                                                      tooltip: 'Preview item',
                                                      onPressed: () {
                                                        Navigator.pop(ctx);
                                                        onPreview(item);
                                                      },
                                                    ),
                                                    const SizedBox(width: 4),
                                                  ],
                                                  IconButton(
                                                    key: Key(
                                                        'download_item_$index'),
                                                    padding: EdgeInsets.zero,
                                                    constraints: const BoxConstraints(
                                                      minWidth: 28,
                                                      minHeight: 28,
                                                    ),
                                                    visualDensity: VisualDensity.compact,
                                                    icon: const Icon(
                                                      Icons.download,
                                                      size: 18,
                                                    ),
                                                    color: Colors.teal,
                                                    tooltip: 'Download this',
                                                    onPressed: () {
                                                      Navigator.pop(ctx);
                                                      onAddToQueue(
                                                        parentContext,
                                                        item,
                                                        variants: group
                                                            .candidates
                                                            .map((c) =>
                                                                c.media)
                                                            .toList(),
                                                      );
                                                    },
                                                  ),
                                                  const SizedBox(width: 4),
                                                  IconButton(
                                                    key: Key(
                                                        'info_item_$index'),
                                                    padding: EdgeInsets.zero,
                                                    constraints: const BoxConstraints(
                                                      minWidth: 28,
                                                      minHeight: 28,
                                                    ),
                                                    visualDensity: VisualDensity.compact,
                                                    icon: const Icon(
                                                      Icons.info_outline,
                                                      size: 18,
                                                    ),
                                                    color: context
                                                        .ac
                                                        .textSecondary,
                                                    tooltip: 'Details',
                                                    onPressed: () => onInfo(
                                                      parentContext,
                                                      item,
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
                                },
                                childCount: filteredGroups.length,
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                );
              },
            ),
          );
        },
      );
    },
  );
}

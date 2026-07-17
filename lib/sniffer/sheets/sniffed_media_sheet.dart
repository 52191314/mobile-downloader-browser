// Standalone library — Capture sheet orchestrator.
// Visual chrome lives under `lib/sniffer/capture/`. Selection semantics and
// the displayedGroups pipeline come from PR1.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:aurora_downloader/settings/download_settings.dart';
import 'package:aurora_downloader/sniffer/capture/capture_batch_bar.dart';
import 'package:aurora_downloader/sniffer/capture/capture_empty_state.dart';
import 'package:aurora_downloader/sniffer/capture/capture_filter_bar.dart';
import 'package:aurora_downloader/sniffer/capture/capture_group_sort.dart';
import 'package:aurora_downloader/sniffer/capture/capture_media_row.dart';
import 'package:aurora_downloader/sniffer/capture/capture_options_row.dart';
import 'package:aurora_downloader/sniffer/capture/capture_sheet_header.dart';
import 'package:aurora_downloader/sniffer/capture/capture_stats_row.dart';
import 'package:aurora_downloader/sniffer/capture/media_accent.dart';
import 'package:aurora_downloader/sniffer/capture/media_filter.dart';
import 'package:aurora_downloader/sniffer/controllers/media_catch_controller.dart';
import 'package:aurora_downloader/sniffer/media_capture_analyzer.dart';
import 'package:aurora_downloader/sniffer/models/browser_tab.dart';
import 'package:aurora_downloader/sniffer/models/sniffed_media.dart';
import 'package:aurora_downloader/theme/aurora_palette.dart';

export 'package:aurora_downloader/sniffer/capture/media_filter.dart';

/// Lightweight StatefulWidget that subscribes to a [Stream<SniffedMedia>]
/// and triggers a rebuild of the outer [StatefulBuilder] whenever the
/// stream emits.
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

/// Inverse of [_mediaTypeForFilter] — seeds the segmented control from
/// the controller's persisted `activeFilter`.
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

int _totalBytes(Iterable<SniffedMedia> list) {
  return list.fold<int>(0, (s, m) => s + (m.contentLengthBytes ?? 0));
}

/// Shows the rich caught-media bottom sheet for [activeTab].
///
/// [onAddToQueue] is awaitable and returns `true` when the user confirmed
/// enqueue (or dialog completed as success), `false` on cancel — batch
/// download stops the sequential loop on `false` (KD13 / KD23).
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
  required Future<bool> Function(
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
    backgroundColor: context.ac.surfacePanel,
    builder: (ctx) {
      MediaFilter currentSegment = _filterForMediaType(
        mediaCatchController.activeFilter,
      );
      // Local mirror so dropdowns, display mode, and group sort update
      // immediately. Host settings are written via onSettingsChanged for
      // persistence only (list order uses sheetSettings, not host sortMedia).
      var sheetSettings = settings;

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
                // --- Gather & analyse media (single pipeline) ---
                // Flat sortMedia is optional pre-order; analyzer re-orders by
                // confidence, so displayedGroups are re-sorted below by
                // sheetSettings.sniffedMediaSort (Issue 1 / KD25).
                final allMedia = sortMedia(tab.snifferEngine.detectedMedia)
                    .where((m) => !m.isShortClip)
                    .toList();

                final captureResult = mediaCatchController.analyze(allMedia);

                mediaCatchController.activeFilter =
                    _mediaTypeForFilter(currentSegment);

                var displayedGroups = mediaCatchController.filteredGroups(
                  captureResult.groups,
                );

                if (currentSegment == MediaFilter.hls) {
                  displayedGroups = displayedGroups
                      .where(
                        (g) =>
                            isHlsMedia(g.primary.media) ||
                            g.candidates.any((c) => isHlsMedia(c.media)),
                      )
                      .toList(growable: false);
                }

                // User Sort by — after analyzer confidence + type/HLS filters.
                displayedGroups = sortCaptureGroups(
                  displayedGroups,
                  sheetSettings.sniffedMediaSort,
                );

                final selectedCount = mediaCatchController.selectedCount(
                  displayedGroups.length,
                );
                final totalBytesResult = _totalBytes(allMedia);
                final videoCount =
                    allMedia.where((m) => m.type == MediaType.video).length;
                final audioCount =
                    allMedia.where((m) => m.type == MediaType.audio).length;

                Future<void> runBatchDownload(
                  List<CaptureGroup> selected,
                ) async {
                  if (selected.isEmpty) return;
                  Navigator.pop(ctx);
                  for (final group in selected) {
                    if (!parentContext.mounted) break;
                    final ok = await onAddToQueue(
                      parentContext,
                      group.primary.media,
                      variants:
                          group.candidates.map((c) => c.media).toList(),
                    );
                    if (!ok) break;
                  }
                }

                // IMPORTANT: with isScrollControlled bottom sheets, DSS needs a
                // finite-height parent. Column+Expanded inside expand:false DSS
                // collapses to ~0 height (empty white/black sheet). Give the
                // sheet the full screen height and expand:true so the Column
                // receives bounded constraints (sticky batch bar still works).
                final sheetHeight = MediaQuery.sizeOf(ctx).height;
                return SizedBox(
                  height: sheetHeight,
                  child: DraggableScrollableSheet(
                    initialChildSize: 0.90,
                    minChildSize: 0.30,
                    maxChildSize: 1.0,
                    snap: true,
                    snapSizes: const [0.3, 0.5, 0.9, 1.0],
                    expand: true,
                    builder: (scrollCtx, scrollController) {
                      return Material(
                        color: scrollCtx.ac.surfacePanel,
                        child: Column(
                          children: [
                            Expanded(
                              child: CustomScrollView(
                                key: const Key('sniffer_drawer'),
                                controller: scrollController,
                                physics: const ClampingScrollPhysics(),
                                slivers: [
                              SliverToBoxAdapter(
                                child: CaptureSheetHeader(
                                  totalShown: displayedGroups.length,
                                  selectedCount: selectedCount,
                                  onSelectBest: () {
                                    setSheetState(() {
                                      mediaCatchController.clearSelection();
                                      mediaCatchController.selectedIndices
                                          .addAll(
                                        mediaCatchController
                                            .recommendedGroupIndices(
                                          displayedGroups,
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
                                child: CaptureFilterBar(
                                  current: currentSegment,
                                  onSelected: (v) {
                                    setSheetState(() {
                                      currentSegment = v;
                                      mediaCatchController.clearSelection();
                                    });
                                  },
                                ),
                              ),
                              // Options zone — show-all + sort + display mode (PR5 / KD25–26).
                              SliverToBoxAdapter(
                                child: CaptureOptionsRow(
                                  settings: sheetSettings,
                                  showAll:
                                      mediaCatchController.captureShowAllMedia,
                                  onShowAllChanged: (value) {
                                    setSheetState(() {
                                      mediaCatchController.captureShowAllMedia =
                                          value;
                                      mediaCatchController.clearSelection();
                                      sheetSettings = sheetSettings.copyWith(
                                        captureShowAllMedia: value,
                                      );
                                    });
                                    onSettingsChanged?.call(sheetSettings);
                                  },
                                  onSettingsChanged: (next) {
                                    // Immediate rebuild uses sheetSettings for
                                    // sort + display mode; persist async via host.
                                    setSheetState(() {
                                      sheetSettings = next;
                                    });
                                    onSettingsChanged?.call(next);
                                  },
                                ),
                              ),
                              const SliverToBoxAdapter(
                                child: SizedBox(height: 4),
                              ),
                              SliverToBoxAdapter(
                                child: CaptureStatsRow(
                                  foundCount: allMedia.length,
                                  videoCount: videoCount,
                                  audioCount: audioCount,
                                  totalBytes: totalBytesResult,
                                  filteredCount: captureResult.hiddenCount,
                                ),
                              ),
                              SliverToBoxAdapter(
                                child: Padding(
                                  padding: const EdgeInsets.only(
                                    top: 8,
                                    bottom: 4,
                                  ),
                                  child: Divider(
                                    height: 1,
                                    thickness: 1,
                                    color: context.ac.borderHairline,
                                  ),
                                ),
                              ),
                              if (displayedGroups.isEmpty)
                                SliverFillRemaining(
                                  hasScrollBody: false,
                                  child: CaptureEmptyState(onRescan: onRescan),
                                )
                              else
                                SliverPadding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  sliver: SliverList(
                                    delegate: SliverChildBuilderDelegate(
                                      (context, index) {
                                        final group = displayedGroups[index];
                                        final item = group.primary.media;
                                        final isSelected = mediaCatchController
                                            .selectedIndices
                                            .contains(index);
                                        final canPreview = item.type ==
                                                MediaType.video ||
                                            item.type == MediaType.audio ||
                                            item.type == MediaType.image;

                                        return CaptureMediaRow(
                                          index: index,
                                          group: group,
                                          selected: isSelected,
                                          displayMode: sheetSettings
                                              .sniffedMediaDisplayMode,
                                          onSelectedChanged: (_) {
                                            setSheetState(() {
                                              mediaCatchController
                                                  .toggleSelection(index);
                                            });
                                          },
                                          onPreview: canPreview
                                              ? () {
                                                  Navigator.pop(ctx);
                                                  onPreview(item);
                                                }
                                              : null,
                                          onDownload: () {
                                            Navigator.pop(ctx);
                                            unawaited(
                                              onAddToQueue(
                                                parentContext,
                                                item,
                                                variants: group.candidates
                                                    .map((c) => c.media)
                                                    .toList(),
                                              ),
                                            );
                                          },
                                          onInfo: () =>
                                              onInfo(parentContext, item),
                                        );
                                      },
                                      childCount: displayedGroups.length,
                                    ),
                                  ),
                                ),
                                ],
                              ),
                            ),
                            if (selectedCount > 0)
                              CaptureBatchBar(
                                selectedCount: selectedCount,
                                totalCount: displayedGroups.length,
                                onToggleSelectAll: () {
                                  setSheetState(() {
                                    final allSelected = selectedCount ==
                                        displayedGroups.length;
                                    if (allSelected) {
                                      mediaCatchController.clearSelection();
                                    } else {
                                      mediaCatchController
                                          .selectAll(displayedGroups.length);
                                    }
                                  });
                                },
                                onDownloadSelected: () {
                                  final selected =
                                      mediaCatchController.selectedFrom(
                                    displayedGroups,
                                  );
                                  unawaited(runBatchDownload(selected));
                                },
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          );
        },
      );
    },
  );
}

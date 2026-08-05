// Standalone library — Capture sheet orchestrator.
// Visual chrome lives under `lib/sniffer/capture/`.

import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';

import 'package:aurora_downloader/premium/free_taste.dart';
import 'package:aurora_downloader/premium/pro_entitlement.dart';
import 'package:aurora_downloader/premium/pro_features.dart';
import 'package:aurora_downloader/premium/pro_upsell_sheet.dart';
import 'package:aurora_downloader/premium/upsell_controller.dart';
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
import 'package:aurora_downloader/sniffer/controllers/sniff_intake_controller.dart';
import 'package:aurora_downloader/sniffer/media_capture_analyzer.dart';
import 'package:aurora_downloader/sniffer/models/browser_tab.dart';
import 'package:aurora_downloader/sniffer/models/sniffed_media.dart';
import 'package:aurora_downloader/sniffer/series_grab_detector.dart';
import 'package:aurora_downloader/theme/aurora_palette.dart';

export 'package:aurora_downloader/sniffer/capture/media_filter.dart';

/// The page's `og:image`, but only when it is a fair stand-in for a capture's
/// own poster — that is, when the page holds exactly one playable capture.
///
/// On a watch page the artwork really is the video's own frame, and is the best
/// thumbnail available when the element carries no `poster` attribute. On a
/// gallery page it is the site's social card, which belongs to none of the
/// files listed; painting it on every row produced a column of identical
/// images that read as a rendering fault rather than a thumbnail.
///
/// Groups are the right unit to count: HLS variants of one stream collapse into
/// a single group, so a watch page offering 240p–4K still counts as one.
@visibleForTesting
String? pagePosterFor(List<CaptureGroup> groups, String? ogImage) {
  final poster = ogImage?.trim();
  if (poster == null || poster.isEmpty) return null;

  var playable = 0;
  for (final group in groups) {
    final type = group.primary.media.type;
    if (type == MediaType.video ||
        type == MediaType.audio ||
        type == MediaType.playlist) {
      // Bail on the second one rather than counting the whole list.
      if (++playable > 1) return null;
    }
  }
  return playable == 1 ? poster : null;
}

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
/// [onAddToQueue] returns `true` when enqueue was confirmed, `false` on
/// cancel — batch download stops the sequential loop on `false`.
void showSniffedMediaSheet(
  BuildContext context, {
  required BrowserTab activeTab,
  required MediaCatchController mediaCatchController,
  required DownloadSettings settings,
  required ValueChanged<DownloadSettings>? onSettingsChanged,
  required bool isMounted,
  required VoidCallback onChanged,
  required List<SniffedMedia> Function(List<SniffedMedia> media) sortMedia,
  required void Function(
    SniffedMedia media, {
    List<SniffedMedia> variants,
  }) onPreview,
  required void Function(BuildContext context, SniffedMedia item) onInfo,
  required Future<bool> Function(
    BuildContext context,
    SniffedMedia media, {
    List<SniffedMedia> variants,
  }) onAddToQueue,
  required VoidCallback onRescan,
}) {
  if (!isMounted) return;
  mediaCatchController.clearSelection();

  developer.log('Capture sheet open', name: 'capture_sheet');

  // Fixed-height sheet (no DraggableScrollableSheet). DSS was collapsing or
  // flashing blank when TikTok's onMediaChanged stream rebuilt it every few
  // hundred ms. Fixed SizedBox + Column/Expanded is the stable pattern for
  // isScrollControlled modals.
  showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    isDismissible: true,
    enableDrag: true,
    backgroundColor: context.ac.surfacePanel,
    builder: (sheetContext) {
      return _CaptureSheetScaffold(
        activeTab: activeTab,
        mediaCatchController: mediaCatchController,
        settings: settings,
        onSettingsChanged: onSettingsChanged,
        sortMedia: sortMedia,
        onPreview: onPreview,
        onInfo: onInfo,
        onAddToQueue: onAddToQueue,
        onRescan: onRescan,
        parentContext: context,
      );
    },
  ).whenComplete(() {
    developer.log('Capture sheet closed', name: 'capture_sheet');
  });
}

/// Owns sheet local state + media-stream subscription so rebuilds do not
/// tear down a DraggableScrollableSheet (which caused flash-then-blank).
class _CaptureSheetScaffold extends StatefulWidget {
  const _CaptureSheetScaffold({
    required this.activeTab,
    required this.mediaCatchController,
    required this.settings,
    required this.onSettingsChanged,
    required this.sortMedia,
    required this.onPreview,
    required this.onInfo,
    required this.onAddToQueue,
    required this.onRescan,
    required this.parentContext,
  });

  final BrowserTab activeTab;
  final MediaCatchController mediaCatchController;
  final DownloadSettings settings;
  final ValueChanged<DownloadSettings>? onSettingsChanged;
  final List<SniffedMedia> Function(List<SniffedMedia> media) sortMedia;
  final void Function(
    SniffedMedia media, {
    List<SniffedMedia> variants,
  }) onPreview;
  final void Function(BuildContext context, SniffedMedia item) onInfo;
  final Future<bool> Function(
    BuildContext context,
    SniffedMedia media, {
    List<SniffedMedia> variants,
  }) onAddToQueue;
  final VoidCallback onRescan;
  final BuildContext parentContext;

  @override
  State<_CaptureSheetScaffold> createState() => _CaptureSheetScaffoldState();
}

class _CaptureSheetScaffoldState extends State<_CaptureSheetScaffold> {
  late MediaFilter _segment;
  late DownloadSettings _sheetSettings;
  StreamSubscription<SniffedMedia>? _mediaSub;
  Timer? _rebuildDebounce;
  Object? _buildError;

  /// True once the sheet has started closing (batch download / series grab
  /// double-tap guard — see [_enqueueGroups]).
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _segment = _filterForMediaType(widget.mediaCatchController.activeFilter);
    _sheetSettings = widget.settings;
    // Debounce stream rebuilds — TikTok can emit dozens of media events/sec.
    // Immediate setState on every event was rebuilding the whole sheet and
    // blanking it after the first paint.
    _mediaSub = widget.activeTab.snifferEngine.onMediaChanged.listen((_) {
      _rebuildDebounce?.cancel();
      _rebuildDebounce = Timer(const Duration(milliseconds: 250), () {
        if (mounted) setState(() {});
      });
    });
  }

  @override
  void dispose() {
    _rebuildDebounce?.cancel();
    _mediaSub?.cancel();
    super.dispose();
  }

  Future<void> _openOptions() {
    return showCaptureOptionsSheet(
      context,
      currentSettings: () => _sheetSettings,
      currentShowAll: () => widget.mediaCatchController.captureShowAllMedia,
      onShowAllChanged: (value) {
        setState(() {
          widget.mediaCatchController.captureShowAllMedia = value;
          widget.mediaCatchController.clearSelection();
          _sheetSettings = _sheetSettings.copyWith(captureShowAllMedia: value);
        });
        widget.onSettingsChanged?.call(_sheetSettings);
      },
      onSettingsChanged: (next) {
        setState(() => _sheetSettings = next);
        widget.onSettingsChanged?.call(next);
      },
    );
  }

  Future<void> _runBatchDownload(List<CaptureGroup> selected) async {
    if (selected.isEmpty) return;

    // P1 — free taste via FreeTaste softActionCap (first-N + upsell).
    final tier = proUpsellEntitlement?.tier ?? EntitlementTier.free;
    final decision = await FreeTaste.evaluate(
      feature: ProFeature.batchCapture,
      tier: tier,
      actionSize: selected.length,
    );
    if (!decision.allowed) {
      if (mounted) {
        unawaited(
          UpsellController.show(
            widget.parentContext,
            feature: ProFeature.batchCapture,
            userTier: tier,
          ),
        );
      }
      return;
    }

    var toEnqueue = selected;
    final cap = decision.allowedCount;
    if (cap != null && cap < selected.length) {
      toEnqueue = selected.take(cap).toList();
      if (mounted) {
        unawaited(
          UpsellController.show(
            widget.parentContext,
            feature: ProFeature.batchCapture,
            userTier: tier,
          ),
        );
      }
    }

    await _enqueueGroups(toEnqueue);
  }

  /// P2 series grab: order capture groups that look like episodes and enqueue
  /// with soft first-5 free taste.
  Future<void> _runSeriesGrab(List<CaptureGroup> displayedGroups) async {
    if (displayedGroups.isEmpty) return;

    final scored = <({CaptureGroup group, int order})>[];
    for (final group in displayedGroups) {
      final media = group.primary.media;
      final labels = <String>[
        media.name,
        media.url,
        if (media.pageTitle != null) media.pageTitle!,
      ];
      EpisodeLink? parsed;
      for (final label in labels) {
        if (label.trim().isEmpty) continue;
        parsed = parseEpisodeLink(label, media.url);
        if (parsed != null) break;
      }
      if (parsed != null) {
        scored.add((group: group, order: parsed.order));
      }
    }

    if (scored.length < 2) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No series pattern found in captured media '
            '(need titles like EP01, S01E02, 第1集).',
          ),
        ),
      );
      return;
    }

    scored.sort((a, b) => a.order.compareTo(b.order));
    var ordered = scored.map((e) => e.group).toList();
    if (ordered.length > seriesGrabSafetyMax) {
      ordered = ordered.take(seriesGrabSafetyMax).toList();
    }

    final tier = proUpsellEntitlement?.tier ?? EntitlementTier.free;
    final decision = await FreeTaste.evaluate(
      feature: ProFeature.seriesGrab,
      tier: tier,
      actionSize: ordered.length,
    );
    if (!decision.allowed) {
      if (mounted) {
        unawaited(
          UpsellController.show(
            widget.parentContext,
            feature: ProFeature.seriesGrab,
            userTier: tier,
          ),
        );
      }
      return;
    }

    var toEnqueue = ordered;
    final cap = decision.allowedCount;
    if (cap != null && cap < ordered.length) {
      toEnqueue = ordered.take(cap).toList();
      if (mounted) {
        unawaited(
          UpsellController.show(
            widget.parentContext,
            feature: ProFeature.seriesGrab,
            userTier: tier,
          ),
        );
      }
    }

    await _enqueueGroups(toEnqueue);
  }

  Future<void> _enqueueGroups(List<CaptureGroup> toEnqueue) async {
    // Guard: if this sheet is already being closed (double-tap on
    // "Download selected"/"Series grab" fires this twice before the first
    // pop lands), a second pop would eject an unrelated route below.
    if (_closing) return;
    _closing = true;
    final nav = Navigator.of(context);
    nav.pop();
    for (final group in toEnqueue) {
      if (!widget.parentContext.mounted) break;
      final ok = await widget.onAddToQueue(
        widget.parentContext,
        group.primary.media,
        variants: group.candidates.map((c) => c.media).toList(),
      );
      if (!ok) break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final screenH = MediaQuery.sizeOf(context).height;
    // useSafeArea already inset the modal; take most of remaining height.
    final sheetH = screenH * 0.88;

    List<CaptureGroup> displayedGroups = const [];
    String? pagePoster;
    var selectedCount = 0;
    var allMedia = <SniffedMedia>[];
    var videoCount = 0;
    var audioCount = 0;
    var totalBytes = 0;
    var filteredCount = 0;

    try {
      allMedia = widget
          .sortMedia(widget.activeTab.snifferEngine.detectedMedia)
          .where((m) => !m.isShortClip)
          .toList();

      final captureResult = widget.mediaCatchController.analyze(allMedia);
      filteredCount = captureResult.hiddenCount;

      // Judged against the unfiltered groups, so switching the filter tabs
      // cannot turn thumbnails on and off under the user.
      pagePoster = pagePosterFor(
        captureResult.groups,
        widget.activeTab.pageMeta.ogImage,
      );

      widget.mediaCatchController.activeFilter = _mediaTypeForFilter(_segment);

      displayedGroups = widget.mediaCatchController.filteredGroups(
        captureResult.groups,
      );

      if (_segment == MediaFilter.hls) {
        displayedGroups = displayedGroups
            .where(
              (g) =>
                  isHlsMedia(g.primary.media) ||
                  g.candidates.any((c) => isHlsMedia(c.media)),
            )
            .toList(growable: false);
      }

      displayedGroups = sortCaptureGroups(
        displayedGroups,
        _sheetSettings.sniffedMediaSort,
      );

      selectedCount = widget.mediaCatchController.selectedCount(
        displayedGroups.length,
      );
      totalBytes = _totalBytes(allMedia);
      videoCount = allMedia.where((m) => m.type == MediaType.video).length;
      audioCount = allMedia.where((m) => m.type == MediaType.audio).length;
      _buildError = null;
    } catch (e, st) {
      _buildError = e;
      developer.log(
        'Capture sheet build failed: $e',
        name: 'capture_sheet',
        error: e,
        stackTrace: st,
      );
    }

    if (_buildError != null) {
      return SizedBox(
        height: sheetH,
        child: Material(
          color: ac.surfacePanel,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline, color: ac.statusError, size: 40),
                  const SizedBox(height: 12),
                  Text(
                    'Capture sheet error',
                    style: TextStyle(
                      color: ac.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '$_buildError',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: ac.textSecondary, fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: () => setState(() {}),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: sheetH,
      child: Material(
        color: ac.surfacePanel,
        child: Column(
          children: [
            Expanded(
              child: CustomScrollView(
                key: const Key('sniffer_drawer'),
                physics: const ClampingScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(
                    child: CaptureSheetHeader(
                      totalShown: displayedGroups.length,
                      selectedCount: selectedCount,
                      onSelectBest: () {
                        setState(() {
                          widget.mediaCatchController.clearSelection();
                          widget.mediaCatchController.selectedIndices.addAll(
                            widget.mediaCatchController.recommendedGroupIndices(
                              displayedGroups,
                            ),
                          );
                        });
                      },
                      onDownloadSelected: () {
                        final selected =
                            widget.mediaCatchController.selectedFrom(
                          displayedGroups,
                        );
                        unawaited(_runBatchDownload(selected));
                      },
                      onSeriesGrab: displayedGroups.isEmpty
                          ? null
                          : () => unawaited(
                                _runSeriesGrab(displayedGroups),
                              ),
                      onRescan: widget.onRescan,
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: CaptureFilterBar(
                      current: _segment,
                      onSelected: (v) {
                        setState(() {
                          _segment = v;
                          widget.mediaCatchController.clearSelection();
                        });
                      },
                      optionsActive:
                          captureOptionsAreCustomised(_sheetSettings),
                      onOpenOptions: _openOptions,
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: CaptureStatsRow(
                      foundCount: allMedia.length,
                      videoCount: videoCount,
                      audioCount: audioCount,
                      totalBytes: totalBytes,
                      filteredCount: filteredCount,
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 4),
                      child: Divider(
                        height: 1,
                        thickness: 1,
                        color: ac.borderHairline,
                      ),
                    ),
                  ),
                  if (displayedGroups.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: CaptureEmptyState(onRescan: widget.onRescan),
                    )
                  else
                    SliverPadding(
                      padding: EdgeInsets.only(
                        bottom: selectedCount > 0 ? 8 : 16,
                      ),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (rowCtx, index) {
                            final group = displayedGroups[index];
                            final item = group.primary.media;
                            final isSelected = widget
                                .mediaCatchController.selectedIndices
                                .contains(index);
                            final canPreview = item.type == MediaType.video ||
                                item.type == MediaType.audio ||
                                item.type == MediaType.image;

                            return CaptureMediaRow(
                              index: index,
                              group: group,
                              selected: isSelected,
                              displayMode:
                                  _sheetSettings.sniffedMediaDisplayMode,
                              // Page artwork suits playable media only — an
                              // og:image stamped on a sniffed PDF or zip would
                              // just be mislabelling it.
                              pagePoster:
                                  SniffIntakeController.acceptsPageLevelPoster(
                                item.url,
                                item.contentType,
                              )
                                      ? pagePoster
                                      : null,
                              onSelectedChanged: (_) {
                                setState(() {
                                  widget.mediaCatchController
                                      .toggleSelection(index);
                                });
                              },
                              onPreview: canPreview
                                  ? () {
                                      Navigator.of(context).pop();
                                      // Pass sibling candidates so the player
                                      // quality picker covers the whole group.
                                      widget.onPreview(
                                        item,
                                        variants: group.candidates
                                            .map((c) => c.media)
                                            .toList(growable: false),
                                      );
                                    }
                                  : null,
                              onInfo: () =>
                                  widget.onInfo(widget.parentContext, item),
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
                  setState(() {
                    final allSelected =
                        selectedCount == displayedGroups.length;
                    if (allSelected) {
                      widget.mediaCatchController.clearSelection();
                    } else {
                      widget.mediaCatchController
                          .selectAll(displayedGroups.length);
                    }
                  });
                },
                onDownloadSelected: () {
                  final selected = widget.mediaCatchController.selectedFrom(
                    displayedGroups,
                  );
                  unawaited(_runBatchDownload(selected));
                },
              ),
          ],
        ),
      ),
    );
  }
}

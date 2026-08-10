import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../downloader/downloader.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/aurora_palette.dart';
import '../../theme/aurora_tokens.dart';
import 'download_properties_dialog.dart';
import 'edge_swipe_card.dart';
import 'settings_formatters.dart';

/// Determines the [FileCategory] for a [DownloadTask] by inspecting
/// its URL, content type, and filename extension.
FileCategory categoryForTask(DownloadTask task) {
  // 1) Magnet → torrent
  if (task.url.startsWith('magnet:')) return FileCategory.torrents;

  // 2) URL path hints (.m3u8 / .mpd → video)
  final urlLower = task.url.toLowerCase();
  if (urlLower.contains('.m3u8') || urlLower.contains('.mpd')) {
    return FileCategory.videos;
  }

  // 3) Content type → MIME → category
  if (task.contentType != null && task.contentType!.isNotEmpty) {
    final cleanMime = task.contentType!.split(';').first.trim().toLowerCase();
    if (cleanMime == 'application/vnd.apple.mpegurl' ||
        cleanMime == 'application/x-mpegurl' ||
        cleanMime == 'application/dash+xml') {
      return FileCategory.videos;
    }
    final cat = MediaFileTypes.categoryForExtension(
      MediaFileTypes.extensionForMime(cleanMime),
    );
    if (cat != FileCategory.other) return cat;
  }

  // 4) Extension from task display name
  final name = taskDisplayName(task);
  final dotIdx = name.lastIndexOf('.');
  if (dotIdx > 0) {
    final ext = name.substring(dotIdx).toLowerCase();
    final cat = MediaFileTypes.categoryForExtension(ext);
    if (cat != FileCategory.other) return cat;
  }

  // 5) Extension from URL
  final parsedUri = Uri.tryParse(task.url);
  if (parsedUri != null && parsedUri.pathSegments.isNotEmpty) {
    final lastSeg = parsedUri.pathSegments.last;
    final lastDot = lastSeg.lastIndexOf('.');
    if (lastDot > 0) {
      final ext = lastSeg.substring(lastDot).toLowerCase();
      final cat = MediaFileTypes.categoryForExtension(ext);
      if (cat != FileCategory.other) return cat;
    }
  }

  return FileCategory.other;
}

/// Maps [FileCategory] to a Material icon for the queue card glyph.
IconData iconForCategory(FileCategory c) {
  switch (c) {
    case FileCategory.videos:
      return Icons.movie_outlined;
    case FileCategory.audio:
      return Icons.audiotrack;
    case FileCategory.images:
      return Icons.image_outlined;
    case FileCategory.documents:
      return Icons.description_outlined;
    case FileCategory.archives:
      return Icons.folder_zip_outlined;
    case FileCategory.torrents:
      return Icons.share;
    case FileCategory.subtitles:
      return Icons.subtitles_outlined;
    case FileCategory.playlists:
    case FileCategory.applications:
    case FileCategory.other:
      return Icons.insert_drive_file_outlined;
  }
}

/// Single queue list/grid card. Owns presentation, HoldSwipeCard (when
/// enabled), primary button, and overflow menu construction. Parent owns
/// engine calls and destructive undo orchestration via callbacks.
class DownloadCard extends StatelessWidget {
  const DownloadCard({
    super.key,
    required this.task,
    required this.onOpenDownload,
    this.onPause,
    this.onResume,
    this.onRetry,
    this.onCancel,
    this.onForceMerge,
    this.onResniffAuto,
    this.onResniffManual,
    this.onOpenUrlInBrowser,
    this.onShare,
    this.onSendToPc,
    this.onMoveToVault,
    this.onRedownload,
    this.onOpenFfmpegStudio,
    this.onSchedule,
    this.selectionMode = false,
    this.selected = false,
    this.onToggleSelected,
    this.onSelectRange,
    this.enableSwipe = true,
    this.dense = false,
    this.progressListenable,
  });

  final DownloadTask task;

  /// Live per-task notifier (P1b). When provided, the progress-dependent
  /// section (progress bar, percent, bytes/speed/ETA line, status message)
  /// rebuilds from this notifier's value on every tick instead of the whole
  /// card waiting for a page rebuild. Null = card is fully static.
  final ValueListenable<DownloadTask>? progressListenable;

  final Future<void> Function(DownloadTask task) onOpenDownload;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onRetry;
  final VoidCallback? onCancel;
  final VoidCallback? onForceMerge;
  final Future<void> Function(DownloadTask task)? onResniffAuto;
  final Future<void> Function(DownloadTask task)? onResniffManual;
  final void Function(String url)? onOpenUrlInBrowser;
  final Future<void> Function(DownloadTask task)? onShare;
  /// Send the completed file to a PC over the local network (P6).
  final Future<void> Function(DownloadTask task)? onSendToPc;
  /// Move to Private Vault (P7).
  final Future<void> Function(DownloadTask task)? onMoveToVault;
  /// Start a fresh download of the same URL (new queue entry).
  final Future<void> Function(DownloadTask task)? onRedownload;
  /// Process or edit completed file in FFmpeg Studio.
  final Future<void> Function(DownloadTask task)? onOpenFfmpegStudio;
  final void Function(DownloadTask task, DateTime startAt)? onSchedule;

  final bool selectionMode;
  final bool selected;
  final VoidCallback? onToggleSelected;
  final VoidCallback? onSelectRange;

  final bool enableSwipe;
  final bool dense;

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Color _statusColor(AColors ac) {
    switch (task.state) {
      case DownloadState.downloading:
      case DownloadState.idle:
        return ac.accentFrost;
      case DownloadState.scheduled:
        return ac.accentPurple;
      case DownloadState.paused:
        return ac.accentAmber;
      case DownloadState.completed:
        return ac.statusSuccess;
      case DownloadState.failed:
        return ac.statusError;
      case DownloadState.merging:
        return Colors.orange;
    }
  }

  String _displayErrorMessage(String raw) {
    var msg = raw.replaceAll(RegExp(r'\[PARTIAL:[\d.]+\]\s*'), '').trim();
    if (msg.contains('\n')) {
      msg = msg.split('\n').first.trim();
    }
    final prefixes = [
      'Exception: ',
      'SocketException: ',
      'HttpException: ',
      'FileSystemException: ',
      'FormatException: ',
      'DioException [unknown]: ',
    ];
    for (final p in prefixes) {
      if (msg.startsWith(p)) {
        msg = msg.substring(p.length).trim();
      }
    }
    return msg;
  }

  String _metadataLabel(DownloadTask t, AppLocalizations l10n) {
    final parts = <String>[];
    if (t.state == DownloadState.scheduled) {
      if (t.scheduledStartAt != null) {
        final diff = t.scheduledStartAt!.difference(DateTime.now());
        if (diff.isNegative) {
          parts.add(l10n.cardStatusStarting);
        } else {
          String pad(int n) => n.toString().padLeft(2, '0');
          if (diff.inDays > 1) {
            parts.add('Scheduled ${pad(t.scheduledStartAt!.hour)}:${pad(t.scheduledStartAt!.minute)} '
                '${t.scheduledStartAt!.month}/${t.scheduledStartAt!.day}');
          } else {
            parts.add('Scheduled ${pad(t.scheduledStartAt!.hour)}:${pad(t.scheduledStartAt!.minute)}');
          }
          if (diff.inMinutes < 60) {
            parts.add('${diff.inMinutes}m left');
          } else if (diff.inHours < 24) {
            parts.add('${diff.inHours}h ${diff.inMinutes % 60}m left');
          }
        }
      } else {
        parts.add(l10n.cardStatusScheduled);
      }
    } else if (t.state == DownloadState.downloading ||
        t.state == DownloadState.idle) {
      if (t.totalBytes > 0) {
        final totalLabel = t.downloadedBytes > t.totalBytes
            ? '~${formatBytes(t.downloadedBytes)}+'
            : formatBytes(t.totalBytes);
        parts.add(
          '${formatBytes(t.downloadedBytes)} / $totalLabel',
        );
      } else if (t.downloadedBytes > 0) {
        parts.add('${formatBytes(t.downloadedBytes)} ${l10n.cardStatusDownloaded}');
      }
      parts.add(formatSpeed(t.speed));
      // ETA: for HLS prefer remaining parts × avg speed when total bytes lag.
      if (t.speed > 0) {
        if (t.totalParts > 0 &&
            t.completedParts < t.totalParts &&
            t.completedParts > 0 &&
            t.downloadedBytes > 0) {
          final avgPerPart = t.downloadedBytes / t.completedParts;
          final remainBytes =
              ((t.totalParts - t.completedParts) * avgPerPart).round();
          final eta = formatEta(
            downloadedBytes: 0,
            totalBytes: remainBytes,
            speedEmaBytesPerSec: t.speed,
          );
          if (eta != null) parts.add(eta);
        } else if (t.totalBytes > 0 &&
            t.downloadedBytes < t.totalBytes) {
          final eta = formatEta(
            downloadedBytes: t.downloadedBytes,
            totalBytes: t.totalBytes,
            speedEmaBytesPerSec: t.speed,
          );
          if (eta != null) parts.add(eta);
        }
      }
      final elapsed = DateTime.now().difference(t.createdAt);
      final m = elapsed.inMinutes;
      final s = elapsed.inSeconds % 60;
      parts.add('${m}m ${s}s');
    } else if (t.state == DownloadState.completed && t.totalBytes > 0) {
      parts.add(formatBytes(t.totalBytes));
    } else if (t.state == DownloadState.completed && t.downloadedBytes > 0) {
      parts.add('${formatBytes(t.downloadedBytes)} ${l10n.cardStatusDownloaded}');
    } else if (t.state == DownloadState.failed) {
      if (t.downloadedBytes > 0) {
        parts.add('${formatBytes(t.downloadedBytes)} ${l10n.cardStatusSaved}');
      }
      parts.add(l10n.cardStatusFailed);
    } else if (t.state == DownloadState.paused) {
      if (t.totalBytes > 0) {
        parts.add('${formatBytes(t.downloadedBytes)} / ${formatBytes(t.totalBytes)}');
      } else if (t.downloadedBytes > 0) {
        parts.add('${formatBytes(t.downloadedBytes)} ${l10n.cardStatusDownloaded}');
      }
      parts.add(l10n.cardStatusPaused);
    } else if (t.state == DownloadState.merging) {
      if (t.totalBytes > 0 && t.downloadedBytes > 0) {
        parts.add('${l10n.cardStatusMerging} ${t.downloadedBytes}/${t.totalBytes}');
      } else {
        parts.add(l10n.cardStatusMerging);
      }
    }
    return parts.join(' · ');
  }

  /// Renders the task filename with middle-ellipsis: the base name
  /// is end-ellipsized inside an Expanded, while the file extension
  /// sits in a separate non-shrinking Text so it is always visible.
  Widget _buildNameWidget(TextStyle style, {Color? extensionColor}) {
    final name = taskDisplayName(task);
    final dotIdx = name.lastIndexOf('.');
    if (dotIdx > 0 && name.length - dotIdx <= 6) {
      final base = name.substring(0, dotIdx);
      final ext = name.substring(dotIdx);
      return Row(
        children: [
          Expanded(
            child: Text(base, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
          ),
          Text(
            ext,
            maxLines: 1,
            style: extensionColor != null
                ? style.copyWith(color: extensionColor)
                : style,
          ),
        ],
      );
    }
    return Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final color = _statusColor(ac);
    final isMerging = task.state == DownloadState.merging;

    // ── Swipe backgrounds ──────────────────────────────────────────
    Widget? rightSwipeBg() {
      Widget icon;
      switch (task.state) {
        case DownloadState.scheduled:
          icon = Icon(Icons.cancel_outlined, color: ac.statusError);
        case DownloadState.idle:
        case DownloadState.downloading:
          icon = Icon(Icons.pause, color: ac.accentFrost);
        case DownloadState.paused:
          icon = Icon(Icons.play_arrow, color: ac.accentFrost);
        case DownloadState.failed:
          icon = Icon(Icons.refresh, color: ac.accentFrost);
        case DownloadState.completed:
          icon = Icon(Icons.open_in_new, color: ac.accentFrost);
        case DownloadState.merging:
          return null;
      }
      return Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: task.state == DownloadState.scheduled
            ? ac.statusError.withValues(alpha: 0.2)
            : ac.accentFrost.withValues(alpha: 0.2),
        child: icon,
      );
    }

    Widget? leftSwipeBg() {
      if (isMerging) return null;
      return Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 20),
        color: ac.statusError.withValues(alpha: 0.2),
        child: Icon(Icons.delete_outline, color: ac.statusError),
      );
    }

    VoidCallback? onRightSwipe() {
      if (isMerging) return null;
      switch (task.state) {
        case DownloadState.scheduled:
          return onCancel;
        case DownloadState.idle:
        case DownloadState.downloading:
          return onPause;
        case DownloadState.paused:
          return onResume;
        case DownloadState.failed:
          return onRetry;
        case DownloadState.completed:
          return () => onOpenDownload(task);
        case DownloadState.merging:
          return null;
      }
    }

    VoidCallback? onLeftSwipe() {
      if (isMerging) return null;
      return onCancel;
    }

    // ── Card body ──────────────────────────────────────────────────
    final cardBody = Container(
      constraints: const BoxConstraints(minHeight: 72),
      decoration: BoxDecoration(
        color: ac.surfaceCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ac.glassBorder),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Leading checkbox for selection mode
            if (selectionMode)
              Padding(
                padding: const EdgeInsets.only(left: 8, right: 4),
                child: GestureDetector(
                  onTap: onToggleSelected,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected
                            ? ac.accentFrost
                            : ac.textTertiary,
                        width: 1.5,
                      ),
                      color: selected
                          ? ac.accentFrost
                          : Colors.transparent,
                    ),
                    child: selected
                        ? Icon(Icons.check,
                            size: 12, color: ac.surfaceCard)
                        : null,
                  ),
                ),
              ),
            // Type glyph icon
            const Padding(padding: EdgeInsets.only(left: 8)),
            Icon(
              () {
                final cat = categoryForTask(task);
                if (cat != FileCategory.other) return iconForCategory(cat);
                // Fallback to state-appropriate icon
                switch (task.state) {
                  case DownloadState.downloading:
                  case DownloadState.idle:
                    return Icons.download_outlined;
                  case DownloadState.paused:
                    return Icons.pause_circle_outline;
                  case DownloadState.failed:
                    return Icons.error_outline;
                  case DownloadState.completed:
                    return Icons.check_circle_outline;
                  case DownloadState.scheduled:
                    return Icons.schedule;
                  case DownloadState.merging:
                    return Icons.merge_type;
                }
              }(),
              size: 20,
              color: color,
            ),
            const SizedBox(width: 8),
            // Text block
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(
                  vertical: task.state == DownloadState.failed ? 10 : 0,
                ),
                child: Column(
                  mainAxisAlignment: task.state == DownloadState.failed
                      ? MainAxisAlignment.start
                      : MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Name row with optional priority pill
                    Row(
                      children: [
                        Expanded(
                          child: _buildNameWidget(
                            TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: ac.textPrimary,
                            ),
                            extensionColor: ac.textSecondary,
                          ),
                        ),
                        if (task.priority != DownloadPriority.medium)
                          Container(
                            margin: const EdgeInsets.only(left: 6),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: (task.priority == DownloadPriority.high
                                      ? ac.accentFrost
                                      : ac.textTertiary)
                                  .withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Builder(
                              builder: (context) {
                                final l10n = AppLocalizations.of(context)!;
                                return Text(
                              task.priority == DownloadPriority.high
                                  ? l10n.cardPriorityHigh
                                  : l10n.cardPriorityLow,
                              style: TextStyle(
                                fontFamily: 'Inter',
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: task.priority == DownloadPriority.high
                                    ? ac.accentFrost
                                    : ac.textSecondary,
                              ),
                            );
                              },
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    // Live section: progress bar, percent, bytes/speed/ETA,
                    // status/error text. Rebuilds per tick from the
                    // per-task notifier when one is provided (P1b); the
                    // rest of the card stays static between transitions.
                    if (progressListenable != null)
                      ValueListenableBuilder<DownloadTask>(
                        valueListenable: progressListenable!,
                        builder: (context, liveTask, _) {
                          final l10n = AppLocalizations.of(context)!;
                          return _buildLiveSection(liveTask, ac, color, l10n);
                        },
                      )
                    else
                      Builder(builder: (context) {
                        final l10n = AppLocalizations.of(context)!;
                        return _buildLiveSection(task, ac, color, l10n);
                      }),
                  ],
                ),
              ),
            ),
            // Action buttons — top-aligned
            Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: EdgeInsets.only(
                  top: task.state == DownloadState.failed ? 8 : 0,
                ),
                child: _buildTaskActions(context, ac, color),
              ),
            ),
          ],
        ),
      ),
    );

    // ── Wrap in HoldSwipeCard when swipe enabled ───────────────────
    Widget card;
    if (enableSwipe && !selectionMode && !isMerging) {
      card = Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: HoldSwipeCard(
          leftBackground: rightSwipeBg(),
          rightBackground: leftSwipeBg(),
          onLeftSwipe: onLeftSwipe(),
          onRightSwipe: onRightSwipe(),
          child: cardBody,
        ),
      );
    } else {
      card = Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: cardBody,
      );
    }

    if (selectionMode) {
      card = GestureDetector(
        onTap: onToggleSelected,
        onLongPress: onSelectRange,
        child: card,
      );
    }

    // Accessibility label
    final name = taskDisplayName(task);
    final stateText = stateLabel(task.state);
    final progressText = (task.totalParts > 0 || task.totalBytes > 0)
        ? ', ${task.progressPercent}%'
        : '';
    return Semantics(
      label: '$name, $stateText$progressText',
      button: true,
      child: card,
    );
  }

  /// Progress-dependent column children (P1b). Rebuilt from the live task
  /// on every progress tick; everything else in the card stays static
  /// between state transitions.
  Widget _buildLiveSection(DownloadTask liveTask, AColors ac, Color color, AppLocalizations l10n) {
    final progress = (liveTask.totalParts > 0 ||
            liveTask.chunks.isNotEmpty ||
            liveTask.totalBytes > 0)
        ? liveTask.progress
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Progress bar (download / idle)
        if (liveTask.state == DownloadState.downloading ||
            liveTask.state == DownloadState.idle)
          RepaintBoundary(
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: ac.borderStrong, width: 0.5),
                borderRadius: BorderRadius.circular(3),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2.5),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 6,
                  backgroundColor: ac.surfaceElevated,
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                ),
              ),
            ),
          ),
        // Paused frozen progress bar
        if (liveTask.state == DownloadState.paused && liveTask.totalBytes > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: ac.borderStrong, width: 0.5),
                borderRadius: BorderRadius.circular(3),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2.5),
                child: LinearProgressIndicator(
                  value: (liveTask.downloadedBytes / liveTask.totalBytes)
                      .clamp(0.0, 1.0),
                  minHeight: 6,
                  backgroundColor: ac.surfaceElevated,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    ac.accentAmber.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ),
          ),
        // Percent label for downloading state
        if (liveTask.state == DownloadState.downloading && progress != null)
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text(
              liveTask.totalParts > 0
                  ? '${liveTask.progressPercent}% · ${liveTask.completedParts}/${liveTask.totalParts} ${l10n.cardSegmentsLabel}'
                  : '${liveTask.progressPercent}%',
              style: TextStyle(
                fontSize: 10,
                fontFamily: 'JetBrainsMono',
                fontWeight: FontWeight.w500,
                color: ac.textSecondary,
              ),
            ),
          ),
        // Metadata line
        Text(
          _metadataLabel(liveTask, l10n),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11,
            fontFamily: 'JetBrainsMono',
            color: ac.textTertiary,
          ),
        ),
        // Transient status message
        if (liveTask.statusMessage != null &&
            liveTask.statusMessage!.isNotEmpty &&
            liveTask.state != DownloadState.completed &&
            liveTask.state != DownloadState.failed)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              liveTask.statusMessage!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'Inter',
                color: ac.accentFrost,
              ),
            ),
          ),
        // Failed error text
        if (liveTask.state == DownloadState.failed &&
            liveTask.errorMessage != null &&
            liveTask.errorMessage!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6, right: 4),
            child: Text(
              _displayErrorMessage(liveTask.errorMessage!),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                height: 1.35,
                fontFamily: 'Inter',
                color: ac.statusError,
              ),
            ),
          ),
      ],
    );
  }

  bool _isRefreshableFailure(DownloadFailure reason) {
    switch (reason) {
      case DownloadFailure.urlExpired:
      case DownloadFailure.httpForbidden:
      case DownloadFailure.httpUnauthorized:
      case DownloadFailure.hlsTokenExpired:
      case DownloadFailure.hlsCircuitBreaker:
        return true;
      default:
        return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Action buttons
  // ---------------------------------------------------------------------------

  Widget _compactButton({
    required IconData icon,
    required Color color,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: 40,
      height: 40,
      child: IconButton(
        icon: Icon(icon, size: 18),
        color: color,
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
        splashRadius: 20,
        onPressed: onPressed,
      ),
    );
  }

  Widget _popupRow(IconData icon, Color color, String label) {
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 10),
        Flexible(
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13)),
        ),
      ],
    );
  }

  Widget _buildTaskActions(BuildContext context, AColors ac, Color color) {
    final l10n = AppLocalizations.of(context)!;
    // ── Primary action icon ──────────────────────────────────────
    Widget? primaryAction;

    if (task.state == DownloadState.scheduled) {
      primaryAction = _compactButton(
        icon: Icons.cancel_outlined,
        color: ac.statusError,
        tooltip: l10n.cardTooltipCancelScheduled,
        onPressed: onCancel ?? () {},
      );
    } else if (task.state == DownloadState.downloading ||
        task.state == DownloadState.idle) {
      primaryAction = _compactButton(
        icon: Icons.pause_rounded,
        color: ac.accentFrost,
        tooltip: l10n.cardTooltipPause,
        onPressed: onPause ?? () {},
      );
    } else if (task.state == DownloadState.paused) {
      primaryAction = _compactButton(
        icon: Icons.play_arrow_rounded,
        color: ac.accentFrost,
        tooltip: l10n.cardTooltipResume,
        onPressed: onResume ?? () {},
      );
    } else if (task.state == DownloadState.merging) {
      primaryAction = SizedBox(
        width: 32,
        height: 32,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(ac.accentFrost),
          ),
        ),
      );
    } else if (task.state == DownloadState.failed) {
      // Smart primary: Refresh link for expired/auth/forbidden failures
      final needsRefresh = task.failureReason != null &&
          _isRefreshableFailure(task.failureReason!);
      if (needsRefresh && onResniffAuto != null) {
        primaryAction = _compactButton(
          icon: Icons.find_replace_rounded,
          color: ac.accentFrost,
          tooltip: l10n.cardTooltipRefreshLink,
          onPressed: () => onResniffAuto!(task),
        );
      } else {
        primaryAction = _compactButton(
          icon: Icons.refresh_rounded,
          color: ac.statusError,
          tooltip: l10n.cardTooltipRetry,
          onPressed: onRetry ?? () {},
        );
      }
    } else if (task.state == DownloadState.completed) {
      primaryAction = _compactButton(
        icon: Icons.open_in_new,
        color: ac.statusSuccess,
        tooltip: l10n.cardTooltipOpen,
        onPressed: () => onOpenDownload(task),
      );
    }

    // ── Overflow menu items ──────────────────────────────────────
    //   Share…            = system share sheet (file already auto-saved
    //                       to public Downloads — no separate "export")
    //   Redownload        = new queue entry for the same URL
    //   Refresh link      = auto probe / token refresh (not for completed)
    //   Re-sniff on page  = open source + capture mode
    //   Open source page  = open only (completed, or when re-sniff N/A)
    final popupItems = <PopupMenuEntry<String>>[];
    final isCompleted = task.state == DownloadState.completed;
    final isActive = task.state == DownloadState.downloading ||
        task.state == DownloadState.merging;
    final hasSource = task.sourcePageUrl != null &&
        task.sourcePageUrl!.trim().isNotEmpty;
    final isMagnet = task.url.startsWith('magnet:');
    final isBlob = task.url.startsWith('blob:');
    // Native-engine torrent tasks have no mergeable chunks (the engine
    // writes pieces straight to its save dir) — force merge can never
    // succeed for them, so don't offer it.
    final isTorrentEngineTask =
        isMagnet || task.url.toLowerCase().endsWith('.torrent');

    // Open file (completed) — same as primary; kept for menu discoverability.
    if (isCompleted) {
      popupItems.add(
        PopupMenuItem(
          value: 'open',
          child: _popupRow(Icons.play_circle_outline, ac.statusSuccess, l10n.cardMenuOpen),
        ),
      );
    }

    // Share via the system sheet (file is already in Downloads after publish).
    if (isCompleted && onShare != null) {
      popupItems.add(
        PopupMenuItem(
          value: 'share',
          child: _popupRow(Icons.share_outlined, ac.accentFrost, l10n.cardMenuShare),
        ),
      );
    }

    // Send to PC over LAN (P6) — completed files only.
    if (isCompleted && onSendToPc != null) {
      popupItems.add(
        PopupMenuItem(
          value: 'send_to_pc',
          child: _popupRow(
            Icons.computer_outlined,
            ac.accentFrost,
            l10n.cardMenuSendToPc,
          ),
        ),
      );
    }

    // Move to Private Vault (P7) — completed files only.
    if (isCompleted && onMoveToVault != null) {
      popupItems.add(
        PopupMenuItem(
          value: 'move_to_vault',
          child: _popupRow(
            Icons.shield_outlined,
            ac.accentPurple,
            l10n.cardMenuMoveToVault,
          ),
        ),
      );
    }

    // Edit in FFmpeg Studio — completed media files only.
    if (isCompleted && onOpenFfmpegStudio != null) {
      popupItems.add(
        PopupMenuItem(
          value: 'ffmpeg_studio',
          child: _popupRow(
            Icons.movie_outlined,
            ac.accentFrost,
            l10n.cardMenuFfmpegStudio,
          ),
        ),
      );
    }

    // Redownload — fresh queue entry (not the same as Retry of a partial).
    if (onRedownload != null && !isActive && !isMagnet && !isBlob) {
      popupItems.add(
        PopupMenuItem(
          value: 'redownload',
          child: _popupRow(
            Icons.download_for_offline_outlined,
            ac.accentFrost,
            l10n.cardMenuRedownload,
          ),
        ),
      );
    }

    // Force merge (partial / interrupted only — never for native torrents)
    if (!isCompleted &&
        !isActive &&
        !isTorrentEngineTask &&
        onForceMerge != null) {
      popupItems.add(
        PopupMenuItem(
          value: 'force_merge',
          child: _popupRow(Icons.merge_type, Colors.orange, l10n.cardMenuForceMerge),
        ),
      );
    }

    // Link recovery — hide for completed (file already finished).
    if (!isCompleted &&
        !isActive &&
        onResniffAuto != null &&
        !isMagnet &&
        !isBlob) {
      popupItems.add(
        PopupMenuItem(
          value: 'resniff_auto',
          child: _popupRow(
            Icons.find_replace_rounded,
            ac.accentFrost,
            l10n.cardMenuRefreshLink,
          ),
        ),
      );
    }

    // One browser action only:
    if (hasSource) {
      if (!isCompleted && !isActive && onResniffManual != null) {
        popupItems.add(
          PopupMenuItem(
            value: 'resniff_manual',
            child: _popupRow(
              Icons.open_in_browser_rounded,
              ac.accentPurple,
              l10n.cardMenuResniffOnPage,
            ),
          ),
        );
      } else if (onOpenUrlInBrowser != null) {
        popupItems.add(
          PopupMenuItem(
            value: 'open_source',
            child: _popupRow(
              Icons.public_outlined,
              ac.accentPurple,
              l10n.cardMenuOpenSourcePage,
            ),
          ),
        );
      }
    }

    // Schedule download
    if (task.state != DownloadState.scheduled && onSchedule != null) {
      popupItems.add(
        PopupMenuItem(
          value: 'schedule',
          child: _popupRow(Icons.schedule, ac.accentFrost, l10n.cardMenuScheduleDownload),
        ),
      );
    }

    // Delete / Cancel
    popupItems.add(
      PopupMenuItem(
        value: 'delete',
        child: _popupRow(
          Icons.delete_outline,
          ac.statusError,
          isCompleted ? l10n.cardMenuRemove : l10n.cardMenuCancel,
        ),
      ),
    );

    // Properties
    popupItems.add(
      PopupMenuItem(
        value: 'properties',
        child: _popupRow(Icons.info_outline, ac.textSecondary, l10n.cardMenuProperties),
      ),
    );

    final hasPrimary = primaryAction != null;
    final hasOverflow = popupItems.isNotEmpty;

    if (!hasPrimary && !hasOverflow) return const SizedBox.shrink();

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPressStart: (_) {},
      onLongPressMoveUpdate: (_) {},
      onLongPressEnd: (_) {},
      onLongPressCancel: () {},
      child: Padding(
        padding: const EdgeInsets.only(right: 8, top: 4, bottom: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.end,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (primaryAction != null) ...[
              primaryAction,
              const SizedBox(width: 4),
            ],
            if (hasOverflow)
              SizedBox(
                width: 40,
                height: 40,
                child: PopupMenuButton<String>(
                  icon: Icon(Icons.more_vert, size: 16,
                      color: ac.textSecondary),
                  padding: EdgeInsets.zero,
                  splashRadius: 20,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  color: ac.surfaceCard,
                  elevation: 4,
                  onSelected: (value) {
                    switch (value) {
                      case 'open':
                        onOpenDownload(task);
                      case 'share':
                        onShare?.call(task);
                      case 'send_to_pc':
                        onSendToPc?.call(task);
                      case 'move_to_vault':
                        onMoveToVault?.call(task);
                      case 'ffmpeg_studio':
                        onOpenFfmpegStudio?.call(task);
                      case 'redownload':
                        onRedownload?.call(task);
                      case 'force_merge':
                        onForceMerge?.call();
                      case 'schedule':
                        _pickScheduleTime(context);
                      case 'open_source':
                        if (task.sourcePageUrl != null) {
                          onOpenUrlInBrowser?.call(task.sourcePageUrl!);
                        }
                      case 'resniff_auto':
                        onResniffAuto?.call(task);
                      case 'resniff_manual':
                        onResniffManual?.call(task);
                      case 'delete':
                        onCancel?.call();
                      case 'properties':
                        showDialog(
                          context: context,
                          builder: (ctx) =>
                              DownloadPropertiesDialog(task: task),
                        );
                    }
                  },
                  itemBuilder: (_) => popupItems,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickScheduleTime(BuildContext context) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now().add(const Duration(hours: 1)),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 30)),
    );
    if (picked == null || !context.mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(picked),
    );
    if (time == null || !context.mounted) return;
    final startAt = DateTime(
      picked.year,
      picked.month,
      picked.day,
      time.hour,
      time.minute,
    );
    onSchedule?.call(task, startAt);
  }
}

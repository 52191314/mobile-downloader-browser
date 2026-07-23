import 'package:flutter/material.dart';

import 'package:aurora_downloader/theme/aurora_palette.dart';

/// Capture sheet zone header: frost icon well, title/subtitle, Rescan / Best / Download.
///
/// Download acts on the current multi-select (checkbox selection). Clear-all was
/// removed in favor of select + download workflow.
class CaptureSheetHeader extends StatelessWidget {
  const CaptureSheetHeader({
    super.key,
    required this.totalShown,
    required this.selectedCount,
    required this.onSelectBest,
    required this.onDownloadSelected,
    required this.onRescan,
    this.onSeriesGrab,
  });

  final int totalShown;
  final int selectedCount;
  final VoidCallback onSelectBest;
  final VoidCallback onDownloadSelected;
  final VoidCallback onRescan;

  /// Optional series auto-grab (P2). Null hides the control.
  final VoidCallback? onSeriesGrab;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final subtitle = totalShown == 0
        ? 'Browse to find downloadable media'
        : '$selectedCount selected · $totalShown shown';
    final canDownload = selectedCount > 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 12),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: ac.accentFrost.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.radar, size: 20, color: ac.accentFrost),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Media on this page',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    height: 1.2,
                    color: ac.textPrimary,
                  ),
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: ac.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Rescan page for new media',
            icon: Icon(Icons.refresh_rounded, color: ac.accentFrost),
            onPressed: onRescan,
          ),
          TextButton.icon(
            key: const Key('capture_select_best_button'),
            icon: Icon(Icons.auto_awesome, size: 16, color: ac.accentAmber),
            label: Text(
              'Best',
              style: TextStyle(
                color: ac.accentAmber,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
            onPressed: totalShown == 0 ? null : onSelectBest,
          ),
          if (onSeriesGrab != null)
            IconButton(
              key: const Key('capture_series_grab_button'),
              tooltip: 'Grab series (episode order)',
              icon: Icon(
                Icons.playlist_play_rounded,
                color: totalShown == 0 ? ac.textDisabled : ac.accentFrost,
              ),
              onPressed: totalShown == 0 ? null : onSeriesGrab,
            ),
          IconButton(
            key: const Key('capture_download_selected_button'),
            tooltip: canDownload
                ? 'Download $selectedCount selected'
                : 'Select items to download',
            icon: Icon(
              Icons.download,
              color: canDownload ? ac.accentFrost : ac.textDisabled,
            ),
            onPressed: canDownload ? onDownloadSelected : null,
          ),
        ],
      ),
    );
  }
}

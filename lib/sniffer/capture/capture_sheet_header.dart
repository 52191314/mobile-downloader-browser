import 'package:flutter/material.dart';

import 'package:aurora_downloader/theme/aurora_palette.dart';

/// Capture sheet zone header: frost icon well, title/subtitle, Rescan / Best / Clear.
class CaptureSheetHeader extends StatelessWidget {
  const CaptureSheetHeader({
    super.key,
    required this.totalShown,
    required this.selectedCount,
    required this.onSelectBest,
    required this.onClearCaptured,
    required this.onRescan,
  });

  final int totalShown;
  final int selectedCount;
  final VoidCallback onSelectBest;
  final VoidCallback onClearCaptured;
  final VoidCallback onRescan;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final subtitle = totalShown == 0
        ? 'Browse to find downloadable media'
        : '$selectedCount selected · $totalShown shown';

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
          IconButton(
            tooltip: 'Clear all detected media',
            icon: Icon(Icons.delete_sweep, color: ac.statusError),
            onPressed: totalShown == 0 ? null : onClearCaptured,
          ),
        ],
      ),
    );
  }
}

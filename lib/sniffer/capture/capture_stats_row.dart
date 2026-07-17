import 'package:flutter/material.dart';

import 'package:aurora_downloader/sniffer/capture/media_accent.dart';
import 'package:aurora_downloader/theme/aurora_palette.dart';

/// Aggregate stats pills for the Capture sheet.
class CaptureStatsRow extends StatelessWidget {
  const CaptureStatsRow({
    super.key,
    required this.foundCount,
    required this.videoCount,
    required this.audioCount,
    required this.totalBytes,
    required this.filteredCount,
  });

  final int foundCount;
  final int videoCount;
  final int audioCount;
  final int totalBytes;
  final int filteredCount;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final sizeLabel = formatCaptureBytes(totalBytes);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _StatPill(
              icon: Icons.link,
              label: '$foundCount found',
              color: ac.textSecondary,
            ),
            _StatPill(
              icon: Icons.movie,
              label: '$videoCount video',
              color: ac.mediaVideo,
            ),
            _StatPill(
              icon: Icons.audiotrack,
              label: '$audioCount audio',
              color: ac.mediaAudio,
            ),
            if (sizeLabel.isNotEmpty)
              _StatPill(
                icon: Icons.storage,
                label: sizeLabel,
                color: ac.textSecondary,
              ),
            _StatPill(
              icon: Icons.visibility_off,
              label: '$filteredCount filtered',
              color: ac.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}

class _StatPill extends StatelessWidget {
  const _StatPill({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Container(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.28)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

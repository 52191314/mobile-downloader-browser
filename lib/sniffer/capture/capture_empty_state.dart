import 'package:flutter/material.dart';

import 'package:aurora_downloader/theme/aurora_palette.dart';

/// Empty list state for the Capture sheet.
class CaptureEmptyState extends StatelessWidget {
  const CaptureEmptyState({
    super.key,
    this.onRescan,
  });

  final VoidCallback? onRescan;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.radar, size: 48, color: ac.textTertiary),
              const SizedBox(height: 16),
              Text(
                'No media detected on this page',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: ac.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Play a video or scroll further so Aurora can catch streams.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: ac.textSecondary,
                ),
              ),
              if (onRescan != null) ...[
                const SizedBox(height: 16),
                TextButton.icon(
                  onPressed: onRescan,
                  icon: Icon(Icons.refresh_rounded, color: ac.accentFrost),
                  label: Text(
                    'Rescan',
                    style: TextStyle(color: ac.accentFrost),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

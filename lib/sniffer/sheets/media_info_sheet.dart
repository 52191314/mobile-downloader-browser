// Standalone library — extracted from `sniffer_screen.dart` during Phase 5 of
// the refactorization. Provides the bottom-sheet showing the read-only
// "media information" panel for a captured [SniffedMedia] (filename, URL,
// source page, size, type). All state-mutating side effects (clipboard
// copy) are kept in-line; everything that used to live on
// `_SnifferScreenState` is now passed in as an explicit callback.
//
// The function is intentionally a **standalone top-level function** (NOT
// `part of`) so it can be unit-tested in isolation and so the
// `_SnifferScreenState` class no longer has to absorb the entire sheet.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:aurora_downloader/sniffer/capture/media_accent.dart';
import 'package:aurora_downloader/sniffer/models/sniffed_media.dart';
import 'package:aurora_downloader/theme/aurora_palette.dart';
import 'package:aurora_downloader/ui/notifications/aurora_snackbar.dart';

/// Shows the "Media Information" bottom sheet for [item]. Replaces the body
/// of `_SnifferScreenState._showMediaInfoSheet`.
///
/// [formatSize] is the size-formatting callback from the host screen (it
/// must be the same `_formatSize` that the rest of the screen uses so the
/// sheet stays visually consistent with the rest of the UI).
void showMediaInfoSheet(
  BuildContext context,
  SniffedMedia item, {
  required String Function(int bytes, {bool isEstimated}) formatSize,
}) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AuroraPalette.of(context).surfacePanel,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) {
      final ac = ctx.ac;
      final hls = isHlsMedia(item);
      final accent = mediaAccentFor(ac, item, isHls: hls);

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
              extLabel = segments.last.split('.').last.toUpperCase();
            }
          }
        }
      } catch (_) {}
      if (hls) extLabel = 'HLS';
      if (extLabel == 'FILE' && item.type == MediaType.video) extLabel = 'MP4';
      if (extLabel == 'FILE' && item.type == MediaType.audio) extLabel = 'MP3';

      return Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: accent.withValues(alpha: 0.3),
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  child: Text(
                    extLabel,
                    style: TextStyle(
                      color: accent,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Media details',
                    style: TextStyle(
                      color: ac.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close, color: ac.textSecondary),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ],
            ),
            Divider(color: ac.borderHairline, height: 24),
            Text(
              'Filename',
              style: TextStyle(
                color: ac.textTertiary,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            SelectableText(
              item.name,
              style: TextStyle(
                color: ac.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Download URL',
              style: TextStyle(
                color: ac.textTertiary,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: ac.surfaceField,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: ac.borderHairline),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: SelectableText(
                      item.url,
                      style: TextStyle(
                        color: ac.textSecondary,
                        fontSize: 12,
                        fontFamily: 'JetBrainsMono',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: Icon(
                      Icons.copy,
                      color: ac.accentFrost,
                      size: 20,
                    ),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: item.url));
                      AuroraSnackbar.show(ctx, 'URL copied');
                    },
                    tooltip: 'Copy URL',
                  ),
                ],
              ),
            ),
            if (item.sourcePageUrl != null &&
                item.sourcePageUrl!.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                'Source page',
                style: TextStyle(
                  color: ac.textTertiary,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              SelectableText(
                item.sourcePageUrl!,
                style: TextStyle(color: ac.textSecondary, fontSize: 13),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                if (item.contentLengthBytes != null) ...[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Size',
                          style: TextStyle(
                            color: ac.textTertiary,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          formatSize(
                            item.contentLengthBytes!,
                            isEstimated: item.isSizeEstimated,
                          ),
                          style: TextStyle(
                            color: ac.textPrimary,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Media type',
                        style: TextStyle(
                          color: ac.textTertiary,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        item.type.name.toUpperCase(),
                        style: TextStyle(
                          color: ac.textPrimary,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
        ),
      );
    },
  );
}

import 'package:flutter/material.dart';

import 'package:aurora_downloader/sniffer/capture/media_filter.dart';
import 'package:aurora_downloader/theme/aurora_palette.dart';
import 'package:aurora_downloader/theme/aurora_tokens.dart';

/// Horizontal type filter chips for the Capture sheet.
///
/// Selected "All" uses frost; selected type chips use the matching media accent.
class CaptureFilterBar extends StatelessWidget {
  const CaptureFilterBar({
    super.key,
    required this.current,
    required this.onSelected,
  });

  final MediaFilter current;
  final ValueChanged<MediaFilter> onSelected;

  static const _chips = <(String, MediaFilter, IconData)>[
    ('All', MediaFilter.all, Icons.all_inclusive),
    ('Video', MediaFilter.video, Icons.movie),
    ('Audio', MediaFilter.audio, Icons.audiotrack),
    ('HLS', MediaFilter.hls, Icons.queue_music),
    ('Torrent', MediaFilter.torrent, Icons.hub),
    ('Image', MediaFilter.image, Icons.image),
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < _chips.length; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              _FilterChip(
                label: _chips[i].$1,
                value: _chips[i].$2,
                icon: _chips[i].$3,
                selected: current == _chips[i].$2,
                onTap: () => onSelected(_chips[i].$2),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.value,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final MediaFilter value;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  Color _accent(AColors ac) {
    return switch (value) {
      MediaFilter.all => ac.accentFrost,
      MediaFilter.video => ac.mediaVideo,
      MediaFilter.audio => ac.mediaAudio,
      MediaFilter.hls => ac.mediaHls,
      MediaFilter.torrent => ac.mediaTorrent,
      MediaFilter.image => ac.mediaImage,
    };
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final accent = _accent(ac);
    final isLight = context.isLight;
    final unselectedFill = isLight ? ac.surfaceElevated : ac.glassSurface;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? accent.withValues(alpha: 0.14) : unselectedFill,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? accent : ac.glassBorder,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: selected ? accent : ac.textSecondary,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? accent : ac.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

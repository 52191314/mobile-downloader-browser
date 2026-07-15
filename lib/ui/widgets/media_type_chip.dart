import 'package:flutter/material.dart';

import '../../sniffer/models/sniffed_media.dart' show MediaType;
import '../../theme/aurora_palette.dart';

class MediaTypeChip extends StatelessWidget {
  final MediaType type;
  final bool disabled;
  final ValueChanged<bool> onChanged;

  const MediaTypeChip({
    super.key,
    required this.type,
    required this.disabled,
    required this.onChanged,
  });

  String get _label {
    return switch (type) {
      MediaType.video => 'Video file',
      MediaType.audio => 'Audio file',
      MediaType.image => 'Image',
      MediaType.document => 'Document',
      MediaType.archive => 'Archive',
      MediaType.torrent => 'Torrent',
      MediaType.subtitle => 'Subtitles',
      MediaType.executable => 'App',
      MediaType.playlist => 'Streaming video',
    };
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final color = context.auroraColorScheme.primary;
    return FilterChip(
      selected: !disabled,
      onSelected: (selected) => onChanged(!selected),
      label: Text(_label),
      selectedColor: color.withValues(alpha: 0.16),
      checkmarkColor: color,
      side: BorderSide(color: disabled ? ac.borderHairline : color),
      labelStyle: TextStyle(
        fontFamily: 'Inter',
        color: disabled ? ac.textDisabled : ac.textPrimary,
        fontSize: 12,
      ),
    );
  }
}

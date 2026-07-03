import 'package:flutter/material.dart';

import '../../sniffer/models/sniffed_media.dart' show MediaType;

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
    final name = type.name;
    return name[0].toUpperCase() + name.substring(1);
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return FilterChip(
      selected: !disabled,
      onSelected: (selected) => onChanged(!selected),
      label: Text(_label),
      selectedColor: color.withValues(alpha: 0.2),
      checkmarkColor: color,
      side: BorderSide(color: disabled ? Colors.white24 : color),
      labelStyle: TextStyle(
        color: disabled ? Colors.white54 : Colors.white,
        fontSize: 12,
      ),
    );
  }
}

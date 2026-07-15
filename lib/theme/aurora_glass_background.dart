// AuroraGlassBackground — palette-aware scaffold background.
//
// Replaces the historic hardcoded dark gradient with a snowfield wash in
// light mode and the original Nordic slate wash in dark. The wash direction
// (top-left → bottom-right) is preserved across modes so the gesture feels
// the same regardless of brightness.
//
// Static: the previous fragment-shader-driven mesh was removed because it
// caused native GPU driver crashes on some Adreno 740 devices (S23 Ultra).

import 'package:flutter/material.dart';

import 'aurora_palette.dart';

class AuroraGlassBackground extends StatelessWidget {
  final Widget child;

  const AuroraGlassBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final isLight = context.isLight;
    final colors = isLight
        ? const [Color(0xFFF4F6FA), Color(0xFFFFFFFF)]
        : const [Color(0xFF0A0F14), Color(0xFF141B23)];
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
      ),
      child: child,
    );
  }
}

/// Themed variant — accepts an explicit palette. Useful for previews and
/// tests that don't want to wrap with [AuroraPalette].
class AuroraGlassBackgroundThemed extends StatelessWidget {
  final Widget child;
  final bool isLight;

  const AuroraGlassBackgroundThemed({
    super.key,
    required this.child,
    required this.isLight,
  });

  @override
  Widget build(BuildContext context) {
    final colors = isLight
        ? const [Color(0xFFF4F6FA), Color(0xFFFFFFFF)]
        : const [Color(0xFF0A0F14), Color(0xFF141B23)];
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
      ),
      child: child,
    );
  }
}

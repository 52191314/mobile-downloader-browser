import 'package:flutter/material.dart';

/// Faint static gradient background that sits behind all content.
///
/// Previously used a GLSL fragment shader (`shaders/aurora_mesh.frag`) for
/// a slow-moving aurora effect at 4% opacity.  The shader was nearly
/// invisible to the eye but caused native GPU driver crashes on some
/// Samsung devices (S23 Ultra Adreno 740) and was a potential source of
/// ANR timeouts.  Replaced with a static `LinearGradient` that has the
/// same visual character (dark base with a faint warm wash) and zero
/// GPU cost.
class AuroraGlassBackground extends StatelessWidget {
  final Widget child;

  const AuroraGlassBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF0A0F14),
            Color(0xFF141B23),
          ],
        ),
      ),
      child: child,
    );
  }
}

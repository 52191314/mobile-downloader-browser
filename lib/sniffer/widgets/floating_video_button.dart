import 'package:flutter/material.dart';

import '../../theme/aurora_palette.dart';

/// IDM-style floating play control that sits over (or near) a detected video.
///
/// Tap → open Aurora's in-app player. Long-press → dismiss for this page.
/// Optional drag so the user can move it if it covers controls.
class FloatingVideoButton extends StatefulWidget {
  final VoidCallback onTap;
  final VoidCallback? onDismiss;

  /// Optional label under the icon (kept short, e.g. quality).
  final String? subtitle;

  const FloatingVideoButton({
    super.key,
    required this.onTap,
    this.onDismiss,
    this.subtitle,
  });

  @override
  State<FloatingVideoButton> createState() => _FloatingVideoButtonState();
}

class _FloatingVideoButtonState extends State<FloatingVideoButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animCtrl;
  late final Animation<double> _scaleAnim;
  Offset _dragOffset = Offset.zero;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _scaleAnim = CurvedAnimation(parent: _animCtrl, curve: Curves.elasticOut);
    _animCtrl.forward();
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  void _dismiss() {
    _animCtrl.reverse().then((_) {
      if (mounted) widget.onDismiss?.call();
    });
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Transform.translate(
      offset: _dragOffset,
      child: ScaleTransition(
        scale: _scaleAnim,
        child: GestureDetector(
          onTap: widget.onTap,
          onLongPress: _dismiss,
          onPanUpdate: (d) {
            setState(() => _dragOffset += d.delta);
          },
          child: Material(
            color: Colors.transparent,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: ac.surfacePanel.withValues(alpha: 0.94),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.45),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                    border: Border.all(
                      color: ac.accentFrost.withValues(alpha: 0.75),
                      width: 2,
                    ),
                  ),
                  child: Icon(
                    Icons.play_arrow_rounded,
                    color: ac.accentFrost,
                    size: 30,
                  ),
                ),
                if (widget.subtitle != null && widget.subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      widget.subtitle!,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

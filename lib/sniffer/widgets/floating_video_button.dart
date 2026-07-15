import 'package:flutter/material.dart';

import '../../theme/aurora_palette.dart';

/// A small floating play button that appears when the sniffer detects a video
/// on the current page, similar to UC Browser's mini-player trigger.
///
/// Positioned near the bottom of the browser viewport. Tapping opens the
/// full-screen [AuroraVideoPlayer]. Long-pressing or swiping down dismisses.
class FloatingVideoButton extends StatefulWidget {
  final VoidCallback onTap;
  final VoidCallback? onDismiss;

  const FloatingVideoButton({
    super.key,
    required this.onTap,
    this.onDismiss,
  });

  @override
  State<FloatingVideoButton> createState() => _FloatingVideoButtonState();
}

class _FloatingVideoButtonState extends State<FloatingVideoButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animCtrl;
  late final Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
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
      widget.onDismiss?.call();
    });
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scaleAnim,
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPress: _dismiss,
        child: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: context.ac.surfacePanel,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.4),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
            border: Border.all(
              color: context.ac.accentFrost.withOpacity(0.6),
              width: 2,
            ),
          ),
          child: Icon(
            Icons.play_arrow_rounded,
            color: context.ac.accentFrost,
            size: 28,
          ),
        ),
      ),
    );
  }
}

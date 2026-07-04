import 'package:flutter/material.dart';

/// A card wrapper that only accepts horizontal swipe from the left and
/// right edge zones (default 32 px).  The entire center area passes
/// touches through to the parent scroll view, preventing the "swipe too
/// sensitive — can barely scroll" problem inherent to [Dismissible].
///
/// [leftBackground] is revealed when swiping right (drag from left edge).
/// [rightBackground] is revealed when swiping left (drag from right edge).
///
/// Both callbacks receive the active [DownloadTask] via their closure.
/// Unlike [Dismissible], this widget never removes the card — callers
/// must handle task removal themselves if desired.
class EdgeSwipeCard extends StatefulWidget {
  final Widget child;
  final Widget? leftBackground;
  final Widget? rightBackground;
  final VoidCallback? onLeftSwipe;
  final VoidCallback? onRightSwipe;

  /// Width in logical pixels of the swipe-trigger zone on each edge.
  /// Larger values make swipe easier to trigger but shrink the
  /// scroll-friendly center area.
  final double edgeWidth;

  /// Fraction of the card's width the user must drag before the action
  /// fires on release.  0.3 means 30% of card width.
  final double actionThreshold;

  const EdgeSwipeCard({
    super.key,
    required this.child,
    this.leftBackground,
    this.rightBackground,
    this.onLeftSwipe,
    this.onRightSwipe,
    this.edgeWidth = 32.0,
    this.actionThreshold = 0.3,
  });

  @override
  State<EdgeSwipeCard> createState() => _EdgeSwipeCardState();
}

class _EdgeSwipeCardState extends State<EdgeSwipeCard>
    with SingleTickerProviderStateMixin {
  double _dragOffset = 0;
  bool _isDragging = false;

  // Snaps the card back to rest with a spring-like animation.
  late final AnimationController _snapController;
  late final Animation<double> _snapAnimation;

  @override
  void initState() {
    super.initState();
    _snapController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    )..addListener(_onSnapUpdate);
    _snapAnimation = Tween<double>(begin: 0, end: 0).animate(_snapController);
  }

  @override
  void dispose() {
    _snapController.dispose();
    super.dispose();
  }

  void _onSnapUpdate() {
    setState(() => _dragOffset = _snapAnimation.value);
  }

  void _snapTo(double target) {
    if (_snapController.isAnimating) _snapController.stop();
    _snapAnimation = Tween<double>(
      begin: _dragOffset,
      end: target,
    ).animate(CurvedAnimation(
      parent: _snapController,
      curve: Curves.decelerate,
    ));
    _snapController.reset();
    _snapController.forward();
  }

  void _startDrag(bool isLeftEdge) {
    _snapController.stop();
    _isDragging = true;
  }

  void _updateDrag(double dx) {
    // Clamp so the card cannot go past 1.1× the card width in either direction.
    final maxOffset = context.size!.width * 1.1;
    setState(() {
      _dragOffset = (_dragOffset + dx).clamp(-maxOffset, maxOffset);
    });
  }

  void _endDrag() {
    _isDragging = false;
    final cardWidth = context.size!.width;
    if (cardWidth <= 0) {
      _snapTo(0);
      return;
    }
    final threshold = cardWidth * widget.actionThreshold;

    if (_dragOffset > threshold) {
      // Swiped right far enough — trigger left-edge action.
      widget.onRightSwipe?.call();
      _snapTo(0);
    } else if (_dragOffset < -threshold) {
      // Swiped left far enough — trigger right-edge action.
      widget.onLeftSwipe?.call();
      _snapTo(0);
    } else {
      _snapTo(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // --- Backgrounds revealed during swipe ---
        if (widget.leftBackground != null && _dragOffset > 0)
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: widget.leftBackground!,
            ),
          ),
        if (widget.rightBackground != null && _dragOffset < 0)
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: widget.rightBackground!,
            ),
          ),

        // --- Card content + edge gesture zones ---
        Transform.translate(
          offset: Offset(_dragOffset, 0),
          child: SizedBox(
            width: double.infinity,
            child: Stack(
              children: [
                // Card body (passes scroll through)
                widget.child,

                // Left edge: swipe-right gesture zone
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: widget.edgeWidth,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragStart: (_) => _startDrag(true),
                    onHorizontalDragUpdate: (d) => _updateDrag(d.delta.dx),
                    onHorizontalDragEnd: (_) => _endDrag(),
                    child: Container(color: Colors.transparent),
                  ),
                ),

                // Right edge: swipe-left gesture zone
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  width: widget.edgeWidth,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragStart: (_) => _startDrag(false),
                    onHorizontalDragUpdate: (d) => _updateDrag(d.delta.dx),
                    onHorizontalDragEnd: (_) => _endDrag(),
                    child: Container(color: Colors.transparent),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

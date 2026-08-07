import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A card wrapper that only activates horizontal swipe after a deliberate
/// long-press hold (default 400 ms).  This prevents accidental swipe
/// triggers during normal vertical scrolling while still allowing the
/// entire card surface to be swipeable.
///
/// **How it works** — Long-press-into-drag:
/// 1. The user presses and holds still on the card for [holdDurationMillis].
/// 2. A haptic tick + subtle scale-up signals "swipe armed".
/// 3. The user then drags horizontally to reveal action backgrounds.
/// 4. Releasing past [actionThreshold] fires the corresponding callback.
/// 5. Releasing early snaps the card back to rest.
///
/// Because vertical scrolling resolves before the long-press timeout,
/// scroll-to-swipe interference is eliminated — no edge-zone hacks needed.
///
/// [leftBackground] is revealed when swiping right (drag from left side).
/// [rightBackground] is revealed when swiping left (drag from right side).
///
/// Both callbacks receive the active [DownloadTask] via their closure.
/// Unlike [Dismissible], this widget never removes the card — callers
/// must handle task removal themselves if desired.
class HoldSwipeCard extends StatefulWidget {
  final Widget child;
  final Widget? leftBackground;
  final Widget? rightBackground;
  final VoidCallback? onLeftSwipe;
  final VoidCallback? onRightSwipe;

  /// Fraction of the card's width the user must drag before the action
  /// fires on release. 0.3 means 30% of card width.
  final double actionThreshold;

  /// How long (in milliseconds) the user must hold still before the
  /// swipe is armed.  Default 400 ms.
  final int holdDurationMillis;

  const HoldSwipeCard({
    super.key,
    required this.child,
    this.leftBackground,
    this.rightBackground,
    this.onLeftSwipe,
    this.onRightSwipe,
    this.actionThreshold = 0.3,
    this.holdDurationMillis = 400,
  });

  @override
  State<HoldSwipeCard> createState() => _HoldSwipeCardState();
}

class _HoldSwipeCardState extends State<HoldSwipeCard>
    with TickerProviderStateMixin {
  double _dragOffset = 0;
  bool _armed = false;

  // Snaps the card back to rest with a spring-like animation.
  late final AnimationController _snapController;
  late Animation<double> _snapAnimation;

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

  // ── Long-press gesture handlers ────────────────────────────────────

  void _onLongPressStart(LongPressStartDetails details) {
    HapticFeedback.mediumImpact();
    setState(() => _armed = true);
  }

  void _onLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    if (!_armed) return;
    final dx = details.localOffsetFromOrigin.dx;
    final maxOffset = context.size!.width * 1.1;
    setState(() {
      _dragOffset = dx.clamp(-maxOffset, maxOffset);
    });
  }

  void _onLongPressEnd(LongPressEndDetails details) {
    if (!_armed) return;
    final cardWidth = context.size!.width;
    if (cardWidth <= 0) {
      _disarm();
      return;
    }
    final threshold = cardWidth * widget.actionThreshold;

    if (_dragOffset > threshold) {
      // Swiped right far enough — right action.
      widget.onRightSwipe?.call();
      _snapTo(0);
    } else if (_dragOffset < -threshold) {
      // Swiped left far enough — left action.
      widget.onLeftSwipe?.call();
      _snapTo(0);
    } else {
      _snapTo(0);
    }
    _disarm();
  }

  void _onLongPressCancel() {
    if (_armed) {
      _snapTo(0);
      _disarm();
    }
  }

  void _disarm() {
    _armed = false;
    _dragOffset = 0;
  }

  // ── Build ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // ── Backgrounds revealed during swipe ──
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

        // ── Card content with long-press-to-arm swipe detection ──
        AnimatedScale(
          scale: _armed ? 1.02 : 1.0,
          duration: const Duration(milliseconds: 100),
          child: Transform.translate(
            offset: Offset(_dragOffset, 0),
            child: SizedBox(
              width: double.infinity,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onLongPressStart: _onLongPressStart,
                onLongPressMoveUpdate: _onLongPressMoveUpdate,
                onLongPressEnd: _onLongPressEnd,
                onLongPressCancel: _onLongPressCancel,
                child: widget.child,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

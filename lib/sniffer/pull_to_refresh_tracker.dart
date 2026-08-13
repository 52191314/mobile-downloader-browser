import 'dart:math' as math;

/// Overscroll distance (logical px) that must be exceeded at the top of the
/// page before a release triggers a refresh.
const double kPullToRefreshThreshold = 120.0;

/// Pull-to-refresh state machine for one WebView, decoupled from widgets so it
/// can be unit-tested without a platform view.
///
/// Android WebView reports a negative `scrollY` while the user overscrolls
/// past the top of the page. The tracker accumulates the most-negative value
/// seen during a pull and, when the scroll springs back to `>= 0` (finger
/// released), reports whether the pull crossed [threshold].
class PullToRefreshTracker {
  PullToRefreshTracker({this.threshold = kPullToRefreshThreshold});

  /// Overscroll distance (logical px) that must be exceeded before a release
  /// triggers a refresh.
  final double threshold;

  double _maxOverscroll = 0;
  double _pullDistance = 0;

  /// Current pull distance (`>= 0`), for driving the indicator. `0` while not
  /// pulling.
  double get pullDistance => _pullDistance;

  /// Feed the latest scroll `y`. Returns true when the pull gesture crossed
  /// [threshold] and was just released (i.e. a refresh should fire now).
  ///
  /// [refreshing] suppresses re-triggering while a refresh is already in
  /// flight (the reload's own scroll events must not start another one).
  bool onScroll(int y, {required bool refreshing}) {
    final dy = y.toDouble();
    if (dy < 0) {
      _maxOverscroll = math.min(_maxOverscroll, dy);
      _pullDistance = -dy;
      return false;
    }
    final shouldRefresh = _maxOverscroll <= -threshold && !refreshing;
    _maxOverscroll = 0;
    _pullDistance = 0;
    return shouldRefresh;
  }
}

import 'dart:async';

/// A simple token-bucket rate limiter for download throughput.
///
/// The limiter operates on 500 ms sliding windows.  When the window budget
/// is exhausted [tryConsume] returns false, and the caller should pause
/// and wait for [onCapacityAvailable] before resuming.
///
/// When the limit is 0 (unlimited) the limiter is a complete no-op — zero
/// allocation, no timer, no overhead.
class SpeedLimiter {
  int _limitBytesPerSec = 0;
  int _bytesThisWindow = 0;
  int _windowStartMs = 0;
  Timer? _refillTimer;
  final _capacityController = StreamController<void>.broadcast();
  bool _hasPendingListener = false;

  /// Whether this limiter is actively capping throughput.
  bool get isActive => _limitBytesPerSec > 0;

  /// Updates the speed limit.
  ///
  /// [kbps] — kilobytes per second.  0 disables (no-op passthrough).
  /// Values above 0 will be enforced as a soft cap with ~500 ms granularity.
  void setLimit(int kbps) {
    final newLimit = kbps * 1024;
    if (newLimit == _limitBytesPerSec) return;
    _limitBytesPerSec = newLimit;
    _bytesThisWindow = 0;
    _windowStartMs = DateTime.now().millisecondsSinceEpoch;
    _refillTimer?.cancel();
    _refillTimer = null;

    if (newLimit > 0) {
      // Start a periodic refill timer that resets the window budget
      // every 500 ms so throughput never stalls for a full second.
      _refillTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        _bytesThisWindow = 0;
        _windowStartMs = DateTime.now().millisecondsSinceEpoch;
        if (_hasPendingListener && _bytesThisWindow < (_limitBytesPerSec ~/ 2)) {
          _hasPendingListener = false;
          _capacityController.add(null);
        }
      });
    }
  }

  /// Tries to consume [bytes] from the current window budget.
  ///
  /// Returns `true` if the caller may proceed immediately.
  /// Returns `false` if the window budget is exhausted — the caller
  /// should not write data and should instead pause the data source,
  /// then wait for [onCapacityAvailable] before resuming.
  bool tryConsume(int bytes) {
    if (_limitBytesPerSec <= 0) return true;

    final now = DateTime.now().millisecondsSinceEpoch;
    final elapsed = now - _windowStartMs;

    // Auto-refresh the window if the periodic timer hasn't fired yet
    // but enough wall-clock time has passed.
    if (elapsed >= 500) {
      _bytesThisWindow = 0;
      _windowStartMs = now;
    }

    if (_bytesThisWindow + bytes <= (_limitBytesPerSec ~/ 2)) {
      _bytesThisWindow += bytes;
      return true;
    }
    return false;
  }

  /// A future that completes when new capacity is available.
  ///
  /// Callers should await this after [tryConsume] returns false, then
  /// retry [tryConsume].
  Future<void> get onCapacityAvailable {
    if (_limitBytesPerSec <= 0) return Future<void>.value();
    _hasPendingListener = true;
    return _capacityController.stream.first;
  }

  /// Disposes internal timer and stream controller.
  void dispose() {
    _refillTimer?.cancel();
    _refillTimer = null;
    _capacityController.close();
  }
}

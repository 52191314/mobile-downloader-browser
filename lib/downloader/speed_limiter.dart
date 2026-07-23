import 'dart:async';

/// A debt-carrying token-bucket rate limiter for download throughput.
///
/// Unlike a simple sliding-window counter, this allows bursts up to
/// one second's worth of the limit and carries debt across windows so
/// large chunks are never artificially starved.  Throughput over any
/// multi-second period converges to exactly the configured limit.
///
/// ## Algorithm
///
/// Tokens accumulate at `limit / 1000` per millisecond up to
/// `limit` (1 s burst capacity).  [tryConsume] always deducts the
/// requested bytes even when insufficient tokens remain — the
/// resulting debt is repaid from future tokens.  It returns `true`
/// when the caller may proceed immediately and `false` when the
/// caller should pause and wait for [onCapacityAvailable] until the
/// debt is cleared (tokens > 0).
///
/// When the limit is 0 (unlimited) the limiter is a complete no-op.
class SpeedLimiter {
  int _limitBytesPerSec = 0;
  double _tokens = 0;
  int _lastRefillMs = 0;
  static const int _maxBurstMs = 1000;
  Timer? _signalTimer;
  final _capacityController = StreamController<void>.broadcast();
  bool _hasPendingListener = false;

  /// Whether this limiter is actively capping throughput.
  bool get isActive => _limitBytesPerSec > 0;

  /// Updates the speed limit.
  ///
  /// [kbps] — kilobytes per second.  0 disables (no-op passthrough).
  void setLimit(int kbps) {
    final newLimit = kbps * 1024;
    if (newLimit == _limitBytesPerSec) return;
    _limitBytesPerSec = newLimit;
    _tokens = newLimit.toDouble(); // start with full bucket
    _lastRefillMs = DateTime.now().millisecondsSinceEpoch;
    _signalTimer?.cancel();
    _signalTimer = null;

    if (newLimit > 0) {
      // Periodic signal so waiters can resume promptly after debt clears.
      _signalTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        _refill();
        if (_hasPendingListener && _tokens > 0) {
          _hasPendingListener = false;
          _capacityController.add(null);
        }
      });
    }
  }

  /// Refills the token bucket based on elapsed wall-clock time.
  void _refill() {
    if (_limitBytesPerSec <= 0) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final elapsed = now - _lastRefillMs;
    if (elapsed <= 0) return;
    _tokens += elapsed * (_limitBytesPerSec / 1000.0);
    final maxTokens = _limitBytesPerSec * _maxBurstMs ~/ 1000;
    if (_tokens > maxTokens) {
      _tokens = maxTokens.toDouble();
    }
    _lastRefillMs = now;
  }

  /// Tries to consume [bytes] from the current token budget.
  ///
  /// Always deducts the requested bytes, even when insufficient tokens
  /// remain (the deficit becomes debt).  Returns `true` if the caller
  /// may proceed immediately; returns `false` if the caller should
  /// pause and await [onCapacityAvailable] until the debt is cleared.
  bool tryConsume(int bytes) {
    if (_limitBytesPerSec <= 0) return true;
    _refill();
    _tokens -= bytes;
    // Cap negative debt to prevent unbounded deficit.
    final maxDebt = (_limitBytesPerSec * _maxBurstMs ~/ 1000).toDouble();
    if (_tokens < -maxDebt) {
      _tokens = -maxDebt;
    }
    return _tokens >= 0;
  }

  /// A future that completes when new capacity is available (debt repaid).
  Future<void> get onCapacityAvailable {
    if (_limitBytesPerSec <= 0) return Future<void>.value();
    _refill();
    if (_tokens > 0) return Future<void>.value();
    _hasPendingListener = true;
    return _capacityController.stream.first;
  }

  /// Disposes internal timer and stream controller.
  void dispose() {
    _signalTimer?.cancel();
    _signalTimer = null;
    _capacityController.close();
  }
}

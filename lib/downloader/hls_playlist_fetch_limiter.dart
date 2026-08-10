import 'dart:async';

/// Process-wide limiter for HLS playlist requests.
///
/// Playlist requests use WebView/browser bridges and are much more expensive
/// than segment requests. Keep this shared across all HlsDownloader instances
/// so batch downloads cannot overwhelm Chromium while segment concurrency
/// remains unchanged.
class HlsPlaylistFetchLimiter {
  HlsPlaylistFetchLimiter._();

  static final HlsPlaylistFetchLimiter instance = HlsPlaylistFetchLimiter._();

  static const int maxInFlight = 1;
  static const Duration maxQueueWait = Duration(seconds: 30);

  int _active = 0;
  final List<Completer<void>> _waiters = [];

  Future<void> _acquire() async {
    if (_active < maxInFlight) {
      _active++;
      return;
    }

    final waiter = Completer<void>();
    _waiters.add(waiter);
    try {
      await waiter.future.timeout(maxQueueWait);
      _active++;
    } on TimeoutException {
      _waiters.remove(waiter);
      rethrow;
    }
  }

  void _release() {
    // Classic counting semaphore: free the slot, then wake the oldest
    // waiter, which increments _active itself on resume. Decrementing
    // here AND letting the waiter increment keeps _active accurate.
    if (_active > 0) _active--;
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    }
  }

  Future<T> run<T>(Future<T> Function() operation) async {
    await _acquire();
    try {
      return await operation();
    } finally {
      _release();
    }
  }
}

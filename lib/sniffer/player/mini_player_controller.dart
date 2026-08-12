import 'package:flutter/foundation.dart';

import 'playback_engine.dart';
import 'playback_source.dart';

/// Owns a playing [PlaybackEngine] after it leaves the fullscreen player, so
/// the video can keep playing in a floating mini-player over the browser.
///
/// Lifecycle:
/// - [adopt] — the player screen hands the engine over when the system PIP
///   window is tapped/dismissed (instead of expanding back into the
///   fullscreen player, the app lands on the Browser with the video still
///   playing).
/// - The mini-player overlay renders [buildSurface] while [isActive].
/// - Tapping the overlay re-opens the fullscreen player with [engine] as a
///   *borrowed* engine — the controller stays the owner, so popping that
///   route returns to the mini-player instead of ending playback.
/// - [close] disposes the engine and clears state (the mini-player's close
///   button).
///
/// A singleton is deliberate: the engine must outlive every screen that
/// renders it, and there is exactly one video the user is watching at a time.
/// The revision notifier lets any widget subscribe to open/close transitions
/// without holding a reference to the engine.
class MiniPlayerController {
  MiniPlayerController._();

  /// Process-wide owner of the minimized video. Tests may construct a fresh
  /// instance via [reset] to avoid cross-test leakage.
  static final MiniPlayerController instance = MiniPlayerController._();

  PlaybackEngine? _engine;
  PlaybackSource? _source;

  /// Bumped on every adopt/close so UI can rebuild without coupling to the
  /// engine object itself.
  final ValueNotifier<int> _revision = ValueNotifier<int>(0);

  ValueListenable<int> get revision => _revision;

  /// True while a video is minimized. The controller owns the only engine
  /// reference and nulls it on [close], so `_engine != null` is sufficient.
  bool get isActive => _engine != null;

  /// The borrowed engine, when active. The caller must NOT dispose it.
  PlaybackEngine? get engine => _engine;

  /// The source the engine was playing (post variant-switch state included).
  PlaybackSource? get source => _source;

  /// Hands [engine] over to the mini-player. Idempotent for the same engine
  /// (the PIP-exit path can fire once per exit while a borrowed fullscreen
  /// route is also being popped).
  void adopt(PlaybackEngine engine, PlaybackSource source) {
    if (identical(_engine, engine)) return;
    _engine = engine;
    _source = source;
    _revision.value++;
  }

  /// Disposes the video and clears the mini-player. Safe to call when idle.
  Future<void> close() async {
    final engine = _engine;
    _engine = null;
    _source = null;
    _revision.value++;
    try {
      await engine?.dispose();
    } catch (_) {
      // The engine may already be mid-teardown; the mini-player must still
      // disappear cleanly.
    }
  }

  /// Test hook: clears state WITHOUT disposing the engine (the test owns it).
  @visibleForTesting
  void reset() {
    _engine = null;
    _source = null;
    _revision.value++;
  }
}

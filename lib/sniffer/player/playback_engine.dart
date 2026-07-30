import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'playback_source.dart';
import 'playback_state.dart';

/// Which backend decodes and renders. Persisted in settings so a user stuck on
/// one stack can move to the other without a rebuild.
enum PlaybackEngineKind {
  /// `video_player` — ExoPlayer on Android. Smallest, uses the platform
  /// decoders, and is the stack the rest of the Flutter ecosystem assumes.
  videoPlayer,

  /// `media_kit` — libmpv. Its own demuxer, decoders and HTTP client, so it
  /// plays streams ExoPlayer refuses and fails differently when it does fail.
  mediaKit,
}

extension PlaybackEngineKindLabel on PlaybackEngineKind {
  String get label => switch (this) {
        PlaybackEngineKind.videoPlayer => 'System (ExoPlayer)',
        PlaybackEngineKind.mediaKit => 'libmpv (media_kit)',
      };

  String get description => switch (this) {
        PlaybackEngineKind.videoPlayer =>
          'Android\'s own player. Lightest on battery and memory.',
        PlaybackEngineKind.mediaKit =>
          'Bundled decoders. Try this when a stream loads but will not play.',
      };

  PlaybackEngineKind get other => switch (this) {
        PlaybackEngineKind.videoPlayer => PlaybackEngineKind.mediaKit,
        PlaybackEngineKind.mediaKit => PlaybackEngineKind.videoPlayer,
      };
}

/// A playback backend behind one interface, so the screen never knows which is
/// running and either can be swapped mid-session.
abstract class PlaybackEngine {
  PlaybackEngineKind get kind;

  /// Observable state. Never emits after [dispose].
  ValueListenable<PlaybackState> get state;

  /// Opens [source] and begins playback. Completing does **not** mean frames
  /// are rendering — watch [state] for that.
  Future<void> open(PlaybackSource source);

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setSpeed(double speed);

  /// Volume as 0..1. Engines with other ranges convert internally.
  Future<void> setVolume(double volume);

  /// The render surface. Each backend has its own; the screen just places it.
  Widget buildSurface({BoxFit fit = BoxFit.contain});

  // --- Scrub preview -------------------------------------------------------
  // Frame-at-position while dragging the seek bar. Needs a second, muted
  // decoder on the same source, so it has to live behind the engine rather
  // than in the screen.
  //
  // Always optional. A second connection to a signed CDN link can be refused,
  // or can burn a concurrency slot the main stream needs, so every path here
  // fails soft: no preview, playback untouched.

  /// False when this backend cannot render preview frames at all — the screen
  /// then shows a timestamp-only scrub bubble.
  bool get supportsScrubPreview;

  /// Spins up the preview decoder. Called once when a drag begins; safe to
  /// call repeatedly. Never throws — check [scrubPreviewReady] after.
  Future<void> prepareScrubPreview();

  /// True once preview frames can actually be rendered.
  bool get scrubPreviewReady;

  /// Moves the preview to [position]. Callers should debounce.
  Future<void> seekScrubPreview(Duration position);

  /// The preview surface, or null when it is not ready.
  Widget? buildScrubPreview();

  /// Flat key/value dump for the diagnostics panel and bug reports. Must never
  /// include header *values* — those carry session cookies.
  Map<String, Object?> diagnostics();

  Future<void> dispose();
}

/// Shared state plumbing: the notifier, the stall watchdog, and disposal
/// guards. Both backends behave identically here, and getting the watchdog
/// right once is the point of having this layer.
abstract class PlaybackEngineBase implements PlaybackEngine {
  PlaybackEngineBase();

  final ValueNotifier<PlaybackState> _state =
      ValueNotifier<PlaybackState>(const PlaybackState());

  Timer? _stallTimer;
  bool _disposed = false;

  PlaybackSource? currentSource;

  @override
  ValueListenable<PlaybackState> get state => _state;

  PlaybackState get value => _state.value;

  bool get isDisposed => _disposed;

  /// How long a stream may sit at 0:00, not buffering, before we call it
  /// stalled. Long enough that a slow handshake is not libelled; short enough
  /// that the user is not left staring at black.
  static const Duration stallTimeout = Duration(seconds: 6);

  @protected
  void emit(PlaybackState next) {
    if (_disposed) return;
    _state.value = next;
  }

  @protected
  void update(PlaybackState Function(PlaybackState current) transform) {
    if (_disposed) return;
    _state.value = transform(_state.value);
  }

  /// Arms the watchdog. Call right after the backend accepts the source.
  @protected
  void armStallWatchdog() {
    _stallTimer?.cancel();
    if (_disposed) return;
    _stallTimer = Timer(stallTimeout, () {
      if (_disposed) return;
      final s = _state.value;
      // Buffering means it is still trying, and any progress at all clears
      // the suspicion. Only a stream that opened and then did nothing counts.
      if (s.isBuffering || s.everAdvanced || s.position > Duration.zero) return;
      if (s.status != PlaybackStatus.ready) return;
      emit(s.copyWith(status: PlaybackStatus.stalled));
    });
  }

  @protected
  void cancelStallWatchdog() {
    _stallTimer?.cancel();
    _stallTimer = null;
  }

  /// Records forward progress, clearing a stalled state if the stream recovers
  /// on its own.
  @protected
  void notePosition(Duration position) {
    if (_disposed) return;
    final s = _state.value;
    final advanced = s.everAdvanced || position > Duration.zero;
    if (s.status == PlaybackStatus.stalled && position > Duration.zero) {
      emit(s.copyWith(
        position: position,
        everAdvanced: true,
        status: PlaybackStatus.ready,
      ));
      return;
    }
    emit(s.copyWith(position: position, everAdvanced: advanced));
  }

  @protected
  void fail(String message) {
    cancelStallWatchdog();
    update((s) => s.copyWith(
          status: PlaybackStatus.failed,
          errorMessage: message,
          isBuffering: false,
          isPlaying: false,
        ));
  }

  // Scrub preview is opt-in. Engines that can do it override all four.
  @override
  bool get supportsScrubPreview => false;

  @override
  bool get scrubPreviewReady => false;

  @override
  Future<void> prepareScrubPreview() async {}

  @override
  Future<void> seekScrubPreview(Duration position) async {}

  @override
  Widget? buildScrubPreview() => null;

  @override
  Map<String, Object?> diagnostics() {
    final s = _state.value;
    final src = currentSource;
    return {
      'engine': kind.label,
      'status': s.status.name,
      'playing': s.isPlaying,
      'buffering': s.isBuffering,
      'everAdvanced': s.everAdvanced,
      'position': _fmt(s.position),
      'duration': s.duration > Duration.zero ? _fmt(s.duration) : 'live/unknown',
      'buffered': _fmt(s.buffered),
      'videoSize': s.hasVideoTrack
          ? '${s.videoSize.width.toInt()}x${s.videoSize.height.toInt()}'
          : 'none',
      'speed': s.speed,
      'error': s.errorMessage ?? '—',
      // Names only. Values hold cookies.
      'headers': src?.headerNames.join(', ') ?? '—',
      'variants': src?.variants.length ?? 0,
      'url': src?.url ?? '—',
    };
  }

  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$m:$ss';
  }

  @override
  @mustCallSuper
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    cancelStallWatchdog();
    _state.dispose();
  }
}

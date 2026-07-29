import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../playback_engine.dart';
import '../playback_source.dart';
import '../playback_state.dart';

/// `media_kit` / libmpv backend.
///
/// Carries its own demuxer, decoders and HTTP client, so it is the fallback
/// when ExoPlayer opens a stream and renders nothing. It also reports real
/// error strings from mpv rather than one opaque PlatformException.
class MediaKitEngine extends PlaybackEngineBase {
  Player? _player;
  VideoController? _videoController;
  final List<StreamSubscription<dynamic>> _subs = [];

  int _generation = 0;

  @override
  PlaybackEngineKind get kind => PlaybackEngineKind.mediaKit;

  @override
  Future<void> open(PlaybackSource source) async {
    currentSource = source;
    emit(const PlaybackState(status: PlaybackStatus.opening));

    final uri = Uri.tryParse(source.url);
    if (uri == null || !uri.hasScheme) {
      fail('That link is not a valid address, so there is nothing to play.');
      return;
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      fail(
        'This page hands its video to the browser in a form that cannot be '
        'played directly ($scheme). Open the capture tray and pick the '
        'stream itself.',
      );
      return;
    }

    await _teardown();
    final generation = ++_generation;

    try {
      final player = Player();
      _player = player;
      _videoController = VideoController(player);
      _wireStreams(player, generation);

      await player.open(
        Media(source.url, httpHeaders: source.headers),
        play: true,
      );
      if (isDisposed || generation != _generation) return;

      update((s) => s.copyWith(
            status: PlaybackStatus.ready,
            clearError: true,
          ));

      if (source.startAt > Duration.zero) {
        await player.seek(source.startAt);
      }
      armStallWatchdog();
    } catch (e) {
      if (isDisposed || generation != _generation) return;
      fail('Could not start this stream: $e');
    }
  }

  void _wireStreams(Player player, int generation) {
    bool stale() => isDisposed || generation != _generation;

    _subs.addAll([
      player.stream.playing.listen((v) {
        if (stale()) return;
        update((s) => s.copyWith(isPlaying: v));
      }),
      player.stream.buffering.listen((v) {
        if (stale()) return;
        update((s) => s.copyWith(isBuffering: v));
      }),
      player.stream.position.listen((v) {
        if (stale()) return;
        notePosition(v);
      }),
      player.stream.duration.listen((v) {
        if (stale()) return;
        update((s) => s.copyWith(duration: v));
      }),
      player.stream.buffer.listen((v) {
        if (stale()) return;
        update((s) => s.copyWith(buffered: v));
      }),
      player.stream.completed.listen((v) {
        if (stale() || !v) return;
        update((s) => s.copyWith(status: PlaybackStatus.completed));
      }),
      player.stream.width.listen((w) {
        if (stale()) return;
        update((s) => s.copyWith(
              videoSize: Size((w ?? 0).toDouble(), s.videoSize.height),
            ));
      }),
      player.stream.height.listen((h) {
        if (stale()) return;
        update((s) => s.copyWith(
              videoSize: Size(s.videoSize.width, (h ?? 0).toDouble()),
            ));
      }),
      player.stream.rate.listen((v) {
        if (stale()) return;
        update((s) => s.copyWith(speed: v));
      }),
      // mpv reports real diagnostics here — surface them instead of guessing.
      player.stream.error.listen((message) {
        if (stale()) return;
        if (message.trim().isEmpty) return;
        fail(message);
      }),
    ]);
  }

  @override
  Future<void> play() async {
    await _player?.play();
  }

  @override
  Future<void> pause() async {
    await _player?.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    await _player?.seek(position);
  }

  @override
  Future<void> setSpeed(double speed) async {
    await _player?.setRate(speed);
  }

  @override
  Future<void> setVolume(double volume) async {
    // media_kit takes 0..100; the interface is 0..1.
    await _player?.setVolume((volume.clamp(0.0, 1.0)) * 100);
    update((s) => s.copyWith(volume: volume));
  }

  @override
  Widget buildSurface({BoxFit fit = BoxFit.contain}) {
    final controller = _videoController;
    if (controller == null) return const SizedBox.expand();
    return Video(
      controller: controller,
      fit: fit,
      // The screen owns every control; the packaged ones would double up.
      controls: NoVideoControls,
      fill: const Color(0xFF000000),
      // AuroraPlayerScreen owns keep-awake for both backends via the
      // player_window channel. Leaving this on would make media_kit the only
      // engine that keeps the screen up, which is how the two drifted apart.
      wakelock: false,
    );
  }

  // --- Scrub preview ---------------------------------------------------

  Player? _previewPlayer;
  VideoController? _previewController;
  bool _previewStarting = false;
  bool _previewReady = false;

  @override
  bool get supportsScrubPreview => true;

  @override
  bool get scrubPreviewReady => _previewReady;

  @override
  Future<void> prepareScrubPreview() async {
    if (_previewReady || _previewStarting || isDisposed) return;
    final source = currentSource;
    if (source == null) return;
    if (value.duration <= Duration.zero) return;

    _previewStarting = true;
    try {
      final player = Player();
      final controller = VideoController(player);
      await player.open(
        Media(source.url, httpHeaders: source.headers),
        play: false,
      );
      await player.setVolume(0);
      if (isDisposed) {
        await player.dispose();
        return;
      }
      _previewPlayer = player;
      _previewController = controller;
      _previewReady = true;
      update((s) => s);
    } catch (_) {
      _previewReady = false;
      _previewPlayer = null;
      _previewController = null;
    } finally {
      _previewStarting = false;
    }
  }

  @override
  Future<void> seekScrubPreview(Duration position) async {
    final player = _previewPlayer;
    if (player == null || !_previewReady) return;
    try {
      await player.seek(position);
      await player.pause();
      update((s) => s);
    } catch (_) {
      // Keep the last frame rather than blanking.
    }
  }

  @override
  Widget? buildScrubPreview() {
    final controller = _previewController;
    if (controller == null || !_previewReady) return null;
    return Video(
      controller: controller,
      fit: BoxFit.cover,
      controls: NoVideoControls,
      fill: const Color(0xFF000000),
      wakelock: false,
    );
  }

  Future<void> _teardownPreview() async {
    final player = _previewPlayer;
    _previewPlayer = null;
    _previewController = null;
    _previewReady = false;
    _previewStarting = false;
    await player?.dispose();
  }

  Future<void> _teardown() async {
    await _teardownPreview();
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    final player = _player;
    _player = null;
    _videoController = null;
    await player?.dispose();
  }

  @override
  Future<void> dispose() async {
    await _teardown();
    await super.dispose();
  }
}

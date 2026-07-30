import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import '../playback_engine.dart';
import '../playback_source.dart';
import '../playback_state.dart';

/// `video_player` / ExoPlayer backend.
class VideoPlayerEngine extends PlaybackEngineBase {
  VideoPlayerController? _controller;
  VoidCallback? _listener;

  /// Rebuilt on every open so a stale surface from a previous source can never
  /// be painted against a new controller.
  int _generation = 0;

  @override
  PlaybackEngineKind get kind => PlaybackEngineKind.videoPlayer;

  @override
  Future<void> open(PlaybackSource source) async {
    currentSource = source;
    emit(const PlaybackState(status: PlaybackStatus.opening));

    final uri = Uri.tryParse(source.url);
    if (uri == null || !uri.hasScheme) {
      fail('That link is not a valid address, so there is nothing to play.');
      return;
    }
    // ExoPlayer only speaks network URLs here. A blob:/data: source is a page
    // construct that was never resolved to a real stream — say so plainly
    // rather than handing it over and rendering black.
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      fail(
        'This page hands its video to the browser in a form that cannot be '
        'played directly ($scheme). Open the capture tray and pick the '
        'stream itself.',
      );
      return;
    }

    // The preview decoder is bound to the previous URL — a quality switch
    // would otherwise scrub against the old rendition.
    await _teardownPreview();
    await _teardownController();
    final generation = ++_generation;

    final headers = Map<String, String>.from(source.headers);
    // Some CDNs reject clients that send no Accept at all.
    if (!headers.keys.any((k) => k.toLowerCase() == 'accept')) {
      headers['Accept'] = '*/*';
    }

    final controller = VideoPlayerController.networkUrl(
      uri,
      httpHeaders: headers,
      formatHint: _formatHintFor(source.url),
    );
    _controller = controller;

    try {
      void listener() => _onControllerTick(controller, generation);
      _listener = listener;
      controller.addListener(listener);

      await controller.initialize();
      if (isDisposed || generation != _generation) {
        await controller.dispose();
        return;
      }

      final size = controller.value.size;
      update((s) => s.copyWith(
            status: PlaybackStatus.ready,
            duration: controller.value.duration,
            videoSize: Size(size.width, size.height),
            clearError: true,
          ));

      if (source.startAt > Duration.zero) {
        await controller.seekTo(source.startAt);
      }
      await controller.play();
      armStallWatchdog();
    } catch (e) {
      if (isDisposed || generation != _generation) return;
      fail(_describeOpenFailure(e, headers));
    }
  }

  void _onControllerTick(VideoPlayerController controller, int generation) {
    if (isDisposed || generation != _generation) return;
    final v = controller.value;

    if (v.hasError) {
      fail(v.errorDescription ?? 'Playback failed for an unreported reason.');
      return;
    }

    final size = v.size;
    update((s) => s.copyWith(
          isPlaying: v.isPlaying,
          isBuffering: v.isBuffering,
          duration: v.duration,
          videoSize: Size(size.width, size.height),
          buffered: v.buffered.isNotEmpty ? v.buffered.last.end : Duration.zero,
          status: v.isCompleted && s.status == PlaybackStatus.ready
              ? PlaybackStatus.completed
              : s.status,
        ));
    notePosition(v.position);
  }

  /// video_player reports network and codec problems through one opaque
  /// PlatformException, so turn the common ones into something actionable.
  String _describeOpenFailure(Object error, Map<String, String> headers) {
    final text = error.toString();
    final hasCookie = headers.keys.any((k) => k.toLowerCase() == 'cookie');

    if (text.contains('403') || text.toLowerCase().contains('forbidden')) {
      return hasCookie
          ? 'The server refused this stream (403). The link is tied to the '
              'page session and has probably expired — reopen the video page, '
              'then try again.'
          : 'The server refused this stream (403) and no session cookies were '
              'sent. Open the video page in the browser first, then retry.';
    }
    if (text.contains('404')) {
      return 'That stream is gone from the server (404).';
    }
    if (text.toLowerCase().contains('source error') ||
        text.toLowerCase().contains('unrecognized') ||
        text.toLowerCase().contains('none of the available extractors')) {
      return 'Android could not read this stream\'s format. Switching the '
          'playback engine to libmpv usually plays it.';
    }
    return 'Could not start this stream: $text';
  }

  static VideoFormat? _formatHintFor(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('.m3u8') || lower.contains('mpegurl')) {
      return VideoFormat.hls;
    }
    if (lower.contains('.mpd') || lower.contains('dash+xml')) {
      return VideoFormat.dash;
    }
    return null;
  }

  @override
  Future<void> play() async {
    await _controller?.play();
  }

  @override
  Future<void> pause() async {
    await _controller?.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    await _controller?.seekTo(position);
  }

  @override
  Future<void> setSpeed(double speed) async {
    await _controller?.setPlaybackSpeed(speed);
    update((s) => s.copyWith(speed: speed));
  }

  @override
  Future<void> setVolume(double volume) async {
    await _controller?.setVolume(volume);
    update((s) => s.copyWith(volume: volume));
  }

  @override
  Widget buildSurface({BoxFit fit = BoxFit.contain}) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.expand();
    }
    final size = controller.value.size;
    return ValueListenableBuilder<PlaybackState>(
      valueListenable: state,
      builder: (context, _, _) {
        return FittedBox(
          fit: fit,
          child: SizedBox(
            width: size.width > 0 ? size.width : 16,
            height: size.height > 0 ? size.height : 9,
            child: VideoPlayer(controller),
          ),
        );
      },
    );
  }

  // --- Scrub preview ---------------------------------------------------

  VideoPlayerController? _preview;
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
    // Live streams have nothing to scrub to.
    if (value.duration <= Duration.zero) return;

    final uri = Uri.tryParse(source.url);
    if (uri == null || !uri.hasScheme) return;

    _previewStarting = true;
    try {
      final headers = Map<String, String>.from(source.headers);
      if (!headers.keys.any((k) => k.toLowerCase() == 'accept')) {
        headers['Accept'] = '*/*';
      }
      final c = VideoPlayerController.networkUrl(
        uri,
        httpHeaders: headers,
        formatHint: _formatHintFor(source.url),
      );
      await c.initialize();
      await c.setVolume(0);
      await c.pause();
      if (isDisposed) {
        await c.dispose();
        return;
      }
      _preview = c;
      _previewReady = true;
      // Nudge the screen so the bubble swaps from timestamp to frame.
      update((s) => s);
    } catch (_) {
      // Refused second connection, expired token, concurrency cap — all fine.
      // The scrub bubble falls back to a timestamp.
      _previewReady = false;
      _preview = null;
    } finally {
      _previewStarting = false;
    }
  }

  @override
  Future<void> seekScrubPreview(Duration position) async {
    final c = _preview;
    if (c == null || !_previewReady) return;
    try {
      await c.seekTo(position);
      await c.pause();
      update((s) => s);
    } catch (_) {
      // Leave the last good frame up rather than blanking the bubble.
    }
  }

  @override
  Widget? buildScrubPreview() {
    final c = _preview;
    if (c == null || !_previewReady || !c.value.isInitialized) return null;
    final size = c.value.size;
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: size.width > 0 ? size.width : 16,
        height: size.height > 0 ? size.height : 9,
        child: VideoPlayer(c),
      ),
    );
  }

  Future<void> _teardownPreview() async {
    final c = _preview;
    _preview = null;
    _previewReady = false;
    _previewStarting = false;
    await c?.dispose();
  }

  Future<void> _teardownController() async {
    final controller = _controller;
    final listener = _listener;
    _controller = null;
    _listener = null;
    if (controller == null) return;
    if (listener != null) controller.removeListener(listener);
    await controller.dispose();
  }

  @override
  Future<void> dispose() async {
    await _teardownPreview();
    await _teardownController();
    await super.dispose();
  }
}

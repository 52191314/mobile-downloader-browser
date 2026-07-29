import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';

/// Where a stream is in its lifecycle.
///
/// [stalled] is the state the previous player had no name for: the engine
/// opened the stream and reported a duration and a frame size, then never
/// advanced. That is a black rectangle with no audio and no error — and
/// because nothing modelled it, the UI had nothing to show. It is a first
/// class status here.
enum PlaybackStatus {
  idle,
  opening,
  ready,
  stalled,
  completed,
  failed,
}

@immutable
class PlaybackState {
  const PlaybackState({
    this.status = PlaybackStatus.idle,
    this.isPlaying = false,
    this.isBuffering = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.buffered = Duration.zero,
    this.videoSize = Size.zero,
    this.speed = 1.0,
    this.volume = 1.0,
    this.errorMessage,
    this.everAdvanced = false,
  });

  final PlaybackStatus status;
  final bool isPlaying;
  final bool isBuffering;
  final Duration position;
  final Duration duration;
  final Duration buffered;
  final Size videoSize;
  final double speed;
  final double volume;
  final String? errorMessage;

  /// True once the clock has moved past zero at least once. Distinguishes
  /// "still starting" from "opened and permanently stuck".
  final bool everAdvanced;

  bool get isLive => duration <= Duration.zero;
  bool get hasVideoTrack => videoSize.width > 0 && videoSize.height > 0;

  /// Aspect ratio to lay the surface out with, falling back to 16:9 before the
  /// first frame reports real dimensions.
  double get aspectRatio {
    if (!hasVideoTrack) return 16 / 9;
    return videoSize.width / videoSize.height;
  }

  bool get canShowSurface =>
      status == PlaybackStatus.ready ||
      status == PlaybackStatus.stalled ||
      status == PlaybackStatus.completed;

  PlaybackState copyWith({
    PlaybackStatus? status,
    bool? isPlaying,
    bool? isBuffering,
    Duration? position,
    Duration? duration,
    Duration? buffered,
    Size? videoSize,
    double? speed,
    double? volume,
    String? errorMessage,
    bool? everAdvanced,
    bool clearError = false,
  }) {
    return PlaybackState(
      status: status ?? this.status,
      isPlaying: isPlaying ?? this.isPlaying,
      isBuffering: isBuffering ?? this.isBuffering,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      buffered: buffered ?? this.buffered,
      videoSize: videoSize ?? this.videoSize,
      speed: speed ?? this.speed,
      volume: volume ?? this.volume,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      everAdvanced: everAdvanced ?? this.everAdvanced,
    );
  }
}

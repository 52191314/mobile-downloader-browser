import 'engines/media_kit_engine.dart';
import 'engines/video_player_engine.dart';
import 'playback_engine.dart';

/// Builds the backend for [kind].
///
/// The only place in the app that knows both implementations exist — everything
/// else talks to [PlaybackEngine].
PlaybackEngine createPlaybackEngine(PlaybackEngineKind kind) {
  return switch (kind) {
    PlaybackEngineKind.videoPlayer => VideoPlayerEngine(),
    PlaybackEngineKind.mediaKit => MediaKitEngine(),
  };
}

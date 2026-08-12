import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/aurora_palette.dart';
import '../player/mini_player_controller.dart';
import '../player/playback_engine.dart';
import '../player/playback_state.dart';

/// Draggable floating video window parked over the browser while a video
/// keeps playing after the fullscreen player closed (system-PIP exit).
///
/// - Drag anywhere to move it.
/// - Tap the video to expand back into the fullscreen player (the engine is
///   borrowed — popping that route returns to this mini-player).
/// - Play/pause and close (X) live as scrim buttons over the video.
class MiniPlayerOverlay extends StatefulWidget {
  const MiniPlayerOverlay({
    super.key,
    this.bottomInset = 12,
    this.onExpand,
  });

  /// Space to leave clear below the card (the browser's bottom bar).
  final double bottomInset;

  /// Re-opens the fullscreen player with the borrowed engine.
  final VoidCallback? onExpand;

  @override
  State<MiniPlayerOverlay> createState() => _MiniPlayerOverlayState();
}

class _MiniPlayerOverlayState extends State<MiniPlayerOverlay> {
  static const double _width = 180.0;
  static const double _height = 102.0; // ~16:9

  /// Unclamped drag position; null = parked at the default corner. Storing
  /// the raw value (not the clamped render position) lets the user drag back
  /// out of an edge instead of fighting the clamp.
  Offset? _offset;

  double _clampTo(double value, double limit) {
    if (limit <= 0) return 0;
    return value.clamp(0.0, limit).toDouble();
  }

  /// Resumes playback, restarting from the beginning when the video already
  /// ended — both engines sit on the last frame after completion, where
  /// play() alone is a no-op ("stuck at the last frame").
  Future<void> _playFrom(PlaybackEngine engine, PlaybackState state) async {
    if (state.duration > Duration.zero && state.position >= state.duration) {
      await engine.seek(Duration.zero);
    }
    await engine.play();
  }

  @override
  Widget build(BuildContext context) {
    final controller = MiniPlayerController.instance;
    return ValueListenableBuilder<int>(
      valueListenable: controller.revision,
      builder: (context, _, _) {
        if (!controller.isActive) return const SizedBox.shrink();
        final engine = controller.engine!;
        // Positioned.fill is the direct Stack child (ValueListenableBuilder
        // is a plain wrapper — ParentData flows through). LayoutBuilder must
        // NOT sit between the Stack and a Positioned, so the card is placed
        // by an inner Stack instead.
        return Positioned.fill(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final defaultOffset = Offset(
                constraints.maxWidth - _width - 12,
                constraints.maxHeight - _height - widget.bottomInset,
              );
              final offset = _offset ?? defaultOffset;
              return Stack(
                children: [
                  Positioned(
                    left: _clampTo(offset.dx, constraints.maxWidth - _width),
                    top: _clampTo(offset.dy, constraints.maxHeight - _height),
                    child: ValueListenableBuilder<PlaybackState>(
                      valueListenable: engine.state,
                      builder: (context, state, _) {
                        return GestureDetector(
                          onPanUpdate: (d) {
                            setState(() => _offset = offset + d.delta);
                          },
                          child: Container(
                            key: const Key('mini_player_card'),
                            width: _width,
                            height: _height,
                            clipBehavior: Clip.antiAlias,
                            decoration: BoxDecoration(
                              color: Colors.black,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: context.ac.borderStrong,
                                width: 1,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.4),
                                  blurRadius: 14,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                // Tap the video → fullscreen player (engine
                                // is borrowed, so playback continues).
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: widget.onExpand,
                                  child: engine.buildSurface(fit: BoxFit.contain),
                                ),
                                Positioned(
                                  top: 4,
                                  right: 4,
                                  child: _ScrimIconButton(
                                    icon: Icons.close_rounded,
                                    tooltip: 'Close video',
                                    onTap: () =>
                                        unawaited(controller.close()),
                                  ),
                                ),
                                Positioned(
                                  left: 4,
                                  bottom: 4,
                                  child: _ScrimIconButton(
                                    icon: state.isPlaying
                                        ? Icons.pause_rounded
                                        : Icons.play_arrow_rounded,
                                    tooltip: state.isPlaying ? 'Pause' : 'Play',
                                    onTap: () {
                                      if (state.isPlaying) {
                                        unawaited(engine.pause());
                                      } else {
                                        unawaited(_playFrom(engine, state));
                                      }
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

/// Small circular icon button on a dark scrim, sized for the mini-player.
class _ScrimIconButton extends StatelessWidget {
  const _ScrimIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.45),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Tooltip(
          message: tooltip,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(icon, size: 18, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

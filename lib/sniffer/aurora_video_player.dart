import 'dart:async';

import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../platform/public_downloads_service.dart';
import '../theme/aurora_palette.dart';
import 'sniffer_url_utils.dart';

/// One selectable HLS/DASH (or progressive) quality for [AuroraVideoPlayer].
class PlayerQualityOption {
  final String url;
  final String label;
  final int? height;
  final int? bandwidth;

  const PlayerQualityOption({
    required this.url,
    required this.label,
    this.height,
    this.bandwidth,
  });
}

/// Which value a vertical drag is currently adjusting.
enum _DragMode { none, brightness, volume }

/// A transient overlay pill shown for a gesture (seek, brightness, volume).
///
/// Deliberately small and top-anchored: a gesture indicator sits on top of the
/// thing the user is trying to watch, so it stays out of the picture and never
/// explains itself. Discoverability belongs in the settings/help copy, not in a
/// card rendered over the video on every long press.
class _GestureHud {
  final IconData icon;
  final String label;

  /// 0..1 for the thin level bar (brightness/volume). Null hides the bar.
  final double? value;

  const _GestureHud({required this.icon, required this.label, this.value});
}

/// A full-screen custom video player with UC Browser-style controls.
///
/// Wraps [VideoPlayerController] directly (no Chewie) so we own every pixel
/// of the UI: header bar, scrub preview, hold-to-speed-up, lockable controls,
/// rotation, and custom bottom bar.
///
/// - Tap toggles control overlays (does **not** play/pause — use the center
///   button or bottom play control).
/// - Double-tap seeks ∓10s on the left/right third, play/pause in the middle.
/// - Vertical drag adjusts brightness (left half) or volume (right half).
/// - Long-press boosts speed to a fixed 2×; other rates live in the speed menu.
/// - Buffering always shows a spinner + label (slow network is not silent).
/// - Rotation button forces landscape / returns to sensor orientation.
/// - Lock icon at the left edge disables overlay controls.
/// - When [qualityOptions] has 2+ entries, a quality picker is shown.
class AuroraVideoPlayer extends StatefulWidget {
  final String url;
  final String title;
  final Map<String, String> headers;

  /// Called when the user taps the download button.
  /// Returning `null` means no download action.
  final VoidCallback? onDownload;

  /// Called when the user toggles the star (favorite) button.
  /// Receives the current video URL as a convenience for bookmarking.
  final Future<void> Function(String url)? onFavorite;

  /// Optional – if given, used for the "Add to Favorites" flow.
  final String? sourcePageUrl;

  /// Alternate stream qualities (HLS variants, etc.). When length ≥ 2, the
  /// player shows an in-UI quality picker.
  final List<PlayerQualityOption> qualityOptions;

  /// Re-resolve auth/CDN headers when the user switches quality. If null,
  /// the current [headers] map is reused for the new URL.
  final Future<Map<String, String>> Function(String url)? resolveHeadersForUrl;

  const AuroraVideoPlayer({
    super.key,
    required this.url,
    required this.title,
    this.headers = const {},
    this.onDownload,
    this.onFavorite,
    this.sourcePageUrl,
    this.qualityOptions = const [],
    this.resolveHeadersForUrl,
  });

  @override
  State<AuroraVideoPlayer> createState() => _AuroraVideoPlayerState();
}

class _AuroraVideoPlayerState extends State<AuroraVideoPlayer> {
  // --- Player ---
  VideoPlayerController? _controller;
  bool _initialized = false;
  String? _error;
  VoidCallback? _controllerListener;

  /// Active stream URL/headers (may differ from [widget.url] after a quality switch).
  late String _activeUrl;
  late Map<String, String> _activeHeaders;
  String _activeQualityLabel = 'Auto';
  bool _switchingQuality = false;

  // --- UI state ---
  bool _controlsVisible = true;
  bool _locked = false;

  // --- Seeking ---
  bool _isSeeking = false;
  Duration _seekPosition = Duration.zero;
  /// 0..1 along the visible track (for preview popup alignment).
  double _seekFraction = 0.0;

  /// Secondary muted player used only for YouTube-style scrub thumbnails.
  VideoPlayerController? _previewController;
  bool _previewReady = false;
  bool _previewInitStarted = false;
  Timer? _previewSeekDebounce;
  /// Last-seen `isPlaying` so controller-driven play/pause icon changes (e.g.
  /// when playback finishes) still trigger a full rebuild. Pure position
  /// updates no longer need one — see [_buildBottomControls].
  bool _wasPlaying = false;

  // --- Speed ---
  double _currentSpeed = 1.0;
  bool _holdSpeedActive = false;
  double _holdSpeedPrev = 1.0;

  /// Rate applied while holding. Fixed: the vertical axis belongs to
  /// brightness/volume, and any other rate is one tap away in the speed menu.
  static const double _holdSpeedRate = 2.0;

  // --- Gesture HUD (transient pill; hold-speed renders from _holdSpeedActive) ---
  _GestureHud? _hud;
  Timer? _hudTimer;

  // --- Vertical drag: brightness (left half) / volume (right half) ---
  _DragMode _dragMode = _DragMode.none;
  double _dragStartValue = 0;
  double _dragStartY = 0;
  double _brightness = 0.5;
  double _volume = 1.0;
  static const MethodChannel _windowChannel =
      MethodChannel('aurora_downloader/player_window');

  // --- Double-tap detection (hand-rolled so single tap stays instant) ---
  DateTime? _lastTapAt;
  Offset? _lastTapPos;

  // --- Aspect ratio ---
  BoxFit _fit = BoxFit.contain;

  // --- Orientation (false = system/sensor; true = landscape locked) ---
  bool _landscapeForced = false;

  // --- Timers ---
  Timer? _autoHideTimer;
  Timer? _clockTimer;

  // --- Play/pause icon flash (center button / double-feedback) ---
  bool _showPlayPauseIcon = false;
  Timer? _playPauseIconTimer;

  // --- Buffering ---
  bool _isBuffering = false;
  bool _isBufferingSlow = false;
  Timer? _bufferingTimer;

  // --- Star ---
  bool _isFavorited = false;

  // --- PiP ---
  static const MethodChannel _pipChannel = MethodChannel('aurora_downloader/pip');
  bool _isInPipMode = false;

  // --- Dimensions (for fit switching when not initialized yet) ---
  double _videoWidth = 16;
  double _videoHeight = 9;

  bool get _hasQualityPicker => widget.qualityOptions.length >= 2;

  @override
  void initState() {
    super.initState();
    _activeUrl = widget.url;
    _activeHeaders = Map<String, String>.from(widget.headers);
    _activeQualityLabel = _labelForUrl(_activeUrl) ?? 'Auto';
    _initPlayer();
    _seedBrightness();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _pipChannel.setMethodCallHandler((call) async {
      if (call.method == 'onPipModeChanged') {
        final inPip = call.arguments as bool? ?? false;
        if (mounted) {
          setState(() {
            _isInPipMode = inPip;
            if (inPip) {
              _controlsVisible = false;
            }
          });
        }
      }
    });
  }

  /// Start the brightness drag from wherever the device already is, so the
  /// first swipe doesn't jump. Failures are non-fatal — the drag still works,
  /// it just starts from the 50% default.
  Future<void> _seedBrightness() async {
    try {
      final value = await _windowChannel.invokeMethod<double>('getBrightness');
      if (value != null && mounted) {
        _brightness = value.clamp(0.0, 1.0);
      }
    } catch (_) {
      // Non-Android or channel unavailable — keep the default.
    }
  }

  String? _labelForUrl(String url) {
    for (final q in widget.qualityOptions) {
      if (q.url == url) return q.label;
    }
    // Soft match: same path without query (signed tokens often differ).
    final path = Uri.tryParse(url)?.path;
    if (path != null && path.isNotEmpty) {
      for (final q in widget.qualityOptions) {
        final qp = Uri.tryParse(q.url)?.path;
        if (qp != null && qp == path) return q.label;
      }
    }
    return null;
  }

  Future<void> _initPlayer({bool retry = false}) async {
    if (retry) {
      setState(() {
        _error = null;
        _initialized = false;
      });
    }

    final uri = Uri.tryParse(_activeUrl);
    if (uri == null || !uri.hasScheme) {
      if (mounted) {
        setState(() {
          _error = 'Could not play this video. The URL is not valid.';
          _initialized = true;
        });
      }
      return;
    }

    try {
      // Dispose any previous controller before retry.
      if (_controllerListener != null) {
        _controller?.removeListener(_controllerListener!);
      }
      await _controller?.dispose();
      _controller = null;

      final headers = _activeHeaders.isNotEmpty
          ? Map<String, String>.from(_activeHeaders)
          : <String, String>{};

      // Ensure Accept covers common media/HLS responses; some CDNs
      // reject bare clients that omit it.
      if (!headers.keys.any((k) => k.toLowerCase() == 'accept')) {
        headers['Accept'] = '*/*';
      }
      _activeHeaders = headers;

      final formatHint = _formatHintForUrl(_activeUrl);
      final controller = VideoPlayerController.networkUrl(
        uri,
        httpHeaders: headers,
        formatHint: formatHint,
      );
      _controller = controller;
      _wasPlaying = false;
      _controllerListener = _onControllerUpdate;
      controller.addListener(_controllerListener!);
      await controller.initialize();

      if (!mounted) {
        controller.dispose();
        return;
      }

      _videoWidth = controller.value.size.width > 0
          ? controller.value.size.width
          : 16;
      _videoHeight = controller.value.size.height > 0
          ? controller.value.size.height
          : 9;

      await controller.play();
      setState(() => _initialized = true);
      _startAutoHideTimer();
    } catch (e) {
      if (mounted) {
        final hasCookie = _activeHeaders.keys.any(
          (k) => k.toLowerCase() == 'cookie',
        );
        setState(() {
          _error = hasCookie
              ? 'Could not play this video. The stream may be protected or expired — open the page again, then retry.'
              : 'Could not play this video. Missing session cookies — open the page in the browser first, then try again.';
          _initialized = true;
        });
      }
    }
  }

  /// Android ExoPlayer format hint for HLS/DASH URLs so playback does not
  /// depend on content-type sniffing alone.
  static VideoFormat? _formatHintForUrl(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('.m3u8') ||
        lower.contains('mpegurl') ||
        lower.contains('m3u8') ||
        isPlaylistPathHint(lower)) {
      return VideoFormat.hls;
    }
    if (lower.contains('.mpd') || lower.contains('dash+xml')) {
      return VideoFormat.dash;
    }
    return null;
  }

  /// Controller listener. Full-screen `setState` is reserved for non-position
  /// UI state: buffering, the play/pause icon, and video dimensions. Position /
  /// duration / buffered updates for the progress bar + clock are consumed
  /// frame-scoped by the `ValueListenableBuilder`s in [_buildBottomControls],
  /// so they no longer need a throttled whole-screen rebuild.
  void _onControllerUpdate() {
    if (!mounted || _controller == null) return;
    final v = _controller!.value;

    var needsFullRebuild = false;

    if (v.size.width > 0 && v.size.height > 0) {
      if (_videoWidth != v.size.width || _videoHeight != v.size.height) {
        _videoWidth = v.size.width;
        _videoHeight = v.size.height;
        needsFullRebuild = true;
      }
    }

    // Play/pause icon reflects isPlaying — e.g. when the video finishes.
    if (v.isPlaying != _wasPlaying) {
      _wasPlaying = v.isPlaying;
      needsFullRebuild = true;
    }

    // Buffering: ExoPlayer often clears isPlaying while stalled — treat
    // isBuffering alone as the signal so slow networks aren't silent.
    final buffering = v.isBuffering;
    if (buffering != _isBuffering) {
      _isBuffering = buffering;
      if (buffering) {
        _bufferingTimer ??= Timer(const Duration(seconds: 3), () {
          if (mounted && _isBuffering) {
            setState(() => _isBufferingSlow = true);
          }
        });
      } else {
        _bufferingTimer?.cancel();
        _bufferingTimer = null;
        _isBufferingSlow = false;
      }
      // Immediate rebuild so the spinner appears without any delay.
      needsFullRebuild = true;
    }

    if (needsFullRebuild) setState(() {});
  }

  @override
  void dispose() {
    _pipChannel.setMethodCallHandler(null);
    // Hand screen brightness back to the system — a window override would
    // otherwise persist for the rest of the app session.
    unawaited(
      _windowChannel
          .invokeMethod('setBrightness', {'value': -1.0})
          .catchError((_) => null),
    );
    _autoHideTimer?.cancel();
    _clockTimer?.cancel();
    _hudTimer?.cancel();
    _previewSeekDebounce?.cancel();
    if (_controllerListener != null) {
      _controller?.removeListener(_controllerListener!);
    }
    _playPauseIconTimer?.cancel();
    _bufferingTimer?.cancel();
    _controller?.dispose();
    _previewController?.dispose();
    // Restore free orientation when leaving the player.
    unawaited(
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]),
    );
    super.dispose();
  }

  /// Lazy-init a second muted controller for scrub preview frames.
  Future<void> _ensurePreviewController() async {
    if (_previewReady || _previewInitStarted) return;
    _previewInitStarted = true;
    final uri = Uri.tryParse(_activeUrl);
    if (uri == null || !uri.hasScheme) {
      _previewInitStarted = false;
      return;
    }
    try {
      final headers = _activeHeaders.isNotEmpty
          ? Map<String, String>.from(_activeHeaders)
          : <String, String>{};
      if (!headers.keys.any((k) => k.toLowerCase() == 'accept')) {
        headers['Accept'] = '*/*';
      }
      final c = VideoPlayerController.networkUrl(
        uri,
        httpHeaders: headers,
        formatHint: _formatHintForUrl(_activeUrl),
      );
      await c.initialize();
      await c.setVolume(0);
      await c.pause();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() {
        _previewController = c;
        _previewReady = true;
      });
    } catch (_) {
      _previewInitStarted = false;
      _previewReady = false;
    }
  }

  void _schedulePreviewSeek(Duration pos) {
    unawaited(_ensurePreviewController());
    _previewSeekDebounce?.cancel();
    _previewSeekDebounce = Timer(const Duration(milliseconds: 140), () async {
      final c = _previewController;
      if (c == null || !c.value.isInitialized) return;
      try {
        await c.seekTo(pos);
        await c.pause();
        if (mounted && _isSeeking) setState(() {});
      } catch (_) {}
    });
  }

  /// Map a local X (within the progress GestureDetector) to a media position.
  /// [trackWidth] is the full detector width; bar is inset by [hPad] each side.
  (Duration pos, double fraction) _positionFromLocalX({
    required double localX,
    required double trackWidth,
    required Duration duration,
    double hPad = 12,
  }) {
    final barWidth = (trackWidth - hPad * 2).clamp(1.0, double.infinity);
    final x = (localX - hPad).clamp(0.0, barWidth);
    final fraction = (x / barWidth).clamp(0.0, 1.0);
    final ms = duration.inMilliseconds;
    final pos = ms > 0
        ? Duration(milliseconds: (fraction * ms).round())
        : Duration.zero;
    return (pos, fraction);
  }

  // ---- Timer helpers ----

  void _startAutoHideTimer() {
    _autoHideTimer?.cancel();
    if (_locked) return;
    _autoHideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _controlsVisible && !_locked) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _resetAutoHideTimer() {
    if (_locked) return;
    _startAutoHideTimer();
  }

  void _flashPlayPauseIcon() {
    _showPlayPauseIcon = true;
    _playPauseIconTimer?.cancel();
    _playPauseIconTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _showPlayPauseIcon = false);
    });
    if (mounted) setState(() {});
  }

  // ---- Gesture handlers ----

  /// Tap only shows/hides chrome — play/pause is explicit (center / bottom).
  void _onVideoTap() {
    if (_locked) return;
    if (_controller == null || !_initialized) return;
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) {
      _startAutoHideTimer();
    } else {
      _autoHideTimer?.cancel();
    }
  }

  void _onTogglePlayPause() {
    if (_locked) return;
    final c = _controller;
    if (c == null || !_initialized || !c.value.isInitialized) return;
    if (c.value.isPlaying) {
      unawaited(c.pause());
    } else {
      unawaited(c.play());
    }
    _flashPlayPauseIcon();
    _resetAutoHideTimer();
    setState(() => _controlsVisible = true);
  }

  void _onLongPressStart(LongPressStartDetails d) {
    if (_locked) return;
    final c = _controller;
    if (c == null || !_initialized || !c.value.isInitialized) return;
    _holdSpeedPrev = _currentSpeed;
    // Ensure we are playing — hold must never look like a silent pause.
    unawaited(c.play());
    unawaited(c.setPlaybackSpeed(_holdSpeedRate));
    setState(() {
      _holdSpeedActive = true;
      _controlsVisible = false;
    });
  }

  void _onLongPressEnd(LongPressEndDetails d) {
    _endHoldSpeed();
  }

  void _onLongPressCancel() {
    _endHoldSpeed();
  }

  void _endHoldSpeed() {
    if (!_holdSpeedActive) return;
    final c = _controller;
    if (c != null && c.value.isInitialized) {
      unawaited(c.setPlaybackSpeed(_holdSpeedPrev));
      // Leave playback running; user can pause explicitly.
      if (!c.value.isPlaying) {
        unawaited(c.play());
      }
    }
    if (mounted) {
      setState(() => _holdSpeedActive = false);
    } else {
      _holdSpeedActive = false;
    }
  }

  // ---- Gesture HUD ----

  void _showHud(_GestureHud hud) {
    _hudTimer?.cancel();
    if (!mounted) return;
    setState(() => _hud = hud);
    _hudTimer = Timer(const Duration(milliseconds: 650), () {
      if (mounted) setState(() => _hud = null);
    });
  }

  // ---- Tap / double-tap ----

  /// Hand-rolled double-tap so a single tap toggles the chrome immediately.
  /// Flutter's [GestureDetector.onDoubleTap] would hold the arena open for
  /// [kDoubleTapTimeout], adding ~300ms of lag to every controls toggle.
  void _onTapUp(TapUpDetails d) {
    final now = DateTime.now();
    final prevAt = _lastTapAt;
    final prevPos = _lastTapPos;
    _lastTapAt = now;
    _lastTapPos = d.localPosition;

    final isDouble = prevAt != null &&
        prevPos != null &&
        now.difference(prevAt) < const Duration(milliseconds: 280) &&
        (d.localPosition - prevPos).distance < 72;

    if (isDouble) {
      _lastTapAt = null;
      _lastTapPos = null;
      _onDoubleTap(d.localPosition);
      return;
    }
    _onVideoTap();
  }

  void _onDoubleTap(Offset localPosition) {
    if (_locked) return;
    final c = _controller;
    if (c == null || !_initialized || !c.value.isInitialized) return;
    final width = context.size?.width ?? MediaQuery.of(context).size.width;
    final third = width / 3;
    if (localPosition.dx < third) {
      _seekBy(const Duration(seconds: -10));
    } else if (localPosition.dx > width - third) {
      _seekBy(const Duration(seconds: 10));
    } else {
      _onTogglePlayPause();
    }
  }

  void _seekBy(Duration delta) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final duration = c.value.duration;
    var target = c.value.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;
    unawaited(c.seekTo(target));
    final seconds = delta.inSeconds.abs();
    _showHud(
      _GestureHud(
        icon: delta.isNegative
            ? Icons.fast_rewind_rounded
            : Icons.fast_forward_rounded,
        label: '${delta.isNegative ? '−' : '+'}${seconds}s',
      ),
    );
  }

  // ---- Vertical drag: brightness (left) / volume (right) ----

  void _onVerticalDragStart(DragStartDetails d) {
    if (_locked || _isInPipMode || !_initialized) return;
    final width = context.size?.width ?? MediaQuery.of(context).size.width;
    final isLeft = d.localPosition.dx < width / 2;
    _dragMode = isLeft ? _DragMode.brightness : _DragMode.volume;
    _dragStartValue = isLeft ? _brightness : _volume;
    _dragStartY = d.localPosition.dy;
  }

  void _onVerticalDragUpdate(DragUpdateDetails d) {
    if (_dragMode == _DragMode.none || _locked) return;
    final height = context.size?.height ?? MediaQuery.of(context).size.height;
    // ~70% of the screen height covers the full range: enough travel for fine
    // control without needing a full-height swipe.
    final travel = height * 0.7;
    if (travel <= 0) return;
    final delta = (_dragStartY - d.localPosition.dy) / travel;
    final next = (_dragStartValue + delta).clamp(0.0, 1.0);
    if (_dragMode == _DragMode.brightness) {
      _applyBrightness(next);
    } else {
      _applyVolume(next);
    }
  }

  void _onVerticalDragEnd(DragEndDetails d) => _dragMode = _DragMode.none;

  void _applyBrightness(double value) {
    _brightness = value;
    unawaited(
      _windowChannel
          .invokeMethod('setBrightness', {'value': value})
          .catchError((_) => null),
    );
    _showHud(
      _GestureHud(
        icon: value < 0.34
            ? Icons.brightness_low_rounded
            : value < 0.67
                ? Icons.brightness_medium_rounded
                : Icons.brightness_high_rounded,
        label: '${(value * 100).round()}%',
        value: value,
      ),
    );
  }

  void _applyVolume(double value) {
    _volume = value;
    unawaited(_controller?.setVolume(value));
    _showHud(
      _GestureHud(
        icon: value <= 0.001
            ? Icons.volume_off_rounded
            : value < 0.5
                ? Icons.volume_down_rounded
                : Icons.volume_up_rounded,
        label: '${(value * 100).round()}%',
        value: value,
      ),
    );
  }

  void _onToggleLock() {
    setState(() {
      _locked = !_locked;
      if (_locked) {
        _controlsVisible = false;
        _autoHideTimer?.cancel();
      } else {
        _controlsVisible = true;
        _startAutoHideTimer();
      }
    });
  }

  void _onToggleOrientation() {
    _resetAutoHideTimer();
    _landscapeForced = !_landscapeForced;
    if (_landscapeForced) {
      unawaited(
        SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]),
      );
    } else {
      unawaited(
        SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]),
      );
    }
    setState(() {});
  }

  void _onRetry() {
    if (_controllerListener != null) {
      _controller?.removeListener(_controllerListener!);
    }
    _controller?.dispose();
    _controller = null;
    _controllerListener = null;
    _initPlayer(retry: true);
  }

  // ---- Speed selector ----

  static const List<double> _speedOptions = [
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    2.0,
    3.0,
    4.0,
  ];

  void _showSpeedMenu() {
    final ac = context.ac;
    _resetAutoHideTimer();
    showModalBottomSheet(
      context: context,
      backgroundColor: ac.surfacePanel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Playback speed',
                  style: TextStyle(
                    color: ac.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                ..._speedOptions.map((speed) {
                  final selected = speed == _currentSpeed;
                  return ListTile(
                    leading: Icon(
                      selected ? Icons.radio_button_checked : Icons.radio_button_off,
                      color: selected ? ac.accentFrost : ac.textSecondary,
                    ),
                    title: Text(
                      _formatSpeedLabel(speed),
                      style: TextStyle(
                        color: selected ? ac.textPrimary : ac.textSecondary,
                        fontWeight:
                            selected ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    onTap: () {
                      unawaited(_controller?.setPlaybackSpeed(speed));
                      setState(() => _currentSpeed = speed);
                      Navigator.pop(ctx);
                    },
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  // ---- Quality selector ----

  void _showQualityMenu() {
    if (!_hasQualityPicker) return;
    final ac = context.ac;
    _resetAutoHideTimer();
    showModalBottomSheet(
      context: context,
      backgroundColor: ac.surfacePanel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Select quality',
                  style: TextStyle(
                    color: ac.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(ctx).height * 0.45,
                  ),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final option in widget.qualityOptions)
                        ListTile(
                          leading: Icon(
                            option.url == _activeUrl ||
                                    option.label == _activeQualityLabel
                                ? Icons.radio_button_checked
                                : Icons.radio_button_off,
                            color: option.url == _activeUrl ||
                                    option.label == _activeQualityLabel
                                ? ac.accentFrost
                                : ac.textSecondary,
                          ),
                          title: Text(
                            option.label,
                            style: TextStyle(
                              color: ac.textPrimary,
                              fontWeight: option.url == _activeUrl
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                          subtitle: option.bandwidth != null
                              ? Text(
                                  _formatBandwidth(option.bandwidth!),
                                  style: TextStyle(
                                    color: ac.textSecondary,
                                    fontSize: 12,
                                  ),
                                )
                              : null,
                          onTap: () {
                            Navigator.pop(ctx);
                            unawaited(_switchQuality(option));
                          },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static String _formatBandwidth(int bps) {
    if (bps >= 1_000_000) {
      return '${(bps / 1_000_000).toStringAsFixed(1)} Mbps';
    }
    if (bps >= 1_000) return '${(bps / 1_000).toStringAsFixed(0)} Kbps';
    return '$bps bps';
  }

  Future<void> _switchQuality(PlayerQualityOption option) async {
    if (_switchingQuality) return;
    if (option.url == _activeUrl) return;

    final pos = _controller?.value.position ?? Duration.zero;
    final wasPlaying = _controller?.value.isPlaying ?? true;
    final speed = _currentSpeed;

    setState(() {
      _switchingQuality = true;
      _error = null;
      _initialized = false;
      _activeQualityLabel = option.label;
    });

    // Drop scrub-preview so it re-inits against the new stream.
    _previewSeekDebounce?.cancel();
    await _previewController?.dispose();
    _previewController = null;
    _previewReady = false;
    _previewInitStarted = false;

    Map<String, String> headers = Map<String, String>.from(_activeHeaders);
    if (widget.resolveHeadersForUrl != null) {
      try {
        final resolved = await widget.resolveHeadersForUrl!(option.url);
        if (resolved.isNotEmpty) {
          headers = Map<String, String>.from(resolved);
        }
      } catch (_) {
        // Keep previous headers on resolver failure.
      }
    }
    if (!headers.keys.any((k) => k.toLowerCase() == 'accept')) {
      headers['Accept'] = '*/*';
    }

    _activeUrl = option.url;
    _activeHeaders = headers;

    await _initPlayer(retry: true);

    if (!mounted) return;

    final c = _controller;
    if (c != null && c.value.isInitialized) {
      try {
        if (pos > Duration.zero) {
          await c.seekTo(pos);
        }
        await c.setPlaybackSpeed(speed);
        if (wasPlaying) {
          await c.play();
        } else {
          await c.pause();
        }
      } catch (_) {}
    }

    if (mounted) {
      setState(() => _switchingQuality = false);
    }
  }

  void _onToggleAspectRatio() {
    _resetAutoHideTimer();
    final fits = [BoxFit.contain, BoxFit.fill, BoxFit.cover];
    final idx = (fits.indexOf(_fit) + 1) % fits.length;
    setState(() => _fit = fits[idx]);
  }

  void _onToggleFavorite() {
    _resetAutoHideTimer();
    setState(() => _isFavorited = !_isFavorited);
    if (_isFavorited && widget.onFavorite != null) {
      widget.onFavorite!(widget.sourcePageUrl ?? widget.url);
    }
  }

  Future<void> _enterPip() async {
    _resetAutoHideTimer();
    try {
      final int w = _videoWidth.round();
      final int h = _videoHeight.round();
      final bool success = await _pipChannel.invokeMethod<bool>('enterPip', {
        'width': w > 0 ? w : 16,
        'height': h > 0 ? h : 9,
      }) ?? false;

      if (!success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.playerPipNotAvailable),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('[AuroraVideoPlayer] enterPip failed: $e');
      // Same UX as the !success path: tell the user instead of kicking
      // them out of the player. Popping here would end playback for a
      // transient platform error.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Picture-in-Picture is not available on this device.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  void _showOverflowMenu() {
    final ac = context.ac;
    _resetAutoHideTimer();
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        MediaQuery.of(context).size.width - 200,
        MediaQuery.of(context).padding.top + 48,
        MediaQuery.of(context).size.width - 8,
        MediaQuery.of(context).padding.top + 48 + 200,
      ),
      color: ac.surfacePanel,
      items: [
        if (_hasQualityPicker)
          PopupMenuItem(
            value: 'quality',
            child: ListTile(
              leading: Icon(Icons.high_quality_rounded,
                  color: ac.textPrimary, size: 20),
              title: Text(
                'Quality ($_activeQualityLabel)',
                style: TextStyle(color: ac.textPrimary, fontSize: 14),
              ),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        PopupMenuItem(
          value: 'open_browser',
          child: ListTile(
            leading: Icon(Icons.open_in_browser, color: ac.textPrimary, size: 20),
            title: Text('Open in browser', style: TextStyle(color: ac.textPrimary, fontSize: 14)),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: 'copy_url',
          child: ListTile(
            leading: Icon(Icons.copy, color: ac.textPrimary, size: 20),
            title: Text('Copy video link', style: TextStyle(color: ac.textPrimary, fontSize: 14)),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: 'share',
          child: ListTile(
            leading: Icon(Icons.share, color: ac.textPrimary, size: 20),
            title: Text('Share', style: TextStyle(color: ac.textPrimary, fontSize: 14)),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    ).then((value) {
      if (value == 'quality') {
        _showQualityMenu();
      } else if (value == 'open_browser') {
        final targetUrl = widget.sourcePageUrl ?? _activeUrl;
        unawaited(PublicDownloadsService.openUrl(targetUrl));
      } else if (value == 'copy_url') {
        unawaited(Clipboard.setData(ClipboardData(text: _activeUrl)));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppLocalizations.of(context)!.playerCopiedLink),
              duration: Duration(seconds: 1),
            ),
          );
        }
      } else if (value == 'share') {
        unawaited(PublicDownloadsService.shareUrl(_activeUrl));
      }
    });
  }

  // ---- String helpers ----

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  String _formatSpeedLabel(double speed) {
    if (speed == speed.roundToDouble()) {
      return '${speed.toInt()}×';
    }
    return '$speed×';
  }

  String get _currentTimeString {
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
  }

  // ---- Build ----

  @override
  Widget build(BuildContext context) {
    if (_isInPipMode) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: _buildVideoArea(),
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // --- Video area ---
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: _onTapUp,
                onLongPressStart: _onLongPressStart,
                onLongPressEnd: _onLongPressEnd,
                onLongPressCancel: _onLongPressCancel,
                onVerticalDragStart: _onVerticalDragStart,
                onVerticalDragUpdate: _onVerticalDragUpdate,
                onVerticalDragEnd: _onVerticalDragEnd,
                onVerticalDragCancel: () => _dragMode = _DragMode.none,
                child: _buildVideoArea(),
              ),
            ),

            // --- Gesture HUD pill (speed / seek / brightness / volume) ---
            if (!_locked) _buildGestureHud(),

            // --- Controls ---
            if (_controlsVisible && !_locked) _buildHeader(),
            if (_controlsVisible && !_locked) _buildBottomControls(),

            // --- Center play/pause (when chrome visible, not holding) ---
            if (_controlsVisible &&
                !_locked &&
                !_holdSpeedActive &&
                _initialized &&
                _error == null)
              Positioned.fill(
                child: Center(
                  child: _buildCenterPlayButton(),
                ),
              ),

            // --- Lock button ---
            Positioned(
              left: 8,
              top: 0,
              bottom: 0,
              child: Center(
                child: GestureDetector(
                  onTap: _onToggleLock,
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Icon(
                      _locked ? Icons.lock_rounded : Icons.lock_open_rounded,
                      color: Colors.white70,
                      size: 18,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Transient gesture feedback: a small pill at the top, out of the picture.
  /// Hold-speed takes precedence over the timed HUD while the finger is down.
  Widget _buildGestureHud() {
    final hud = _holdSpeedActive
        ? _GestureHud(
            icon: Icons.fast_forward_rounded,
            label: _formatSpeedLabel(_holdSpeedRate),
          )
        : _hud;
    if (hud == null) return const SizedBox.shrink();
    final ac = context.ac;
    return Positioned(
      top: 16,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.62),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(hud.icon, color: ac.accentFrost, size: 18),
                const SizedBox(width: 8),
                Text(
                  hud.label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                if (hud.value != null) ...[
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 56,
                    height: 3,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: hud.value,
                        minHeight: 3,
                        backgroundColor: Colors.white24,
                        valueColor: AlwaysStoppedAnimation<Color>(ac.accentFrost),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCenterPlayButton() {
    final c = _controller;
    final playing = c != null && c.value.isInitialized && c.value.isPlaying;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _onTogglePlayPause,
        customBorder: const CircleBorder(),
        child: Container(
          width: 68,
          height: 68,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.45),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white24),
          ),
          child: Icon(
            playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            color: Colors.white,
            size: 40,
          ),
        ),
      ),
    );
  }

  Widget _buildVideoArea() {
    final ac = context.ac;
    if (!_initialized) {
      return Center(
        child: SizedBox(
          width: 36,
          height: 36,
          child: CircularProgressIndicator(
            strokeWidth: 3,
            valueColor: AlwaysStoppedAnimation<Color>(ac.accentFrost),
          ),
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: Colors.white38, size: 48),
            const SizedBox(height: 12),
            Text(
              _error!,
              style: const TextStyle(color: Colors.white54, fontSize: 15),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry'),
              style: ElevatedButton.styleFrom(
                backgroundColor: ac.accentFrost,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
            ),
          ],
        ),
      );
    }

    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      return Center(
        child: SizedBox(
          width: 36,
          height: 36,
          child: CircularProgressIndicator(
            strokeWidth: 3,
            valueColor: AlwaysStoppedAnimation<Color>(ac.accentFrost),
          ),
        ),
      );
    }

    final vSize = c.value.size;
    final w = vSize.width > 0 ? vSize.width : _videoWidth;
    final h = vSize.height > 0 ? vSize.height : _videoHeight;

    return Stack(
      alignment: Alignment.center,
      children: [
        // Video
        ClipRect(
          child: SizedBox.expand(
            child: FittedBox(
              fit: _fit,
              child: SizedBox(
                width: w,
                height: h,
                child: VideoPlayer(c),
              ),
            ),
          ),
        ),

        // Buffering overlay — always visible while stalled (not only after 3s).
        if (_isBuffering && !_locked && !_holdSpeedActive)
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !_isBufferingSlow,
              child: Container(
                color: _isBufferingSlow ? Colors.black54 : Colors.transparent,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(ac.accentFrost),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _isBufferingSlow
                          ? 'Buffering is slow'
                          : 'Buffering…',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (_isBufferingSlow) ...[
                      const SizedBox(height: 10),
                      GestureDetector(
                        onTap: _onRetry,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: ac.accentFrost,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            'Retry',
                            style: TextStyle(
                              color: Colors.black,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),

        // Brief play/pause flash after explicit toggle
        if (_showPlayPauseIcon)
          IgnorePointer(
            child: AnimatedOpacity(
              opacity: _showPlayPauseIcon ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: Container(
                width: 64,
                height: 64,
                decoration: const BoxDecoration(
                  color: Colors.black38,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  c.value.isPlaying
                      ? Icons.play_arrow_rounded
                      : Icons.pause_rounded,
                  color: Colors.white,
                  size: 32,
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ---- Header ----

  Widget _buildHeader() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        height: 52,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: Row(
          children: [
            // Back button
            GestureDetector(
              onTap: () => Navigator.pop(context),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Icon(Icons.arrow_back_rounded, color: Colors.white, size: 24),
              ),
            ),
            // Title
            Expanded(
              child: Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            // Battery + Clock
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.battery_full_rounded, color: Colors.white70, size: 16),
                  const SizedBox(width: 2),
                  Text(
                    _currentTimeString,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
            // PiP button
            GestureDetector(
              onTap: _enterPip,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Icon(Icons.picture_in_picture_alt_rounded, color: Colors.white70, size: 20),
              ),
            ),
            // 3-dot menu
            GestureDetector(
              onTap: _showOverflowMenu,
              child: const Padding(
                padding: EdgeInsets.only(right: 8, left: 4),
                child: Icon(Icons.more_vert_rounded, color: Colors.white70, size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- Bottom controls ----

  /// Progress-bar / clock values derived from a live controller value.
  /// While scrubbing, the visible position is the user's thumb position
  /// ([_seekPosition]) rather than the live playback position.
  (double progress, double bufferedFraction, Duration duration, Duration displayPosition)
      _progressValues(VideoPlayerValue value) {
    final duration = value.isInitialized ? value.duration : Duration.zero;
    final displayPosition = _isSeeking ? _seekPosition : value.position;
    final double progress = duration.inMilliseconds > 0
        ? (displayPosition.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    // Build buffered ranges.
    double bufferedProgress = 0.0;
    if (value.isInitialized && duration.inMilliseconds > 0) {
      for (final range in value.buffered) {
        final end = range.end.inMilliseconds;
        if (end > bufferedProgress) {
          bufferedProgress = end.toDouble();
        }
      }
    }
    final double bufferedFraction = duration.inMilliseconds > 0
        ? (bufferedProgress / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    return (progress, bufferedFraction, duration, displayPosition);
  }

  Widget _buildBottomControls() {
    final ac = context.ac;
    final c = _controller;

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).padding.bottom + 4,
          top: 4,
        ),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // --- Progress bar ---
            // Rebuilt per-frame from the controller (a ValueListenable) so the
            // bar tracks position/buffered without a whole-screen setState.
            c == null
                ? _buildProgressBar(0.0, 0.0, Duration.zero)
                : ValueListenableBuilder<VideoPlayerValue>(
                    valueListenable: c,
                    builder: (context, value, _) {
                      final (progress, bufferedFraction, duration, _) =
                          _progressValues(value);
                      return _buildProgressBar(
                        bufferedFraction,
                        progress,
                        duration,
                      );
                    },
                  ),

            const SizedBox(height: 6),

            // --- Bottom action row ---
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  // Play / pause (explicit — tap on video no longer toggles)
                  _miniButton(
                    onTap: _onTogglePlayPause,
                    child: Icon(
                      (c != null &&
                              c.value.isInitialized &&
                              c.value.isPlaying)
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 26,
                    ),
                  ),
                  // Time (elapsed / duration) — frame-scoped like the bar.
                  Flexible(
                    child: c == null
                        ? const Text(
                            '00:00 / 00:00',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          )
                        : ValueListenableBuilder<VideoPlayerValue>(
                            valueListenable: c,
                            builder: (context, value, _) {
                              final (_, _, duration, displayPosition) =
                                  _progressValues(value);
                              return Text(
                                '${_formatDuration(displayPosition)} / ${_formatDuration(duration)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              );
                            },
                          ),
                  ),
                  const Spacer(),
                  // Quality (HLS variants / multi-rendition)
                  if (_hasQualityPicker) ...[
                    _miniButton(
                      onTap: _switchingQuality ? () {} : _showQualityMenu,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.high_quality_rounded,
                            color: ac.accentFrost,
                            size: 16,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            _switchingQuality ? '…' : _activeQualityLabel,
                            style: TextStyle(
                              color: ac.accentFrost,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  // Speed (includes 2× / 4× for permanent rate)
                  _miniButton(
                    onTap: _showSpeedMenu,
                    child: Text(
                      _formatSpeedLabel(_currentSpeed),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  // Screen rotation
                  _miniButton(
                    onTap: _onToggleOrientation,
                    child: Icon(
                      _landscapeForced
                          ? Icons.screen_lock_rotation_rounded
                          : Icons.screen_rotation_rounded,
                      color: _landscapeForced ? ac.accentFrost : Colors.white70,
                      size: 20,
                    ),
                  ),
                  // Star (favorite)
                  _miniButton(
                    onTap: _onToggleFavorite,
                    child: Icon(
                      _isFavorited
                          ? Icons.star_rounded
                          : Icons.star_outline_rounded,
                      color: _isFavorited ? ac.accentFrost : Colors.white70,
                      size: 20,
                    ),
                  ),
                  // Download
                  _miniButton(
                    onTap: () {
                      widget.onDownload?.call();
                    },
                    child: const Icon(
                      Icons.download_rounded,
                      color: Colors.white70,
                      size: 20,
                    ),
                  ),
                  // Aspect ratio
                  _miniButton(
                    onTap: _onToggleAspectRatio,
                    child: _aspectRatioIcon(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressBar(
    double bufferedFraction,
    double progress,
    Duration duration,
  ) {
    final ac = context.ac;
    const hPad = 12.0;
    const previewW = 132.0;
    const previewH = 74.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final trackWidth = constraints.maxWidth;
        final barWidth = (trackWidth - hPad * 2).clamp(1.0, double.infinity);
        final displayProgress = _isSeeking ? _seekFraction : progress;
        final thumbCenterX = hPad + displayProgress * barWidth;

        void applyLocalX(double localX, {required bool commit}) {
          if (_locked || duration.inMilliseconds <= 0) return;
          final (pos, fraction) = _positionFromLocalX(
            localX: localX,
            trackWidth: trackWidth,
            duration: duration,
            hPad: hPad,
          );
          setState(() {
            _isSeeking = !commit;
            _seekPosition = pos;
            _seekFraction = fraction;
          });
          if (commit) {
            unawaited(_controller?.seekTo(pos));
            if (_controller != null && !_controller!.value.isPlaying) {
              unawaited(_controller!.play());
            }
            _resetAutoHideTimer();
          } else {
            _schedulePreviewSeek(pos);
          }
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) {
            if (_locked) return;
            applyLocalX(details.localPosition.dx, commit: true);
            setState(() => _isSeeking = false);
          },
          onHorizontalDragStart: (details) {
            if (_locked) return;
            applyLocalX(details.localPosition.dx, commit: false);
            unawaited(_ensurePreviewController());
          },
          onHorizontalDragUpdate: (details) {
            if (_locked) return;
            applyLocalX(details.localPosition.dx, commit: false);
          },
          onHorizontalDragEnd: (_) {
            if (_locked) return;
            unawaited(_controller?.seekTo(_seekPosition));
            if (_controller != null && !_controller!.value.isPlaying) {
              unawaited(_controller!.play());
            }
            setState(() => _isSeeking = false);
            _resetAutoHideTimer();
          },
          onHorizontalDragCancel: () {
            if (mounted) setState(() => _isSeeking = false);
          },
          child: SizedBox(
            height: _isSeeking ? 110 : 40,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.bottomCenter,
              children: [
                // YouTube-style scrub thumbnail + time above the thumb.
                if (_isSeeking)
                  Positioned(
                    left: (thumbCenterX - previewW / 2).clamp(
                      4.0,
                      trackWidth - previewW - 4,
                    ),
                    bottom: 36,
                    child: _buildSeekPreviewCard(
                      width: previewW,
                      height: previewH,
                      timeLabel: _formatDuration(_seekPosition),
                    ),
                  ),

                // Track row
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 10,
                  height: 20,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: hPad),
                    child: Center(
                      child: SizedBox(
                        height: 4,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            // Background
                            Container(
                              decoration: BoxDecoration(
                                color: Colors.white12,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            // Buffered
                            FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: bufferedFraction.clamp(0.0, 1.0),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.white24,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                            // Played
                            FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: displayProgress.clamp(0.0, 1.0),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: ac.accentFrost,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                            // Thumb — position from bar width only (not full screen).
                            Positioned(
                              left: (displayProgress * barWidth - 7).clamp(
                                -2.0,
                                barWidth - 5,
                              ),
                              top: -5,
                              child: Container(
                                width: 14,
                                height: 14,
                                decoration: BoxDecoration(
                                  color: ac.accentFrost,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 1.5,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: ac.accentFrost.withValues(
                                        alpha: 0.45,
                                      ),
                                      blurRadius: 6,
                                      spreadRadius: 1,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Floating scrub preview (thumbnail frame + timestamp).
  Widget _buildSeekPreviewCard({
    required double width,
    required double height,
    required String timeLabel,
  }) {
    final ac = context.ac;
    final preview = _previewController;
    final showVideo =
        _previewReady && preview != null && preview.value.isInitialized;

    return Material(
      elevation: 8,
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: width,
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: ac.accentFrost.withValues(alpha: 0.7)),
          boxShadow: const [
            BoxShadow(
              color: Colors.black54,
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(7)),
              child: SizedBox(
                width: width,
                height: height,
                child: showVideo
                    ? FittedBox(
                        fit: BoxFit.cover,
                        child: SizedBox(
                          width: preview.value.size.width > 0
                              ? preview.value.size.width
                              : 16,
                          height: preview.value.size.height > 0
                              ? preview.value.size.height
                              : 9,
                          child: VideoPlayer(preview),
                        ),
                      )
                    : ColoredBox(
                        color: Colors.black,
                        child: Center(
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: ac.accentFrost,
                            ),
                          ),
                        ),
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                timeLabel,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniButton({required VoidCallback onTap, required Widget child}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(6),
        child: child,
      ),
    );
  }

  Widget _aspectRatioIcon() {
    switch (_fit) {
      case BoxFit.contain:
        return const Icon(Icons.crop_original_rounded, color: Colors.white70, size: 20);
      case BoxFit.fill:
        return const Icon(Icons.crop, color: Colors.white70, size: 20);
      case BoxFit.cover:
        return const Icon(Icons.crop_din_rounded, color: Colors.white70, size: 20);
      default:
        return const Icon(Icons.crop_original_rounded, color: Colors.white70, size: 20);
    }
  }
}

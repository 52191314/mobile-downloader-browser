import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:aurora_downloader/theme/aurora_palette.dart';

import 'engine_factory.dart';
import 'playback_engine.dart';
import 'playback_source.dart';
import 'playback_state.dart';

/// Which value a vertical drag is adjusting.
enum _DragMode { none, brightness, volume }

/// Transient overlay pill for a gesture (seek, brightness, volume, speed).
///
/// Small and top-anchored on purpose: it sits over the thing the user is
/// trying to watch, so it stays out of the picture and never explains itself.
@immutable
class _GestureHud {
  const _GestureHud({
    required this.icon,
    required this.label,
    this.value,
    this.hint,
  });

  final IconData icon;
  final String label;

  /// 0..1 for the thin level bar (brightness/volume). Null hides the bar.
  final double? value;

  /// Extra affordance text, e.g. the 4x escalation hint while holding.
  final String? hint;
}

/// Full-screen player built on the [PlaybackEngine] abstraction.
///
/// The screen never touches a decoder. It renders whatever
/// [PlaybackEngine.buildSurface] gives it and drives the engine through the
/// interface, which is what makes swapping backends mid-playback possible —
/// the single most useful control here when a stream will not start.
class AuroraPlayerScreen extends StatefulWidget {
  const AuroraPlayerScreen({
    super.key,
    required this.source,
    required this.initialEngine,
    this.onDownload,
    this.onFavorite,
    this.onEnginePreferenceChanged,
    this.resolveHeadersForUrl,
  });

  final PlaybackSource source;
  final PlaybackEngineKind initialEngine;

  /// Pops the route with `'download'`.
  final VoidCallback? onDownload;

  /// Bookmarks the playing URL. Null hides the star.
  final Future<void> Function(String url)? onFavorite;

  /// Fired when the user switches engines, so the choice can be persisted.
  final ValueChanged<PlaybackEngineKind>? onEnginePreferenceChanged;

  /// Re-resolves cookies/Referer for a variant URL before switching to it.
  final Future<Map<String, String>> Function(String url)? resolveHeadersForUrl;

  @override
  State<AuroraPlayerScreen> createState() => _AuroraPlayerScreenState();
}

class _AuroraPlayerScreenState extends State<AuroraPlayerScreen> {
  late PlaybackEngineKind _engineKind;
  late PlaybackEngine _engine;
  late PlaybackSource _source;

  bool _controlsVisible = true;
  bool _showDiagnostics = false;
  bool _scrubbing = false;
  bool _favorited = false;
  Duration _scrubTarget = Duration.zero;
  BoxFit _fit = BoxFit.contain;
  Timer? _autoHide;

  /// Preview seeks are debounced — a drag emits far more updates than a second
  /// decoder can service, and queueing them all makes the bubble lag the thumb.
  Timer? _previewDebounce;

  // --- Hold to speed up ---
  // Press and hold for 2x; keep holding and slide up for 4x. Releasing
  // restores whatever rate was set before the press.
  bool _holdSpeedActive = false;
  double _holdSpeedRate = 2.0;
  double _speedBeforeHold = 1.0;

  /// Upward travel, in logical pixels, that escalates 2x to 4x.
  static const double _escalateAfter = 48.0;

  // --- Native window / PiP ---
  // Owned by the screen rather than either engine, so keep-awake and PiP
  // behave identically whichever backend is running. The previous split — one
  // engine setting its own wakelock, the other setting none — meant the
  // default backend let the screen sleep mid-video.
  static const MethodChannel _windowChannel =
      MethodChannel('aurora_downloader/player_window');
  static const MethodChannel _pipChannel =
      MethodChannel('aurora_downloader/pip');

  bool _inPip = false;
  bool _pipSupported = false;

  // --- Lock / orientation ---
  bool _locked = false;
  bool _landscapeForced = false;

  // --- Vertical drag: brightness (left half) / volume (right half) ---
  _DragMode _dragMode = _DragMode.none;
  double _dragStartValue = 0;
  double _dragStartY = 0;
  double _brightness = 0.5;
  double _volume = 1.0;

  // --- Hand-rolled double-tap ---
  // Flutter's onDoubleTap holds the gesture arena open for kDoubleTapTimeout,
  // which would add ~300ms of lag to every single-tap controls toggle.
  DateTime? _lastTapAt;
  Offset? _lastTapPos;

  // --- Transient gesture HUD ---
  _GestureHud? _hud;
  Timer? _hudTimer;

  // --- Wall clock in the header ---
  Timer? _clockTimer;

  @override
  void initState() {
    super.initState();
    _engineKind = widget.initialEngine;
    _source = widget.source;
    _engine = createPlaybackEngine(_engineKind);
    unawaited(_engine.open(_source));
    _restartAutoHide();
    _setKeepScreenOn(true);
    _initPip();
    _seedBrightness();
    _clockTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  /// Start the brightness drag wherever the device already is, so the first
  /// swipe does not jump. Failure is non-fatal — the drag still works, it just
  /// starts from 50%.
  Future<void> _seedBrightness() async {
    try {
      final v = await _windowChannel.invokeMethod<double>('getBrightness');
      if (v != null && mounted) _brightness = v.clamp(0.0, 1.0);
    } catch (_) {
      // Non-Android or channel unavailable.
    }
  }

  Future<void> _setKeepScreenOn(bool on) async {
    try {
      await _windowChannel.invokeMethod('setKeepScreenOn', {'value': on});
    } catch (_) {
      // Non-Android or channel missing — the screen may sleep, nothing worse.
    }
  }

  Future<void> _initPip() async {
    _pipChannel.setMethodCallHandler((call) async {
      if (call.method != 'onPipModeChanged') return;
      final inPip = call.arguments as bool? ?? false;
      if (!mounted) return;
      setState(() {
        _inPip = inPip;
        // Aurora's chrome must never paint into the PiP window.
        if (inPip) _controlsVisible = false;
      });
    });
    try {
      final supported =
          await _pipChannel.invokeMethod<bool>('isPipSupported') ?? false;
      if (mounted) setState(() => _pipSupported = supported);
    } catch (_) {
      // Leave the button hidden rather than offering something that no-ops.
    }
  }

  Future<void> _enterPip() async {
    final size = _engine.state.value.videoSize;
    try {
      await _pipChannel.invokeMethod('enterPip', {
        'width': size.width > 0 ? size.width.toInt() : 16,
        'height': size.height > 0 ? size.height.toInt() : 9,
      });
    } catch (_) {
      // Denied by the system (permission off, unsupported form factor).
    }
  }

  @override
  void dispose() {
    _autoHide?.cancel();
    _previewDebounce?.cancel();
    _hudTimer?.cancel();
    _clockTimer?.cancel();
    _pipChannel.setMethodCallHandler(null);
    // Hand the brightness override back — it is scoped to this window and
    // would otherwise persist for the rest of the app session.
    unawaited(
      _windowChannel
          .invokeMethod('setBrightness', {'value': -1.0})
          .catchError((_) => null),
    );
    // Hand the display back before the route goes — a stuck KEEP_SCREEN_ON
    // flag would outlive the player and drain the battery silently.
    unawaited(_setKeepScreenOn(false));
    unawaited(_engine.dispose());
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
    super.dispose();
  }

  void _restartAutoHide() {
    _autoHide?.cancel();
    _autoHide = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    if (_locked) return;
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) {
      _restartAutoHide();
    } else {
      _autoHide?.cancel();
    }
  }

  void _showHud(_GestureHud hud, {bool sticky = false}) {
    _hudTimer?.cancel();
    if (!mounted) return;
    setState(() => _hud = hud);
    if (sticky) return;
    _hudTimer = Timer(const Duration(milliseconds: 650), () {
      if (mounted) setState(() => _hud = null);
    });
  }

  void _clearHud() {
    _hudTimer?.cancel();
    if (mounted) setState(() => _hud = null);
  }

  // --- Tap / double-tap ---------------------------------------------------

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
    _toggleControls();
  }

  void _onDoubleTap(Offset localPosition) {
    if (_locked) return;
    final state = _engine.state.value;
    if (state.status != PlaybackStatus.ready) return;

    final width = context.size?.width ?? MediaQuery.sizeOf(context).width;
    final third = width / 3;
    if (localPosition.dx < third) {
      _seekBy(const Duration(seconds: -10));
    } else if (localPosition.dx > width - third) {
      _seekBy(const Duration(seconds: 10));
    } else {
      state.isPlaying ? _engine.pause() : _engine.play();
      _restartAutoHide();
    }
  }

  void _seekBy(Duration delta) {
    final state = _engine.state.value;
    var target = state.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (state.duration > Duration.zero && target > state.duration) {
      target = state.duration;
    }
    unawaited(_engine.seek(target));
    _showHud(
      _GestureHud(
        icon: delta.isNegative
            ? Icons.fast_rewind_rounded
            : Icons.fast_forward_rounded,
        label: '${delta.isNegative ? '−' : '+'}${delta.inSeconds.abs()}s',
      ),
    );
  }

  // --- Vertical drag: brightness (left) / volume (right) ------------------

  void _onVerticalDragStart(DragStartDetails d) {
    if (_locked || _inPip) return;
    final width = context.size?.width ?? MediaQuery.sizeOf(context).width;
    final isLeft = d.localPosition.dx < width / 2;
    _dragMode = isLeft ? _DragMode.brightness : _DragMode.volume;
    _dragStartValue = isLeft ? _brightness : _volume;
    _dragStartY = d.localPosition.dy;
  }

  void _onVerticalDragUpdate(DragUpdateDetails d) {
    if (_dragMode == _DragMode.none || _locked) return;
    final height = context.size?.height ?? MediaQuery.sizeOf(context).height;
    // ~70% of the height covers the full range: enough travel for fine
    // control without demanding a full-height swipe.
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

  void _endVerticalDrag() => _dragMode = _DragMode.none;

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
    unawaited(_engine.setVolume(value));
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

  // --- Lock / orientation -------------------------------------------------

  void _toggleLock() {
    setState(() {
      _locked = !_locked;
      if (_locked) {
        _controlsVisible = false;
        _autoHide?.cancel();
      } else {
        _controlsVisible = true;
        _restartAutoHide();
      }
    });
  }

  void _toggleOrientation() {
    _restartAutoHide();
    _landscapeForced = !_landscapeForced;
    unawaited(
      SystemChrome.setPreferredOrientations(
        _landscapeForced
            ? const [
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ]
            : DeviceOrientation.values,
      ),
    );
    setState(() {});
  }

  /// Rebuilds on the other backend, resuming where the current one got to.
  /// This is the escape hatch: one tap moves a stream that will not start off
  /// the stack that is failing it.
  Future<void> _switchEngine(PlaybackEngineKind next) async {
    if (next == _engineKind) return;
    final resumeAt = _engine.state.value.position;
    final old = _engine;

    setState(() {
      _engineKind = next;
      _engine = createPlaybackEngine(next);
    });
    widget.onEnginePreferenceChanged?.call(next);

    unawaited(old.dispose());
    await _engine.open(_source.copyWith(startAt: resumeAt));
  }

  // --- Hold to speed up ---------------------------------------------------

  void _onHoldStart() {
    if (_locked) return;
    final state = _engine.state.value;
    if (state.status != PlaybackStatus.ready) return;
    _speedBeforeHold = state.speed;
    _holdSpeedRate = 2.0;
    setState(() {
      _holdSpeedActive = true;
      _controlsVisible = false;
    });
    // A hold that silently pauses would be indistinguishable from a stall.
    unawaited(_engine.play());
    unawaited(_engine.setSpeed(_holdSpeedRate));
    _showSpeedHud();
  }

  void _onHoldMove(LongPressMoveUpdateDetails details) {
    if (!_holdSpeedActive) return;
    // Negative dy is upward.
    final next = details.localOffsetFromOrigin.dy <= -_escalateAfter ? 4.0 : 2.0;
    if (next == _holdSpeedRate) return;
    setState(() => _holdSpeedRate = next);
    unawaited(_engine.setSpeed(next));
    _showSpeedHud();
  }

  void _onHoldEnd() {
    if (!_holdSpeedActive) return;
    setState(() => _holdSpeedActive = false);
    unawaited(_engine.setSpeed(_speedBeforeHold));
    _clearHud();
  }

  /// Sticky while the finger is down — this one is a status readout, not a
  /// transient acknowledgement like seek or volume.
  void _showSpeedHud() {
    _showHud(
      _GestureHud(
        icon: Icons.fast_forward_rounded,
        label: '${_holdSpeedRate.toStringAsFixed(0)}×',
        hint: _holdSpeedRate < 4.0 ? 'slide up for 4×' : null,
      ),
      sticky: true,
    );
  }

  // --- Scrub preview ------------------------------------------------------

  void _onScrubStart(Duration at) {
    setState(() {
      _scrubbing = true;
      _scrubTarget = at;
    });
    // Lazy: the second decoder only ever opens if the user actually scrubs.
    unawaited(_engine.prepareScrubPreview());
  }

  void _onScrubUpdate(Duration at) {
    setState(() => _scrubTarget = at);
    _previewDebounce?.cancel();
    _previewDebounce = Timer(const Duration(milliseconds: 120), () {
      unawaited(_engine.seekScrubPreview(at));
    });
  }

  void _onScrubEnd(Duration at) {
    _previewDebounce?.cancel();
    setState(() => _scrubbing = false);
    unawaited(_engine.seek(at));
    _restartAutoHide();
  }

  Future<void> _retry() async {
    final resumeAt = _engine.state.value.position;
    await _engine.open(_source.copyWith(startAt: resumeAt));
  }

  Future<void> _switchVariant(PlaybackVariant variant) async {
    final resumeAt = _engine.state.value.position;
    var headers = variant.headers ?? _source.headers;
    if (variant.headers == null && widget.resolveHeadersForUrl != null) {
      try {
        headers = await widget.resolveHeadersForUrl!(variant.url);
      } catch (_) {
        // Keep the current headers — they are more likely right than none.
      }
    }
    if (!mounted) return;
    setState(() {
      _source = _source.copyWith(url: variant.url, headers: headers);
    });
    await _engine.open(_source.copyWith(startAt: resumeAt));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: ValueListenableBuilder<PlaybackState>(
        valueListenable: _engine.state,
        builder: (context, state, _) {
          // In PiP the window is a thumbnail on someone else's screen — it
          // gets the video and nothing else.
          if (_inPip) {
            return Center(
              child: state.canShowSurface
                  ? _engine.buildSurface(fit: BoxFit.contain)
                  : const SizedBox.expand(),
            );
          }
          return Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: _onTapUp,
                onLongPressStart: (_) => _onHoldStart(),
                onLongPressMoveUpdate: _onHoldMove,
                onLongPressEnd: (_) => _onHoldEnd(),
                onLongPressCancel: _onHoldEnd,
                onVerticalDragStart: _onVerticalDragStart,
                onVerticalDragUpdate: _onVerticalDragUpdate,
                onVerticalDragEnd: (_) => _endVerticalDrag(),
                onVerticalDragCancel: _endVerticalDrag,
                child: Center(
                  child: state.canShowSurface
                      ? _engine.buildSurface(fit: _fit)
                      : const SizedBox.expand(),
                ),
              ),
              if (_hud != null && !_locked) _HudPill(hud: _hud!),
              // Always reachable, even locked — it is the way back out.
              _LockButton(locked: _locked, onTap: _toggleLock),
              if (state.status == PlaybackStatus.opening)
                const Center(child: CircularProgressIndicator()),
              if (state.isBuffering && state.status == PlaybackStatus.ready)
                const Center(child: CircularProgressIndicator()),
              if (state.status == PlaybackStatus.failed ||
                  state.status == PlaybackStatus.stalled)
                _Problem(
                  state: state,
                  engineKind: _engineKind,
                  onRetry: _retry,
                  onSwitchEngine: () => _switchEngine(_engineKind.other),
                ),
              if (_controlsVisible && !_locked) ...[
                _TopBar(
                  title: _source.title,
                  engineKind: _engineKind,
                  favorited: _favorited,
                  landscapeForced: _landscapeForced,
                  onToggleOrientation: _toggleOrientation,
                  onPip: _pipSupported ? _enterPip : null,
                  onBack: () => Navigator.of(context).maybePop(),
                  onToggleDiagnostics: () =>
                      setState(() => _showDiagnostics = !_showDiagnostics),
                  onDownload: widget.onDownload,
                  onFavorite: widget.onFavorite == null
                      ? null
                      : () async {
                          await widget.onFavorite!(_source.url);
                          if (mounted) setState(() => _favorited = true);
                        },
                ),
                _BottomBar(
                  state: state,
                  scrubbing: _scrubbing,
                  scrubTarget: _scrubTarget,
                  fit: _fit,
                  variants: _source.variants,
                  scrubPreview: _scrubbing ? _engine.buildScrubPreview() : null,
                  onPlayPause: () {
                    state.isPlaying ? _engine.pause() : _engine.play();
                    _restartAutoHide();
                  },
                  onScrubStart: _onScrubStart,
                  onScrubUpdate: _onScrubUpdate,
                  onScrubEnd: _onScrubEnd,
                  onCycleFit: () {
                    setState(() {
                      _fit = _fit == BoxFit.contain
                          ? BoxFit.cover
                          : _fit == BoxFit.cover
                              ? BoxFit.fill
                              : BoxFit.contain;
                    });
                    _restartAutoHide();
                  },
                  onSpeed: (v) {
                    _engine.setSpeed(v);
                    _restartAutoHide();
                  },
                  onVariant: _switchVariant,
                ),
              ],
              if (_showDiagnostics)
                _DiagnosticsPanel(
                  data: _engine.diagnostics(),
                  onClose: () => setState(() => _showDiagnostics = false),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Shown for both `failed` and `stalled` — from the user's side they are the
/// same event ("it isn't playing"), and both are fixed by the same two actions.
class _Problem extends StatelessWidget {
  const _Problem({
    required this.state,
    required this.engineKind,
    required this.onRetry,
    required this.onSwitchEngine,
  });

  final PlaybackState state;
  final PlaybackEngineKind engineKind;
  final VoidCallback onRetry;
  final VoidCallback onSwitchEngine;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final stalled = state.status == PlaybackStatus.stalled;
    final message = stalled
        ? 'This stream opened but never started playing. That usually means '
            'the link is tied to the page session and has expired, or this '
            'engine cannot decode it.'
        : (state.errorMessage ?? 'Playback failed.');

    return Container(
      color: Colors.black.withValues(alpha: 0.82),
      padding: const EdgeInsets.all(28),
      child: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                stalled ? Icons.hourglass_disabled_rounded : Icons.error_outline,
                color: stalled ? ac.accentAmber : ac.statusError,
                size: 44,
              ),
              const SizedBox(height: 14),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Retry'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white24),
                    ),
                  ),
                  ElevatedButton.icon(
                    onPressed: onSwitchEngine,
                    icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                    label: Text('Try ${engineKind.other.label}'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: ac.accentFrost,
                      foregroundColor: Colors.black,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.engineKind,
    required this.favorited,
    required this.landscapeForced,
    required this.onToggleOrientation,
    required this.onBack,
    required this.onToggleDiagnostics,
    this.onDownload,
    this.onFavorite,
    this.onPip,
  });

  final String title;
  final PlaybackEngineKind engineKind;
  final bool favorited;
  final bool landscapeForced;
  final VoidCallback onToggleOrientation;
  final VoidCallback onBack;
  final VoidCallback onToggleDiagnostics;
  final VoidCallback? onDownload;
  final VoidCallback? onFavorite;

  /// Null when the device or build does not support picture-in-picture, so the
  /// button is absent rather than present and inert.
  final VoidCallback? onPip;

  static String _clockLabel() {
    final now = DateTime.now();
    final h = now.hour.toString().padLeft(2, '0');
    final m = now.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black.withValues(alpha: 0.75), Colors.transparent],
          ),
        ),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: onBack,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title.isEmpty ? 'Playing' : title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    engineKind.label,
                    // Without these the label wraps and hyphenates mid-word
                    // ("System (ExoPlay / er)") as soon as the trailing icon
                    // cluster squeezes this column on a narrow screen.
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            // Wall clock — the reason it belongs in a fullscreen player is
            // that the status bar is hidden while watching.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                _clockLabel(),
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontFamily: 'JetBrains Mono',
                ),
              ),
            ),
            IconButton(
              tooltip: landscapeForced
                  ? 'Follow device rotation'
                  : 'Lock to landscape',
              icon: Icon(
                landscapeForced
                    ? Icons.screen_lock_rotation
                    : Icons.screen_rotation_rounded,
                color: landscapeForced ? Colors.amber : Colors.white70,
              ),
              onPressed: onToggleOrientation,
            ),
            if (onPip != null)
              _CompactIcon(
                tooltip: 'Picture-in-picture',
                icon: Icons.picture_in_picture_alt_rounded,
                onPressed: onPip!,
              ),
            if (onFavorite != null)
              _CompactIcon(
                tooltip: 'Add to favourites',
                icon: favorited
                    ? Icons.star_rounded
                    : Icons.star_border_rounded,
                color: favorited ? Colors.amber : Colors.white70,
                onPressed: onFavorite!,
              ),
            // Download and diagnostics live in the overflow: six controls plus
            // a clock left the title column ~30dp wide, which is how the
            // header ended up rendering as "164…".
            PopupMenuButton<String>(
              tooltip: 'More',
              icon: const Icon(Icons.more_vert, color: Colors.white70),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              onSelected: (v) {
                if (v == 'diagnostics') onToggleDiagnostics();
                if (v == 'download') onDownload?.call();
              },
              itemBuilder: (_) => [
                if (onDownload != null)
                  const PopupMenuItem(
                    value: 'download',
                    child: Text('Download'),
                  ),
                const PopupMenuItem(
                  value: 'diagnostics',
                  child: Text('Playback diagnostics'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Tight icon button — the default 48dp IconButton footprint is what starved
/// the title column in the header.
class _CompactIcon extends StatelessWidget {
  const _CompactIcon({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.color = Colors.white70,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, size: 20),
      color: color,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 38, height: 38),
      onPressed: onPressed,
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.state,
    required this.scrubbing,
    required this.scrubTarget,
    required this.fit,
    required this.variants,
    required this.scrubPreview,
    required this.onPlayPause,
    required this.onScrubStart,
    required this.onScrubUpdate,
    required this.onScrubEnd,
    required this.onCycleFit,
    required this.onSpeed,
    required this.onVariant,
  });

  final PlaybackState state;
  final bool scrubbing;
  final Duration scrubTarget;
  final BoxFit fit;
  final List<PlaybackVariant> variants;

  /// Frame at the scrub position, or null when the engine has no preview
  /// decoder ready — the bubble then shows just the timestamp.
  final Widget? scrubPreview;

  final VoidCallback onPlayPause;
  final ValueChanged<Duration> onScrubStart;
  final ValueChanged<Duration> onScrubUpdate;
  final ValueChanged<Duration> onScrubEnd;
  final VoidCallback onCycleFit;
  final ValueChanged<double> onSpeed;
  final ValueChanged<PlaybackVariant> onVariant;

  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$m:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final total = state.duration;
    final shown = scrubbing ? scrubTarget : state.position;
    final maxMs = total.inMilliseconds;
    final canSeek = maxMs > 0;

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: EdgeInsets.only(
          bottom: MediaQuery.paddingOf(context).bottom + 6,
        ),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black.withValues(alpha: 0.82), Colors.transparent],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const SizedBox(width: 12),
                Text(
                  _fmt(shown),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontFamily: 'JetBrains Mono',
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final fraction = (canSeek && maxMs > 0)
                          ? (shown.inMilliseconds / maxMs).clamp(0.0, 1.0)
                          : 0.0;
                      return Stack(
                        clipBehavior: Clip.none,
                        alignment: Alignment.center,
                        children: [
                          Slider(
                            value: canSeek
                                ? shown.inMilliseconds
                                    .clamp(0, maxMs)
                                    .toDouble()
                                : 0,
                            max: canSeek ? maxMs.toDouble() : 1,
                            activeColor: ac.accentFrost,
                            inactiveColor: Colors.white24,
                            onChangeStart: canSeek
                                ? (v) => onScrubStart(
                                    Duration(milliseconds: v.round()))
                                : null,
                            onChanged: canSeek
                                ? (v) => onScrubUpdate(
                                    Duration(milliseconds: v.round()))
                                : null,
                            onChangeEnd: canSeek
                                ? (v) => onScrubEnd(
                                    Duration(milliseconds: v.round()))
                                : null,
                          ),
                          if (scrubbing)
                            _ScrubBubble(
                              trackWidth: constraints.maxWidth,
                              fraction: fraction,
                              label: _fmt(shown),
                              preview: scrubPreview,
                            ),
                        ],
                      );
                    },
                  ),
                ),
                Text(
                  canSeek ? _fmt(total) : 'LIVE',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontFamily: 'JetBrains Mono',
                  ),
                ),
                const SizedBox(width: 12),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  iconSize: 34,
                  icon: Icon(
                    state.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    color: Colors.white,
                  ),
                  onPressed: onPlayPause,
                ),
                PopupMenuButton<double>(
                  tooltip: 'Playback speed',
                  onSelected: onSpeed,
                  itemBuilder: (_) => [
                    for (final s in const [0.5, 1.0, 1.25, 1.5, 2.0])
                      PopupMenuItem(value: s, child: Text('${s}x')),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    child: Text(
                      '${state.speed}x',
                      style: const TextStyle(
                          color: Colors.white, fontSize: 13),
                    ),
                  ),
                ),
                if (variants.length >= 2)
                  PopupMenuButton<PlaybackVariant>(
                    tooltip: 'Quality',
                    onSelected: onVariant,
                    itemBuilder: (_) => [
                      for (final v in variants)
                        PopupMenuItem(value: v, child: Text(v.label)),
                    ],
                    child: const Padding(
                      padding: EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      child: Icon(Icons.high_quality_outlined,
                          color: Colors.white),
                    ),
                  ),
                IconButton(
                  tooltip: 'Aspect ratio',
                  icon: const Icon(Icons.aspect_ratio, color: Colors.white),
                  onPressed: onCycleFit,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Frame-at-position bubble that rides above the seek thumb.
///
/// Falls back to a timestamp-only pill when the engine has no preview decoder
/// — either it does not support one, or the second connection was refused,
/// which signed CDN links routinely do.
class _ScrubBubble extends StatelessWidget {
  const _ScrubBubble({
    required this.trackWidth,
    required this.fraction,
    required this.label,
    required this.preview,
  });

  final double trackWidth;
  final double fraction;
  final String label;
  final Widget? preview;

  static const double _w = 148;
  static const double _h = 83; // 16:9 plus the caption strip

  @override
  Widget build(BuildContext context) {
    final hasFrame = preview != null;
    final width = hasFrame ? _w : 62.0;
    // Track the thumb, but never let the bubble hang off either end.
    final left = (trackWidth * fraction - width / 2).clamp(
      0.0,
      (trackWidth - width).clamp(0.0, double.infinity),
    );

    return Positioned(
      left: left,
      bottom: 34,
      width: width,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasFrame)
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(7),
                  ),
                  child: SizedBox(
                    width: _w,
                    height: _h - 21,
                    child: preview,
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontFamily: 'JetBrains Mono',
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One pill for every gesture — seek, brightness, volume, hold-speed.
class _HudPill extends StatelessWidget {
  const _HudPill({required this.hud});

  final _GestureHud hud;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Positioned(
      top: MediaQuery.paddingOf(context).top + 18,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.66),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(hud.icon, size: 18, color: ac.accentFrost),
                    const SizedBox(width: 8),
                    Text(
                      hud.label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    if (hud.hint != null) ...[
                      const SizedBox(width: 10),
                      const Icon(Icons.keyboard_arrow_up_rounded,
                          size: 16, color: Colors.white54),
                      Text(
                        hud.hint!,
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 11),
                      ),
                    ],
                  ],
                ),
                if (hud.value != null) ...[
                  const SizedBox(height: 6),
                  SizedBox(
                    width: 110,
                    height: 3,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: hud.value!.clamp(0.0, 1.0),
                        backgroundColor: Colors.white24,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(ac.accentFrost),
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
}

/// Left-edge lock. Stays hittable while locked — it is the only way out.
class _LockButton extends StatelessWidget {
  const _LockButton({required this.locked, required this.onTap});

  final bool locked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 8,
      top: 0,
      bottom: 0,
      child: Center(
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: Colors.black45,
              borderRadius: BorderRadius.circular(19),
            ),
            child: Icon(
              locked ? Icons.lock_rounded : Icons.lock_open_rounded,
              color: locked ? Colors.amber : Colors.white70,
              size: 18,
            ),
          ),
        ),
      ),
    );
  }
}

/// Live engine state, on screen. The previous player's failure mode was that
/// none of this was observable from the device — reproducing meant guessing.
class _DiagnosticsPanel extends StatelessWidget {
  const _DiagnosticsPanel({required this.data, required this.onClose});

  final Map<String, Object?> data;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 8,
      top: MediaQuery.paddingOf(context).top + 56,
      width: 300,
      child: Material(
        color: Colors.black.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Playback diagnostics',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: onClose,
                    child: const Icon(Icons.close,
                        color: Colors.white54, size: 18),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final entry in data.entries)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: RichText(
                            text: TextSpan(
                              children: [
                                TextSpan(
                                  text: '${entry.key}: ',
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 11,
                                  ),
                                ),
                                TextSpan(
                                  text: '${entry.value}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontFamily: 'JetBrains Mono',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:aurora_downloader/theme/aurora_palette.dart';

import 'engine_factory.dart';
import 'playback_engine.dart';
import 'playback_source.dart';
import 'playback_state.dart';

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
    _pipChannel.setMethodCallHandler(null);
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
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _restartAutoHide();
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
  }

  void _onHoldMove(LongPressMoveUpdateDetails details) {
    if (!_holdSpeedActive) return;
    // Negative dy is upward.
    final next = details.localOffsetFromOrigin.dy <= -_escalateAfter ? 4.0 : 2.0;
    if (next == _holdSpeedRate) return;
    setState(() => _holdSpeedRate = next);
    unawaited(_engine.setSpeed(next));
  }

  void _onHoldEnd() {
    if (!_holdSpeedActive) return;
    setState(() => _holdSpeedActive = false);
    unawaited(_engine.setSpeed(_speedBeforeHold));
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
                onTap: _toggleControls,
                onLongPressStart: (_) => _onHoldStart(),
                onLongPressMoveUpdate: _onHoldMove,
                onLongPressEnd: (_) => _onHoldEnd(),
                onLongPressCancel: _onHoldEnd,
                child: Center(
                  child: state.canShowSurface
                      ? _engine.buildSurface(fit: _fit)
                      : const SizedBox.expand(),
                ),
              ),
              if (_holdSpeedActive)
                _SpeedHud(
                  rate: _holdSpeedRate,
                  canEscalate: _holdSpeedRate < 4.0,
                ),
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
              if (_controlsVisible) ...[
                _TopBar(
                  title: _source.title,
                  engineKind: _engineKind,
                  favorited: _favorited,
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
    required this.onBack,
    required this.onToggleDiagnostics,
    this.onDownload,
    this.onFavorite,
    this.onPip,
  });

  final String title;
  final PlaybackEngineKind engineKind;
  final bool favorited;
  final VoidCallback onBack;
  final VoidCallback onToggleDiagnostics;
  final VoidCallback? onDownload;
  final VoidCallback? onFavorite;

  /// Null when the device or build does not support picture-in-picture, so the
  /// button is absent rather than present and inert.
  final VoidCallback? onPip;

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
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            if (onPip != null)
              IconButton(
                tooltip: 'Picture-in-picture',
                icon: const Icon(Icons.picture_in_picture_alt_rounded,
                    color: Colors.white70),
                onPressed: onPip,
              ),
            if (onFavorite != null)
              IconButton(
                tooltip: 'Add to favourites',
                icon: Icon(
                  favorited ? Icons.star_rounded : Icons.star_border_rounded,
                  color: favorited ? Colors.amber : Colors.white70,
                ),
                onPressed: onFavorite,
              ),
            IconButton(
              tooltip: 'Playback diagnostics',
              icon: const Icon(Icons.monitor_heart_outlined,
                  color: Colors.white70),
              onPressed: onToggleDiagnostics,
            ),
            if (onDownload != null)
              IconButton(
                tooltip: 'Download',
                icon: const Icon(Icons.download, color: Colors.white70),
                onPressed: onDownload,
              ),
          ],
        ),
      ),
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

/// Hold-to-speed indicator. Shows the hint to slide up only while 4x is still
/// reachable, so it stops nagging once the user is already there.
class _SpeedHud extends StatelessWidget {
  const _SpeedHud({required this.rate, required this.canEscalate});

  final double rate;
  final bool canEscalate;

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
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.fast_forward_rounded,
                    size: 18, color: ac.accentFrost),
                const SizedBox(width: 8),
                Text(
                  '${rate.toStringAsFixed(rate == rate.roundToDouble() ? 0 : 1)}×',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (canEscalate) ...[
                  const SizedBox(width: 10),
                  const Icon(Icons.keyboard_arrow_up_rounded,
                      size: 16, color: Colors.white54),
                  const Text(
                    'slide up for 4×',
                    style: TextStyle(color: Colors.white54, fontSize: 11),
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

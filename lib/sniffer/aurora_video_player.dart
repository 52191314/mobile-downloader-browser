import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../theme/aurora_palette.dart';

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

/// A full-screen custom video player with UC Browser-style controls.
///
/// Wraps [VideoPlayerController] directly (no Chewie) so we own every pixel
/// of the UI: header bar, tap-to-seek, hold-to-speed-up, lockable controls,
/// clock display, and custom bottom bar.
///
/// - Tapping the video toggles the control overlays (auto-hide after 3s).
/// - Long-pressing the video temporarily boosts playback to 2×.
/// - A lock icon at the left edge disables all overlay controls.
/// - When [qualityOptions] has 2+ entries, a quality picker appears in the
///   bottom bar (and overflow menu) so the user can switch mid-playback.
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
  /// Throttle main-player UI rebuilds so the bar moves smoothly without
  /// setState every vsync.
  DateTime _lastProgressUiAt = DateTime.fromMillisecondsSinceEpoch(0);

  // --- Speed ---
  double _currentSpeed = 1.0;
  bool _holdSpeedActive = false;
  double _holdSpeedPrev = 1.0;

  // --- Aspect ratio ---
  BoxFit _fit = BoxFit.contain;

  // --- Timers ---
  Timer? _autoHideTimer;
  Timer? _clockTimer;

  // --- Play/pause icon flash ---
  bool _showPlayPauseIcon = false;
  Timer? _playPauseIconTimer;

  // --- Buffering slow detection ---
  bool _isBufferingSlow = false;
  Timer? _bufferingTimer;

  // --- Star ---
  bool _isFavorited = false;

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
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
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
        lower.contains('m3u8')) {
      return VideoFormat.hls;
    }
    if (lower.contains('.mpd') || lower.contains('dash+xml')) {
      return VideoFormat.dash;
    }
    return null;
  }

  void _onControllerUpdate() {
    if (!mounted || _controller == null) return;
    final v = _controller!.value;

    // Detect buffering
    if (v.isPlaying && v.isBuffering) {
      _bufferingTimer ??= Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _isBufferingSlow = true);
      });
    } else {
      _bufferingTimer?.cancel();
      _bufferingTimer = null;
      if (_isBufferingSlow) {
        setState(() => _isBufferingSlow = false);
      }
    }

    // Keep the progress bar live (~10 fps). Previously only the 1s clock
    // timer rebuilt UI, so the bar jumped and felt "stuck in the middle".
    if (_isSeeking) return;
    final now = DateTime.now();
    if (now.difference(_lastProgressUiAt).inMilliseconds < 100) return;
    _lastProgressUiAt = now;
    setState(() {});
  }

  @override
  void dispose() {
    _autoHideTimer?.cancel();
    _clockTimer?.cancel();
    _previewSeekDebounce?.cancel();
    if (_controllerListener != null) {
      _controller?.removeListener(_controllerListener!);
    }
    _playPauseIconTimer?.cancel();
    _bufferingTimer?.cancel();
    _controller?.dispose();
    _previewController?.dispose();
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

  void _onVideoTap() {
    if (_locked) return;
    if (_controller == null || !_initialized) return;
    setState(() {
      if (_controller!.value.isPlaying) {
        _controller!.pause();
      } else {
        _controller!.play();
      }
      _controlsVisible = !_controlsVisible;
    });
    _flashPlayPauseIcon();
  }

  void _onLongPressStart(LongPressStartDetails d) {
    if (_locked) return;
    if (_controller == null || !_initialized) return;
    _holdSpeedPrev = _currentSpeed;
    _controller!.setPlaybackSpeed(2.0);
    setState(() => _holdSpeedActive = true);
  }

  void _onLongPressEnd(LongPressEndDetails d) {
    if (_locked) return;
    if (_controller == null || !_initialized) return;
    _controller!.setPlaybackSpeed(_holdSpeedPrev);
    setState(() => _holdSpeedActive = false);
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

  static const List<double> _speedOptions = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

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
                      '${speed}x',
                      style: TextStyle(
                        color: selected ? ac.textPrimary : ac.textSecondary,
                        fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    onTap: () {
                      _controller?.setPlaybackSpeed(speed);
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
        // Pop and let the caller handle it (or use the sourcePageUrl)
        Navigator.pop(context, 'open_browser');
      } else if (value == 'copy_url') {
        // Copy URL to clipboard
        // ignore: deprecated_member_use
        // Clipboard.setData(ClipboardData(text: widget.url));
        Navigator.pop(context, 'copy_url');
      } else if (value == 'share') {
        Navigator.pop(context, 'share');
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

  String get _currentTimeString {
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
  }

  // ---- Build ----

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // --- Video area ---
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _onVideoTap,
                onLongPressStart: _onLongPressStart,
                onLongPressEnd: _onLongPressEnd,
                child: _buildVideoArea(),
              ),
            ),

            // --- Hold-speed badge ---
            if (_holdSpeedActive && !_locked)
              Positioned(
                top: 60,
                right: 16,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: ac.accentFrost.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    '2x',
                    style: TextStyle(
                      color: Colors.black,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),

            // --- Controls ---
            if (_controlsVisible && !_locked) _buildHeader(),
            if (_controlsVisible && !_locked) _buildBottomControls(),

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

    return Stack(
      alignment: Alignment.center,
      children: [
        // Video
        ClipRect(
          child: SizedBox.expand(
            child: FittedBox(
              fit: _fit,
              child: SizedBox(
                width: _videoWidth,
                height: _videoHeight,
                child: VideoPlayer(c),
              ),
            ),
          ),
        ),

        // Buffering slow overlay
        if (_isBufferingSlow && !_locked)
          Positioned.fill(
            child: Container(
              color: Colors.black54,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(ac.accentFrost),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Buffering is slow',
                    style: TextStyle(color: Colors.white60, fontSize: 14),
                  ),
                  const SizedBox(height: 4),
                  GestureDetector(
                    onTap: _onRetry,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
              ),
            ),
          ),

        // Play/pause flash icon
        if (_showPlayPauseIcon)
          IgnorePointer(
            child: AnimatedOpacity(
              opacity: _showPlayPauseIcon ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: Colors.black38,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  c.value.isPlaying ? Icons.play_arrow_rounded : Icons.pause_rounded,
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
            // PiP / Minimize button
            GestureDetector(
              onTap: () => Navigator.pop(context),
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

  Widget _buildBottomControls() {
    final ac = context.ac;
    final c = _controller;
    final position = (c != null && c.value.isInitialized)
        ? c.value.position
        : Duration.zero;
    final duration = (c != null && c.value.isInitialized)
        ? c.value.duration
        : Duration.zero;

    final displayPosition = _isSeeking ? _seekPosition : position;

    final double progress =
        duration.inMilliseconds > 0
            ? (displayPosition.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
            : 0.0;

    // Build buffered ranges
    double bufferedProgress = 0.0;
    if (c != null && c.value.isInitialized && duration.inMilliseconds > 0) {
      for (final range in c.value.buffered) {
        final end = range.end.inMilliseconds;
        if (end > bufferedProgress) {
          bufferedProgress = end.toDouble();
        }
      }
    }
    final double bufferedFraction =
        duration.inMilliseconds > 0
            ? (bufferedProgress / duration.inMilliseconds).clamp(0.0, 1.0)
            : 0.0;

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
            _buildProgressBar(bufferedFraction, progress, duration),

            const SizedBox(height: 6),

            // --- Bottom action row ---
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  // Time
                  Text(
                    '${_formatDuration(displayPosition)} / ${_formatDuration(duration)}',
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
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
                    const SizedBox(width: 2),
                  ],
                  // Speed
                  _miniButton(
                    onTap: _showSpeedMenu,
                    child: Text(
                      '${_currentSpeed}x',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  // Star (favorite)
                  _miniButton(
                    onTap: _onToggleFavorite,
                    child: Icon(
                      _isFavorited ? Icons.star_rounded : Icons.star_outline_rounded,
                      color: _isFavorited ? ac.accentFrost : Colors.white70,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 2),
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
                  const SizedBox(width: 2),
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

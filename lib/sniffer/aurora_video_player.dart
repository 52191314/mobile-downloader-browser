import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../theme/aurora_palette.dart';

/// A full-screen custom video player with UC Browser-style controls.
///
/// Wraps [VideoPlayerController] directly (no Chewie) so we own every pixel
/// of the UI: header bar, tap-to-seek, hold-to-speed-up, lockable controls,
/// clock display, and custom bottom bar.
///
/// - Tapping the video toggles the control overlays (auto-hide after 3s).
/// - Long-pressing the video temporarily boosts playback to 2×.
/// - A lock icon at the left edge disables all overlay controls.
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

  const AuroraVideoPlayer({
    super.key,
    required this.url,
    required this.title,
    this.headers = const {},
    this.onDownload,
    this.onFavorite,
    this.sourcePageUrl,
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

  // --- UI state ---
  bool _controlsVisible = true;
  bool _locked = false;

  // --- Seeking ---
  bool _isSeeking = false;
  Duration _seekPosition = Duration.zero;

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

  @override
  void initState() {
    super.initState();
    _initPlayer();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _initPlayer({bool retry = false}) async {
    if (retry) {
      setState(() {
        _error = null;
        _initialized = false;
      });
    }

    final uri = Uri.tryParse(widget.url);
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

      final headers = widget.headers.isNotEmpty
          ? Map<String, String>.from(widget.headers)
          : <String, String>{};

      // Ensure Accept covers common media/HLS responses; some CDNs
      // reject bare clients that omit it.
      if (!headers.keys.any((k) => k.toLowerCase() == 'accept')) {
        headers['Accept'] = '*/*';
      }

      final formatHint = _formatHintForUrl(widget.url);
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
        final hasCookie = widget.headers.keys.any(
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
  }

  @override
  void dispose() {
    _autoHideTimer?.cancel();
    _clockTimer?.cancel();
    if (_controllerListener != null) {
      _controller?.removeListener(_controllerListener!);
    }
    _playPauseIconTimer?.cancel();
    _bufferingTimer?.cancel();
    _controller?.dispose();
    super.dispose();
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
      if (value == 'open_browser') {
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
    final isPlaying = c?.value.isPlaying ?? false;

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

  Widget _buildProgressBar(double bufferedFraction, double progress, Duration duration) {
    final ac = context.ac;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (details) {
        if (_locked) return;
        _onSeek(details.localPosition.dx);
      },
      onHorizontalDragStart: (_) {
        if (_locked) return;
        setState(() => _isSeeking = true);
      },
      onHorizontalDragUpdate: (details) {
        if (_locked) return;
        final w = context.size?.width ?? MediaQuery.of(context).size.width;
        final fraction = (details.localPosition.dx / w).clamp(0.0, 1.0);
        setState(() {
          _seekPosition = Duration(
            milliseconds: (fraction * duration.inMilliseconds).toInt(),
          );
        });
      },
      onHorizontalDragEnd: (details) {
        if (_locked) return;
        if (_controller != null) {
          _controller!.seekTo(_seekPosition);
        }
        setState(() => _isSeeking = false);
        if (!_controller!.value.isPlaying) {
          _controller!.play();
        }
        _resetAutoHideTimer();
      },
      child: SizedBox(
        height: 32,
        child: Center(
          child: Container(
            height: 4,
            margin: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: Colors.white12,
              borderRadius: BorderRadius.circular(2),
            ),
            child: Stack(
              children: [
                // Buffered track
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: bufferedFraction,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                // Played track
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: progress,
                  child: Container(
                    decoration: BoxDecoration(
                      color: ac.accentFrost,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                // Thumb
                Positioned(
                  left: (progress * (MediaQuery.of(context).size.width - 24)).clamp(-6.0, MediaQuery.of(context).size.width - 18),
                  top: -4,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: ac.accentFrost,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: ac.accentFrost.withValues(alpha: 0.4),
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
    );
  }

  void _onSeek(double dx) {
    if (_controller == null || !_controller!.value.isInitialized) return;
    final w = context.size?.width ?? MediaQuery.of(context).size.width;
    final fraction = (dx / w).clamp(0.0, 1.0);
    final pos = Duration(
      milliseconds: (fraction * _controller!.value.duration.inMilliseconds).toInt(),
    );
    _controller!.seekTo(pos);
    if (!_controller!.value.isPlaying) {
      _controller!.play();
    }
    _resetAutoHideTimer();
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

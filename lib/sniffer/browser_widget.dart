import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'browser_controller.dart';
import 'pull_to_refresh_tracker.dart';

class BrowserWidget extends StatefulWidget {
  final SnifferBrowserController controller;
  final VoidCallback? onSwipeForward;
  final VoidCallback? onRefresh;

  /// When non-null/non-empty, the WebView navigates here on first create.
  /// Used for external opens (Queue source page, History open-all) so the
  /// page starts loading even if a deferred [loadRequest] races with
  /// platform-view creation.
  final String? initialUrl;
  final String? userAgent;

  const BrowserWidget({
    super.key,
    required this.controller,
    this.onSwipeForward,
    this.onRefresh,
    this.initialUrl,
    this.userAgent,
  });

  @override
  State<BrowserWidget> createState() => _BrowserWidgetState();
}

class _BrowserWidgetState extends State<BrowserWidget> {
  /// Current pull-down distance (>= 0) while the user overscrolls at the top
  /// of the page. Drives the pull-to-refresh indicator.
  final ValueNotifier<double> _pullDistance = ValueNotifier<double>(0);

  /// True while a refresh triggered by the pull gesture is in flight.
  /// The indicator spins (indeterminate) until the reloaded page finishes
  /// loading ([onLoadStop]).
  final ValueNotifier<bool> _refreshing = ValueNotifier<bool>(false);

  /// Pure overscroll state machine (see [PullToRefreshTracker]).
  final PullToRefreshTracker _tracker = PullToRefreshTracker();

  /// Android WebView reports negative `scrollY` while the user overscrolls
  /// past the top of the page. The tracker accumulates the most-negative value
  /// and, when the scroll springs back to >= 0 (finger released), reports
  /// whether the pull crossed the threshold. Purely observational — no gesture
  /// detector, so normal WebView scrolling is never affected.
  void _handleScrollChanged(int y) {
    if (_tracker.onScroll(y, refreshing: _refreshing.value)) {
      _triggerRefresh();
    }
    _pullDistance.value = _tracker.pullDistance;
  }

  void _triggerRefresh() {
    _refreshing.value = true;
    widget.onRefresh?.call();
  }

  void _handleLoadStop() {
    if (_refreshing.value) {
      _refreshing.value = false;
      _pullDistance.value = 0;
    }
  }

  @override
  void dispose() {
    _pullDistance.dispose();
    _refreshing.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    if (ctrl is SnifferWebViewControllerImpl) {
      final seed = widget.initialUrl?.trim();
      final initialRequest = (seed != null &&
              seed.isNotEmpty &&
              seed != 'about:blank' &&
              !ctrl.cloudflareStealthEnabled)
          ? URLRequest(url: WebUri(seed))
          : null;
      return _GestureWrappedWebView(
        webView: InAppWebView(
          initialUrlRequest: initialRequest,
          initialSettings: InAppWebViewSettings(
            incognito: ctrl.isIncognito,
            javaScriptEnabled: true,
            useShouldOverrideUrlLoading: true,
            useOnLoadResource: false,
            useOnDownloadStart: true,
            useShouldInterceptRequest: true,
            supportMultipleWindows: false,
            userAgent: widget.userAgent,
            applicationNameForUserAgent: '',
            // This WebView renders arbitrary untrusted pages. Neither flag has a
            // use case for a general-purpose browser, and both widen the blast
            // radius of the JS-bridge surface in browser_controller.dart.
            allowFileAccess: false,
            allowContentAccess: false,
            domStorageEnabled: true,
            databaseEnabled: true,
            mediaPlaybackRequiresUserGesture: false,
            transparentBackground: false,
            rendererPriorityPolicy: RendererPriorityPolicy(
              rendererRequestedPriority: RendererPriority.RENDERER_PRIORITY_IMPORTANT,
              waivedWhenNotVisible: true,
            ),
          ),
          onWebViewCreated: (c) => ctrl.onWebViewCreated(c),
          onLoadStart: (c, url) => ctrl.onLoadStart(url),
          onLoadStop: (c, url) {
            ctrl.onLoadStop(url);
            _handleLoadStop();
          },
          onUpdateVisitedHistory: (c, url, isReload) =>
              ctrl.onUpdateVisitedHistory(url, isReload),
          onProgressChanged: (c, progress) => ctrl.onProgressChanged(progress),
          shouldOverrideUrlLoading: (c, action) async =>
              ctrl.shouldOverrideUrlLoadingCallback(action),
          onLoadResource: (c, resource) => ctrl.onLoadResource(resource),
          shouldInterceptRequest: (c, request) =>
              ctrl.shouldInterceptRequestCallback(request),
          onScrollChanged: (c, x, y) {
            ctrl.onScrollChanged(x, y);
            _handleScrollChanged(y);
          },
          onDownloadStartRequest: (c, request) =>
              ctrl.onDownloadStartRequestCallback(request),
          onReceivedError: (c, request, error) =>
              ctrl.onReceivedErrorCallback(request, error),
          onRenderProcessGone: (c, detail) => ctrl.onRenderProcessGone(),
        ),
        onSwipeForward: widget.onSwipeForward,
        onRefresh: widget.onRefresh,
        pullDistance: _pullDistance,
        refreshing: _refreshing,
      );
    } else {
      return _GestureWrappedWebView(
        webView: Container(
          key: const Key('mock_webview_placeholder'),
          color: Colors.grey[200],
          child: const Center(child: Text('Mock WebView Placeholder')),
        ),
        onSwipeForward: widget.onSwipeForward,
        onRefresh: widget.onRefresh,
        pullDistance: _pullDistance,
        refreshing: _refreshing,
      );
    }
  }
}

class _GestureWrappedWebView extends StatefulWidget {
  final Widget webView;
  final VoidCallback? onSwipeForward;
  final VoidCallback? onRefresh;
  final ValueListenable<double> pullDistance;
  final ValueListenable<bool> refreshing;

  const _GestureWrappedWebView({
    required this.webView,
    this.onSwipeForward,
    this.onRefresh,
    required this.pullDistance,
    required this.refreshing,
  });

  @override
  State<_GestureWrappedWebView> createState() => _GestureWrappedWebViewState();
}

class _GestureWrappedWebViewState extends State<_GestureWrappedWebView> {
  // Right-edge zone width. The left edge is intentionally left free so the
  // system back gesture can fire normally (navigating the active WebView back
  // via the PopScope handler). Only the right edge is claimed for forward
  // navigation (swipe left → go forward), matching Samsung Internet's pattern.
  static const double _edgeWidth = 24.0;

  @override
  Widget build(BuildContext context) {
    // Use a Stack with a right-edge overlay whose GestureDetector
    // participates in Flutter's gesture arena and wins, preventing the
    // native WebView from ever seeing touches at the right edge.
    // The left edge is left unclaimed — system back gesture handles back.
    // The pull-to-refresh indicator is visual-only (IgnorePointer) so it can
    // never steal touches from the WebView.
    return Stack(
      children: [
        widget.webView,
        // Pull-to-refresh indicator — top-center, follows the pull, never
        // intercepts touches.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: ListenableBuilder(
              listenable: Listenable.merge(
                [widget.pullDistance, widget.refreshing],
              ),
              builder: (context, _) => _PullToRefreshIndicator(
                pullDistance: widget.pullDistance.value,
                refreshing: widget.refreshing.value,
              ),
            ),
          ),
        ),
        // Right edge zone — swipe left → go forward
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: _edgeWidth,
          child: _ForwardSwipeZone(onSwipe: widget.onSwipeForward),
        ),
      ],
    );
  }
}

/// Top-center circular indicator for the pull-to-refresh gesture.
///
/// While pulling, it fills proportionally to the pull distance and fades in;
/// once the threshold is crossed and the finger released it spins
/// indefinitely until the reloaded page finishes loading.
class _PullToRefreshIndicator extends StatelessWidget {
  final double pullDistance;
  final bool refreshing;

  const _PullToRefreshIndicator({
    required this.pullDistance,
    required this.refreshing,
  });

  @override
  Widget build(BuildContext context) {
    final progress = (pullDistance / kPullToRefreshThreshold).clamp(0.0, 1.0);
    final opacity = refreshing
        ? 1.0
        : (pullDistance / (kPullToRefreshThreshold * 0.5)).clamp(0.0, 1.0);
    final offsetY = refreshing
        ? 20.0
        : math.min(pullDistance * 0.5, kPullToRefreshThreshold * 0.4);

    return Opacity(
      opacity: opacity,
      child: Transform.translate(
        offset: Offset(0, offsetY),
        child: Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              value: refreshing ? null : progress,
              strokeWidth: 3,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Detects a right-edge horizontal swipe-to-left (forward navigation).
///
/// Uses a [GestureDetector] (not [Listener]) so its
/// [HorizontalDragGestureRecognizer] competes in Flutter's gesture arena
/// and wins, preventing the native WebView from receiving the touch at all.
/// This eliminates the race condition that occurs when both Flutter and
/// the native view process the same touch simultaneously.
///
/// Thresholds are tuned to feel natural alongside the system back gesture:
/// 60px minimum travel, 50px max vertical drift, 120 px/s minimum velocity.
class _ForwardSwipeZone extends StatefulWidget {
  final VoidCallback? onSwipe;

  const _ForwardSwipeZone({required this.onSwipe});

  @override
  State<_ForwardSwipeZone> createState() => _ForwardSwipeZoneState();
}

class _ForwardSwipeZoneState extends State<_ForwardSwipeZone> {
  double _netDx = 0;
  double _netDy = 0;
  double _peakAbsDx = 0;

  static const double _minSwipeDistance = 60.0;
  static const double _maxVerticalDrift = 50.0;
  static const double _minVelocity = 120.0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (_) {
        _netDx = 0;
        _netDy = 0;
        _peakAbsDx = 0;
      },
      onHorizontalDragUpdate: (details) {
        _netDx += details.delta.dx;
        _netDy += details.delta.dy;
        final absDx = _netDx.abs();
        if (absDx > _peakAbsDx) {
          _peakAbsDx = absDx;
        }
      },
      onHorizontalDragEnd: (details) {
        // Use peak distance so the gesture is recognized even if the user
        // pauses mid-swipe and lifts their finger partway back.
        if (_peakAbsDx < _minSwipeDistance) return;
        // Reject swipes with excessive vertical drift.
        if (_netDy.abs() > _maxVerticalDrift) return;
        // Right edge → must go left (negative dx) for forward navigation.
        if (_netDx >= 0) return;
        // Velocity check (from the recognizer, not manual calculation).
        final velocity = details.primaryVelocity ?? 0;
        if (velocity.abs() < _minVelocity) return;

        widget.onSwipe?.call();
      },
    );
  }
}

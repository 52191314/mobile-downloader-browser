import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'browser_controller.dart';

class BrowserWidget extends StatelessWidget {
  final SnifferBrowserController controller;
  final VoidCallback? onSwipeBack;
  final VoidCallback? onSwipeForward;
  final VoidCallback? onRefresh;

  const BrowserWidget({
    super.key,
    required this.controller,
    this.onSwipeBack,
    this.onSwipeForward,
    this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final ctrl = controller;
    if (ctrl is SnifferWebViewControllerImpl) {
      return _GestureWrappedWebView(
        webView: InAppWebView(
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            useShouldOverrideUrlLoading: true,
            useOnLoadResource: true,
            useOnDownloadStart: true,
            useShouldInterceptRequest: true,
            supportMultipleWindows: false,
            allowFileAccess: true,
            allowContentAccess: true,
            domStorageEnabled: true,
            databaseEnabled: true,
            mediaPlaybackRequiresUserGesture: false,
            transparentBackground: true,
          ),
          onWebViewCreated: (c) => ctrl.onWebViewCreated(c),
          onLoadStart: (c, url) => ctrl.onLoadStart(url),
          onLoadStop: (c, url) => ctrl.onLoadStop(url),
          onUpdateVisitedHistory: (c, url, isReload) =>
              ctrl.onUpdateVisitedHistory(url, isReload),
          onProgressChanged: (c, progress) => ctrl.onProgressChanged(progress),
          shouldOverrideUrlLoading: (c, action) async =>
              ctrl.shouldOverrideUrlLoadingCallback(action),
          onLoadResource: (c, resource) => ctrl.onLoadResource(resource),
          shouldInterceptRequest: (c, request) =>
              ctrl.shouldInterceptRequestCallback(request),
          onScrollChanged: (c, x, y) => ctrl.onScrollChanged(x, y),
          onDownloadStartRequest: (c, request) =>
              ctrl.onDownloadStartRequestCallback(request),
        ),
        onSwipeBack: onSwipeBack,
        onSwipeForward: onSwipeForward,
        onRefresh: onRefresh,
      );
    } else {
      return _GestureWrappedWebView(
        webView: Container(
          key: const Key('mock_webview_placeholder'),
          color: Colors.grey[200],
          child: const Center(child: Text('Mock WebView Placeholder')),
        ),
        onSwipeBack: onSwipeBack,
        onSwipeForward: onSwipeForward,
        onRefresh: onRefresh,
      );
    }
  }
}

class _GestureWrappedWebView extends StatefulWidget {
  final Widget webView;
  final VoidCallback? onSwipeBack;
  final VoidCallback? onSwipeForward;
  final VoidCallback? onRefresh;

  const _GestureWrappedWebView({
    required this.webView,
    this.onSwipeBack,
    this.onSwipeForward,
    this.onRefresh,
  });

  @override
  State<_GestureWrappedWebView> createState() => _GestureWrappedWebViewState();
}

class _GestureWrappedWebViewState extends State<_GestureWrappedWebView> {
  // Edge zone width — touches starting here are captured by the overlay's
  // GestureDetector, which claims them via the gesture arena so the native
  // WebView never receives them (a translucent Listener wrapping the WebView
  // always lost the arena to the PlatformView).
  static const double _edgeWidth = 44.0;

  @override
  Widget build(BuildContext context) {
    // Use a Stack with opaque edge overlays whose GestureDetector
    // participates in Flutter's gesture arena and wins, preventing the
    // native WebView from ever seeing touches at the screen edges.
    return Stack(
      children: [
        widget.webView,
        // Left edge zone — swipe right → go back
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: _edgeWidth,
          child: _EdgeSwipeZone(
            isLeft: true,
            onSwipe: widget.onSwipeBack,
          ),
        ),
        // Right edge zone — swipe left → go forward
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: _edgeWidth,
          child: _EdgeSwipeZone(
            isLeft: false,
            onSwipe: widget.onSwipeForward,
          ),
        ),
      ],
    );
  }
}

/// Detects horizontal edge-swipes in a single edge zone.
///
/// Each zone uses a [GestureDetector] (not [Listener]) so its
/// [HorizontalDragGestureRecognizer] competes in Flutter's gesture arena
/// and wins, preventing the native WebView from receiving the touch at all.
/// This eliminates the race condition that occurs when both Flutter and
/// the native view process the same touch simultaneously.
///
/// Thresholds are tuned to reject accidental swipes: 60px minimum travel,
/// 50px max vertical drift, 200 px/s minimum velocity.
class _EdgeSwipeZone extends StatefulWidget {
  final bool isLeft;
  final VoidCallback? onSwipe;

  const _EdgeSwipeZone({
    required this.isLeft,
    required this.onSwipe,
  });

  @override
  State<_EdgeSwipeZone> createState() => _EdgeSwipeZoneState();
}

class _EdgeSwipeZoneState extends State<_EdgeSwipeZone> {
  double _netDx = 0;
  double _netDy = 0;
  double _peakAbsDx = 0;

  static const double _minSwipeDistance = 60.0;
  static const double _maxVerticalDrift = 50.0;
  static const double _minVelocity = 200.0;

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
        // Direction check: left edge → must go right, right edge → must go left.
        if (widget.isLeft && _netDx <= 0) return;
        if (!widget.isLeft && _netDx >= 0) return;
        // Velocity check (from the recognizer, not manual calculation).
        final velocity = details.primaryVelocity ?? 0;
        if (velocity.abs() < _minVelocity) return;

        widget.onSwipe?.call();
      },
    );
  }
}

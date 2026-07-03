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
  int? _activePointer;
  Offset? _startPosition;
  Offset? _lastPosition;
  DateTime? _startTime;
  // Track the maximum horizontal distance reached during the swipe so that
  // slow drags (where the user pauses mid-swipe) still register. Without
  // this we would only see the final delta which can collapse to 0 once
  // the user lifts their finger near the start point.
  double _maxHorizontalDelta = 0;

  // Edge-swipe detection constants. The Flutter-side Listener is the sole
  // detector now that the JS-side fallback has been removed (it caused
  // double-navigation on every edge swipe). Thresholds are balanced to
  // reject accidental swipes: require 60px horizontal travel, allow at
  // most 50px vertical drift, and demand 200 px/s minimum velocity.
  static const double _edgeWidth = 44.0;        // keep — edge zone is fine
  static const double _minSwipeDistance = 60.0;  // 36→60: require more horizontal travel
  static const double _maxVerticalDrift = 50.0;  // 160→50: reject swipes with significant vertical movement
  static const double _minVelocity = 200.0;     // 30→200: require a deliberate speed

  @override
  Widget build(BuildContext context) {
    // Use Listener instead of GestureDetector so we don't register any
    // drag gesture recognizer that would compete with the WebView's native
    // vertical scrolling. We only observe raw pointer events to detect
    // horizontal edge swipes for back/forward navigation.
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: widget.webView,
    );
  }

  void _onPointerDown(PointerDownEvent event) {
    _activePointer = event.pointer;
    _startPosition = event.localPosition;
    _lastPosition = event.localPosition;
    _startTime = DateTime.now();
    _maxHorizontalDelta = 0;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_activePointer != event.pointer) return;
    final start = _startPosition;
    if (start == null) return;
    _lastPosition = event.localPosition;
    final delta = (event.localPosition - start).dx.abs();
    if (delta > _maxHorizontalDelta) {
      _maxHorizontalDelta = delta;
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (_activePointer != event.pointer) {
      _reset();
      return;
    }
    _maybeHandleSwipe(event.localPosition);
    _reset();
  }

  void _onPointerCancel(PointerCancelEvent event) {
    // PointerCancel can fire when the WebView claims the gesture (e.g. for a
    // horizontal scroll on a wide table). Still evaluate the swipe based on
    // the last position we saw so a partially-completed edge swipe is not
    // silently dropped.
    _maybeHandleSwipe(_lastPosition ?? _startPosition ?? Offset.zero);
    _reset();
  }

  void _reset() {
    _activePointer = null;
    _startPosition = null;
    _lastPosition = null;
    _startTime = null;
    _maxHorizontalDelta = 0;
  }

  void _maybeHandleSwipe(Offset endPosition) {
    final start = _startPosition;
    final startTime = _startTime;
    if (start == null || startTime == null) return;

    final totalDelta = endPosition - start;
    // Use the maximum horizontal distance observed during the swipe as the
    // primary signal. The final delta can be misleading when the user lifts
    // their finger partway back across the start.
    final horizontalDistance = _maxHorizontalDelta > totalDelta.dx.abs()
        ? _maxHorizontalDelta
        : totalDelta.dx.abs();

    if (horizontalDistance < _minSwipeDistance) return;
    if (totalDelta.dy.abs() > _maxVerticalDrift) return;

    final size = MediaQuery.of(context).size;
    final startedOnLeftEdge = start.dx <= _edgeWidth;
    final startedOnRightEdge = start.dx >= size.width - _edgeWidth;
    if (!startedOnLeftEdge && !startedOnRightEdge) return;

    final elapsedMs = DateTime.now().difference(startTime).inMilliseconds;
    final dt = elapsedMs < 50 ? 50 : elapsedMs;
    final velocity = horizontalDistance / (dt / 1000.0);
    if (velocity < _minVelocity) return;

    if (totalDelta.dx > 0) {
      widget.onSwipeBack?.call();
    } else {
      widget.onSwipeForward?.call();
    }
  }
}

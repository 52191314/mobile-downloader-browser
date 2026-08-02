import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'browser_controller.dart';

class BrowserWidget extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final ctrl = controller;
    if (ctrl is SnifferWebViewControllerImpl) {
      final seed = initialUrl?.trim();
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
            userAgent: userAgent,
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
          onReceivedError: (c, request, error) =>
              ctrl.onReceivedErrorCallback(request, error),
          onRenderProcessGone: (c, detail) => ctrl.onRenderProcessGone(),
        ),
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
        onSwipeForward: onSwipeForward,
        onRefresh: onRefresh,
      );
    }
  }
}

class _GestureWrappedWebView extends StatefulWidget {
  final Widget webView;
  final VoidCallback? onSwipeForward;
  final VoidCallback? onRefresh;

  const _GestureWrappedWebView({
    required this.webView,
    this.onSwipeForward,
    this.onRefresh,
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
    return Stack(
      children: [
        widget.webView,
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

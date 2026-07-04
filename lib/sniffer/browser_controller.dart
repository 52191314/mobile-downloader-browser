import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../downloader/hls_models.dart';
import '../settings/download_settings.dart';
import 'ad_block_engine_native.dart';
import 'adblock_injector.dart';
import 'browser_guard_installer.dart';
import 'webview_fetch_delegate.dart';

abstract interface class SnifferBrowserController {
  Future<void> loadRequest(
    Uri uri, {
    Map<String, String>? headers,
    bool addToHistory = true,
  });
  Future<void> loadFile(String path);
  Future<String?> currentUrl();
  Future<String?> pageTitle();
  Future<Object?> evaluateJavaScript(String source);
  Future<bool> canGoBack();
  Future<void> goBack();
  Future<bool> canGoForward();
  Future<void> goForward();
  Future<void> reload();
  List<String> get historyUrls;
  int get historyIndex;
  void restoreHistory(List<String> urls, int index);
  void setOnUrlChanged(void Function(String url) callback);
  void setOnPageStarted(void Function(String url) callback);
  void setOnPageFinished(void Function(String url) callback);
  void setOnScrollPositionChange(void Function(double x, double y) callback);
  void addJavaScriptChannel(
    String name, {
    required void Function(String message) onMessageReceived,
  });
  Future<void> setUserAgent(String userAgent);
  Future<void> setZoomScale(double scale);
  Future<double?> getZoomScale();
  Future<void> freeze();
  Future<void> thaw();

  /// Pauses JavaScript timers, layout, and rendering on ALL browser
  /// WebViews (global).  Called when leaving the Browser main tab so
  /// the Dart event loop is freed for download HTTP stream processing.
  /// Also hides the DOM on the active tab.
  Future<void> pauseAllWebViews();

  /// Resumes JavaScript timers, layout, and rendering (global).
  /// Called when re-entering the Browser main tab.  Also restores
  /// DOM visibility on the active tab.
  Future<void> resumeActiveWebView();
  Future<int> fillForm(Map<String, String> values);
  Future<void> findAllAsync(String search);
  Future<void> findNext(bool forward);
  Future<void> clearMatches();
  Future<void> clearCookies();
  Future<void> clearSiteData(String url);

  // Adblocker features
  bool get adBlockerEnabled;
  set adBlockerEnabled(bool enabled);
  bool get popupBlockingEnabled;
  int get blockedPopupsCount;
  void incrementBlockedPopups();
  int get blockedRequestCount;
  List<String> get adblockAllowlist;
  void updateAdblockAllowlist(List<String> allowlist);
  bool shouldBlockUrl(
    String url, {
    String sourceHost = '',
    String requestType = '',
    bool isThirdParty = false,
  });
  bool shouldSuppressSniffedUrl(String url);
  Future<void> configureAdBlock({
    required bool enabled,
    bool popupBlockingEnabled = true,
    List<AdblockFilterSource> filterSources = const [],
    List<ManualAdBlockRule> manualRules = const [],
    List<CosmeticAdRule> cosmeticRules = const [],
  });
  Future<WebResourceResponse?> shouldInterceptRequestCallback(
    WebResourceRequest request,
  );
  Map<String, String> get currentHeaders;
  HlsPlaylist? get lastMasterPlaylist;
  void setOnIframeMediaDetected(void Function(String url) callback);
  void setOnDownloadStartRequest(
      void Function(String url, String? suggestedFilename) callback);
  Future<String?> fetchFreshPlaylistUrl(String url);
  Future<String?> fetchViaJavaScript(String url, {Map<String, String>? headers});
  /// Fetches response headers for [url] through the WebView's networking
  /// stack using an async XHR HEAD request. Returns a map of lowercased
  /// header names to values, including at minimum 'statusCode'. Returns
  /// null on failure (timeout, network error, or non-2xx status).
  /// The 'content-length' key is reliably populated for CORS-safelisted
  /// responses (Content-Length is always exposed cross-origin).
  Future<Map<String, String>?> fetchHeadersViaJavaScript(String url);
  /// Fetches the full response body for [url] through the WebView's JS
  /// networking stack using a GET request. Returns the response text or
  /// null on failure. Used to fetch HLS playlist bodies that the browser
  /// cached but the Dart HTTP client cannot reach (Cloudflare WAF).
  Future<String?> fetchPlaylistBodyViaJavaScript(String url);
  /// Fetches binary data (e.g. .ts segments) through the WebView's
  /// networking stack. Uses XHR with responseType='arraybuffer' and
  /// returns the body as List<int>. Returns null on failure.
  Future<List<int>?> fetchBinaryViaJavaScript(String url);
  /// Returns cookies for the given [url]. If [url] is null or empty, falls
  /// back to the current page URL.
  Future<Map<String, String>> getCookiesForDomain({String? url});
  void requestOpenUrl(String url);
  void setOnOpenUrlRequest(void Function(String url)? callback);
  void dispose();
}

String _adBlockConfigSignature({
  required bool enabled,
  required bool popupBlockingEnabled,
  required List<AdblockFilterSource> filterSources,
  required List<ManualAdBlockRule> manualRules,
  required List<CosmeticAdRule> cosmeticRules,
}) {
  final buffer = StringBuffer()
    ..write(enabled)
    ..write('|')
    ..write(popupBlockingEnabled);
  for (final source in filterSources) {
    buffer
      ..write('|source:')
      ..write(source.name)
      ..write(',')
      ..write(source.url)
      ..write(',')
      ..write(source.enabled);
  }
  for (final rule in manualRules) {
    buffer
      ..write('|manual:')
      ..write(rule.pattern)
      ..write(',')
      ..write(rule.domainRule);
  }
  for (final rule in cosmeticRules) {
    buffer
      ..write('|cosmetic:')
      ..write(rule.host)
      ..write(',')
      ..write(rule.selector);
  }
  return buffer.toString();
}

class SnifferWebViewControllerImpl implements SnifferBrowserController {
  InAppWebViewController? _controller;
  final Completer<void> _ready = Completer<void>();

  void Function(String)? _onUrlChanged;
  void Function(String)? _onPageStarted;
  void Function(String)? _onPageFinished;
  void Function(double x, double y)? _onScrollPositionChange;
  void Function(String)? _onIframeMediaDetected;
  void Function(String url, String? suggestedFilename)? _onDownloadStartRequest;

  final Map<String, void Function(String)> _jsChannels = {};

  bool _adBlockerEnabled = true;
  bool _popupBlockingEnabled = true;
  AdBlockEngine _adBlockEngine = AdBlockEngine.builtIn();
  int _blockedRequestCount = 0;
  /// Per-site allowlist of hostnames. When the current page host matches an
  /// entry in this list, adblock is bypassed for both subresource requests
  /// and main-frame navigations.
  List<String> _adblockAllowlist = const [];
  String? _lastAdBlockConfigSignature;
  Future<void>? _adBlockConfigFuture;
  int _adBlockConfigGeneration = 0;
  int _blockedPopupsCount = 0;
  Map<String, String> _currentHeaders = {};
  String? _currentUrl;
  HlsPlaylist? _lastMasterPlaylist;
  bool _webViewCreated = false;
  Timer? _loadResourceTimer;
  final Set<String> _pendingResourceUrls = {};

  // Custom history stack that survives app restarts. The native WebView
  // history is only valid for the current session.
  final List<String> _history = [];
  int _historyIndex = -1;

  /// When true, [shouldOverrideUrlLoadingCallback] skips the adblock check so
  /// that back/forward navigation is never blocked by a rule change or
  /// heuristic difference between the original visit and the revisit.
  bool _isHistoryNavigation = false;

  // WebView-side WAF-bypass fetch methods (fetch* + getCookiesForDomain).
  late final WebViewFetchDelegate _fetchDelegate = WebViewFetchDelegate(
    controller: _controller,
    getCurrentUrl: () => _currentUrl,
  );

  // JS guard installer + 20s refresh timer.
  late final BrowserGuardInstaller _guardInstaller =
      BrowserGuardInstaller(controller: _controller);

  // Cosmetic filter + scriptlet injector.
  final AdblockInjector _adblockInjector = AdblockInjector(
    controller: null,
    engine: AdBlockEngine.builtIn(),
  );

  static final RegExp _mediaUrlRegExp = RegExp(
    // .ts is excluded â€” HLS segments are not discoverable media; the
    // playlist (.m3u8) is what the downloader needs.
    r'\.(mp4|m3u8|webm|mkv|avi|flv|mov|mp3|wav|aac|ogg|m4a|flac|mpd|f4m|smil)(\?.*)?$',
    caseSensitive: false,
  );

  /// Called by BrowserWidget when InAppWebView creates its controller.
  void onWebViewCreated(InAppWebViewController controller) {
    _controller = controller;
    _webViewCreated = true;
    _fetchDelegate.setController(controller);
    _guardInstaller.setController(controller);
    // Register the guard as a user script that runs AT_DOCUMENT_START,
    // before any page JavaScript.  This is the primary fix for the
    // sniffing race where the page's HLS player fetches the playlist
    // before `evaluateJavascript` can install the fetch/XHR hooks.
    unawaited(_guardInstaller.installAsUserScript());
    _adblockInjector.setController(controller);
    // Register the cosmetic + scriptlet scripts as user scripts that
    // run AT_DOCUMENT_START, before any page JavaScript executes.
    unawaited(_adblockInjector.installAsUserScript());
    _registerPendingChannels();
    unawaited(_syncPopupBlockingFlag());
    if (!_ready.isCompleted) _ready.complete();
  }

  @override
  void setOnIframeMediaDetected(void Function(String url) callback) {
    _onIframeMediaDetected = callback;
  }

  @override
  void setOnDownloadStartRequest(
      void Function(String url, String? suggestedFilename) callback) {
    _onDownloadStartRequest = callback;
  }

  @override
  HlsPlaylist? get lastMasterPlaylist => _lastMasterPlaylist;

  @override
  Map<String, String> get currentHeaders => _currentHeaders;

  Future<void> installBrowserGuards() => _guardInstaller.installBrowserGuards();

  @override
  bool get adBlockerEnabled => _adBlockerEnabled;

  @override
  bool get popupBlockingEnabled => _popupBlockingEnabled;

  @override
  int get blockedRequestCount => _blockedRequestCount;

  @override
  set adBlockerEnabled(bool enabled) {
    _adBlockerEnabled = enabled;
    _adBlockEngine = AdBlockEngine(
      enabled: enabled,
      rules: _adBlockEngine.rules,
      cosmeticRules: _adBlockEngine.cosmeticRules,
      sourceStatuses: _adBlockEngine.sourceStatuses,
    );
  }

  @override
  int get blockedPopupsCount => _blockedPopupsCount;

  @override
  void incrementBlockedPopups() {
    _blockedPopupsCount++;
  }

  @override
  List<String> get adblockAllowlist => _adblockAllowlist;

  @override
  void updateAdblockAllowlist(List<String> allowlist) {
    _adblockAllowlist = List<String>.unmodifiable(allowlist);
  }

  @override
  bool shouldBlockUrl(
    String url, {
    String sourceHost = '',
    String requestType = '',
    bool isThirdParty = false,
  }) {
    return _adBlockEngine.shouldBlockUrl(
      url,
      sourceHost: sourceHost,
      requestType: requestType,
      isThirdParty: isThirdParty,
    );
  }

  @override
  bool shouldSuppressSniffedUrl(String url) {
    if (url.trim().isEmpty) return false;
    final pageUri = Uri.tryParse(_currentUrl ?? '');
    final requestUri = Uri.tryParse(url);
    final sourceHost = pageUri?.host ?? '';
    bool isThirdParty = false;
    if (pageUri != null &&
        requestUri != null &&
        requestUri.hasScheme &&
        pageUri.hasScheme) {
      isThirdParty = pageUri.host != requestUri.host;
    }
    return shouldBlockUrl(
      url,
      sourceHost: sourceHost,
      requestType: 'other',
      isThirdParty: isThirdParty,
    );
  }

  @override
  Future<void> configureAdBlock({
    required bool enabled,
    bool popupBlockingEnabled = true,
    List<AdblockFilterSource> filterSources = const [],
    List<ManualAdBlockRule> manualRules = const [],
    List<CosmeticAdRule> cosmeticRules = const [],
  }) async {
    final signature = _adBlockConfigSignature(
      enabled: enabled,
      popupBlockingEnabled: popupBlockingEnabled,
      filterSources: filterSources,
      manualRules: manualRules,
      cosmeticRules: cosmeticRules,
    );
    _adBlockerEnabled = enabled;
    _popupBlockingEnabled = popupBlockingEnabled;

    if (_lastAdBlockConfigSignature == signature) {
      final pending = _adBlockConfigFuture;
      if (pending != null) {
        return pending;
      }
      await _syncPopupBlockingFlag();
      return;
    }

    final generation = ++_adBlockConfigGeneration;
    _lastAdBlockConfigSignature = signature;
    late final Future<void> configureFuture;
    configureFuture = () async {
      final engine = await AdBlockEngine.fromFilterSources(
        enabled: enabled,
        sources: filterSources,
        manualRules: manualRules,
        manualCosmeticRules: cosmeticRules,
      );
      if (generation != _adBlockConfigGeneration) return;
      _adBlockEngine = engine;
      _adblockInjector.setEngine(engine);
      await _syncPopupBlockingFlag();
    }();
    late final Future<void> pendingFuture;
    pendingFuture = configureFuture.whenComplete(() {
      if (identical(_adBlockConfigFuture, pendingFuture)) {
        _adBlockConfigFuture = null;
      }
    });
    _adBlockConfigFuture = pendingFuture;
    return pendingFuture;
  }

  Future<void> _syncPopupBlockingFlag() async {
    if (_webViewCreated) {
      await _controller
          ?.evaluateJavascript(
            source:
                'window.__auroraPopupBlockingEnabled = '
                '${_popupBlockingEnabled ? 'true' : 'false'};',
          )
          .catchError((_) {});
    }
  }

  @override
  Future<WebResourceResponse?> shouldInterceptRequestCallback(
    WebResourceRequest request,
  ) async {
    if (!_adBlockerEnabled) return null;

    // Skip main frame — already handled by shouldOverrideUrlLoading
    if (request.isForMainFrame == true) return null;

    // Per-site allowlist: skip adblock for the current page's host
    final pageHost = Uri.tryParse(_currentUrl ?? '')?.host ?? '';
    if (pageHost.isNotEmpty && _adblockAllowlist.contains(pageHost)) {
      return null;
    }

    final url = request.url.toString();
    if (url.isEmpty) return null;

    // Skip data: and blob: URLs
    final lower = url.toLowerCase();
    if (lower.startsWith('data:') || lower.startsWith('blob:')) return null;

    // Skip non-http(s) schemes
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) return null;

    final requestUri = Uri.tryParse(url);
    final pageUri = Uri.tryParse(_currentUrl ?? '');
    if (requestUri == null) return null;

    final sourceHost = pageUri?.host ?? '';
    bool isThirdParty = false;
    if (pageUri != null && requestUri.host != pageUri.host) {
      isThirdParty = true;
    }

    // Infer request type from URL extension and headers
    final requestType = _inferRequestType(url, request.method ?? 'GET');

    if (shouldBlockUrl(
      url,
      sourceHost: sourceHost,
      requestType: requestType,
      isThirdParty: isThirdParty,
    )) {
      _blockedRequestCount++;
      // Return an empty 204 No Content response to block the request
      return WebResourceResponse(
        contentType: 'text/plain',
        statusCode: 204,
        data: Uint8List(0),
        reasonPhrase: 'No Content',
      );
    }

    return null; // allow
  }

  String _inferRequestType(String url, String method) {
    final ext = url.toLowerCase();
    if (ext.endsWith('.js')) return 'script';
    if (ext.endsWith('.css')) return 'stylesheet';
    if (ext.endsWith('.png') || ext.endsWith('.jpg') || ext.endsWith('.jpeg') ||
        ext.endsWith('.gif') || ext.endsWith('.webp') || ext.endsWith('.svg') ||
        ext.endsWith('.ico') || ext.endsWith('.bmp')) return 'image';
    if (ext.endsWith('.html') || ext.endsWith('.htm')) return 'subdocument';
    if (ext.endsWith('.xml')) return 'xmlhttprequest';
    if (ext.endsWith('.json')) return 'xmlhttprequest';
    return 'other';
  }

  // --- Widget callback methods (called by BrowserWidget) ---

  /// Called by InAppWebView onLoadStart
  void onLoadStart(WebUri? url) {
    final urlStr = url?.toString() ?? '';
    if (urlStr.isNotEmpty) {
      _currentUrl = urlStr;
    }
    unawaited(_adblockInjector.injectForPage(urlStr));
    _guardInstaller.installBrowserGuards();
    _onPageStarted?.call(urlStr);
    _onUrlChanged?.call(urlStr);
  }

  /// Called by InAppWebView onLoadStop
  void onLoadStop(WebUri? url) {
    final urlStr = url?.toString() ?? '';
    if (urlStr.isNotEmpty) {
      _currentUrl = urlStr;
    }
    _guardInstaller.installBrowserGuards(force: true);
    _onPageFinished?.call(urlStr);
  }

  /// Called by InAppWebView onUpdateVisitedHistory
  void onUpdateVisitedHistory(WebUri? url, bool? isReload) {
    _guardInstaller.installBrowserGuards(force: true);
    if (url != null) {
      final urlStr = url.toString();
      _currentUrl = urlStr;
      // Track real navigations in our persistent history stack. Reloads don't
      // push a new entry.
      if (isReload != true &&
          (_history.isEmpty || _history[_historyIndex] != urlStr)) {
        _recordHistoryNavigation(urlStr);
      }
      _onUrlChanged?.call(urlStr);
    }
  }

  /// Called by InAppWebView onProgressChanged
  void onProgressChanged(int progress) {
    // Guards already installed via onLoadStart/onLoadStop
  }

  /// Called by InAppWebView shouldOverrideUrlLoading
  Future<NavigationActionPolicy> shouldOverrideUrlLoadingCallback(
    NavigationAction action,
  ) async {
    final url = action.request.url?.toString() ?? '';
    final pageUri = Uri.tryParse(_currentUrl ?? '');
    final requestUri = Uri.tryParse(url);
    final sourceHost = pageUri?.host ?? '';
    final requestType = action.isForMainFrame ? 'document' : 'subdocument';
    bool isThirdParty = false;
    if (pageUri != null &&
        requestUri != null &&
        requestUri.hasScheme &&
        pageUri.hasScheme) {
      isThirdParty = pageUri.host != requestUri.host;
    }
    // Per-site allowlist: skip adblock for the current page's host
    final pageHost = Uri.tryParse(_currentUrl ?? '')?.host ?? '';
    final allowlisted = pageHost.isNotEmpty && _adblockAllowlist.contains(pageHost);

    // Skip adblock for history navigation (back/forward) so that URLs
    // that were successfully visited before are never blocked on revisit.
    // The `_history.contains(url)` fallback catches the race where
    // `_isHistoryNavigation` has already been reset by the time
    // this native callback fires.
    final isHistoryNav =
        _isHistoryNavigation || _history.contains(url);
    if (!allowlisted &&
        !isHistoryNav &&
        shouldBlockUrl(
          url,
          sourceHost: sourceHost,
          requestType: requestType,
          isThirdParty: isThirdParty,
        )) {
      return NavigationActionPolicy.CANCEL;
    }
    if (_mediaUrlRegExp.hasMatch(url)) {
      _onIframeMediaDetected?.call(url);
    }
    return NavigationActionPolicy.ALLOW;
  }

  /// Called by InAppWebView onDownloadStartRequest when the WebView detects
  /// a file download (e.g. <a download>, Content-Disposition: attachment).
  /// Routes the download URL to the sniffer so it appears in the FAB drawer.
  void onDownloadStartRequestCallback(DownloadStartRequest request) {
    final url = request.url.toString();
    if (url.isNotEmpty && _onDownloadStartRequest != null) {
      _onDownloadStartRequest!(url, request.suggestedFilename);
    }
  }

  /// Called by InAppWebView onLoadResource â€” this is the KEY callback for Beeg24.
  /// It fires for ALL subresource loads including cross-origin iframes.
  /// Note: LoadedResource only exposes url + initiatorType (no MIME/headers),
  /// so we classify by URL extension and initiator type.
  void onLoadResource(LoadedResource? resource) {
    if (resource == null) return;
    final url = resource.url?.toString() ?? '';
    if (url.isEmpty) return;
    final initiator = resource.initiatorType ?? '';

    // SKIP: segment files (HLS .ts fragments, DASH .m4s fragments)
    final lowUrl = url.toLowerCase();
    if (lowUrl.endsWith('.ts') ||
        lowUrl.endsWith('.m4s') ||
        lowUrl.endsWith('.mp4a') ||
        lowUrl.endsWith('.m4v') ||
        lowUrl.contains('/seg') ||
        lowUrl.contains('/chunk/') ||
        lowUrl.contains('/fragment/')) {
      return;
    }

    bool matches = false;

    // Extension-based match: only playlist + direct media extensions
    if (lowUrl.contains('.m3u8') ||
        lowUrl.contains('.mpd') ||
        lowUrl.contains('.smil') ||
        lowUrl.contains('.f4m')) {
      matches = true; // Playlists
    } else if (_mediaUrlRegExp.hasMatch(url)) {
      matches = true; // Direct media (.mp4, .webm, .mp3, etc.)
    }

    // Path-hint-based match: catch disguised playlists where the URL path
    // strongly suggests an HLS/DASH stream even with a non-standard extension
    // (e.g. .../hls/.../index.jpg served as #EXTM3U). Applies to all
    // initiator types including fetch, xmlhttprequest, and media.
    if (!matches) {
      if (lowUrl.contains('/hls/') ||
          lowUrl.contains('/master') ||
          lowUrl.contains('/playlist') ||
          lowUrl.contains('/manifest') ||
          lowUrl.contains('/dash/')) {
        matches = true;
      }
    }
    // NOTE: fetch/xhr initiators WITHOUT extensions are NOT matched.
    // This filters out 99% of the junk (ad trackers, analytics, JSON configs).

    if (!matches) return;

    // Throttle: batch matching URLs and flush at MOST every 2000ms,
    // with a hard cap of 20 URLs per flush to prevent platform channel saturation.
    _pendingResourceUrls.add(url);
    _loadResourceTimer ??= Timer.periodic(const Duration(milliseconds: 2000), (
      _,
    ) {
      if (_pendingResourceUrls.isEmpty) {
        _loadResourceTimer?.cancel();
        _loadResourceTimer = null;
        return;
      }
      final urls = _pendingResourceUrls.take(20).toList();
      _pendingResourceUrls.removeAll(urls);
      if (_pendingResourceUrls.isEmpty) {
        _loadResourceTimer?.cancel();
        _loadResourceTimer = null;
      }
      for (final u in urls) {
        _onIframeMediaDetected?.call(u);
      }
    });
  }

  /// Called by InAppWebView onScrollChanged
  void onScrollChanged(int x, int y) {
    _onScrollPositionChange?.call(x.toDouble(), y.toDouble());
  }

  // --- Abstract interface implementations ---

  @override
  Future<void> loadRequest(
    Uri uri, {
    Map<String, String>? headers,
    bool addToHistory = true,
  }) async {
    _currentHeaders = headers ?? const {};
    final urlStr = uri.toString();
    _currentUrl = urlStr;
    if (addToHistory) {
      _recordHistoryNavigation(urlStr);
    }
    // Fire callbacks immediately so the SnifferScreen UI updates even when
    // the WebView's onLoadStart/onUpdateVisitedHistory are delayed or
    // suppressed (e.g. same-page hash navigation, platform-view timing).
    _onPageStarted?.call(urlStr);
    _onUrlChanged?.call(urlStr);
    await _ready.future;
    await _controller?.loadUrl(
      urlRequest: URLRequest(url: WebUri.uri(uri), headers: headers),
    );
  }

  void _recordHistoryNavigation(String urlStr) {
    if (_historyIndex < _history.length - 1) {
      _history.removeRange(_historyIndex + 1, _history.length);
    }
    _history.add(urlStr);
    _historyIndex = _history.length - 1;
  }

  @override
  List<String> get historyUrls => List.unmodifiable(_history);

  @override
  int get historyIndex => _historyIndex;

  @override
  void restoreHistory(List<String> urls, int index) {
    _history
      ..clear()
      ..addAll(urls);
    _historyIndex = index.clamp(-1, _history.length - 1);
    _currentUrl = _historyIndex >= 0 ? _history[_historyIndex] : null;
  }

  @override
  Future<void> loadFile(String path) async {
    _currentUrl = 'file://$path';
    await _ready.future;
    await _controller?.loadFile(assetFilePath: path);
  }

  @override
  Future<String?> currentUrl() async {
    await _ready.future;
    final url = await _controller?.getUrl();
    _currentUrl = url?.toString() ?? _currentUrl;
    return _currentUrl;
  }

  @override
  Future<String?> pageTitle() async {
    await _ready.future;
    return await _controller?.getTitle();
  }

  @override
  Future<Object?> evaluateJavaScript(String source) async {
    await _ready.future;
    return await _controller?.evaluateJavascript(source: source);
  }

  @override
  Future<bool> canGoBack() async => _historyIndex > 0;

  @override
  Future<void> goBack() async {
    if (_historyIndex > 0) {
      _isHistoryNavigation = true;
      _historyIndex--;
      final url = _history[_historyIndex];
      await loadRequest(Uri.parse(url), addToHistory: false);
      _isHistoryNavigation = false;
    }
  }

  @override
  Future<bool> canGoForward() async => _historyIndex < _history.length - 1;

  @override
  Future<void> goForward() async {
    if (_historyIndex < _history.length - 1) {
      _isHistoryNavigation = true;
      _historyIndex++;
      final url = _history[_historyIndex];
      await loadRequest(Uri.parse(url), addToHistory: false);
      _isHistoryNavigation = false;
    }
  }

  @override
  Future<void> reload() async {
    await _ready.future;
    // Clear WebView cache so reload fetches a fresh token/playlist instead
    // of reusing a cached, expired one.
    await InAppWebViewController.clearAllCache();
    await _controller?.reload();
  }

  @override
  void setOnUrlChanged(void Function(String url) callback) {
    _onUrlChanged = callback;
  }

  @override
  void setOnPageStarted(void Function(String url) callback) {
    _onPageStarted = callback;
  }

  @override
  void setOnPageFinished(void Function(String url) callback) {
    _onPageFinished = callback;
  }

  @override
  void setOnScrollPositionChange(void Function(double x, double y) callback) {
    _onScrollPositionChange = callback;
  }

  @override
  void addJavaScriptChannel(
    String name, {
    required void Function(String message) onMessageReceived,
  }) {
    _jsChannels[name] = onMessageReceived;
    if (_controller != null) {
      _registerChannel(name, onMessageReceived);
    }
  }

  void _registerChannel(String name, void Function(String message) callback) {
    _controller?.addJavaScriptHandler(
      handlerName: name,
      callback: (args) {
        if (args.isNotEmpty) {
          callback(args[0].toString());
        }
      },
    );
  }

  void _registerPendingChannels() {
    for (final entry in _jsChannels.entries) {
      _registerChannel(entry.key, entry.value);
    }
  }

  @override
  Future<void> setUserAgent(String userAgent) async {
    await _ready.future;
    await _controller?.setSettings(
      settings: InAppWebViewSettings(userAgent: userAgent),
    );
  }

  @override
  Future<void> setZoomScale(double scale) async {
    await _ready.future;
    await _controller?.setSettings(
      settings: InAppWebViewSettings(
        builtInZoomControls: true,
        supportZoom: true,
      ),
    );
    await _controller?.evaluateJavascript(
      source:
          'document.body.style.zoom = ${scale.toStringAsFixed(3)}; '
          'document.documentElement.style.zoom = ${scale.toStringAsFixed(3)};',
    );
  }

  @override
  Future<double?> getZoomScale() async {
    await _ready.future;
    final result = await _controller?.evaluateJavascript(
      source: 'document.body.style.zoom || "1"',
    );
    if (result is String) {
      final trimmed = result.replaceAll('"', '').trim();
      return double.tryParse(trimmed);
    }
    if (result is num) return result.toDouble();
    return null;
  }

  @override
  Future<void> freeze() async {
    try {
      await _controller?.evaluateJavascript(
        source:
            'try{window.__auroraFrozenAt=Date.now();document.documentElement.style.visibility="hidden";}catch(e){}',
      );
    } catch (_) {}
  }

  @override
  Future<void> thaw() async {
    try {
      await _controller?.evaluateJavascript(
        source:
            'try{document.documentElement.style.visibility="";delete window.__auroraFrozenAt;}catch(e){}',
      );
    } catch (_) {}
  }

  @override
  Future<void> pauseAllWebViews() async {
    // InAppWebViewController.pauseTimers() pauses JS timers, layout, and
    // parsing for ALL WebViews in the process.  This frees the Dart event
    // loop from WebView activity so download HTTP streams are processed
    // without starvation.
    try {
      await _controller?.pauseTimers();
    } catch (_) {}
    // Also hide the DOM on the current tab as a best-effort signal.
    await freeze();
  }

  @override
  Future<void> resumeActiveWebView() async {
    try {
      await _controller?.resumeTimers();
    } catch (_) {}
    await thaw();
  }

  @override
  Future<int> fillForm(Map<String, String> values) async {
    if (values.isEmpty) return 0;
    final json = jsonEncode(values);
    try {
      final result = await _controller?.evaluateJavascript(
        source:
            '(function(){var data=$json;var aliases={fullName:["name","fullname","full_name","your-name","customer-name","cardholder"],email:["email","e-mail","your-email","username"],phone:["phone","tel","telephone","mobile","phone-number"],addressLine1:["address","address1","address-1","street","street-address","addr1","billing-address"],addressLine2:["address2","address-2","apt","suite","unit","addr2"],city:["city","locality","town"],state:["state","region","province","county"],postalCode:["zip","zipcode","postal","postal-code","postcode"],country:["country","country-name"],cardName:["cc-name","cardholder-name","name-on-card"],cardNumber:["cc-number","cardnumber","credit-card","card-number","cc-num"],cardExpiry:["cc-exp","expiry","exp-date","card-expiry","cc-exp-date"]};function set(el,v){if(!el)return false;var proto=Object.getPrototypeOf(el);var setter=Object.getOwnPropertyDescriptor(proto,"value")&&Object.getOwnPropertyDescriptor(proto,"value").set;if(setter){setter.call(el,v);}else{el.value=v;}el.dispatchEvent(new Event("input",{bubbles:true}));el.dispatchEvent(new Event("change",{bubbles:true}));return true;}function findField(aliases){for(var i=0;i<aliases.length;i++){var sel="[name="+JSON.stringify(aliases[i])+"]";var el=document.querySelector(sel);if(el)return el;sel="[id="+JSON.stringify(aliases[i])+"]";el=document.querySelector(sel);if(el)return el;sel="[autocomplete="+JSON.stringify(aliases[i])+"]";el=document.querySelector(sel);if(el)return el;var ph=document.querySelector("input[placeholder*="+JSON.stringify(aliases[i].replace(/-/g," "))+" i]");if(ph)return ph;}return null;}var filled=0;for(var key in data){var v=data[key];if(!v)continue;var list=aliases[key]||[key];var el=findField(list);if(el&&set(el,v))filled++;}return filled;})()',
      );
      if (result is int) return result;
      if (result is num) return result.toInt();
      return 0;
    } catch (_) {
      return 0;
    }
  }

  @override
  Future<void> findAllAsync(String search) async {
    final c = _controller;
    if (c == null) return;
    await c
        .evaluateJavascript(
          source:
              'window.__auroraFindMatchCount = 0;'
              'window.__auroraFindCurrentIdx = 0;'
              'if(window.getSelection) window.getSelection().removeAllRanges();',
        )
        .catchError((_) {});
    await c
        .evaluateJavascript(
          source:
              "window.find('${_jsEscape(search)}',false,false,true,false,true,false);"
              'window.__auroraFindMatchCount = 1;',
        )
        .catchError((_) {});
    await c
        .evaluateJavascript(
          source:
              'var c=0;while(window.find("${_jsEscape(search)}",false,false,true,false,true,false))c++;'
              'window.__auroraFindMatchCount=c||1;'
              'window.getSelection().removeAllRanges();',
        )
        .catchError((_) {});
    await c
        .evaluateJavascript(
          source:
              "window.find('${_jsEscape(search)}',false,false,true,false,true,false);",
        )
        .catchError((_) {});
  }

  @override
  Future<void> findNext(bool forward) async {
    await _controller
        ?.evaluateJavascript(
          source:
              "window.find(' ',false,!$forward,true,false,true,false);"
              'window.find(window.getSelection().toString(),false,'
              '!$forward,true,false,true,false);',
        )
        .catchError((_) {});
  }

  @override
  Future<void> clearMatches() async {
    await _controller
        ?.evaluateJavascript(
          source:
              'if(window.getSelection) window.getSelection().removeAllRanges();'
              'window.__auroraFindMatchCount = 0;'
              'window.__auroraFindCurrentIdx = 0;',
        )
        .catchError((_) {});
  }

  String _jsEscape(String s) {
    return s
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "\\'")
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '');
  }

  @override
  Future<void> clearCookies() async {
    await InAppWebViewController.clearAllCache();
  }

  @override
  Future<void> clearSiteData(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await CookieManager.instance().deleteCookies(url: WebUri.uri(uri));
    } catch (_) {}
    try {
      await _controller?.evaluateJavascript(
        source: 'try{localStorage.clear();sessionStorage.clear();}catch(e){}',
      );
    } catch (_) {}
    try {
      await InAppWebViewController.clearAllCache();
    } catch (_) {}
  }

  @override
  Future<String?> fetchFreshPlaylistUrl(String url) =>
      _fetchDelegate.fetchFreshPlaylistUrl(url);

  @override
  Future<String?> fetchViaJavaScript(String url, {Map<String, String>? headers}) =>
      _fetchDelegate.fetchViaJavaScript(url, headers: headers);

  @override
  Future<Map<String, String>?> fetchHeadersViaJavaScript(String url) =>
      _fetchDelegate.fetchHeadersViaJavaScript(url);

  @override
  Future<String?> fetchPlaylistBodyViaJavaScript(String url) =>
      _fetchDelegate.fetchPlaylistBodyViaJavaScript(url);

  @override
  Future<List<int>?> fetchBinaryViaJavaScript(String url) =>
      _fetchDelegate.fetchBinaryViaJavaScript(url);

  @override
  Future<Map<String, String>> getCookiesForDomain({String? url}) =>
      _fetchDelegate.getCookiesForDomain(url: url);

  void Function(String)? _onOpenUrlRequest;

  @override
  void requestOpenUrl(String url) => _onOpenUrlRequest?.call(url);

  @override
  void setOnOpenUrlRequest(void Function(String url)? callback) =>
      _onOpenUrlRequest = callback;

  @override
  void dispose() {
    _guardInstaller.dispose();
    _adblockInjector.dispose();
    _loadResourceTimer?.cancel();
    _controller?.dispose();
    _controller = null;
  }
}

class MockBrowserController implements SnifferBrowserController {
  String? _currentUrl;
  String? _title;
  final List<String> _history = [];
  int _historyIndex = -1;

  void Function(String)? _onUrlChanged;
  void Function(String)? _onPageStarted;
  void Function(String)? _onPageFinished;

  final Map<String, void Function(String)> _jsChannels = {};

  bool _adBlockerEnabled = true;
  bool _popupBlockingEnabled = true;
  AdBlockEngine _adBlockEngine = AdBlockEngine.builtIn();
  int _blockedPopupsCount = 0;
  Map<String, String> _currentHeaders = {};
  HlsPlaylist? _lastMasterPlaylist;

  void Function(String)? _onOpenUrlRequest;

  @override
  void requestOpenUrl(String url) => _onOpenUrlRequest?.call(url);

  @override
  void setOnOpenUrlRequest(void Function(String url)? callback) =>
      _onOpenUrlRequest = callback;

  @override
  void dispose() {}
  @override
  void setOnIframeMediaDetected(void Function(String url) callback) {}
  @override
  void setOnDownloadStartRequest(
      void Function(String url, String? suggestedFilename) callback) {}
  @override
  HlsPlaylist? get lastMasterPlaylist => _lastMasterPlaylist;

  @override
  Map<String, String> get currentHeaders => _currentHeaders;

  @override
  bool get adBlockerEnabled => _adBlockerEnabled;

  @override
  bool get popupBlockingEnabled => _popupBlockingEnabled;

  @override
  set adBlockerEnabled(bool enabled) {
    _adBlockerEnabled = enabled;
    _adBlockEngine = AdBlockEngine(
      enabled: enabled,
      rules: _adBlockEngine.rules,
      cosmeticRules: _adBlockEngine.cosmeticRules,
      sourceStatuses: _adBlockEngine.sourceStatuses,
    );
  }

  @override
  int get blockedPopupsCount => _blockedPopupsCount;

  @override
  void incrementBlockedPopups() {
    _blockedPopupsCount++;
  }

  @override
  int get blockedRequestCount => 0;

  @override
  List<String> get adblockAllowlist => const [];

  @override
  void updateAdblockAllowlist(List<String> allowlist) {}

  @override
  Future<WebResourceResponse?> shouldInterceptRequestCallback(
    WebResourceRequest request,
  ) async => null;

  @override
  bool shouldBlockUrl(
    String url, {
    String sourceHost = '',
    String requestType = '',
    bool isThirdParty = false,
  }) {
    return _adBlockEngine.shouldBlockUrl(
      url,
      sourceHost: sourceHost,
      requestType: requestType,
      isThirdParty: isThirdParty,
    );
  }

  @override
  bool shouldSuppressSniffedUrl(String url) {
    if (url.trim().isEmpty) return false;
    final pageUri = Uri.tryParse(_currentUrl ?? '');
    final requestUri = Uri.tryParse(url);
    final sourceHost = pageUri?.host ?? '';
    bool isThirdParty = false;
    if (pageUri != null &&
        requestUri != null &&
        requestUri.hasScheme &&
        pageUri.hasScheme) {
      isThirdParty = pageUri.host != requestUri.host;
    }
    return shouldBlockUrl(
      url,
      sourceHost: sourceHost,
      requestType: 'other',
      isThirdParty: isThirdParty,
    );
  }

  @override
  Future<void> configureAdBlock({
    required bool enabled,
    bool popupBlockingEnabled = true,
    List<AdblockFilterSource> filterSources = const [],
    List<ManualAdBlockRule> manualRules = const [],
    List<CosmeticAdRule> cosmeticRules = const [],
  }) async {
    _adBlockerEnabled = enabled;
    _popupBlockingEnabled = popupBlockingEnabled;
    final builtIn = AdBlockEngine.builtIn(enabled: enabled);
    _adBlockEngine = AdBlockEngine(
      enabled: enabled,
      rules: [
        ...builtIn.rules,
        for (final rule in manualRules)
          AdBlockRule(
            type: rule.domainRule
                ? AdBlockRuleType.domain
                : AdBlockRuleType.contains,
            pattern: rule.pattern,
          ),
      ],
      cosmeticRules: [...builtIn.cosmeticRules, ...cosmeticRules],
    );
  }

  MockBrowserController({String? initialUrl}) {
    if (initialUrl != null) {
      _history.add(initialUrl);
      _historyIndex = 0;
      _currentUrl = initialUrl;
      _title = Uri.tryParse(initialUrl)?.host;
    }
  }

  @override
  Future<void> loadRequest(
    Uri uri, {
    Map<String, String>? headers,
    bool addToHistory = true,
  }) async {
    _currentHeaders = headers ?? const {};
    final urlStr = uri.toString();
    if (shouldBlockUrl(urlStr)) {
      return;
    }

    _onPageStarted?.call(urlStr);

    if (addToHistory) {
      if (_historyIndex < _history.length - 1) {
        _history.removeRange(_historyIndex + 1, _history.length);
      }
      _history.add(urlStr);
      _historyIndex = _history.length - 1;
    }
    _currentUrl = urlStr;
    _title = uri.host;
    _onUrlChanged?.call(urlStr);
    _onPageFinished?.call(urlStr);
  }

  @override
  List<String> get historyUrls => List.unmodifiable(_history);

  @override
  int get historyIndex => _historyIndex;

  @override
  void restoreHistory(List<String> urls, int index) {
    _history
      ..clear()
      ..addAll(urls);
    _historyIndex = index.clamp(-1, _history.length - 1);
    if (_historyIndex >= 0) {
      _currentUrl = _history[_historyIndex];
    }
  }

  @override
  Future<void> loadFile(String path) async {
    _currentUrl = 'file://$path';
    _onPageStarted?.call(_currentUrl!);
    _onPageFinished?.call(_currentUrl!);
  }

  @override
  Future<String?> currentUrl() async => _currentUrl;

  @override
  Future<String?> pageTitle() async => _title;

  @override
  Future<Object?> evaluateJavaScript(String source) async {
    if (source.contains('document.cookie')) return '""';
    if (source.contains('currentSrc') || source.contains('src')) return '""';
    return null;
  }

  @override
  Future<bool> canGoBack() async => _historyIndex > 0;

  @override
  Future<void> goBack() async {
    if (_historyIndex > 0) {
      _historyIndex--;
      _currentUrl = _history[_historyIndex];
      _onUrlChanged?.call(_currentUrl!);
    }
  }

  @override
  Future<bool> canGoForward() async => _historyIndex < _history.length - 1;

  @override
  Future<void> goForward() async {
    if (_historyIndex < _history.length - 1) {
      _historyIndex++;
      _currentUrl = _history[_historyIndex];
      _onUrlChanged?.call(_currentUrl!);
    }
  }

  @override
  Future<void> reload() async {
    if (_currentUrl != null) {
      _onPageStarted?.call(_currentUrl!);
      _onPageFinished?.call(_currentUrl!);
    }
  }

  @override
  void setOnUrlChanged(void Function(String url) callback) {
    _onUrlChanged = callback;
  }

  @override
  void setOnPageStarted(void Function(String url) callback) {
    _onPageStarted = callback;
  }

  @override
  void setOnPageFinished(void Function(String url) callback) {
    _onPageFinished = callback;
  }

  @override
  void setOnScrollPositionChange(void Function(double x, double y) callback) {}

  @override
  void addJavaScriptChannel(
    String name, {
    required void Function(String message) onMessageReceived,
  }) {
    _jsChannels[name] = onMessageReceived;
  }

  void simulateJavaScriptMessage(String channelName, String message) {
    _jsChannels[channelName]?.call(message);
  }

  @override
  Future<void> setUserAgent(String userAgent) async {}

  @override
  Future<void> setZoomScale(double scale) async {}

  @override
  Future<double?> getZoomScale() async => null;

  @override
  Future<void> freeze() async {}

  @override
  Future<void> thaw() async {}

  @override
  Future<void> pauseAllWebViews() async {}

  @override
  Future<void> resumeActiveWebView() async {}

  @override
  Future<int> fillForm(Map<String, String> values) async => 0;

  @override
  Future<void> findAllAsync(String search) async {}

  @override
  Future<void> findNext(bool forward) async {}

  @override
  Future<void> clearMatches() async {}

  @override
  Future<void> clearCookies() async {}

  @override
  Future<void> clearSiteData(String url) async {}

  @override
  Future<String?> fetchFreshPlaylistUrl(String url) async => url;

  @override
  Future<String?> fetchViaJavaScript(String url, {Map<String, String>? headers}) async => null;

  @override
  Future<Map<String, String>?> fetchHeadersViaJavaScript(String url) async => null;

  @override
  Future<String?> fetchPlaylistBodyViaJavaScript(String url) async => null;

  @override
  Future<List<int>?> fetchBinaryViaJavaScript(String url) async => null;

  @override
  Future<Map<String, String>> getCookiesForDomain({String? url}) async => {};
}

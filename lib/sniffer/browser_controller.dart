import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../compliance/restricted_media_policy.dart';
import '../downloader/hls_models.dart';
import '../settings/download_settings.dart';
import 'ad_block_engine_native.dart';
import 'adblock_injector.dart';
import 'browser_guard_installer.dart';
import 'stealth_injector.dart';
import 'stealth_metadata_channel.dart';
import 'external_scheme.dart';
import 'sniffer_url_utils.dart';
import 'webview_fetch_delegate.dart';
import 'worker_isolate_pool.dart';

class StrictRedirectEvent {
  final String url;
  final String sourceUrl;
  final String method;
  final bool userInitiated;
  final bool isRedirect;

  const StrictRedirectEvent({
    required this.url,
    this.sourceUrl = '',
    this.method = 'navigation',
    this.userInitiated = false,
    this.isRedirect = false,
  });
}

abstract interface class SnifferBrowserController {
  Future<void> loadRequest(
    Uri uri, {
    Map<String, String>? headers,
    bool addToHistory = true,
    bool skipExternalPrompt = false,
  });
  Future<void> loadFile(String path);
  /// Re-runs the per-page cosmetic-rule injection on the current document so a
  /// newly added rule (e.g. element picker) applies without a reload.
  Future<void> reapplyCosmeticRules(String pageUrl);
  Future<String?> currentUrl();
  Future<String?> pageTitle();
  Future<Object?> evaluateJavaScript(String source);
  Future<bool> canGoBack();
  Future<void> goBack();
  Future<bool> canGoForward();
  Future<void> goForward();
  Future<void> reload();
  Future<void> stop();
  void setOnProgressChanged(void Function(int progress)? callback);
  List<String> get historyUrls;
  int get historyIndex;
  void restoreHistory(List<String> urls, int index);
  void setOnUrlChanged(void Function(String url) callback);
  void setOnPageStarted(void Function(String url) callback);
  void setOnPageFinished(void Function(String url) callback);
  void setOnScrollPositionChange(void Function(double x, double y) callback);
  void setOnRecreated(void Function() callback);
  void addJavaScriptChannel(
    String name, {
    required void Function(String message) onMessageReceived,
  });
  Future<void> setUserAgent(String userAgent);
  Future<void> setZoomScale(double scale);
  Future<double?> getZoomScale();
  Future<void> freeze();
  Future<void> thaw();

  /// Process-global: pauses JS timers / layout for **all** WebViews.
  /// Use only when the app is backgrounded or the Browser shell is hidden.
  /// Never call this when switching between browser tabs while browsing.
  Future<void> pauseAllWebViews();

  /// Process-global: resumes JS timers for all WebViews, plus a health check
  /// on this controller's instance when it has a live WebView.
  Future<void> resumeActiveWebView();

  /// Per-WebView render pause (Android `onPause`). Does **not** call
  /// process-global [pauseAllWebViews]/pauseTimers — that would freeze the
  /// active tab if used on a background tab after resume.
  Future<void> pauseWebView();

  /// Resume this WebView's render pipeline and ensure process timers run.
  /// Always ends with resumeTimers so a prior global pause cannot stick.
  /// When [checkAlive] is true (default), probes the renderer and reloads
  /// if it was killed by Android (common under memory pressure with many
  /// background tabs).
  Future<void> resumeWebView({bool checkAlive = true});

  /// Suspend this WebView's rendering pipeline (Android-only, per-WebView).
  /// Unlike a global timer pause, this does NOT call pauseTimers()
  /// which would affect ALL WebViews in the process.
  Future<void> suspendTab();

  /// Resume a previously suspended WebView (Android-only, per-WebView).
  Future<void> resumeTab();
  void onRenderProcessGone();
  Future<int> fillForm(Map<String, String> values);
  Future<int> findAllAsync(String search);
  Future<void> findNext(bool forward, String query);
  Future<void> clearMatches();
  /// Captures the current document's outerHTML in bounded chunks so a large
  /// DOM never crosses the platform channel as one giant message (which froze
  /// the tab). Returns null when the page is unreadable or too large.
  Future<String?> capturePageHtml({
    int chunkSize = 200000,
    int maxBytes = 30 * 1024 * 1024,
  });
  Future<void> clearCookies();
  Future<void> clearSiteData(String url);

  // Adblocker features
  bool get adBlockerEnabled;
  set adBlockerEnabled(bool enabled);
  bool get popupBlockingEnabled;
  bool get invisibleRedirectBlockingEnabled;
  int get blockedPopupsCount;
  void incrementBlockedPopups();
  int get blockedInvisibleRedirectsCount;
  void incrementBlockedInvisibleRedirects();
  Future<void> setInvisibleRedirectBlocking(bool enabled);

  /// Replaces the per-source-site redirect blocklist
  /// (`sourceHost → [targetHost, …]`). Redirects matching an entry are
  /// cancelled silently without prompting (see [setInvisibleRedirectBlocking]).
  void setAlwaysBlockedRedirectHosts(Map<String, List<String>> hosts);

  /// When true, injected JS intercepts site media `play()` and routes
  /// playback to Aurora's in-app player instead.
  Future<void> setReplaceSitePlayer(bool enabled);

  /// Enable or disable Cloudflare Stealth Mode (overrides Sec-CH-UA, UA, and navigator.userAgentData).
  bool get cloudflareStealthEnabled;
  Future<void> setCloudflareStealthEnabled(bool enabled);
  void setOnCloudflareBlockDetected(void Function(String host, bool retrying)? callback);

  /// Enable or disable WebView incognito (private browsing) mode.
  /// When on, cookies/cache/history for this WebView are not persisted.
  Future<void> setIncognito(bool incognito);

  /// Whether incognito (private browsing) mode is active.
  bool get isIncognito;

  /// Briefly block main-frame cross-origin navigations after play intercept
  /// so ad-on-play redirects cannot steal the tab.
  void armPlayNavigationSuppress([Duration duration]);

  /// Allow the next cross-origin main-frame load (address bar / user confirmed
  /// redirect dialog) without re-prompting the invisible-redirect blocker.
  Future<void> allowNextCrossOriginNavigation([String? url]);

  int get blockedRequestCount;
  List<String> get adblockAllowlist;
  void updateAdblockAllowlist(List<String> allowlist);
  void updateCustomVideoHosts(List<String> hosts);
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
    void Function(String url, String? suggestedFilename) callback,
  );
  Future<String?> fetchFreshPlaylistUrl(String url);
  Future<String?> fetchViaJavaScript(
    String url, {
    Map<String, String>? headers,
  });

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

  /// Open [url] in a new browser tab directly, bypassing the
  /// [requestOpenUrl] / [setOnOpenUrlRequest] indirection.
  void openUrlInNewTab(String url);

  /// Registers a callback for [openUrlInNewTab]. Passing `null` clears it.
  void setOnOpenUrlInNewTab(void Function(String url)? callback);

  /// Opens several URLs as new tabs placed right after the currently active
  /// tab, without switching to them (used by backup import to restore a
  /// browser session live instead of waiting for the next restart).
  void openUrlsInNewTabs(List<String> urls);

  /// Registers a callback for [openUrlsInNewTabs]. Passing `null` clears it.
  void setOnOpenUrlsInNewTabs(void Function(List<String> urls)? callback);

  /// Registers a callback for the active-tab system-back handler.
  /// [SnifferScreen] sets this to a closure that navigates the active
  /// tab's WebView back. Returns `true` if the back was handled
  /// (the WebView could go back), `false` otherwise.
  void setOnSystemBackRequested(Future<bool> Function()? callback);

  /// Called by [AuroraHome] when the system back gesture is detected on
  /// the Browser tab. Delegates to the callback registered via
  /// [setOnSystemBackRequested].
  Future<bool> handleSystemBack();

  /// Registers a callback for synchronous nav-state updates.
  /// Fired whenever [historyIndex] changes, so the UI can update
  /// [canGoBack]/[canGoForward] flags without an async round-trip
  /// to the WebView.
  void setOnNavStateChanged(VoidCallback? callback);

  /// Registers a callback for strict cross-origin redirect prompts. The
  /// controller cancels the attempted main-frame redirect first, then reports
  /// it here so the browser UI can ask what to do with it.
  void setOnStrictRedirectDetected(
    void Function(StrictRedirectEvent event)? callback,
  );

  /// Full page re-scan: resets the DOM-scan flag and re-injects the guard
  /// script so that `<video>`, `<audio>`, `<a>` and other media elements
  /// are re-scanned, and fetch/XHR/src hooks are re-wrapped.
  /// Called from the manual "Re-scan" button.
  Future<void> rescanPage();

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

bool _isHttpLike(Uri uri) => uri.scheme == 'http' || uri.scheme == 'https';

bool _sameOrigin(Uri a, Uri b) =>
    a.scheme == b.scheme && a.host == b.host && a.port == b.port;

class SnifferWebViewControllerImpl implements SnifferBrowserController {
  InAppWebViewController? _controller;
  final Completer<void> _ready = Completer<void>();
  bool _isDisposed = false;

  void Function(String)? _onUrlChanged;
  void Function(String)? _onPageStarted;
  void Function(String)? _onPageFinished;
  void Function(double x, double y)? _onScrollPositionChange;
  void Function(String)? _onIframeMediaDetected;
  void Function(String url, String? suggestedFilename)? _onDownloadStartRequest;
  void Function()? _onRecreated;
  Future<bool> Function()? _onSystemBackRequested;
  void Function()? _onNavStateChanged;
  void Function(int)? _onProgressChanged;
  void Function(StrictRedirectEvent event)? _onStrictRedirectDetected;
  String? _pendingOpenUrl;
  /// Queued external "open in new tab" URLs when SnifferScreen has not
  /// registered [setOnOpenUrlInNewTab] yet (e.g. first visit to Browser).
  final List<String> _pendingOpenInNewTabUrls = [];

  final Map<String, void Function(String)> _jsChannels = {};

  bool _adBlockerEnabled = true;
  bool _popupBlockingEnabled = true;
  bool _invisibleRedirectBlockingEnabled = true;
  // Shared default until [configureAdBlock] installs a full filter engine.
  // Avoids N× native loadRules when restoring many tabs at cold start.
  AdBlockEngine _adBlockEngine = AdBlockEngine.sharedBuiltIn();
  int _blockedRequestCount = 0;
  int _blockedInvisibleRedirectsCount = 0;
  Map<String, List<String>> _alwaysBlockedRedirectHosts = const {};

  /// Per-site allowlist of hostnames. When the current page host matches an
  /// entry in this list, adblock is bypassed for both subresource requests
  /// and main-frame navigations.
  List<String> _adblockAllowlist = const [];
  Set<String> _adblockAllowlistSet = const {};
  Set<String> _customVideoHostsSet = const {};
  String? _lastAdBlockConfigSignature;
  Future<void>? _adBlockConfigFuture;
  int _adBlockConfigGeneration = 0;
  int _blockedPopupsCount = 0;
  Map<String, String> _currentHeaders = {};
  String? _currentUrl;
  Uri? _currentUri;
  String _currentHost = '';
  HlsPlaylist? _lastMasterPlaylist;

  bool _webViewCreated = false;
  Timer? _loadResourceTimer;
  final Set<String> _pendingResourceUrls = {};
  static const int _maxPendingResourceUrls = 80;

  // G1: Extensionless URL probe budget — reset on each new page navigation.
  int _extensionlessProbeCount = 0;
  final Set<String> _extensionlessNegativeCache = {};

  /// Debounces the force-reinstall of browser guards so that
  /// [onLoadStop] and [onUpdateVisitedHistory] (which fire back-to-back
  /// on initial page loads) only trigger a single 40 KB
  /// [evaluateJavascript] call instead of two.
  Timer? _guardReinstallDebounce;

  // Custom history stack that survives app restarts. The native WebView
  // history is only valid for the current session.
  final List<String> _history = [];
  int _historyIndex = -1;

  /// When true, [shouldOverrideUrlLoadingCallback] skips the adblock check so
  /// that back/forward navigation is never blocked by a rule change or
  /// heuristic difference between the original visit and the revisit.
  bool _isHistoryNavigation = false;

  /// Trusted cross-origin load (address bar / "Current tab" confirmation).
  String? _trustedCrossOriginNavUrl;
  DateTime? _trustedCrossOriginNavUntil;

  /// Until this time, main-frame cross-origin navigations are cancelled even
  /// when the user gesture is present. Armed when replace-site-player
  /// intercepts `play()` so ad-on-play redirects cannot steal the tab.
  DateTime? _suppressCrossOriginNavUntil;

  // WebView-side WAF-bypass fetch methods (fetch* + getCookiesForDomain).
  late final WebViewFetchDelegate _fetchDelegate = WebViewFetchDelegate(
    controller: _controller,
    getCurrentUrl: () => _currentUrl,
  );

  // JS guard installer + 20s refresh timer.
  late final BrowserGuardInstaller _guardInstaller = BrowserGuardInstaller(
    controller: _controller,
  );

  late final StealthInjector _stealthInjector = StealthInjector(
    controller: _controller,
  );

  // Cosmetic filter + scriptlet injector (shared default engine — see above).
  final AdblockInjector _adblockInjector = AdblockInjector(
    controller: null,
    engine: AdBlockEngine.sharedBuiltIn(),
  );

  void _setCurrentUrl(String? url, {bool clearOnNull = false}) {
    if (url == null || url.isEmpty) {
      if (clearOnNull) {
        _currentUrl = null;
        _currentUri = null;
        _currentHost = '';
      }
      return;
    }
    _currentUrl = url;
    final uri = Uri.tryParse(url);
    _currentUri = uri;
    _currentHost = uri?.host ?? '';
  }

  static final RegExp _mediaUrlRegExp = RegExp(
    // .ts is excluded — HLS segments are not discoverable media; the
    // playlist (.m3u8) is what the downloader needs.
    r'\.(mp4|m3u8|webm|mkv|avi|flv|mov|mp3|wav|aac|ogg|m4a|flac|mpd|f4m|smil)(\?.*)?$',
    caseSensitive: false,
  );

  bool _cloudflareStealthEnabled = true;
  void Function(String host, bool retrying)? _onCloudflareBlockDetected;
  final Set<String> _cfBlockRetriedHosts = {};

  @override
  bool get cloudflareStealthEnabled => _cloudflareStealthEnabled;

  @override
  void setOnCloudflareBlockDetected(
    void Function(String host, bool retrying)? callback,
  ) {
    _onCloudflareBlockDetected = callback;
  }

  @override
  Future<void> setCloudflareStealthEnabled(bool enabled) async {
    _cloudflareStealthEnabled = enabled;
    if (enabled) {
      await _stealthInjector.installAsUserScript(enabled: true);
      await _applyStealthClientHints();
    } else {
      await _stealthInjector.removeUserScript();
    }
  }

  /// Called by BrowserWidget when InAppWebView creates its controller.
  void onWebViewCreated(InAppWebViewController controller) {
    final isRecreation = _webViewCreated;
    _controller = controller;
    _webViewCreated = true;
    _fetchDelegate.setController(controller);
    _guardInstaller.setController(controller);
    _stealthInjector.setController(controller);
    _adblockInjector.setController(controller);

    unawaited(_guardInstaller.installAsUserScript());
    unawaited(_adblockInjector.installAsUserScript());
    _registerPendingChannels();
    unawaited(_syncPopupBlockingFlag());

    // Apply stealth BEFORE completing _ready so deferred loadRequest calls wait.
    unawaited(() async {
      if (_cloudflareStealthEnabled) {
        await _stealthInjector.installAsUserScript(enabled: true);
        int attempts = 0;
        while (attempts < 10) {
          final count = await _applyStealthClientHints();
          if (count != 0) break; // >0 patched, -1 unsupported
          await Future.delayed(const Duration(milliseconds: 50));
          attempts++;
        }
      }
      if (!_ready.isCompleted) _ready.complete();
    }());

    if (isRecreation) {
      _onRecreated?.call();
    }
  }

  /// Calls the native platform channel to override the WebView's Sec-CH-UA
  /// Client Hints metadata, replacing "Android WebView" with "Google Chrome".
  Future<int> _applyStealthClientHints() async {
    final fullVersion = StealthMetadataChannel.extractFullChromeVersion(
          systemUserAgent,
        ) ??
        StealthMetadataChannel.extractChromeVersion(systemUserAgent) ??
        '131.0.6778.135';
    return await StealthMetadataChannel.applyStealthMetadata(
      chromeVersion: fullVersion,
    );
  }

  @override
  void setOnIframeMediaDetected(void Function(String url) callback) {
    _onIframeMediaDetected = callback;
  }

  @override
  void setOnDownloadStartRequest(
    void Function(String url, String? suggestedFilename) callback,
  ) {
    _onDownloadStartRequest = callback;
  }

  @override
  HlsPlaylist? get lastMasterPlaylist => _lastMasterPlaylist;

  @override
  Map<String, String> get currentHeaders => _currentHeaders;

  Future<void> installBrowserGuards() => _guardInstaller.installBrowserGuards();

  @override
  Future<void> rescanPage() => _guardInstaller.rescanPage();

  @override
  bool get adBlockerEnabled => _adBlockerEnabled;

  @override
  bool get popupBlockingEnabled => _popupBlockingEnabled;

  @override
  bool get invisibleRedirectBlockingEnabled =>
      _invisibleRedirectBlockingEnabled;

  @override
  int get blockedRequestCount => _blockedRequestCount;

  @override
  int get blockedInvisibleRedirectsCount => _blockedInvisibleRedirectsCount;

  @override
  void incrementBlockedInvisibleRedirects() {
    _blockedInvisibleRedirectsCount++;
  }

  @override
  Future<void> setInvisibleRedirectBlocking(bool enabled) async {
    _invisibleRedirectBlockingEnabled = enabled;
    if (_webViewCreated) {
      await _controller
          ?.evaluateJavascript(
            source:
                'window.__auroraInvisibleRedirectBlockingEnabled = '
                '${enabled ? 'true' : 'false'};',
          )
          .catchError((_) {});
    }
  }

  @override
  void setAlwaysBlockedRedirectHosts(Map<String, List<String>> hosts) {
    // Normalise to lowercase so lookups in shouldOverrideUrlLoadingCallback
    // are case-insensitive.
    _alwaysBlockedRedirectHosts = {
      for (final e in hosts.entries)
        e.key.toLowerCase(): e.value.map((h) => h.toLowerCase()).toList(),
    };
  }

  @override
  Future<void> setReplaceSitePlayer(bool enabled) async {
    if (_webViewCreated) {
      await _controller
          ?.evaluateJavascript(
            source:
                'window.__auroraReplaceSitePlayer = '
                '${enabled ? 'true' : 'false'};',
          )
          .catchError((_) {});
    }
  }

  bool _isIncognito = false;

  @override
  bool get isIncognito => _isIncognito;

  /// Sets incognito (private browsing) mode on the WebView.
  /// When enabled, the WebView doesn't persist cookies, cache, or history.
  @override
  Future<void> setIncognito(bool incognito) async {
    _isIncognito = incognito;
    await _ready.future;
    await _controller?.setSettings(
      settings: InAppWebViewSettings(incognito: incognito),
    );
  }

  /// Block main-frame cross-origin navigations for a short window after
  /// Aurora intercepts site `play()` (ad-on-play pattern).
  @override
  void armPlayNavigationSuppress([
    Duration duration = const Duration(milliseconds: 3500),
  ]) {
    _suppressCrossOriginNavUntil = DateTime.now().add(duration);
    // Mirror into JS so location/window.open hooks also suppress.
    if (_webViewCreated) {
      unawaited(
        _controller
            ?.evaluateJavascript(
              source:
                  'window.__auroraSuppressAdNavUntil = Date.now() + '
                  '${duration.inMilliseconds};',
            )
            .catchError((_) {}),
      );
    }
  }

  @override
  Future<void> allowNextCrossOriginNavigation([String? url]) async {
    // Empty/null → short wildcard window so address-bar loads can follow
    // HTTP redirect chains without re-prompting on each hop.
    final token = (url == null || url.isEmpty) ? '*' : url;
    _trustedCrossOriginNavUrl = token;
    _trustedCrossOriginNavUntil =
        DateTime.now().add(const Duration(seconds: 12));
    if (!_webViewCreated) return;
    final encoded = jsonEncode(token);
    await _controller
        ?.evaluateJavascript(
          source:
              'window.__auroraAllowNextCrossOriginNav='
              '{url:$encoded,until:Date.now()+12000};',
        )
        .catchError((_) {});
  }

  /// Whether [url] is inside the intentional-nav trust window (address bar or
  /// user-confirmed redirect). Not single-shot: redirect chains must pass.
  bool _isTrustedCrossOriginNav(String url) {
    final until = _trustedCrossOriginNavUntil;
    if (until == null) return false;
    if (DateTime.now().isAfter(until)) {
      _trustedCrossOriginNavUrl = null;
      _trustedCrossOriginNavUntil = null;
      return false;
    }
    final trusted = _trustedCrossOriginNavUrl;
    if (trusted == null) return false;
    if (trusted == '*') return true;
    if (url == trusted ||
        url.startsWith(trusted) ||
        trusted.startsWith(url)) {
      return true;
    }
    // Same host as the confirmed URL (path/query hop after allow).
    try {
      final t = Uri.parse(trusted);
      final u = Uri.parse(url);
      if (t.hasScheme &&
          u.hasScheme &&
          t.host.isNotEmpty &&
          t.host.toLowerCase() == u.host.toLowerCase()) {
        return true;
      }
    } catch (_) {}
    return false;
  }

  bool get _isPlayNavSuppressActive {
    final until = _suppressCrossOriginNavUntil;
    if (until == null) return false;
    if (DateTime.now().isAfter(until)) {
      _suppressCrossOriginNavUntil = null;
      return false;
    }
    return true;
  }

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
    _adblockAllowlistSet = allowlist.toSet();
  }

  @override
  void updateCustomVideoHosts(List<String> hosts) {
    _customVideoHostsSet = hosts.map((h) => h.trim().toLowerCase()).toSet();
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
    final pageUri = _currentUri;
    final requestUri = Uri.tryParse(url);
    final sourceHost = _currentHost;
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

    final pageUri = _currentUri;
    final pageHost = _currentHost;

    // Per-site allowlist: skip adblock for the current page's host
    if (pageHost.isNotEmpty && _adblockAllowlistSet.contains(pageHost)) {
      return null;
    }

    final requestUri = request.url;
    final reqHost = requestUri.host.toLowerCase();
    // Never block Cloudflare Turnstile / Challenge assets or scripts
    if (reqHost == 'challenges.cloudflare.com' ||
        reqHost.endsWith('.challenges.cloudflare.com') ||
        requestUri.path.contains('/cdn-cgi/challenge-platform/')) {
      return null;
    }

    if (pageUri != null && requestUri.host == pageUri.host) {
      return null;
    }

    // Skip non-http(s) schemes
    final scheme = requestUri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return null;

    final url = requestUri.toString();
    if (url.isEmpty) return null;

    final sourceHost = pageHost;
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

    // Media detection deliberately NOT here — it is handled exclusively
    // in [onLoadResource] to avoid duplicating the same regex/classification
    // work on every subresource.  Keeping it in one place halves the hot-path
    // work on the WebView→Dart bridge.

    return null; // allow
  }

  /// G1: Probes an extensionless URL with a HEAD request to check for a
  /// video/audio content-type. Caches negative results per page to avoid
  /// re-probing the same URL. Budgeted to max 5 probes per page load.
  Future<void> _probeExtensionlessUrl(String url) async {
    if (_extensionlessNegativeCache.contains(url)) return;
    try {
      final result = await WorkerIsolatePool.instance.execute('probe', {
        'method': 'HEAD',
        'url': url,
        'headers': <String, String>{
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
        },
        'timeoutSeconds': 3,
        'onlySuccess': true,
      });
      if (result is Map) {
        final ct = (result['contentType'] as String? ?? '').toLowerCase();
        if (ct.contains('video/') ||
            ct.contains('audio/') ||
            ct.contains('mpegurl') ||
            ct.contains('dash+xml')) {
          _onIframeMediaDetected?.call(url);
          return;
        }
      }
    } catch (_) {}
    // Cache negative result so we don't re-probe the same URL on this page.
    _extensionlessNegativeCache.add(url);
  }

  String _inferRequestType(String url, String method) {
    var path = url;
    final qIdx = url.indexOf('?');
    if (qIdx != -1) {
      path = url.substring(0, qIdx);
    }
    final hashIdx = path.indexOf('#');
    if (hashIdx != -1) {
      path = path.substring(0, hashIdx);
    }
    final ext = path.toLowerCase();
    if (ext.endsWith('.js')) return 'script';
    if (ext.endsWith('.css')) return 'stylesheet';
    if (ext.endsWith('.png') ||
        ext.endsWith('.jpg') ||
        ext.endsWith('.jpeg') ||
        ext.endsWith('.gif') ||
        ext.endsWith('.webp') ||
        ext.endsWith('.svg') ||
        ext.endsWith('.ico') ||
        ext.endsWith('.bmp')) {
      return 'image';
    }
    if (ext.endsWith('.html') || ext.endsWith('.htm')) return 'subdocument';
    if (ext.endsWith('.xml') || ext.endsWith('.json')) return 'xmlhttprequest';
    return 'other';
  }

  // --- Widget callback methods (called by BrowserWidget) ---

  /// Called by InAppWebView onLoadStart
  void onLoadStart(WebUri? url) {
    final urlStr = url?.toString() ?? '';
    _pendingResourceUrls.clear();
    _loadResourceTimer?.cancel();
    _loadResourceTimer = null;
    // Reset G1 extensionless probe budget on page navigation.
    _extensionlessProbeCount = 0;
    _extensionlessNegativeCache.clear();
    if (urlStr.isNotEmpty) {
      _setCurrentUrl(urlStr);
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
      _setCurrentUrl(urlStr);
    }
    _scheduleGuardReinstall();
    unawaited(_checkCloudflareBlockPage(urlStr));
    _onPageFinished?.call(urlStr);
  }

  Future<void> _checkCloudflareBlockPage(String urlStr) async {
    if (!_cloudflareStealthEnabled || _controller == null || _isDisposed) return;
    final host = _currentHost;
    if (host.isEmpty) return;

    try {
      final res = await _controller?.evaluateJavascript(source: '''
        (function() {
          var title = document.title || '';
          var body = (document.body && document.body.innerText) ? document.body.innerText : '';
          var isBlocked = title.indexOf('Blocked') !== -1 ||
                          body.indexOf('Sorry, you have been blocked') !== -1 ||
                          body.indexOf('Cloudflare Ray ID') !== -1;
          return isBlocked;
        })();
      ''');
      if (res == true) {
        if (_cfBlockRetriedHosts.contains(host)) {
          _onCloudflareBlockDetected?.call(host, false);
        } else {
          final patchCount = await _applyStealthClientHints();
          if (patchCount > 0 || patchCount == -1) {
            _cfBlockRetriedHosts.add(host);
            _onCloudflareBlockDetected?.call(host, true);
            await _stealthInjector.installAsUserScript(enabled: true);
            await clearSiteData(urlStr);
            await reload();
          } else {
            _onCloudflareBlockDetected?.call(host, false);
          }
        }
      } else {
        _cfBlockRetriedHosts.remove(host);
      }
    } catch (_) {}
  }

  /// Called by InAppWebView onUpdateVisitedHistory
  void onUpdateVisitedHistory(WebUri? url, bool? isReload) {
    _scheduleGuardReinstall();
    if (url != null) {
      final urlStr = url.toString();
      // For same-host navigations (SPA pushState), clear stale headers so
      // the next media capture reads fresh auth/cookie headers for the
      // current route instead of the original page's headers.
      final newUri = Uri.tryParse(urlStr);
      if (newUri != null && _currentUri != null &&
          newUri.host.toLowerCase() == _currentUri!.host.toLowerCase()) {
        _currentHeaders = {};
      }
      _setCurrentUrl(urlStr);
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
    _onProgressChanged?.call(progress);
  }

  /// Debounces force-reinstall of browser guards so that back-to-back
  /// callbacks ([onLoadStop] + [onUpdateVisitedHistory]) on initial page
  /// loads only trigger a single 40 KB [evaluateJavascript] call.
  /// SPA navigations (where only [onUpdateVisitedHistory] fires) are
  /// unaffected — the debounce window is short enough that the single
  /// callback still triggers the reinstall.
  void _scheduleGuardReinstall() {
    _guardReinstallDebounce?.cancel();
    _guardReinstallDebounce = Timer(const Duration(milliseconds: 300), () {
      unawaited(() async {
        await _guardInstaller.installBrowserGuards(force: true);
        // Re-sync flags after force re-wrap (page/SPA can reset window vars).
        await _syncPopupBlockingFlag();
        await setInvisibleRedirectBlocking(_invisibleRedirectBlockingEnabled);
      }());
    });
  }

  /// Called by InAppWebView shouldOverrideUrlLoading
  Future<NavigationActionPolicy> shouldOverrideUrlLoadingCallback(
    NavigationAction action,
  ) async {
    final url = action.request.url?.toString() ?? '';
    final pageUri = _currentUri;
    final requestUri = Uri.tryParse(url);

    // External / custom schemes: never load inside the WebView.
    // Main-frame only — subresources with exotic schemes are just cancelled.
    // Prompt the user (unless they chose "don't ask again" for this app).
    if (url.isNotEmpty &&
        requestUri != null &&
        isExternalAppUri(requestUri)) {
      if (action.isForMainFrame) {
        unawaited(
          handleExternalAppUri(
            requestUri,
            onMagnet: (u) => _onDownloadStartRequest?.call(u, null),
            pageHost: _currentHost.isNotEmpty ? _currentHost : null,
          ),
        );
      }
      return NavigationActionPolicy.CANCEL;
    }

    final sourceHost = _currentHost;
    final requestType = action.isForMainFrame ? 'document' : 'subdocument';
    bool isThirdParty = false;
    if (pageUri != null &&
        requestUri != null &&
        requestUri.hasScheme &&
        pageUri.hasScheme) {
      isThirdParty = pageUri.host != requestUri.host;
    }
    // Per-site allowlist: skip adblock for the current page's host
    final pageHost = _currentHost;
    final allowlisted =
        pageHost.isNotEmpty && _adblockAllowlistSet.contains(pageHost);

    // Tracking-parameter stripping ($removeparam rules, AdGuard URL
    // Tracking): rewrite main-frame navigations to the cleaned URL instead
    // of loading the tracking-laden one.
    if (action.isForMainFrame &&
        !allowlisted &&
        requestUri != null &&
        _isHttpLike(requestUri) &&
        _adBlockerEnabled) {
      final cleaned = _adBlockEngine.stripTrackingParams(url);
      if (cleaned != null && cleaned != url) {
        unawaited(
          _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(cleaned))),
        );
        return NavigationActionPolicy.CANCEL;
      }
    }

    // Back/forward only for redirect trust — do NOT treat "URL is somewhere
    // in history" as trusted. Ads reusing a previously visited host would
    // otherwise escape the invisible-redirect prompt.
    final isLiveHistoryNav = _isHistoryNavigation;
    final trustedNav = isLiveHistoryNav || _isTrustedCrossOriginNav(url);
    // Adblock still uses history-contains fallback (race with goBack flag).
    final isHistoryNavForAdblock =
        isLiveHistoryNav || _history.contains(url);

    final crossOriginMainFrame = action.isForMainFrame &&
        !trustedNav &&
        pageUri != null &&
        requestUri != null &&
        _isHttpLike(pageUri) &&
        _isHttpLike(requestUri) &&
        !_sameOrigin(pageUri, requestUri);

    // After replace-site-player intercepts play(), cancel ad navigations
    // silently (even with user gesture) so the tab stays on the video page.
    if (crossOriginMainFrame && _isPlayNavSuppressActive) {
      return NavigationActionPolicy.CANCEL;
    }

    if (_invisibleRedirectBlockingEnabled && crossOriginMainFrame) {
      // "Always block on this site" entries: cancel silently, no prompt.
      final alwaysBlocked = _alwaysBlockedRedirectHosts[sourceHost] ?? const [];
      final targetHost =
          requestUri.host.isNotEmpty == true ? requestUri.host : '';
      if (targetHost.isNotEmpty &&
          alwaysBlocked.contains(targetHost.toLowerCase())) {
        _blockedInvisibleRedirectsCount++;
        return NavigationActionPolicy.CANCEL;
      }
      final hasGesture = action.hasGesture == true;
      final isRedirect = action.isRedirect == true;
      final navType = action.navigationType;
      // navigationType is iOS/desktop only — on Android it is usually null.
      final knownNonLink = navType != null &&
          navType != NavigationType.LINK_ACTIVATED &&
          navType != NavigationType.BACK_FORWARD &&
          navType != NavigationType.RELOAD;
      final looksLikeAdDocument = shouldBlockUrl(
        url,
        sourceHost: sourceHost,
        requestType: 'document',
        isThirdParty: true,
      );
      // Prompt + cancel when: server redirect, no gesture, non-link nav type,
      // or the destination is an adblock-listed document (gesture stamped
      // ad hops that previously escaped).
      final shouldPromptStrictRedirect = isRedirect ||
          !hasGesture ||
          knownNonLink ||
          looksLikeAdDocument;
      if (shouldPromptStrictRedirect) {
        final method = isRedirect
            ? 'http-redirect'
            : knownNonLink
                ? 'scripted navigation'
                : looksLikeAdDocument
                    ? 'ad navigation'
                    : 'main-frame navigation';
        _onStrictRedirectDetected?.call(
          StrictRedirectEvent(
            url: url,
            sourceUrl: pageUri.toString(),
            method: method,
            userInitiated: hasGesture,
            isRedirect: isRedirect,
          ),
        );
        return NavigationActionPolicy.CANCEL;
      }
    }
    if (!allowlisted &&
        !isHistoryNavForAdblock &&
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

  /// Safety net when WebView still surfaces [ERR_UNKNOWN_URL_SCHEME]
  /// (e.g. rare loads that skip shouldOverride).
  void onReceivedErrorCallback(
    WebResourceRequest request,
    WebResourceError error,
  ) {
    final url = request.url.toString();
    if (url.isEmpty || request.isForMainFrame != true) return;
    final uri = Uri.tryParse(url);
    if (uri == null || !isExternalAppUri(uri)) return;

    final desc = error.description.toLowerCase();
    final typeName = error.type.toString().toLowerCase();
    final looksUnknownScheme = desc.contains('unknown_url_scheme') ||
        desc.contains('err_unknown_url_scheme') ||
        typeName.contains('unsupported_scheme') ||
        typeName.contains('unknown_url_scheme');
    if (!looksUnknownScheme) return;

    unawaited(
      handleExternalAppUri(
        uri,
        onMagnet: (u) => _onDownloadStartRequest?.call(u, null),
        pageHost: _currentHost.isNotEmpty ? _currentHost : null,
      ),
    );
  }

  /// Called by InAppWebView onDownloadStartRequest when the WebView detects
  /// a file download (e.g. <a download>, Content-Disposition: attachment).
  /// Routes the download URL to the sniffer so it appears in the FAB drawer.
  void onDownloadStartRequestCallback(DownloadStartRequest request) {
    final url = request.url.toString();
    if (url.isEmpty) return;
    // Play channel: never route YouTube download starts into the sniffer.
    if (RestrictedMediaPolicy.isBlocked(
      mediaUrl: url,
      sourcePageUrl: _currentUrl,
    )) {
      return;
    }
    if (_onDownloadStartRequest != null) {
      _onDownloadStartRequest!(url, request.suggestedFilename);
    }
  }

  /// Called by InAppWebView onLoadResource — this is the KEY callback for Beeg24.
  /// It fires for ALL subresource loads including cross-origin iframes.
  /// Note: LoadedResource only exposes url + initiatorType (no MIME/headers),
  /// so we classify by URL extension and initiator type.
  void onLoadResource(LoadedResource? resource) {
    if (resource == null) return;
    final url = resource.url?.toString() ?? '';
    if (url.isEmpty) return;

    // Play: hard-off when main frame is a restricted surface (primary gate).
    if (RestrictedMediaPolicy.shouldHardOffSniffing(_currentUrl)) {
      return;
    }
    // Play: URL/CDN backstop.
    if (RestrictedMediaPolicy.isBlocked(
      mediaUrl: url,
      sourcePageUrl: _currentUrl,
    )) {
      return;
    }

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
      if (isPlaylistPathHint(lowUrl)) {
        matches = true;
      }
    }

    // Video-hosting-domain match: catch URLs from known video CDNs
    // (DoodStream, Streamtape, MixDrop, etc.) that serve video through
    // redirect chains or iframe embeds. These URLs don't end in `.mp4`
    // but are video pages/download links that the user can open to
    // reach the actual video.
    if (!matches) {
      if (isVideoHostingUrl(url)) {
        matches = true;
      }
    }
    // G1: Extensionless URL probe — when a URL has no recognised media
    // extension but comes from a known video host or matches a secondary
    // path hint (/media/, /video/, /stream/, /cdn/), do a single HEAD
    // content-type probe.  Budgeted to max 5 probes per page load with
    // a per-page negative cache.
    if (!matches) {
      final hasHostMatch = isVideoHostingUrl(url, extraHosts: _customVideoHostsSet);
      final hasSecondaryHint = isSecondaryMediaPathHint(lowUrl);
      if ((hasHostMatch || hasSecondaryHint) &&
          _extensionlessProbeCount < 5 &&
          !_extensionlessNegativeCache.contains(url)) {
        _extensionlessProbeCount++;
        unawaited(_probeExtensionlessUrl(url));
      }
    }

    if (!matches) return;

    // Throttle: batch matching URLs and flush every 500ms,
    // with a hard cap of 20 URLs per flush to prevent platform channel saturation.
    // Playlist URLs (.m3u8, .mpd) are flushed immediately so the user sees
    // them in the FAB without waiting for the next batch tick.
    if (url.contains('.m3u8') || url.contains('.mpd')) {
      _onIframeMediaDetected?.call(url);
      return;
    }
    if (!_pendingResourceUrls.contains(url) &&
        _pendingResourceUrls.length >= _maxPendingResourceUrls) {
      _pendingResourceUrls.remove(_pendingResourceUrls.first);
    }
    _pendingResourceUrls.add(url);
    _loadResourceTimer ??= Timer.periodic(const Duration(milliseconds: 500), (
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
    /// Skip the external-app confirmation (typed address bar / explicit user action).
    bool skipExternalPrompt = false,
  }) async {
    if (_isDisposed) return;
    final urlStr = uri.toString();
    if (urlStr.isEmpty) {
      debugPrint(
        '[BrowserController] loadRequest called with empty URI — ignoring',
      );
      return;
    }
    // Address bar / context menu / redirect "open here" can request tg:,
    // magnet:, etc. Never push those into Chromium.
    if (isExternalAppUri(uri)) {
      await handleExternalAppUri(
        uri,
        onMagnet: (u) => _onDownloadStartRequest?.call(u, null),
        skipPrompt: skipExternalPrompt,
        pageHost: _currentHost.isNotEmpty ? _currentHost : null,
      );
      return;
    }
    _currentHeaders = headers ?? const {};
    _setCurrentUrl(urlStr);
    if (addToHistory) {
      _recordHistoryNavigation(urlStr);
    }
    // Address bar / intentional loads must not trip the redirect prompt
    // (wildcard covers server redirect chains off the typed URL).
    await allowNextCrossOriginNavigation();
    // Only fire synthetic callbacks for EXISTING WebViews (already ready).
    // For NEW WebViews, skip and let the real onLoadStart/onUpdateVisitedHistory
    // callbacks handle the UI update, avoiding a race where the WebView hasn't
    // been created yet and refreshPageInfo overwrites tab.currentUrl.
    if (_ready.isCompleted) {
      _onPageStarted?.call(urlStr);
      _onUrlChanged?.call(urlStr);
    }
    await _ready.future;
    if (_isDisposed) return;
    try {
      await _controller?.loadUrl(
        urlRequest: URLRequest(url: WebUri.uri(uri), headers: headers),
      );
    } catch (e) {
      debugPrint('[BrowserController] loadUrl failed (likely disposed): $e');
    }
  }

  void _recordHistoryNavigation(String urlStr) {
    if (_historyIndex < _history.length - 1) {
      _history.removeRange(_historyIndex + 1, _history.length);
    }
    _history.add(urlStr);
    _historyIndex = _history.length - 1;
    _onNavStateChanged?.call();
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
    _setCurrentUrl(
      _historyIndex >= 0 ? _history[_historyIndex] : null,
      clearOnNull: true,
    );
    _onNavStateChanged?.call();
  }

  @override
  Future<void> loadFile(String path) async {
    _setCurrentUrl('file://$path');
    await _ready.future;
    if (path.startsWith('/') || path.contains(':\\\\') || path.contains(':/')) {
      // Absolute path = a saved page. The WebView runs with
      // allowFileAccess=false (browser_widget.dart), which refuses file://
      // loads — so load the captured HTML as data instead (no file access
      // needed). The <base href> the saver injected points at the source
      // origin, so remote subresources (css/images) resolve over the network.
      try {
        final html = await File(path).readAsString();
        await _controller?.loadData(
          data: html,
          baseUrl: WebUri('file://$path'),
        );
      } catch (error) {
        debugPrint('loadFile failed for $path: $error');
      }
    } else {
      await _controller?.loadFile(assetFilePath: path);
    }
  }

  @override
  Future<void> reapplyCosmeticRules(String pageUrl) async {
    await _adblockInjector.injectForPage(pageUrl);
  }

  @override
  Future<String?> currentUrl() async {
    await _ready.future;
    final url = await _controller?.getUrl();
    _setCurrentUrl(url?.toString());
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
      _onNavStateChanged?.call();
      // Use the WebView's native goBack() which uses the browser cache
      // and is instant, instead of reloading the page from the network.
      try {
        final canGo = await _controller?.canGoBack() ?? false;
        if (canGo) {
          await _controller?.goBack();
        } else {
          final url = _history[_historyIndex];
          await loadRequest(Uri.parse(url), addToHistory: false);
        }
      } catch (_) {
        final url = _history[_historyIndex];
        await loadRequest(Uri.parse(url), addToHistory: false);
      }
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
      _onNavStateChanged?.call();
      // Use the WebView's native goForward() which uses the browser cache
      // and is instant, instead of reloading the page from the network.
      try {
        final canGo = await _controller?.canGoForward() ?? false;
        if (canGo) {
          await _controller?.goForward();
        } else {
          final url = _history[_historyIndex];
          await loadRequest(Uri.parse(url), addToHistory: false);
        }
      } catch (_) {
        final url = _history[_historyIndex];
        await loadRequest(Uri.parse(url), addToHistory: false);
      }
      _isHistoryNavigation = false;
    }
  }

  @override
  Future<void> reload() async {
    await _ready.future;
    // Use the WebView's native reload — it already sends Cache-Control: max-age=0
    // to bypass the HTTP cache for this page.  Do NOT call
    // InAppWebViewController.clearAllCache() globally — that destroys the
    // in-memory back-forward cache (bfcache) for EVERY tab, forcing every
    // WebView to reload pages from the network on back/forward navigation.
    await _controller?.reload();
  }

  @override
  Future<void> stop() async {
    await _ready.future;
    await _controller?.stopLoading();
    // stopLoading() does not trigger onLoadStop, so manually fire
    // page-finished to transition the tab out of loading state.
    final url = _currentUrl;
    if (url != null) {
      _onPageFinished?.call(url);
    }
  }

  @override
  void setOnProgressChanged(void Function(int progress)? callback) {
    _onProgressChanged = callback;
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
  void setOnRecreated(void Function() callback) {
    _onRecreated = callback;
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
    // NOTE: We intentionally do NOT call freeze() here.  freeze() hides the
    // DOM via visibility:hidden, but if Android kills the WebView renderer
    // while the tab is in the background, thaw() fails silently and the
    // user sees a permanent blank/blue screen when returning to the tab.
    //
    // pauseTimers is process-global. Call it at most once per hide/background
    // transition — never per background tab after the active tab has resumed.
    try {
      await _controller?.pauseTimers();
    } catch (_) {}
  }

  @override
  Future<void> resumeActiveWebView() async {
    await resumeWebView(checkAlive: true);
  }

  @override
  void onRenderProcessGone() async {
    try {
      final url = await _controller?.getUrl();
      if (url != null && url.toString().isNotEmpty) {
        await _controller?.loadUrl(urlRequest: URLRequest(url: url));
      }
    } catch (_) {}
  }

  @override
  Future<void> pauseWebView() async {
    // Per-WebView only. Global pauseTimers must NOT be used here: when
    // multiple tabs call pauseWebView after the active tab resumed, the
    // last pauseTimers wins and freezes the visible page (scrollbar may
    // still move while pixels stay stale).
    if (!Platform.isAndroid) return;
    try {
      await _controller?.android.pause();
    } catch (_) {}
  }

  @override
  Future<void> resumeWebView({bool checkAlive = true}) async {
    // Always re-enable process timers first so a stuck global pause cannot
    // leave the active tab with a frozen compositor.
    try {
      await _controller?.resumeTimers();
    } catch (_) {}
    if (Platform.isAndroid) {
      try {
        await _controller?.android.resume();
      } catch (_) {}
    }
    // Liveness probe: when Android has killed the background renderer
    // (common under memory pressure with 4+ live WebViews), the surface
    // shows frozen/stale pixels.  Probe with evaluateJavascript and reload
    // if the renderer is gone.
    if (checkAlive) {
      try {
        final url = await _controller?.getUrl();
        if (url != null && url.toString().isNotEmpty) {
          await _controller?.evaluateJavascript(source: '1');
        }
      } catch (_) {
        // Renderer was killed — reload.
        try {
          final url = await _controller?.getUrl();
          if (url != null && url.toString().isNotEmpty) {
            await _controller?.loadUrl(urlRequest: URLRequest(url: url));
          }
        } catch (_) {}
      }
    }
  }

  @override
  Future<void> suspendTab() async {
    if (!Platform.isAndroid) return;
    try {
      await _controller?.android.pause();
    } catch (_) {}
  }

  @override
  Future<void> resumeTab() async {
    if (!Platform.isAndroid) return;
    try {
      await _controller?.android.resume();
    } catch (_) {}
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
  /// Runs the find cycle and returns the number of matches (0 when none).
  ///
  /// Highlights the first match with a single `window.find` and counts via a
  /// TreeWalker over text nodes. No counting loops: repeated `window.find`
  /// calls thrash Android WebView's native finder and can break page
  /// rendering (the white-region regression). The plugin json-decodes
  /// results, so the count arrives as a Dart int directly.
  Future<int> findAllAsync(String search) async {
    final c = _controller;
    if (c == null || search.isEmpty) return 0;
    await c
        .evaluateJavascript(
          source:
              "window.find('${_jsEscape(search)}',false,false,true,false,false,false);",
        )
        .catchError((_) {});
    final count = await c
        .evaluateJavascript(
          source:
              "(function(){var q='${_jsEscape(search.toLowerCase())}';var n=0;var w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);var t;while((t=w.nextNode())){var s=t.textContent.toLowerCase();var i=s.indexOf(q);while(i!==-1){n++;i=s.indexOf(q,i+q.length);}}return n;})();",
        )
        .catchError((_) => 0);
    if (count is int) return count;
    return int.tryParse('$count') ?? 0;
  }

  @override
  Future<String?> capturePageHtml({
    int chunkSize = 200000,
    int maxBytes = 30 * 1024 * 1024,
  }) async {
    final c = _controller;
    if (c == null) return null;
    // This plugin's evaluateJavascript json-decodes results: a JS number
    // arrives as Dart int and a JS string as a decoded String (no quotes).
    final lenRaw = await c
        .evaluateJavascript(
          source: 'document.documentElement.outerHTML.length;',
        )
        .catchError((_) => 0);
    final len = lenRaw is int ? lenRaw : (int.tryParse('$lenRaw') ?? 0);
    if (len <= 0 || len > maxBytes) return null;
    final sb = StringBuffer();
    for (var start = 0; start < len; start += chunkSize) {
      final end = start + chunkSize < len ? start + chunkSize : len;
      final raw = await c
          .evaluateJavascript(
            source:
                'document.documentElement.outerHTML.substring($start, $end);',
          )
          .catchError((_) => '');
      if (raw is String) sb.write(raw);
    }
    return sb.toString();
  }

  @override
  Future<void> findNext(bool forward, String query) async {
    // Navigate with the real query: window.find starts from the current
    // selection, so this moves the highlight to the next/previous occurrence.
    // The previous implementation searched for a space then re-found the
    // selection — it never moved to the next match.
    await _controller
        ?.evaluateJavascript(
          source:
              "window.find('${_jsEscape(query)}',false,${!forward},true,false,false,false);",
        )
        .catchError((_) {});
  }

  @override
  Future<void> clearMatches() async {
    await _controller
        ?.evaluateJavascript(
          source:
              'if(window.getSelection) window.getSelection().removeAllRanges();',
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
    // Delete all cookies through the OS-level CookieManager.
    // Do NOT call InAppWebViewController.clearAllCache() — that destroys
    // the back-forward cache for ALL tabs, forcing network reloads.
    try {
      await CookieManager.instance().deleteAllCookies();
    } catch (_) {
      // Fallback: delete known cookies for the current page domain.
      try {
        if (_currentHost.isNotEmpty) {
          await CookieManager.instance().deleteCookies(
            url: WebUri('https://$_currentHost/'),
          );
          await CookieManager.instance().deleteCookies(
            url: WebUri('http://$_currentHost/'),
          );
        }
      } catch (_) {}
    }
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
    // Deliberately NOT calling InAppWebViewController.clearAllCache() here —
    // that would destroy the back-forward cache for ALL tabs, forcing every
    // WebView to reload from network on back/forward navigation.  Only a
    // per-URL clear would be appropriate, and even then the HTTP cache is
    // separate from the bfcache.
  }

  @override
  Future<String?> fetchFreshPlaylistUrl(String url) =>
      _fetchDelegate.fetchFreshPlaylistUrl(url);

  @override
  Future<String?> fetchViaJavaScript(
    String url, {
    Map<String, String>? headers,
  }) => _fetchDelegate.fetchViaJavaScript(url, headers: headers);

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
  void Function(String)? _onOpenUrlInNewTab;

  @override
  void openUrlInNewTab(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;
    final callback = _onOpenUrlInNewTab;
    if (callback == null) {
      debugPrint(
        '[BrowserController] openUrlInNewTab("$trimmed") — callback null, '
        'queued (pending=${_pendingOpenInNewTabUrls.length + 1})',
      );
      _pendingOpenInNewTabUrls.add(trimmed);
      return;
    }
    debugPrint(
      '[BrowserController] openUrlInNewTab("$trimmed") — invoking callback',
    );
    callback(trimmed);
  }

  /// Registers a callback for [openUrlInNewTab]. Passing `null` clears it.
  @override
  void setOnOpenUrlInNewTab(void Function(String url)? callback) {
    _onOpenUrlInNewTab = callback;
    if (callback != null && _pendingOpenInNewTabUrls.isNotEmpty) {
      final pending = List<String>.from(_pendingOpenInNewTabUrls);
      _pendingOpenInNewTabUrls.clear();
      debugPrint(
        '[BrowserController] setOnOpenUrlInNewTab: flushing ${pending.length} '
        'pending URL(s)',
      );
      scheduleMicrotask(() {
        for (final u in pending) {
          callback(u);
        }
      });
    }
  }

  void Function(List<String> urls)? _onOpenUrlsInNewTabs;
  final List<String> _pendingOpenUrlsInNewTabs = [];

  @override
  void openUrlsInNewTabs(List<String> urls) {
    final trimmed = urls.map((u) => u.trim()).where((u) => u.isNotEmpty).toList();
    if (trimmed.isEmpty) return;
    final callback = _onOpenUrlsInNewTabs;
    if (callback == null) {
      debugPrint(
        '[BrowserController] openUrlsInNewTabs(${trimmed.length}) — callback '
        'null, queued (pending=${_pendingOpenUrlsInNewTabs.length + trimmed.length})',
      );
      _pendingOpenUrlsInNewTabs.addAll(trimmed);
      return;
    }
    callback(trimmed);
  }

  /// Registers a callback for [openUrlsInNewTabs]. Passing `null` clears it.
  @override
  void setOnOpenUrlsInNewTabs(void Function(List<String> urls)? callback) {
    _onOpenUrlsInNewTabs = callback;
    if (callback != null && _pendingOpenUrlsInNewTabs.isNotEmpty) {
      final pending = List<String>.from(_pendingOpenUrlsInNewTabs);
      _pendingOpenUrlsInNewTabs.clear();
      scheduleMicrotask(() => callback(pending));
    }
  }

  @override
  void setOnSystemBackRequested(Future<bool> Function()? callback) {
    _onSystemBackRequested = callback;
  }

  @override
  Future<bool> handleSystemBack() async {
    return (await _onSystemBackRequested?.call()) ?? false;
  }

  @override
  void setOnNavStateChanged(VoidCallback? callback) {
    _onNavStateChanged = callback;
  }

  @override
  void setOnStrictRedirectDetected(
    void Function(StrictRedirectEvent event)? callback,
  ) {
    _onStrictRedirectDetected = callback;
  }

  @override
  void requestOpenUrl(String url) {
    final callback = _onOpenUrlRequest;
    if (callback == null) {
      _pendingOpenUrl = url;
      return;
    }
    callback(url);
  }

  @override
  void setOnOpenUrlRequest(void Function(String url)? callback) {
    _onOpenUrlRequest = callback;
    final pending = _pendingOpenUrl;
    if (callback != null && pending != null && pending.isNotEmpty) {
      _pendingOpenUrl = null;
      scheduleMicrotask(() => callback(pending));
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _guardInstaller.dispose();
    _adblockInjector.dispose();
    _loadResourceTimer?.cancel();
    _guardReinstallDebounce?.cancel();
    _pendingResourceUrls.clear();
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
  bool _invisibleRedirectBlockingEnabled = true;
  AdBlockEngine _adBlockEngine = AdBlockEngine.builtIn();
  int _blockedPopupsCount = 0;
  int _blockedInvisibleRedirectsCount = 0;
  Map<String, String> _currentHeaders = {};
  HlsPlaylist? _lastMasterPlaylist;

  void Function(String)? _onOpenUrlRequest;
  String? _pendingOpenUrl;
  final List<String> _pendingOpenInNewTabUrls = [];
  void Function(String)? _onOpenUrlInNewTab;
  Future<bool> Function()? _onSystemBackRequested;
  void Function()? _onNavStateChanged;

  @override
  void openUrlInNewTab(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;
    final callback = _onOpenUrlInNewTab;
    if (callback == null) {
      _pendingOpenInNewTabUrls.add(trimmed);
      return;
    }
    callback(trimmed);
  }

  @override
  void setOnOpenUrlInNewTab(void Function(String url)? callback) {
    _onOpenUrlInNewTab = callback;
    if (callback != null && _pendingOpenInNewTabUrls.isNotEmpty) {
      final pending = List<String>.from(_pendingOpenInNewTabUrls);
      _pendingOpenInNewTabUrls.clear();
      scheduleMicrotask(() {
        for (final u in pending) {
          callback(u);
        }
      });
    }
  }

  void Function(List<String> urls)? _onOpenUrlsInNewTabs;
  final List<String> _pendingOpenUrlsInNewTabs = [];

  @override
  void openUrlsInNewTabs(List<String> urls) {
    final trimmed = urls.map((u) => u.trim()).where((u) => u.isNotEmpty).toList();
    if (trimmed.isEmpty) return;
    final callback = _onOpenUrlsInNewTabs;
    if (callback == null) {
      _pendingOpenUrlsInNewTabs.addAll(trimmed);
      return;
    }
    callback(trimmed);
  }

  @override
  void setOnOpenUrlsInNewTabs(void Function(List<String> urls)? callback) {
    _onOpenUrlsInNewTabs = callback;
    if (callback != null && _pendingOpenUrlsInNewTabs.isNotEmpty) {
      final pending = List<String>.from(_pendingOpenUrlsInNewTabs);
      _pendingOpenUrlsInNewTabs.clear();
      scheduleMicrotask(() => callback(pending));
    }
  }

  @override
  void setOnSystemBackRequested(Future<bool> Function()? callback) {
    _onSystemBackRequested = callback;
  }

  @override
  Future<bool> handleSystemBack() async {
    return (await _onSystemBackRequested?.call()) ?? false;
  }

  @override
  void setOnNavStateChanged(VoidCallback? callback) {
    _onNavStateChanged = callback;
  }

  @override
  void setOnStrictRedirectDetected(
    void Function(StrictRedirectEvent event)? callback,
  ) {}

  @override
  void requestOpenUrl(String url) {
    final callback = _onOpenUrlRequest;
    if (callback == null) {
      _pendingOpenUrl = url;
      return;
    }
    callback(url);
  }

  @override
  void setOnOpenUrlRequest(void Function(String url)? callback) {
    _onOpenUrlRequest = callback;
    final pending = _pendingOpenUrl;
    if (callback != null && pending != null && pending.isNotEmpty) {
      _pendingOpenUrl = null;
      scheduleMicrotask(() => callback(pending));
    }
  }

  @override
  void dispose() {}

  @override
  Future<void> rescanPage() async {}

  @override
  void setOnIframeMediaDetected(void Function(String url) callback) {}

  @override
  void setOnDownloadStartRequest(
    void Function(String url, String? suggestedFilename) callback,
  ) {}
  @override
  HlsPlaylist? get lastMasterPlaylist => _lastMasterPlaylist;

  @override
  Map<String, String> get currentHeaders => _currentHeaders;

  @override
  bool get adBlockerEnabled => _adBlockerEnabled;

  @override
  bool get popupBlockingEnabled => _popupBlockingEnabled;

  @override
  bool get invisibleRedirectBlockingEnabled =>
      _invisibleRedirectBlockingEnabled;

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
  int get blockedInvisibleRedirectsCount => _blockedInvisibleRedirectsCount;

  @override
  void incrementBlockedInvisibleRedirects() {
    _blockedInvisibleRedirectsCount++;
  }

  @override
  Future<void> setInvisibleRedirectBlocking(bool enabled) async {
    _invisibleRedirectBlockingEnabled = enabled;
  }

  @override
  void setAlwaysBlockedRedirectHosts(Map<String, List<String>> hosts) {}

  @override
  void armPlayNavigationSuppress([
    Duration duration = const Duration(milliseconds: 3500),
  ]) {}

  @override
  Future<void> allowNextCrossOriginNavigation([String? url]) async {}

  @override
  Future<void> setReplaceSitePlayer(bool enabled) async {}

  @override
  Future<void> setIncognito(bool incognito) async {}

  @override
  bool get isIncognito => false;

  @override
  int get blockedRequestCount => 0;

  @override
  List<String> get adblockAllowlist => const [];

  @override
  void updateAdblockAllowlist(List<String> allowlist) {}

  @override
  void updateCustomVideoHosts(List<String> hosts) {}

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

  bool _cloudflareStealthEnabled = true;

  @override
  bool get cloudflareStealthEnabled => _cloudflareStealthEnabled;

  @override
  Future<void> setCloudflareStealthEnabled(bool enabled) async {
    _cloudflareStealthEnabled = enabled;
  }

  @override
  void setOnCloudflareBlockDetected(
    void Function(String host, bool retrying)? callback,
  ) {}

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
    bool skipExternalPrompt = false,
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
      _onNavStateChanged?.call();
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
    _onNavStateChanged?.call();
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
  Future<void> reapplyCosmeticRules(String pageUrl) async {}

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
      _onNavStateChanged?.call();
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
      _onNavStateChanged?.call();
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
  Future<void> stop() async {
    // Mock stop: fire page-finished to simulate load stopping
    if (_currentUrl != null) {
      _onPageFinished?.call(_currentUrl!);
    }
  }

  @override
  void setOnProgressChanged(void Function(int progress)? callback) {}

  @override
  void setOnUrlChanged(void Function(String url) callback) {
    _onUrlChanged = callback;
  }

  @override
  void setOnRecreated(void Function() callback) {}

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
  Future<void> pauseWebView() async {}

  @override
  Future<void> resumeWebView({bool checkAlive = true}) async {}

  @override
  Future<void> suspendTab() async {}

  @override
  Future<void> resumeTab() async {}

  @override
  void onRenderProcessGone() {}

  @override
  Future<int> fillForm(Map<String, String> values) async => 0;

  @override
  Future<int> findAllAsync(String search) async => 0;

  @override
  Future<void> findNext(bool forward, String query) async {}

  @override
  Future<String?> capturePageHtml({
    int chunkSize = 200000,
    int maxBytes = 30 * 1024 * 1024,
  }) async =>
      null;

  @override
  Future<void> clearMatches() async {}

  @override
  Future<void> clearCookies() async {}

  @override
  Future<void> clearSiteData(String url) async {}

  @override
  Future<String?> fetchFreshPlaylistUrl(String url) async => url;

  @override
  Future<String?> fetchViaJavaScript(
    String url, {
    Map<String, String>? headers,
  }) async => null;

  @override
  Future<Map<String, String>?> fetchHeadersViaJavaScript(String url) async =>
      null;

  @override
  Future<String?> fetchPlaylistBodyViaJavaScript(String url) async => null;

  @override
  Future<List<int>?> fetchBinaryViaJavaScript(String url) async => null;

  @override
  Future<Map<String, String>> getCookiesForDomain({String? url}) async => {};
}

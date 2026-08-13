import 'dart:async';

import 'package:flutter/material.dart';

import '../../compliance/restricted_media_policy.dart';
import '../../downloader/downloader.dart';
import '../../downloader/filename_service.dart';
import '../../settings/download_settings.dart';
import '../bridge_url_guard.dart';
import '../models/browser_tab.dart';
import '../models/page_meta.dart';
import '../models/sniffed_media.dart';
import 'sniff_intake_controller.dart';

/// Narrow interface that [TabCallbackBinder] uses to reach back into the
/// owning [SnifferScreen] for side effects it must not own directly
/// (navigation state, scroll chrome, popup/redirect UX, download
/// decisions, player orchestration, and mutable bookkeeping fields).
///
/// Every member is a callback, getter, or getter/setter pair the host
/// screen satisfies.  Inject controllers directly when possible instead
/// of adding more host methods.
abstract class TabCallbackHost {
  /// Whether the host widget is currently mounted.
  bool get isMounted;

  /// The currently active browser tab.
  BrowserTab get activeTab;

  /// Current download settings (popup blocking, replace-site-player, …).
  DownloadSettings get settings;

  /// Triggers a [State.setState] rebuild on the host.
  void markNeedsBuild();

  /// Debounced version of [markNeedsBuild] for navigation callbacks.
  void debouncedNavSetState();

  /// Update the tab's navigation state (canGoBack, canGoForward).
  void updateTabNavState(BrowserTab tab);

  /// Handle scroll-driven chrome show/hide.
  void onScroll(double x, double y);

  /// Progress value notifier for the active tab.
  ValueNotifier<int> get progressNotifier;

  /// Address bar listener callback (fires suggestions).
  VoidCallback get onAddressChanged;

  /// Returns true when two URLs represent genuinely different pages
  /// (used to decide cache clearing on navigation).
  bool isDifferentPage(String? a, String? b);

  // ---- Mutable bookkeeping (owned by host screen) ----

  double get lastScrollY;
  set lastScrollY(double v);

  bool get barsVisible;
  set barsVisible(bool v);

  SniffedMedia? get latestVideoMedia;
  set latestVideoMedia(SniffedMedia? v);

  Rect? get videoFloatRect;
  set videoFloatRect(Rect? v);

  String? get floatingPlayerDismissedForUrl;
  set floatingPlayerDismissedForUrl(String? v);

  // ---- Popup / redirect / picker handlers ----

  void handleNativeStrictRedirect(BrowserTab tab, Object event);
  void handlePopupEvent(BrowserTab tab, String message);
  void handleInvisibleRedirect(BrowserTab tab, String message);
  Future<void> handlePickedElement(BrowserTab tab, String message);
  void showLinkContextMenu(String message);

  // ---- Player / float ----

  Future<void> handleAuroraPlayRequest(String message);
  void handleVideoFloatMessage(String message);

  /// Show the restricted-media compliance snackbar on the active
  /// [BuildContext].  Called from [onPageFinished] when a page is
  /// hard-off restricted and the notice hasn't been shown yet.
  void showComplianceNotice();

  // ---- JS / sniffing helpers ----

  Future<Map?> decodeJsInBackground(String message);
  void sniffIframeContent(BrowserTab tab, String url);

  // ---- Download callbacks ----

  Future<void> handleEnqueueDownload(
    BrowserTab tab,
    String url,
    String? suggestedFilename,
  );
  void handleDownloadPrompt(
    BrowserTab tab,
    String url,
    String? suggestedFilename,
  );
  void showSnack(String message);

  // ---- Page-level lifecycle helpers (onPageFinished) ----

  Future<void> refreshPageInfo(BrowserTab tab, {bool recordHistory = false});
  Future<void> saveTabs();
  void startVideoPoll(BrowserTab tab);
  void applyZoomForPage(BrowserTab tab, String url);
  Future<void> applyDarkModeForPage(BrowserTab tab, String url);
  Future<void> loadUrlWithHostSettings(
    BrowserTab tab,
    Uri uri, {
    bool addToHistory = false,
    bool forceInApp = false,
  });

  // ---- Media / playback helpers ----

  bool mediaBelongsToActiveTab(SniffedMedia media);
  bool shouldReplaceVideo(SniffedMedia incoming);
}

/// Wires all WebView callbacks (navigation, sniffing, download, play,
/// popup blocking, JS channels) onto a single [BrowserTab].
///
/// Previously the ~450-line `_setupTabCallbacks` method inside
/// `_SnifferScreenState`.  Extracted so the wiring is unit-testable,
/// the host surface is explicit, and the screen file shrinks.
class TabCallbackBinder {
  final TabCallbackHost _host;
  final SniffIntakeController _sniffIntakeController;

  TabCallbackBinder({
    required TabCallbackHost host,
    required SniffIntakeController sniffIntakeController,
  })  : _host = host,
        _sniffIntakeController = sniffIntakeController;

  /// Attach all callbacks to [tab].  Call once per tab creation.
  /// Does **not** guard against double-attach — callers must ensure
  /// single attachment (mirrors current `attachAddressListener` pattern).
  void attach(BrowserTab tab) {
    // Drive smart address suggestions while the user types.
    tab.attachAddressListener(_host.onAddressChanged);
    tab.controller.setOnUrlChanged((url) {
      if (!_host.isMounted) return;
      final changed =
          tab.currentUrl != url || tab.addressController.text != url;
      if (!changed) return;
      tab.addressController.text = url;
      tab.currentUrl = url;
      _sniffIntakeController.sniffBrowserUrl(tab, url, sourcePageUrl: url);
      _host.updateTabNavState(tab);
      if (_host.isMounted && tab == _host.activeTab) _host.debouncedNavSetState();
    });
    tab.controller.setOnPageStarted((url) {
      if (!_host.isMounted) return;
      tab.isLoading = true;
      tab.progress = 0;
      if (tab == _host.activeTab) {
        _host.progressNotifier.value = 0;
      }
      _host.lastScrollY = 0.0;
      if (!_host.barsVisible) {
        _host.barsVisible = true;
      }
      tab.fetchedIframeSrcs.clear();
      debugPrint('Page started: $url');
      tab.authHeaderCache.clear();
      final navHost = Uri.tryParse(url)?.host;
      if (navHost != null) {
        _sniffIntakeController.clearCookieCacheForHost(navHost);
      }
      final hardOff = RestrictedMediaPolicy.shouldHardOffSniffing(url);
      tab.sniffingEnabled = !hardOff;
      if (!hardOff) {
        tab.complianceNoticeShown = false;
      } else {
        tab.videoPollTimer?.cancel();
        tab.videoPollTimer = null;
        tab.snifferEngine.purgeRestrictedMedia();
      }
      final previousUrl = tab.committedMainFrameUrl;
      if (url != tab.committedMainFrameUrl &&
          _host.isDifferentPage(tab.currentUrl, url)) {
        debugPrint('Navigation: clearing media cache ($previousUrl -> $url)');
        tab.snifferEngine.clearCache();
        if (tab == _host.activeTab) {
          _host.latestVideoMedia = null;
          _host.videoFloatRect = null;
          _host.floatingPlayerDismissedForUrl = null;
        }
      } else {
        debugPrint('Same-page navigation ($url) — keeping media cache '
          '(${tab.snifferEngine.detectedMedia.length} items)');
      }
      if (tab.sniffingEnabled) {
        _sniffIntakeController.sniffBrowserUrl(tab, url, sourcePageUrl: url);
      }
      _host.updateTabNavState(tab);
      if (tab == _host.activeTab) {
        _host.debouncedNavSetState();
      }
    });
    tab.controller.setOnPageFinished((url) {
      if (!_host.isMounted) return;
      tab.isLoading = false;
      tab.progress = 0;
      tab.committedMainFrameUrl = url;
      _host.debouncedNavSetState();
      debugPrint('Page finished: $url');
      final hardOff = RestrictedMediaPolicy.shouldHardOffSniffing(url);
      tab.sniffingEnabled = !hardOff;
      if (hardOff) {
        tab.snifferEngine.purgeRestrictedMedia();
        tab.videoPollTimer?.cancel();
        tab.videoPollTimer = null;
        if (tab == _host.activeTab && !tab.complianceNoticeShown) {
          tab.complianceNoticeShown = true;
          _host.showComplianceNotice();
        }
      } else {
        tab.complianceNoticeShown = false;
      }
      if (tab.sniffingEnabled) {
        _sniffIntakeController.sniffBrowserUrl(tab, url, sourcePageUrl: url);
      }
      _host.updateTabNavState(tab);
      unawaited(_host.refreshPageInfo(tab, recordHistory: true));
      unawaited(_host.saveTabs());
      _host.startVideoPoll(tab);
      _host.applyZoomForPage(tab, url);
      unawaited(_host.applyDarkModeForPage(tab, url));
      unawaited(
        tab.controller.setReplaceSitePlayer(_host.settings.replaceSitePlayer),
      );
    });
    tab.controller.setOnProgressChanged((progress) {
      if (!_host.isMounted) return;
      tab.progress = progress;
      if (tab == _host.activeTab) {
        _host.progressNotifier.value = progress;
      }
    });
    tab.controller.setOnScrollPositionChange((x, y) {
      if (tab == _host.activeTab) {
        _host.onScroll(x, y);
      }
    });
    tab.controller.setOnRecreated(() {
      final url = tab.currentUrl ?? tab.addressController.text;
      if (url.isNotEmpty && url != 'about:blank') {
        // forceInApp: recreation is an internal state restore, not a user
        // navigation. Without this flag, resuming from a CCT on a WAF-blocked
        // host (externalBrowserHosts) re-routes to CCT → platform views
        // recreate on resume → loop.
        unawaited(
          _host.loadUrlWithHostSettings(
            tab,
            Uri.parse(url),
            addToHistory: false,
            forceInApp: true,
          ),
        );
      }
    });
    tab.controller.setOnNavStateChanged(() {
      if (!_host.isMounted) return;
      final prevBack = tab.canGoBack;
      final prevForward = tab.canGoForward;
      tab.canGoBack = tab.controller.historyIndex > 0;
      tab.canGoForward =
          tab.controller.historyIndex < tab.controller.historyUrls.length - 1;
      if (tab.canGoBack != prevBack || tab.canGoForward != prevForward) {
        if (_host.isMounted) _host.markNeedsBuild();
      }
    });
    tab.controller.setOnStrictRedirectDetected((event) {
      _host.handleNativeStrictRedirect(tab, event);
    });
    tab.controller.addJavaScriptChannel(
      'MediaSnifferChannel',
      onMessageReceived: (message) {
        final url = message.trim();
        final pageUrl = tab.addressController.text;
        if (!isAllowedBridgeUrl(url, pageUrl: pageUrl)) return;
        _sniffIntakeController.sniffBrowserUrl(
          tab,
          url,
          sourcePageUrl: pageUrl,
        );
      },
    );
    tab.controller.addJavaScriptChannel(
      'MediaSniffer',
      onMessageReceived: (message) {
        final url = message.trim();
        final pageUrl = tab.addressController.text;
        if (!isAllowedBridgeUrl(url, pageUrl: pageUrl)) return;
        _sniffIntakeController.sniffBrowserUrl(
          tab,
          url,
          sourcePageUrl: pageUrl,
        );
      },
    );
    tab.controller.addJavaScriptChannel(
      'AdBlockerChannel',
      onMessageReceived: (message) {
        if (message == 'popup_blocked' &&
            _host.isMounted &&
            _host.settings.popupBlockingEnabled) {
          tab.controller.incrementBlockedPopups();
          if (_host.isMounted) _host.markNeedsBuild();
        }
      },
    );
    tab.controller.addJavaScriptChannel(
      'PopupBlockerChannel',
      onMessageReceived: (message) {
        _host.handlePopupEvent(tab, message);
      },
    );
    tab.controller.addJavaScriptChannel(
      'InvisibleRedirectChannel',
      onMessageReceived: (message) {
        _host.handleInvisibleRedirect(tab, message);
      },
    );
    tab.controller.addJavaScriptChannel(
      'ElementPickerChannel',
      onMessageReceived: (message) {
        unawaited(_host.handlePickedElement(tab, message));
      },
    );
    tab.controller.addJavaScriptChannel(
      'LinkContextChannel',
      onMessageReceived: (message) {
        _host.showLinkContextMenu(message);
      },
    );
    tab.controller.addJavaScriptChannel(
      'AuroraPlayChannel',
      onMessageReceived: (message) {
        if (tab != _host.activeTab) return;
        unawaited(_host.handleAuroraPlayRequest(message));
      },
    );
    tab.controller.addJavaScriptChannel(
      'VideoFloatChannel',
      onMessageReceived: (message) {
        if (tab != _host.activeTab) return;
        _host.handleVideoFloatMessage(message);
      },
    );
    tab.controller.addJavaScriptChannel(
      'MediaMetaChannel',
      onMessageReceived: (message) {
        final capturedTab = tab;
        final pageUrl = capturedTab.addressController.text;
        _host.decodeJsInBackground(message).then((data) {
          if (data == null || !_host.isMounted) return;
          final src = data['src'] as String?;
          if (src != null && src.isNotEmpty) {
            // The poster is fetched by the app to paint the capture thumbnail,
            // so it goes through the same guard as any other bridge URL.
            final poster = data['poster'] as String?;
            _sniffIntakeController.sniffBrowserUrl(
              capturedTab,
              src,
              sourcePageUrl: pageUrl,
              thumbnailUrl:
                  (poster != null && isAllowedBridgeUrl(poster, pageUrl: pageUrl))
                      ? poster
                      : null,
            );
          }
        });
      },
    );
    tab.controller.addJavaScriptChannel(
      'MediaSnifferDataChannel',
      onMessageReceived: (message) {
        final capturedTab = tab;
        final pageUrl = capturedTab.addressController.text;
        _host.decodeJsInBackground(message).then((data) {
          if (data == null || !_host.isMounted) return;
          final url = data['url'] as String?;
          final ct = data['contentType'] as String?;
          final clStr = data['contentLength'] as String?;
          final cl = (clStr != null && clStr.isNotEmpty)
              ? int.tryParse(clStr)
              : null;
          if (url != null && url.isNotEmpty) {
            _sniffIntakeController.sniffBrowserUrl(
              capturedTab,
              url,
              sourcePageUrl: pageUrl,
              contentType: ct,
              contentLength: cl,
            );
          }
        });
      },
    );
    tab.controller.addJavaScriptChannel(
      'PageMetaChannel',
      onMessageReceived: (message) {
        final capturedTab = tab;
        _host.decodeJsInBackground(message).then((data) {
          if (data == null || !_host.isMounted) return;
          final ogTitle = data['ogTitle'] as String?;
          final twitterTitle = data['twitterTitle'] as String?;
          final h1Title = data['h1Title'] as String?;
          final ldName = data['ldName'] as String?;
          final docTitle = data['title'] as String? ?? '';
          final resolvedTitle = FilenameService.pickBestTitle([
                ogTitle,
                twitterTitle,
                h1Title,
                ldName,
                docTitle,
              ]) ??
              '';
          final ogImage = data['ogImage'] as String?;
          capturedTab.pageMeta = PageMeta(
            title: resolvedTitle,
            videoWidth: int.tryParse((data['ogVideoWidth'] as String?) ?? ''),
            videoHeight: int.tryParse((data['ogVideoHeight'] as String?) ?? ''),
            structuredName: ldName,
            // Page-supplied URL that the app will later fetch to paint the
            // capture-row thumbnail — same guard as every other bridge URL.
            ogImage: (ogImage != null &&
                    isAllowedBridgeUrl(
                      ogImage,
                      pageUrl: capturedTab.addressController.text,
                    ))
                ? ogImage
                : null,
          );
          if (resolvedTitle.trim().isNotEmpty) {
            final title = resolvedTitle.trim();
            final media = capturedTab.snifferEngine.detectedMedia;
            for (var i = 0; i < media.length; i++) {
              final m = media[i];
              final existing = m.pageTitle?.trim() ?? '';
              if (existing.isEmpty || existing.length + 20 < title.length) {
                media[i] = m.copyWith(pageTitle: title);
              }
            }
          }
          if (_host.isMounted) _host.markNeedsBuild();
        });
      },
    );
    tab.controller.addJavaScriptChannel(
      'IframeSrcChannel',
      onMessageReceived: (message) {
        final url = message.trim();
        // Highest-risk channel: this makes the app fetch a page-chosen URL with
        // app-level network reach. See bridge_url_guard.dart.
        if (isAllowedBridgeUrl(url, pageUrl: tab.addressController.text)) {
          _host.sniffIframeContent(tab, url);
        }
      },
    );

    tab.controller.addJavaScriptChannel(
      'HlsPlaylistChannel',
      onMessageReceived: (message) {
        final capturedTab = tab;
        _host.decodeJsInBackground(message)
            .then((data) {
              if (data == null || !_host.isMounted) return;
              final url = data['url'] as String?;
              final body = data['body'] as String?;
              if (url != null &&
                  body != null &&
                  url.isNotEmpty &&
                  body.isNotEmpty) {
                capturedTab.hlsPlaylistCache[url] = body;
                debugPrint('HlsPlaylistChannel cached body for $url (${body.length} chars, cache size=${capturedTab.hlsPlaylistCache.length})');
              }
            })
            .catchError((e) {
              debugPrint('HlsPlaylistChannel error: $e');
            });
      },
    );
    tab.controller.setOnIframeMediaDetected((url) {
      _sniffIntakeController.sniffBrowserUrl(
        tab,
        url,
        sourcePageUrl: tab.addressController.text,
      );
    });
    tab.controller.setOnDownloadStartRequest((url, suggestedFilename) async {
      await _sniffIntakeController.sniffWithLiveHeaders(
        tab,
        url,
        sourcePageUrl: tab.addressController.text,
      );

      if (!_host.isMounted) return;

      switch (_host.settings.downloadLinkBehavior) {
        case DownloadLinkBehavior.capture:
          _host.showSnack(
            suggestedFilename != null
                ? 'Captured $suggestedFilename — open the capture tray to add it to the queue.'
                : 'URL captured — open the capture tray to add it to the queue.',
          );
        case DownloadLinkBehavior.autoDownload:
          await _host.handleEnqueueDownload(tab, url, suggestedFilename);
        case DownloadLinkBehavior.ask:
          _host.handleDownloadPrompt(tab, url, suggestedFilename);
        case DownloadLinkBehavior.block:
          break;
      }

      _sniffIntakeController.scheduleMediaRebuild();
      _sniffIntakeController.scheduleMediaSave(tab);
    });

    tab.mediaSubscription?.cancel();
    tab.mediaSubscription = tab.snifferEngine.onMediaDetected.listen((media) {
      if (!_host.isMounted) return;
      if (media.type != MediaType.video && media.type != MediaType.playlist) {
        return;
      }
      if (tab != _host.activeTab) return;
      if (!_host.mediaBelongsToActiveTab(media)) return;
      if (_host.shouldReplaceVideo(media)) {
        final prevUrl = _host.latestVideoMedia?.url;
        _host.latestVideoMedia = media;
        if (prevUrl != media.url &&
            !_host.settings.replaceSitePlayer &&
            _host.isMounted) {
          _host.markNeedsBuild();
        }
      }
    });
  }
}

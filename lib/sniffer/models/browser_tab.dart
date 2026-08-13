import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../downloader/headless_webview_fetcher.dart';
import '../browser_controller.dart';
import '../media_sniffer_engine.dart';
import 'page_meta.dart';
import 'sniffed_media.dart';

class BrowserTab {
  final String id;
  final SnifferBrowserController controller;
  final MediaSnifferEngine snifferEngine;
  final TextEditingController addressController;
  final bool ownsEngine;
  final bool ownsController;
  Timer? videoPollTimer;
  StreamSubscription<SniffedMedia>? mediaSubscription;
  String? userAgent;
  String? title;
  String? currentUrl;
  /// Last *fully-loaded* main-frame URL, updated on `onPageFinished`.
  /// Invisible JS navigations (ad insertion, analytics `location.href`
  /// reassignments) and SPA `pushState` route changes never reach
  /// `onPageFinished`, so this stays pinned to the previous real page. Used
  /// by `SnifferScreen.setOnPageStarted` to decide whether to clear the
  /// media cache — see the "Page-lifecycle guard" section of the flow doc.
  String? committedMainFrameUrl;
  String? groupName;
  /// Optional explicit color-index override (0..7) for the group. When
  /// `null` the color is derived from the group name via
  /// [TabGroupPalette.forName]. Set when the user picks a swatch or
  /// when restoring a tab whose group had an explicit color override.
  int? groupColorIndex;
  /// True when this tab was added to its group automatically (because
  /// the group's `autoHost` matched the URL host). The flag lets the
  /// system avoid re-adding a tab that the user has explicitly removed
  /// from the group.
  bool autoGrouped = false;
  bool canGoBack = false;
  bool canGoForward = false;
  bool isLoading = false;
  int progress = 0;
  /// One-shot Play-compliance snackbar when the user lands on a restricted page.
  bool complianceNoticeShown = false;

  /// True for ephemeral preview tabs (long-press link → Preview). They are
  /// excluded from tab persistence and the tab carousel, and are always
  /// closed when the preview is dismissed — they never become real tabs.
  bool isPreview = false;

  /// Play channel: when false, all media sniffing is hard-off for this tab
  /// (restricted site). URL-level [RestrictedMediaPolicy.isBlocked] remains a
  /// backstop for paste/queue/CDN. Default true (sniffing allowed).
  bool sniffingEnabled = true;

  PageMeta pageMeta = const PageMeta();

  /// Per-tab cache of HLS playlist response bodies captured by
  /// browser_guard.js. Keyed by URL, value is the raw playlist text.
  /// Cleared on each page navigation.
  Map<String, String> hlsPlaylistCache = {};

  /// Per-tab cache of Authorization headers captured during sniffing.
  /// Keyed by media URL. Populated by [_sniffWithLiveHeaders] so the
  /// header survives the sanitization in [sanitizeSniffedMediaHeaders]
  /// and can be re-added at download time. Cleared on each page navigation.
  Map<String, String> authHeaderCache = {};

  /// Per-tab set of iframe source URLs already fetched for media sniffing.
  /// Kept per tab (not shared) so a background tab that loads the same iframe
  /// URL as a previously-fetched tab still gets sniffed with its own cookies
  /// and session. Cleared on each page navigation (via `onPageStarted`) and
  /// discarded with the tab when it is disposed, so preview tabs and restored
  /// tabs naturally start with an empty set.
  final Set<String> fetchedIframeSrcs = {};

  /// Headless WebView fetcher used as the last-resort tier for fetching
  /// HLS/DASH playlist bodies. Created lazily by [TabLifecycleController]
  /// and disposed when the tab is closed. Uses same-origin XHR from the
  /// CDN domain to bypass CORS and Cloudflare WAF.
  HeadlessWebViewFetcher? headlessFetcher;

  /// True after deferred cold-start work has run for this tab (adblock
  /// configure, sniffed-media cache load, initial URL navigation).
  /// Background tabs restored at launch leave this false until first
  /// activation so Secure Folder / large tab lists do not freeze startup.
  bool startupReady = false;

  /// When false, [BrowserWidget] must not seed [initialUrl] from the
  /// address bar — lets cold start mount a blank WebView first, then
  /// navigate after the UI frame and download-hold settle.
  bool canSeedWebViewUrl = true;

  BrowserTab({
    required this.id,
    required this.controller,
    required this.snifferEngine,
    required this.addressController,
    this.ownsEngine = true,
    this.ownsController = true,
    this.groupName,
  });

  void dispose() {
    videoPollTimer?.cancel();
    mediaSubscription?.cancel();
    addressController.dispose();
    headlessFetcher?.dispose();
    snifferEngine.clearCache();
    if (ownsEngine) {
      snifferEngine.dispose();
    }
    if (ownsController) {
      controller.dispose();
    }
  }

  void attachAddressListener(void Function() listener) {
    // Idempotent: remove first so double-setup on tab restore is safe.
    addressController.removeListener(listener);
    addressController.addListener(listener);
  }

  void detachAddressListener(void Function() listener) {
    addressController.removeListener(listener);
  }
}

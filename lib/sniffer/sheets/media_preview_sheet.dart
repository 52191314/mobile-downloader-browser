// Standalone library — extracted from `sniffer_screen.dart` during Phase 5 of
// the refactorization. Provides the preview flow for a captured
// [SniffedMedia] (`showMediaPreview`). The original `_showMediaPreview`
// method resolved the URL/headers, then either pushed `PipPlayerScreen`
// (for video/audio) or `MediaPreviewWidget` (for everything else), and
// forwarded a "download" result to `_showAddQueueDialog`.
//
// All dependencies that used to live on `_SnifferScreenState` are now
// passed in explicitly as callbacks. The function is intentionally a
// **standalone top-level function** (NOT `part of`).

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:aurora_downloader/sniffer/aurora_video_player.dart';
import 'package:aurora_downloader/sniffer/media_preview_widget.dart';
import 'package:aurora_downloader/sniffer/player/aurora_player_screen.dart';
import 'package:aurora_downloader/sniffer/player/playback_engine.dart';
import 'package:aurora_downloader/sniffer/player/playback_source.dart';
import 'package:aurora_downloader/sniffer/models/browser_tab.dart';
import 'package:aurora_downloader/sniffer/models/sniffed_media.dart';

/// Resolves the live URL/headers for [media] and shows either the
/// in-app PIP player (video/audio) or the read-only media preview
/// widget (everything else). When the user taps "Download" inside the
/// preview, [onAddToQueue] is invoked with the resolved media.
///
/// Replaces the body of `_SnifferScreenState._showMediaPreview`.
///
/// [qualityVariants] (when 2+) are shown as an in-player quality picker.
/// Headers are re-resolved via the same cookie/CDN path on quality switch.
Future<void> showMediaPreview(
  BuildContext context,
  SniffedMedia media, {
  required BrowserTab activeTab,
  required bool Function() isMounted,
  required Future<Map<String, String>> Function(String url) getCookiesForUrl,
  /// Optional multi-host cookie collector (media URL + page URL). When
  /// provided, used instead of a single [getCookiesForUrl] call so CDN
  /// playback receives both media-host and page-session cookies.
  Future<Map<String, String>> Function({
    required String mediaUrl,
    String? pageUrl,
  })? getPlaybackCookies,
  required Map<String, String> Function({
    required BrowserTab tab,
    required SniffedMedia media,
    required Map<String, String> cookieHeaders,
    String? currentUrl,
  }) buildSniffedDownloadHeaders,
  required Future<String> Function(String url, Map<String, String> headers)
      refreshM3u8IfNeeded,
  required Future<void> Function(SniffedMedia media) onAddToQueue,
  /// Alternate renditions for the in-player quality picker.
  List<SniffedMedia> qualityVariants = const [],
  /// Backend the player opens with. The user can switch inside the player when
  /// a stream will not start; [onEngineChanged] persists that choice.
  PlaybackEngineKind engine = PlaybackEngineKind.videoPlayer,
  ValueChanged<PlaybackEngineKind>? onEngineChanged,
  /// Saves [media] to the Videos subpage of Favorites. Owns its own free-tier
  /// gate and user feedback; this sheet just hands the media over.
  Future<void> Function(SniffedMedia media)? onSaveVideoFavorite,
  /// Records a playback in the Videos subpage of History.
  void Function(SniffedMedia media)? onRecordVideoPlay,
}) async {
  showDialog(
    context: context,
    barrierDismissible: false,
    // Block system back during header resolution: barrierDismissible only
    // stops barrier taps, NOT the back button. If the user backs out while
    // the loading dialog is up, the later Navigator.pop(context) would pop
    // whatever is on top (in the worst case the root home route).
    builder: (ctx) => PopScope(
      canPop: false,
      child: const Center(child: CircularProgressIndicator()),
    ),
  );

  String resolvedUrl = media.url;
  Map<String, String> resolvedHeaders = {};
  String? pageUrl;
  String? currentUrl;
  try {
    currentUrl = await activeTab.controller.currentUrl();
    final sourcePage = media.sourcePageUrl;
    pageUrl = (sourcePage != null && sourcePage.isNotEmpty)
        ? sourcePage
        : (currentUrl ?? activeTab.addressController.text);

    resolvedHeaders = await _resolvePlaybackHeaders(
      mediaUrl: media.url,
      media: media,
      activeTab: activeTab,
      pageUrl: pageUrl,
      currentUrl: currentUrl,
      getCookiesForUrl: getCookiesForUrl,
      getPlaybackCookies: getPlaybackCookies,
      buildSniffedDownloadHeaders: buildSniffedDownloadHeaders,
    );

    if (media.type == MediaType.video ||
        media.type == MediaType.audio ||
        media.type == MediaType.playlist) {
      resolvedUrl = await refreshM3u8IfNeeded(media.url, resolvedHeaders);
    }
  } catch (_) {}

  if (!isMounted()) return;
  Navigator.pop(context);

  final finalMedia = media.copyWith(
    url: resolvedUrl,
    headers: resolvedHeaders,
  );

  if (finalMedia.type == MediaType.video ||
      finalMedia.type == MediaType.audio ||
      finalMedia.type == MediaType.playlist) {
    final qualityOptions = _playerQualityOptions(
      playing: finalMedia,
      variants: qualityVariants,
    );
    final effectivePageUrl = pageUrl;
    final effectiveCurrentUrl = currentUrl;

    // Recorded on open rather than on completion: the user asked for this
    // video, and a stream they abandoned after ten seconds is still one they
    // will want to find again.
    onRecordVideoPlay?.call(finalMedia);

    Future<Map<String, String>> resolveFor(String url) async {
      // Rebuild Cookie/Referer/Origin for the newly selected CDN URL.
      SniffedMedia variant = finalMedia.copyWith(url: url);
      for (final v in qualityVariants) {
        if (v.url == url) {
          variant = v;
          break;
        }
      }
      return _resolvePlaybackHeaders(
        mediaUrl: url,
        media: variant,
        activeTab: activeTab,
        pageUrl: effectivePageUrl ??
            variant.sourcePageUrl ??
            activeTab.addressController.text,
        currentUrl: effectiveCurrentUrl,
        getCookiesForUrl: getCookiesForUrl,
        getPlaybackCookies: getPlaybackCookies,
        buildSniffedDownloadHeaders: buildSniffedDownloadHeaders,
      );
    }
    // Automatically pause onsite webpage HTML5 video & audio elements before
    // launching custom player to prevent dual playback, dual audio, and data waste.
    try {
      await activeTab.controller.evaluateJavaScript('''
(function() {
  try {
    var media = document.querySelectorAll('video, audio');
    for (var i = 0; i < media.length; i++) {
      try { media[i].pause(); } catch(e) {}
    }
  } catch(e) {}
})();
''');
    } catch (_) {}

    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => AuroraPlayerScreen(
          initialEngine: engine,
          onEnginePreferenceChanged: onEngineChanged,
          resolveHeadersForUrl: resolveFor,
          onDownload: () => Navigator.pop(context, 'download'),
          onFavorite: onSaveVideoFavorite == null
              ? null
              : (_) => onSaveVideoFavorite(finalMedia),
          source: PlaybackSource(
            url: finalMedia.url,
            title: finalMedia.name.isNotEmpty
                ? finalMedia.name
                : 'Sniffed media',
            headers: finalMedia.headers,
            sourcePageUrl: finalMedia.sourcePageUrl,
            variants: [
              for (final q in qualityOptions)
                PlaybackVariant(
                  url: q.url,
                  label: q.label,
                  height: q.height,
                  bandwidth: q.bandwidth,
                ),
            ],
          ),
        ),
      ),
    );
    if (!isMounted()) return;
    if (result == 'download') {
      await onAddToQueue(finalMedia);
    }
    return;
  }
  final result = await Navigator.push<String>(
    context,
    MaterialPageRoute(builder: (_) => MediaPreviewWidget(media: finalMedia)),
  );
  if (!isMounted()) return;
  if (result == 'download') {
    await onAddToQueue(finalMedia);
  }
}

/// Shared cookie + Referer/Origin assembly used for first play and mid-stream
/// quality switches so capture-sheet preview and the floating player share
/// the same CDN-surviving path.
Future<Map<String, String>> _resolvePlaybackHeaders({
  required String mediaUrl,
  required SniffedMedia media,
  required BrowserTab activeTab,
  required String pageUrl,
  required String? currentUrl,
  required Future<Map<String, String>> Function(String url) getCookiesForUrl,
  Future<Map<String, String>> Function({
    required String mediaUrl,
    String? pageUrl,
  })? getPlaybackCookies,
  required Map<String, String> Function({
    required BrowserTab tab,
    required SniffedMedia media,
    required Map<String, String> cookieHeaders,
    String? currentUrl,
  }) buildSniffedDownloadHeaders,
}) async {
  // Prefer multi-host cookie merge (media CDN + page session) so
  // ExoPlayer/VideoPlayer gets the same jar the WebView used.
  Map<String, String> cookieHeaders;
  if (getPlaybackCookies != null) {
    cookieHeaders = await getPlaybackCookies(
      mediaUrl: mediaUrl,
      pageUrl: pageUrl,
    );
  } else {
    cookieHeaders = await getCookiesForUrl(mediaUrl);
  }

  final resolvedHeaders = buildSniffedDownloadHeaders(
    tab: activeTab,
    media: media.copyWith(url: mediaUrl),
    cookieHeaders: cookieHeaders,
    currentUrl: currentUrl,
  );

  // Ensure page Referer/Origin for playback when builders left them empty.
  // Do not overwrite host-specific fixes (e.g. surrit.com same-origin
  // Referer from _normalizeHeadersForUrl).
  final hasReferer = resolvedHeaders.keys.any(
    (k) => k.toLowerCase() == 'referer',
  );
  final hasOrigin = resolvedHeaders.keys.any(
    (k) => k.toLowerCase() == 'origin',
  );
  if (pageUrl.isNotEmpty && !hasReferer) {
    resolvedHeaders['Referer'] = pageUrl;
  }
  if (pageUrl.isNotEmpty && !hasOrigin) {
    final pageUri = Uri.tryParse(pageUrl);
    if (pageUri != null &&
        pageUri.host.isNotEmpty &&
        pageUri.scheme.isNotEmpty) {
      resolvedHeaders['Origin'] = '${pageUri.scheme}://${pageUri.host}';
    }
  }
  return resolvedHeaders;
}

List<PlayerQualityOption> _playerQualityOptions({
  required SniffedMedia playing,
  required List<SniffedMedia> variants,
}) {
  final byUrl = <String, SniffedMedia>{};
  for (final v in variants) {
    if (v.url.isNotEmpty) byUrl[v.url] = v;
  }
  if (playing.url.isNotEmpty) {
    byUrl.putIfAbsent(playing.url, () => playing);
  }
  if (byUrl.length < 2) return const [];

  final list = byUrl.values.toList()
    ..sort((a, b) {
      final ah = a.height ?? 0;
      final bh = b.height ?? 0;
      if (ah != bh) return bh.compareTo(ah);
      return (b.bandwidth ?? 0).compareTo(a.bandwidth ?? 0);
    });

  return list
      .map(
        (m) => PlayerQualityOption(
          url: m.url,
          label: _qualityLabel(m),
          height: m.height,
          bandwidth: m.bandwidth,
        ),
      )
      .toList();
}

String _qualityLabel(SniffedMedia m) {
  if (m.height != null && m.height! > 0) return '${m.height}p';
  final res = RegExp(
    r'(?<!\d)(2160|1440|1080|720|540|480|360)p(?!\d)',
    caseSensitive: false,
  ).firstMatch('${m.name} ${m.url}');
  if (res != null) return '${res.group(1)}p';
  if (m.bandwidth != null && m.bandwidth! > 0) {
    final bps = m.bandwidth!;
    if (bps >= 1_000_000) {
      return '${(bps / 1_000_000).toStringAsFixed(1)} Mbps';
    }
    if (bps >= 1_000) return '${(bps / 1_000).toStringAsFixed(0)} Kbps';
    return '$bps bps';
  }
  if (m.name.isNotEmpty) return m.name;
  return 'Default';
}


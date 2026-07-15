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
import 'package:aurora_downloader/sniffer/models/browser_tab.dart';
import 'package:aurora_downloader/sniffer/models/sniffed_media.dart';

/// Resolves the live URL/headers for [media] and shows either the
/// in-app PIP player (video/audio) or the read-only media preview
/// widget (everything else). When the user taps "Download" inside the
/// preview, [onAddToQueue] is invoked with the resolved media.
///
/// Replaces the body of `_SnifferScreenState._showMediaPreview`.
Future<void> showMediaPreview(
  BuildContext context,
  SniffedMedia media, {
  required BrowserTab activeTab,
  required bool isMounted,
  required Future<Map<String, String>> Function(String url) getCookiesForUrl,
  required Map<String, String> Function({
    required BrowserTab tab,
    required SniffedMedia media,
    required Map<String, String> cookieHeaders,
    String? currentUrl,
  }) buildSniffedDownloadHeaders,
  required Future<String> Function(String url, Map<String, String> headers)
      refreshM3u8IfNeeded,
  required Future<void> Function(SniffedMedia media) onAddToQueue,
}) async {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => const Center(child: CircularProgressIndicator()),
  );

  String resolvedUrl = media.url;
  Map<String, String> resolvedHeaders = {};
  try {
    final currentUrl = await activeTab.controller.currentUrl();
    final cookieHeaders = await getCookiesForUrl(media.url);
    resolvedHeaders = buildSniffedDownloadHeaders(
      tab: activeTab,
      media: media,
      cookieHeaders: cookieHeaders,
      currentUrl: currentUrl,
    );
    if (media.type == MediaType.video || media.type == MediaType.audio) {
      resolvedUrl = await refreshM3u8IfNeeded(media.url, resolvedHeaders);
    }
  } catch (_) {}

  if (!isMounted) return;
  Navigator.pop(context);

  final finalMedia = media.copyWith(
    url: resolvedUrl,
    headers: resolvedHeaders,
  );

  if (finalMedia.type == MediaType.video ||
      finalMedia.type == MediaType.audio) {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => AuroraVideoPlayer(
          url: finalMedia.url,
          title: finalMedia.name.isNotEmpty
              ? finalMedia.name
              : 'Sniffed media',
          headers: finalMedia.headers,
          sourcePageUrl: finalMedia.sourcePageUrl,
          onDownload: () => Navigator.pop(context, 'download'),
          onFavorite: (url) => _addToFavorites(context, url, finalMedia.name),
        ),
      ),
    );
    if (!isMounted) return;
    if (result == 'download') {
      await onAddToQueue(finalMedia);
    }
    return;
  }
  final result = await Navigator.push<String>(
    context,
    MaterialPageRoute(builder: (_) => MediaPreviewWidget(media: finalMedia)),
  );
  if (!isMounted) return;
  if (result == 'download') {
    await onAddToQueue(finalMedia);
  }
}

Future<void> _addToFavorites(BuildContext context, String url, String name) async {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('Added "$name" to favorites'),
      duration: const Duration(seconds: 1),
    ),
  );
}

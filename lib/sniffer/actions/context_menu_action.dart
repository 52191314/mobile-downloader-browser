// Standalone library — extracted from `sniffer_screen.dart` during Phase 5 of
// the refactorization. Provides the long-press element context menu flow
// (`showElementContextMenu`), the "open target in tab" helper
// (`openContextTarget`), and the "send target to the download queue" helper
// (`addContextTargetToQueue`).
//
// These functions are intentionally **standalone top-level functions** (NOT
// `part of`) so they can be unit-tested in isolation and so the
// `_SnifferScreenState` class no longer has to absorb all the menu logic.
// All state that the originals read from the class is now passed in
// explicitly via the call-site (the state class wraps each call).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:aurora_downloader/downloader/downloader.dart';
import 'package:aurora_downloader/platform/public_downloads_service.dart';
import 'package:aurora_downloader/sniffer/hls_playlist_cache_lookup.dart';
import 'package:aurora_downloader/sniffer/models/browser_tab.dart';
import 'package:aurora_downloader/sniffer/sniffer_url_utils.dart';
import 'package:aurora_downloader/sniffer/token_refresh_service.dart';
import 'package:aurora_downloader/sniffer/sheets/duplicate_download_dialog.dart';

/// Trims a JSON-decoded value to a non-empty string, or returns `null`.
String? _contextString(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

enum ContextMenuTargetKind {
  ignored,
  page,
  textSelection,
  link,
  media,
  linkedMedia,
}

ContextMenuTargetKind classifyContextMenuPayload(Map<String, dynamic> data) {
  final href = _contextString(data['href']);
  final src = _contextString(data['src']);
  final selectedText = _contextString(data['selectedText']);
  final tagName = _contextString(data['tagName']);
  final selector = _contextString(data['selector']);

  // Defense-in-depth for the old popup path. `postLinkContext()` emitted an
  // anchor-shaped payload without a real selector; popups must never open the
  // element context sheet.
  if (href != null && src == null && selectedText == null && tagName == 'a' && selector == null) {
    return ContextMenuTargetKind.ignored;
  }

  if (href != null && src != null) return ContextMenuTargetKind.linkedMedia;
  if (href != null) return ContextMenuTargetKind.link;
  if (src != null) return ContextMenuTargetKind.media;
  if (selectedText != null) return ContextMenuTargetKind.textSelection;
  return ContextMenuTargetKind.page;
}

/// Truncates a URL for display, showing host and the tail of the path.
String _truncateUrl(String url, {int maxLength = 35}) {
  if (url.length <= maxLength) return url;
  final uri = Uri.tryParse(url);
  if (uri != null && uri.host.isNotEmpty) {
    final host = uri.host;
    final path = uri.path;
    if (path.length > 15) {
      return '$host/...${path.substring(path.length - 12)}';
    }
    return '$host$path';
  }
  return '${url.substring(0, maxLength - 3)}...';
}



/// Displays the long-press / context-menu sheet for a picked page element.
///
/// Replaces the body of `_SnifferScreenState._showElementContextMenu`. The
/// original method only delegated to other private helpers — those are
/// surfaced as named callbacks below so the state class can keep its
/// own copies (e.g. `_isContextMenuShowing`, `_openNewTab`, …).
void showElementContextMenu(
  BuildContext context,
  String rawMessage, {
  required BrowserTab activeTab,
  required bool isContextMenuShowing,
  required void Function(bool) onContextMenuShowingChanged,
  required Future<void> Function(String url) onHandlePickedElement,
  required Future<void> Function(String value, String message) onCopyText,
  required void Function({String? url, bool switchToTab}) onOpenNewTab,
  required Future<void> Function(String url) onOpenPreview,
  required Future<void> Function() onCopyCurrentUrl,
  required Future<void> Function() onToggleFavorite,
  required Future<void> Function() onSaveCurrentPage,
  required void Function(String message) onShowSnack,
  required Future<void> Function(Uri uri) onLoadUrl,
  required void Function(String targetUrl, String? label) onAddToQueue,
  required Future<void> Function(String text) onTranslateText,
  required Future<void> Function(String text) onSearchText,
  required bool isCurrentPageFavorited,
  required bool isMounted,
}) {
  if (!isMounted) return;
  Map<String, dynamic>? data;
  try {
    final decoded = jsonDecode(rawMessage);
    if (decoded is Map) {
      data = Map<String, dynamic>.from(decoded);
    }
  } catch (_) {
    return;
  }
  if (data == null) return;
  final href = _contextString(data['href']);
  final src = _contextString(data['src']);
  final text = _contextString(data['text']);
  final selectedText = _contextString(data['selectedText']);
  final tagName = _contextString(data['tagName']);
  final selector = _contextString(data['selector']);
  final pageUrl = _contextString(data['pageUrl']);
  final pageTitle = _contextString(data['pageTitle']);
  final targetKind = classifyContextMenuPayload(data);
  if (targetKind == ContextMenuTargetKind.ignored) return;
  final targetUrl = href ?? src;
  final label =
      text ?? selectedText ?? pageTitle ?? tagName ?? 'Page element';
  final isFavorite = isCurrentPageFavorited;
  final hasLink = targetKind == ContextMenuTargetKind.link ||
      targetKind == ContextMenuTargetKind.linkedMedia;
  final hasMedia = targetKind == ContextMenuTargetKind.media ||
      targetKind == ContextMenuTargetKind.linkedMedia;
  final hasTextSelection = selectedText != null;
  final isPageOnly = targetKind == ContextMenuTargetKind.page;

  if (isContextMenuShowing) return;
  onContextMenuShowingChanged(true);

  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (ctx) {
      final tab = activeTab;
      final blockPayload = <String, String>{
        'href': href ?? '',
        'src': src ?? '',
        'selector': selector ?? '',
        'host': Uri.tryParse(pageUrl ?? '')?.host ?? '',
      };

      Widget section(String title, List<Widget> tiles) {
        if (tiles.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 14, 12, 4),
              child: Text(
                title,
                style: Theme.of(ctx).textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                    ),
              ),
            ),
            ...tiles,
            const Divider(height: 8),
          ],
        );
      }

      Widget item(
        IconData icon,
        String title,
        VoidCallback onTap,
      ) {
        return ListTile(
          dense: true,
          leading: Icon(icon),
          title: Text(title),
          onTap: () {
            Navigator.pop(ctx);
            onTap();
          },
        );
      }

      void openTarget(String url) {
        openContextTarget(
          context,
          tab: tab,
          targetUrl: url,
          onLoadUrl: onLoadUrl,
          onShowSnack: onShowSnack,
          isMounted: isMounted,
        );
      }

      final textActions = <Widget>[
        if (selectedText != null) ...[
          item(
            Icons.content_copy,
            'Copy text',
            () => unawaited(
              onCopyText(selectedText, 'Selected text copied.'),
            ),
          ),
          item(
            Icons.search,
            'Web Search',
            () => unawaited(onSearchText(selectedText)),
          ),
          item(
            Icons.translate,
            'Translate',
            () => unawaited(onTranslateText(selectedText)),
          ),
          item(
            Icons.share,
            'Share text',
            () => unawaited(PublicDownloadsService.shareUrl(selectedText)),
          ),
        ],
      ];

      final linkActions = <Widget>[
        if (href != null) ...[
          item(
            Icons.visibility_outlined,
            'Preview',
            () => unawaited(onOpenPreview(href)),
          ),
          item(Icons.open_in_browser, 'Open link', () => openTarget(href)),
          item(
            Icons.tab,
            'Open in new tab',
            () => onOpenNewTab(url: href, switchToTab: true),
          ),
          item(
            Icons.tab_unselected,
            'Open in background tab',
            () => onOpenNewTab(url: href, switchToTab: false),
          ),
          if (text != null && text.trim().isNotEmpty && text.trim() != href.trim())
            item(
              Icons.short_text,
              'Copy link text',
              () => unawaited(onCopyText(text, 'Link text copied.')),
            ),
          item(
            Icons.copy,
            'Copy link URL',
            () => unawaited(onCopyText(href, 'Link URL copied.')),
          ),
          item(
            Icons.share,
            'Share link',
            () => unawaited(PublicDownloadsService.shareUrl(href)),
          ),
          item(Icons.open_in_new, 'Open in system browser', () {
            PublicDownloadsService.openUrl(href);
          }),
          item(Icons.history, 'Add link to queue', () {
            onAddToQueue(href, text ?? pageTitle);
          }),
        ],
      ];

      final mediaActions = <Widget>[
        if (src != null) ...[
          item(Icons.image, 'Open media', () => openTarget(src)),
          item(
            Icons.tab,
            'Open media in new tab',
            () => onOpenNewTab(url: src, switchToTab: true),
          ),
          item(
            Icons.copy,
            'Copy media URL',
            () => unawaited(onCopyText(src, 'Media URL copied.')),
          ),
          item(
            Icons.share,
            'Share media URL',
            () => unawaited(PublicDownloadsService.shareUrl(src)),
          ),
          item(
            Icons.image_search,
            'Search image (Google Lens)',
            () => onOpenNewTab(
              url: 'https://lens.google.com/uploadbyurl?url=${Uri.encodeComponent(src)}',
              switchToTab: true,
            ),
          ),
          item(
            Icons.travel_explore,
            'Search image (Yandex)',
            () => onOpenNewTab(
              url: 'https://yandex.com/images/search?rpt=imageview&url=${Uri.encodeComponent(src)}',
              switchToTab: true,
            ),
          ),
          item(Icons.download, 'Download media', () {
            onAddToQueue(src, text ?? pageTitle);
          }),
        ],
      ];

      final pageActions = <Widget>[
        item(
          Icons.copy,
          'Copy page URL',
          () => unawaited(onCopyCurrentUrl()),
        ),
        if (pageUrl != null && pageUrl.isNotEmpty)
          item(
            Icons.share,
            'Share page URL',
            () => unawaited(PublicDownloadsService.shareUrl(pageUrl)),
          ),
        item(
          isFavorite ? Icons.star : Icons.star_border,
          isFavorite ? 'Remove favorite' : 'Add favorite',
          () => unawaited(onToggleFavorite()),
        ),
        item(
          Icons.save_alt,
          'Save page',
          () => unawaited(onSaveCurrentPage()),
        ),
      ];

      final elementTools = <Widget>[
        if (selector != null || href != null || src != null)
          item(Icons.ads_click, 'Block this element', () {
            unawaited(onHandlePickedElement(jsonEncode(blockPayload)));
          }),
      ];

      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 18),
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _truncateUrl(targetUrl ?? selectedText ?? pageUrl ?? 'Page element'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            if (hasTextSelection) section('Text selection', textActions),
            if (hasLink) section('Link', linkActions),
            if (hasMedia) section('Media', mediaActions),
            if (isPageOnly) section('Page', pageActions),
            section('Tools', elementTools),
          ],
        ),
      );
    },
  ).whenComplete(() {
    onContextMenuShowingChanged(false);
  });
}

/// Opens [targetUrl] in the given [tab] using the host-settings-aware
/// loader. Equivalent to the body of `_SnifferScreenState._openContextTarget`.
void openContextTarget(
  BuildContext context, {
  required BrowserTab tab,
  required String targetUrl,
  required Future<void> Function(Uri uri) onLoadUrl,
  required void Function(String message) onShowSnack,
  required bool isMounted,
}) {
  final uri = Uri.tryParse(targetUrl);
  if (uri == null || !uri.hasScheme) {
    onShowSnack('Could not open target.');
    return;
  }
  // onLoadUrl → _loadUrlWithHostSettings / loadRequest already routes
  // external app schemes (tg:, intent://, …) out of the WebView.
  unawaited(onLoadUrl(uri));
}

/// Adds a context-menu target to the download queue.
///
/// This is the body of `_SnifferScreenState._addContextTargetToQueue` with
/// every dependency injected through the parameter list. The state class
/// still owns the queue, the disk paths, the cookies, the dialog prompts,
/// and the HLS refresh logic — they are exposed as callbacks below.
Future<void> addContextTargetToQueue(
  BuildContext context,
  String targetUrl,
  String? label, {
  required BrowserTab activeTab,
  required String? baseDir,
  required String? baseTemp,
  required String Function(String? label, String targetUrl)
      downloadFilenameFor,
  required Future<Map<String, String>> Function(String url) getCookiesForUrl,
  required DownloadQueue downloadQueue,
  required Future<DuplicateDialogResult> Function(BuildContext context, String filename)
      showDuplicatePrompt,
  required void Function(String message) showSnack,
  required bool isMounted,
}) async {
  try {
    final filename = downloadFilenameFor(label, targetUrl);
    final cookieHeaders = await getCookiesForUrl(targetUrl);
    final taskHeaders = <String, String>{
      'User-Agent': downloadUserAgent(targetUrl, activeTab),
      ...activeTab.controller.currentHeaders,
      ...cookieHeaders,
    };
    final curUrl = await activeTab.controller.currentUrl();

    if (!hasHeader(taskHeaders, 'Referer')) {
      final referer = firstNonEmpty([
        curUrl,
        activeTab.addressController.text,
      ]);
      if (referer != null) {
        taskHeaders['Referer'] = referer;
      }
    }

    normalizeHeadersForUrl(
      taskHeaders,
      targetUrl,
      currentUrl: curUrl,
      addressText: activeTab.addressController.text,
    );

    final tab = activeTab;
    final task = DownloadTask(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      url: targetUrl,
      sourcePageUrl: curUrl,
      savePath:
          '${baseDir ?? '.'}${Platform.pathSeparator}completed${Platform.pathSeparator}$filename',
      tempDir:
          '${baseTemp ?? '.'}${Platform.pathSeparator}temp_${DateTime.now().millisecondsSinceEpoch}',
      headers: taskHeaders,
    );
    task.onTokenExpired = TokenRefreshService.gatedClosure(
      task,
      ({bool forceReload = false}) => TokenRefreshService.refresh(task),
    );
    task.fetchViaWebView = (url, {headers}) =>
        tab.controller.fetchPlaylistBodyViaJavaScript(url);
    task.hlsPlaylistCache =
        (url) => lookupHlsPlaylistCache(tab.hlsPlaylistCache, url);
    task.fetchBinaryViaWebView =
        (url) => tab.controller.fetchBinaryViaJavaScript(url);
    task.cookieProvider = (url) =>
        tab.controller.getCookiesForDomain(url: url);

    bool force = false;
    if (downloadQueue.urlExists(targetUrl) ||
        downloadQueue.samePageFilenameExists(filename, curUrl)) {
      if (!isMounted) return;
      // ignore: use_build_context_synchronously
      final result = await showDuplicatePrompt(context, filename);
      if (result.choice == DuplicateChoice.skip) return;
      if (result.choice == DuplicateChoice.replace) {
        final existing = downloadQueue.getTaskByUrl(targetUrl);
        if (existing != null) {
          await downloadQueue.cancelTaskAsync(existing.id);
        }
      }
      force = true;
    }
    downloadQueue.addTask(task, force: force);
    showSnack('Added "$filename" to queue.');
  } catch (e) {
    // ignore: avoid_print
    print('[SnifferScreen] Failed to add "$targetUrl" to queue: $e');
    if (isMounted) {
      showSnack('Could not add download: ${e.toString()}');
    }
  }
}

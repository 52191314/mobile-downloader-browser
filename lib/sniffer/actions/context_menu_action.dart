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

import 'package:aurora_downloader/downloader/models.dart';
import 'package:aurora_downloader/platform/public_downloads_service.dart';
import 'package:aurora_downloader/sniffer/models/browser_tab.dart';
import 'package:aurora_downloader/sniffer/sniffer_url_utils.dart';

/// Trims a JSON-decoded value to a non-empty string, or returns `null`.
String? _contextString(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

/// Case-insensitive header-name lookup, matching `_hasHeader` in the
/// original state class.
bool _hasHeader(Map<String, String> headers, String name) {
  return headers.keys.any((key) => key.toLowerCase() == name.toLowerCase());
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
  required Future<void> Function() onCopyCurrentUrl,
  required Future<void> Function() onToggleFavorite,
  required Future<void> Function() onSaveCurrentPage,
  required void Function(String message) onShowSnack,
  required Future<void> Function(Uri uri) onLoadUrl,
  required void Function(String targetUrl, String? label) onAddToQueue,
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
  final targetUrl = href ?? src;
  final label =
      text ?? selectedText ?? pageTitle ?? tagName ?? 'Page element';
  final isFavorite = isCurrentPageFavorited;

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
                    targetUrl ?? pageUrl ?? 'Page element',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            if (targetUrl != null) ...[
              ListTile(
                leading: const Icon(Icons.open_in_browser),
                title: const Text('Open in Browser'),
                onTap: () {
                  Navigator.pop(ctx);
                  openContextTarget(
                    context,
                    tab: tab,
                    targetUrl: targetUrl,
                    onLoadUrl: onLoadUrl,
                    onShowSnack: onShowSnack,
                    isMounted: isMounted,
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.ads_click),
                title: const Text('Block This Element'),
                onTap: () {
                  Navigator.pop(ctx);
                  unawaited(
                    onHandlePickedElement(jsonEncode(blockPayload)),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('Copy Target URL'),
                onTap: () {
                  Navigator.pop(ctx);
                  unawaited(onCopyText(targetUrl, 'Target URL copied.'));
                },
              ),
              ListTile(
                leading: const Icon(Icons.tab),
                title: const Text('Open in New Tab'),
                onTap: () {
                  Navigator.pop(ctx);
                  onOpenNewTab(url: targetUrl, switchToTab: true);
                },
              ),
              ListTile(
                leading: const Icon(Icons.tab_unselected),
                title: const Text('Open in Background Tab'),
                onTap: () {
                  Navigator.pop(ctx);
                  onOpenNewTab(url: targetUrl, switchToTab: false);
                },
              ),
              ListTile(
                leading: const Icon(Icons.open_in_new),
                title: const Text('Open in System Browser'),
                onTap: () {
                  Navigator.pop(ctx);
                  PublicDownloadsService.openUrl(targetUrl);
                },
              ),
              ListTile(
                leading: const Icon(Icons.history),
                title: const Text('Add to Queue'),
                subtitle: Text(
                  src == null
                      ? 'Download page for later'
                      : 'Download target URL',
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  onAddToQueue(targetUrl, text ?? pageTitle);
                },
              ),
              const Divider(),
            ],
            if (selectedText != null)
              ListTile(
                leading: const Icon(Icons.content_copy),
                title: const Text('Copy Selected Text'),
                onTap: () {
                  Navigator.pop(ctx);
                  unawaited(
                    onCopyText(selectedText, 'Selected text copied.'),
                  );
                },
              ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy Page URL'),
              subtitle: pageUrl == null ? null : Text(pageUrl),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(onCopyCurrentUrl());
              },
            ),
            ListTile(
              leading: Icon(isFavorite ? Icons.star : Icons.star_border),
              title: Text(isFavorite ? 'Remove Favorite' : 'Add Favorite'),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(onToggleFavorite());
              },
            ),
            ListTile(
              leading: const Icon(Icons.save_alt),
              title: const Text('Save Page'),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(onSaveCurrentPage());
              },
            ),
            if (targetUrl == null)
              ListTile(
                leading: const Icon(Icons.ads_click),
                title: const Text('Block This Element'),
                onTap: () {
                  Navigator.pop(ctx);
                  unawaited(
                    onHandlePickedElement(jsonEncode(blockPayload)),
                  );
                },
              ),
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
  required bool Function(String url) urlExists,
  required void Function(DownloadTask task, {bool force}) addTask,
  required Future<bool> Function(BuildContext context, String filename)
      showDuplicatePrompt,
  required void Function(String message) showSnack,
  required Future<String?> Function(
    BrowserTab tab,
    String? sourcePageUrl, {
    bool forceReload,
  }) reloadForFreshUrl,
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

    if (!_hasHeader(taskHeaders, 'Referer')) {
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
    task.onTokenExpired = ({bool forceReload = false}) =>
        reloadForFreshUrl(tab, curUrl, forceReload: forceReload);
    task.fetchViaWebView = (url, {headers}) =>
        tab.controller.fetchViaJavaScript(url, headers: headers);
    task.hlsPlaylistCache = (url) => tab.hlsPlaylistCache[url];
    task.fetchBinaryViaWebView =
        (url) => tab.controller.fetchBinaryViaJavaScript(url);

    bool force = false;
    if (urlExists(targetUrl)) {
      if (!isMounted) return;
      // ignore: use_build_context_synchronously
      final skip = await showDuplicatePrompt(context, filename);
      if (skip) return;
      force = true;
    }
    addTask(task, force: force);
    showSnack('Added "$filename" to queue.');
  } catch (e) {
    // ignore: avoid_print
    print('[SnifferScreen] Failed to add "$targetUrl" to queue: $e');
    if (isMounted) {
      showSnack('Could not add download: ${e.toString()}');
    }
  }
}

import 'dart:io';

import 'package:flutter/material.dart';

import '../downloader/download_rules.dart';
import '../downloader/downloader.dart';
import '../downloader/filename_service.dart';
import '../downloader/url_filename_resolver.dart';
import '../settings/download_settings.dart';
import 'controllers/site_profile_runtime.dart';
import 'hls_playlist_cache_lookup.dart';
import 'models/browser_tab.dart';
import 'models/sniffed_media.dart';
import 'sheets/duplicate_download_dialog.dart';
import 'sniffer_url_utils.dart';
import 'token_refresh_service.dart';

/// Builds a user-facing suggested filename for a captured media item.
String buildSuggestedFilenameForTab({
  required BrowserTab tab,
  required String mediaName,
  required DownloadSettings settings,
  String? mediaUrl,
  SniffedMedia? media,
}) {
  final metaTitle = tab.pageMeta.title.trim();
  final structured = tab.pageMeta.structuredName?.trim() ?? '';
  final tabTitle = tab.title?.trim() ?? '';
  final bestTitle = FilenameService.pickBestTitle([
    metaTitle,
    structured,
    tabTitle,
    media?.pageTitle,
  ]);

  String? explicitQuality;
  if (media != null) {
    final h = media.height;
    final w = media.width;
    if (h != null || w != null) {
      explicitQuality = FilenameService.qualityLabelFrom(
        height: h,
        width: w,
        bandwidth: media.bandwidth,
      );
      if (explicitQuality != null) explicitQuality = '${explicitQuality}p';
    }
  }

  return FilenameService.buildSuggestedFilename(
    mediaName: mediaName,
    mediaUrl: mediaUrl,
    pageTitle: bestTitle,
    mediaPageTitle: media?.pageTitle,
    structuredName: structured.isNotEmpty ? structured : null,
    sourcePageUrl: media?.sourcePageUrl ?? tab.addressController.text,
    width: media?.width,
    height: media?.height,
    bandwidth: media?.bandwidth,
    explicitQuality: explicitQuality,
    includeQualitySuffix: settings.includeQualitySuffix,
    defaultMp4ForVideoHosts: mediaUrl != null && isVideoHostingUrl(mediaUrl),
    isPlaylist: media?.type == MediaType.playlist,
  );
}

/// Resolves a stable download filename from a URL and optional suggestion.
String resolveSuggestedDownloadName({
  required String url,
  required String? suggestedFilename,
  required String Function(String mediaName) buildFromMediaName,
  SniffedMedia? media,
}) {
  final urlExt = extensionFromUrlPath(url);
  if (suggestedFilename != null) {
    if (urlExt.isNotEmpty) {
      final base = suggestedFilename.replaceAll(RegExp(r'\.[^.]+$'), '');
      return '$base$urlExt';
    }
    return suggestedFilename;
  }
  final parsed = Uri.tryParse(url);
  final nameFromUrl = parsed != null
      ? parsed.path
            .split('/')
            .lastWhere((s) => s.isNotEmpty, orElse: () => '')
      : url.split('/').last;
  return buildFromMediaName(
    media?.name ?? (nameFromUrl.isNotEmpty ? nameFromUrl : 'download'),
  );
}

/// Directly enqueues a download without the Add-to-Queue dialog.
///
/// When [silent] is true (batch flows like listing-page crawl), already-queued
/// URLs are skipped quietly instead of prompting, and the per-item "Started
/// downloading" snackbar is suppressed — the caller shows one summary instead.
Future<void> enqueueDirectDownload({
  required BuildContext context,
  required BrowserTab tab,
  required String url,
  required String? suggestedFilename,
  required DownloadQueue downloadQueue,
  required DownloadSettings settings,
  required String? baseDir,
  required String? baseTemp,
  required Future<Map<String, String>> Function(String url) getCookiesForUrl,
  required void Function(String message) showSnack,
  required bool Function() isMounted,
  DownloadRuleEngine? ruleEngine,
  String? pageHost,
  String? mediaTypeForRule,
  bool silent = false,
}) async {
  final media = tab.snifferEngine.detectedMedia
      .where((m) => m.url == url)
      .lastOrNull;
  final currentUrl = await tab.controller.currentUrl() ?? '';

  final urlExt = extensionFromUrlPath(url);
  var suggestedName = resolveSuggestedDownloadName(
    url: url,
    suggestedFilename: suggestedFilename,
    media: media,
    buildFromMediaName: (name) => buildSuggestedFilenameForTab(
      tab: tab,
      mediaName: name,
      mediaUrl: url,
      media: media,
      settings: settings,
    ),
  );
  if (suggestedName.isEmpty) return;

  final cookieHeaders = await getCookiesForUrl(url);
  final headerMap = <String, String>{
    'User-Agent': downloadUserAgent(url, tab),
  };
  mergeHeaders(headerMap, tab.controller.currentHeaders);
  if (media != null) {
    mergeHeaders(headerMap, sanitizeSniffedMediaHeaders(media.headers));
  }
  if (!hasHeader(headerMap, 'Referer')) {
    final ref = firstNonEmpty([
      media?.sourcePageUrl,
      currentUrl,
      tab.addressController.text,
    ]);
    if (ref != null) headerMap['Referer'] = ref;
  }
  mergeHeaders(headerMap, cookieHeaders);
  final cachedAuth = tab.authHeaderCache[url];
  if (cachedAuth != null &&
      cachedAuth.isNotEmpty &&
      !hasHeader(headerMap, 'Authorization')) {
    headerMap['Authorization'] = cachedAuth;
  }

  normalizeHeadersForUrl(
    headerMap,
    url,
    currentUrl: currentUrl,
    addressText: tab.addressController.text,
    sourcePageUrl: media?.sourcePageUrl,
  );

  String? resolvedContentType;
  if (urlExt.isEmpty) {
    final resolved = await resolveFilename(
      url: url,
      headers: headerMap,
      suggestedFilename: suggestedFilename,
    );
    if (resolved.name.isNotEmpty) {
      suggestedName = resolved.name;
    }
    resolvedContentType = resolved.contentType;
  }

  final taskId = DateTime.now().millisecondsSinceEpoch.toString();
  var saveDir = '${baseDir ?? '.'}${Platform.pathSeparator}completed';

  // --- Site profile overrides (download folder + custom headers) ---
  // Match on source page host when available so download rules follow the
  // browsing site, not a CDN host for the media URL.
  final profiles = await loadProfiles();
  final profileMatchUrl = firstNonEmpty([
        media?.sourcePageUrl,
        currentUrl,
        tab.addressController.text,
        url,
      ]) ??
      url;
  final enqueueOverride = enqueueOverrideFor(profileMatchUrl, profiles);
  if (enqueueOverride?.downloadFolder != null) {
    saveDir = enqueueOverride!.downloadFolder!;
  }
  if (enqueueOverride?.customHeaders != null &&
      enqueueOverride!.customHeaders!.isNotEmpty) {
    mergeHeaders(headerMap, enqueueOverride.customHeaders!);
  }

  // --- Download Rules Engine (rename, destination, constraints) ---
  DownloadRule? matchedRule;
  if (ruleEngine != null) {
    matchedRule = ruleEngine.matchRule(
      url,
      mediaType: mediaTypeForRule,
      pageHost: pageHost,
    );
    if (matchedRule?.renameTemplate != null && matchedRule!.renameTemplate!.isNotEmpty) {
      suggestedName = ruleEngine.applyRename(matchedRule, suggestedName);
    }
    final ruleDest = ruleEngine.getDestinationFolder(matchedRule);
    if (ruleDest != null && ruleDest.isNotEmpty) {
      saveDir = '${baseDir ?? '.'}${Platform.pathSeparator}$ruleDest';
    }
  }

  final task = DownloadTask(
    id: taskId,
    url: url,
    sourcePageUrl: media?.sourcePageUrl ?? currentUrl,
    savePath: '$saveDir${Platform.pathSeparator}$suggestedName',
    tempDir:
        '${baseTemp ?? '.'}${Platform.pathSeparator}temp_$taskId',
    priority: DownloadPriority.medium,
    contentType: resolvedContentType ?? media?.contentType,
    headers: headerMap,
    totalBytes: media?.contentLengthBytes ?? -1,
  );
  task.fetchViaWebView = (fetchUrl, {Map<String, String>? headers}) =>
      tab.controller.fetchPlaylistBodyViaJavaScript(fetchUrl);
  task.hlsPlaylistCache =
      (cacheUrl) => lookupHlsPlaylistCache(tab.hlsPlaylistCache, cacheUrl);
  task.fetchBinaryViaWebView = (binaryUrl) =>
      tab.controller.fetchBinaryViaJavaScript(binaryUrl);
  task.cookieProvider = (cookieUrl) =>
      tab.controller.getCookiesForDomain(url: cookieUrl);
  task.onTokenExpired = TokenRefreshService.gatedClosure(
    task,
    ({bool forceReload = false}) => TokenRefreshService.refresh(task),
  );

  var force = false;
  if (downloadQueue.urlExists(url) ||
      downloadQueue.samePageFilenameExists(
        suggestedName,
        media?.sourcePageUrl ?? currentUrl,
      )) {
    if (silent) return; // batch: skip already-queued quietly
    if (!context.mounted) return;
    final choice = await showDuplicateDownloadDialog(
      context: context,
      filename: suggestedName,
    );
    if (choice == DuplicateChoice.skip) return;
    if (choice == DuplicateChoice.updateExisting) {
      final existing = downloadQueue.getTaskByUrl(url);
      if (existing != null) {
        await downloadQueue.updateTaskFromDonor(existing.id, task);
        if (isMounted()) {
          showSnack('Done — Link updated. Download will retry.');
        }
        return;
      }
    }
    force = true;
  }
  downloadQueue.addTask(task, force: force);

  // Apply rule time window constraint
  if (matchedRule != null) {
    final now = DateTime.now();
    if (matchedRule.timeWindowStartHour != null && matchedRule.timeWindowEndHour != null) {
      final currentHour = now.hour;
      final startH = matchedRule.timeWindowStartHour!;
      final endH = matchedRule.timeWindowEndHour!;
      final inWindow = startH <= endH
          ? (currentHour >= startH && currentHour < endH)
          : (currentHour >= startH || currentHour < endH);
      if (!inWindow) {
        var schedDate = DateTime(now.year, now.month, now.day, startH);
        if (schedDate.isBefore(now)) {
          schedDate = schedDate.add(const Duration(days: 1));
        }
        downloadQueue.scheduleTask(task, schedDate);
        return;
      }
    }
  }

  if (!silent && isMounted()) {
    showSnack('Started downloading $suggestedName');
  }
}

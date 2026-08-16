import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../downloader/downloader.dart';
import '../platform/public_downloads_service.dart';
import '../settings/download_settings.dart';
import '../backup/unified_backup_database.dart';
import 'browser_library.dart';
import 'models/browser_tab.dart';
import 'sheets/library_transfer_sheets.dart';

/// Result summary after applying an import.
class LibraryTransferImportSummary {
  final int favoritesCount;
  final int historyCount;
  final int savedPagesCount;
  final int queueCount;
  final int tabsCount;
  final bool settingsImported;
  final BrowserLibrary? updatedLibrary;

  const LibraryTransferImportSummary({
    this.favoritesCount = 0,
    this.historyCount = 0,
    this.savedPagesCount = 0,
    this.queueCount = 0,
    this.tabsCount = 0,
    this.settingsImported = false,
    this.updatedLibrary,
  });

  String snackMessage() {
    final summary = <String>[];
    if (favoritesCount > 0) summary.add('$favoritesCount favorites');
    if (historyCount > 0) summary.add('$historyCount history entries');
    if (savedPagesCount > 0) summary.add('$savedPagesCount saved pages');
    if (queueCount > 0) summary.add('$queueCount download tasks');
    if (tabsCount > 0) summary.add('$tabsCount open tabs');
    if (settingsImported) summary.add('app settings');
    if (summary.isEmpty) {
      return 'Import completed (no new items found).';
    }
    return 'Imported: ${summary.join(', ')}.';
  }
}

/// Export / import orchestration extracted from [SnifferScreen].
class LibraryTransfer {
  /// Runs the export sheet + file write + share flow.
  static Future<void> exportWithUi({
    required BuildContext context,
    required BrowserLibrary library,
    required BrowserLibraryStore libraryStore,
    required DownloadQueue downloadQueue,
    required DownloadSettings settings,
    required List<BrowserTab> tabs,
    required int activeTabIndex,
    required void Function(String message) showSnack,
  }) async {
    final options = await showLibraryExportOptionsSheet(
      context: context,
      favoritesCount: library.favorites.length,
      foldersCount: library.folders.length,
      historyCount: library.history.length,
      savedPagesCount: library.savedPages.length,
      queueTaskCount: downloadQueue.allTasks.length,
      openTabsCount: tabs.length,
    );
    if (options == null || !options.anySelected) return;

    try {
      final downloadQueueJson = options.queue
          ? downloadQueue.allTasks.map((t) => t.toJson()).toList()
          : null;
      final settingsJson = options.settings ? settings.toJson() : null;
      final tabsJson = options.tabs
          ? tabs.asMap().entries.map((e) {
              final url = (e.value.currentUrl ??
                      e.value.committedMainFrameUrl ??
                      e.value.addressController.text)
                  .trim();
              return {
                'id': e.value.id,
                'url': url,
                'title': e.value.title,
                'active': e.key == activeTabIndex,
                'history': e.value.controller.historyUrls,
                'historyIndex': e.value.controller.historyIndex,
                'groupName': e.value.groupName,
                'groupColorIndex': e.value.groupColorIndex,
                'autoGrouped': e.value.autoGrouped,
              };
            }).toList()
          : null;

      final file = await libraryStore.exportToFile(
        exportFavorites: options.favorites,
        exportHistory: options.history,
        exportSavedPages: options.savedPages,
        downloadQueueJson: downloadQueueJson,
        settingsJson: settingsJson,
        tabsJson: tabsJson,
      );
      await PublicDownloadsService.shareFile(file.path);
    } catch (error) {
      showSnack('Export failed: $error');
    }
  }

  /// Runs file pick + import sheet + apply. Returns snack message.
  static Future<String?> importWithUi({
    required BuildContext context,
    required BrowserLibrary library,
    required BrowserLibraryStore libraryStore,
    required DownloadQueue downloadQueue,
    required String? baseDir,
    required String? baseTemp,
    required Future<void> Function() ensurePaths,
    required Future<void> Function(BrowserLibrary library) saveLibrary,
    required ValueChanged<DownloadSettings>? onSettingsChanged,
    void Function(List<String> urls)? onImportTabs,
    required void Function(String message) showSnack,
  }) async {
    try {
      if (baseDir == null) {
        await ensurePaths();
      }

      final filePath = await PublicDownloadsService.pickImportFile();
      if (filePath == null) return null;

      final Map<String, dynamic> decoded =
          await UnifiedBackupDatabase.parseBackupFileTransactional(filePath);

      final hasFavorites = decoded.containsKey('favorites') &&
          (decoded['favorites'] is List) &&
          (decoded['favorites'] as List).isNotEmpty;
      final hasHistory = decoded.containsKey('history') &&
          (decoded['history'] is List) &&
          (decoded['history'] as List).isNotEmpty;
      final hasSavedPages = decoded.containsKey('savedPages') &&
          (decoded['savedPages'] is List) &&
          (decoded['savedPages'] as List).isNotEmpty;
      final hasQueue = decoded.containsKey('downloadQueue') &&
          (decoded['downloadQueue'] is List) &&
          (decoded['downloadQueue'] as List).isNotEmpty;
      final hasSettings = decoded.containsKey('settings');
      final hasTabs = decoded.containsKey('tabs') &&
          (decoded['tabs'] is List) &&
          (decoded['tabs'] as List).isNotEmpty;

      final isLegacy = decoded.containsKey('favorites') ||
          decoded.containsKey('history') ||
          decoded.containsKey('savedPages') ||
          (!decoded.containsKey('settings') &&
              !decoded.containsKey('downloadQueue') &&
              !decoded.containsKey('tabs') &&
              decoded.isNotEmpty &&
              !decoded.containsKey('favorites') &&
              !decoded.containsKey('history') &&
              !decoded.containsKey('savedPages'));

      if (!context.mounted) return null;
      final options = await showLibraryImportOptionsSheet(
        context: context,
        hasFavorites: hasFavorites,
        hasHistory: hasHistory,
        hasSavedPages: hasSavedPages,
        hasQueue: hasQueue,
        hasSettings: hasSettings,
        hasTabs: hasTabs,
        isLegacy: isLegacy,
      );
      if (options == null || !options.anySelected) return null;

      final summary = await applyImport(
        decoded: decoded,
        options: options,
        library: library,
        downloadQueue: downloadQueue,
        baseDir: baseDir ?? '.',
        baseTemp: baseTemp ?? '.',
        saveLibrary: saveLibrary,
        onSettingsChanged: onSettingsChanged,
        onImportTabs: onImportTabs,
      );
      return summary.snackMessage();
    } catch (error, stack) {
      debugPrint('[ImportLibrary] $error\n$stack');
      showSnack('Import failed: $error');
      return null;
    }
  }

  /// Applies a decoded import map (no UI).
  static Future<LibraryTransferImportSummary> applyImport({
    required Map<String, dynamic> decoded,
    required LibraryImportOptions options,
    required BrowserLibrary library,
    required DownloadQueue downloadQueue,
    required String baseDir,
    required String baseTemp,
    required Future<void> Function(BrowserLibrary library) saveLibrary,
    ValueChanged<DownloadSettings>? onSettingsChanged,
    void Function(List<String> urls)? onImportTabs,
  }) async {
    var importedFavoritesCount = 0;
    var importedHistoryCount = 0;
    var importedSavedPagesCount = 0;
    var importedQueueCount = 0;
    var importedTabsCount = 0;
    var importedSettings = false;
    var updatedLibrary = library;

    if (options.settings && decoded.containsKey('settings')) {
      final settingsMap = decoded['settings'];
      if (settingsMap is Map) {
        final imported = DownloadSettings.fromJson(
          Map<String, dynamic>.from(settingsMap),
        );
        onSettingsChanged?.call(imported);
        importedSettings = true;
      }
    }

    if (options.queue && decoded.containsKey('downloadQueue')) {
      final queueList = decoded['downloadQueue'];
      if (queueList is List) {
        for (final item in queueList) {
          if (item is! Map) continue;
          try {
            final taskMap = Map<String, dynamic>.from(item);
            _rebaseTaskPaths(
              taskMap,
              baseDir: baseDir,
              baseTemp: baseTemp,
              importedQueueCount: importedQueueCount,
            );
            final task = DownloadTask.fromJson(taskMap);
            downloadQueue.addTask(task);
            importedQueueCount++;
          } catch (_) {}
        }
      }
    }

    if (options.favorites && decoded.containsKey('favorites')) {
      final importedFolders = decoded.containsKey('folders')
          ? (decoded['folders'] as List? ?? const [])
              .whereType<Map>()
              .map(
                (item) =>
                    BookmarkFolder.fromJson(Map<String, dynamic>.from(item)),
              )
              .toList()
          : library.folders;
      final known = {for (final folder in importedFolders) folder.id};
      final importedFavorites = (decoded['favorites'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (item) =>
                BrowserFavorite.fromJson(Map<String, dynamic>.from(item)),
          )
          .map((favorite) {
            if (favorite.folderId != null &&
                !known.contains(favorite.folderId)) {
              return favorite.copyWith(clearFolder: true);
            }
            return favorite;
          })
          .toList();

      updatedLibrary = updatedLibrary.copyWith(
        favorites: importedFavorites,
        folders: importedFolders,
      );
      importedFavoritesCount = importedFavorites.length;
    }

    if (options.history && decoded.containsKey('history')) {
      final importedHistory = (decoded['history'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (item) =>
                BrowserHistoryEntry.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList();
      updatedLibrary = updatedLibrary.copyWith(history: importedHistory);
      importedHistoryCount = importedHistory.length;
    }

    if (options.savedPages && decoded.containsKey('savedPages')) {
      final importedSavedPages = (decoded['savedPages'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => SavedPage.fromJson(Map<String, dynamic>.from(item)))
          .toList();
      updatedLibrary =
          updatedLibrary.copyWith(savedPages: importedSavedPages);
      importedSavedPagesCount = importedSavedPages.length;
    }

    if (options.favorites || options.history || options.savedPages) {
      if (!decoded.containsKey('favorites') &&
          !decoded.containsKey('history') &&
          !decoded.containsKey('savedPages')) {
        final legacyLib = BrowserLibrary.fromJson(decoded);
        List<BrowserFavorite>? favs;
        List<BookmarkFolder>? folders;
        List<BrowserHistoryEntry>? hist;
        List<SavedPage>? saved;

        if (options.favorites) {
          favs = legacyLib.favorites;
          folders = legacyLib.folders;
          importedFavoritesCount = legacyLib.favorites.length;
        }
        if (options.history) {
          hist = legacyLib.history;
          importedHistoryCount = legacyLib.history.length;
        }
        if (options.savedPages) {
          saved = legacyLib.savedPages;
          importedSavedPagesCount = legacyLib.savedPages.length;
        }

        updatedLibrary = updatedLibrary.copyWith(
          favorites: favs,
          folders: folders,
          history: hist,
          savedPages: saved,
        );
      }
      await saveLibrary(updatedLibrary);
    }

    if (options.tabs && decoded.containsKey('tabs')) {
      final tabsList = decoded['tabs'];
      if (tabsList is List && tabsList.isNotEmpty) {
        final tabsFile = File('$baseDir/browser_tabs.json');
        List<dynamic> existingTabs = [];
        if (await tabsFile.exists()) {
          try {
            final raw = await tabsFile.readAsString();
            final decodedExisting = jsonDecode(raw);
            if (decodedExisting is List) {
              existingTabs = decodedExisting;
            }
          } catch (_) {}
        }

        final existingUrls = existingTabs
            .whereType<Map>()
            .map((t) => (t['url'] as String? ?? '').trim().toLowerCase())
            .where((u) => u.isNotEmpty)
            .toSet();

        final uniqueNewTabs = <Map<String, dynamic>>[];
        final seenImportUrls = <String>{};
        final importedTabUrls = <String>[];

        for (final item in tabsList) {
          if (item is! Map) continue;
          final map = Map<String, dynamic>.from(item);
          final url = (map['url'] as String? ?? '').trim();
          final lower = url.toLowerCase();
          if (url.isNotEmpty &&
              url != 'about:blank' &&
              !existingUrls.contains(lower) &&
              !seenImportUrls.contains(lower)) {
            seenImportUrls.add(lower);
            uniqueNewTabs.add(map);
            importedTabUrls.add(url);
          }
        }

        if (uniqueNewTabs.isNotEmpty) {
          final mergedTabs = [...existingTabs, ...uniqueNewTabs];
          await tabsFile.writeAsString(jsonEncode(mergedTabs));
          importedTabsCount = uniqueNewTabs.length;
        }

        if (decoded.containsKey('tabGroups')) {
          final groupsFile = File('$baseDir/tab_groups.json');
          List<dynamic> existingGroups = [];
          if (await groupsFile.exists()) {
            try {
              final rawGroups = await groupsFile.readAsString();
              final decodedGroups = jsonDecode(rawGroups);
              if (decodedGroups is List) existingGroups = decodedGroups;
            } catch (_) {}
          }
          final existingGroupNames = existingGroups
              .whereType<Map>()
              .map((g) => (g['name'] as String? ?? '').trim().toLowerCase())
              .toSet();
          final importedGroups = (decoded['tabGroups'] as List? ?? [])
              .whereType<Map>()
              .where((g) {
                final name =
                    (g['name'] as String? ?? '').trim().toLowerCase();
                return name.isNotEmpty && !existingGroupNames.contains(name);
              })
              .toList();
          if (importedGroups.isNotEmpty) {
            final mergedGroups = [...existingGroups, ...importedGroups];
            await groupsFile.writeAsString(jsonEncode(mergedGroups));
          }
        }

        if (onImportTabs != null && importedTabUrls.isNotEmpty) {
          onImportTabs(importedTabUrls);
        }
      }
    }

    return LibraryTransferImportSummary(
      favoritesCount: importedFavoritesCount,
      historyCount: importedHistoryCount,
      savedPagesCount: importedSavedPagesCount,
      queueCount: importedQueueCount,
      tabsCount: importedTabsCount,
      settingsImported: importedSettings,
      updatedLibrary: updatedLibrary,
    );
  }

  static void _rebaseTaskPaths(
    Map<String, dynamic> taskMap, {
    required String baseDir,
    required String baseTemp,
    required int importedQueueCount,
  }) {
    var savePath = taskMap['savePath'] as String? ?? '';
    final normalized = savePath.replaceAll('\\', '/');
    final completedIndex = normalized.lastIndexOf('/completed/');
    if (completedIndex != -1) {
      final relativePart =
          normalized.substring(completedIndex + '/completed/'.length);
      taskMap['savePath'] =
          '$baseDir${Platform.pathSeparator}completed${Platform.pathSeparator}${relativePart.replaceAll('/', Platform.pathSeparator)}';
    } else if (savePath.startsWith('completed/') ||
        savePath.startsWith('completed\\')) {
      final relativePart = savePath.substring('completed/'.length);
      taskMap['savePath'] =
          '$baseDir${Platform.pathSeparator}completed${Platform.pathSeparator}${relativePart.replaceAll('/', Platform.pathSeparator).replaceAll('\\', Platform.pathSeparator)}';
    } else {
      final filename = p.basename(savePath);
      taskMap['savePath'] =
          '$baseDir${Platform.pathSeparator}completed${Platform.pathSeparator}$filename';
    }

    var tempDir = taskMap['tempDir'] as String? ?? '';
    final normalizedTemp = tempDir.replaceAll('\\', '/');
    final tempIndex = normalizedTemp.lastIndexOf('/temp_');
    if (tempIndex != -1) {
      final relativePart = normalizedTemp.substring(tempIndex);
      taskMap['tempDir'] = '$baseTemp$relativePart';
    } else {
      taskMap['tempDir'] =
          '$baseTemp${Platform.pathSeparator}temp_${DateTime.now().millisecondsSinceEpoch}_$importedQueueCount';
    }
  }
}

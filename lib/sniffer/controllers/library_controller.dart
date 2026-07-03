import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../downloader/downloader.dart';
import '../../settings/download_settings.dart';
import '../browser_library.dart';
import '../idm_backup_parser.dart';
import '../models/browser_tab.dart';
import '../models/favorite_selection.dart';

/// Result of an import operation.
class LibraryImportResult {
  final int favoritesCount;
  final int historyCount;
  final int savedPagesCount;
  final int queueCount;
  final bool settingsImported;

  const LibraryImportResult({
    this.favoritesCount = 0,
    this.historyCount = 0,
    this.savedPagesCount = 0,
    this.queueCount = 0,
    this.settingsImported = false,
  });
}

/// Manages browser library: bookmarks, history, saved pages, export/import.
class LibraryController {
  BrowserLibrary library = BrowserLibrary.empty();
  bool isSavingPage = false;

  final BrowserLibraryStore _libraryStore;
  VoidCallback? onLibraryChanged;

  LibraryController({
    required BrowserLibraryStore libraryStore,
  }) : _libraryStore = libraryStore;

  // ---------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------

  Future<void> load() async {
    library = await _libraryStore.load();
    onLibraryChanged?.call();
  }

  Future<void> save(BrowserLibrary newLibrary) async {
    library = newLibrary;
    onLibraryChanged?.call();
    await _libraryStore.save(newLibrary);
  }

  // ---------------------------------------------------------------------------
  // History
  // ---------------------------------------------------------------------------

  Future<void> recordHistory(
    String url,
    String title, {
    required bool privateMode,
  }) async {
    if (privateMode) return;
    final existing = library.history.where((entry) => entry.url != url);
    final history = [
      BrowserHistoryEntry(title: title, url: url, visitedAt: DateTime.now()),
      ...existing,
    ].take(100).toList(growable: false);
    await save(library.copyWith(history: history));
  }

  // ---------------------------------------------------------------------------
  // Favorites
  // ---------------------------------------------------------------------------

  bool isFavorite(String url) => library.favorites.any((f) => f.url == url);

  Future<void> toggleFavorite({
    required BrowserTab activeTab,
    required Future<FavoriteSelection?> Function(List<BookmarkFolder> folders)
        promptFavoriteFolder,
    required void Function(String message) showSnack,
  }) async {
    final url = await activeTab.controller.currentUrl();
    if (url == null || url.isEmpty || url.startsWith('file:')) {
      showSnack('Cannot bookmark this page.');
      return;
    }

    // Check if already a favorite
    if (isFavorite(url)) {
      final updated = library.copyWith(
        favorites: library.favorites.where((f) => f.url != url).toList(),
      );
      await save(updated);
      showSnack('Favorite removed.');
      return;
    }

    // Prompt for folder
    final selection = await promptFavoriteFolder(library.folders);
    if (selection == null) return;

    final title = await activeTab.controller.pageTitle();
    final cleanTitle = _cleanTitle(title ?? '');

    final favorite = BrowserFavorite(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: cleanTitle.isNotEmpty ? cleanTitle : url,
      url: url,
      createdAt: DateTime.now(),
      folderId: selection.folderName != null && selection.folderName!.isNotEmpty
          ? selection.folderName
          : null,
    );

    final updated = library.copyWith(
      favorites: [...library.favorites, favorite],
    );
    await save(updated);

    if (selection.folderName != null && selection.folderName!.isNotEmpty) {
      showSnack('Bookmarked in "${selection.folderName}".');
    } else {
      showSnack('Bookmarked.');
    }
  }

  // ---------------------------------------------------------------------------
  // Saved Pages
  // ---------------------------------------------------------------------------

  Future<void> saveCurrentPage({
    required BrowserTab activeTab,
    required void Function(String message) showSnack,
  }) async {
    final url = await activeTab.controller.currentUrl();
    if (url == null || url.isEmpty || url.startsWith('file:')) {
      showSnack('Cannot save this page.');
      return;
    }

    isSavingPage = true;
    onLibraryChanged?.call();

    try {
      final html = await activeTab.controller.evaluateJavaScript(
        'document.documentElement.outerHTML',
      );
      if (html is! String || html.isEmpty) {
        showSnack('Failed to get page content.');
        return;
      }

      final title = (await activeTab.controller.pageTitle()) ?? 'Untitled';
      final fileName =
          '${DateTime.now().millisecondsSinceEpoch}.html';
      final dir = await _libraryStore.savedPagesDirectory();
      final file = File('${dir.path}/$fileName');
      await file.writeAsString(html);

      final savedPage = SavedPage(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        title: title,
        sourceUrl: url,
        localPath: file.path,
        savedAt: DateTime.now(),
      );

      final updated = library.copyWith(
        savedPages: [...library.savedPages, savedPage],
      );
      await save(updated);
      showSnack('Page saved.');
    } catch (e) {
      showSnack('Failed to save page: $e');
    } finally {
      isSavingPage = false;
      onLibraryChanged?.call();
    }
  }

  // ---------------------------------------------------------------------------
  // Export
  // ---------------------------------------------------------------------------

  Future<File?> performExport({
    required bool exportFavorites,
    required bool exportHistory,
    required bool exportSavedPages,
    required bool exportQueue,
    required bool exportSettings,
    required DownloadQueue? downloadQueue,
    required DownloadSettings settings,
  }) async {
    try {
      final queueJson = exportQueue && downloadQueue != null
          ? downloadQueue.allTasks.map((t) => t.toJson()).toList()
          : null;
      final settingsJson = exportSettings ? settings.toJson() : null;
      return await _libraryStore.exportToFile(
        exportFavorites: exportFavorites,
        exportHistory: exportHistory,
        exportSavedPages: exportSavedPages,
        downloadQueueJson: queueJson,
        settingsJson: settingsJson,
      );
    } catch (e) {
      debugPrint('[LibraryController] Export failed: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Import
  // ---------------------------------------------------------------------------

  Future<LibraryImportResult> performImport({
    required String filePath,
    DownloadQueue? downloadQueue,
    DownloadSettings? settings,
    ValueChanged<DownloadSettings>? onSettingsChanged,
    required String baseDir,
    required String baseTemp,
  }) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return const LibraryImportResult();
      }

      Map<String, dynamic> decoded;
      if (filePath.endsWith('.1dmbak')) {
        decoded = await IdmBackupParser.parse(filePath);
      } else {
        final content = await file.readAsString();
        decoded = Map<String, dynamic>.from(
          jsonDecode(content) as Map,
        );
      }

      var favoritesCount = 0;
      var historyCount = 0;
      var savedPagesCount = 0;
      var queueCount = 0;
      var settingsImported = false;

      // Settings
      if (decoded['settings'] is Map && onSettingsChanged != null) {
        final s = DownloadSettings.fromJson(
          Map<String, dynamic>.from(decoded['settings'] as Map),
        );
        onSettingsChanged(s);
        settingsImported = true;
      }

      // Favorites
      if (decoded['favorites'] is List) {
        final favs = (decoded['favorites'] as List)
            .whereType<Map>()
            .map((m) => BrowserFavorite.fromJson(m.cast<String, dynamic>()))
            .toList(growable: false);
        favoritesCount = favs.length;
      }

      // History
      if (decoded['history'] is List) {
        final entries = (decoded['history'] as List)
            .whereType<Map>()
            .map(
              (m) =>
                  BrowserHistoryEntry.fromJson(m.cast<String, dynamic>()),
            )
            .toList(growable: false);
        historyCount = entries.length;
      }

      // Saved Pages
      if (decoded['savedPages'] is List) {
        final pages = (decoded['savedPages'] as List)
            .whereType<Map>()
            .map((m) => SavedPage.fromJson(m.cast<String, dynamic>()))
            .toList(growable: false);
        savedPagesCount = pages.length;
      }

      // Merge into library
      if (favoritesCount > 0 || savedPagesCount > 0 || historyCount > 0) {
        var merged = library;
        if (favoritesCount > 0) {
          // Merge favorites: add new ones, skip duplicates by URL
          final existingUrls = merged.favorites.map((f) => f.url).toSet();
          final newFavs = (decoded['favorites'] as List)
              .whereType<Map>()
              .map((m) => BrowserFavorite.fromJson(m.cast<String, dynamic>()))
              .where((f) => !existingUrls.contains(f.url))
              .toList(growable: false);
          merged = merged.copyWith(
            favorites: [...merged.favorites, ...newFavs],
          );
        }
        if (historyCount > 0) {
          merged = merged.copyWith(
            history: [
              ...merged.history,
              ...(decoded['history'] as List)
                  .whereType<Map>()
                  .map(
                    (m) => BrowserHistoryEntry.fromJson(
                      m.cast<String, dynamic>(),
                    ),
                  ),
            ].take(100).toList(growable: false),
          );
        }
        if (savedPagesCount > 0) {
          merged = merged.copyWith(
            savedPages: [
              ...merged.savedPages,
              ...(decoded['savedPages'] as List)
                  .whereType<Map>()
                  .map(
                    (m) => SavedPage.fromJson(m.cast<String, dynamic>()),
                  ),
            ],
          );
        }
        await save(merged);
      }

      // Queue
      if (decoded['downloadQueue'] is List && downloadQueue != null) {
        final tasks = (decoded['downloadQueue'] as List)
            .whereType<Map>()
            .map((m) => DownloadTask.fromJson(m.cast<String, dynamic>()))
            .toList(growable: false);
        for (final task in tasks) {
          // Re-base the save path
          final fileName = p.basename(task.savePath);
          task.savePath = '$baseDir/completed/$fileName';
          downloadQueue.addTask(task);
          queueCount++;
        }
      }

      return LibraryImportResult(
        favoritesCount: favoritesCount,
        historyCount: historyCount,
        savedPagesCount: savedPagesCount,
        queueCount: queueCount,
        settingsImported: settingsImported,
      );
    } catch (e) {
      debugPrint('[LibraryController] Import failed: $e');
      return const LibraryImportResult();
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  String _cleanTitle(String title) {
    var cleaned = title.trim();
    if (cleaned.startsWith('"') && cleaned.endsWith('"')) {
      cleaned = cleaned.substring(1, cleaned.length - 1);
    }
    return cleaned.length > 200 ? '${cleaned.substring(0, 200)}…' : cleaned;
  }

  void dispose() {
    onLibraryChanged = null;
  }
}

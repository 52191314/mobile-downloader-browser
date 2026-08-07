import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../downloader/downloader.dart';
import '../../settings/download_settings.dart';
import '../../backup/unified_backup_database.dart';
import '../browser_library.dart';
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

  Timer? _saveDebounce;
  BrowserLibrary? _pendingSave;

  /// Default coalescing window for [saveDebounced].
  static const Duration saveDebounceDelay = Duration(milliseconds: 900);

  /// Writes [newLibrary] immediately.
  ///
  /// Use for anything the user did on purpose — bookmarking, importing,
  /// deleting — where losing the write would be noticed. Any coalesced write is
  /// dropped first: it is superseded by definition, and letting its timer fire
  /// afterwards would clobber this newer state with older data.
  Future<void> save(BrowserLibrary newLibrary) async {
    _saveDebounce?.cancel();
    _saveDebounce = null;
    _pendingSave = null;
    library = newLibrary;
    onLibraryChanged?.call();
    await _libraryStore.save(newLibrary);
  }

  /// Publishes [newLibrary] in memory now and writes it once the burst settles.
  ///
  /// History is recorded on every page load, so activating three unloaded tabs
  /// in a row previously rewrote the entire library file three times in as many
  /// hundred milliseconds. In-memory state updates immediately either way, so
  /// the UI is unaffected by the delay.
  void saveDebounced(
    BrowserLibrary newLibrary, {
    Duration delay = saveDebounceDelay,
  }) {
    library = newLibrary;
    onLibraryChanged?.call();
    _pendingSave = newLibrary;
    _saveDebounce?.cancel();
    _saveDebounce = Timer(delay, () {
      _saveDebounce = null;
      final pending = _pendingSave;
      _pendingSave = null;
      if (pending != null) unawaited(_libraryStore.save(pending));
    });
  }

  /// Flushes a coalesced write now. Call when the screen is going away, so a
  /// visit recorded in the last instant is not lost.
  Future<void> flushPendingSave() async {
    _saveDebounce?.cancel();
    _saveDebounce = null;
    final pending = _pendingSave;
    _pendingSave = null;
    if (pending != null) await _libraryStore.save(pending);
  }

  // ---------------------------------------------------------------------------
  // History
  // ---------------------------------------------------------------------------

  /// Records a visit, deduped by [BrowserLibrary.withVisit]. Nothing is dropped.
  ///
  /// Debounced, not immediate: this fires on every page load, and it is the one
  /// write frequent enough that rewriting the whole file each time was the cause
  /// of the tab-switch freeze on large histories.
  Future<void> recordHistory(
    String url,
    String title, {
    required bool privateMode,
  }) async {
    if (privateMode) return;
    saveDebounced(library.withVisit(url, title));
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
      showSnack('Can\'t bookmark this page right now.');
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
      showSnack('Saved to "${selection.folderName}".');
    } else {
      showSnack('Page bookmarked.');
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
      showSnack('Can\'t save this page right now.');
      return;
    }

    isSavingPage = true;
    onLibraryChanged?.call();

    try {
      final html = await activeTab.controller.evaluateJavaScript(
        'document.documentElement.outerHTML',
      );
      if (html is! String || html.isEmpty) {
        showSnack('Could not read this page\'s content. Try again.');
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
      showSnack('Page saved offline.');
    } catch (e) {
      showSnack('Could not save this page: $e');
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
    required bool exportTabs,
    required DownloadQueue? downloadQueue,
    required DownloadSettings settings,
    List<Map<String, dynamic>>? tabsJson,
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
        tabsJson: exportTabs ? (tabsJson ?? []) : null,
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

      final Map<String, dynamic> decoded =
          await UnifiedBackupDatabase.parseBackupFileTransactional(filePath);

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
            ].toList(),
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
    // Fire-and-forget rather than dropped: dispose cannot await, but losing the
    // last recorded visit would be a silent data loss.
    final pending = _pendingSave;
    _saveDebounce?.cancel();
    _saveDebounce = null;
    _pendingSave = null;
    if (pending != null) unawaited(_libraryStore.save(pending));
    onLibraryChanged = null;
  }
}

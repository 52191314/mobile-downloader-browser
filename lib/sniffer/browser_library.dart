import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class BrowserFavorite {
  final String id;
  final String title;
  final String url;
  final DateTime createdAt;
  final String? faviconUrl;
  final String? folderId;
  final List<String> tags;

  const BrowserFavorite({
    required this.id,
    required this.title,
    required this.url,
    required this.createdAt,
    this.faviconUrl,
    this.folderId,
    this.tags = const [],
  });

  BrowserFavorite copyWith({
    String? title,
    String? url,
    String? faviconUrl,
    String? folderId,
    bool clearFolder = false,
    List<String>? tags,
  }) {
    return BrowserFavorite(
      id: id,
      title: title ?? this.title,
      url: url ?? this.url,
      createdAt: createdAt,
      faviconUrl: faviconUrl ?? this.faviconUrl,
      folderId: clearFolder ? null : (folderId ?? this.folderId),
      tags: tags ?? this.tags,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'url': url,
    'createdAt': createdAt.toIso8601String(),
    'faviconUrl': faviconUrl,
    'folderId': folderId,
    'tags': tags,
  };

  factory BrowserFavorite.fromJson(Map<String, dynamic> json) {
    return BrowserFavorite(
      id: json['id'] as String,
      title: json['title'] as String? ?? json['url'] as String? ?? 'Favorite',
      url: json['url'] as String,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      faviconUrl: json['faviconUrl'] as String?,
      folderId: json['folderId'] as String?,
      tags: (json['tags'] as List? ?? const [])
          .whereType<String>()
          .map((tag) => tag.trim())
          .where((tag) => tag.isNotEmpty)
          .toList(growable: false),
    );
  }
}

class BookmarkFolder {
  final String id;
  final String name;
  final DateTime createdAt;

  const BookmarkFolder({
    required this.id,
    required this.name,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
  };

  factory BookmarkFolder.fromJson(Map<String, dynamic> json) {
    return BookmarkFolder(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'Folder',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

class SavedPage {
  final String id;
  final String title;
  final String sourceUrl;
  final String localPath;
  final DateTime savedAt;

  const SavedPage({
    required this.id,
    required this.title,
    required this.sourceUrl,
    required this.localPath,
    required this.savedAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'sourceUrl': sourceUrl,
    'localPath': localPath,
    'savedAt': savedAt.toIso8601String(),
  };

  factory SavedPage.fromJson(Map<String, dynamic> json) {
    return SavedPage(
      id: json['id'] as String,
      title:
          json['title'] as String? ?? json['sourceUrl'] as String? ?? 'Saved',
      sourceUrl: json['sourceUrl'] as String,
      localPath: json['localPath'] as String,
      savedAt:
          DateTime.tryParse(json['savedAt'] as String? ?? '') ?? DateTime.now(),
    );
  }
}

class BrowserHistoryEntry {
  final String title;
  final String url;
  final DateTime visitedAt;

  const BrowserHistoryEntry({
    required this.title,
    required this.url,
    required this.visitedAt,
  });

  Map<String, dynamic> toJson() => {
    'title': title,
    'url': url,
    'visitedAt': visitedAt.toIso8601String(),
  };

  factory BrowserHistoryEntry.fromJson(Map<String, dynamic> json) {
    return BrowserHistoryEntry(
      title: json['title'] as String? ?? json['url'] as String? ?? 'Page',
      url: json['url'] as String,
      visitedAt:
          DateTime.tryParse(json['visitedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

class BrowserLibrary {
  final List<BrowserFavorite> favorites;
  final List<SavedPage> savedPages;
  final List<BrowserHistoryEntry> history;
  final List<BookmarkFolder> folders;

  const BrowserLibrary({
    required this.favorites,
    required this.savedPages,
    required this.history,
    this.folders = const [],
  });

  factory BrowserLibrary.empty() => const BrowserLibrary(
    favorites: [],
    savedPages: [],
    history: [],
    folders: [],
  );

  BrowserLibrary copyWith({
    List<BrowserFavorite>? favorites,
    List<SavedPage>? savedPages,
    List<BrowserHistoryEntry>? history,
    List<BookmarkFolder>? folders,
  }) {
    return BrowserLibrary(
      favorites: favorites ?? this.favorites,
      savedPages: savedPages ?? this.savedPages,
      history: history ?? this.history,
      folders: folders ?? this.folders,
    );
  }

  /// Returns folders that exist on at least one favorite. Used to migrate
  /// legacy libraries and to seed the "Unsorted" pseudo-folder view.
  List<BrowserFavorite> favoritesInFolder(String? folderId) {
    return favorites
        .where((fav) => fav.folderId == folderId)
        .toList(growable: false);
  }

  Set<String> knownFolderIds() {
    return {for (final folder in folders) folder.id};
  }

  Map<String, dynamic> toJson() => {
    'favorites': favorites.map((favorite) => favorite.toJson()).toList(),
    'savedPages': savedPages.map((page) => page.toJson()).toList(),
    'history': history.map((entry) => entry.toJson()).toList(),
    'folders': folders.map((folder) => folder.toJson()).toList(),
  };

  factory BrowserLibrary.fromJson(Map<String, dynamic> json) {
    final folders = (json['folders'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (item) => BookmarkFolder.fromJson(Map<String, dynamic>.from(item)),
        )
        .toList(growable: false);
    final known = {for (final folder in folders) folder.id};
    final migratedFavorites = (json['favorites'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (item) => BrowserFavorite.fromJson(Map<String, dynamic>.from(item)),
        )
        .map((favorite) {
          if (favorite.folderId != null && !known.contains(favorite.folderId)) {
            return favorite.copyWith(clearFolder: true);
          }
          return favorite;
        })
        .toList(growable: false);
    return BrowserLibrary(
      favorites: migratedFavorites,
      savedPages: (json['savedPages'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => SavedPage.fromJson(Map<String, dynamic>.from(item)))
          .toList(growable: false),
      history: (json['history'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (item) =>
                BrowserHistoryEntry.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList(growable: false),
      folders: folders,
    );
  }
}

class BrowserLibraryStore {
  final String fileName;
  final Directory? baseDirectory;

  const BrowserLibraryStore({
    this.fileName = 'browser_library.json',
    this.baseDirectory,
  });

  Future<BrowserLibrary> load() async {
    final file = await _libraryFile();
    try {
      if (!await file.exists()) return BrowserLibrary.empty();
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        await _preserveCorruptLibraryFile(file, 'Library file was not a Map.');
        return BrowserLibrary.empty();
      }
      return BrowserLibrary.fromJson(Map<String, dynamic>.from(decoded));
    } catch (e) {
      await _preserveCorruptLibraryFile(file, e.toString());
      return BrowserLibrary.empty();
    }
  }

  Future<void> _preserveCorruptLibraryFile(File file, String reason) async {
    try {
      if (!await file.exists()) return;
      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('.', '-');
      final corruptPath = '${file.path}.corrupt.$timestamp';
      await file.rename(corruptPath);
    } catch (_) {
      // Avoid crash on log/rename failures
    }
  }

  Future<void> save(BrowserLibrary library) async {
    final file = await _libraryFile();
    if (!await file.parent.exists()) {
      await file.parent.create(recursive: true);
    }
    await file.writeAsString(jsonEncode(library.toJson()));
  }

  Future<Directory> savedPagesDirectory() async {
    final dir = baseDirectory ?? await getApplicationSupportDirectory();
    final pagesDir = Directory('${dir.path}/saved_pages');
    if (!await pagesDir.exists()) {
      await pagesDir.create(recursive: true);
    }
    return pagesDir;
  }

  Future<File> exportToFile({
    Directory? targetDirectory,
    bool exportFavorites = true,
    bool exportHistory = true,
    bool exportSavedPages = true,
    List<Map<String, dynamic>>? downloadQueueJson,
    Map<String, dynamic>? settingsJson,
  }) async {
    final library = await load();
    final Directory dir;
    if (targetDirectory != null) {
      dir = targetDirectory;
    } else {
      final extDir = Platform.isAndroid ? await getExternalStorageDirectory() : null;
      final baseDir = extDir ?? await getApplicationSupportDirectory();
      dir = Directory('${baseDir.path}/Backups');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    }
    final file = File(
      '${dir.path}/aurora_backup_${DateTime.now().millisecondsSinceEpoch}.json',
    );

    final Map<String, dynamic> exportData = {};
    if (exportFavorites) {
      exportData['favorites'] = library.favorites.map((favorite) => favorite.toJson()).toList();
      exportData['folders'] = library.folders.map((folder) => folder.toJson()).toList();
    }
    if (exportHistory) {
      exportData['history'] = library.history.map((entry) => entry.toJson()).toList();
    }
    if (exportSavedPages) {
      exportData['savedPages'] = library.savedPages.map((page) => page.toJson()).toList();
    }
    if (downloadQueueJson != null) {
      exportData['downloadQueue'] = downloadQueueJson;
    }
    if (settingsJson != null) {
      exportData['settings'] = settingsJson;
    }

    await file.writeAsString(jsonEncode(exportData));
    return file;
  }

  Future<BrowserLibrary> importFromFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('Could not find that import file at: $filePath');
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) throw Exception('This file is not a valid library backup.');
    return BrowserLibrary.fromJson(Map<String, dynamic>.from(decoded));
  }

  Future<Map<String, dynamic>> readImportMap(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('Could not find that import file at: $filePath');
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) throw Exception('This file is not a valid library backup.');
    return Map<String, dynamic>.from(decoded);
  }

  Future<File> _libraryFile() async {
    final dir = baseDirectory ?? await getApplicationSupportDirectory();
    return File('${dir.path}/$fileName');
  }
}

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path_provider/path_provider.dart';

/// Whether a library entry points at a page or at a media stream.
///
/// Favourites and history were page-only until video favouriting existed, so
/// every entry written before this field must read back as [site] — see the
/// `fromJson` fallbacks. Never reorder: the names are persisted.
enum LibraryEntryKind { site, video }

LibraryEntryKind _kindFromJson(Object? raw) {
  if (raw is String) {
    for (final k in LibraryEntryKind.values) {
      if (k.name == raw) return k;
    }
  }
  // Absent or unrecognised: everything written before the split was a page.
  return LibraryEntryKind.site;
}

class BrowserFavorite {
  final String id;
  final String title;
  final String url;
  final DateTime createdAt;
  final String? faviconUrl;
  final String? folderId;
  final List<String> tags;

  /// Page bookmark or saved video. Drives which subpage this appears under.
  final LibraryEntryKind kind;

  /// Poster for a video entry, harvested by the sniffer. Null for sites and
  /// for videos whose page exposed no artwork.
  final String? thumbnailUrl;

  /// The page the video was found on. Kept so a saved stream whose signed URL
  /// has expired can still be re-opened at its source rather than being a dead
  /// link — the single most likely failure for a stored CDN link.
  final String? sourcePageUrl;

  const BrowserFavorite({
    required this.id,
    required this.title,
    required this.url,
    required this.createdAt,
    this.faviconUrl,
    this.folderId,
    this.tags = const [],
    this.kind = LibraryEntryKind.site,
    this.thumbnailUrl,
    this.sourcePageUrl,
  });

  bool get isVideo => kind == LibraryEntryKind.video;

  BrowserFavorite copyWith({
    String? title,
    String? url,
    String? faviconUrl,
    String? folderId,
    bool clearFolder = false,
    List<String>? tags,
    LibraryEntryKind? kind,
    String? thumbnailUrl,
    String? sourcePageUrl,
  }) {
    return BrowserFavorite(
      id: id,
      title: title ?? this.title,
      url: url ?? this.url,
      createdAt: createdAt,
      faviconUrl: faviconUrl ?? this.faviconUrl,
      folderId: clearFolder ? null : (folderId ?? this.folderId),
      tags: tags ?? this.tags,
      kind: kind ?? this.kind,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      sourcePageUrl: sourcePageUrl ?? this.sourcePageUrl,
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
    'kind': kind.name,
    'thumbnailUrl': thumbnailUrl,
    'sourcePageUrl': sourcePageUrl,
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
      kind: _kindFromJson(json['kind']),
      thumbnailUrl: json['thumbnailUrl'] as String?,
      sourcePageUrl: json['sourcePageUrl'] as String?,
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

  /// Page visit or video playback. See [LibraryEntryKind].
  final LibraryEntryKind kind;

  /// Poster for a video entry. Null for page visits.
  final String? thumbnailUrl;

  /// Page the video played from, so an expired stream URL still has a way back.
  final String? sourcePageUrl;

  const BrowserHistoryEntry({
    required this.title,
    required this.url,
    required this.visitedAt,
    this.kind = LibraryEntryKind.site,
    this.thumbnailUrl,
    this.sourcePageUrl,
  });

  bool get isVideo => kind == LibraryEntryKind.video;

  Map<String, dynamic> toJson() => {
    'title': title,
    'url': url,
    'visitedAt': visitedAt.toIso8601String(),
    'kind': kind.name,
    'thumbnailUrl': thumbnailUrl,
    'sourcePageUrl': sourcePageUrl,
  };

  factory BrowserHistoryEntry.fromJson(Map<String, dynamic> json) {
    return BrowserHistoryEntry(
      title: json['title'] as String? ?? json['url'] as String? ?? 'Page',
      url: json['url'] as String,
      visitedAt:
          DateTime.tryParse(json['visitedAt'] as String? ?? '') ??
          DateTime.now(),
      kind: _kindFromJson(json['kind']),
      thumbnailUrl: json['thumbnailUrl'] as String?,
      sourcePageUrl: json['sourcePageUrl'] as String?,
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

  /// Page bookmarks, newest first. Folders apply only to these.
  List<BrowserFavorite> get siteFavorites => favorites
      .where((f) => f.kind == LibraryEntryKind.site)
      .toList(growable: false);

  /// Saved videos, newest first. Deliberately flat — folders are a page-
  /// organising idea, and forcing videos through them would mean every saved
  /// video landing in "Unsorted".
  List<BrowserFavorite> get videoFavorites {
    final list = favorites
        .where((f) => f.kind == LibraryEntryKind.video)
        .toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List.unmodifiable(list);
  }

  /// This library with a visit to [url] recorded at the front of history.
  ///
  /// Any earlier entry for the same URL is dropped rather than duplicated, so a
  /// site visited fifty times occupies one row. Both callers that record visits
  /// share this, so the dedupe rule cannot drift between them.
  ///
  /// **History is unbounded by default.** [limit] exists for callers that want a
  /// bounded view (and for tests), but truncating on write would silently
  /// destroy the user's browsing record, and it was never what made a large
  /// history expensive — re-serialising the entire library on every visit was.
  /// That is fixed in [BrowserLibraryStore], not here.
  ///
  /// Note this is lossy in a way a real browser's history is not: Firefox and
  /// Chromium keep one row per *visit* alongside one row per URL, so they can
  /// show visit counts and a full timeline. Collapsing to the newest entry per
  /// URL is a consequence of the flat JSON shape, and is the thing a proper
  /// `urls` + `visits` schema would fix.
  BrowserLibrary withVisit(
    String url,
    String title, {
    DateTime? at,
    int? limit,
  }) {
    final kept = <BrowserHistoryEntry>[
      BrowserHistoryEntry(
        title: title,
        url: url,
        visitedAt: at ?? DateTime.now(),
      ),
    ];
    for (final existing in history) {
      // Stops walking once full, so a bounded caller does not copy the whole
      // list just to discard the tail.
      if (limit != null && kept.length >= limit) break;
      if (existing.url == url) continue;
      kept.add(existing);
    }
    return copyWith(history: kept);
  }

  List<BrowserHistoryEntry> get siteHistory => history
      .where((h) => h.kind == LibraryEntryKind.site)
      .toList(growable: false);

  List<BrowserHistoryEntry> get videoHistory {
    final list =
        history.where((h) => h.kind == LibraryEntryKind.video).toList();
    list.sort((a, b) => b.visitedAt.compareTo(a.visitedAt));
    return List.unmodifiable(list);
  }

  /// Page bookmarks in [folderId]. Videos are excluded — they live on their
  /// own subpage, and letting them fall into "Unsorted" would have silently
  /// mixed streams into the user's site bookmarks.
  List<BrowserFavorite> favoritesInFolder(String? folderId) {
    return favorites
        .where((fav) =>
            fav.kind == LibraryEntryKind.site && fav.folderId == folderId)
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
      // Decoded off-thread for the same reason encoding is: with history
      // unbounded this parse grows without limit, and on the root isolate it
      // would land as a stall during cold start.
      final raw = await file.readAsString();
      final library = await Isolate.run(() {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) return null;
        return BrowserLibrary.fromJson(Map<String, dynamic>.from(decoded));
      });
      if (library == null) {
        await _preserveCorruptLibraryFile(file, 'Library file was not a Map.');
        return BrowserLibrary.empty();
      }
      return library;
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
    // Serialising a few thousand history entries is tens of milliseconds of
    // synchronous CPU, and this runs on every recorded visit. On the root
    // isolate that surfaces as dropped frames mid-navigation, so the string
    // building happens off-thread. Only the plain JSON tree crosses the
    // boundary, which is always sendable.
    final json = library.toJson();
    final encoded = await Isolate.run(() => jsonEncode(json));

    final tempFile = File('${file.path}.tmp');
    await tempFile.writeAsString(encoded, flush: true);
    try {
      await tempFile.rename(file.path);
    } catch (_) {
      await tempFile.copy(file.path);
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }
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
    List<Map<String, dynamic>>? tabsJson,
    dynamic downloadRulesJson,
    Map<String, dynamic>? extraJson,
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
    if (tabsJson != null) {
      exportData['tabs'] = tabsJson;
    }
    if (downloadRulesJson != null) {
      exportData['downloadRules'] = downloadRulesJson;
    }
    if (extraJson != null) {
      exportData.addAll(extraJson);
    }

    final encoded = await Isolate.run(() => jsonEncode(exportData));
    final tempFile = File('${file.path}.tmp');
    await tempFile.writeAsString(encoded, flush: true);
    try {
      await tempFile.rename(file.path);
    } catch (_) {
      await tempFile.copy(file.path);
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }
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

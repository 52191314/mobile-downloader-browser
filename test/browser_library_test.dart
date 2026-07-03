import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aurora_downloader/sniffer/browser_library.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('aurora_browser_library_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'BrowserLibraryStore persists favorites, saved pages, and history',
    () async {
      final store = BrowserLibraryStore(baseDirectory: tempDir);
      final library = BrowserLibrary(
        favorites: [
          BrowserFavorite(
            id: 'fav-1',
            title: 'Example',
            url: 'https://example.com',
            createdAt: DateTime(2026),
          ),
        ],
        savedPages: [
          SavedPage(
            id: 'saved-1',
            title: 'Saved Example',
            sourceUrl: 'https://example.com/saved',
            localPath: '${tempDir.path}/saved.html',
            savedAt: DateTime(2026, 2),
          ),
        ],
        history: [
          BrowserHistoryEntry(
            title: 'History Example',
            url: 'https://example.com/history',
            visitedAt: DateTime(2026, 3),
          ),
        ],
      );

      await store.save(library);
      final loaded = await store.load();

      expect(loaded.favorites.single.title, 'Example');
      expect(loaded.savedPages.single.sourceUrl, 'https://example.com/saved');
      expect(loaded.history.single.url, 'https://example.com/history');
    },
  );

  test('savedPagesDirectory creates a local page folder', () async {
    final store = BrowserLibraryStore(baseDirectory: tempDir);

    final dir = await store.savedPagesDirectory();

    expect(await dir.exists(), isTrue);
    expect(dir.path, contains('saved_pages'));
  });

  test('favorites round-trip with folder and tags', () async {
    final store = BrowserLibraryStore(baseDirectory: tempDir);
    final folder = BookmarkFolder(
      id: 'folder-1',
      name: 'Work',
      createdAt: DateTime(2026, 4),
    );
    final library = BrowserLibrary(
      favorites: [
        BrowserFavorite(
          id: 'fav-2',
          title: 'Docs',
          url: 'https://docs.example.com',
          createdAt: DateTime(2026, 5),
          folderId: folder.id,
          tags: const ['reference', 'api'],
        ),
      ],
      savedPages: const [],
      history: const [],
      folders: [folder],
    );

    await store.save(library);
    final loaded = await store.load();

    expect(loaded.folders.single.name, 'Work');
    expect(loaded.favorites.single.folderId, 'folder-1');
    expect(loaded.favorites.single.tags, ['reference', 'api']);
    expect(loaded.favoritesInFolder('folder-1').single.id, 'fav-2');
  });

  test('legacy favorites with missing folder are unsorted on load', () {
    final library = BrowserLibrary.fromJson({
      'favorites': [
        {
          'id': 'fav-3',
          'title': 'Legacy',
          'url': 'https://legacy.example.com',
          'createdAt': '2026-01-01T00:00:00.000Z',
          'folderId': 'stale-folder',
        },
      ],
      'folders': <Map>[],
    });

    expect(library.favorites.single.folderId, isNull);
    expect(library.favoritesInFolder(null).single.id, 'fav-3');
  });

  test('custom export and import filter options', () async {
    final store = BrowserLibraryStore(baseDirectory: tempDir);
    final library = BrowserLibrary(
      favorites: [
        BrowserFavorite(
          id: 'fav-1',
          title: 'Example',
          url: 'https://example.com',
          createdAt: DateTime(2026),
        ),
      ],
      savedPages: [
        SavedPage(
          id: 'saved-1',
          title: 'Saved Example',
          sourceUrl: 'https://example.com/saved',
          localPath: '${tempDir.path}/saved.html',
          savedAt: DateTime(2026, 2),
        ),
      ],
      history: [
        BrowserHistoryEntry(
          title: 'History Example',
          url: 'https://example.com/history',
          visitedAt: DateTime(2026, 3),
        ),
      ],
    );

    await store.save(library);

    // Test: Export only Favorites and Settings/Queue
    final settingsMap = {'theme': 'dark', 'maxConnections': 8};
    final queueList = [
      {'id': 'task-1', 'url': 'https://download.com/1', 'state': 'completed'}
    ];

    final file = await store.exportToFile(
      targetDirectory: tempDir,
      exportFavorites: true,
      exportHistory: false,
      exportSavedPages: false,
      downloadQueueJson: queueList,
      settingsJson: settingsMap,
    );

    final importedMap = await store.readImportMap(file.path);

    expect(importedMap.containsKey('favorites'), isTrue);
    expect(importedMap.containsKey('folders'), isTrue);
    expect(importedMap.containsKey('history'), isFalse);
    expect(importedMap.containsKey('savedPages'), isFalse);
    expect(importedMap.containsKey('settings'), isTrue);
    expect(importedMap.containsKey('downloadQueue'), isTrue);

    expect(importedMap['settings']['maxConnections'], 8);
    expect(importedMap['downloadQueue'][0]['id'], 'task-1');
  });
}

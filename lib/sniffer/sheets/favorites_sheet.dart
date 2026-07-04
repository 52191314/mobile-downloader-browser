import 'dart:async';

import 'package:flutter/material.dart';

import '../browser_library.dart';
import '../models/browser_tab.dart';
import '../../theme/aurora_colors.dart';

void showFavoritesSheet(
  BuildContext context, {
  required BrowserTab activeTab,
  required BrowserLibrary library,
  required BookmarkFolder unsortedFolder,
  required bool Function(String url) isCurrentPageFavorited,
  required Future<void> Function(BrowserLibrary) onSaveLibrary,
  required Future<void> Function(String url) onLoadUrl,
  required VoidCallback onFavoriteToggled,
  required Future<void> Function() onNewFolderCreated,
  required Future<BrowserLibrary?> Function(BrowserFavorite favorite) onEditFavorite,
}) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) {
      return FavoritesSheetContent(
        activeTab: activeTab,
        library: library,
        unsortedFolder: unsortedFolder,
        isCurrentPageFavorited: isCurrentPageFavorited,
        onSaveLibrary: onSaveLibrary,
        onLoadUrl: onLoadUrl,
        onFavoriteToggled: onFavoriteToggled,
        onNewFolderCreated: onNewFolderCreated,
        onEditFavorite: onEditFavorite,
      );
    },
  );
}

class FavoritesSheetContent extends StatefulWidget {
  final BrowserTab activeTab;
  final BrowserLibrary library;
  final BookmarkFolder unsortedFolder;
  final bool Function(String url) isCurrentPageFavorited;
  final Future<void> Function(BrowserLibrary) onSaveLibrary;
  final Future<void> Function(String url) onLoadUrl;
  final VoidCallback onFavoriteToggled;
  final Future<void> Function() onNewFolderCreated;
  final Future<BrowserLibrary?> Function(BrowserFavorite favorite) onEditFavorite;

  const FavoritesSheetContent({
    super.key,
    required this.activeTab,
    required this.library,
    required this.unsortedFolder,
    required this.isCurrentPageFavorited,
    required this.onSaveLibrary,
    required this.onLoadUrl,
    required this.onFavoriteToggled,
    required this.onNewFolderCreated,
    required this.onEditFavorite,
  });

  @override
  State<FavoritesSheetContent> createState() => _FavoritesSheetContentState();
}

class _FavoritesSheetContentState extends State<FavoritesSheetContent>
    with TickerProviderStateMixin {
  late BrowserLibrary _currentLibrary;
  TabController? _tabController;
  late List<BookmarkFolder> _folders;

  @override
  void initState() {
    super.initState();
    _currentLibrary = widget.library;
    _updateFoldersAndController();
  }

  @override
  void didUpdateWidget(covariant FavoritesSheetContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.library != oldWidget.library) {
      setState(() {
        _currentLibrary = widget.library;
        _updateFoldersAndController();
      });
    }
  }

  void _updateFoldersAndController() {
    _folders = [widget.unsortedFolder, ..._currentLibrary.folders];
    final oldController = _tabController;
    _tabController = TabController(
      length: _folders.length,
      vsync: this,
      initialIndex: oldController != null
          ? oldController.index.clamp(0, _folders.length - 1)
          : 0,
    );
    if (oldController != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        oldController.dispose();
      });
    }
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  Future<void> _createNewFolder() async {
    final nameController = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('New folder'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Folder name',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogCtx).pop(nameController.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    nameController.dispose();
    if (name == null || name.isEmpty) return;

    final folder = BookmarkFolder(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
      createdAt: DateTime.now(),
    );
    final updatedLibrary = _currentLibrary.copyWith(
      folders: [..._currentLibrary.folders, folder],
    );
    await widget.onSaveLibrary(updatedLibrary);

    setState(() {
      _currentLibrary = updatedLibrary;
      _updateFoldersAndController();
    });
    widget.onFavoriteToggled();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        key: ValueKey('favorites_column_${_folders.length}'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                const Icon(Icons.star, color: AuroraColors.accentAmber),
                const SizedBox(width: 8),
                const Text(
                  'Favorites',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _createNewFolder,
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('New folder'),
                ),
              ],
            ),
          ),
          TabBar(
            controller: _tabController,
            isScrollable: true,
            tabs: [
              for (final folder in _folders) Tab(text: folder.name),
            ],
          ),
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.55,
            child: TabBarView(
              controller: _tabController,
              children: [
                for (final folder in _folders)
                  buildFavoritesFolderList(
                    context,
                    widget.activeTab,
                    folder,
                    _currentLibrary.favoritesInFolder(
                      folder.id == '__unsorted__' ? null : folder.id,
                    ),
                    library: _currentLibrary,
                    unsortedFolder: widget.unsortedFolder,
                    isCurrentPageFavorited: widget.isCurrentPageFavorited,
                    onSaveLibrary: (updatedLib) async {
                      await widget.onSaveLibrary(updatedLib);
                      setState(() {
                        _currentLibrary = updatedLib;
                        _updateFoldersAndController();
                      });
                      widget.onFavoriteToggled();
                    },
                    onLoadUrl: widget.onLoadUrl,
                    onFavoriteToggled: widget.onFavoriteToggled,
                    onNewFolderCreated: () async {
                      setState(() {
                        _updateFoldersAndController();
                      });
                      widget.onFavoriteToggled();
                    },
                    onEditFavorite: widget.onEditFavorite,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Widget buildFavoritesFolderList(
  BuildContext sheetContext,
  BrowserTab tab,
  BookmarkFolder folder,
  List<BrowserFavorite> items, {
  required BrowserLibrary library,
  required BookmarkFolder unsortedFolder,
  required bool Function(String url) isCurrentPageFavorited,
  required Future<void> Function(BrowserLibrary) onSaveLibrary,
  required Future<void> Function(String url) onLoadUrl,
  required VoidCallback onFavoriteToggled,
  required Future<void> Function() onNewFolderCreated,
  required Future<BrowserLibrary?> Function(BrowserFavorite favorite) onEditFavorite,
}) {
  final isUnsorted = folder.id == '__unsorted__';

  Widget listWidget;
  if (items.isEmpty) {
    listWidget = Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Nothing saved in ${folder.name}.',
          style: const TextStyle(color: AuroraColors.mutedText),
        ),
      ),
    );
  } else {
    listWidget = ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, i) {
        final fav = items[i];
        return ListTile(
          leading: const Icon(Icons.star, color: AuroraColors.accentAmber),
          title: Text(fav.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                fav.url,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
              if (fav.tags.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 2,
                    children: [
                      for (final tag in fav.tags)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: AuroraColors.surfaceVariant,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            tag,
                            style: const TextStyle(
                              fontSize: 10,
                              color: AuroraColors.accent,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
          trailing: PopupMenuButton<String>(
            onSelected: (action) async {
              if (action == 'delete') {
                await onSaveLibrary(
                  library.copyWith(
                    favorites: library.favorites
                        .where((favorite) => favorite.id != fav.id)
                        .toList(growable: false),
                  ),
                );
              } else if (action == 'move') {
                final selectedFolder = await showDialog<BookmarkFolder?>(
                  context: context,
                  builder: (dialogCtx) => AlertDialog(
                    title: const Text('Move to folder'),
                    content: SizedBox(
                      width: 280,
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          ListTile(
                            title: const Text('Unsorted'),
                            onTap: () =>
                                Navigator.of(dialogCtx).pop(unsortedFolder),
                          ),
                          const Divider(),
                          for (final f in library.folders)
                            ListTile(
                              title: Text(f.name),
                              onTap: () => Navigator.of(dialogCtx).pop(f),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
                if (selectedFolder != null) {
                  final targetFolderId = selectedFolder.id == '__unsorted__'
                      ? null
                      : selectedFolder.id;
                  await onSaveLibrary(
                    library.copyWith(
                      favorites: library.favorites
                          .map((f) => f.id == fav.id
                              ? f.copyWith(
                                  folderId: targetFolderId,
                                  clearFolder: targetFolderId == null,
                                )
                              : f)
                          .toList(growable: false),
                    ),
                  );
                }
              } else if (action == 'edit') {
                final updatedLib = await onEditFavorite(fav);
                if (updatedLib != null) {
                  await onSaveLibrary(updatedLib);
                }
              }
              onNewFolderCreated();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit tags')),
              PopupMenuItem(value: 'move', child: Text('Move to folder…')),
              PopupMenuItem(value: 'delete', child: Text('Remove bookmark')),
            ],
          ),
          onTap: () {
            Navigator.of(context).pop();
            unawaited(onLoadUrl(fav.url));
          },
        );
      },
    );
  }

  if (isUnsorted) {
    return listWidget;
  }

  return Column(
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton.icon(
              icon: const Icon(Icons.edit, size: 16),
              label:
                  const Text('Rename folder', style: TextStyle(fontSize: 12)),
              onPressed: () async {
                final nameController = TextEditingController(text: folder.name);
                final newName = await showDialog<String>(
                  context: sheetContext,
                  builder: (dialogCtx) => AlertDialog(
                    title: const Text('Rename folder'),
                    content: TextField(
                      controller: nameController,
                      autofocus: true,
                      decoration: const InputDecoration(
                        hintText: 'Folder name',
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(dialogCtx).pop(),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(dialogCtx)
                            .pop(nameController.text.trim()),
                        child: const Text('Save'),
                      ),
                    ],
                  ),
                );
                nameController.dispose();
                if (newName == null || newName.isEmpty || newName == folder.name) return;

                final updatedFolders = library.folders.map((f) {
                  return f.id == folder.id
                      ? BookmarkFolder(
                          id: f.id,
                          name: newName,
                          createdAt: f.createdAt,
                        )
                      : f;
                }).toList();

                 await onSaveLibrary(library.copyWith(folders: updatedFolders));
                 onNewFolderCreated();
               },
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              icon: const Icon(Icons.delete_outline, size: 16),
              label:
                  const Text('Delete folder', style: TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: sheetContext,
                  builder: (dialogCtx) => AlertDialog(
                    title: const Text('Delete folder?'),
                    content: const Text(
                      'All bookmarks inside this folder will be moved to Unsorted.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(dialogCtx).pop(false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(dialogCtx).pop(true),
                        style: TextButton.styleFrom(foregroundColor: Colors.red),
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                );
                if (confirm != true) return;

                final updatedFolders =
                    library.folders.where((f) => f.id != folder.id).toList();
                final updatedFavorites = library.favorites.map((fav) {
                  if (fav.folderId == folder.id) {
                    return fav.copyWith(clearFolder: true);
                  }
                  return fav;
                }).toList();

                 await onSaveLibrary(
                   library.copyWith(
                     folders: updatedFolders,
                     favorites: updatedFavorites,
                   ),
                 );
                 onNewFolderCreated();
               },
            ),
          ],
        ),
      ),
      const Divider(height: 1),
      Expanded(child: listWidget),
    ],
  );
}

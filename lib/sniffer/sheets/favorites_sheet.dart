import 'dart:async';

import 'package:flutter/material.dart';

import '../../premium/pro_entitlement.dart';
import '../../premium/pro_upsell_sheet.dart';
import '../browser_library.dart';
import '../models/browser_tab.dart';
import '../video_library.dart';
import '../../theme/aurora_palette.dart';
import 'video_library_views.dart';

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
  required Future<BrowserLibrary?> Function(BrowserFavorite favorite)
      onEditFavorite,
  /// Plays a saved video. Null falls back to loading its URL as a page.
  Future<void> Function(BrowserFavorite favorite)? onPlayVideo,
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
        onPlayVideo: onPlayVideo,
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
  final Future<BrowserLibrary?> Function(BrowserFavorite favorite)
      onEditFavorite;
  final Future<void> Function(BrowserFavorite favorite)? onPlayVideo;

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
    this.onPlayVideo,
  });

  @override
  State<FavoritesSheetContent> createState() => _FavoritesSheetContentState();
}

class _FavoritesSheetContentState extends State<FavoritesSheetContent>
    with TickerProviderStateMixin {
  late BrowserLibrary _currentLibrary;
  TabController? _tabController;
  late List<BookmarkFolder> _folders;
  LibrarySection _section = LibrarySection.sites;

  /// Controllers waiting for a safe post-frame dispose (after TabBar has
  /// detached). Prevents `_dependents.isEmpty` crashes when recreating
  /// the controller after "New folder".
  final List<TabController> _pendingDispose = [];

  @override
  void initState() {
    super.initState();
    _currentLibrary = widget.library;
    _folders = _buildFolders(_currentLibrary);
    _tabController = TabController(length: _folders.length, vsync: this);
  }

  @override
  void didUpdateWidget(covariant FavoritesSheetContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Do not call setState here — parent rebuilds already schedule a frame.
    if (widget.library != oldWidget.library) {
      _applyLibrary(widget.library);
    }
  }

  @override
  void dispose() {
    for (final c in _pendingDispose) {
      c.dispose();
    }
    _pendingDispose.clear();
    _tabController?.dispose();
    _tabController = null;
    super.dispose();
  }

  List<BookmarkFolder> _buildFolders(BrowserLibrary library) {
    return [widget.unsortedFolder, ...library.folders];
  }

  /// Updates library + folder list. Recreates [TabController] only when the
  /// tab count changes (creating/deleting a folder). Favorite edits alone
  /// keep the same controller — recreating every time caused the red-screen
  /// `_dependents.isEmpty` assert.
  void _applyLibrary(
    BrowserLibrary library, {
    String? preferFolderId,
  }) {
    final nextFolders = _buildFolders(library);
    final old = _tabController;

    _currentLibrary = library;
    _folders = nextFolders;

    // Keep the same controller when tab count is unchanged (rename / move /
    // tag edits). Recreating on every library save disposed a TabController
    // that TabBar still depended on → red screen `_dependents.isEmpty`.
    if (old != null && old.length == nextFolders.length) {
      if (preferFolderId != null) {
        final idx = nextFolders.indexWhere((f) => f.id == preferFolderId);
        if (idx >= 0 && idx != old.index) {
          old.animateTo(idx);
        }
      }
      return;
    }

    var initialIndex = (old?.index ?? 0).clamp(0, nextFolders.length - 1);
    if (preferFolderId != null) {
      final preferred =
          nextFolders.indexWhere((f) => f.id == preferFolderId);
      if (preferred >= 0) initialIndex = preferred;
    }

    final next = TabController(
      length: nextFolders.length,
      vsync: this,
      initialIndex: initialIndex,
    );
    _tabController = next;

    if (old != null) {
      // Detach first (next build uses [next]), then dispose old safely.
      _pendingDispose.add(old);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          // State already disposed — dispose() drained the list.
          return;
        }
        if (_pendingDispose.remove(old)) {
          old.dispose();
        }
      });
    }
  }

  Future<void> _createNewFolder() async {
    final nameController = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Create folder'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Folder name',
          ),
          onSubmitted: (v) => Navigator.of(dialogCtx).pop(v.trim()),
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
    if (name == null || name.isEmpty || !mounted) return;

    final folder = BookmarkFolder(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
      createdAt: DateTime.now(),
    );
    final updatedLibrary = _currentLibrary.copyWith(
      folders: [..._currentLibrary.folders, folder],
    );
    await widget.onSaveLibrary(updatedLibrary);
    if (!mounted) return;

    setState(() {
      _applyLibrary(updatedLibrary, preferFolderId: folder.id);
    });
    widget.onFavoriteToggled();
  }

  Future<void> _onLibrarySaved(
    BrowserLibrary updatedLib, {
    String? preferFolderId,
  }) async {
    await widget.onSaveLibrary(updatedLib);
    if (!mounted) return;
    setState(() {
      _applyLibrary(updatedLib, preferFolderId: preferFolderId);
    });
    widget.onFavoriteToggled();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _tabController;
    if (controller == null) {
      return const SizedBox.shrink();
    }

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Icon(Icons.star, color: context.ac.accentAmber),
                const SizedBox(width: 8),
                const Text(
                  'Favorites',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                if (_section == LibrarySection.sites)
                  TextButton.icon(
                    onPressed: _createNewFolder,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('New folder'),
                  ),
              ],
            ),
          ),
          LibrarySectionBar(
            current: _section,
            videoCount: _currentLibrary.videoFavorites.length,
            onChanged: (s) => setState(() => _section = s),
          ),
          if (_section == LibrarySection.videos)
            _buildVideosSection(context)
          else
            ..._buildSitesSection(controller),
        ],
      ),
    );
  }

  /// Saved videos. Flat, and gated by the free inventory cap — folders are a
  /// page-organising idea and every saved video would land in "Unsorted".
  Widget _buildVideosSection(BuildContext context) {
    final tier = proUpsellEntitlement?.tier ?? EntitlementTier.free;
    final limit = VideoLibrary.freeLimitFor(tier);
    final videos = _currentLibrary.videoFavorites;

    // Fixed height, matching the folder view — the sheet's Column is
    // MainAxisSize.min, so an Expanded here would be unbounded and throw.
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.55,
      child: Column(
        children: [
          if (limit != null)
            VideoGateBanner(
              used: videos.length,
              limit: limit,
              tier: tier,
              message: 'Pro saves unlimited videos',
            ),
          Expanded(
            child: VideoFavoritesList(
              items: videos,
              onOpen: (fav) async {
                Navigator.of(context).pop();
                final play = widget.onPlayVideo;
                if (play != null) {
                  await play(fav);
                } else {
                  await widget.onLoadUrl(fav.url);
                }
              },
              onOpenSourcePage: (fav) {
                Navigator.of(context).pop();
                unawaited(widget.onLoadUrl(fav.sourcePageUrl!));
              },
              onRemove: (fav) async {
                await _onLibrarySaved(
                  VideoLibrary.removeFavorite(_currentLibrary, fav.id),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildSitesSection(TabController controller) {
    return [
      TabBar(
            // Key forces a clean TabBar when length changes so it never
            // keeps a disposed controller identity across rebuilds.
            key: ValueKey('fav_tabs_${controller.length}_${controller.hashCode}'),
            controller: controller,
            isScrollable: true,
            tabs: [
              for (final folder in _folders) Tab(text: folder.name),
            ],
          ),
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.55,
            child: TabBarView(
              key: ValueKey(
                'fav_views_${controller.length}_${controller.hashCode}',
              ),
              controller: controller,
              children: [
                for (final folder in _folders)
                  KeyedSubtree(
                    key: ValueKey('folder_tab_${folder.id}'),
                    child: buildFavoritesFolderList(
                      context,
                      widget.activeTab,
                      folder,
                      _currentLibrary.favoritesInFolder(
                        folder.id == '__unsorted__' ? null : folder.id,
                      ),
                      library: _currentLibrary,
                      unsortedFolder: widget.unsortedFolder,
                      isCurrentPageFavorited: widget.isCurrentPageFavorited,
                      onSaveLibrary: (updatedLib) =>
                          _onLibrarySaved(updatedLib),
                      onLoadUrl: widget.onLoadUrl,
                      onFavoriteToggled: widget.onFavoriteToggled,
                      onNewFolderCreated: () async {
                        // Library already saved by caller; just refresh tabs
                        // if parent pushed a different library later.
                        if (!mounted) return;
                        setState(() {
                          _applyLibrary(_currentLibrary);
                        });
                        widget.onFavoriteToggled();
                      },
                      onEditFavorite: widget.onEditFavorite,
                    ),
                  ),
              ],
            ),
          ),
    ];
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
  required Future<BrowserLibrary?> Function(BrowserFavorite favorite)
      onEditFavorite,
}) {
  final isUnsorted = folder.id == '__unsorted__';

  Widget listWidget;
  if (items.isEmpty) {
    listWidget = Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'No bookmarks in ${folder.name}.',
          style: TextStyle(color: sheetContext.ac.textSecondary),
        ),
      ),
    );
  } else {
    listWidget = ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, i) {
        final fav = items[i];
        return ListTile(
          leading: Icon(Icons.star, color: sheetContext.ac.accentAmber),
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
                            color: sheetContext.ac.surfaceElevated,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            tag,
                            style: TextStyle(
                              fontSize: 10,
                              color: sheetContext.ac.accentFrost,
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
              await onNewFolderCreated();
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
                final nameController =
                    TextEditingController(text: folder.name);
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
                if (newName == null ||
                    newName.isEmpty ||
                    newName == folder.name) {
                  return;
                }

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
                        style:
                            TextButton.styleFrom(foregroundColor: Colors.red),
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

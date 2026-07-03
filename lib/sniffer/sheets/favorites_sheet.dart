import 'dart:async';

import 'package:flutter/material.dart';

import '../browser_library.dart';
import '../models/browser_tab.dart';
import '../../theme/aurora_colors.dart';

/// Shows the favorites bottom sheet for the given [activeTab] and
/// [library]. Favorites are grouped by folder (with an implicit
/// "Unsorted" pseudo-folder for favorites with no folder).
///
/// Standalone library — all state-mutating side effects are delegated
/// via callbacks so this function can be unit-tested in isolation.
///
/// Parameters in detail:
/// - [isCurrentPageFavorited]: caller checks whether the active tab's
///   current URL is already a favorite. Currently unused inside the
///   sheet itself (kept for parity with the in-class implementation
///   and future use).
/// - [onFavoriteToggled]: caller rebuilds the host widget after a
///   favorite was toggled. Currently unused inside the sheet itself
///   (the sheet is rebuilt via [onNewFolderCreated] / [onEditFavorite]
///   instead).
/// - [onNewFolderCreated]: called when a new folder was just created
///   or when the existing list changed (delete / move) and the sheet
///   should pop itself and reopen to reflect the new state. Equivalent
///   to the original `Navigator.pop(ctx); _showFavoritesSheet();`
///   pattern in the host class.
/// - [onEditFavorite]: called when the user picks "Move / edit tags"
///   on a favorite. The host's `_editFavoriteFolder` is wired here.
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
  required Future<void> Function(BrowserFavorite favorite) onEditFavorite,
}) {
  final tab = activeTab;
  final folders = <BookmarkFolder>[unsortedFolder, ...library.folders];
  final folderItems = folders;
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) {
      return SafeArea(
        child: DefaultTabController(
          length: folderItems.length,
          child: Column(
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
                      onPressed: () async {
                        // Show dialog on top of the sheet (sheet remains
                        // stable so DefaultTabController's inherited element
                        // stays alive during setState). Pop + reopen only
                        // after the folder is created.
                        final nameController = TextEditingController();
                        final name = await showDialog<String>(
                          context: ctx,
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
                                onPressed: () =>
                                    Navigator.of(dialogCtx).pop(),
                                child: const Text('Cancel'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.of(
                                  dialogCtx,
                                ).pop(nameController.text.trim()),
                                child: const Text('Create'),
                              ),
                            ],
                          ),
                        );
                        nameController.dispose();
                        if (name == null || name.isEmpty) return;
                        final folder = BookmarkFolder(
                          id: DateTime.now().microsecondsSinceEpoch
                              .toString(),
                          name: name,
                          createdAt: DateTime.now(),
                        );
                        await onSaveLibrary(
                          library.copyWith(
                            folders: [...library.folders, folder],
                          ),
                        );
                        onNewFolderCreated();
                      },
                      icon: const Icon(Icons.create_new_folder_outlined),
                      label: const Text('New folder'),
                    ),
                  ],
                ),
              ),
              TabBar(
                isScrollable: true,
                tabs: [
                  for (final folder in folderItems) Tab(text: folder.name),
                ],
              ),
              SizedBox(
                height: MediaQuery.of(ctx).size.height * 0.55,
                child: TabBarView(
                  children: [
                    for (final folder in folderItems)
                      buildFavoritesFolderList(
                        ctx,
                        tab,
                        folder,
                        library.favoritesInFolder(
                          folder.id == '__unsorted__' ? null : folder.id,
                        ),
                        library: library,
                        isCurrentPageFavorited: isCurrentPageFavorited,
                        onSaveLibrary: onSaveLibrary,
                        onLoadUrl: onLoadUrl,
                        onFavoriteToggled: onFavoriteToggled,
                        onNewFolderCreated: onNewFolderCreated,
                        onEditFavorite: onEditFavorite,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

Widget buildFavoritesFolderList(
  BuildContext sheetContext,
  BrowserTab tab,
  BookmarkFolder folder,
  List<BrowserFavorite> items, {
  required BrowserLibrary library,
  required bool Function(String url) isCurrentPageFavorited,
  required Future<void> Function(BrowserLibrary) onSaveLibrary,
  required Future<void> Function(String url) onLoadUrl,
  required VoidCallback onFavoriteToggled,
  required Future<void> Function() onNewFolderCreated,
  required Future<void> Function(BrowserFavorite favorite) onEditFavorite,
}) {
  if (items.isEmpty) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Nothing saved in ${folder.name}.',
          style: const TextStyle(color: AuroraColors.mutedText),
        ),
      ),
    );
  }
  return ListView.builder(
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
            } else if (action == 'move' && folder.id != '__unsorted__') {
              await onEditFavorite(fav);
            } else if (action == 'edit' && folder.id != '__unsorted__') {
              await onEditFavorite(fav);
            } else if (action == 'edit') {
              await onEditFavorite(fav);
            }
            if (context.mounted) {
              onNewFolderCreated();
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'edit', child: Text('Move / edit tags')),
            PopupMenuItem(value: 'delete', child: Text('Delete')),
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

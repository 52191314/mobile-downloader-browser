import 'package:flutter/material.dart';

import '../browser_library.dart';
import '../models/favorite_selection.dart';

/// Dialog to pick folder + tags when adding a favorite.
Future<FavoriteSelection?> showPromptFavoriteFolderDialog({
  required BuildContext context,
  required List<BookmarkFolder> folders,
}) async {
  final folderList = List<BookmarkFolder>.from(folders);
  String? folderId;
  final tagsController = TextEditingController();
  final newFolderController = TextEditingController();
  final result = await showDialog<FavoriteSelection>(
    context: context,
    builder: (ctx) {
      return AlertDialog(
        title: const Text('Add to favorites'),
        content: StatefulBuilder(
          builder: (ctx, setLocal) {
            return SizedBox(
              width: 320,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Folder', style: TextStyle(fontSize: 12)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String?>(
                    // ignore: deprecated_member_use
                    value: folderId,
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: 'Unsorted',
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('Unsorted'),
                      ),
                      for (final folder in folderList)
                        DropdownMenuItem<String?>(
                          value: folder.id,
                          child: Text(folder.name),
                        ),
                    ],
                    onChanged: (value) => setLocal(() => folderId = value),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: newFolderController,
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: 'Create new folder',
                      prefixIcon: Icon(Icons.create_new_folder_outlined),
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextButton.icon(
                    onPressed: () {
                      final name = newFolderController.text.trim();
                      if (name.isEmpty) return;
                      final newFolder = BookmarkFolder(
                        id: DateTime.now().microsecondsSinceEpoch.toString(),
                        name: name,
                        createdAt: DateTime.now(),
                      );
                      folderList.add(newFolder);
                      folderId = newFolder.id;
                      newFolderController.clear();
                      setLocal(() {});
                    },
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Add folder'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: tagsController,
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: 'Tags (comma separated)',
                      prefixIcon: Icon(Icons.label_outline),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final tags = tagsController.text
                  .split(',')
                  .map((tag) => tag.trim())
                  .where((tag) => tag.isNotEmpty)
                  .toList(growable: false);
              Navigator.of(ctx).pop(
                FavoriteSelection(
                  folderId: folderId,
                  folderName: folderId == null
                      ? null
                      : folderList
                            .where((folder) => folder.id == folderId)
                            .map((folder) => folder.name)
                            .firstOrNull,
                  tags: tags,
                  updatedFolders: folderList,
                ),
              );
            },
            child: const Text('Save'),
          ),
        ],
      );
    },
  );
  tagsController.dispose();
  newFolderController.dispose();
  return result;
}

/// Result of editing a favorite's folder/tags (before library save).
class EditFavoriteResult {
  final String? folderId;
  final List<String> tags;

  const EditFavoriteResult({required this.folderId, required this.tags});
}

/// Dialog to edit folder + tags for an existing favorite.
/// Returns null if cancelled.
Future<EditFavoriteResult?> showEditFavoriteDialog({
  required BuildContext context,
  required BrowserFavorite favorite,
  required List<BookmarkFolder> folders,
}) async {
  String? folderId = favorite.folderId;
  final tagsController = TextEditingController(text: favorite.tags.join(', '));
  final saved = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Edit favorite'),
      content: StatefulBuilder(
        builder: (ctx, setLocal) => SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Folder', style: TextStyle(fontSize: 12)),
              const SizedBox(height: 6),
              DropdownButtonFormField<String?>(
                // ignore: deprecated_member_use
                value: folderId,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'Unsorted',
                ),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Unsorted'),
                  ),
                  for (final folder in folders)
                    DropdownMenuItem<String?>(
                      value: folder.id,
                      child: Text(folder.name),
                    ),
                ],
                onChanged: (value) => setLocal(() => folderId = value),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: tagsController,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'Tags (comma separated)',
                  prefixIcon: Icon(Icons.label_outline),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  if (saved != true) {
    tagsController.dispose();
    return null;
  }
  final tags = tagsController.text
      .split(',')
      .map((tag) => tag.trim())
      .where((tag) => tag.isNotEmpty)
      .toList(growable: false);
  tagsController.dispose();
  return EditFavoriteResult(folderId: folderId, tags: tags);
}

/// Applies [edit] to [library] and returns the updated library.
BrowserLibrary applyFavoriteEdit(
  BrowserLibrary library,
  BrowserFavorite favorite,
  EditFavoriteResult edit,
) {
  return library.copyWith(
    favorites: library.favorites
        .map(
          (fav) => fav.id == favorite.id
              ? fav.copyWith(
                  folderId: edit.folderId,
                  clearFolder: edit.folderId == null,
                  tags: edit.tags,
                )
              : fav,
        )
        .toList(growable: false),
  );
}

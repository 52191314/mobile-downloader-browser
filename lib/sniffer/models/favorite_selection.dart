import '../browser_library.dart';

class FavoriteSelection {
  final String? folderId;
  final String? folderName;
  final List<String> tags;
  final List<BookmarkFolder>? updatedFolders;

  const FavoriteSelection({
    required this.folderId,
    required this.folderName,
    required this.tags,
    this.updatedFolders,
  });
}

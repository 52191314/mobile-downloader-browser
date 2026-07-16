import 'media_file_types.dart';

export 'media_file_types.dart' show FileCategory;

/// Maps file extensions to category folders for auto-classification.
///
/// Extension data lives in [MediaFileTypes]; this class is the thin
/// API used by [DownloadQueue].
class FileClassifier {
  FileClassifier._();

  /// Classifies a file by its extension (from a file path or URL).
  ///
  /// Returns [FileCategory.other] for unrecognised extensions or when no
  /// extension can be extracted.
  static FileCategory classify(String path) {
    final ext = MediaFileTypes.extensionOf(path);
    return MediaFileTypes.categoryForExtension(ext);
  }

  /// Folder label for [path], applying optional custom extension→folder maps.
  static String folderLabelFor(
    String path, {
    Map<String, String> customMappings = const {},
  }) {
    return MediaFileTypes.folderLabelForPath(
      path,
      customFolderMappings: customMappings,
    );
  }

  /// Human-readable folder name for a category.
  static String categoryLabel(FileCategory c) {
    return MediaFileTypes.categoryLabel(c);
  }
}

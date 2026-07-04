/// Categories into which downloaded files are automatically sorted.
enum FileCategory {
  videos,
  audio,
  images,
  documents,
  archives,
  applications,
  torrents,
  subtitles,
  playlists,
  other,
}

/// Maps file extensions to category folders for auto-classification.
class FileClassifier {
  FileClassifier._();

  static const Map<String, FileCategory> _extMap = {
    // ── Videos ──
    '.mp4': FileCategory.videos,
    '.mkv': FileCategory.videos,
    '.webm': FileCategory.videos,
    '.avi': FileCategory.videos,
    '.mov': FileCategory.videos,
    '.flv': FileCategory.videos,
    '.wmv': FileCategory.videos,
    '.m4v': FileCategory.videos,
    '.3gp': FileCategory.videos,
    '.ts': FileCategory.videos,
    // ── Audio ──
    '.mp3': FileCategory.audio,
    '.aac': FileCategory.audio,
    '.flac': FileCategory.audio,
    '.ogg': FileCategory.audio,
    '.wav': FileCategory.audio,
    '.m4a': FileCategory.audio,
    '.wma': FileCategory.audio,
    '.opus': FileCategory.audio,
    // ── Images ──
    '.jpg': FileCategory.images,
    '.jpeg': FileCategory.images,
    '.png': FileCategory.images,
    '.gif': FileCategory.images,
    '.webp': FileCategory.images,
    '.bmp': FileCategory.images,
    '.svg': FileCategory.images,
    '.ico': FileCategory.images,
    '.heic': FileCategory.images,
    '.heif': FileCategory.images,
    // ── Documents ──
    '.pdf': FileCategory.documents,
    '.doc': FileCategory.documents,
    '.docx': FileCategory.documents,
    '.xls': FileCategory.documents,
    '.xlsx': FileCategory.documents,
    '.ppt': FileCategory.documents,
    '.pptx': FileCategory.documents,
    '.txt': FileCategory.documents,
    '.csv': FileCategory.documents,
    '.rtf': FileCategory.documents,
    '.odt': FileCategory.documents,
    '.epub': FileCategory.documents,
    '.md': FileCategory.documents,
    // ── Archives / Compressed ──
    '.zip': FileCategory.archives,
    '.rar': FileCategory.archives,
    '.7z': FileCategory.archives,
    '.tar': FileCategory.archives,
    '.gz': FileCategory.archives,
    '.bz2': FileCategory.archives,
    '.xz': FileCategory.archives,
    '.zst': FileCategory.archives,
    '.br': FileCategory.archives,
    // ── Applications ──
    '.apk': FileCategory.applications,
    '.exe': FileCategory.applications,
    '.dmg': FileCategory.applications,
    '.deb': FileCategory.applications,
    '.rpm': FileCategory.applications,
    '.appimage': FileCategory.applications,
    '.msi': FileCategory.applications,
    // ── Torrents ──
    '.torrent': FileCategory.torrents,
    // ── Subtitles ──
    '.srt': FileCategory.subtitles,
    '.ass': FileCategory.subtitles,
    '.vtt': FileCategory.subtitles,
    '.sub': FileCategory.subtitles,
    // ── Playlists / Streaming manifests ──
    '.m3u8': FileCategory.playlists,
    '.mpd': FileCategory.playlists,
    '.m3u': FileCategory.playlists,
  };

  /// Classifies a file by its extension (from a file path or URL).
  ///
  /// Returns [FileCategory.other] for unrecognised extensions or when no
  /// extension can be extracted.
  static FileCategory classify(String path) {
    final ext = _extension(path);
    if (ext == null) return FileCategory.other;
    return _extMap[ext.toLowerCase()] ?? FileCategory.other;
  }

  /// Human-readable folder name for a category.
  static String categoryLabel(FileCategory c) {
    return switch (c) {
      FileCategory.videos => 'Videos',
      FileCategory.audio => 'Audio',
      FileCategory.images => 'Images',
      FileCategory.documents => 'Documents',
      FileCategory.archives => 'Archives',
      FileCategory.applications => 'Applications',
      FileCategory.torrents => 'Torrents',
      FileCategory.subtitles => 'Subtitles',
      FileCategory.playlists => 'Playlists',
      FileCategory.other => 'Other',
    };
  }

  /// Extracts the file extension (including leading dot) from a path or URL.
  /// Returns `null` when no extension is present.
  static String? _extension(String path) {
    try {
      final normalized = path.replaceAll('\\', '/');
      final last = normalized.split('/').last;
      final dot = last.lastIndexOf('.');
      if (dot <= 0 || dot >= last.length - 1) return null;
      return last.substring(dot);
    } catch (_) {
      return null;
    }
  }
}

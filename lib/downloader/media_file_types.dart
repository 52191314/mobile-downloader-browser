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

/// Single source of truth for extension ↔ MIME ↔ category mappings used by
/// naming, publish, auto-classify, and sniffer container labels.
class MediaFileTypes {
  MediaFileTypes._();

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

  /// Extension (with leading dot, lowercased) → primary MIME type.
  static const Map<String, String> mimeByExtension = {
    // Video
    '.mp4': 'video/mp4',
    '.m4v': 'video/mp4',
    '.webm': 'video/webm',
    '.mkv': 'video/x-matroska',
    '.mov': 'video/quicktime',
    '.avi': 'video/x-msvideo',
    '.flv': 'video/x-flv',
    '.wmv': 'video/x-ms-wmv',
    '.3gp': 'video/3gpp',
    '.ts': 'video/mp2t',
    '.m2ts': 'video/mp2t',
    '.mts': 'video/mp2t',
    '.m4s': 'video/iso.segment',
    '.ogv': 'video/ogg',
    '.hevc': 'video/hevc',
    // Audio
    '.mp3': 'audio/mpeg',
    '.m4a': 'audio/mp4',
    '.aac': 'audio/aac',
    '.flac': 'audio/flac',
    '.ogg': 'audio/ogg',
    '.opus': 'audio/opus',
    '.wav': 'audio/wav',
    '.wma': 'audio/x-ms-wma',
    // Images
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.png': 'image/png',
    '.gif': 'image/gif',
    '.webp': 'image/webp',
    '.bmp': 'image/bmp',
    '.svg': 'image/svg+xml',
    '.ico': 'image/x-icon',
    '.heic': 'image/heic',
    '.heif': 'image/heif',
    // Documents
    '.pdf': 'application/pdf',
    '.doc': 'application/msword',
    '.docx':
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    '.xls': 'application/vnd.ms-excel',
    '.xlsx':
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    '.ppt': 'application/vnd.ms-powerpoint',
    '.pptx':
        'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    '.txt': 'text/plain',
    '.csv': 'text/csv',
    '.rtf': 'application/rtf',
    '.odt': 'application/vnd.oasis.opendocument.text',
    '.epub': 'application/epub+zip',
    '.md': 'text/markdown',
    '.json': 'application/json',
    '.xml': 'application/xml',
    '.html': 'text/html',
    '.htm': 'text/html',
    // Archives
    '.zip': 'application/zip',
    '.rar': 'application/vnd.rar',
    '.7z': 'application/x-7z-compressed',
    '.tar': 'application/x-tar',
    '.gz': 'application/gzip',
    '.bz2': 'application/x-bzip2',
    '.xz': 'application/x-xz',
    '.zst': 'application/zstd',
    '.br': 'application/x-br',
    // Apps
    '.apk': 'application/vnd.android.package-archive',
    '.exe': 'application/vnd.microsoft.portable-executable',
    '.dmg': 'application/x-apple-diskimage',
    '.deb': 'application/vnd.debian.binary-package',
    '.rpm': 'application/x-rpm',
    '.msi': 'application/x-msi',
    '.appimage': 'application/x-iso9660-appimage',
    // Torrents / playlists / subtitles
    '.torrent': 'application/x-bittorrent',
    '.m3u8': 'application/vnd.apple.mpegurl',
    '.m3u': 'audio/x-mpegurl',
    '.mpd': 'application/dash+xml',
    '.srt': 'application/x-subrip',
    '.ass': 'text/x-ssa',
    '.vtt': 'text/vtt',
    '.sub': 'text/x-microdvd',
  };

  /// MIME type (lowercased, no parameters) → preferred extension.
  static const Map<String, String> extensionByMime = {
    'video/mp4': '.mp4',
    'video/webm': '.webm',
    'video/x-matroska': '.mkv',
    'video/quicktime': '.mov',
    'video/x-msvideo': '.avi',
    'video/x-flv': '.flv',
    'video/x-ms-wmv': '.wmv',
    'video/3gpp': '.3gp',
    'video/mp2t': '.ts',
    'video/iso.segment': '.m4s',
    'video/ogg': '.ogv',
    'video/hevc': '.hevc',
    'application/vnd.apple.mpegurl': '.m3u8',
    'application/x-mpegurl': '.m3u8',
    'application/dash+xml': '.mpd',
    'audio/mpeg': '.mp3',
    'audio/mp4': '.m4a',
    'audio/aac': '.aac',
    'audio/flac': '.flac',
    'audio/ogg': '.ogg',
    'audio/opus': '.opus',
    'audio/wav': '.wav',
    'audio/x-ms-wma': '.wma',
    'audio/x-mpegurl': '.m3u',
    'image/jpeg': '.jpg',
    'image/png': '.png',
    'image/gif': '.gif',
    'image/webp': '.webp',
    'image/bmp': '.bmp',
    'image/svg+xml': '.svg',
    'image/x-icon': '.ico',
    'image/heic': '.heic',
    'image/heif': '.heif',
    'application/pdf': '.pdf',
    'application/msword': '.doc',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document':
        '.docx',
    'application/vnd.ms-excel': '.xls',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet':
        '.xlsx',
    'application/vnd.ms-powerpoint': '.ppt',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation':
        '.pptx',
    'text/plain': '.txt',
    'text/csv': '.csv',
    'application/rtf': '.rtf',
    'application/vnd.oasis.opendocument.text': '.odt',
    'application/epub+zip': '.epub',
    'text/markdown': '.md',
    'application/json': '.json',
    'application/xml': '.xml',
    'text/html': '.html',
    'application/zip': '.zip',
    'application/vnd.rar': '.rar',
    'application/x-7z-compressed': '.7z',
    'application/x-tar': '.tar',
    'application/gzip': '.gz',
    'application/x-bzip2': '.bz2',
    'application/x-xz': '.xz',
    'application/zstd': '.zst',
    'application/x-br': '.br',
    'application/vnd.android.package-archive': '.apk',
    'application/vnd.microsoft.portable-executable': '.exe',
    'application/x-apple-diskimage': '.dmg',
    'application/vnd.debian.binary-package': '.deb',
    'application/x-rpm': '.rpm',
    'application/x-msi': '.msi',
    'application/x-iso9660-appimage': '.appimage',
    'application/x-bittorrent': '.torrent',
    'application/x-subrip': '.srt',
    'text/x-ssa': '.ass',
    'text/vtt': '.vtt',
    'text/x-microdvd': '.sub',
  };

  /// Extension → default folder category.
  static const Map<String, FileCategory> categoryByExtension = {
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
    '.m2ts': FileCategory.videos,
    '.mts': FileCategory.videos,
    '.m4s': FileCategory.videos,
    '.ogv': FileCategory.videos,
    '.hevc': FileCategory.videos,
    '.mp3': FileCategory.audio,
    '.aac': FileCategory.audio,
    '.flac': FileCategory.audio,
    '.ogg': FileCategory.audio,
    '.wav': FileCategory.audio,
    '.m4a': FileCategory.audio,
    '.wma': FileCategory.audio,
    '.opus': FileCategory.audio,
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
    '.json': FileCategory.documents,
    '.xml': FileCategory.documents,
    '.html': FileCategory.documents,
    '.htm': FileCategory.documents,
    '.zip': FileCategory.archives,
    '.rar': FileCategory.archives,
    '.7z': FileCategory.archives,
    '.tar': FileCategory.archives,
    '.gz': FileCategory.archives,
    '.bz2': FileCategory.archives,
    '.xz': FileCategory.archives,
    '.zst': FileCategory.archives,
    '.br': FileCategory.archives,
    '.apk': FileCategory.applications,
    '.exe': FileCategory.applications,
    '.dmg': FileCategory.applications,
    '.deb': FileCategory.applications,
    '.rpm': FileCategory.applications,
    '.appimage': FileCategory.applications,
    '.msi': FileCategory.applications,
    '.torrent': FileCategory.torrents,
    '.srt': FileCategory.subtitles,
    '.ass': FileCategory.subtitles,
    '.vtt': FileCategory.subtitles,
    '.sub': FileCategory.subtitles,
    '.m3u8': FileCategory.playlists,
    '.mpd': FileCategory.playlists,
    '.m3u': FileCategory.playlists,
  };

  /// Canonical container format label for UI (from path extension).
  static String? containerFormatForExtension(String ext) {
    final e = _normExt(ext);
    return switch (e) {
      '.mp4' || '.m4v' || '.m4a' => 'mp4',
      '.webm' => 'webm',
      '.mkv' => 'matroska',
      '.mp3' => 'mp3',
      '.flac' => 'flac',
      '.ogg' => 'ogg',
      '.ts' || '.m2ts' || '.mts' => 'mpeg-ts',
      '.avi' => 'avi',
      '.mov' => 'quicktime',
      '.wav' => 'wav',
      '.aac' => 'aac',
      '.opus' => 'opus',
      '.flv' => 'flv',
      '.3gp' => '3gp',
      '.ogv' => 'ogv',
      '.wmv' => 'wmv',
      '.hevc' => 'hevc',
      '.m4s' => 'fmp4',
      _ => null,
    };
  }

  static String mimeTypeForName(String path) {
    final ext = extensionOf(path);
    if (ext == null) return 'application/octet-stream';
    return mimeByExtension[ext] ?? 'application/octet-stream';
  }

  static String? extensionForMime(String mimeType) {
    final clean = mimeType.split(';').first.trim().toLowerCase();
    if (clean.isEmpty) return null;
    return extensionByMime[clean];
  }

  static FileCategory categoryForExtension(
    String? ext, {
    Map<String, String> customFolderMappings = const {},
  }) {
    if (ext == null || ext.isEmpty) return FileCategory.other;
    final e = _normExt(ext);

    // Custom mappings: ".mp4" → "Movies" (folder label override handled
    // by caller when non-empty). Category is still derived when mapping
    // is absent.
    if (customFolderMappings.containsKey(e) ||
        customFolderMappings.containsKey(e.substring(1))) {
      // Mapping only overrides folder name; category lookup still useful
      // for default labels when mapping value is empty.
    }

    return categoryByExtension[e] ?? FileCategory.other;
  }

  /// Returns the folder label for a path, applying optional
  /// [customFolderMappings] (keys may be ".mp4" or "mp4").
  static String folderLabelForPath(
    String path, {
    Map<String, String> customFolderMappings = const {},
  }) {
    final ext = extensionOf(path);
    if (ext != null) {
      final mapped = customFolderMappings[ext] ??
          customFolderMappings[ext.substring(1)];
      if (mapped != null && mapped.trim().isNotEmpty) {
        return mapped.trim();
      }
    }
    final category = categoryForExtension(ext);
    return categoryLabel(category);
  }

  /// File extension including the leading dot, lowercased, or null.
  static String? extensionOf(String pathOrUrl) {
    try {
      var s = pathOrUrl.trim();
      // Prefer path part of URLs — never treat the host (e.g. `.com`) as an
      // extension. Domain-only URLs (`https://example.com`) have an empty
      // path and correctly yield null.
      final uri = Uri.tryParse(s);
      if (uri != null && uri.hasScheme && (uri.host.isNotEmpty || uri.hasAuthority)) {
        s = uri.path;
        if (s.isEmpty || s == '/') return null;
      }
      s = s.replaceAll('\\', '/');
      if (s.endsWith('/')) {
        s = s.substring(0, s.length - 1);
        if (s.isEmpty) return null;
      }
      final last = s.split('/').where((p) => p.isNotEmpty).lastOrNull;
      if (last == null || last.isEmpty) return null;
      // Common double extensions we care about for archives.
      final lower = last.toLowerCase();
      if (lower.endsWith('.tar.gz')) return '.gz';
      if (lower.endsWith('.tar.bz2')) return '.bz2';
      if (lower.endsWith('.tar.xz')) return '.xz';
      final dot = last.lastIndexOf('.');
      if (dot <= 0 || dot >= last.length - 1) return null;
      final ext = last.substring(dot).toLowerCase();
      // Reject absurd "extensions" longer than 8 chars (e.g. query junk).
      if (ext.length > 9) return null;
      if (!RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(ext)) return null;
      return ext;
    } catch (_) {
      return null;
    }
  }

  /// Extension from a URL path (empty string when missing) — for naming APIs.
  static String extensionFromUrlPath(String url) {
    return extensionOf(url) ?? '';
  }

  static String _normExt(String ext) {
    final e = ext.trim().toLowerCase();
    if (e.isEmpty) return e;
    return e.startsWith('.') ? e : '.$e';
  }
}

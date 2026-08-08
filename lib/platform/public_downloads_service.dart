import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../downloader/downloader.dart';
import '../downloader/media_file_types.dart';
import '../downloader/models.dart';
import '../backup/auto_backup_models.dart';

class PublicDownloadsService implements CompletedDownloadPublisher {
  static const MethodChannel _channel = MethodChannel(
    'aurora_downloader/public_downloads',
  );

  static const String defaultRelativePath = 'Download/Aurora Downloader';
  static const String defaultPathLabel = 'Downloads/Aurora Downloader';

  /// MediaStore RELATIVE_PATH root under the Downloads collection
  /// (e.g. `Download/Aurora Downloader`). Updated from Settings.
  String rootRelativePath;

  PublicDownloadsService({
    this.rootRelativePath = defaultRelativePath,
  });

  /// Display label for the current root (`Downloads/...`).
  String get pathLabel {
    final r = rootRelativePath.replaceAll('\\', '/');
    if (r.startsWith('Download/')) {
      return 'Downloads/${r.substring('Download/'.length)}';
    }
    return defaultPathLabel;
  }

  @override
  Future<PublishedDownload?> publishCompletedFile(DownloadTask task) async {
    if (task.exportDirectoryUri != null &&
        task.exportDirectoryUri!.isNotEmpty) {
      try {
        final success = await writeExportFileToDirectory(
          sourcePath: task.savePath,
          directoryUri: task.exportDirectoryUri!,
          displayName: p.basename(task.savePath),
          mimeType: mimeTypeForName(task.savePath),
        );
        if (success) {
          return PublishedDownload(
            uri: task.exportDirectoryUri!,
            pathLabel: 'Saved to custom folder',
          );
        }
      } catch (_) {}
    }

    final entityType = await FileSystemEntity.type(task.savePath);
    if (entityType == FileSystemEntityType.notFound) {
      throw StateError("Couldn't publish — completed file not found: ${task.savePath}");
    }
    if (entityType == FileSystemEntityType.directory) {
      // Folder output (e.g. the native torrent engine's save dir, possibly
      // with a torrent-name subdir). Mirror the whole tree into MediaStore —
      // multi-file torrents have no single "the file" to publish.
      return _publishFolder(task);
    }

    final folderBase = _mediaStoreBaseFor(task.savePath);
    final result = await _channel
        .invokeMapMethod<String, Object?>('publishFile', {
          'sourcePath': task.savePath,
          'displayName': p.basename(task.savePath),
          'mimeType': mimeTypeForName(task.savePath),
          'relativePath': folderBase,
        });

    final uri = result?['uri'] as String?;
    final label = result?['pathLabel'] as String? ?? pathLabel;
    if (uri == null || uri.isEmpty) return null;
    return PublishedDownload(uri: uri, pathLabel: label);
  }

  /// MediaStore RELATIVE_PATH root for a completed internal file/folder:
  /// `rootRelativePath` + the category subfolder (e.g. `Other`) derived from
  /// the path under `/completed/`.
  String _mediaStoreBaseFor(String path) {
    final normalized = p.normalize(path).replaceAll('\\', '/');
    int completedIndex = normalized.lastIndexOf('/completed/');
    int prefixLen = '/completed/'.length;
    if (completedIndex == -1 && normalized.startsWith('completed/')) {
      completedIndex = 0;
      prefixLen = 'completed/'.length;
    }
    if (completedIndex == -1) {
      final filesIndex = normalized.lastIndexOf('/files/');
      if (filesIndex != -1) {
        final subPath = normalized.substring(filesIndex + '/files/'.length);
        if (!subPath.startsWith('completed/')) {
          completedIndex = filesIndex;
          prefixLen = '/files/'.length;
        }
      }
    }

    final root = rootRelativePath.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
    String relativePath = root;
    if (completedIndex != -1) {
      final subPath = normalized.substring(completedIndex + prefixLen);
      final parts = subPath.split('/');
      if (parts.length > 1) {
        final subFolder = parts.sublist(0, parts.length - 1).join('/');
        relativePath = '$root/$subFolder';
      }
    }
    return relativePath;
  }

  /// Publishes every file under [task.savePath] (recursively), preserving
  /// the on-disk structure below the folder inside the MediaStore root.
  /// Returns a handle for the first published file (its URI drives "Open").
  Future<PublishedDownload?> _publishFolder(DownloadTask task) async {
    final dir = Directory(task.savePath);
    final files = <File>[];
    await for (final entity
        in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) files.add(entity);
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    if (files.isEmpty) {
      throw StateError("Folder is empty — nothing to publish: ${task.savePath}");
    }

    final folderRel = p.join(
      _mediaStoreBaseFor(task.savePath),
      p.basename(task.savePath),
    ).replaceAll('\\', '/');

    Uri? firstUri;
    String label = pathLabel;
    for (final file in files) {
      final rel = p.join(
        folderRel,
        p.relative(file.path, from: task.savePath),
      ).replaceAll('\\', '/');
      final result = await _channel
          .invokeMapMethod<String, Object?>('publishFile', {
            'sourcePath': file.path,
            'displayName': p.basename(file.path),
            'mimeType': mimeTypeForName(file.path),
            'relativePath': rel,
          });
      final uri = result?['uri'] as String?;
      if (uri != null && uri.isNotEmpty) {
        firstUri ??= Uri.parse(uri);
        label = result?['pathLabel'] as String? ?? pathLabel;
      }
    }
    if (firstUri == null) return null;
    return PublishedDownload(uri: firstUri.toString(), pathLabel: label);
  }

  Future<void> open(DownloadTask task) async {
    final uri = task.publicUri;
    if (uri == null || uri.isEmpty) {
      throw StateError("This download hasn't been published yet. Files publish after they finish.");
    }
    await _channel.invokeMethod<void>('openUri', {
      'uri': uri,
      'mimeType': mimeTypeForName(task.savePath),
    });
  }

  Future<bool> renamePublishedFile({
    required String publicUri,
    required String newDisplayName,
  }) async {
    final result = await _channel.invokeMethod<bool>('renamePublishedFile', {
      'uri': publicUri,
      'newDisplayName': newDisplayName,
    });
    return result ?? false;
  }

  /// Opens the system share sheet for a local file path.
  ///
  /// Pass [mimeType] for media (video/audio/image); if omitted the native
  /// side guesses from the extension (defaults used to force `text/plain`,
  /// which broke sharing of completed downloads).
  static Future<void> shareFile(String filePath, {String? mimeType}) async {
    await _channel.invokeMethod<void>('shareFile', {
      'filePath': filePath,
      if (mimeType != null && mimeType.isNotEmpty) 'mimeType': mimeType,
    });
  }

  /// Share an already-published content URI (no second MediaStore copy).
  static Future<void> shareContentUri(
    String uri, {
    required String mimeType,
    String? title,
  }) async {
    await _channel.invokeMethod<void>('shareContentUri', {
      'uri': uri,
      'mimeType': mimeType,
      if (title != null && title.isNotEmpty) 'title': title,
    });
  }

  static Future<String?> pickImportFile() async {
    final result = await _channel.invokeMethod<String>('pickImportFile');
    return result;
  }

  static Future<List<Map<String, dynamic>>> listBackupFiles({String? relativePath}) async {
    final result = await _channel.invokeListMethod<Map<Object?, Object?>>('listBackupFiles', {
      'relativePath': relativePath,
    });
    if (result == null) return [];
    return result.map((item) => Map<String, dynamic>.from(item)).toList();
  }

  static Future<bool> deleteBackupFile(String uri) async {
    final result = await _channel.invokeMethod<bool>('deleteBackupFile', {
      'uri': uri,
    });
    return result ?? false;
  }

  static Future<String?> readBackupFile(String uri) async {
    final result = await _channel.invokeMethod<String>('readBackupFile', {
      'uri': uri,
    });
    return result;
  }

  /// Opens the system "Save as" picker and copies [sourcePath] there.
  ///
  /// [sourcePath] may be an absolute filesystem path **or** a `content://`
  /// URI. After a download is published, the private app-data file is deleted
  /// and only [DownloadTask.publicUri] remains — pass that content URI here.
  Future<bool> exportFile({
    required String sourcePath,
    required String displayName,
    required String mimeType,
  }) async {
    final result = await _channel.invokeMethod<bool>('exportFile', {
      'sourcePath': sourcePath,
      'displayName': displayName,
      'mimeType': mimeType,
    });
    return result ?? false;
  }

  Future<String?> selectExportUri({
    required String displayName,
    required String mimeType,
  }) async {
    final result = await _channel.invokeMethod<String>('selectExportUri', {
      'displayName': displayName,
      'mimeType': mimeType,
    });
    return result;
  }

  Future<bool> writeExportFile({
    required String sourcePath,
    required String exportUri,
  }) async {
    final result = await _channel.invokeMethod<bool>('writeExportFile', {
      'sourcePath': sourcePath,
      'exportUri': exportUri,
    });
    return result ?? false;
  }

  Future<String?> selectExportDirectory() async {
    final result = await _channel.invokeMethod<String>('selectExportDirectory');
    return result;
  }

  Future<bool> writeExportFileToDirectory({
    required String sourcePath,
    required String directoryUri,
    required String displayName,
    required String mimeType,
  }) async {
    final result = await _channel.invokeMethod<bool>('writeExportFileToDirectory', {
      'sourcePath': sourcePath,
      'directoryUri': directoryUri,
      'displayName': displayName,
      'mimeType': mimeType,
    });
    return result ?? false;
  }

  static Future<bool> backupFileToDownloads({
    required String sourcePath,
    required String displayName,
    required String relativePath,
  }) async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'publishFile',
        {
          'sourcePath': sourcePath,
          'displayName': displayName,
          'mimeType': 'application/json',
          'relativePath': relativePath,
        },
      );
      final uri = result?['uri'] as String?;
      return uri != null && uri.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static Future<List<AutoBackupFile>> listAutoBackups() async {
    try {
      final result = await _channel.invokeListMethod<Map<dynamic, dynamic>>(
        'listAutoBackups',
      );
      if (result == null) return const [];
      final entries = <AutoBackupFile>[];
      for (final raw in result) {
        final timestamp = raw['timestamp'] as String? ?? '';
        final name = raw['name'] as String? ?? '';
        final uri = raw['uri'] as String? ?? '';
        if (timestamp.isEmpty || name.isEmpty || uri.isEmpty) continue;
        if (name == 'backup_manifest.json') continue;
        entries.add(AutoBackupFile(timestamp: timestamp, name: name, uri: uri));
      }
      return entries;
    } catch (_) {
      return const [];
    }
  }

  static Future<bool> restoreBackupFile({
    required String uri,
    required String destPath,
  }) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'restoreAutoBackupFile',
        {'uri': uri, 'destPath': destPath},
      );
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens [url] with Chrome directly (when preferChrome is true) or system chooser.
  static Future<bool> openUrlInChrome(String url, {bool preferChrome = true}) async {
    try {
      final res = await _channel.invokeMethod<bool>('openUrlInChrome', {
        'url': url,
        'preferChrome': preferChrome,
      });
      return res == true;
    } catch (_) {
      return false;
    }
  }

  /// Opens [url] with the system resolver (browser, Telegram, market, …).
  /// Throws [PlatformException] when no handler is installed.
  static Future<void> openUrl(String url) async {
    await _channel.invokeMethod<void>('openUrl', {'url': url});
  }

  static Future<void> shareUrl(String url) async {
    await _channel.invokeMethod<void>('shareUrl', {'url': url});
  }

  static String mimeTypeForName(String path) {
    return MediaFileTypes.mimeTypeForName(path);
  }

  /// Returns the file extension (including the dot) for a given MIME type,
  /// or `null` if the MIME type is not recognized.
  static String? extensionForMime(String mimeType) {
    return MediaFileTypes.extensionForMime(mimeType);
  }
}

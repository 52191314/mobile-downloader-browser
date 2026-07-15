import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../downloader/downloader.dart';
import '../downloader/models.dart';
import '../backup/auto_backup_models.dart';

class PublicDownloadsService implements CompletedDownloadPublisher {
  static const MethodChannel _channel = MethodChannel(
    'aurora_downloader/public_downloads',
  );

  static const String defaultRelativePath = 'Download/Aurora Downloader';
  static const String defaultPathLabel = 'Downloads/Aurora Downloader';

  const PublicDownloadsService();

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
      throw UnsupportedError(
        "Aurora can publish single files to Downloads. Folder publishing isn't available yet.",
      );
    }

    final normalized = p.normalize(task.savePath).replaceAll('\\', '/');
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

    String relativePath = defaultRelativePath;
    if (completedIndex != -1) {
      final subPath = normalized.substring(completedIndex + prefixLen);
      final parts = subPath.split('/');
      if (parts.length > 1) {
        final subFolder = parts.sublist(0, parts.length - 1).join('/');
        relativePath = '$defaultRelativePath/$subFolder';
      }
    }

    final result = await _channel
        .invokeMapMethod<String, Object?>('publishFile', {
          'sourcePath': task.savePath,
          'displayName': p.basename(task.savePath),
          'mimeType': mimeTypeForName(task.savePath),
          'relativePath': relativePath,
        });

    final uri = result?['uri'] as String?;
    final label = result?['pathLabel'] as String? ?? defaultPathLabel;
    if (uri == null || uri.isEmpty) return null;
    return PublishedDownload(uri: uri, pathLabel: label);
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

  static Future<void> shareFile(String filePath) async {
    await _channel.invokeMethod<void>('shareFile', {
      'filePath': filePath,
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

  static Future<void> openUrl(String url) async {
    await _channel.invokeMethod<void>('openUrl', {'url': url});
  }

  static Future<void> shareUrl(String url) async {
    await _channel.invokeMethod<void>('shareUrl', {'url': url});
  }

  static String mimeTypeForName(String path) {
    final extension = p.extension(path).toLowerCase();
    return switch (extension) {
      '.mp4' => 'video/mp4',
      '.m3u8' => 'application/vnd.apple.mpegurl',
      '.ts' => 'video/mp2t',
      '.webm' => 'video/webm',
      '.mkv' => 'video/x-matroska',
      '.mov' => 'video/quicktime',
      '.mp3' => 'audio/mpeg',
      '.m4a' => 'audio/mp4',
      '.aac' => 'audio/aac',
      '.flac' => 'audio/flac',
      '.ogg' => 'audio/ogg',
      '.pdf' => 'application/pdf',
      '.zip' => 'application/zip',
      '.rar' => 'application/vnd.rar',
      '.7z' => 'application/x-7z-compressed',
      '.torrent' => 'application/x-bittorrent',
      '.txt' => 'text/plain',
      _ => 'application/octet-stream',
    };
  }

  /// Returns the file extension (including the dot) for a given MIME type,
  /// or `null` if the MIME type is not recognized.
  static String? extensionForMime(String mimeType) {
    return switch (mimeType.toLowerCase()) {
      'video/mp4' => '.mp4',
      'application/vnd.apple.mpegurl' => '.m3u8',
      'application/x-mpegurl' => '.m3u8',
      'video/mp2t' => '.ts',
      'video/webm' => '.webm',
      'video/x-matroska' => '.mkv',
      'video/quicktime' => '.mov',
      'audio/mpeg' => '.mp3',
      'audio/mp4' => '.m4a',
      'audio/aac' => '.aac',
      'audio/flac' => '.flac',
      'audio/ogg' => '.ogg',
      'application/pdf' => '.pdf',
      'application/zip' => '.zip',
      'application/vnd.rar' => '.rar',
      'application/x-7z-compressed' => '.7z',
      'application/x-bittorrent' => '.torrent',
      'text/plain' => '.txt',
      'application/dash+xml' => '.mpd',
      'image/jpeg' => '.jpg',
      'image/png' => '.png',
      'image/gif' => '.gif',
      'image/webp' => '.webp',
      'application/json' => '.json',
      'application/xml' => '.xml',
      'text/html' => '.html',
      _ => null,
    };
  }
}

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../downloader/downloader.dart';

class PublicDownloadsService implements CompletedDownloadPublisher {
  static const MethodChannel _channel = MethodChannel(
    'aurora_downloader/public_downloads',
  );

  static const String defaultRelativePath = 'Download/Aurora Downloads';
  static const String defaultPathLabel = 'Downloads/Aurora Downloads';

  const PublicDownloadsService();

  @override
  Future<PublishedDownload?> publishCompletedFile(DownloadTask task) async {
    final entityType = await FileSystemEntity.type(task.savePath);
    if (entityType == FileSystemEntityType.notFound) {
      throw StateError('Completed file was not found: ${task.savePath}');
    }
    if (entityType == FileSystemEntityType.directory) {
      throw UnsupportedError(
        'Folder publishing is not available yet; individual files publish to Downloads.',
      );
    }

    if (task.exportUri != null && task.exportUri!.isNotEmpty) {
      try {
        final success = await writeExportFile(
          sourcePath: task.savePath,
          exportUri: task.exportUri!,
        );
        if (success) {
          return PublishedDownload(
            uri: task.exportUri!,
            pathLabel: 'Custom Location',
          );
        }
      } catch (_) {}
    } else if (task.exportDirectoryUri != null &&
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
            pathLabel: 'Custom Directory',
          );
        }
      } catch (_) {}
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
      throw StateError('This download has not been published yet.');
    }
    await _channel.invokeMethod<void>('openUri', {
      'uri': uri,
      'mimeType': mimeTypeForName(task.savePath),
    });
  }

  Future<void> share(DownloadTask task) async {
    final uri = task.publicUri;
    if (uri == null || uri.isEmpty) {
      throw StateError('This download has not been published yet.');
    }
    await _channel.invokeMethod<void>('shareUri', {
      'uri': uri,
      'mimeType': mimeTypeForName(task.savePath),
      'displayName': p.basename(task.savePath),
    });
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

  static Future<void> openUrl(String url) async {
    await _channel.invokeMethod<void>('openUrl', {'url': url});
  }

  static Future<void> shareUrl(String url) async {
    await _channel.invokeMethod<void>('shareUrl', {'url': url});
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

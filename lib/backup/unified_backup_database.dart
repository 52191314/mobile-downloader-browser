import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

import '../sniffer/idm_backup_parser.dart';

/// Unified transactional backup database payload format version.
const int kUnifiedBackupVersion = 2;

/// Structure representing a consolidated transactional backup snapshot.
class UnifiedBackupPayload {
  final int version;
  final String timestamp;
  final Map<String, dynamic> data;

  const UnifiedBackupPayload({
    required this.version,
    required this.timestamp,
    required this.data,
  });

  Map<String, dynamic> toJson() => {
        'version': version,
        'timestamp': timestamp,
        'data': data,
      };

  factory UnifiedBackupPayload.fromJson(Map<String, dynamic> json) {
    final rawVersion = json['version'];
    final version = (rawVersion is num && rawVersion.isFinite)
        ? rawVersion.toInt()
        : (rawVersion is String ? int.tryParse(rawVersion) ?? 1 : 1);

    final rawTimestamp = json['timestamp'];
    final timestamp = rawTimestamp is String
        ? rawTimestamp
        : (rawTimestamp?.toString() ?? '');

    final rawData = json['data'];
    final Map<String, dynamic> data;
    if (rawData is Map) {
      data = rawData.map((k, v) => MapEntry(k.toString(), v));
    } else {
      data = json.map((k, v) => MapEntry(k.toString(), v));
    }

    return UnifiedBackupPayload(
      version: version,
      timestamp: timestamp,
      data: data,
    );
  }
}

/// Unified Transactional Database Backup Engine (Solution B).
///
/// Handles atomic compilation, export, restoration, and 1DM / 1dmbak
/// transactional ingestion with low memory overhead and off-thread isolate isolation.
class UnifiedBackupDatabase {
  UnifiedBackupDatabase._();

  /// Compiles local app data into a transactional database snapshot file off-thread.
  static Future<File> exportTransactionalDatabase({
    required List<Map<String, dynamic>>? downloadQueue,
    required Map<String, dynamic>? settings,
    required List<Map<String, dynamic>>? favorites,
    required List<Map<String, dynamic>>? folders,
    required List<Map<String, dynamic>>? history,
    required List<Map<String, dynamic>>? savedPages,
    required List<Map<String, dynamic>>? tabs,
    List<Map<String, dynamic>>? tabGroups,
    required dynamic downloadRules,
    required Map<String, dynamic>? extra,
    Directory? targetDirectory,
  }) async {
    final now = DateTime.now();
    final timestamp = now.toIso8601String().replaceAll(':', '-');

    final Directory dir;
    if (targetDirectory != null) {
      dir = targetDirectory;
    } else {
      final baseDir = await getApplicationSupportDirectory();
      dir = Directory('${baseDir.path}/Backups');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    }

    final nonce = '${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1000000)}';
    final targetFile = File('${dir.path}/aurora_backup_${timestamp}_$nonce.json');
    final tempFile = File('${targetFile.path}.$nonce.tmp');

    final Map<String, dynamic> payloadData = {};
    if (downloadQueue != null) payloadData['downloadQueue'] = downloadQueue;
    if (settings != null) payloadData['settings'] = settings;
    if (favorites != null) payloadData['favorites'] = favorites;
    if (folders != null) payloadData['folders'] = folders;
    if (history != null) payloadData['history'] = history;
    if (savedPages != null) payloadData['savedPages'] = savedPages;
    if (tabs != null) payloadData['tabs'] = tabs;
    if (tabGroups != null) payloadData['tabGroups'] = tabGroups;
    if (downloadRules != null) payloadData['downloadRules'] = downloadRules;
    if (extra != null && extra.isNotEmpty) payloadData.addAll(extra);

    final payload = UnifiedBackupPayload(
      version: kUnifiedBackupVersion,
      timestamp: timestamp,
      data: payloadData,
    );

    // Encode JSON off the main thread in an Isolate
    final encoded = await Isolate.run(() => jsonEncode(payload.toJson()));

    // Perform atomic write via temporary file
    await tempFile.writeAsString(encoded, flush: true);
    try {
      await tempFile.rename(targetFile.path);
    } catch (_) {
      await tempFile.copy(targetFile.path);
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }

    return targetFile;
  }

  /// Parses an incoming backup file (.json, .1dmbak, .1dm, or .db format)
  /// and returns a transactional payload map.
  static Future<Map<String, dynamic>> parseBackupFileTransactional(
    String filePath,
  ) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw FileSystemException('Backup file not found', filePath);
    }

    final lower = filePath.toLowerCase();
    bool is1dm = lower.endsWith('.1dmbak') || lower.endsWith('.1dm');

    if (!is1dm) {
      try {
        final raf = await file.open(mode: FileMode.read);
        try {
          final header = await raf.read(4);
          if (header.length == 4 &&
              header[0] == 0x50 &&
              header[1] == 0x4B &&
              header[2] == 0x03 &&
              header[3] == 0x04) {
            is1dm = true;
          }
        } finally {
          await raf.close();
        }
      } catch (_) {}
    }

    if (is1dm) {
      // Offload 1DM ZIP/XML decompression & parsing directly off-thread
      return await Isolate.run(() async {
        return await IdmBackupParser.parse(filePath);
      });
    }

    final Map<String, dynamic> rawMap = await Isolate.run(() {
      try {
        final content = file.readAsStringSync();
        if (content.trim().isEmpty) {
          return <String, dynamic>{};
        }
        final decoded = jsonDecode(content);
        if (decoded is Map) {
          return decoded.map((k, v) => MapEntry(k.toString(), v));
        }
        return <String, dynamic>{};
      } catch (_) {
        return <String, dynamic>{};
      }
    });

    if (rawMap.containsKey('version') && rawMap.containsKey('data') && rawMap['data'] is Map) {
      final rawData = rawMap['data'] as Map;
      return rawData.map((k, v) => MapEntry(k.toString(), v));
    }

    return rawMap;
  }
}


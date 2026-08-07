import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class IdmBackupParser {
  /// Parses a .1dmbak or .1dm file and returns a map compatible with Aurora Downloader's import format.
  static Future<Map<String, dynamic>> parse(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw FileSystemException("Could not find that backup file at the given path.", filePath);
    }

    final data = await file.readAsBytes();
    final filesMap = <String, List<int>>{};
    int idx = 0;

    // 1. Extract all files from the ZIP-like stream sequentially without writing temp files
    while (idx < data.length) {
      if (!_checkSignature(data, idx, const [0x50, 0x4b, 0x03, 0x04])) {
        // Search for the next local file header signature
        int nextIdx = _findSignature(data, idx + 1, const [0x50, 0x4b, 0x03, 0x04]);
        if (nextIdx == -1) break;
        idx = nextIdx;
      }

      if (idx + 30 > data.length) break;

      final headerData = ByteData.sublistView(data, idx, idx + 30);
      final compMethod = headerData.getUint16(8, Endian.little);
      final compSize = headerData.getUint32(18, Endian.little);
      final fnLen = headerData.getUint16(26, Endian.little);
      final extraLen = headerData.getUint16(28, Endian.little);

      if (idx + 30 + fnLen > data.length) break;
      final fnBytes = data.sublist(idx + 30, idx + 30 + fnLen);
      final fn = utf8.decode(fnBytes, allowMalformed: true);

      final startData = idx + 30 + fnLen + extraLen;
      if (startData > data.length) break;

      List<int>? compBytes;
      int nextEntryIdx = startData;

      if (compSize > 0 && startData + compSize <= data.length) {
        compBytes = data.sublist(startData, startData + compSize);
        nextEntryIdx = startData + compSize;
        if (_checkSignature(data, nextEntryIdx, const [0x50, 0x4b, 0x07, 0x08])) {
          nextEntryIdx += 16;
        }
      } else {
        // Find the corresponding data descriptor signature PK\x07\x08
        final ddIdx = _findSignature(data, startData, const [0x50, 0x4b, 0x07, 0x08]);
        if (ddIdx == -1) {
          break;
        }
        compBytes = data.sublist(startData, ddIdx);
        nextEntryIdx = ddIdx + 16; // Skip PK\x07\x08 (4) + CRC (4) + CompSize (4) + UncompSize (4)
      }

      List<int>? decomp;
      if (compMethod == 8) {
        try {
          // Decompress using raw deflate (no zlib headers)
          decomp = ZLibDecoder(raw: true).convert(compBytes);
        } catch (_) {
          // Skip file if decompression fails
        }
      } else if (compMethod == 0) {
        decomp = compBytes;
      }

      if (decomp != null) {
        filesMap[fn] = decomp;
      }

      idx = nextEntryIdx;
    }

    final downloadQueue = <Map<String, dynamic>>[];
    final favorites = <Map<String, dynamic>>[];
    final folders = <Map<String, dynamic>>[];
    final history = <Map<String, dynamic>>[];
    final folderNameToId = <String, String>{};

    // 2. Parse download tasks
    for (final entry in filesMap.entries) {
      if (entry.key.startsWith('download_info')) {
        try {
          final decodedJson = json.decode(utf8.decode(entry.value));
          final String xmlStr = decodedJson is String ? decodedJson : json.encode(decodedJson);

          final tag = _extractTag(xmlStr, 'tag') ?? '';
          final uri = _extractTag(xmlStr, 'uri') ?? '';
          String rawName = _extractTag(xmlStr, 'name') ?? '';
          final dirPath = _extractTag(xmlStr, 'dir') ?? '';
          final referer = _extractTag(xmlStr, 'referer') ?? '';
          final userAgent = _extractTag(xmlStr, 'userAgent') ?? '';
          final lengthStr = _extractTag(xmlStr, 'length') ?? '0';
          final torrentFinishedStr = _extractTag(xmlStr, 'torrent_finished') ?? '0';
          final addedOnStr = _extractTag(xmlStr, 'addedOn') ?? '0';
          final completedOnStr = _extractTag(xmlStr, 'completedOn') ?? '';
          final stateStr = _extractTag(xmlStr, 'state') ?? '0';
          final contentType = _extractTag(xmlStr, 'contentType') ?? '';

          if (!_isSafeUri(uri)) continue;

          String name = '';
          if (rawName.isNotEmpty && rawName.toLowerCase() != 'none') {
            name = _sanitizeFilename(rawName);
          }

          if (name.isEmpty) {
            try {
              final parsedUri = Uri.parse(uri);
              if (parsedUri.pathSegments.isNotEmpty) {
                name = _sanitizeFilename(parsedUri.pathSegments.last);
              }
            } catch (_) {}
          }

          if (name.isEmpty) {
            name = 'download';
          }

          final subfolder = _sanitizeSubfolder(dirPath);
          final savePath = subfolder.isNotEmpty ? 'completed/$subfolder/$name' : 'completed/$name';

          final addedOn = int.tryParse(addedOnStr) ?? 0;
          final createdAt = addedOn > 0
              ? DateTime.fromMillisecondsSinceEpoch(addedOn, isUtc: true).toIso8601String()
              : DateTime.now().toUtc().toIso8601String();

          final completedOn = int.tryParse(completedOnStr) ?? 0;
          final completedAt = completedOn > 0
              ? DateTime.fromMillisecondsSinceEpoch(completedOn, isUtc: true).toIso8601String()
              : null;

          final totalBytes = int.tryParse(lengthStr) ?? 0;
          final torrentFinished = int.tryParse(torrentFinishedStr) ?? 0;

          String state = "paused";
          final isCompleted = (stateStr == '105') ||
              (completedAt != null) ||
              (totalBytes > 0 && totalBytes == torrentFinished);
          if (isCompleted) {
            state = "completed";
          }

          final downloadedBytes = isCompleted ? totalBytes : torrentFinished;

          final headers = <String, String>{};
          if (referer.isNotEmpty && referer.toLowerCase() != 'none') {
            headers['Referer'] = referer;
          }
          if (userAgent.isNotEmpty && userAgent.toLowerCase() != 'none') {
            headers['User-Agent'] = userAgent;
          }

          final taskId = tag.isNotEmpty ? tag : '1dm_$addedOn';

          final taskMap = <String, dynamic>{
            "id": taskId,
            "url": uri,
            "sourcePageUrl": (referer.isNotEmpty && referer.toLowerCase() != 'none') ? referer : null,
            "savePath": savePath,
            "tempDir": 'temp_$addedOn',
            "priority": "normal",
            "state": state,
            "totalBytes": totalBytes,
            "downloadedBytes": downloadedBytes,
            "speed": 0.0,
            "errorMessage": null,
            "createdAt": createdAt,
            "headers": headers,
            "chunks": []
          };

          if (contentType.isNotEmpty && contentType.toLowerCase() != 'none') {
            taskMap["contentType"] = contentType;
          }

          downloadQueue.add(taskMap);
        } catch (_) {
          // Skip malformed download tasks
        }
      }
    }

    // 3. Parse bookmarks (Favorites & Folders)
    if (filesMap.containsKey('key_bookmarks.json')) {
      try {
        final decodedJson = json.decode(utf8.decode(filesMap['key_bookmarks.json']!));
        final bookmarks = decodedJson is String ? json.decode(decodedJson) : decodedJson;

        if (bookmarks is List) {
          for (final b in bookmarks) {
            if (b is! Map) continue;
            final map = Map<String, dynamic>.from(b);
            final mUrl = (map['mUrl'] as String? ?? '').trim();
            final mTitle = (map['mTitle'] as String? ?? '').trim();
            final mFolder = (map['mFolder'] as String? ?? '').trim();
            final uuid = (map['uuid'] as String? ?? '').trim();
            final modifiedDate = map['modifiedDate'] as int? ?? 0;

            if (!_isSafeUri(mUrl)) continue;

            final favId = uuid.isNotEmpty ? uuid : 'fav_$mUrl';
            final createdAt = modifiedDate > 0
                ? DateTime.fromMillisecondsSinceEpoch(modifiedDate, isUtc: true).toIso8601String()
                : DateTime.now().toUtc().toIso8601String();

            String? folderId;
            if (mFolder.isNotEmpty) {
              final cleanFolder = _sanitizeFilename(mFolder);
              if (cleanFolder.isNotEmpty) {
                if (!folderNameToId.containsKey(cleanFolder)) {
                  final fId = 'folder_${folderNameToId.length + 1}';
                  folderNameToId[cleanFolder] = fId;
                  folders.add({
                    "id": fId,
                    "name": cleanFolder,
                    "createdAt": DateTime.now().toUtc().toIso8601String()
                  });
                }
                folderId = folderNameToId[cleanFolder];
              }
            }

            favorites.add({
              "id": favId,
              "title": mTitle.isNotEmpty ? mTitle : mUrl,
              "url": mUrl,
              "createdAt": createdAt,
              "faviconUrl": null,
              "folderId": folderId,
              "tags": []
            });
          }
        }
      } catch (_) {}
    }

    // 4. Parse history
    if (filesMap.containsKey('key_history.json')) {
      try {
        final decodedJson = json.decode(utf8.decode(filesMap['key_history.json']!));
        final historyList = decodedJson is String ? json.decode(decodedJson) : decodedJson;

        if (historyList is List) {
          for (final h in historyList) {
            if (h is! Map) continue;
            final map = Map<String, dynamic>.from(h);
            final mUrl = (map['mUrl'] as String? ?? '').trim();
            final mTitle = (map['mTitle'] as String? ?? '').trim();
            final modifiedDate = map['modifiedDate'] as int? ?? 0;

            if (!_isSafeUri(mUrl)) continue;

            final visitedAt = modifiedDate > 0
                ? DateTime.fromMillisecondsSinceEpoch(modifiedDate, isUtc: true).toIso8601String()
                : DateTime.now().toUtc().toIso8601String();

            history.add({
              "title": mTitle.isNotEmpty ? mTitle : mUrl,
              "url": mUrl,
              "visitedAt": visitedAt
            });
          }
        }
      } catch (_) {}
    }

    return {
      "favorites": favorites,
      "folders": folders,
      "history": history,
      "savedPages": [],
      "downloadQueue": downloadQueue
    };
  }

  // --- Utility Functions ---

  static bool _checkSignature(List<int> data, int idx, List<int> sig) {
    if (idx + sig.length > data.length) return false;
    for (int i = 0; i < sig.length; i++) {
      if (data[idx + i] != sig[i]) return false;
    }
    return true;
  }

  static int _findSignature(List<int> data, int start, List<int> sig) {
    final limit = data.length - sig.length;
    for (int i = start; i <= limit; i++) {
      if (data[i] == sig[0]) {
        bool match = true;
        for (int j = 1; j < sig.length; j++) {
          if (data[i + j] != sig[j]) {
            match = false;
            break;
          }
        }
        if (match) return i;
      }
    }
    return -1;
  }

  static String? _extractTag(String xml, String tag) {
    final match = RegExp('<$tag>(.*?)</$tag>', dotAll: true).firstMatch(xml);
    return match?.group(1)?.trim();
  }

  static String _getSubfolder(String dirPath) {
    if (dirPath.isEmpty || dirPath.toLowerCase() == 'none') return "";
    final match = RegExp(r'/(?:Download|Downloads)/(.*)', caseSensitive: false).firstMatch(dirPath);
    if (match != null) {
      return match.group(1)!.trim().replaceAll('\\', '/').replaceAll('//', '/');
    }
    final parts = dirPath.split('/');
    if (parts.length > 5) {
      if (parts[4].toLowerCase() == 'download' || parts[4].toLowerCase() == 'downloads') {
        return parts.sublist(5).join('/').trim().replaceAll('\\', '/');
      }
    }
    return "";
  }

  static bool _isSafeUri(String uriStr) {
    if (uriStr.isEmpty || uriStr.toLowerCase() == 'none') return false;
    final uri = Uri.tryParse(uriStr);
    if (uri == null) return false;
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'file' || scheme == 'content' || scheme == 'javascript' || scheme == 'data') {
      return false;
    }
    return true;
  }

  static String _sanitizeFilename(String input) {
    var s = input.replaceAll('\x00', '').trim();
    s = s.replaceAll('\\', '/');
    if (s.contains('/')) {
      s = s.split('/').last.trim();
    }
    while (s.startsWith('../') || s.startsWith('..\\')) {
      s = s.substring(3).trim();
    }
    if (s == '..' || s == '.') {
      s = '';
    }
    s = s.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
    s = s.replaceAll(RegExp(r'[\s.]+$'), '');
    return s;
  }

  static String _sanitizeSubfolder(String dirPath) {
    if (dirPath.isEmpty || dirPath.toLowerCase() == 'none') return "";
    final rawSub = _getSubfolder(dirPath);
    if (rawSub.isEmpty) return "";
    final parts = rawSub.replaceAll('\\', '/').split('/');
    final cleanParts = <String>[];
    for (final part in parts) {
      final cleanPart = _sanitizeFilename(part);
      if (cleanPart.isNotEmpty && cleanPart != '.' && cleanPart != '..') {
        cleanParts.add(cleanPart);
      }
    }
    return cleanParts.join('/');
  }
}

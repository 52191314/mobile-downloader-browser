/// Persistence layer for [WatchRule] list.
///
/// Stored as JSON in app support directory (`watcher_rules.json`).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'watcher_models.dart';

class WatcherStore {
  static const _fileName = 'watcher_rules.json';

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  /// Load all watch rules from disk. Returns empty list if file doesn't exist.
  static Future<List<WatchRule>> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return [];
      final raw = await f.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map<String, dynamic>>()
            .map((m) => WatchRule.fromJson(m))
            .toList();
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[WatcherStore] load failed: $e');
      }
    }
    return [];
  }

  /// Persist all watch rules to disk.
  static Future<void> save(List<WatchRule> rules) async {
    try {
      final f = await _file();
      final json = rules.map((r) => r.toJson()).toList();
      await f.writeAsString(jsonEncode(json));
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[WatcherStore] save failed: $e');
      }
    }
  }
}

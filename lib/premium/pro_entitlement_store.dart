import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// File-backed cache for last-known Pro entitlement (offline / after restart).
class ProEntitlementStore {
  static const _fileName = 'pro_entitlement.json';

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  static Future<Map<String, dynamic>?> read() async {
    try {
      final f = await _file();
      if (!await f.exists()) return null;
      final raw = await f.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[ProEntitlementStore] read failed: $e');
      }
    }
    return null;
  }

  static Future<void> write({
    required bool isPro,
    required String source,
  }) async {
    try {
      final f = await _file();
      await f.writeAsString(
        jsonEncode({
          'isPro': isPro,
          'source': source,
          'updatedAt': DateTime.now().toIso8601String(),
        }),
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[ProEntitlementStore] write failed: $e');
      }
    }
  }
}

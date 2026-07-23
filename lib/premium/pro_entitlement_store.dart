import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'pro_entitlement.dart';

/// File-backed cache for last-known entitlement (offline / after restart).
///
/// Schema v2:
/// ```json
/// {
///   "schemaVersion": 2,
///   "tier": "pro",
///   "source": "play",
///   "ownedProductIds": ["aurora_pro_unlock"],
///   "updatedAt": "2026-07-19T12:00:00.000Z",
///   "lastReconcileAt": "2026-07-19T12:00:00.000Z",
///   "lastReconcileOk": true
/// }
/// ```
///
/// v1 (`{ isPro, source, updatedAt }`) is migrated in-memory on read: an
/// `isPro: true` becomes `tier=pro` with an empty owned set (unknown IDs)
/// until a successful reconcile fills them from Play. Corrupt JSON is treated
/// as free + empty owned + a logged error; this method never throws.
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
    required EntitlementTier tier,
    required EntitlementSource source,
    required Set<String> ownedProductIds,
    DateTime? lastReconcileAt,
    required bool lastReconcileOk,
  }) async {
    try {
      final f = await _file();
      await f.writeAsString(
        jsonEncode({
          'schemaVersion': 2,
          'tier': tier.name,
          'source': source.name,
          'ownedProductIds': ownedProductIds.toList()..sort(),
          'updatedAt': DateTime.now().toIso8601String(),
          'lastReconcileAt': lastReconcileAt?.toIso8601String(),
          'lastReconcileOk': lastReconcileOk,
        }),
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[ProEntitlementStore] write failed: $e');
      }
    }
  }

  // --- v1 → v2 migration helpers ---

  static EntitlementTier? tierFromData(Map<String, dynamic> data) {
    final version = data['schemaVersion'];
    if (version == 2) {
      final name = data['tier'] as String?;
      if (name != null) {
        for (final t in EntitlementTier.values) {
          if (t.name == name) return t;
        }
      }
      return EntitlementTier.free;
    }
    // v1 (or unknown): isPro true → pro, else free.
    final isPro = data['isPro'] == true;
    return isPro ? EntitlementTier.pro : EntitlementTier.free;
  }

  static Set<String> ownedFromData(Map<String, dynamic> data) {
    final version = data['schemaVersion'];
    if (version == 2) {
      final list = data['ownedProductIds'];
      if (list is List) {
        return {
          for (final e in list)
            if (e is String) e,
        };
      }
      return {};
    }
    // v1 had no owned IDs.
    return {};
  }

  static EntitlementSource sourceFromData(Map<String, dynamic> data) {
    final version = data['schemaVersion'];
    if (version == 2) {
      final name = data['source'] as String?;
      if (name != null) {
        for (final s in EntitlementSource.values) {
          if (s.name == name) return s;
        }
      }
      return EntitlementSource.none;
    }
    final raw = data['source'] as String?;
    switch (raw) {
      case 'play':
        return EntitlementSource.play;
      case 'legacy':
        return EntitlementSource.legacy;
      case 'cache':
        return EntitlementSource.cache;
      case 'debug':
        return EntitlementSource.debug;
      default:
        return EntitlementSource.none;
    }
  }

  static DateTime? reconcileAtFromData(Map<String, dynamic> data) {
    final version = data['schemaVersion'];
    if (version != 2) return null;
    final raw = data['lastReconcileAt'];
    if (raw is String) {
      return DateTime.tryParse(raw);
    }
    return null;
  }

  static bool reconcileOkFromData(Map<String, dynamic> data) {
    final version = data['schemaVersion'];
    if (version != 2) return false;
    return data['lastReconcileOk'] == true;
  }
}

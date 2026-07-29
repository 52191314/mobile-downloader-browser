import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// On-disk license cache.
///
/// The JWT is *self-protecting*: editing any field invalidates the signature,
/// so unlike `pro_entitlement.json` this file does not have to be trusted. The
/// only things worth persisting alongside it are scheduling metadata.
class LicenseCacheData {
  const LicenseCacheData({
    this.license,
    this.installId,
    this.lastRefreshAt,
    this.lastAttemptAt,
    this.lastOutcome,
    this.legacyGraceUntil,
  });

  /// The raw signed JWT, exactly as issued.
  final String? license;

  /// Which install the cached JWT was issued to. A mismatch (app data cleared,
  /// backup restored onto another device) means the cache is unusable.
  final String? installId;

  /// Last time the server confirmed entitlement.
  final DateTime? lastRefreshAt;

  /// Last time we *tried*, successful or not — used to space out retries.
  final DateTime? lastAttemptAt;

  final String? lastOutcome;

  /// Deadline for the one-time migration window granted to users who already
  /// owned Pro/Ultra before licensing shipped (plan §15 gap 4).
  final DateTime? legacyGraceUntil;

  LicenseCacheData copyWith({
    String? license,
    bool clearLicense = false,
    String? installId,
    DateTime? lastRefreshAt,
    DateTime? lastAttemptAt,
    String? lastOutcome,
    DateTime? legacyGraceUntil,
    bool clearLegacyGrace = false,
  }) =>
      LicenseCacheData(
        license: clearLicense ? null : (license ?? this.license),
        installId: installId ?? this.installId,
        lastRefreshAt: lastRefreshAt ?? this.lastRefreshAt,
        lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
        lastOutcome: lastOutcome ?? this.lastOutcome,
        legacyGraceUntil:
            clearLegacyGrace ? null : (legacyGraceUntil ?? this.legacyGraceUntil),
      );

  Map<String, dynamic> toJson() => {
        'schemaVersion': 1,
        'license': license,
        'installId': installId,
        'lastRefreshAt': lastRefreshAt?.toIso8601String(),
        'lastAttemptAt': lastAttemptAt?.toIso8601String(),
        'lastOutcome': lastOutcome,
        'legacyGraceUntil': legacyGraceUntil?.toIso8601String(),
      };

  static LicenseCacheData fromJson(Map<String, dynamic> json) {
    DateTime? date(Object? raw) =>
        raw is String ? DateTime.tryParse(raw)?.toUtc() : null;
    return LicenseCacheData(
      license: json['license'] is String ? json['license'] as String : null,
      installId: json['installId'] is String ? json['installId'] as String : null,
      lastRefreshAt: date(json['lastRefreshAt']),
      lastAttemptAt: date(json['lastAttemptAt']),
      lastOutcome:
          json['lastOutcome'] is String ? json['lastOutcome'] as String : null,
      legacyGraceUntil: date(json['legacyGraceUntil']),
    );
  }
}

/// File-backed store for [LicenseCacheData]. Never throws.
class LicenseStore {
  const LicenseStore();

  static const String _fileName = 'aurora_license.json';

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<LicenseCacheData> read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const LicenseCacheData();
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) return LicenseCacheData.fromJson(decoded);
      if (decoded is Map) {
        return LicenseCacheData.fromJson(
          decoded.map((k, v) => MapEntry(k.toString(), v)),
        );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[LicenseStore] read failed: $e');
    }
    return const LicenseCacheData();
  }

  Future<void> write(LicenseCacheData data) async {
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode(data.toJson()), flush: true);
    } catch (e) {
      if (kDebugMode) debugPrint('[LicenseStore] write failed: $e');
    }
  }

  Future<void> clear() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (e) {
      if (kDebugMode) debugPrint('[LicenseStore] clear failed: $e');
    }
  }
}

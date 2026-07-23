import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'pro_features.dart';

/// Daily free-cap counters (plan §Free-cap product rules).
///
/// Tracks per-day usage for count-limited Pro features that free users may
/// taste: [FreeCapKind.sendToPc] (20/day) and [FreeCapKind.audioExtract]
/// (3/day, used by P5). Pro+ users are unlimited and never consume.
///
/// Day boundary is the device local calendar date (`YYYY-MM-DD`). On load,
/// if the stored day differs from today, all counters reset to 0. A single
/// async mutex prevents concurrent [tryConsume] from double-spending.
enum FreeCapKind { audioExtract, sendToPc }

class FreeCapStore {
  FreeCapStore._();

  static const String _fileName = 'free_caps.json';

  static final Map<String, dynamic> _cache = {};
  static bool _loaded = false;
  static Completer<void>? _loadMutex;
  static Completer<void>? _writeMutex;

  static int _limitFor(FreeCapKind kind) => switch (kind) {
        FreeCapKind.audioExtract => ProFeatures.freeAudioExtractPerDay,
        FreeCapKind.sendToPc => ProFeatures.freeSendToPcPerDay,
      };

  static String _keyFor(FreeCapKind kind) => switch (kind) {
        FreeCapKind.audioExtract => 'audioExtract',
        FreeCapKind.sendToPc => 'sendToPc',
      };

  static Future<String> _today() async {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  /// Loads (once) and rolls over the day if needed. Serialised via a mutex so
  /// concurrent callers do not double-read or double-reset.
  ///
  /// When path_provider is unavailable (unit tests / missing plugin), falls
  /// back to an in-memory cache for the process lifetime.
  static Future<void> ensureDay() async {
    if (_loaded) return;
    if (_loadMutex != null) return _loadMutex!.future;
    _loadMutex = Completer<void>();
    try {
      try {
        final f = await _file();
        if (await f.exists()) {
          try {
            final decoded = jsonDecode(await f.readAsString());
            if (decoded is Map<String, dynamic>) {
              _cache
                ..clear()
                ..addAll(decoded);
            }
          } catch (_) {
            _cache.clear();
          }
        }
      } catch (e) {
        // MissingPluginException / IO — keep memory-only cache.
        if (kDebugMode) {
          debugPrint('[FreeCapStore] load skipped (memory-only): $e');
        }
      }
      final today = await _today();
      if (_cache['day'] != today) {
        _cache['day'] = today;
        _cache['audioExtract'] = 0;
        _cache['sendToPc'] = 0;
        await _persist();
      }
      _loaded = true;
    } finally {
      _loadMutex!.complete();
    }
  }

  /// Test-only: reset in-memory state between unit tests.
  @visibleForTesting
  static void debugReset() {
    _cache.clear();
    _loaded = false;
    _loadMutex = null;
    _writeMutex = null;
  }

  /// Remaining count for [kind] today (0 when limit reached).
  static Future<int> remaining(FreeCapKind kind) async {
    await ensureDay();
    final limit = _limitFor(kind);
    final used = (_cache[_keyFor(kind)] as int?) ?? 0;
    return (limit - used).clamp(0, limit);
  }

  /// Attempts to consume [n] units of [kind]. Returns true if granted (and
  /// persists the new count). Returns false when the daily limit is reached
  /// or would be exceeded. Serialised via a write mutex.
  static Future<bool> tryConsume(FreeCapKind kind, {int n = 1}) async {
    await ensureDay();
    final key = _keyFor(kind);
    final limit = _limitFor(kind);
    final used = (_cache[key] as int?) ?? 0;
    if (used + n > limit) return false;

    // Serialise the read-modify-write so concurrent calls cannot double-spend.
    while (_writeMutex != null) {
      await _writeMutex!.future;
    }
    _writeMutex = Completer<void>();
    try {
      final nowUsed = (_cache[key] as int?) ?? 0;
      if (nowUsed + n > limit) return false;
      _cache[key] = nowUsed + n;
      await _persist();
      return true;
    } finally {
      _writeMutex!.complete();
      _writeMutex = null;
    }
  }

  static Future<void> _persist() async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode(_cache));
    } catch (e) {
      if (kDebugMode) debugPrint('[FreeCapStore] persist failed: $e');
    }
  }
}

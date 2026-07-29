import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Stable, anonymous per-install identifier.
///
/// This is the `sub` of every license JWT: a license issued to one install is
/// worthless on another. It is a random v4 UUID with no device identifiers in
/// it — clearing app data produces a new one, which is why re-activating an
/// existing purchase token under a fresh install id is an explicitly supported
/// path on the server.
class InstallIdStore {
  InstallIdStore._();

  static const String _fileName = 'aurora_install_id.txt';
  static const String _pattern = r'^[A-Za-z0-9_.:-]{8,128}$';

  static String? _cached;
  static Future<String>? _inFlight;

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  /// Read the install id, creating and persisting one on first call.
  ///
  /// Concurrent callers share a single future so two racing callers cannot
  /// generate two different ids.
  static Future<String> get() {
    final cached = _cached;
    if (cached != null) return Future<String>.value(cached);
    return _inFlight ??= _load().whenComplete(() => _inFlight = null);
  }

  static Future<String> _load() async {
    try {
      final file = await _file();
      if (await file.exists()) {
        final existing = (await file.readAsString()).trim();
        if (RegExp(_pattern).hasMatch(existing)) {
          _cached = existing;
          return existing;
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[InstallIdStore] read failed: $e');
    }

    final generated = _generateUuidV4();
    try {
      final file = await _file();
      await file.writeAsString(generated, flush: true);
    } catch (e) {
      // An unwritable id still works for this session; the next launch will
      // mint another one and simply re-activate against the server.
      if (kDebugMode) debugPrint('[InstallIdStore] write failed: $e');
    }
    _cached = generated;
    return generated;
  }

  /// Test seam — forces the next [get] to re-read from disk.
  @visibleForTesting
  static void resetCacheForTesting() {
    _cached = null;
    _inFlight = null;
  }

  static String _generateUuidV4() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10
    String hex(int start, int end) => bytes
        .sublist(start, end)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
  }
}

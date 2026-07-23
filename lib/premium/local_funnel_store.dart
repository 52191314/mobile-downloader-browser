import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Local, privacy-safe analytics funnel. No PII, no purchase tokens.
///
/// Ring buffer of recent events plus rolling counters. Diagnostics export
/// shares a small JSON snapshot for "I paid but free" support.
class LocalFunnelStore {
  LocalFunnelStore._();

  static const _fileName = 'local_funnel.json';
  static const int maxEvents = 500;

  static final List<Map<String, dynamic>> _events = [];
  static final Map<String, int> _counters = {};

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  /// Record an event with an optional props map. Thread-safe enough for UI
  /// use; counters are incremented atomically in memory.
  static void record(String event, {Map<String, dynamic>? props}) {
    _events.add({
      't': DateTime.now().millisecondsSinceEpoch,
      'e': event,
      if (props != null) 'p': props,
    });
    if (_events.length > maxEvents) {
      _events.removeAt(0);
    }
    _counters[event] = (_counters[event] ?? 0) + 1;
    // Composite counters (e.g. upsell_accepted.<product>).
    if (props != null) {
      final composite = props.entries
          .map((e) => '$event.${e.key}=${e.value}')
          .join(',');
      _counters[composite] = (_counters[composite] ?? 0) + 1;
    }
  }

  static int counter(String key) => _counters[key] ?? 0;

  /// JSON snapshot for diagnostics export (no PII, no tokens).
  static Map<String, dynamic> exportSnapshot() => {
        'events': List<Map<String, dynamic>>.from(_events),
        'counters': Map<String, int>.from(_counters),
      };

  /// Persist to disk (best-effort).
  static Future<void> persist() async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode(exportSnapshot()));
    } catch (e) {
      if (kDebugMode) debugPrint('[LocalFunnelStore] persist failed: $e');
    }
  }

  /// Load previously persisted funnel (best-effort).
  static Future<void> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final decoded = jsonDecode(await f.readAsString());
      if (decoded is Map<String, dynamic>) {
        final evs = decoded['events'];
        if (evs is List) {
          _events.clear();
          for (final e in evs) {
            if (e is Map<String, dynamic>) _events.add(e);
          }
        }
        final c = decoded['counters'];
        if (c is Map) {
          _counters.clear();
          c.forEach((k, v) {
            if (k is String && v is int) _counters[k] = v;
          });
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[LocalFunnelStore] load failed: $e');
    }
  }
}

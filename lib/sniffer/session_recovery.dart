import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class SessionRecovery {
  final String fileName;

  const SessionRecovery({this.fileName = 'session_recovery.json'});

  /// Returns the saved payload if the previous session did not exit cleanly.
  /// Returns null if the previous session closed cleanly, or if the flag
  /// file is missing / corrupt.
  Future<SessionState?> readPendingRestore() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      final clean = map['cleanExit'] as bool? ?? true;
      if (clean) return null;
      return SessionState(
        tabs: (map['tabs'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => SessionTab.fromJson(Map<String, dynamic>.from(e)))
            .toList(growable: false),
        timestamp: DateTime.tryParse(map['timestamp'] as String? ?? ''),
      );
    } catch (_) {
      return null;
    }
  }

  /// Call after a clean exit. Marks the previous session as clean.
  Future<void> markClean() async {
    await _write(cleanExit: true, tabs: const []);
  }

  /// Call when the app starts to begin tracking the new session.
  Future<void> beginSession(List<SessionTab> tabs) async {
    await _write(cleanExit: false, tabs: tabs);
  }

  /// Update the tab list being tracked.
  Future<void> updateTabs(List<SessionTab> tabs) async {
    try {
      final file = await _file();
      Map<String, dynamic> current = {};
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) current = Map<String, dynamic>.from(decoded);
      }
      current['cleanExit'] = false;
      current['tabs'] = tabs.map((t) => t.toJson()).toList();
      current['timestamp'] = DateTime.now().toIso8601String();
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      final encoded = jsonEncode(current);
      final tempFile = File('${file.path}.tmp');
      await tempFile.writeAsString(encoded, flush: true);
      try {
        await tempFile.rename(file.path);
      } catch (_) {
        await tempFile.copy(file.path);
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      }
    } catch (_) {}
  }

  Future<void> _write({
    required bool cleanExit,
    required List<SessionTab> tabs,
  }) async {
    try {
      final file = await _file();
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      final encoded = jsonEncode({
        'cleanExit': cleanExit,
        'tabs': tabs.map((t) => t.toJson()).toList(),
        'timestamp': DateTime.now().toIso8601String(),
      });
      final tempFile = File('${file.path}.tmp');
      await tempFile.writeAsString(encoded, flush: true);
      try {
        await tempFile.rename(file.path);
      } catch (_) {
        await tempFile.copy(file.path);
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      }
    } catch (_) {}
  }

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$fileName');
  }
}

class SessionState {
  final List<SessionTab> tabs;
  final DateTime? timestamp;

  const SessionState({required this.tabs, this.timestamp});
}

class SessionTab {
  final String id;
  final String url;

  const SessionTab({required this.id, required this.url});

  Map<String, dynamic> toJson() => {'id': id, 'url': url};

  factory SessionTab.fromJson(Map<String, dynamic> json) {
    return SessionTab(
      id: json['id'] as String? ?? '',
      url: json['url'] as String? ?? '',
    );
  }
}

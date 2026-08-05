import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

class LogEntry {
  final DateTime timestamp;
  final String level; // 'INFO', 'WARN', 'ERROR'
  final String message;

  LogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
  });

  String get formattedTime {
    final h = timestamp.hour.toString().padLeft(2, '0');
    final m = timestamp.minute.toString().padLeft(2, '0');
    final s = timestamp.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'level': level,
        'message': message,
      };

  factory LogEntry.fromJson(Map<String, dynamic> json) => LogEntry(
        timestamp: DateTime.parse(json['timestamp'] as String),
        level: json['level'] as String,
        message: json['message'] as String,
      );
}

class DownloadLogger {
  static final DownloadLogger instance = DownloadLogger._internal();
  DownloadLogger._internal();

  final List<LogEntry> _logs = [];
  final StreamController<List<LogEntry>> _logController =
      StreamController<List<LogEntry>>.broadcast();
  String? _logPath;
  bool _isLoading = false;
  bool _isSaving = false;
  bool _needsSave = false;

  List<LogEntry> get logs => List.unmodifiable(_logs);
  Stream<List<LogEntry>> get onLogsChanged => _logController.stream;

  Future<void> initialize(String path) async {
    _logPath = path;
    _isLoading = true;
    try {
      final file = File(path);
      if (await file.exists()) {
        final content = await file.readAsString();
        final decoded = jsonDecode(content);
        if (decoded is List) {
          _logs.clear();
          for (final item in decoded) {
            if (item is Map<String, dynamic>) {
              _logs.add(LogEntry.fromJson(item));
            }
          }
          if (!_logController.isClosed) {
            _logController.add(_logs);
          }
        }
      }
    } catch (e) {
      debugPrint('[DownloadLogger] Failed to load logs: $e');
    } finally {
      _isLoading = false;
    }
  }

  void error(String message) => _addEntry('ERROR', message);

  void _addEntry(String level, String message) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: level,
      message: message,
    );
    _logs.insert(0, entry); // newest first
    if (_logs.length > 500) {
      _logs.removeLast();
    }
    if (!_logController.isClosed) {
      _logController.add(_logs);
    }
    _saveToFile();
  }

  Future<void>? _activeSaveFuture;

  Future<void> get pendingWrites async {
    while (_isSaving || _needsSave) {
      await _activeSaveFuture;
      await Future.delayed(Duration.zero);
    }
  }

  void _saveToFile() {
    if (_logPath == null || _isLoading) return;
    _needsSave = true;
    _activeSaveFuture = _triggerSave();
  }

  Future<void> _triggerSave() async {
    if (_isSaving) return;
    _isSaving = true;
    while (_needsSave) {
      _needsSave = false;
      try {
        final path = _logPath!;
        final file = File(path);
        final tempFile = File('$path.tmp');
        final data = _logs.map((e) => e.toJson()).toList(growable: false);
        await tempFile.writeAsString(jsonEncode(data), flush: true);
        if (await tempFile.exists()) {
          if (await file.exists()) {
            await file.delete();
          }
          await tempFile.rename(file.path);
        }
      } catch (e) {
        debugPrint('[DownloadLogger] Failed to save logs: $e');
      }
    }
    _isSaving = false;
  }

  void clear() {
    _logs.clear();
    if (!_logController.isClosed) {
      _logController.add(_logs);
    }
    _saveToFile();
  }
}

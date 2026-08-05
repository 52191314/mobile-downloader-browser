import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

import '../sniffer/worker_isolate_pool.dart';

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

enum LogLevel {
  debug, info, warn, error, fatal;

  String get label => name;
}

enum LogCategory {
  app,
  download,
  hls,
  torrent,
  browser,
  sniffer,
  adblock,
  native,
  platform,
  sync,
  notification,
  settings;

  String get label => name;
}

enum LogScreen {
  queue,
  browser,
  settings,
  background,
  unknown;

  String get label => name;
}

enum LogEventType {
  lifecycle,
  navigation,
  userAction,
  network,
  fileIo,
  stateChange,
  error,
  sniff;

  String get label => name;
}

/// Controls how many log levels are stored and displayed.
enum LogVerbosity {
  /// Only warn, error, fatal are ingested and shown.
  minimal,

  /// All levels (debug through fatal) are ingested and shown.
  verbose;
}

// ---------------------------------------------------------------------------
// Entry model
// ---------------------------------------------------------------------------

class AuroraLogEntry {
  final DateTime timestamp;
  final LogLevel level;
  final LogCategory category;
  final LogScreen screen;
  final LogEventType eventType;
  final String message;
  final String? taskId;
  final String? stackTrace;

  const AuroraLogEntry({
    required this.timestamp,
    required this.level,
    required this.category,
    required this.screen,
    required this.eventType,
    required this.message,
    this.taskId,
    this.stackTrace,
  });

  String get formattedTime {
    final y = timestamp.year.toString();
    final mo = timestamp.month.toString().padLeft(2, '0');
    final d = timestamp.day.toString().padLeft(2, '0');
    final h = timestamp.hour.toString().padLeft(2, '0');
    final m = timestamp.minute.toString().padLeft(2, '0');
    final s = timestamp.second.toString().padLeft(2, '0');
    final ms = timestamp.millisecond.toString().padLeft(3, '0');
    return '$y-$mo-$d $h:$m:$s.$ms';
  }

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'level': level.name,
        'category': category.name,
        'screen': screen.name,
        'eventType': eventType.name,
        'message': message,
        if (taskId != null) 'taskId': taskId,
        if (stackTrace != null) 'stackTrace': stackTrace,
      };

  factory AuroraLogEntry.fromJson(Map<String, dynamic> json) {
    return AuroraLogEntry(
      timestamp: DateTime.parse(json['timestamp'] as String),
      level: LogLevel.values.firstWhere((e) => e.name == json['level']),
      category:
          LogCategory.values.firstWhere((e) => e.name == json['category']),
      screen: LogScreen.values.firstWhere((e) => e.name == json['screen']),
      eventType:
          LogEventType.values.firstWhere((e) => e.name == json['eventType']),
      message: json['message'] as String,
      taskId: json['taskId'] as String?,
      stackTrace: json['stackTrace'] as String?,
    );
  }
}

// ---------------------------------------------------------------------------
// Singleton logger
// ---------------------------------------------------------------------------

class AuroraLog {
  static final AuroraLog instance = AuroraLog._internal();
  AuroraLog._internal();

  static const int _maxEntries = 10000;

  /// Repeat-detection window in seconds: identical messages within this
  /// window are aggregated with an `[xN, ΔTs]` suffix instead of flooding
  /// the log with redundant entries.
  static const int _repeatWindowSec = 30;

  final List<AuroraLogEntry> _entries = [];
  final StreamController<List<AuroraLogEntry>> _controller =
      StreamController<List<AuroraLogEntry>>.broadcast();
  final StreamController<AuroraLogEntry> _logAddedController =
      StreamController<AuroraLogEntry>.broadcast();

  Stream<AuroraLogEntry> get onLogAdded => _logAddedController.stream;

  String? _logPath;
  LogVerbosity _verbosity = LogVerbosity.verbose;
  bool _isLoading = false;
  bool _isSaving = false;
  bool _needsSave = false;

  // -- repeat tracking --
  String? _lastRepeatKey;
  int _repeatCount = 0;
  DateTime? _repeatFirst;
  DateTime? _repeatLast;
  AuroraLogEntry? _repeatEntry; // the first instance (in _entries[0])

  // -- public accessors --

  List<AuroraLogEntry> get entries => List.unmodifiable(_entries);
  Stream<List<AuroraLogEntry>> get onEntriesChanged => _controller.stream;
  LogVerbosity get verbosity => _verbosity;
  int get count => _entries.length;

  // -- init --

  Future<void> initialize(String path, {LogVerbosity? verbosity}) async {
    _logPath = path;
    if (verbosity != null) _verbosity = verbosity;
    _isLoading = true;
    try {
      final file = File(path);
      if (await file.exists()) {
        final content = await file.readAsString();
        // Offload jsonDecode to a background isolate so parsing 10 000
        // entries does not block the UI thread on every cold start.
        final decoded = await WorkerIsolatePool.instance.execute(
          'jsonDecode',
          {'json': content},
        );
        if (decoded is List) {
          _entries.clear();
          // Cap entries during restore to keep main-isolate iteration time
          // bounded even when the persisted file is at _maxEntries.
          final maxRestore = _maxEntries ~/ 5; // 2000 entries max
          var count = 0;
          for (final item in decoded) {
            if (item is Map<String, dynamic>) {
              try {
                _entries.add(AuroraLogEntry.fromJson(item));
                count++;
                if (count >= maxRestore) break;
              } catch (_) {
                // Skip malformed entries during load.
              }
            }
          }
          // Ensure newest-first order after load.
          _entries.sort((a, b) => b.timestamp.compareTo(a.timestamp));
          if (_entries.length > _maxEntries) {
            _entries.removeRange(_maxEntries, _entries.length);
          }
          if (!_controller.isClosed) {
            _controller.add(_entries);
          }
        }
      }
    } catch (e) {
      // File corrupt or unreadable — start fresh.
      debugPrint('[AuroraLog] Failed to load logs: $e');
    } finally {
      _isLoading = false;
    }
  }

  // -- verbosity --

  void setVerbosity(LogVerbosity v) {
    _verbosity = v;
  }

  /// Whether a given level passes the current verbosity filter for ingestion.
  bool _passesFilter(LogLevel level) {
    switch (_verbosity) {
      case LogVerbosity.minimal:
        return level == LogLevel.warn ||
            level == LogLevel.error ||
            level == LogLevel.fatal;
      case LogVerbosity.verbose:
        return true;
    }
  }

  // -- convenience methods --

  void debug(
    String message, {
    LogCategory category = LogCategory.app,
    LogScreen screen = LogScreen.background,
    LogEventType eventType = LogEventType.stateChange,
    String? taskId,
    StackTrace? stackTrace,
  }) {
    _add(LogLevel.debug, message,
        category: category,
        screen: screen,
        eventType: eventType,
        taskId: taskId,
        stackTrace: stackTrace);
  }

  void info(
    String message, {
    LogCategory category = LogCategory.app,
    LogScreen screen = LogScreen.background,
    LogEventType eventType = LogEventType.stateChange,
    String? taskId,
    StackTrace? stackTrace,
  }) {
    _add(LogLevel.info, message,
        category: category,
        screen: screen,
        eventType: eventType,
        taskId: taskId,
        stackTrace: stackTrace);
  }

  void warn(
    String message, {
    LogCategory category = LogCategory.app,
    LogScreen screen = LogScreen.background,
    LogEventType eventType = LogEventType.error,
    String? taskId,
    StackTrace? stackTrace,
  }) {
    _add(LogLevel.warn, message,
        category: category,
        screen: screen,
        eventType: eventType,
        taskId: taskId,
        stackTrace: stackTrace);
  }

  void error(
    String message, {
    LogCategory category = LogCategory.app,
    LogScreen screen = LogScreen.background,
    LogEventType eventType = LogEventType.error,
    String? taskId,
    StackTrace? stackTrace,
  }) {
    _add(LogLevel.error, message,
        category: category,
        screen: screen,
        eventType: eventType,
        taskId: taskId,
        stackTrace: stackTrace);
  }

  void fatal(
    String message, {
    LogCategory category = LogCategory.app,
    LogScreen screen = LogScreen.background,
    LogEventType eventType = LogEventType.error,
    String? taskId,
    StackTrace? stackTrace,
  }) {
    _add(LogLevel.fatal, message,
        category: category,
        screen: screen,
        eventType: eventType,
        taskId: taskId,
        stackTrace: stackTrace);
  }

  // -- internal --

  /// Build a composite key used for repeat detection.
  String _repeatKey(
    LogLevel level,
    LogCategory category,
    String message,
    String? taskId,
  ) =>
      '${level.name}|${category.name}|$message|$taskId';

  /// Flush any pending aggregated repeat to the log entry in-memory.
  /// Called before writing a non-duplicate message or when the repeat
  /// window expires.
  void _flushRepeats() {
    if (_repeatCount <= 1 || _repeatEntry == null) return;
    final elapsed = _repeatLast!.difference(_repeatFirst!).inSeconds;
    // Replace the aggregated entry's message in-place in _entries so
    // the next save-to-file picks up the [xN, ΔTs] suffix.
    final updated = AuroraLogEntry(
      timestamp: _repeatEntry!.timestamp,
      level: _repeatEntry!.level,
      category: _repeatEntry!.category,
      screen: _repeatEntry!.screen,
      eventType: _repeatEntry!.eventType,
      message: '${_repeatEntry!.message} [x$_repeatCount, ${elapsed}s]',
      taskId: _repeatEntry!.taskId,
    );
    final idx = _entries.indexOf(_repeatEntry!);
    if (idx != -1) {
      _entries[idx] = updated;
      if (!_controller.isClosed) {
        _controller.add(_entries);
      }
      _saveToFile();
    }
    _repeatEntry = null;
  }

  void _add(
    LogLevel level,
    String message, {
    LogCategory category = LogCategory.app,
    LogScreen screen = LogScreen.background,
    LogEventType eventType = LogEventType.stateChange,
    String? taskId,
    StackTrace? stackTrace,
  }) {
    // Ingestion filter based on verbosity.
    if (!_passesFilter(level)) return;

    final now = DateTime.now();
    final key = _repeatKey(level, category, message, taskId);

    // --- repeat detection ---
    if (key == _lastRepeatKey &&
        _repeatFirst != null &&
        now.difference(_repeatFirst!).inSeconds < _repeatWindowSec) {
      // Same message within the aggregation window — suppress and count.
      _repeatCount++;
      _repeatLast = now;
      return; // no new entry, no save
    }

    // Different message or window expired — flush previous repeats first.
    _flushRepeats();

    // Reset repeat tracking for the new message.
    _lastRepeatKey = key;
    _repeatCount = 1;
    _repeatFirst = now;
    _repeatLast = now;

    final entry = AuroraLogEntry(
      timestamp: now,
      level: level,
      category: category,
      screen: screen,
      eventType: eventType,
      message: message,
      taskId: taskId,
      stackTrace: stackTrace?.toString(),
    );
    _repeatEntry = entry;

    // Mirror to debugPrint in debug mode so logcat still works.
    if (kDebugMode) {
      debugPrint(
          '[${entry.formattedTime}] [${level.name.toUpperCase()}] [${category.name}/${screen.name}] [${eventType.name}] $message');
    }

    _entries.insert(0, entry); // newest first
    if (_entries.length > _maxEntries) {
      _entries.removeLast();
    }
    if (!_controller.isClosed) {
      _controller.add(_entries);
    }
    if (!_logAddedController.isClosed) {
      _logAddedController.add(entry);
    }
    _saveToFile();
  }

  // -- persistence --

  Future<void>? _activeSaveFuture;
  Timer? _saveTimer;

  /// How long to wait after the last log entry before persisting. Bursts of
  /// entries (e.g. HLS/torrent progress logging) coalesce into a single save.
  static const Duration _saveDebounce = Duration(milliseconds: 1200);

  Future<void> get pendingWrites async {
    // Flush any pending debounced save so the returned future means
    // "everything is on disk".
    _cancelDebounceAndSave();
    while (_isSaving || _needsSave) {
      await _activeSaveFuture;
      await Future.delayed(Duration.zero);
    }
  }

  /// Cancels a pending debounce timer and, if entries are waiting, starts a
  /// save immediately. Used by [pendingWrites] and [dispose] so a pending
  /// save is never dropped when the log is closed.
  void _cancelDebounceAndSave() {
    if (_saveTimer != null) {
      _saveTimer!.cancel();
      _saveTimer = null;
    }
    if (_needsSave && _logPath != null && !_isLoading) {
      _activeSaveFuture = _triggerSave();
    }
  }

  void _saveToFile() {
    if (_logPath == null || _isLoading) return;
    _needsSave = true;
    // Debounce: coalesce bursts of entries into a single save instead of
    // rewriting the file on every log call. Arm the timer ONCE per burst —
    // resetting it on every entry would starve the save during continuous
    // logging (e.g. HLS progress) and the file would never be written until
    // logging pauses. `_triggerSave`'s `while (_needsSave)` drain loop then
    // picks up any entries that arrive while a save is in flight.
    if (_saveTimer != null) return;
    _saveTimer = Timer(_saveDebounce, () {
      _saveTimer = null;
      _activeSaveFuture = _triggerSave();
    });
  }

  Future<void>? _inFlightSave;

  Future<void> _triggerSave() {
    if (_isSaving) {
      // A save is already running — return ITS future so callers that
      // captured `_activeSaveFuture` await the real work instead of a
      // completed no-op (which turned pendingWrites into a busy-poll).
      return _inFlightSave ?? Future<void>.value();
    }
    _isSaving = true;
    final run = _runSaveLoop();
    _inFlightSave = run;
    return run.whenComplete(() {
      _isSaving = false;
      _inFlightSave = null;
    });
  }

  Future<void> _runSaveLoop() async {
    while (_needsSave) {
      _needsSave = false;
      try {
        final path = _logPath!;
        final file = File(path);
        final tempFile = File('$path.tmp');
        final data =
            _entries.map((e) => e.toJson()).toList(growable: false);
        // Offload JSON encoding to a worker isolate so serialising up to
        // _maxEntries never blocks the UI isolate. If the pool is unavailable
        // or fails, encode on the UI isolate instead — never lose entries.
        String jsonString;
        try {
          jsonString = await WorkerIsolatePool.instance.execute(
            'jsonEncode',
            {'data': data},
          ) as String;
        } catch (e) {
          debugPrint(
              '[AuroraLog] Worker encode failed, encoding on UI isolate: $e');
          jsonString = jsonEncode(data);
        }
        await tempFile.writeAsString(jsonString);
        if (await tempFile.exists()) {
          if (await file.exists()) {
            await file.delete();
          }
          await tempFile.rename(file.path);
        }
      } catch (e) {
        debugPrint('[AuroraLog] Failed to save logs: $e');
      }
    }
  }

  // -- clear --

  void clear() {
    _entries.clear();
    if (!_controller.isClosed) {
      _controller.add(_entries);
    }
    _saveToFile();
  }

  // -- dispose --

  void dispose() {
    // Best-effort final flush: cancel any pending debounce timer and persist
    // outstanding entries before the log shuts down.
    _cancelDebounceAndSave();
    _controller.close();
  }
}

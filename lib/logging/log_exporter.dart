import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../platform/public_downloads_service.dart';
import 'aurora_log.dart';

/// Supported export formats.
enum LogExportFormat {
  plainText,
  json;

  String get fileExtension {
    switch (this) {
      case LogExportFormat.plainText:
        return 'txt';
      case LogExportFormat.json:
        return 'json';
    }
  }

  String get mimeType {
    switch (this) {
      case LogExportFormat.plainText:
        return 'text/plain';
      case LogExportFormat.json:
        return 'application/json';
    }
  }
}

/// Generates plain-text and JSON export files from a list of log entries,
/// writes them to temp files, and optionally triggers the Android share sheet.
class LogExporter {
  const LogExporter._();

  static const LogExporter instance = LogExporter._();

  /// Sanitizes a message string by replacing URL paths with a hash.
  /// Preserves the domain name for debugging but strips the path and query.
  ///
  /// Example:
  ///   `https://surrit.com/ab365d77-.../video.m3u8?token=abc`
  ///   → `https://surrit.com/[b784e3]`
  static String sanitizeMessage(String message) {
    final urlRegex = RegExp(r'https?://[^\s]+');
    return message.replaceAllMapped(urlRegex, (match) {
      final url = match.group(0)!;
      try {
        final uri = Uri.parse(url);
        final hash = _shortHash(url);
        return '${uri.scheme}://${uri.host}/[$hash]';
      } catch (_) {
        return 'https://[redacted]';
      }
    });
  }

  /// A short numeric hash of the input string for stable cross-session tracking.
  static String _shortHash(String input) {
    var hash = 0;
    for (var i = 0; i < input.length; i++) {
      hash = ((hash << 5) - hash) + input.codeUnitAt(i);
      hash = hash & hash; // Convert to 32-bit integer
    }
    return (hash.abs() % 0xFFFFFF).toRadixString(16).padLeft(6, '0');
  }

  /// Builds a human-readable plain-text representation.
  static String toPlainText(List<AuroraLogEntry> entries, {bool sanitize = false}) {
    final buf = StringBuffer();
    for (final e in entries) {
      final msg = sanitize ? sanitizeMessage(e.message) : e.message;
      buf.writeln(
        '[${e.formattedTime}] [${e.level.name.toUpperCase()}] '
        '[${e.category.name}/${e.screen.name}] [${e.eventType.name}]'
        '${e.taskId != null ? " [task=${e.taskId}]" : ""}'
        ' $msg',
      );
      if (e.stackTrace != null && e.stackTrace!.isNotEmpty) {
        final st = sanitize ? sanitizeMessage(e.stackTrace!) : e.stackTrace!;
        buf.writeln('  Stack: $st');
      }
    }
    return buf.toString();
  }

  /// Builds a pretty-printed JSON array string.
  static String toJson(List<AuroraLogEntry> entries, {bool sanitize = false}) {
    final jsonList = entries.map((e) {
      final json = e.toJson();
      if (sanitize) {
        json['message'] = sanitizeMessage(json['message'] as String);
        if (json['stackTrace'] != null) {
          json['stackTrace'] =
              sanitizeMessage(json['stackTrace'] as String);
        }
      }
      return json;
    }).toList(growable: false);
    return const JsonEncoder.withIndent('  ').convert(jsonList);
  }

  /// Writes entries to a temp file and returns the [File].
  /// Filename: `aurora_logs_YYYYMMDD_HHmmss.{txt|json}`.
  static Future<File> writeToFile(
    List<AuroraLogEntry> entries,
    LogExportFormat format, {
    bool sanitize = false,
  }) async {
    final now = DateTime.now();
    final ts = '${now.year}${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
    final sanitizePrefix = sanitize ? 'sanitized_' : '';
    final fileName = 'aurora_logs_${sanitizePrefix}$ts.${format.fileExtension}';

    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/$fileName');

    final content = format == LogExportFormat.plainText
        ? toPlainText(entries, sanitize: sanitize)
        : toJson(entries, sanitize: sanitize);
    await file.writeAsString(content, flush: true);

    return file;
  }

  /// Writes and shares via Android share sheet.
  static Future<void> exportAndShare(
    List<AuroraLogEntry> entries,
    LogExportFormat format, {
    bool sanitize = false,
  }) async {
    try {
      final file = await writeToFile(entries, format, sanitize: sanitize);
      await PublicDownloadsService.shareFile(file.path);
    } catch (e) {
      debugPrint('[LogExporter] exportAndShare failed: $e');
      rethrow;
    }
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

// ---------------------------------------------------------------------------
// DownloadRule model
// ---------------------------------------------------------------------------

/// A download rule that controls how a download is handled.
///
/// Rules can match by host (glob pattern) and/or media type. When matched,
/// they can rename the file, redirect it to a custom folder, or impose
/// conditions (Wi‑Fi, charging, time window).
class DownloadRule {
  final String id;
  final String name;
  final bool enabled;
  final String? hostPattern; // glob pattern like "*.youtube.com" or null = all hosts
  final Set<String>? typeFilter; // {"video", "audio", "hls", "image"} or null = all types
  final String? renameTemplate; // e.g. "{host}_{quality}_{title}.{ext}" — null = no rename
  final String? destinationFolder; // override download folder
  final bool? requireWifi; // only download on WiFi
  final bool? requireCharging; // only download while charging
  final int? timeWindowStartHour; // e.g. 1 for 1 AM
  final int? timeWindowEndHour; // e.g. 6 for 6 AM
  final DateTime createdAt;

  const DownloadRule({
    required this.id,
    required this.name,
    this.enabled = true,
    this.hostPattern,
    this.typeFilter,
    this.renameTemplate,
    this.destinationFolder,
    this.requireWifi,
    this.requireCharging,
    this.timeWindowStartHour,
    this.timeWindowEndHour,
    required this.createdAt,
  });

  /// Returns the default (empty) list of rules.
  static List<DownloadRule> defaults() => const [];

  /// Returns a list of example rules for testing, all disabled by default.
  static List<DownloadRule> sample() {
    final now = DateTime.now();
    return [
      DownloadRule(
        id: now.microsecondsSinceEpoch.toString(),
        name: 'Direct video files',
        enabled: false,
        hostPattern: '*.example.com',
        typeFilter: const {'video', 'hls'},
        renameTemplate: '{title}_{quality}.{ext}',
        destinationFolder: 'Videos',
        createdAt: now,
      ),
      DownloadRule(
        id: (now.microsecondsSinceEpoch + 1).toString(),
        name: 'Audio only - WiFi',
        enabled: false,
        hostPattern: null,
        typeFilter: const {'audio'},
        renameTemplate: null,
        destinationFolder: 'Music',
        requireWifi: true,
        createdAt: now,
      ),
    ];
  }

  DownloadRule copyWith({
    String? id,
    String? name,
    bool? enabled,
    String? hostPattern,
    Set<String>? typeFilter,
    String? renameTemplate,
    String? destinationFolder,
    bool? requireWifi,
    bool? requireCharging,
    int? timeWindowStartHour,
    int? timeWindowEndHour,
    DateTime? createdAt,
  }) {
    return DownloadRule(
      id: id ?? this.id,
      name: name ?? this.name,
      enabled: enabled ?? this.enabled,
      hostPattern: hostPattern ?? this.hostPattern,
      typeFilter: typeFilter ?? this.typeFilter,
      renameTemplate: renameTemplate ?? this.renameTemplate,
      destinationFolder: destinationFolder ?? this.destinationFolder,
      requireWifi: requireWifi ?? this.requireWifi,
      requireCharging: requireCharging ?? this.requireCharging,
      timeWindowStartHour: timeWindowStartHour ?? this.timeWindowStartHour,
      timeWindowEndHour: timeWindowEndHour ?? this.timeWindowEndHour,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'enabled': enabled,
      if (hostPattern != null) 'hostPattern': hostPattern,
      if (typeFilter != null) 'typeFilter': typeFilter!.toList(),
      if (renameTemplate != null) 'renameTemplate': renameTemplate,
      if (destinationFolder != null) 'destinationFolder': destinationFolder,
      if (requireWifi != null) 'requireWifi': requireWifi,
      if (requireCharging != null) 'requireCharging': requireCharging,
      if (timeWindowStartHour != null) 'timeWindowStartHour': timeWindowStartHour,
      if (timeWindowEndHour != null) 'timeWindowEndHour': timeWindowEndHour,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory DownloadRule.fromJson(Map<String, dynamic> json) {
    return DownloadRule(
      id: json['id'] as String? ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: json['name'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? true,
      hostPattern: json['hostPattern'] as String?,
      typeFilter: json['typeFilter'] != null
          ? Set<String>.from(json['typeFilter'] as List)
          : null,
      renameTemplate: json['renameTemplate'] as String?,
      destinationFolder: json['destinationFolder'] as String?,
      requireWifi: json['requireWifi'] as bool?,
      requireCharging: json['requireCharging'] as bool?,
      timeWindowStartHour: json['timeWindowStartHour'] as int?,
      timeWindowEndHour: json['timeWindowEndHour'] as int?,
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : DateTime.now(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DownloadRule &&
          id == other.id &&
          name == other.name &&
          enabled == other.enabled &&
          hostPattern == other.hostPattern &&
          typeFilter == other.typeFilter &&
          renameTemplate == other.renameTemplate &&
          destinationFolder == other.destinationFolder &&
          requireWifi == other.requireWifi &&
          requireCharging == other.requireCharging &&
          timeWindowStartHour == other.timeWindowStartHour &&
          timeWindowEndHour == other.timeWindowEndHour &&
          createdAt == other.createdAt;

  @override
  int get hashCode => Object.hash(
        id,
        name,
        enabled,
        hostPattern,
        typeFilter,
        renameTemplate,
        destinationFolder,
        requireWifi,
        requireCharging,
        timeWindowStartHour,
        timeWindowEndHour,
        createdAt,
      );
}

// ---------------------------------------------------------------------------
// DownloadRuleEngine
// ---------------------------------------------------------------------------

/// Evaluates download rules against URLs and applies transformations.
class DownloadRuleEngine {
  final List<DownloadRule> rules;

  const DownloadRuleEngine(this.rules);

  /// Evaluates a URL against all enabled rules, returning the first match.
  ///
  /// The [mediaType] should be one of "video", "audio", "hls", "image"
  /// (or null to match any type). [pageHost] is used as a fallback when
  /// the URL cannot be parsed for its host.
  DownloadRule? matchRule(String url, {String? mediaType, String? pageHost}) {
    for (final rule in rules) {
      if (!rule.enabled) continue;

      // Check host pattern (glob-style).
      if (rule.hostPattern != null && rule.hostPattern!.isNotEmpty) {
        final uri = Uri.tryParse(url);
        final host = uri?.host.isNotEmpty == true ? uri!.host : (pageHost ?? '');
        if (host.isEmpty || !_globMatch(host, rule.hostPattern!)) {
          continue;
        }
      }

      // Check media-type filter.
      if (rule.typeFilter != null && rule.typeFilter!.isNotEmpty) {
        if (mediaType == null || !rule.typeFilter!.contains(mediaType)) {
          // If mediaType is null but the rule requires a specific type,
          // we still match (no information to filter on).
          // Only skip when we know the type and it doesn't match.
          if (mediaType != null) continue;
        }
      }

      return rule;
    }
    return null;
  }

  /// Applies the rename template of [rule] to [originalFilename].
  ///
  /// Supported tokens:
  /// - `{host}` — URL host from the original filename context (unavailable here, uses 'unknown')
  /// - `{ext}` — file extension (including the dot)
  /// - `{quality}` — extracted quality string
  /// - `{title}` — filename without extension
  /// - `{date}` — current date in YYYY-MM-DD format
  String applyRename(DownloadRule rule, String originalFilename,
      {String? quality}) {
    final template = rule.renameTemplate;
    if (template == null || template.isEmpty) return originalFilename;

    final dotIndex = originalFilename.lastIndexOf('.');
    final title = dotIndex > 0 ? originalFilename.substring(0, dotIndex) : originalFilename;
    final ext = dotIndex > 0 ? originalFilename.substring(dotIndex) : '';
    final qualityStr = quality ?? 'unknown';
    final dateStr = _formatDate(DateTime.now());

    String result = template
        .replaceAll('{host}', 'unknown')
        .replaceAll('{ext}', ext)
        .replaceAll('{quality}', qualityStr)
        .replaceAll('{title}', title)
        .replaceAll('{date}', dateStr);

    // Sanitize the result — remove characters problematic on FAT32/NTFS.
    result = result.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    return result;
  }

  /// Returns the destination folder override from a matched rule, or null.
  String? getDestinationFolder(DownloadRule? rule) {
    return rule?.destinationFolder;
  }

  /// Simple glob matching: `*` matches any sequence, `?` matches any single char.
  static bool _globMatch(String text, String pattern) {
    final regexStr = StringBuffer('^');
    for (int i = 0; i < pattern.length; i++) {
      final c = pattern[i];
      if (c == '*') {
        regexStr.write('.*');
      } else if (c == '?') {
        regexStr.write('.');
      } else {
        regexStr.write(RegExp.escape(c));
      }
    }
    regexStr.write(r'$');
    return RegExp(regexStr.toString(), caseSensitive: false).hasMatch(text);
  }

  /// Formats [date] as YYYY-MM-DD.
  static String _formatDate(DateTime date) {
    final y = date.year.toString();
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}

// ---------------------------------------------------------------------------
// DownloadRulesStore (persistence)
// ---------------------------------------------------------------------------

/// Loads and saves [DownloadRule]s to `download_rules.json` in the app
/// support directory.
class DownloadRulesStore {
  const DownloadRulesStore();

  /// Loads rules from `download_rules.json`. Returns [DownloadRule.defaults]
  /// if the file does not exist or is corrupt.
  Future<List<DownloadRule>> load() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/download_rules.json');
      if (!await file.exists()) return DownloadRule.defaults();
      final contents = await file.readAsString();
      if (contents.trim().isEmpty) return DownloadRule.defaults();
      final list = jsonDecode(contents) as List;
      return list
          .map((e) => DownloadRule.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return DownloadRule.defaults();
    }
  }

  /// Saves [rules] to `download_rules.json`.
  Future<void> save(List<DownloadRule> rules) async {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/download_rules.json');
    final contents = jsonEncode(rules.map((r) => r.toJson()).toList());
    final tempFile = File('${file.path}.tmp');
    await tempFile.writeAsString(contents, flush: true);
    try {
      await tempFile.rename(file.path);
    } catch (_) {
      await tempFile.copy(file.path);
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }
  }
}

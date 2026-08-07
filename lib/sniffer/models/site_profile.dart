import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// A per-site profile that overrides browser and download settings.
///
/// When a URL's host matches [hostPattern], the profile's non-null settings
/// override the corresponding global [DownloadSettings] values.
class SiteProfile {
  final String id;
  final String name; // display name, e.g. "YouTube"
  final String hostPattern; // glob like "*.youtube.com"
  final bool enabled;

  // Browser settings overrides
  final bool? desktopMode; // null = use global, true = desktop, false = mobile
  final String?
      userAgentProfile; // null = use global, else "mobile"/"desktop_chrome"/"desktop_firefox"/"safari"
  final bool? adblockEnabled; // null = use global
  final bool? replaceSitePlayer; // null = use global setting

  // Download settings overrides
  final String? downloadFolder; // override download destination
  final Map<String, String>? customHeaders; // extra HTTP headers
  final String? downloadLinkBehavior; // override download link behavior ("ask", "autoDownload", "capture", "block")

  final DateTime createdAt;
  final DateTime updatedAt;

  const SiteProfile({
    required this.id,
    required this.name,
    required this.hostPattern,
    this.enabled = true,
    this.desktopMode,
    this.userAgentProfile,
    this.adblockEnabled,
    this.replaceSitePlayer,
    this.downloadFolder,
    this.customHeaders,
    this.downloadLinkBehavior,
    required this.createdAt,
    required this.updatedAt,
  });

  SiteProfile copyWith({
    String? name,
    String? hostPattern,
    bool? enabled,
    Object? desktopMode = _sentinel,
    Object? userAgentProfile = _sentinel,
    Object? adblockEnabled = _sentinel,
    Object? replaceSitePlayer = _sentinel,
    Object? downloadFolder = _sentinel,
    Object? customHeaders = _sentinel,
    Object? downloadLinkBehavior = _sentinel,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return SiteProfile(
      id: id,
      name: name ?? this.name,
      hostPattern: hostPattern ?? this.hostPattern,
      enabled: enabled ?? this.enabled,
      desktopMode: identical(desktopMode, _sentinel)
          ? this.desktopMode
          : desktopMode as bool?,
      userAgentProfile: identical(userAgentProfile, _sentinel)
          ? this.userAgentProfile
          : userAgentProfile as String?,
      adblockEnabled: identical(adblockEnabled, _sentinel)
          ? this.adblockEnabled
          : adblockEnabled as bool?,
      replaceSitePlayer: identical(replaceSitePlayer, _sentinel)
          ? this.replaceSitePlayer
          : replaceSitePlayer as bool?,
      downloadFolder: identical(downloadFolder, _sentinel)
          ? this.downloadFolder
          : downloadFolder as String?,
      customHeaders: identical(customHeaders, _sentinel)
          ? this.customHeaders
          : customHeaders as Map<String, String>?,
      downloadLinkBehavior: identical(downloadLinkBehavior, _sentinel)
          ? this.downloadLinkBehavior
          : downloadLinkBehavior as String?,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'hostPattern': hostPattern,
        'enabled': enabled,
        if (desktopMode != null) 'desktopMode': desktopMode,
        if (userAgentProfile != null) 'userAgentProfile': userAgentProfile,
        if (adblockEnabled != null) 'adblockEnabled': adblockEnabled,
        if (replaceSitePlayer != null)
          'replaceSitePlayer': replaceSitePlayer,
        if (downloadFolder != null) 'downloadFolder': downloadFolder,
        if (customHeaders != null && customHeaders!.isNotEmpty)
          'customHeaders': customHeaders,
        if (downloadLinkBehavior != null)
          'downloadLinkBehavior': downloadLinkBehavior,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory SiteProfile.fromJson(Map<String, dynamic> json) {
    final rawHeaders = json['customHeaders'];
    Map<String, String>? headers;
    if (rawHeaders is Map) {
      headers = rawHeaders.map((k, v) => MapEntry(k.toString(), v.toString()));
      if (headers.isEmpty) headers = null;
    }
    return SiteProfile(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      hostPattern: json['hostPattern'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? true,
      desktopMode: json['desktopMode'] as bool?,
      userAgentProfile: json['userAgentProfile'] as String?,
      adblockEnabled: json['adblockEnabled'] as bool?,
      replaceSitePlayer: json['replaceSitePlayer'] as bool?,
      downloadFolder: json['downloadFolder'] as String?,
      customHeaders: headers,
      downloadLinkBehavior: json['downloadLinkBehavior'] as String?,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SiteProfile && other.id == id);

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'SiteProfile($name, host=$hostPattern, enabled=$enabled)';
}

const Object _sentinel = Object();

/// Persistence for [SiteProfile] list.
///
/// Stores profiles as a JSON array in `site_profiles.json` under the
/// app support directory.
class SiteProfileStore {
  final String fileName;

  const SiteProfileStore({this.fileName = 'site_profiles.json'});

  /// Loads saved profiles. Returns an empty list on any error or if the
  /// file does not exist yet.
  Future<List<SiteProfile>> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const [];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((item) => SiteProfile.fromJson(Map<String, dynamic>.from(item)))
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  /// Persists [profiles] to disk.
  Future<void> save(List<SiteProfile> profiles) async {
    try {
      final file = await _file();
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      await file.writeAsString(
        jsonEncode(profiles.map((p) => p.toJson()).toList()),
      );
    } catch (_) {}
  }

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$fileName');
  }
}

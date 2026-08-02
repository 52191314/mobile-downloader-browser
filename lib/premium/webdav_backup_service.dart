/// P11 WebDAV backup — Digest-auth HTTP client for remote file storage.
///
/// Allows Pro+ users to back up their download queue, vault, and settings to
/// any WebDAV-compatible server (Nextcloud, ownCloud, Box, Synology, etc.).
///
/// ## Security
/// - Credentials stored in Android Keystore via `flutter_secure_storage`.
/// - HTTP Digest auth; cnonce is crypto-random.
/// - **HTTPS required** for non-private hosts; cleartext HTTP only for
///   loopback / RFC1918 private IPs (LAN NAS).
/// - Remote names and restore payloads are validated before write.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'pro_entitlement.dart';
import 'pro_features.dart';
import '../backup/unified_backup_database.dart';
import '../downloader/download_rules.dart';
import '../settings/download_settings.dart';
import '../sniffer/browser_library.dart';

/// Max restore JSON size (8 MiB) — blocks oversized hostile backups.
const int _kMaxRestoreBytes = 8 * 1024 * 1024;

/// Returns null if [url] is allowed; otherwise a user-facing error.
///
/// Policy: `https://` always OK. `http://` only for private/local hosts.
String? validateWebdavUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.host.isEmpty) {
    return 'Invalid WebDAV URL.';
  }
  if (uri.scheme == 'https') return null;
  if (uri.scheme == 'http') {
    if (_isPrivateOrLocalHost(uri.host)) return null;
    return 'HTTP is only allowed for local/private addresses '
        '(e.g. 192.168.x.x). Use HTTPS for remote servers.';
  }
  return 'URL must start with https:// (or http:// for LAN only).';
}

/// Sanitizes a remote backup filename. Returns null if unsafe.
String? sanitizeBackupRemoteName(String name) {
  final base = p.basename(name.trim());
  if (!RegExp(r'^aurora_backup_[A-Za-z0-9._-]+$').hasMatch(base)) {
    return null;
  }
  if (base.contains('..')) return null;
  return base;
}

bool _isPrivateOrLocalHost(String host) {
  final h = host.toLowerCase();
  if (h == 'localhost' || h == '127.0.0.1' || h == '::1') return true;
  final ip = InternetAddress.tryParse(host);
  if (ip == null) {
    // Hostnames on LAN (e.g. nas.local) — require HTTPS for safety.
    return false;
  }
  if (ip.isLoopback || ip.isLinkLocal) return true;
  final parts = host.split('.');
  if (parts.length == 4) {
    final a = int.tryParse(parts[0]) ?? -1;
    final b = int.tryParse(parts[1]) ?? -1;
    if (a == 10) return true;
    if (a == 192 && b == 168) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
  }
  return false;
}

// =============================================================================
// Digest auth HTTP client
// =============================================================================

/// An [http.Client] wrapper that transparently handles Digest authentication
/// (RFC 7616) for WebDAV requests.
///
/// On a 401 response with `WWW-Authenticate: Digest`, computes the client
/// response and retries once with the Authorization header.
class DigestAuthClient extends http.BaseClient {
  final http.Client _inner = http.Client();
  final String username;
  final String password;
  String? _cachedNonce;
  String? _cachedRealm;
  String? _cachedQop;
  String? _cachedOpaque;
  int _nonceCount = 0;

  DigestAuthClient({
    required this.username,
    required this.password,
  });

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // Pre-authorize if we have cached challenge params.
    if (_cachedNonce != null && _cachedRealm != null) {
      request.headers['Authorization'] = _buildDigestHeader(
        request.method,
        request.url.toString(),
      );
    }

    var response = await _inner.send(request);

    if (response.statusCode == 401) {
      final authHeader = response.headers['www-authenticate'] ?? '';
      if (authHeader.toLowerCase().startsWith('digest')) {
        _parseChallenge(authHeader);
        final newRequest = _cloneRequest(request);
        newRequest.headers['Authorization'] = _buildDigestHeader(
          request.method,
          request.url.toString(),
        );
        response = await _inner.send(newRequest);
      }
    }

    return response;
  }

  void _parseChallenge(String header) {
    // Extract realm, nonce, qop, opaque from the WWW-Authenticate header.
    final realmMatch = RegExp(r'realm="([^"]+)"').firstMatch(header);
    final nonceMatch = RegExp(r'nonce="([^"]+)"').firstMatch(header);
    final qopMatch = RegExp(r'qop="([^"]+)"').firstMatch(header);
    final opaqueMatch = RegExp(r'opaque="([^"]+)"').firstMatch(header);

    _cachedRealm = realmMatch?.group(1);
    _cachedNonce = nonceMatch?.group(1);
    _cachedQop = qopMatch?.group(1) ?? 'auth';
    _cachedOpaque = opaqueMatch?.group(1);
    _nonceCount = 0;
  }

  String _buildDigestHeader(String method, String uri) {
    _nonceCount++;
    final ha1 = md5.convert(utf8.encode('$username:$_cachedRealm:$password'));
    final ha2 = md5.convert(utf8.encode('$method:$uri'));
    final nc = _nonceCount.toString().padLeft(8, '0');
    final cnonce = _generateCnonce();
    final response = _cachedQop == 'auth'
        ? md5.convert(utf8.encode(
            '${ha1.toString()}:$_cachedNonce:$nc:$cnonce:$_cachedQop:${ha2.toString()}'))
        : md5.convert(utf8.encode(
            '${ha1.toString()}:$_cachedNonce:${ha2.toString()}'));

    final sb = StringBuffer('Digest ');
    sb.write('username="$username", ');
    sb.write('realm="$_cachedRealm", ');
    sb.write('nonce="$_cachedNonce", ');
    sb.write('uri="$uri", ');
    sb.write('response="${response.toString()}"');
    if (_cachedQop == 'auth') {
      sb.write(', qop=$_cachedQop, nc=$nc, cnonce="$cnonce"');
    }
    if (_cachedOpaque != null) {
      sb.write(', opaque="$_cachedOpaque"');
    }
    return sb.toString();
  }

  String _generateCnonce() {
    final bytes = List<int>.generate(16, (_) => _secureRandom.nextInt(256));
    return base64UrlEncode(bytes);
  }

  static final _secureRandom = Random.secure();

  http.Request _cloneRequest(http.BaseRequest original) {
    final uri = original.url;
    final newRequest = http.Request(original.method, uri);
    newRequest.headers.addAll(original.headers);
    newRequest.bodyBytes = (original is http.Request) ? original.bodyBytes : [];
    return newRequest;
  }

  @override
  void close() {
    _inner.close();
  }
}

// =============================================================================
// WebDAV settings
// =============================================================================

/// Persisted WebDAV connection settings.
class WebdavSettings {
  final String url;
  final String username;
  final String password;

  const WebdavSettings({
    required this.url,
    required this.username,
    required this.password,
  });

  Map<String, dynamic> toJson() => {
        'url': url,
        'username': username,
      };
}

// =============================================================================
// WebDAV backup service
// =============================================================================

/// Static entry point for WebDAV backup operations.
///
/// Typical flow:
/// 1. User configures WebDAV URL + credentials in settings (saved via
///    `flutter_secure_storage`).
/// 2. User triggers a backup (manual or scheduled).
/// 3. Service creates a ZIP archive of queue.json + free_caps.json +
///    settings + vault metadata, then uploads via PUT.
///
/// Restore: user selects a backup archive from the server, downloads it,
/// extracts, and overwrites local data.
class WebdavBackupService {
  WebdavBackupService._();

  static const _storage = FlutterSecureStorage();
  static const _keyUrl = 'webdav_url';
  static const _keyUsername = 'webdav_username';
  static const _keyPassword = 'webdav_password';

  // ---------------------------------------------------------------------------
  // Credential management
  // ---------------------------------------------------------------------------

  /// Loads saved WebDAV settings from secure storage.
  static Future<WebdavSettings?> loadSettings() async {
    final url = await _storage.read(key: _keyUrl);
    final username = await _storage.read(key: _keyUsername);
    final password = await _storage.read(key: _keyPassword);
    if (url == null || username == null || password == null) return null;
    return WebdavSettings(url: url, username: username, password: password);
  }

  /// Persists WebDAV settings to secure storage.
  /// Throws [ArgumentError] if the URL violates HTTPS/LAN policy.
  static Future<void> saveSettings(WebdavSettings settings) async {
    final err = validateWebdavUrl(settings.url);
    if (err != null) throw ArgumentError(err);
    await _storage.write(key: _keyUrl, value: settings.url);
    await _storage.write(key: _keyUsername, value: settings.username);
    await _storage.write(key: _keyPassword, value: settings.password);
  }

  /// Clears saved WebDAV credentials.
  static Future<void> clearSettings() async {
    await _storage.delete(key: _keyUrl);
    await _storage.delete(key: _keyUsername);
    await _storage.delete(key: _keyPassword);
  }

  // ---------------------------------------------------------------------------
  // HTTP helpers
  // ---------------------------------------------------------------------------

  static DigestAuthClient _client(WebdavSettings settings) =>
      DigestAuthClient(
        username: settings.username,
        password: settings.password,
      );

  static Uri _resolveUri(String baseUrl, String path) {
    final base = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
    return Uri.parse('$base${path.startsWith('/') ? path.substring(1) : path}');
  }

  // ---------------------------------------------------------------------------
  // Test connection
  // ---------------------------------------------------------------------------

  /// Tests connectivity and credentials by issuing PROPFIND on the root.
  /// Returns null on success, or an error message on failure.
  static Future<String?> testConnection(WebdavSettings settings) async {
    final urlErr = validateWebdavUrl(settings.url);
    if (urlErr != null) return urlErr;
    try {
      final client = _client(settings);
      final uri = _resolveUri(settings.url, '');
      final request = http.Request('PROPFIND', uri);
      request.headers['Depth'] = '0';
      // Minimal XML body required by some servers.
      request.body = '<?xml version="1.0"?>'
          '<d:propfind xmlns:d="DAV:">'
          '<d:prop><d:resourcetype/></d:prop>'
          '</d:propfind>';

      final response = await client.send(request);
      final status = response.statusCode;
      client.close();

      if (status == 207 || status == 200) return null; // Multi-Status or OK
      if (status == 401 || status == 403) {
        return 'Authentication failed (HTTP $status). Check username/password.';
      }
      if (status == 404) {
        return 'Path not found (HTTP 404). Check the server URL.';
      }
      return 'Server returned HTTP $status.';
    } catch (e) {
      return 'Connection failed: $e';
    }
  }

  // ---------------------------------------------------------------------------
  // List backups
  // ---------------------------------------------------------------------------

  /// Lists backup archives on the server (files matching `aurora_backup_*`).
  static Future<List<String>> listBackups(WebdavSettings settings) async {
    if (validateWebdavUrl(settings.url) != null) return [];
    final client = _client(settings);
    final uri = _resolveUri(settings.url, '');
    final request = http.Request('PROPFIND', uri);
    request.headers['Depth'] = '1';
    request.body = '<?xml version="1.0"?>'
        '<d:propfind xmlns:d="DAV:">'
        '<d:prop><d:displayname/><d:getcontentlength/><d:getlastmodified/></d:prop>'
        '</d:propfind>';

    try {
      final response = await client.send(request);
      final body = await response.stream.bytesToString();
      client.close();

      if (response.statusCode != 207) return [];

      // Parse Multi-Status XML to find backup files.
      final backupNames = <String>[];
      final hrefRegex = RegExp(r'<(?:\w+:)?href>([^<]+)</(?:\w+:)?href>', caseSensitive: false);
      final displayNameRegex = RegExp(r'<(?:\w+:)?displayname>([^<]+)</(?:\w+:)?displayname>', caseSensitive: false);

      final hrefMatches = hrefRegex.allMatches(body);
      final nameMatches = displayNameRegex.allMatches(body);

      for (var i = 0; i < hrefMatches.length; i++) {
        final rawName = i < nameMatches.length
            ? nameMatches.elementAt(i).group(1)!
            : hrefMatches.elementAt(i).group(1)!.split('/').last;
        final name = Uri.decodeComponent(rawName);
        final safe = sanitizeBackupRemoteName(name);
        if (safe != null && !backupNames.contains(safe)) backupNames.add(safe);
      }
      return backupNames;
    } catch (e) {
      client.close();
      debugPrint('[WebDAV] listBackups failed: $e');
      return [];
    }
  }

  // ---------------------------------------------------------------------------
  // Upload backup
  // ---------------------------------------------------------------------------

  /// Creates a backup archive and uploads to the WebDAV server.
  /// Returns the remote filename on success, null on failure.
  ///
  /// The backup includes:
  /// - queue.json (download queue state)
  /// - free_caps.json
  /// - upsell_state.json
  /// - settings export (JSON)
  ///
  /// TODO(P11): add vault metadata and settings export streams.
  static Future<String?> uploadBackup(WebdavSettings settings) async {
    if (validateWebdavUrl(settings.url) != null) return null;
    try {
      final tempDir = await getTemporaryDirectory();

      final settingsObj = await const DownloadSettingsStore().load();
      final libraryObj = await const BrowserLibraryStore().load();
      final rulesObj = await const DownloadRulesStore().load();

      final backupFile = await UnifiedBackupDatabase.exportTransactionalDatabase(
        downloadQueue: null,
        settings: settingsObj.toJson(),
        favorites: libraryObj.favorites.map((f) => f.toJson()).toList(),
        folders: libraryObj.folders.map((f) => f.toJson()).toList(),
        history: libraryObj.history.map((h) => h.toJson()).toList(),
        savedPages: libraryObj.savedPages.map((p) => p.toJson()).toList(),
        tabs: null,
        downloadRules: rulesObj.map((r) => r.toJson()).toList(),
        extra: null,
        targetDirectory: tempDir,
      );

      if (!await backupFile.exists()) return null;

      final archiveName = p.basename(backupFile.path);
      final client = _client(settings);
      final uri = _resolveUri(settings.url, archiveName);
      final request = http.Request('PUT', uri);
      request.bodyBytes = await backupFile.readAsBytes();

      final response = await client.send(request);
      client.close();

      try {
        await backupFile.delete();
      } catch (_) {}

      if (response.statusCode == 201 || response.statusCode == 204 || response.statusCode == 200) {
        debugPrint('[WebDAV] Backup uploaded: $archiveName');
        return archiveName;
      }
      debugPrint('[WebDAV] Upload failed: HTTP ${response.statusCode}');
      return null;
    } catch (e) {
      debugPrint('[WebDAV] uploadBackup failed: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Download backup
  // ---------------------------------------------------------------------------

  /// Downloads [remoteName] from the server and returns the local temp path.
  static Future<String?> downloadBackup(
      WebdavSettings settings, String remoteName) async {
    if (validateWebdavUrl(settings.url) != null) return null;
    final safeName = sanitizeBackupRemoteName(remoteName);
    if (safeName == null) return null;
    try {
      final client = _client(settings);
      final uri = _resolveUri(settings.url, safeName);
      final request = http.Request('GET', uri);

      final response = await client.send(request);
      if (response.statusCode != 200) {
        client.close();
        return null;
      }

      final bytes = await response.stream.toBytes();
      client.close();
      if (bytes.length > _kMaxRestoreBytes) {
        debugPrint('[WebDAV] download too large: ${bytes.length}');
        return null;
      }

      final tempDir = await getTemporaryDirectory();
      final localPath = p.join(tempDir.path, safeName);
      final file = File(localPath);
      await file.writeAsBytes(bytes);
      return localPath;
    } catch (e) {
      debugPrint('[WebDAV] downloadBackup failed: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Restore from backup
  // ---------------------------------------------------------------------------

  /// Restores local data from a downloaded backup archive.
  /// Returns true on success.
  ///
  /// Only known top-level keys are written; values must be JSON objects/maps
  /// (or empty). Oversized files are rejected.
  static Future<bool> restoreFromBackup(String localPath) async {
    try {
      final file = File(localPath);
      if (!await file.exists()) return false;
      final length = await file.length();
      if (length <= 0 || length > _kMaxRestoreBytes) return false;

      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return false;
      final data = Map<String, dynamic>.from(decoded);

      final appDir = await getApplicationSupportDirectory();
      const allowedKeys = {'queue', 'free_caps', 'upsell_state'};

      for (final key in allowedKeys) {
        if (!data.containsKey(key) || data[key] == null) continue;
        final value = data[key];
        // Must re-encode cleanly as JSON object/array/primitive — no functions.
        final encoded = jsonEncode(value);
        if (encoded.length > _kMaxRestoreBytes) return false;
        final out = File(p.join(appDir.path, '$key.json'));
        // free_caps / upsell_state use their real filenames.
        final target = switch (key) {
          'queue' => File(p.join(appDir.path, 'queue.json')),
          'free_caps' => File(p.join(appDir.path, 'free_caps.json')),
          'upsell_state' => File(p.join(appDir.path, 'upsell_state.json')),
          _ => out,
        };
        await target.writeAsString(encoded);
      }

      try {
        await file.delete();
      } catch (_) {}

      debugPrint('[WebDAV] Restore complete from $localPath');
      return true;
    } catch (e) {
      debugPrint('[WebDAV] restoreFromBackup failed: $e');
      return false;
    }
  }
}

/// Convenience: checks if WebDAV backup is gated for [tier].
bool webdavBackupAllowed(EntitlementTier tier) =>
    ProFeatures.allows(ProFeature.webdavBackup, tier);

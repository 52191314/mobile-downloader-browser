/// P11 WebDAV backup service scaffold.
///
/// Gated behind [ProFeature.webdavBackup]. Acts as an alternative to Drive
/// backup when `kDriveSyncEnabled` is false.
///
/// ## Implementation order (TODO):
/// 1. Add `dav` client dependency or implement custom HTTP client with Digest
///    auth (RFC 2518) using `package:http`.
/// 2. Settings UI: WebDAV URL, username, password (stored via
///    `flutter_secure_storage` for creds).
/// 3. `testConnection()` → PROPFIND on root.
/// 4. `uploadBackup(File)` → PUT backup archive.
/// 5. `listBackups()` → PROPFIND to list.
/// 6. `restoreBackup(String url)` → GET + extract.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

/// Holds WebDAV connection settings.
class WebdavSettings {
  final String url;
  final String username;
  final String password;

  const WebdavSettings({
    required this.url,
    required this.username,
    required this.password,
  });
}

/// Static entry point for WebDAV backup operations.
///
/// Typical call site:
/// ```
/// if (!ProFeatures.allows(ProFeature.webdavBackup, tier)) {
///   showProUpsell(context, ProFeature.webdavBackup);
///   return;
/// }
/// await WebdavBackupService.upload(settings, backupFile);
/// ```
class WebdavBackupService {
  WebdavBackupService._();

  /// Tests connectivity + credentials by issuing a PROPFIND on the root.
  /// TODO(P11): implement PROPFIND with Digest auth.
  static Future<bool> testConnection(WebdavSettings settings) async {
    debugPrint('[WebDAV] TODO: test connection to ${settings.url}');
    return false;
  }

  /// Uploads [backupFile] to the WebDAV server.
  /// TODO(P11): implement PUT with Digest auth, chunked upload.
  static Future<bool> upload(WebdavSettings settings, File backupFile) async {
    debugPrint('[WebDAV] TODO: upload ${backupFile.path} to ${settings.url}');
    return false;
  }

  /// Lists backup archives on the server.
  /// TODO(P11): implement PROPFIND, parse XML response.
  static Future<List<String>> listBackups(WebdavSettings settings) async {
    debugPrint('[WebDAV] TODO: list backups from ${settings.url}');
    return [];
  }

  /// Downloads and restores a backup from [remoteUrl].
  /// TODO(P11): implement GET + extract to restore directory.
  static Future<bool> restore(
      WebdavSettings settings, String remoteUrl) async {
    debugPrint('[WebDAV] TODO: restore from $remoteUrl');
    return false;
  }
}

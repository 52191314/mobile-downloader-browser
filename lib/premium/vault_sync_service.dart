/// E2EE Vault Sync — encrypted vault backup over user-controlled storage.
///
/// Gate: [ProFeature.vaultSync] (Ultra tier only).
///
/// Design:
/// - Derive sync key from user passphrase using PBKDF2 (Argon2 not available
///   in pure Dart; PBKDF2-SHA256 with high iteration count is acceptable).
/// - Encrypt vault metadata + file list using AES-GCM.
/// - Upload to user WebDAV at `/aurora/vault-sync/`.
/// - Restore requires passphrase — wrong passphrase fails closed.
/// - Keys never leave the device; server operator cannot read files.
///
/// NEVER put plaintext vault in the existing auto WebDAV backup.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'pro_entitlement.dart';
import 'pro_features.dart';
import 'vault_crypto.dart';

/// Key length in bytes (AES-256).
const _kKeyLength = 32;

/// Salt length in bytes.
const _kSaltLength = 32;

/// Vault sync blob format version.
const _kVaultSyncVersion = 1;

/// Manages encrypted vault sync over the user's own WebDAV/S3 storage.
class VaultSyncService {
  final String _webdavBaseUrl;
  final String _webdavUsername;
  final String _webdavPassword;

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  static const _keySalt = 'vault_sync_salt';

  /// The full WebDAV path for vault sync.
  String get _syncPath => '$_webdavBaseUrl/aurora/vault-sync';

  VaultSyncService({
    required String webdavBaseUrl,
    required String webdavUsername,
    required String webdavPassword,
  })  : _webdavBaseUrl = webdavBaseUrl.endsWith('/')
            ? webdavBaseUrl.substring(0, webdavBaseUrl.length - 1)
            : webdavBaseUrl,
        _webdavUsername = webdavUsername,
        _webdavPassword = webdavPassword;

  // ---------------------------------------------------------------------------
  // Upload
  // ---------------------------------------------------------------------------

  /// Encrypt and upload vault data to user WebDAV.
  ///
  /// [passphrase] is the user-chosen sync passphrase.
  /// [vaultData] is a JSON-serializable map of vault contents.
  /// Returns true on success.
  Future<bool> uploadVault({
    required String passphrase,
    required Map<String, dynamic> vaultData,
  }) async {
    try {
      // 1. Generate or load salt
      final salt = await _getOrCreateSalt();

      // 2. Derive key from passphrase + salt
      final keyBytes = _deriveKey(passphrase, salt);

      // 3. Prepare plaintext
      final plaintext = utf8.encode(jsonEncode({
        'version': _kVaultSyncVersion,
        'timestamp': DateTime.now().toIso8601String(),
        'data': vaultData,
      }));

      // 4. Encrypt with AES-GCM
      final key = enc.Key(Uint8List.fromList(keyBytes));
      final nonce = _generateNonce();
      final iv = enc.IV(Uint8List.fromList(nonce));
      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));

      final encrypted = encrypter.encryptBytes(
        Uint8List.fromList(plaintext),
        iv: iv,
      );

      // 5. Build blob: salt (32) | nonce (12) | ciphertext+tag
      final blob = <int>[
        ...salt,
        ...nonce,
        ...encrypted.bytes,
      ];

      // 6. Upload via WebDAV PUT
      final blobBase64 = base64.encode(blob);
      final response = await _webdavRequest(
        'PUT',
        '$_syncPath/vault.dat',
        body: blobBase64,
      );

      return response.statusCode == 201 || response.statusCode == 204;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[VaultSyncService] upload failed: $e');
      }
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Download / Restore
  // ---------------------------------------------------------------------------

  /// Download and decrypt vault from user WebDAV.
  ///
  /// Returns the decrypted vault data JSON on success, null on failure.
  /// A wrong passphrase results in null (fails closed).
  Future<Map<String, dynamic>?> downloadVault({
    required String passphrase,
  }) async {
    try {
      // 1. Download blob
      final response = await _webdavRequest('GET', '$_syncPath/vault.dat');
      if (response.statusCode != 200) return null;

      final blobBase64 = response.body;
      final blob = base64.decode(blobBase64);

      if (blob.length < _kSaltLength + 12 + 16 /* min GCM tag */) {
        return null;
      }

      // 2. Extract salt, nonce, ciphertext
      final salt = blob.sublist(0, _kSaltLength);
      final nonce = blob.sublist(_kSaltLength, _kSaltLength + 12);
      final ciphertext = blob.sublist(_kSaltLength + 12);

      // 3. Derive key
      final keyBytes = _deriveKey(passphrase, salt);
      final key = enc.Key(Uint8List.fromList(keyBytes));
      final iv = enc.IV(Uint8List.fromList(nonce));
      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));

      // 4. Decrypt
      final decrypted = encrypter.decryptBytes(
        enc.Encrypted(Uint8List.fromList(ciphertext)),
        iv: iv,
      );

      // 5. Parse JSON
      final plaintext = utf8.decode(decrypted);
      final data = jsonDecode(plaintext) as Map<String, dynamic>;

      // 6. Verify version
      if (data['version'] != _kVaultSyncVersion) {
        return null;
      }

      return data['data'] as Map<String, dynamic>?;
    } catch (e) {
      // Failed closed — wrong passphrase or corrupt blob
      if (kDebugMode) {
        debugPrint('[VaultSyncService] download failed: $e');
      }
      return null;
    }
  }

  /// Uploads a single encrypted vault blob to WebDAV.
  ///
  /// Streams the vault file through AES-GCM into a temp blob file, then
  /// streams a chunked-base64 body into the PUT (optimization research
  /// P10) — a multi-GB vault file no longer needs 3 in-memory copies.
  Future<bool> uploadVaultBlob({
    required String passphrase,
    required String vaultName,
    required File vaultFile,
  }) async {
    try {
      final salt = await _getOrCreateSalt();
      final keyBytes = _deriveKey(passphrase, salt);
      final nonce = _generateNonce();

      final blobTmp = File('${vaultFile.path}.blob.tmp');
      try {
        // Pass only sendable values into the isolate (paths + key material).
        final srcPath = vaultFile.path;
        final tmpPath = blobTmp.path;
        final keyU8 = Uint8List.fromList(keyBytes);
        final nonceU8 = Uint8List.fromList(nonce);
        final saltU8 = Uint8List.fromList(salt);
        await Isolate.run(() async {
          await encryptGcmStream(
            src: File(srcPath),
            dst: File(tmpPath),
            key: keyU8,
            nonce: nonceU8,
            header: Uint8List.fromList([...saltU8, ...nonceU8]),
          );
        });

        final expectedLen =
            await vaultFile.length() + _kSaltLength + 12 + kVaultGcmTagBytes;
        final response = await _webdavRequestStreamed(
          'PUT',
          '$_syncPath/blobs/$vaultName',
          body: _streamBase64File(blobTmp),
          contentLength: ((expectedLen + 2) ~/ 3) * 4,
        );
        return response.statusCode == 201 || response.statusCode == 204;
      } finally {
        try {
          if (await blobTmp.exists()) await blobTmp.delete();
        } catch (_) {}
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[VaultSyncService] blob upload failed: $e');
      return false;
    }
  }

  /// Downloads and restores a single encrypted vault blob from WebDAV.
  ///
  /// Streams the response body through a chunked base64 decoder into a temp
  /// blob file, then decrypts off the UI isolate (P10) — bounded memory for
  /// multi-GB vault blobs.
  Future<bool> downloadAndRestoreVaultBlob({
    required String passphrase,
    required String vaultName,
    required Directory vaultDir,
  }) async {
    try {
      final uri = Uri.parse('$_syncPath/blobs/$vaultName');
      final request = http.Request('GET', uri);
      _applyAuth(request);
      final client = http.Client();
      final blobTmp = File('${vaultDir.path}/.restore-$vaultName.tmp');
      final dest = File('${vaultDir.path}/$vaultName');
      final destTmp = File('${dest.path}.restore.tmp');
      try {
        final streamedResponse = await client.send(request);
        if (streamedResponse.statusCode != 200) return false;

        final sink = blobTmp.openWrite();
        final decoder = ChunkedBase64Decoder();
        try {
          await for (final chunk in streamedResponse.stream) {
            final decoded = decoder.add(utf8.decode(chunk, allowMalformed: true));
            if (decoded.isNotEmpty) sink.add(decoded);
          }
          final tail = decoder.close();
          if (tail.isNotEmpty) sink.add(tail);
        } finally {
          await sink.close();
        }

        if (await blobTmp.length() < _kSaltLength + 12 + 16) return false;

        final salt = (await blobTmp
                .openRead(0, _kSaltLength)
                .expand((c) => c)
                .toList())
            .cast<int>();
        final nonce = (await blobTmp
                .openRead(_kSaltLength, _kSaltLength + 12)
                .expand((c) => c)
                .toList())
            .cast<int>();

        final keyBytes = _deriveKey(passphrase, salt);
        final srcPath = blobTmp.path;
        final tmpPath = destTmp.path;
        final keyU8 = Uint8List.fromList(keyBytes);
        final nonceU8 = Uint8List.fromList(nonce);
        await Isolate.run(() async {
          await decryptGcmStream(
            src: File(srcPath),
            dst: File(tmpPath),
            key: keyU8,
            nonce: nonceU8,
            skipBytes: _kSaltLength + 12,
          );
        });
        await destTmp.rename(dest.path);
        return true;
      } finally {
        client.close();
        try {
          if (await blobTmp.exists()) await blobTmp.delete();
        } catch (_) {}
        try {
          if (await destTmp.exists()) await destTmp.delete();
        } catch (_) {}
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[VaultSyncService] blob restore failed: $e');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Delete remote vault
  // ---------------------------------------------------------------------------

  /// Delete the remote vault sync file.
  Future<bool> deleteRemoteVault() async {
    try {
      final response = await _webdavRequest('DELETE', '$_syncPath/vault.dat');
      return response.statusCode == 204 || response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Crypto helpers
  // ---------------------------------------------------------------------------

  Uint8List _deriveKey(String passphrase, List<int> salt) {
    final passBytes = utf8.encode(passphrase);
    final hmac = Hmac(sha256, passBytes);
    final result = <int>[];
    int blockIndex = 1;

    while (result.length < _kKeyLength) {
      final blockInput = <int>[
        ...salt,
        (blockIndex >> 24) & 0xff,
        (blockIndex >> 16) & 0xff,
        (blockIndex >> 8) & 0xff,
        blockIndex & 0xff,
      ];
      var u = hmac.convert(blockInput).bytes;
      final block = List<int>.from(u);

      for (int i = 1; i < 10000; i++) {
        u = hmac.convert(u).bytes;
        for (int j = 0; j < block.length; j++) {
          block[j] ^= u[j];
        }
      }

      result.addAll(block);
      blockIndex++;
    }

    return Uint8List.fromList(result.sublist(0, _kKeyLength));
  }

  Future<List<int>> _getOrCreateSalt() async {
    final stored = await _secureStorage.read(key: _keySalt);
    if (stored != null && stored.isNotEmpty) {
      return base64.decode(stored);
    }
    final salt = List<int>.generate(
      _kSaltLength,
      (_) => Random.secure().nextInt(256),
    );
    await _secureStorage.write(key: _keySalt, value: base64.encode(salt));
    return salt;
  }

  List<int> _generateNonce() {
    return List<int>.generate(12, (_) => Random.secure().nextInt(256));
  }

  // ---------------------------------------------------------------------------
  // WebDAV HTTP helpers
  // ---------------------------------------------------------------------------

  Future<http.Response> _webdavRequest(
    String method,
    String url, {
    String? body,
  }) async {
    final uri = Uri.parse(url);
    // Create parent directories if needed (MKCOL)
    if (method == 'PUT') {
      await _ensureParentDirectories(uri);
    }

    final request = http.Request(method, uri);
    if (body != null) {
      request.body = body;
    }

    _applyAuth(request);

    final client = http.Client();
    try {
      final streamedResponse = await client.send(request);
      return await http.Response.fromStream(streamedResponse);
    } finally {
      client.close();
    }
  }

  /// Applies Basic auth + content type to a request.
  void _applyAuth(http.BaseRequest request) {
    final credentials = base64.encode(
      utf8.encode('$_webdavUsername:$_webdavPassword'),
    );
    request.headers['Authorization'] = 'Basic $credentials';
    request.headers['Content-Type'] = 'application/octet-stream';
  }

  /// PUT/POST variant that streams [body] with a known [contentLength]
  /// (used by the vault blob upload so a multi-GB blob never materializes
  /// in memory — P10).
  Future<http.Response> _webdavRequestStreamed(
    String method,
    String url, {
    required Stream<List<int>> body,
    required int contentLength,
  }) async {
    final uri = Uri.parse(url);
    // Create parent directories if needed (MKCOL)
    if (method == 'PUT') {
      await _ensureParentDirectories(uri);
    }

    final request = http.StreamedRequest(method, uri);
    request.contentLength = contentLength;
    _applyAuth(request);

    final client = http.Client();
    try {
      final responseFuture = client.send(request);
      await for (final chunk in body) {
        request.sink.add(chunk);
      }
      await request.sink.close();
      return await http.Response.fromStream(await responseFuture);
    } finally {
      client.close();
    }
  }

  /// Streams [file] as chunked-base64 UTF-8 bytes (stateful encoder keeps
  /// 3-byte groups intact across chunk boundaries).
  Stream<List<int>> _streamBase64File(File file) async* {
    final encoder = ChunkedBase64Encoder();
    await for (final chunk in file.openRead()) {
      final s = encoder.add(chunk);
      if (s.isNotEmpty) yield utf8.encode(s);
    }
    final tail = encoder.close();
    if (tail.isNotEmpty) yield utf8.encode(tail);
  }

  Future<void> _ensureParentDirectories(Uri uri) async {
    // Try MKCOL on parent path
    final segments = uri.pathSegments;
    for (int i = 1; i < segments.length; i++) {
      final parentPath = '/${segments.sublist(0, i).join('/')}';
      final parentUri = uri.replace(path: parentPath);
      try {
        final req = http.Request('MKCOL', parentUri);
        final credentials = base64.encode(
          utf8.encode('$_webdavUsername:$_webdavPassword'),
        );
        req.headers['Authorization'] = 'Basic $credentials';
        final client = http.Client();
        try {
          await client.send(req);
        } finally {
          client.close();
        }
      } catch (_) {
        // Directory may already exist, ignore
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Gate helper
  // ---------------------------------------------------------------------------

  /// Whether the user has access to vault sync.
  static bool isAllowed(EntitlementTier tier) {
    return ProFeatures.allows(ProFeature.vaultSync, tier);
  }
}

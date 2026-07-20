/// P7 Private Vault — Keystore-backed AES-GCM vault for downloaded files.
///
/// Security notes:
/// - Keys live in [FlutterSecureStorage] (Android Keystore-backed when available).
/// - File format v1: `0x01 | 12-byte nonce | AES-GCM ciphertext+tag`.
/// - Legacy CBC blobs (no version byte) can still be decrypted for export.
/// - Auth **fails closed** when the device has no PIN/biometric.
/// - [vaultName] is always basename-sanitized to block path traversal.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'phase2_caps.dart';
import 'pro_entitlement.dart';

/// How long an unlocked session lasts before biometric is required again.
const Duration _kUnlockDuration = Duration(minutes: 5);

/// Vault file format version for AES-GCM.
const int _kVaultFormatGcm = 0x01;

/// P7 Private Vault. Instantiate once and reuse.
class VaultService {
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  final LocalAuthentication _localAuth = LocalAuthentication();
  Directory? _vaultDir;
  enc.Key? _sessionKey;
  DateTime? _unlockedAt;

  static const _keyAesKey = 'vault_aes_key';
  static const _keyRecoveryShown = 'vault_recovery_shown';

  String? _lastRecoveryKey;

  /// Returns the recovery key (shown exactly once before first lock).
  String? get recoveryKey => _lastRecoveryKey;

  // ---------------------------------------------------------------------------
  // Initialization
  // ---------------------------------------------------------------------------

  /// Ensures vault directory exists and a Keystore-backed key is ready.
  Future<bool> ensureInitialized() async {
    await vaultDir;
    final existingKey = await _secureStorage.read(key: _keyAesKey);
    if (existingKey != null) return true;

    final keyBytes =
        List<int>.generate(32, (_) => Random.secure().nextInt(256));
    final keyBase64 = base64Url.encode(keyBytes);
    await _secureStorage.write(key: _keyAesKey, value: keyBase64);
    _lastRecoveryKey = keyBase64;
    return true;
  }

  /// Whether the recovery key has been shown to the user.
  Future<bool> get recoveryKeyShown async {
    final val = await _secureStorage.read(key: _keyRecoveryShown);
    return val == 'true';
  }

  /// Marks recovery key as shown and clears it from memory.
  Future<void> markRecoveryKeyShown() async {
    await _secureStorage.write(key: _keyRecoveryShown, value: 'true');
    _lastRecoveryKey = null;
  }

  // ---------------------------------------------------------------------------
  // Biometric gate
  // ---------------------------------------------------------------------------

  /// Returns true if biometric/device credential passes or session is still
  /// unlocked.
  ///
  /// **Fails closed** when the device has no PIN/pattern/biometric — vault
  /// must not open on open emulators / unsecured devices.
  Future<bool> authenticate({required String reason}) async {
    if (_sessionKey != null &&
        _unlockedAt != null &&
        DateTime.now().difference(_unlockedAt!) < _kUnlockDuration) {
      return true;
    }

    final deviceSupported = await _localAuth.isDeviceSupported();
    final canCheck = await _localAuth.canCheckBiometrics;
    if (!deviceSupported && !canCheck) {
      if (kDebugMode) {
        debugPrint('[Vault] No device credential — fail closed');
      }
      return false;
    }

    try {
      final didAuth = await _localAuth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false, // allow PIN/pattern fallback
        ),
      );
      if (didAuth) {
        _unlockedAt = DateTime.now();
        await _loadSessionKey();
      }
      return didAuth;
    } catch (e) {
      if (kDebugMode) debugPrint('[Vault] authenticate failed: $e');
      return false;
    }
  }

  Future<void> _loadSessionKey() async {
    final keyBase64 = await _secureStorage.read(key: _keyAesKey);
    if (keyBase64 == null) return;
    _sessionKey = enc.Key(base64Url.decode(keyBase64));
  }

  // ---------------------------------------------------------------------------
  // Vault directory
  // ---------------------------------------------------------------------------

  Future<Directory> get vaultDir async {
    if (_vaultDir != null) return _vaultDir!;
    final appDir = await getApplicationSupportDirectory();
    final dir = Directory('${appDir.path}/vault');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
      final nomedia = File('${dir.path}/.nomedia');
      if (!await nomedia.exists()) await nomedia.create();
    }
    _vaultDir = dir;
    return dir;
  }

  /// Reject path traversal; only allow a single path segment filename.
  static String? sanitizeVaultName(String vaultName) {
    final raw = vaultName.trim();
    // Reject any path-like input before basename (basename would hide `../`).
    if (raw.isEmpty ||
        raw.contains('/') ||
        raw.contains('\\') ||
        raw.contains('\x00') ||
        raw.contains('..')) {
      return null;
    }
    if (raw == '.' || raw == '..') return null;
    if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(raw)) return null;
    return raw;
  }

  // ---------------------------------------------------------------------------
  // Inventory
  // ---------------------------------------------------------------------------

  Future<int> fileCount() async {
    final dir = await vaultDir;
    try {
      return dir.listSync().whereType<File>().where((f) {
        return !p.basename(f.path).startsWith('.');
      }).length;
    } catch (_) {
      return 0;
    }
  }

  Future<bool> canAccept(EntitlementTier tier) async {
    final count = await fileCount();
    return Phase2Caps.vaultInventoryOk(count, tier);
  }

  // ---------------------------------------------------------------------------
  // Store (import into vault) — AES-GCM
  // ---------------------------------------------------------------------------

  /// Encrypts [source] into the vault with AES-256-GCM.
  /// Returns vault filename on success, null on failure.
  Future<String?> store(File source, {EntitlementTier? tier}) async {
    final effectiveTier = tier ?? EntitlementTier.free;
    if (!await canAccept(effectiveTier)) return null;
    if (!await authenticate(reason: 'Store file in private vault')) return null;

    final dir = await vaultDir;
    final sourceBytes = await source.readAsBytes();
    if (sourceBytes.isEmpty) return null;

    final key = _sessionKey;
    if (key == null) return null;

    final nonce = enc.IV.fromSecureRandom(12);
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));
    final encrypted = encrypter.encryptBytes(sourceBytes, iv: nonce);

    final vaultName = '${DateTime.now().millisecondsSinceEpoch}.vault';
    final dest = File(p.join(dir.path, vaultName));
    // v1: version | nonce(12) | ciphertext+tag
    final outBytes = Uint8List.fromList([
      _kVaultFormatGcm,
      ...nonce.bytes,
      ...encrypted.bytes,
    ]);
    await dest.writeAsBytes(outBytes, flush: true);
    return vaultName;
  }

  // ---------------------------------------------------------------------------
  // Export (decrypt from vault)
  // ---------------------------------------------------------------------------

  /// Decrypts [vaultName] and writes to [destination].
  Future<bool> export(
    String vaultName,
    String destination, {
    bool authed = false,
  }) async {
    if (!authed && !await authenticate(reason: 'Export file from vault')) {
      return false;
    }
    final safeName = sanitizeVaultName(vaultName);
    if (safeName == null) return false;

    final dir = await vaultDir;
    final src = File(p.join(dir.path, safeName));
    // Ensure resolved path stays under vault dir.
    final vaultRoot = await dir.resolveSymbolicLinks();
    final resolved = src.existsSync()
        ? await src.resolveSymbolicLinks()
        : src.path;
    if (!resolved.startsWith(vaultRoot)) return false;
    if (!await src.exists()) return false;

    final key = _sessionKey;
    if (key == null) return false;

    final blob = await src.readAsBytes();
    final plain = _decryptBlob(key, blob);
    if (plain == null) return false;

    final dest = File(destination);
    await dest.parent.create(recursive: true);
    await dest.writeAsBytes(plain, flush: true);
    return true;
  }

  /// Decrypts vault blob (GCM v1 or legacy CBC).
  Uint8List? _decryptBlob(enc.Key key, Uint8List blob) {
    try {
      if (blob.isEmpty) return null;

      // New format: 0x01 | nonce(12) | ct+tag
      if (blob[0] == _kVaultFormatGcm && blob.length > 13) {
        final nonce = enc.IV(Uint8List.sublistView(blob, 1, 13));
        final ct = Uint8List.sublistView(blob, 13);
        final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));
        final decrypted =
            encrypter.decryptBytes(enc.Encrypted(ct), iv: nonce);
        return Uint8List.fromList(decrypted);
      }

      // Legacy CBC: IV(16) | ciphertext (no auth)
      if (blob.length > 16) {
        final iv = enc.IV(Uint8List.sublistView(blob, 0, 16));
        final ct = Uint8List.sublistView(blob, 16);
        final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));
        final decrypted =
            encrypter.decryptBytes(enc.Encrypted(ct), iv: iv);
        return Uint8List.fromList(decrypted);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[Vault] decrypt failed: $e');
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Delete / list
  // ---------------------------------------------------------------------------

  Future<bool> delete(String vaultName) async {
    final safeName = sanitizeVaultName(vaultName);
    if (safeName == null) return false;
    final dir = await vaultDir;
    final file = File(p.join(dir.path, safeName));
    final vaultRoot = await dir.resolveSymbolicLinks();
    if (!file.existsSync()) return false;
    final resolved = await file.resolveSymbolicLinks();
    if (!resolved.startsWith(vaultRoot)) return false;
    await file.delete();
    return true;
  }

  Future<List<VaultEntry>> list({bool authed = false}) async {
    if (!authed && !await authenticate(reason: 'List vault files')) {
      return [];
    }
    final dir = await vaultDir;
    final files = dir.listSync().whereType<File>().where((f) {
      return !p.basename(f.path).startsWith('.');
    });
    return files.map((f) {
      final stat = f.statSync();
      return VaultEntry(
        name: p.basename(f.path),
        size: stat.size,
        modified: stat.modified,
      );
    }).toList()
      ..sort((a, b) => b.modified.compareTo(a.modified));
  }

  void lock() {
    _sessionKey = null;
    _unlockedAt = null;
  }
}

class VaultEntry {
  final String name;
  final int size;
  final DateTime modified;

  const VaultEntry({
    required this.name,
    required this.size,
    required this.modified,
  });
}

/// P7 Private Vault — Keystore-backed AES-128-CBC vault for downloaded files.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:path_provider/path_provider.dart';

import 'phase2_caps.dart';
import 'pro_entitlement.dart';

/// How long an unlocked session lasts before biometric is required again.
const Duration _kUnlockDuration = Duration(minutes: 5);

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

    final keyBytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    final keyBase64 = base64Url.encode(keyBytes);
    await _secureStorage.write(key: _keyAesKey, value: keyBase64);
    _lastRecoveryKey = keyBase64;
    debugPrint('[Vault] Initialized');
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

  /// Returns true if biometric passes or session is still unlocked.
  Future<bool> authenticate({required String reason}) async {
    if (_sessionKey != null &&
        _unlockedAt != null &&
        DateTime.now().difference(_unlockedAt!) < _kUnlockDuration) {
      return true;
    }
    final canCheck = await _localAuth.canCheckBiometrics;
    if (!canCheck) {
      final canAuth = await _localAuth.isDeviceSupported();
      if (!canAuth) {
        debugPrint('[Vault] No auth available — proceeding.');
        return true;
      }
    }
    final didAuth = await _localAuth.authenticate(
      localizedReason: reason,
      options: const AuthenticationOptions(
        stickyAuth: true,
        biometricOnly: false,
      ),
    );
    if (didAuth) {
      _unlockedAt = DateTime.now();
      await _loadSessionKey();
    }
    return didAuth;
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

  // ---------------------------------------------------------------------------
  // Inventory
  // ---------------------------------------------------------------------------

  /// Number of vault files (excluding dotfiles like .nomedia).
  Future<int> fileCount() async {
    final dir = await vaultDir;
    try {
      return dir.listSync().whereType<File>().where((f) {
        return !f.uri.pathSegments.last.startsWith('.');
      }).length;
    } catch (_) {
      return 0;
    }
  }

  /// True if vault can accept a new file for [tier].
  Future<bool> canAccept(EntitlementTier tier) async {
    final count = await fileCount();
    return Phase2Caps.vaultInventoryOk(count, tier);
  }

  // ---------------------------------------------------------------------------
  // Store (import into vault)
  // ---------------------------------------------------------------------------

  /// Moves [source] into the vault with AES-128-CBC encryption.
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

    final iv = enc.IV.fromSecureRandom(16);
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));
    final encrypted = encrypter.encryptBytes(sourceBytes, iv: iv);

    final vaultName = '${DateTime.now().millisecondsSinceEpoch}.vault';
    final dest = File('${dir.path}/$vaultName');
    final outBytes = Uint8List.fromList([...iv.bytes, ...encrypted.bytes]);
    await dest.writeAsBytes(outBytes);
    return vaultName;
  }

  // ---------------------------------------------------------------------------
  // Export (decrypt from vault)
  // ---------------------------------------------------------------------------

  /// Decrypts [vaultName] and writes to [destination].
  /// Returns true on success.
  Future<bool> export(String vaultName, String destination,
      {bool authed = false}) async {
    if (!authed && !await authenticate(reason: 'Export file from vault')) {
      return false;
    }
    final dir = await vaultDir;
    final src = File('${dir.path}/$vaultName');
    if (!await src.exists()) return false;

    final key = _sessionKey;
    if (key == null) return false;

    final encryptedBytes = await src.readAsBytes();
    if (encryptedBytes.length < 16) return false;

    final iv = enc.IV(Uint8List.fromList(encryptedBytes.take(16).toList()));
    final ciphertext = Uint8List.fromList(encryptedBytes.skip(16).toList());

    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));
    final decrypted = encrypter.decryptBytes(enc.Encrypted(ciphertext), iv: iv);

    final dest = File(destination);
    await dest.writeAsBytes(decrypted);
    return true;
  }

  // ---------------------------------------------------------------------------
  // Delete
  // ---------------------------------------------------------------------------

  Future<bool> delete(String vaultName) async {
    final dir = await vaultDir;
    final file = File('${dir.path}/$vaultName');
    if (!await file.exists()) return false;
    await file.delete();
    return true;
  }

  // ---------------------------------------------------------------------------
  // List
  // ---------------------------------------------------------------------------

  Future<List<VaultEntry>> list({bool authed = false}) async {
    if (!authed && !await authenticate(reason: 'List vault files')) {
      return [];
    }
    final dir = await vaultDir;
    final files = dir.listSync().whereType<File>().where((f) {
      return !f.uri.pathSegments.last.startsWith('.');
    });
    return files.map((f) {
      final stat = f.statSync();
      return VaultEntry(
        name: f.uri.pathSegments.last,
        size: stat.size,
        modified: stat.modified,
      );
    }).toList()
      ..sort((a, b) => b.modified.compareTo(a.modified));
  }

  // ---------------------------------------------------------------------------
  // Lock
  // ---------------------------------------------------------------------------

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

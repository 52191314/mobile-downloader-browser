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
import 'dart:isolate';
import 'dart:math';

import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'phase2_caps.dart';
import 'pro_entitlement.dart';
import 'vault_crypto.dart';

/// How long an unlocked session lasts before biometric is required again.
const Duration _kUnlockDuration = Duration(minutes: 5);

/// Vault file format version for AES-GCM.
const int _kVaultFormatGcm = 0x01;

/// Why the last [VaultService.authenticate] attempt failed.
/// `null` (service field) means the last attempt succeeded.
enum VaultAuthFailure {
  /// Device has no enrolled lock screen (no PIN/pattern/biometric).
  noCredential,
  /// User dismissed or cancelled the system auth dialog.
  cancelled,
  /// The platform auth call threw.
  error,
}

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

  /// Why the most recent [authenticate] failed, or null when the last
  /// attempt succeeded or none was made yet.
  VaultAuthFailure? lastAuthFailure;

  /// Raw error detail when [lastAuthFailure] is [VaultAuthFailure.error].
  String? lastAuthFailureDetail;

  /// User-facing explanation of the most recent authentication failure.
  String? get lastAuthFailureMessage {
    switch (lastAuthFailure) {
      case VaultAuthFailure.noCredential:
        return 'No screen lock (PIN, pattern, or biometric) is set up on '
            'this device. Private Vault needs one to encrypt your files.';
      case VaultAuthFailure.cancelled:
        return 'Authentication was cancelled.';
      case VaultAuthFailure.error:
        return lastAuthFailureDetail ?? 'Authentication failed unexpectedly.';
      case null:
        return null;
    }
  }

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

  /// Returns the recovery key when it has never been acknowledged, re-reading
  /// it from secure storage. A key created in an earlier session whose banner
  /// was never dismissed is still recoverable (fixes the lost-key bug where
  /// `_lastRecoveryKey` memory was the only copy).
  Future<String?> recoveryKeyIfUnshown() async {
    if (await recoveryKeyShown) return null;
    final keyBase64 = await _secureStorage.read(key: _keyAesKey);
    if (keyBase64 == null) return null;
    _lastRecoveryKey = keyBase64;
    return keyBase64;
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
  /// **Fails closed** when the device has no enrolled PIN/pattern/biometric or auth fails.
  /// Note: On Android `isDeviceSupported()` verifies enrolled device credentials; on iOS
  /// local_auth_darwin handles enrolled checks during `authenticate()`. The outcome is
  /// strictly fail-closed across both platforms.
  Future<bool> authenticate({required String reason}) async {
    if (_sessionKey != null &&
        _unlockedAt != null &&
        DateTime.now().difference(_unlockedAt!) < _kUnlockDuration) {
      lastAuthFailure = null;
      lastAuthFailureDetail = null;
      return true;
    }

    final deviceSupported = await _localAuth.isDeviceSupported();
    final canCheck = await _localAuth.canCheckBiometrics;
    if (!deviceSupported && !canCheck) {
      lastAuthFailure = VaultAuthFailure.noCredential;
      lastAuthFailureDetail = null;
      if (kDebugMode) {
        debugPrint('[Vault] No device credential — fail closed');
      }
      return false;
    }

    try {
      final didAuth = await _localAuth.authenticate(
        localizedReason: reason,
        persistAcrossBackgrounding: true,
        biometricOnly: false, // allow PIN/pattern fallback
      );
      if (didAuth) {
        lastAuthFailure = null;
        lastAuthFailureDetail = null;
        _unlockedAt = DateTime.now();
        await _loadSessionKey();
      } else {
        lastAuthFailure = VaultAuthFailure.cancelled;
        lastAuthFailureDetail = null;
      }
      return didAuth;
    } catch (e) {
      lastAuthFailure = VaultAuthFailure.error;
      lastAuthFailureDetail = '$e';
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
  ///
  /// Streams the file (1 MiB chunks) inside a background isolate — a
  /// multi-GB import no longer loads the whole file + ciphertext into
  /// memory on the UI isolate (optimization research P10). Output is
  /// byte-identical to the previous one-shot path (v1 format), so older
  /// app versions can still export files vaulted by this build.
  Future<String?> store(File source, {EntitlementTier? tier}) async {
    final effectiveTier = tier ?? EntitlementTier.free;
    if (!await canAccept(effectiveTier)) return null;
    if (!await authenticate(reason: 'Store file in private vault')) return null;
    if (await source.length() == 0) return null;

    final key = _sessionKey;
    if (key == null) return null;

    final dir = await vaultDir;
    final nonce = enc.IV.fromSecureRandom(12);
    final vaultName = '${DateTime.now().millisecondsSinceEpoch}.vault';
    final dest = File(p.join(dir.path, vaultName));
    final tmp = File('${dest.path}.tmp');
    try {
      // File objects cannot cross isolate boundaries — pass paths + key
      // material (all sendable) and reconstruct inside the isolate.
      final srcPath = source.path;
      final tmpPath = tmp.path;
      final keyBytes = key.bytes;
      final nonceBytes = nonce.bytes;
      await Isolate.run(() async {
        // v1: version | nonce(12) | ciphertext+tag
        final header = Uint8List.fromList([_kVaultFormatGcm, ...nonceBytes]);
        await encryptGcmStream(
          src: File(srcPath),
          dst: File(tmpPath),
          key: keyBytes,
          nonce: nonceBytes,
          header: header,
        );
      });
      // Atomic-ish: only a fully written blob becomes a vault entry.
      await tmp.rename(dest.path);
      return vaultName;
    } catch (e) {
      if (kDebugMode) debugPrint('[Vault] store failed: $e');
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      return null;
    }
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

    // v1 blobs stream-decrypt off the UI isolate (P10: a multi-GB vault
    // export no longer loads blob + plaintext into memory). The first byte
    // distinguishes v1 (0x01) from legacy CBC blobs.
    try {
      final firstByte = await src.openRead(0, 1).first;
      if (firstByte.isNotEmpty && firstByte[0] == _kVaultFormatGcm) {
        final nonceBytes = (await src.openRead(1, 13).expand((c) => c).toList())
            .cast<int>();
        if (nonceBytes.length != 12) return false;
        final dest = File(destination);
        await dest.parent.create(recursive: true);
        final tmp = File('${dest.path}.tmp');
        try {
          final srcPath = src.path;
          final tmpPath = tmp.path;
          final keyBytes = key.bytes;
          final nonceU8 = Uint8List.fromList(nonceBytes);
          await Isolate.run(() async {
            await decryptGcmStream(
              src: File(srcPath),
              dst: File(tmpPath),
              key: keyBytes,
              nonce: nonceU8,
              skipBytes: 13,
            );
          });
          await tmp.rename(dest.path);
          return true;
        } catch (e) {
          if (kDebugMode) debugPrint('[Vault] export decrypt failed: $e');
          try {
            if (await tmp.exists()) await tmp.delete();
          } catch (_) {}
          return false;
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[Vault] export open failed: $e');
      return false;
    }

    // Legacy CBC blob — rare, keep the one-shot path.
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
        final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc, padding: null));
        final decrypted =
            encrypter.decryptBytes(enc.Encrypted(ct), iv: iv);
        final raw = Uint8List.fromList(decrypted);
        return _unpadPkcs7(raw);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[Vault] decrypt failed: $e');
    }
    return null;
  }

  /// Strips PKCS#7 padding from [bytes] decrypted with CBC mode.
  ///
  /// Returns `null` if the padding bytes are invalid or inconsistent.
  static Uint8List? _unpadPkcs7(Uint8List bytes) {
    if (bytes.isEmpty) return null;
    final pad = bytes.last;
    if (pad < 1 || pad > 16 || pad > bytes.length) return null;
    for (var i = bytes.length - pad; i < bytes.length; i++) {
      if (bytes[i] != pad) return null;
    }
    return Uint8List.sublistView(bytes, 0, bytes.length - pad);
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
    lastAuthFailure = null;
    lastAuthFailureDetail = null;
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

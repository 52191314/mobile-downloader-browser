/// P7 Private Vault service scaffold.
///
/// Gated behind [ProFeature.privateVault]. Free users get ≤25 items inventory
/// cap (filesystem-based, checked via [Phase2Caps.vaultInventoryOk]).
///
/// ## Security model
/// - Files stored in app-private directory (`getApplicationSupportDirectory()/vault/`)
/// - `.nomedia` file to hide from media scanners
/// - AES-128-CBC encryption via `package:encrypt` (already in deps)
/// - AES key stored in Android Keystore via platform channel or
///   `flutter_secure_storage` (backed by Keystore on Android)
/// - Biometric unlock via `local_auth` before key use
/// - Recovery key shown once before first lock; no Aurora escrow
/// - `FLAG_SECURE` on vault UI to block screenshots
///
/// ## Implementation order (TODO):
/// 1. Add `flutter_secure_storage` dependency (or use platform channel).
/// 2. Create vault directory + .nomedia on first access.
/// 3. Implement key generation + Keystore storage.
/// 4. Implement biometric gate via local_auth.
/// 5. Implement encrypt/decrypt wrappers.
/// 6. Build vault UI screen.
/// 7. Wire "Move to Vault" action on completed downloads.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'pro_features.dart';

/// Static entry point for vault operations.
///
/// Typical call site:
/// ```
/// final vault = VaultService();
/// final files = await vault.listFiles();
/// if (!Phase2Caps.vaultInventoryOk(files.length, tier)) {
///   // show "Vault full" message + upsell
///   return;
/// }
/// await vault.store(originalFile);
/// ```
class VaultService {
  Directory? _vaultDir;

  /// Returns (and lazily creates) the vault directory with .nomedia.
  Future<Directory> get vaultDir async {
    if (_vaultDir != null) return _vaultDir!;
    final appDir = await getApplicationSupportDirectory();
    final dir = Directory('${appDir.path}/vault');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
      // Create .nomedia to hide from media scanners.
      final nomedia = File('${dir.path}/.nomedia');
      if (!await nomedia.exists()) {
        await nomedia.create();
      }
    }
    _vaultDir = dir;
    return dir;
  }

  /// Lists all files currently in the vault.
  /// TODO(P7): decrypt filenames and verify AES headers.
  Future<List<FileSystemEntity>> listFiles() async {
    final dir = await vaultDir;
    return dir.list().toList();
  }

  /// Moves [source] into the vault with AES encryption.
  /// TODO(P7): implement AES encrypt + Keystore key management + biometric
  /// gate before key use.
  Future<void> store(File source) async {
    final dir = await vaultDir;
    final dest = File('${dir.path}/${source.uri.pathSegments.last}');
    debugPrint('[Vault] TODO: encrypt ${source.path} → ${dest.path}');
    await source.copy(dest.path);
  }

  /// Exports a vault file to [destination] (decrypts then copies).
  /// TODO(P7): implement AES decrypt + biometric gate.
  Future<void> export(String vaultFileName, String destination) async {
    debugPrint('[Vault] TODO: decrypt $vaultFileName → $destination');
    final dir = await vaultDir;
    final src = File('${dir.path}/$vaultFileName');
    await src.copy(destination);
  }
}

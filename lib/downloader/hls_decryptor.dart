import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as encrypt;

class HlsDecryptor {
  /// Decrypts an AES-128-CBC encrypted HLS segment [file] in place.
  ///
  /// Heavy AES work runs on a background isolate so the UI isolate stays
  /// responsive during multi-segment downloads.
  static Future<void> decryptInPlace(
    File file,
    Uint8List key,
    Uint8List iv,
  ) async {
    // Isolate.run requires transferable args; pass path + key/iv copies.
    await Isolate.run(() => _decryptInPlaceImpl(file.path, key, iv));
  }

  /// Same as [decryptInPlace] but stays on the current isolate.
  /// Prefer [decryptInPlace] from UI/download orchestration code.
  static Future<void> decryptInPlaceSync(
    File file,
    Uint8List key,
    Uint8List iv,
  ) =>
      _decryptInPlaceImpl(file.path, key, iv);

  static Future<void> _decryptInPlaceImpl(
    String path,
    Uint8List key,
    Uint8List iv,
  ) async {
    final file = File(path);
    final tempFile = File('$path.dec');
    final output = tempFile.openWrite();
    var currentIv = Uint8List.fromList(iv);
    var pending = Uint8List(0);

    // Reuse one AES key schedule per key for the whole segment stream.
    // Creating Encrypter/AES per chunk forces PointyCastle to re-expand the
    // same key on every iteration (GC + CPU waste).
    final encrypterNoPad = encrypt.Encrypter(
      encrypt.AES(
        encrypt.Key(key),
        mode: encrypt.AESMode.cbc,
        padding: null,
      ),
    );
    final encrypterPkcs7 = encrypt.Encrypter(
      encrypt.AES(
        encrypt.Key(key),
        mode: encrypt.AESMode.cbc,
        padding: 'PKCS7',
      ),
    );

    try {
      await for (final chunk in file.openRead()) {
        final combined = Uint8List(pending.length + chunk.length)
          ..setRange(0, pending.length, pending)
          ..setRange(pending.length, pending.length + chunk.length, chunk);
        if (combined.length < 32) {
          pending = combined;
          continue;
        }

        // Keep the final encrypted block pending so PKCS7 padding is only
        // stripped after EOF. CBC IV chaining is advanced with ciphertext.
        final decryptLength = ((combined.length - 16) ~/ 16) * 16;
        final encryptedBlocks = Uint8List.sublistView(
          combined,
          0,
          decryptLength,
        );
        final decrypted = _decryptWith(
          encrypterNoPad,
          encryptedBlocks,
          currentIv,
        );
        output.add(decrypted);
        currentIv = Uint8List.sublistView(
          encryptedBlocks,
          encryptedBlocks.length - 16,
        );
        pending = Uint8List.sublistView(combined, decryptLength);
      }

      if (pending.isEmpty || pending.length % 16 != 0) {
        throw StateError(
          'Encrypted HLS segment length must be a multiple of 16 bytes.',
        );
      }

      final finalBlock = _decryptFinalBlock(
        encrypterPkcs7,
        encrypterNoPad,
        pending,
        currentIv,
      );
      output.add(finalBlock);
      await output.close();
      await file.delete();
      await tempFile.rename(path);
    } catch (_) {
      await output.close();
      if (await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }

  static Uint8List _decryptFinalBlock(
    encrypt.Encrypter withPadding,
    encrypt.Encrypter withoutPadding,
    Uint8List encrypted,
    Uint8List iv,
  ) {
    try {
      return _decryptWith(withPadding, encrypted, iv);
    } catch (_) {
      // Some streams don't use PKCS7 padding; retry without padding.
      return _decryptWith(withoutPadding, encrypted, iv);
    }
  }

  static Uint8List _decryptWith(
    encrypt.Encrypter encrypter,
    Uint8List encrypted,
    Uint8List iv,
  ) {
    return Uint8List.fromList(
      encrypter.decryptBytes(encrypt.Encrypted(encrypted), iv: encrypt.IV(iv)),
    );
  }
}

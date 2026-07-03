import 'dart:io';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as encrypt;

class HlsDecryptor {
  static Future<void> decryptInPlace(
    File file,
    Uint8List key,
    Uint8List iv,
  ) async {
    final tempFile = File('${file.path}.dec');
    final output = tempFile.openWrite();
    var currentIv = Uint8List.fromList(iv);
    var pending = Uint8List(0);

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
        final decrypted = _decryptAes128CbcChunk(
          encryptedBlocks,
          key,
          currentIv,
          hasPadding: false,
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

      final finalBlock = _decryptAes128Cbc(pending, key, currentIv);
      output.add(finalBlock);
      await output.close();
      await file.delete();
      await tempFile.rename(file.path);
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

  static Uint8List _decryptAes128Cbc(
    Uint8List encrypted,
    Uint8List key,
    Uint8List iv,
  ) {
    try {
      return _decryptAes128CbcChunk(encrypted, key, iv, hasPadding: true);
    } catch (_) {
      // Some streams don't use PKCS7 padding; retry without padding.
      return _decryptAes128CbcChunk(encrypted, key, iv, hasPadding: false);
    }
  }

  static Uint8List _decryptAes128CbcChunk(
    Uint8List encrypted,
    Uint8List key,
    Uint8List iv, {
    required bool hasPadding,
  }) {
    final encrypter = encrypt.Encrypter(
      encrypt.AES(
        encrypt.Key(key),
        mode: encrypt.AESMode.cbc,
        padding: hasPadding ? 'PKCS7' : null,
      ),
    );
    return Uint8List.fromList(
      encrypter.decryptBytes(encrypt.Encrypted(encrypted), iv: encrypt.IV(iv)),
    );
  }
}

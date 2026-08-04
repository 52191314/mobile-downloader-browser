import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';

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

    // ONE raw CBC cipher for the whole segment stream. The AES key schedule
    // is expanded exactly once (on init) and the internal CBC chaining state
    // (the previous ciphertext block) carries across processBlock calls, so
    // subsequent chunks never re-init the cipher or re-expand the key. The
    // decrypted output reuses a single scratch buffer instead of allocating a
    // fresh Uint8List per 64 KB chunk.
    final cipher = CBCBlockCipher(AESEngine())
      ..init(false, ParametersWithIV(KeyParameter(key), iv));
    var pending = Uint8List(0); // held-back tail (< 2 blocks) between chunks
    var combined = Uint8List(0); // reusable scratch: pending + current chunk
    var outBuffer = Uint8List(0); // reusable decrypted-output scratch

    try {
      await for (final chunk in file.openRead()) {
        final totalLength = pending.length + chunk.length;
        if (totalLength < 32) {
          // Too small to safely hold back a block; accumulate the whole run.
          final next = Uint8List(totalLength)
            ..setRange(0, pending.length, pending)
            ..setRange(pending.length, totalLength, chunk);
          pending = next;
          continue;
        }

        if (combined.length < totalLength) {
          combined = Uint8List(totalLength);
        }
        combined
          ..setRange(0, pending.length, pending)
          ..setRange(pending.length, totalLength, chunk);

        // Keep the final encrypted block pending so PKCS7 padding is only
        // stripped after EOF. CBC IV chaining is advanced with ciphertext and
        // tracked internally by [cipher] (no manual currentIv bookkeeping).
        final decryptLength = ((totalLength - 16) ~/ 16) * 16;
        if (outBuffer.length < decryptLength) {
          outBuffer = Uint8List(decryptLength);
        }
        _decryptBlocks(cipher, combined, 0, decryptLength, outBuffer);
        output.add(Uint8List.sublistView(outBuffer, 0, decryptLength));
        // Copy (not view) the tail: `combined` is reused next iteration.
        pending = Uint8List.fromList(
          Uint8List.sublistView(combined, decryptLength, totalLength),
        );
      }

      if (pending.isEmpty || pending.length % 16 != 0) {
        throw StateError(
          'Encrypted HLS segment length must be a multiple of 16 bytes.',
        );
      }

      if (outBuffer.length < pending.length) {
        outBuffer = Uint8List(pending.length);
      }
      _decryptBlocks(cipher, pending, 0, pending.length, outBuffer);
      final plainLength = _stripPkcs7(outBuffer, pending.length);
      output.add(Uint8List.sublistView(outBuffer, 0, plainLength));
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

  /// Decrypts [length] bytes of [input] starting at [start] into [output].
  /// [length] is always a multiple of the 16-byte AES block size. CBC chaining
  /// state lives inside [cipher], so successive calls continue the chain
  /// across chunk boundaries.
  static void _decryptBlocks(
    CBCBlockCipher cipher,
    Uint8List input,
    int start,
    int length,
    Uint8List output,
  ) {
    for (var off = 0; off < length; off += 16) {
      cipher.processBlock(input, start + off, output, off);
    }
  }

  /// Strips PKCS7 padding from the last block of a decrypted run, falling back
  /// to treating the last block as unpadded (raw CBC) when the padding bytes
  /// are invalid — the same try-padded-then-retry-no-pad behavior as the
  /// previous two-encrypter implementation. Returns the plaintext length.
  static int _stripPkcs7(Uint8List decrypted, int length) {
    final pad = decrypted[length - 1];
    if (pad >= 1 && pad <= 16) {
      var valid = true;
      for (var i = 1; i <= pad; i++) {
        if (decrypted[length - i] != pad) {
          valid = false;
          break;
        }
      }
      if (valid) return length - pad;
    }
    return length;
  }
}

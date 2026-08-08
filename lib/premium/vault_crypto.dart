/// Streaming AES-256-GCM helpers for vault blobs (optimization P10).
///
/// Produces and consumes the exact same ciphertext layout as the previous
/// one-shot `package:encrypt` path — `ciphertext || 16-byte tag`, same
/// AEAD parameters (empty AAD, 128-bit tag, 12-byte nonce) — so files
/// written by either path decrypt with the other. Memory stays O(chunk)
/// instead of O(file): a multi-GB vault import/export no longer spikes
/// multi-GB RSS on the UI isolate. The callers run these inside
/// `Isolate.run` (this module takes file paths + key bytes, all of which
/// are sendable across isolates).
///
/// Implementation notes (pointycastle 3.9.1 `GCMBlockCipher`, which is a
/// BC-style streaming AEAD):
/// - Feed arbitrary-length chunks via `processBytes`; it buffers partial
///   blocks internally and (on decrypt) holds back the trailing 16 tag
///   bytes until `doFinal`.
/// - `doFinal` must be called exactly once at the end: on encrypt it emits
///   the buffered partial block plus the tag; on decrypt it emits the
///   partial plaintext block and validates the tag (throws
///   `InvalidCipherTextException` on mismatch).
/// - AAD must be an empty (non-null) list, matching package:encrypt.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// AES-GCM tag size in bytes — must match the vault blob formats.
const int kVaultGcmTagBytes = 16;

/// Read/write chunk size (1 MiB). Multiple of the 16-byte AES block size.
const int kVaultStreamChunkBytes = 1 << 20;

/// Encrypts [src] into [dst] as `[header] ciphertext || tag`.
///
/// [key] must be 32 bytes (AES-256), [nonce] 12 bytes. [header] is written
/// verbatim before the ciphertext (e.g. the vault version byte or the
/// sync salt+nonce). Throws on I/O errors; the caller is responsible for
/// cleaning up a partially written [dst].
Future<void> encryptGcmStream({
  required File src,
  required File dst,
  required Uint8List key,
  required Uint8List nonce,
  Uint8List? header,
  int chunkBytes = kVaultStreamChunkBytes,
}) async {
  final cipher = GCMBlockCipher(AESEngine())
    ..init(true, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
  final sink = dst.openWrite();
  try {
    if (header != null && header.isNotEmpty) {
      sink.add(header);
    }
    await for (final chunk in src.openRead()) {
      if (chunk.isEmpty) continue;
      final data = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      final out = Uint8List(data.length + kVaultGcmTagBytes);
      final n = cipher.processBytes(data, 0, data.length, out, 0);
      if (n > 0) sink.add(Uint8List.sublistView(out, 0, n));
    }
    // doFinal: buffered partial block + tag (encrypt side).
    final tail = Uint8List(kVaultGcmTagBytes * 2);
    final n = cipher.doFinal(tail, 0);
    if (n > 0) sink.add(Uint8List.sublistView(tail, 0, n));
  } finally {
    await sink.close();
  }
}

/// Decrypts `[header] ciphertext || tag` from [src] into [dst].
///
/// [skipBytes] must equal the header length (e.g. 1 + 12 for vault v1).
/// Throws [InvalidCipherTextException] when the GCM tag does not match
/// (tampered/corrupt blob or wrong key/nonce).
Future<void> decryptGcmStream({
  required File src,
  required File dst,
  required Uint8List key,
  required Uint8List nonce,
  int skipBytes = 0,
  int chunkBytes = kVaultStreamChunkBytes,
}) async {
  final cipher = GCMBlockCipher(AESEngine())
    ..init(false, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
  final sink = dst.openWrite();
  try {
    await for (final chunk in src.openRead(skipBytes)) {
      if (chunk.isEmpty) continue;
      final data = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      final out = Uint8List(data.length + kVaultGcmTagBytes);
      final n = cipher.processBytes(data, 0, data.length, out, 0);
      if (n > 0) sink.add(Uint8List.sublistView(out, 0, n));
    }
    // doFinal: buffered partial block; validates the held-back tag.
    final tail = Uint8List(kVaultGcmTagBytes * 2);
    final n = cipher.doFinal(tail, 0);
    if (n > 0) sink.add(Uint8List.sublistView(tail, 0, n));
  } finally {
    await sink.close();
  }
}

// ---------------------------------------------------------------------------
// Chunked base64 (the sync path streams blobs into HTTP bodies and reads
// them back; dart:convert's base64 is one-shot only, so we keep 3-byte /
// 4-char group state ourselves).
// ---------------------------------------------------------------------------

/// Stateful base64 encoder for chunked input. Feed arbitrary byte chunks
/// with [add], then call [close] for the final padded output.
class ChunkedBase64Encoder {
  final BytesBuilder _pending = BytesBuilder();
  final List<String> _out = [];

  /// Encodes [chunk], returning any complete base64 groups (may be '').
  String add(List<int> chunk) {
    _pending.add(chunk);
    final bytes = _pending.takeBytes();
    final complete = bytes.length - (bytes.length % 3);
    if (complete == 0) {
      _pending.add(bytes);
      return '';
    }
    final head = Uint8List.sublistView(bytes, 0, complete);
    _pending.add(Uint8List.sublistView(bytes, complete));
    return base64.encode(head);
  }

  /// Flushes the remainder with padding. Must be called exactly once.
  String close() {
    final rest = _pending.takeBytes();
    _out.add(base64.encode(rest));
    return _out.join();
  }
}

/// Stateful base64 decoder for chunked input. Feed base64 text chunks with
/// [add] (whitespace tolerated), then call [close] for the final bytes.
class ChunkedBase64Decoder {
  final BytesBuilder _pending = BytesBuilder();

  /// Decodes [chunk], returning the newly decoded bytes (may be empty).
  Uint8List add(String chunk) {
    _pending.add(utf8.encode(chunk.replaceAll(RegExp(r'\s'), '')));
    final s = String.fromCharCodes(_pending.takeBytes());
    final complete = s.length - (s.length % 4);
    if (complete == 0) {
      _pending.add(utf8.encode(s));
      return Uint8List(0);
    }
    final head = s.substring(0, complete);
    _pending.add(utf8.encode(s.substring(complete)));
    return base64.decode(head);
  }

  /// Flushes the final group (which may carry padding). Must be called
  /// exactly once after the last [add]; returns only the remainder.
  Uint8List close() {
    final rest = String.fromCharCodes(_pending.takeBytes());
    if (rest.isEmpty) return Uint8List(0);
    return base64.decode(rest);
  }
}

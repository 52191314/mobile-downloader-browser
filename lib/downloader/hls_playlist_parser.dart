import 'dart:typed_data';

import 'hls_models.dart';

class HlsPlaylistParser {
  static HlsPlaylist parse(String body, Uri playlistUri) {
    final lines = body
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (lines.isEmpty || !lines.first.startsWith('#EXTM3U')) {
      throw FormatException('This is not a valid HLS playlist.');
    }

    final variants = <HlsVariant>[];
    final segments = <HlsSegment>[];
    var hasEncryption = false;
    var hasFmp4 = false;
    Uri? initSegmentUri;
    HlsEncryptionKey? encryptionKey;
    var mediaSequence = 0;
    double? pendingDuration;
    int? pendingBandwidth;
    String? pendingResolution;
    int? pendingByteRangeLength;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.startsWith('#EXT-X-KEY')) {
        final method = _attribute(line, 'METHOD')?.toUpperCase() ?? '';
        if (method == 'NONE') {
          encryptionKey = null;
        } else {
          final keyUriStr = _attribute(line, 'URI');
          if (keyUriStr != null) {
            final keyUri = _inheritPlaylistQuery(
              playlistUri,
              playlistUri.resolve(keyUriStr),
            );
            final ivHex = _attribute(line, 'IV');
            Uint8List? iv;
            if (ivHex != null) {
              final hex = ivHex.toLowerCase().startsWith('0x')
                  ? ivHex.substring(2)
                  : ivHex;
              iv = _hexToBytes(hex);
              if (iv.length != 16) {
                throw FormatException(
                  'AES-128 IV must be 16 bytes, got ${iv.length}',
                );
              }
            }
            encryptionKey = HlsEncryptionKey(
              method: method,
              uri: keyUri,
              iv: iv,
            );
          }
        }
        hasEncryption = encryptionKey != null;
        continue;
      }
      if (line.startsWith('#EXT-X-MEDIA-SEQUENCE')) {
        final prefixLen = '#EXT-X-MEDIA-SEQUENCE:'.length;
        mediaSequence = line.length >= prefixLen
            ? (int.tryParse(line.substring(prefixLen).trim()) ?? 0)
            : 0;
        continue;
      }
      if (line.startsWith('#EXT-X-MAP')) {
        hasFmp4 = true;
        final mapUriStr = _attribute(line, 'URI');
        if (mapUriStr != null) {
          initSegmentUri = _inheritPlaylistQuery(
            playlistUri,
            playlistUri.resolve(mapUriStr),
          );
        }
        continue;
      }
      if (line.startsWith('#EXT-X-STREAM-INF')) {
        pendingBandwidth = int.tryParse(_attribute(line, 'BANDWIDTH') ?? '');
        pendingResolution = _attribute(line, 'RESOLUTION');
        continue;
      }
      if (line.startsWith('#EXTINF')) {
        final prefixLen = '#EXTINF:'.length;
        if (line.length >= prefixLen) {
          final value = line.substring(prefixLen).split(',').first.trim();
          pendingDuration = double.tryParse(value) ?? 0;
        } else {
          pendingDuration = 0;
        }
        continue;
      }
      if (line.startsWith('#EXT-X-BYTERANGE')) {
        final prefixLen = '#EXT-X-BYTERANGE:'.length;
        if (line.length >= prefixLen) {
          final val = line.substring(prefixLen).trim();
          final lenStr = val.split('@').first;
          pendingByteRangeLength = int.tryParse(lenStr);
        }
        continue;
      }
      if (line.startsWith('#')) continue;

      var resolved = _inheritPlaylistQuery(
        playlistUri,
        playlistUri.resolve(line),
      );
      final path = resolved.path.toLowerCase();
      if (path.endsWith('.m4s') || path.endsWith('.mp4')) {
        hasFmp4 = true;
      }
      if (pendingBandwidth != null) {
        variants.add(
          HlsVariant(
            uri: resolved,
            bandwidth: pendingBandwidth,
            resolution: pendingResolution,
          ),
        );
        pendingBandwidth = null;
        pendingResolution = null;
      } else {
        segments.add(
          HlsSegment(
            uri: resolved,
            durationSeconds: pendingDuration ?? 0,
            byteRangeLength: pendingByteRangeLength,
          ),
        );
        pendingByteRangeLength = null;
      }
      pendingDuration = null;
    }

    final isLive = !body.contains('#EXT-X-ENDLIST');

    return HlsPlaylist(
      uri: playlistUri,
      variants: variants,
      segments: segments,
      hasEncryption: hasEncryption,
      hasFmp4: hasFmp4,
      initSegmentUri: initSegmentUri,
      encryptionKey: encryptionKey,
      mediaSequence: mediaSequence,
      isLive: isLive,
    );
  }

  static Uint8List _hexToBytes(String hex) {
    final clean = hex.replaceAll(' ', '').toLowerCase();
    if (clean.length % 2 != 0) {
      throw FormatException('Invalid hex string length: ${clean.length}');
    }
    final bytes = Uint8List(clean.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  /// Inherit the playlist's signed query only if the resolved URL does not
  /// already carry its own query. Appending the playlist query to a URL that
  /// already has one creates duplicate auth tokens and causes 403s.
  static Uri _inheritPlaylistQuery(Uri playlistUri, Uri resolved) {
    if (!playlistUri.hasQuery) return resolved;
    final originalQuery = playlistUri.query;
    if (originalQuery.isEmpty || resolved.hasQuery) return resolved;
    return resolved.replace(query: originalQuery);
  }

  static String? _attribute(String line, String name) {
    final match = RegExp(
      '$name=("([^"]+)"|[^,]+)',
      caseSensitive: false,
    ).firstMatch(line);
    if (match == null) return null;
    return (match.group(2) ?? match.group(1) ?? '').replaceAll('"', '').trim();
  }
}

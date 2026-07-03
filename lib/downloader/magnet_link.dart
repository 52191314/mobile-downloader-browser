import 'dart:typed_data';

class MagnetLink {
  final String infoHash;
  final String? displayName;
  final List<String> trackers;
  final List<String> webSeeds;

  MagnetLink({
    required this.infoHash,
    this.displayName,
    this.trackers = const [],
    this.webSeeds = const [],
  });

  factory MagnetLink.parse(String uriString) {
    uriString = uriString.trim();
    while (uriString.startsWith('"') || uriString.startsWith("'") || uriString.startsWith('`')) {
      uriString = uriString.substring(1);
    }
    while (uriString.endsWith('"') || uriString.endsWith("'") || uriString.endsWith('`')) {
      uriString = uriString.substring(0, uriString.length - 1);
    }
    uriString = uriString.trim();
    uriString = uriString.replaceAll(' ', '%20');

    final uri = Uri.parse(uriString);
    if (uri.scheme != 'magnet') {
      throw FormatException('Scheme must be magnet');
    }
    final params = uri.queryParametersAll;
    final xtList = params['xt'];
    if (xtList == null || xtList.isEmpty) {
      throw FormatException('Missing xt parameter');
    }

    String? xt;
    for (final x in xtList) {
      if (x.startsWith('urn:btih:')) {
        xt = x;
        break;
      }
    }
    if (xt == null) {
      throw FormatException('Missing xt parameter with urn:btih: prefix');
    }

    final hashPart = xt.substring('urn:btih:'.length);
    final normalizedHash = _validateAndNormalizeHash(hashPart);

    final dnList = params['dn'];
    final dn = (dnList != null && dnList.isNotEmpty) ? dnList.first : null;
    final tr = params['tr'] ?? const [];
    final ws = params['ws'] ?? const [];

    return MagnetLink(
      infoHash: normalizedHash,
      displayName: dn,
      trackers: tr,
      webSeeds: ws,
    );
  }

  static String _validateAndNormalizeHash(String hash) {
    if (hash.length == 40) {
      final hexRegExp = RegExp(r'^[0-9a-fA-F]{40}$');
      if (!hexRegExp.hasMatch(hash)) {
        throw FormatException('Invalid hex info-hash format');
      }
      return hash.toLowerCase();
    } else if (hash.length == 32) {
      try {
        final bytes = _decodeBase32(hash);
        if (bytes.length != 20) {
          throw FormatException('Decoded base32 hash must be 20 bytes');
        }
        return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      } catch (e) {
        throw FormatException('Invalid Base32 info-hash format: $e');
      }
    } else {
      throw FormatException(
        'Invalid info-hash length: must be 40 (hex) or 32 (base32) characters',
      );
    }
  }

  static Uint8List _decodeBase32(String input) {
    final cleanInput = input.toUpperCase().replaceAll('=', '');
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    var bits = 0;
    var value = 0;
    final bytes = <int>[];

    for (var i = 0; i < cleanInput.length; i++) {
      final char = cleanInput[i];
      final idx = alphabet.indexOf(char);
      if (idx == -1) {
        throw FormatException('Invalid Base32 character: $char');
      }
      value = (value << 5) | idx;
      bits += 5;
      if (bits >= 8) {
        bytes.add((value >> (bits - 8)) & 0xFF);
        bits -= 8;
      }
    }
    return Uint8List.fromList(bytes);
  }
}

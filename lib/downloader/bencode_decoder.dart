import 'dart:convert';
import 'dart:typed_data';

class BencodeDecoder {
  final Uint8List _bytes;
  int _pos = 0;

  BencodeDecoder(this._bytes);

  static dynamic decode(Uint8List bytes) {
    final decoder = BencodeDecoder(bytes);
    final result = decoder._parseAny();
    if (decoder._pos < bytes.length) {
      throw FormatException('Trailing garbage at index ${decoder._pos}');
    }
    return result;
  }

  dynamic _parseAny() {
    if (_pos >= _bytes.length) {
      throw FormatException('Unexpected EOF');
    }
    final char = _bytes[_pos];
    if (char == 105) {
      // 'i'
      return _parseInt();
    } else if (char == 108) {
      // 'l'
      return _parseList();
    } else if (char == 100) {
      // 'd'
      return _parseDict();
    } else if (char >= 48 && char <= 57) {
      // '0'-'9'
      return _parseByteString();
    } else {
      throw FormatException(
        'Invalid bencode type prefix at index $_pos: ${String.fromCharCode(char)}',
      );
    }
  }

  int _parseInt() {
    _pos++; // skip 'i'
    final start = _pos;
    while (_pos < _bytes.length && _bytes[_pos] != 101) {
      // 'e'
      _pos++;
    }
    if (_pos >= _bytes.length) {
      throw FormatException('Unterminated integer');
    }
    final end = _pos;
    _pos++; // skip 'e'

    final numStr = utf8.decode(_bytes.sublist(start, end));
    if (numStr.isEmpty) {
      throw FormatException('Empty integer representation');
    }

    if (numStr == '-0') {
      throw FormatException('Negative zero is not allowed');
    }
    if (numStr.length > 1) {
      if (numStr.startsWith('0')) {
        throw FormatException('Leading zero is not allowed');
      }
      if (numStr.startsWith('-') && numStr.substring(1).startsWith('0')) {
        throw FormatException(
          'Leading zero after negative sign is not allowed',
        );
      }
    }

    final parsed = int.tryParse(numStr);
    if (parsed == null) {
      throw FormatException('Invalid integer format: $numStr');
    }
    return parsed;
  }

  Uint8List _parseByteString() {
    var len = 0;
    while (_pos < _bytes.length && _bytes[_pos] != 58) {
      // ':'
      final char = _bytes[_pos];
      if (char < 48 || char > 57) {
        throw FormatException('Invalid character in string length at $_pos');
      }
      len = len * 10 + (char - 48);
      _pos++;
    }
    if (_pos >= _bytes.length) {
      throw FormatException('Unterminated string length');
    }
    _pos++; // skip ':'

    if (_pos + len > _bytes.length) {
      throw FormatException('String data length $len exceeds remaining bytes');
    }
    final data = _bytes.sublist(_pos, _pos + len);
    _pos += len;
    return data;
  }

  List<dynamic> _parseList() {
    _pos++; // skip 'l'
    final list = <dynamic>[];
    while (_pos < _bytes.length && _bytes[_pos] != 101) {
      // 'e'
      list.add(_parseAny());
    }
    if (_pos >= _bytes.length) {
      throw FormatException('Unterminated list');
    }
    _pos++; // skip 'e'
    return list;
  }

  Map<String, dynamic> _parseDict() {
    _pos++; // skip 'd'
    final dict = <String, dynamic>{};
    while (_pos < _bytes.length && _bytes[_pos] != 101) {
      // 'e'
      if (_bytes[_pos] < 48 || _bytes[_pos] > 57) {
        throw FormatException('Dictionary key must be a byte string');
      }
      final keyBytes = _parseByteString();
      final key = utf8.decode(keyBytes);

      final valStart = _pos;
      final value = _parseAny();
      final valEnd = _pos;

      if (key == 'info') {
        final rawInfoBytes = _bytes.sublist(valStart, valEnd);
        dict['_raw_info_bytes'] = rawInfoBytes;
      }

      dict[key] = value;
    }
    if (_pos >= _bytes.length) {
      throw FormatException('Unterminated dictionary');
    }
    _pos++; // skip 'e'
    return dict;
  }
}

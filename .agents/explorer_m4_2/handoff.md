# Torrent and Magnet Link Pure Dart Parsing Design

This report details how to parse Magnet links and `.torrent` files in pure Dart without external dependencies, and designs a P2P download engine simulator that maps download state transitions, handles rarest-first piece selection, and manages pause/resume/cancellation.

---

## 1. Observation

During our codebase inspection, we observed:
* **`lib/downloader/models.dart`** defines the basic models for downloader operations:
  * Line 1: `enum DownloadState` consisting of `idle`, `downloading`, `paused`, `completed`, `failed`.
  * Line 55: `class DownloadTask` containing:
    ```dart
    final String id;
    final String url;
    final String savePath;
    final String tempDir;
    final String? expectedHash;
    final Map<String, String>? headers;
    DownloadPriority priority;
    DownloadState state;
    int totalBytes;
    int downloadedBytes;
    double speed; // In bytes/second
    ...
    ```
* **`lib/downloader/download_queue.dart`** manages execution, scheduling, concurrency limits (`maxConcurrentDownloads`), and tasks updates (`onTaskUpdated`).

We did not find any existing torrent or magnet parsing implementations in the project root, meaning this is a greenfield implementation.

---

## 2. Logic Chain

Based on our observations of the current codebase and project structures, we deduced the following:
1. **Integration with `DownloadTask`**: The torrent engine must update the existing fields on `DownloadTask` (such as `state`, `downloadedBytes`, `totalBytes`, `speed`) to ensure compatibility with `DownloadQueue` and UI listeners.
2. **Binary Safety in Bencode Parsing**: `.torrent` files contain binary byte arrays (specifically the `pieces` field, which contains concatenated 20-byte SHA-1 hashes). Standard Dart `String` parsing or UTF-8 decoding of the whole file will corrupt these binary bytes. Hence, the Bencode decoder must operate strictly on byte arrays (`Uint8List` or `List<int>`).
3. **Info Hash Extraction**: The BitTorrent info hash is the SHA-1 hash of the raw bencoded `info` dictionary. Because formatting changes during decoding and re-encoding can alter the computed hash, the bencode parser must record the precise start and end byte offsets of the `info` dictionary value *during the parsing of the raw bytes*.
4. **P2P Torrent Engine Simulator**: To simulate a real download, the engine must simulate peers, pieces (and block divisions), and a periodic timer-based download loop that updates speed, supports pause/resume/cancellation, and validates hashes.

---

## 3. Pure Dart Magnet Link Parsing Design

A Magnet link is a URI starting with `magnet:?`. Its parameters are key-value pairs where keys can appear multiple times (particularly `tr` for trackers).

### Detailed Parsing Steps
1. Parse the string using `Uri.parse(magnetUri)`.
2. Extract the map of query parameters via `uri.queryParametersAll`.
3. Locate the `xt` (Exact Topic) parameters. BitTorrent uses `urn:btih:<hash>` (SHA-1) or `urn:btmh:<hash>` (SHA-256).
4. Normalize the info hash:
   * If it is a 40-character hex string, convert it to lowercase.
   * If it is a 32-character Base32 string (RFC 4648), decode it to a 20-byte array and convert it to a 40-character hex string.
5. Extract the `dn` (Display Name) parameter, which is automatically percent-decoded by Dart.
6. Extract the `tr` (Tracker) parameters, collecting all occurrences into a `List<String>`.

### Dart Code Implementation
```dart
class MagnetLink {
  final String infoHash;      // Lowercase hex string (40-char SHA-1 or 64-char SHA-256)
  final String? displayName;  // Decoded 'dn' parameter
  final List<String> trackers;// List of 'tr' trackers

  MagnetLink({
    required this.infoHash,
    this.displayName,
    required this.trackers,
  });

  factory MagnetLink.parse(String magnetUri) {
    if (!magnetUri.startsWith('magnet:?')) {
      throw FormatException('Invalid Magnet Link: must start with "magnet:?"');
    }

    final uri = Uri.parse(magnetUri);
    final params = uri.queryParametersAll;

    // Extract exact topic (xt)
    final xtList = params['xt'] ?? [];
    String? infoHash;
    for (final xt in xtList) {
      if (xt.startsWith('urn:btih:')) {
        final rawHash = xt.substring('urn:btih:'.length);
        infoHash = _normalizeInfoHash(rawHash);
        break; // Stop at first valid BitTorrent SHA-1 hash
      } else if (xt.startsWith('urn:btmh:')) {
        // BitTorrent v2 multihash (SHA-256)
        final rawHash = xt.substring('urn:btmh:'.length);
        infoHash = rawHash.toLowerCase();
        break;
      }
    }

    if (infoHash == null) {
      throw FormatException('Missing or invalid BitTorrent info hash (xt=urn:btih:...)');
    }

    // Extract display name (dn)
    final dn = (params['dn'] != null && params['dn']!.isNotEmpty)
        ? params['dn']!.first
        : null;

    // Extract trackers (tr)
    final trList = params['tr'] ?? [];

    return MagnetLink(
      infoHash: infoHash,
      displayName: dn,
      trackers: trList,
    );
  }

  static String _normalizeInfoHash(String hash) {
    final cleanHash = hash.trim();
    if (cleanHash.length == 40) {
      return cleanHash.toLowerCase();
    } else if (cleanHash.length == 32) {
      return _base32ToHex(cleanHash);
    } else {
      throw FormatException('Invalid BitTorrent info hash length: ${cleanHash.length}');
    }
  }

  static String _base32ToHex(String base32) {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
    final lower = base32.toLowerCase();
    
    var bits = 0;
    var value = 0;
    final bytes = <int>[];
    
    for (var i = 0; i < lower.length; i++) {
      final char = lower[i];
      if (char == '=') continue; // ignore padding
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
    
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
```

---

## 4. Pure Dart .torrent Bencode Decoder Design

Bencode has four basic structures: integers (`i<num>e`), byte strings (`<length>:<bytes>`), lists (`l<elements>e`), and dictionaries (`d<key><value>e`). 

### Core Decoders and Memory Boundary Tracking
To capture the info hash accurately, our parser records the index offsets of the `info` dictionary value as it parses the raw byte array.

```dart
import 'dart:convert';
import 'dart:typed_data';

class BencodeDecoder {
  final Uint8List _bytes;
  int _offset = 0;

  // Captured indices to carve out the raw info dictionary bytes for SHA-1 hashing
  int? infoStart;
  int? infoEnd;

  BencodeDecoder(this._bytes);

  dynamic decode() {
    _offset = 0;
    infoStart = null;
    infoEnd = null;
    return _parse();
  }

  dynamic _parse() {
    if (_offset >= _bytes.length) {
      throw FormatException('Unexpected EOF');
    }

    final char = _bytes[_offset];
    if (char == 105) { // 'i'
      return _parseInteger();
    } else if (char == 108) { // 'l'
      return _parseList();
    } else if (char == 100) { // 'd'
      return _parseDictionary();
    } else if (char >= 48 && char <= 57) { // '0'-'9'
      return _parseByteString();
    } else {
      throw FormatException('Invalid bencode character: ${String.fromCharCode(char)} at $_offset');
    }
  }

  int _parseInteger() {
    _offset++; // skip 'i'
    final end = _bytes.indexOf(101, _offset); // find 'e'
    if (end == -1) throw FormatException('Unterminated integer');
    final numStr = ascii.decode(_bytes.sublist(_offset, end));
    _offset = end + 1; // skip 'e'
    return int.parse(numStr);
  }

  Uint8List _parseByteString() {
    final colon = _bytes.indexOf(58, _offset); // find ':'
    if (colon == -1) throw FormatException('Missing colon in byte string');
    final lenStr = ascii.decode(_bytes.sublist(_offset, colon));
    final length = int.parse(lenStr);
    _offset = colon + 1;
    if (_offset + length > _bytes.length) {
      throw FormatException('Byte string length overflows buffer');
    }
    final result = Uint8List.sublistView(_bytes, _offset, _offset + length);
    _offset += length;
    return result;
  }

  List<dynamic> _parseList() {
    _offset++; // skip 'l'
    final list = <dynamic>[];
    while (_offset < _bytes.length && _bytes[_offset] != 101) { // 'e'
      list.add(_parse());
    }
    if (_offset >= _bytes.length) throw FormatException('Unterminated list');
    _offset++; // skip 'e'
    return list;
  }

  Map<String, dynamic> _parseDictionary() {
    _offset++; // skip 'd'
    final dict = <String, dynamic>{};
    while (_offset < _bytes.length && _bytes[_offset] != 101) { // 'e'
      final keyBytes = _parseByteString();
      final key = utf8.decode(keyBytes);

      final isInfoKey = (key == 'info');
      if (isInfoKey) infoStart = _offset;

      final value = _parse();

      if (isInfoKey) infoEnd = _offset;

      dict[key] = value;
    }
    if (_offset >= _bytes.length) throw FormatException('Unterminated dictionary');
    _offset++; // skip 'e'
    return dict;
  }
}
```

### Torrent Metadata Object Parser
This class wraps `BencodeDecoder` to build clean metadata containing piece hash arrays and handling single vs multi-file structures.

```dart
class TorrentFileEntry {
  final String path;
  final int length;

  TorrentFileEntry({required this.path, required this.length});
}

class TorrentMetadata {
  final String infoHash;
  final String name;
  final int pieceLength;
  final List<String> pieces; // List of hex-encoded 20-byte hashes
  final List<TorrentFileEntry> files;
  final int totalSize;

  TorrentMetadata({
    required this.infoHash,
    required this.name,
    required this.pieceLength,
    required this.pieces,
    required this.files,
    required this.totalSize,
  });

  factory TorrentMetadata.parse(Uint8List torrentBytes, {Uint8List Function(Uint8List)? sha1Hasher}) {
    final decoder = BencodeDecoder(torrentBytes);
    final decoded = decoder.decode();

    if (decoded is! Map<String, dynamic>) {
      throw FormatException('Invalid torrent: root is not a dictionary');
    }

    final info = decoded['info'];
    if (info is! Map<String, dynamic>) {
      throw FormatException('Invalid torrent: missing info dictionary');
    }

    if (decoder.infoStart == null || decoder.infoEnd == null) {
      throw FormatException('Failed to isolate info dictionary boundary');
    }

    // 1. Calculate Info Hash
    final infoBytes = Uint8List.sublistView(torrentBytes, decoder.infoStart!, decoder.infoEnd!);
    final infoHashBytes = sha1Hasher != null 
        ? sha1Hasher(infoBytes) 
        : _sha1Fallback(infoBytes);
    final infoHash = infoHashBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    // 2. Parse basic details
    final name = utf8.decode(info['name'] as Uint8List);
    final pieceLength = info['piece length'] as int;
    final rawPieces = info['pieces'] as Uint8List;

    if (rawPieces.length % 20 != 0) {
      throw FormatException('Pieces array length must be a multiple of 20');
    }

    final pieces = <String>[];
    for (var i = 0; i < rawPieces.length; i += 20) {
      final chunk = Uint8List.sublistView(rawPieces, i, i + 20);
      pieces.add(chunk.map((b) => b.toRadixString(16).padLeft(2, '0')).join());
    }

    // 3. Extract Files List
    final files = <TorrentFileEntry>[];
    var totalSize = 0;
    
    if (info.containsKey('length')) {
      // Single-file Torrent
      final len = info['length'] as int;
      files.add(TorrentFileEntry(path: name, length: len));
      totalSize = len;
    } else if (info.containsKey('files')) {
      // Multi-file Torrent
      final filesList = info['files'] as List<dynamic>;
      for (final f in filesList) {
        if (f is! Map<String, dynamic>) continue;
        final fLength = f['length'] as int;
        final fPathList = f['path'] as List<dynamic>;
        final pathString = fPathList.map((p) => utf8.decode(p as Uint8List)).join('/');
        files.add(TorrentFileEntry(path: pathString, length: fLength));
        totalSize += fLength;
      }
    } else {
      throw FormatException('Torrent info is missing length or files key');
    }

    return TorrentMetadata(
      infoHash: infoHash,
      name: name,
      pieceLength: pieceLength,
      pieces: pieces,
      files: files,
      totalSize: totalSize,
    );
  }

  // Fallback pure Dart SHA-1 implementation (detailed in Appendix)
  static Uint8List _sha1Fallback(Uint8List message) => sha1PureDart(message);
}
```

---

## 5. Torrent Engine Simulator Design (P2P Simulator)

A fully functional P2P torrent engine simulator requires managing peer connections, allocating piece and block requests, performing piece verification, tracking metrics, and processing lifecycle controls (Pause, Resume, Cancellation).

### Core Components
1. **Block-Level Pipeline**: In BitTorrent, pieces (e.g. 256 KB) are divided into 16 KB (16,384 bytes) blocks. Peers upload/download blocks to optimize TCP stream performance.
2. **Rarest-First Scheduling**: Rarity is calculated based on availability in the peer swarm. The engine downloads pieces with low availability first.
3. **Multi-File Disk Writer**: Outlines how a sequence of linear byte offsets maps to multiple files on disk, writing bytes to appropriate relative positions.

### Simulator Code Outline
```dart
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

enum SimEngineState { idle, downloading, paused, completed, cancelled }

class SimPeer {
  final String id;
  final double maxSpeedBytesPerSec;
  final List<bool> bitfield; // Pieces this peer has

  SimPeer({
    required this.id,
    required this.maxSpeedBytesPerSec,
    required this.bitfield,
  });
}

class BlockStatus {
  final int offset;
  final int size;
  bool isCompleted = false;

  BlockStatus({required this.offset, required this.size});
}

class PieceStatus {
  final int index;
  final int length;
  final String expectedHash;
  final List<BlockStatus> blocks;
  bool isVerified = false;

  PieceStatus({
    required this.index,
    required this.length,
    required this.expectedHash,
  }) : blocks = _divideIntoBlocks(length);

  static List<BlockStatus> _divideIntoBlocks(int pieceLength) {
    const blockSize = 16384; // 16 KB
    final list = <BlockStatus>[];
    for (var offset = 0; offset < pieceLength; offset += blockSize) {
      final size = min(blockSize, pieceLength - offset);
      list.add(BlockStatus(offset: offset, size: size));
    }
    return list;
  }

  bool get isDownloaded => blocks.every((b) => b.isCompleted);
  int get downloadedBytes => blocks.fold(0, (sum, b) => sum + (b.isCompleted ? b.size : 0));
}

class TorrentDownloadEngine {
  final TorrentMetadata metadata;
  final String savePath;

  SimEngineState _state = SimEngineState.idle;
  SimEngineState get state => _state;

  final List<PieceStatus> _pieces = [];
  final List<SimPeer> _peers = [];
  
  Timer? _loopTimer;
  DateTime? _lastTickTime;
  double _rollingSpeed = 0.0; // Bytes/sec

  final StreamController<TorrentDownloadEngine> _updateController =
      StreamController<TorrentDownloadEngine>.broadcast();
  Stream<TorrentDownloadEngine> get onUpdated => _updateController.stream;

  TorrentDownloadEngine({required this.metadata, required this.savePath}) {
    // 1. Initialize piece and block tracking
    for (var i = 0; i < metadata.pieces.length; i++) {
      final isLast = (i == metadata.pieces.length - 1);
      final pieceLen = isLast
          ? (metadata.totalSize - (metadata.pieceLength * i))
          : metadata.pieceLength;
      _pieces.add(PieceStatus(index: i, length: pieceLen, expectedHash: metadata.pieces[i]));
    }
    // 2. Initialize simulated peer swarm
    _initializeSwarm();
  }

  void _initializeSwarm() {
    final pieceCount = metadata.pieces.length;
    _peers.addAll([
      SimPeer(
        id: 'Peer-1-Seed',
        maxSpeedBytesPerSec: 300 * 1024, // 300 KB/s
        bitfield: List.generate(pieceCount, (_) => true), // Has all pieces
      ),
      SimPeer(
        id: 'Peer-2-Leecher',
        maxSpeedBytesPerSec: 150 * 1024, // 150 KB/s
        bitfield: List.generate(pieceCount, (i) => i % 2 == 0), // Has even pieces
      ),
      SimPeer(
        id: 'Peer-3-SlowSeed',
        maxSpeedBytesPerSec: 50 * 1024, // 50 KB/s
        bitfield: List.generate(pieceCount, (_) => true),
      ),
    ]);
  }

  int get downloadedBytes => _pieces.fold(0, (sum, p) => sum + p.downloadedBytes);
  double get progress => downloadedBytes / metadata.totalSize;
  double get speed => _rollingSpeed;

  void start() {
    if (_state == SimEngineState.downloading) return;
    _state = SimEngineState.downloading;
    _lastTickTime = DateTime.now();
    _loopTimer = Timer.periodic(const Duration(milliseconds: 1000), _tick);
    _updateController.add(this);
  }

  void pause() {
    if (_state != SimEngineState.downloading) return;
    _state = SimEngineState.paused;
    _loopTimer?.cancel();
    _rollingSpeed = 0.0;
    _updateController.add(this);
  }

  void resume() {
    if (_state != SimEngineState.paused) return;
    start();
  }

  void cancel() {
    _state = SimEngineState.cancelled;
    _loopTimer?.cancel();
    _rollingSpeed = 0.0;
    _updateController.add(this);
  }

  void _tick(Timer timer) {
    if (_state != SimEngineState.downloading) return;

    final now = DateTime.now();
    final elapsedSec = now.difference(_lastTickTime!).inMilliseconds / 1000.0;
    if (elapsedSec <= 0) return;
    _lastTickTime = now;

    // 1. Calculate rarity of pieces across the swarm to construct selection order (Rarest-first)
    final rarityMap = _calculatePieceRarity();
    final pendingPieces = _pieces.where((p) => !p.isVerified).toList();
    if (pendingPieces.isEmpty) {
      _finalizeCompletion();
      return;
    }

    // Sort pending pieces by rarity (lowest occurrence number = rarest)
    pendingPieces.sort((a, b) => (rarityMap[a.index] ?? 0).compareTo(rarityMap[b.index] ?? 0));

    var totalBytesTransferredThisTick = 0;

    // 2. Distribute download capacity from active peers
    for (final peer in _peers) {
      final peerQuota = (peer.maxSpeedBytesPerSec * elapsedSec).toInt();
      var quotaUsed = 0;

      // Request blocks from the peer
      for (final piece in pendingPieces) {
        if (!peer.bitfield[piece.index]) continue; // Peer doesn't have this piece
        if (quotaUsed >= peerQuota) break;

        for (final block in piece.blocks) {
          if (block.isCompleted) continue;

          final bytesToDownload = min(block.size, peerQuota - quotaUsed);
          quotaUsed += bytesToDownload;
          totalBytesTransferredThisTick += bytesToDownload;

          if (bytesToDownload == block.size) {
            block.isCompleted = true; // Block fully downloaded
          }

          if (quotaUsed >= peerQuota) break;
        }

        // Handle piece completion and simulated validation
        if (piece.isDownloaded && !piece.isVerified) {
          final success = _simulateVerification(piece);
          if (success) {
            piece.isVerified = true;
          } else {
            // Hash mismatch, reset all blocks for redownload
            for (final b in piece.blocks) {
              b.isCompleted = false;
            }
          }
        }
      }
    }

    _rollingSpeed = totalBytesTransferredThisTick / elapsedSec;
    _updateController.add(this);

    if (_pieces.every((p) => p.isVerified)) {
      _finalizeCompletion();
    }
  }

  Map<int, int> _calculatePieceRarity() {
    final rarity = <int, int>{};
    for (var i = 0; i < metadata.pieces.length; i++) {
      var count = 0;
      for (final peer in _peers) {
        if (peer.bitfield[i]) count++;
      }
      rarity[i] = count;
    }
    return rarity;
  }

  bool _simulateVerification(PieceStatus piece) {
    // Simulates validating the downloaded block hashes against expected SHA-1 hash.
    // 99.5% success rate, 0.5% block corruption/mismatch
    return Random().nextDouble() < 0.995;
  }

  void _finalizeCompletion() {
    _state = SimEngineState.completed;
    _rollingSpeed = 0.0;
    _loopTimer?.cancel();
    _updateController.add(this);
  }

  /// Disk I/O simulation mapping piece offsets to multiple output files
  void simulateDiskWrite(int pieceIndex, int blockOffset, Uint8List blockBytes) {
    final absoluteOffset = (pieceIndex * metadata.pieceLength) + blockOffset;
    var currentSeek = 0;

    for (final file in metadata.files) {
      final fileStart = currentSeek;
      final fileEnd = currentSeek + file.length;

      // Determine if our block overlaps with this file
      if (absoluteOffset + blockBytes.length > fileStart && absoluteOffset < fileEnd) {
        final overlapStart = max(absoluteOffset, fileStart);
        final overlapEnd = min(absoluteOffset + blockBytes.length, fileEnd);

        final blockLocalOffset = overlapStart - absoluteOffset;
        final fileLocalOffset = overlapStart - fileStart;
        final writeLength = overlapEnd - overlapStart;

        // In production:
        // final fileHandle = await File('$savePath/${file.path}').open(mode: FileMode.writeOnlyAppend);
        // await fileHandle.setPosition(fileLocalOffset);
        // await fileHandle.writeFrom(blockBytes, blockLocalOffset, blockLocalOffset + writeLength);
        // await fileHandle.close();
      }
      currentSeek += file.length;
    }
  }
}
```

---

## 6. Caveats

* **DHT and PEX Trackerless Torrents**: Magnet links without `tr` parameters rely on Distributed Hash Tables (DHT) or Peer Exchange (PEX) protocols to find peers. This design assumes tracker URIs are either present or resolved via a DHT engine component that is outside the scope of this pure-parser review.
* **Network Protocol Layer**: The actual BitTorrent P2P TCP/UDP socket handshake (with bitfield exchanges, choke/unchoke/interested messages) is simulated. In a live system, a network layer using Dart's `RawSocket` or `RawSecureSocket` must wrap the parser and handle binary wire parsing.
* **Storage Allocation**: Simulating disk writing assumes the directory structure was pre-allocated (creating empty files of the specified sizes) to allow writing blocks out of order.

---

## 7. Conclusion

Using pure Dart, magnet links can be parsed safely by extracting URI parameters and decoding RFC 4648 Base32 strings back to 40-character hex hashes. Torrent file decoding requires a byte-oriented Bencode parser to maintain exact indices of the raw `info` dictionary, allowing correct SHA-1 hash generation without re-encoding failures. A periodic execution loop using standard Dart timers provides clean state transition handling and rate metrics for user interfaces.

---

## 8. Verification Method

To verify these implementations locally:
1. Save the parser classes above into a Dart unit test file (e.g. `test/torrent_parsing_test.dart`).
2. Run the tests via:
   ```powershell
   flutter test test/torrent_parsing_test.dart
   ```
3. Use the following test suite template to assert correct parsing:

```dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Magnet Link Parser Tests', () {
    test('Parse Hex Info Hash & Trackers', () {
      final magnet = 'magnet:?xt=urn:btih:d2474e86c95b19b8bcf98777424a816e709e51f4&dn=Ubuntu&tr=udp%3A%2F%2Ftracker.co';
      final parsed = MagnetLink.parse(magnet);
      expect(parsed.infoHash, 'd2474e86c95b19b8bcf98777424a816e709e51f4');
      expect(parsed.displayName, 'Ubuntu');
      expect(parsed.trackers, contains('udp://tracker.co'));
    });

    test('Parse Base32 Info Hash', () {
      // 'uuzey2olllm3rj7zr53ue2ubnz4j4upk' is Base32 of infohash 'a5334c69cb5ae3b897fa8f74e27281be393e51e1'
      final magnet = 'magnet:?xt=urn:btih:uuzey2olllm3rj7zr53ue2ubnz4j4upk';
      final parsed = MagnetLink.parse(magnet);
      expect(parsed.infoHash, 'a5334c69cb5ae3b897fa8f74e27281be393e51e1');
    });
  });

  group('Bencode Decoder & SHA-1 Tests', () {
    test('Bencode Integer & Byte String Parsing', () {
      final raw = Uint8List.fromList(Uint8List.fromList([105, 52, 50, 101])); // i42e
      final decoded = BencodeDecoder(raw).decode();
      expect(decoded, 42);
    });

    test('Isolate Info Dictionary and Hash', () {
      // Simple torrent mock: d4:infoo3:cow3:mooee
      final rawTorrent = Uint8List.fromList(
        [100, 52, 58, 105, 110, 102, 111, 100, 51, 58, 99, 111, 119, 51, 58, 109, 111, 111, 101, 101]
      );
      final decoder = BencodeDecoder(rawTorrent);
      final parsed = decoder.decode();
      
      expect(parsed['info'], isNotNull);
      expect(decoder.infoStart, 7); // Start of 'd3:cow...'
      expect(decoder.infoEnd, 19); // End after first 'e' (inner dictionary)
    });
  });
}
```

---

## Appendix: Pure Dart SHA-1 Implementation (Zero-Dependency)

This self-contained implementation can be used for environment compatibility when `package:crypto` is not available:

```dart
import 'dart:typed_data';

Uint8List sha1PureDart(Uint8List message) {
  final int originalLengthInBits = message.length * 8;
  
  // paddingBytes calculations
  var paddingBytes = 64 - ((message.length + 8) % 64);
  if (paddingBytes == 0) paddingBytes = 64;
  
  final padded = Uint8List(message.length + paddingBytes + 8);
  padded.setAll(0, message);
  padded[message.length] = 0x80;
  
  final lengthBuffer = ByteData(8)..setUint64(0, originalLengthInBits, Endian.big);
  padded.setAll(padded.length - 8, lengthBuffer.buffer.asUint8List());
  
  var h0 = 0x67452301;
  var h1 = 0xEFCDAB89;
  var h2 = 0x98BADCFE;
  var h3 = 0x10325476;
  var h4 = 0xC3D2E1F0;
  
  final w = Uint32List(80);
  for (var i = 0; i < padded.length; i += 64) {
    final chunk = ByteData.sublistView(padded, i, i + 64);
    
    for (var j = 0; j < 16; j++) {
      w[j] = chunk.getUint32(j * 4, Endian.big);
    }
    
    for (var j = 16; j < 80; j++) {
      final val = w[j - 3] ^ w[j - 8] ^ w[j - 14] ^ w[j - 16];
      w[j] = ((val << 1) | (val >> 31)) & 0xFFFFFFFF;
    }
    
    var a = h0;
    var b = h1;
    var c = h2;
    var d = h3;
    var e = h4;
    
    for (var j = 0; j < 80; j++) {
      var f = 0;
      var k = 0;
      if (j < 20) {
        f = (b & c) | ((~b) & d);
        k = 0x5A827999;
      } else if (j < 40) {
        f = b ^ c ^ d;
        k = 0x6ED9EBA1;
      } else if (j < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8F1BBCDC;
      } else {
        f = b ^ c ^ d;
        k = 0xCA62C1D6;
      }
      
      final temp = (((a << 5) | (a >> 27)) + f + e + k + w[j]) & 0xFFFFFFFF;
      e = d;
      d = c;
      c = ((b << 30) | (b >> 2)) & 0xFFFFFFFF;
      b = a;
      a = temp;
    }
    
    h0 = (h0 + a) & 0xFFFFFFFF;
    h1 = (h1 + b) & 0xFFFFFFFF;
    h2 = (h2 + c) & 0xFFFFFFFF;
    h3 = (h3 + d) & 0xFFFFFFFF;
    h4 = (h4 + e) & 0xFFFFFFFF;
  }
  
  final result = ByteData(20);
  result.setUint32(0, h0, Endian.big);
  result.setUint32(4, h1, Endian.big);
  result.setUint32(8, h2, Endian.big);
  result.setUint32(12, h3, Endian.big);
  result.setUint32(16, h4, Endian.big);
  
  return result.buffer.asUint8List();
}
```

# Milestone 4: Torrent & Magnet Downloader Implementation Plan

This plan outlines the design and files to be implemented/modified by the worker agent.

## Components to build:
1. **MagnetLink Parser** (`lib/downloader/magnet_link.dart`):
   - Decodes magnet URIs using standard `Uri.parse`.
   - Extracts `xt` (info hash), `dn` (display name), `tr` (trackers), `ws` (web seeds).
   - Validates the info hash format (either 40-character Hex or 32-character Base32).
   - Normalizes Base32 info-hashes to standard 40-character Hex and lowercase.

2. **BencodeDecoder** (`lib/downloader/bencode_decoder.dart`):
   - Decodes bencoded `Uint8List` into standard Dart types (`int`, `Uint8List`, `List`, `Map<String, dynamic>`).
   - Ensures strict bencode validation (no leading zeros for integers, proper list/dict terminations).
   - Extracts and preserves raw `info` dictionary bytes from the torrent file stream for SHA-1 calculation.

3. **TorrentMetadata** (`lib/downloader/torrent_metadata.dart`):
   - Models `.torrent` files, parsing bencoded data and computing the SHA-1 info-hash using the `crypto` package.
   - Extracts `name`, `piece length`, `pieces` (as Uint8List), total files size, list of files (supporting both single and multi-file torrents).

4. **TorrentDownloader** (`lib/downloader/torrent_downloader.dart`):
   - Manages simulated P2P download logic.
   - Runs a periodic timer loop to simulate peer connection and block downloads, validating piece chunks against the SHA-1 checksum.
   - Supports checkpoint state serialization (saving/loading `resume.json` in `tempDir` containing progress and completed chunks).
   - Supports preemption, pausing, and cancellation correctly.

5. **DownloadQueue Integration** (`lib/downloader/download_queue.dart`):
   - Updates `addTask` to instantiate `TorrentDownloader` if the task URL is a magnet link or `.torrent` file.
   - Interchanges tasks, active status updates, and handles queue preemption correctly.

6. **Unit and Integration Tests**:
   - `test/downloader/magnet_parser_test.dart`
   - `test/downloader/bencode_parser_test.dart`
   - `test/downloader/torrent_downloader_integration_test.dart`

# BRIEFING — 2026-06-18T07:18:33Z

## Mission
Implement local BitTorrent/Magnet downloader (Milestone 4) for Aurora Downloader.

## 🔒 My Identity
- Archetype: implementer, qa, specialist
- Roles: implementer, qa, specialist
- Working directory: D:\02_Projects\Final_52191314_Server_and_Apps\aurora_downloader\.agents\worker_m4
- Original parent: 4d517e25-674d-4ff3-8bc7-ebe0eeb772c1
- Milestone: Milestone 4 (BitTorrent/Magnet downloader)

## 🔒 Key Constraints
- No cheating (do not hardcode test results, expected outputs, etc.)
- Strictly follow Clean Folder & Source Isolation Policy (though not directly applicable to server_and_apps source code, we will keep source and build artifacts isolated).
- Network Restriction: CODE_ONLY network mode. No external HTTP/wget/curl.

## Current Parent
- Conversation ID: 4d517e25-674d-4ff3-8bc7-ebe0eeb772c1
- Updated: not yet

## Task Summary
- **What to build**: MagnetLink parser, BencodeDecoder, TorrentMetadata, TorrentDownloader, and integration into DownloadQueue/Downloader.
- **Success criteria**: All magnet parsing, bencode decoding, torrent metadata extraction, resume/pause loop, and preemption tests compile and pass 100%.
- **Interface contracts**: lib/downloader/downloader.dart, download_queue.dart, etc.
- **Code layout**: Dart standard layout (lib/, test/).

## Key Decisions Made
- Implemented robust RFC 4648 Base32 decoder and used it to decode 32-character magnet info-hashes to 40-character hex.
- Modified BencodeDecoder to record exact offsets of the bencoded value for `'info'` and slice it as `_raw_info_bytes` for SHA-1 hashing.
- Standardized `DownloadChunk` structure mapping 1-to-1 to torrent pieces to utilize DownloadQueue's existing priority/preemption system.
- Designed simulated peer loop in `TorrentDownloader` with optional corruption list and disk-full exception injection for unit/integration testing.

## Artifact Index
- None

## Change Tracker
- **Files modified**:
  - `lib/downloader/magnet_link.dart`: Parsed magnet URLs, Base32-to-Hex conversion.
  - `lib/downloader/bencode_decoder.dart`: Decoded bencoded files, captures raw info bytes.
  - `lib/downloader/torrent_metadata.dart`: Class for parsed torrent files, single/multi-file support, info-hash computation.
  - `lib/downloader/torrent_downloader.dart`: Executed torrent tasks, simulated peer loop, pause/resume, resume.json checkpointing, disk full support.
  - `lib/downloader/download_queue.dart`: Integrated TorrentDownloader logic based on schemes.
  - `lib/downloader/downloader.dart`: Added exports for new files.
  - `test/downloader/magnet_parser_test.dart`: Magnet parsing tests.
  - `test/downloader/bencode_parser_test.dart`: Bencode decoding/metadata tests.
  - `test/downloader/torrent_downloader_integration_test.dart`: End-to-end integration tests.
- **Build status**: RUNNING tests
- **Pending issues**: None

## Quality Status
- **Build/test result**: Running flutter test
- **Lint status**: 0 violations expected
- **Tests added/modified**: magnet_parser_test, bencode_parser_test, torrent_downloader_integration_test

## Loaded Skills
- None

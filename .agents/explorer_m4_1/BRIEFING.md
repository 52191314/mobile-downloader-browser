# BRIEFING — 2026-06-18T00:17:10Z

## Mission
Analyze core Torrent Downloader design in Dart and its integration with existing structures.

## 🔒 My Identity
- Archetype: Teamwork explorer
- Roles: Reader-only investigation, analyser, reporter
- Working directory: D:\02_Projects\Final_52191314_Server_and_Apps\aurora_downloader\.agents\explorer_m4_1
- Original parent: 4d517e25-674d-4ff3-8bc7-ebe0eeb772c1
- Milestone: Torrent Downloader design

## 🔒 Key Constraints
- Read-only investigation — do NOT implement
- CODE_ONLY network mode: No external websites/services, no curl/wget/lynx.
- Write only to your own agent folder.

## Current Parent
- Conversation ID: 4d517e25-674d-4ff3-8bc7-ebe0eeb772c1
- Updated: 2026-06-18T07:30:00+07:00

## Investigation State
- **Explored paths**:
  - `lib/downloader/models.dart` (Checked task representation)
  - `lib/downloader/download_queue.dart` (Analyzed scheduler, task management, coupling with HTTP splitter)
  - `lib/downloader/download_splitter.dart` (Verified how HTTP chunk downloads work)
  - `lib/downloader/file_combiner.dart` (Understood chunk combination & checksum verification)
  - `test/downloader_test.dart` (Verified test suite behavior)
- **Key findings**:
  - `DownloadTask` is a concrete serializable class using `fromJson`/`toJson`.
  - `DownloadQueue` runs tasks by directly creating `DownloadSplitter`s.
  - Integration of Torrent tasks requires introducing a generic `DownloadRunner` abstraction to decouple queue scheduling from HTTP-specific downloading.
  - Adding `DownloadType` to `DownloadTask` lets the queue conditionally instantiate a `DownloadSplitter` (for HTTP) or `TorrentDownloadRunner` (for Torrents).
  - To support multi-file torrents and peer-to-peer stats, `DownloadTask` can be subclassed to `TorrentDownloadTask`, with backward-compatible polymorphic serialization.
- **Unexplored areas**:
  - UI integration: How the sniffer screen or download queue UI should display torrent-specific fields (e.g. peers, upload speed).
  - Persistence: Where `.torrent` state or torrent session resume data is saved.

## Key Decisions Made
- Proposed introducing a `DownloadRunner` interface.
- Proposed representing torrent tasks via a `TorrentDownloadTask` subclass extending `DownloadTask`.
- Proposed a generic `TorrentService` interface that handles peer-to-peer networking.

## Artifact Index
- D:\02_Projects\Final_52191314_Server_and_Apps\aurora_downloader\.agents\explorer_m4_1\handoff.md — Handoff report detailing Torrent Downloader model/service design and integration.

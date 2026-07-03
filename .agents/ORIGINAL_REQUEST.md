# Original User Request

## Initial Request — 2026-06-18T06:33:05+07:00

An Android-only Flutter mobile application named Aurora Downloader that manages multi-threaded HTTP downloads, local BitTorrent downloads, captures streaming media via an in-app browser sniffer, and syncs completed downloads to Google Drive, all packaged in a Minimalist Nordic Dark UI.

Working directory: `D:\02_Projects\Final_52191314_Server_and_Apps\aurora_downloader`
Integrity mode: benchmark

## Requirements

### R1. Multi-Threaded Download Engine
The app must support downloading files by splitting them into multiple concurrent segments using HTTP Range headers, and combining them upon completion to maximize download speed.

### R2. Built-in Browser & Sniffer
An in-app web browser must intercept web requests to detect and capture links for media streams (.mp4, .m3u8, etc.) and files (.pdf, .zip, etc.) and present a one-tap download action.

### R3. Local BitTorrent Client
The application must run a local torrent and magnet downloader directly on the device, allowing downloading peer-to-peer torrents.

### R4. Google Drive Sync
The application must support linking to Google Drive and automatically uploading completed downloads to a designated folder.

### R5. Nordic Dark UI
The user interface must implement a Minimalist Nordic Dark Mode (matte blacks/greys, frost accents) containing a download queue dashboard, progress charts, speed limiters, and settings.

### R6. Automated Verification
The team must implement a robust test suite consisting of unit tests for the core engines (download splitter, queue, and state transitions) and widget tests for the UI components.

## Acceptance Criteria

### Automated Verification
- [ ] Execution of `flutter test` succeeds with 100% pass rate for all implemented tests.
- [ ] Unit tests cover range request calculation, chunk combining, and queue priority handling.
- [ ] Widget tests verify that key UI pages render correctly under the Nordic theme.

### Multi-Threaded HTTP Downloading
- [ ] Core engine divides a download URL into independent HTTP range requests.
- [ ] Partial downloads can be successfully paused and resumed without losing progress.
- [ ] Downloaded file matches the source SHA-256 hash.

### Media Sniffer & Browser
- [ ] Web view screen displays web pages correctly and intercepts video/audio streaming links.

### Torrent Downloader
- [ ] Integrates a BitTorrent download engine and successfully parses Magnet URLs and .torrent metadata.

### Cloud Integration
- [ ] Sync manager implements Google Sign-in authentication flow and Drive API file uploads.

## Follow-up — 2026-06-18T00:03:15Z

We have updated the project requirements to include an Adblocker filter in the built-in browser (R2). Please ensure the browser implementation integrates content blocker rules (e.g. using flutter_inappwebview Content Blockers) to filter common ad domains and suppress popups. I have updated prompt_draft.md with the specific details and acceptance criteria.

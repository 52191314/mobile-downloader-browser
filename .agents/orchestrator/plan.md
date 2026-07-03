# Project: Aurora Downloader
# Scope: All Milestones

## Architecture
- Flutter Application structure.
- State management / Services / Repositories.
- Core Modules:
  1. Downloader Service (Multi-threaded HTTP ranges, Segment combination, queue, pause/resume, SHA-256 verification)
  2. Web Sniffer Service (In-app WebView controller, network request interception for media/file extensions)
  3. Torrent Service (BitTorrent/Magnet engine, parsing magnet links, torrent metadata)
  4. Google Sync Service (OAuth/Sign-in mock/flow, Google Drive API upload mock/flow)
  5. UI Layer (Nordic Dark Mode Theme, Dashboard, progress charts, speed limiters, settings)
- Automated Test Suite.

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| 1 | Environment Check & Codebase Analysis | Verify flutter environment, explore project structure | None | DONE |
| 2 | Core Multi-threaded Downloader (R1) | Multi-threaded HTTP Range request calculations, chunks download, chunk joining, pause/resume, SHA-256, Unit tests | M1 | DONE |
| 3 | Browser & Media Sniffer (R2) | WebView with media sniffer, adblocker (filter ad domains, suppress popups), intercept links, widgets | M1 | DONE |
| 4 | Torrent & Magnet Downloader (R3) | Parse Torrent metadata/magnet link, native libtorrent engine, deterministic simulator tests | M1 | DONE |
| 5 | Google Drive Integration (R4) | Google Sign-In plus Drive API uploads with mockable test client | M1 | DONE |
| 6 | Nordic Dark UI & Queue Dashboard (R5) | Minimalist Nordic Dark UI, progress chart, queues, speed limiter, browser, settings | M2, M3, M4, M5 | DONE |
| 7 | Verification & Automated Test Pass (R6) | Analyze, full tests, debug APK build, and release APK build pass | M6 | DONE |

## Interface Contracts
### Downloader ↔ UI
- Queue management and state streams.
- Speed limiters controls.
### Sniffer ↔ Downloader
- Intercepted URL streams to present options to downloader queue.
### Sync ↔ Downloader
- Sync manager listening to completed download events.

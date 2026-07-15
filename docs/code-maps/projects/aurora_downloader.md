# Aurora Downloader — Code Map

> Maintained per AGENTS.md. Last updated: 2026-07-15.

## Overview
Aurora Downloader is a Flutter (Android) media downloader with an integrated
sniffer/browser. It captures media URLs from web pages via injected JavaScript
guards + a Dart-side poll, then downloads via HLS / segmented / torrent engines,
with optional native ad-blocking and auto-backup.

## Architecture
- Single `MaterialApp` with `IndexedStack` tab navigation (Queue / Browser / Settings).
  Browser state is preserved across tab switches.
- 3 tabs: Queue (downloads), Browser (SnifferScreen), Settings.
- Browser supports multiple tabs (`List<_BrowserTab>` in `_SnifferScreenState`).
  Each tab gets its OWN `MediaSnifferEngine` — no shared engines between tabs.
- Sniffer JS guard: single script (`assets/browser_guard.js`) injected per WebView
  via `BrowserGuardInstaller._installBrowserGuards()`. Hooks: DOM scan
  (`video`/`audio`/`a[href]`/`img[src]`/`source[src]`/`iframe`/`script`),
  `HTMLMediaElement.prototype.src` setter, `loadedmetadata`/`play`/`canplay`
  listeners, `fetch`/`XMLHttpRequest` interceptors, `MutationObserver`,
  `PerformanceObserver`, `setAttribute` hook, long-press/element-picker.
- Dart-side 2-second poll (`tab_lifecycle_controller` video poll timer, 15s in
  code) asks the WebView directly for `video.currentSrc` — bypasses CSP that may
  block injected JS.
- Tab URLs persisted to `browser_tabs.json`; sniffed media cached in
  `sniffed_media_cache.json`. Restored on next launch.
- Native adblock: hybrid engine (`lib/sniffer/ad_block_engine_native.dart`)
  auto-detects `libaurora_adblock.so` (C++ domain trie + Aho-Corasick). Falls
  back to Dart rule matching if the `.so` fails to load. No settings toggle.

## Palette System (added 2026-07-15)

- `lib/theme/aurora_tokens.dart` — `AColors` value class with `.dark()` / `.light()` factories. Every semantic token (surfaces, borders, accents, text, status, media, groups) is a named field.
- `lib/theme/aurora_palette.dart` — `AuroraPalette` InheritedWidget plus `context.ac` extension. All widgets read colors via `context.ac.<token>`, which resolves to the correct hex for the active `Brightness`.
- `lib/theme/aurora_theme.dart` — `buildLightTheme()` / `buildDarkTheme()` ThemeData builders (Inter typography, frost-line cards, palette-driven). `AuroraTheme` convenience wrapper for tests.
- `lib/theme/aurora_glass_background.dart` — palette-aware scaffold gradient (light snowfield / dark slate).

Historic `aurora_colors.dart` (AuroraColors + AuroraColorsLight) has been deleted. All ~250+ call-sites migrated to `context.ac.*`.

## Key Files
- `lib/sniffer/sniffer_screen.dart` — main browser/sniffer UI, tab management,
  dock, sniffed-media sheet.
- `lib/sniffer/browser_controller.dart` — `SnifferWebViewControllerImpl`
  (freeze/thaw, resource timer, dispose lifecycle).
- `lib/sniffer/browser_guard_installer.dart` — injects guard JS, 20s refresh timer.
- `assets/browser_guard.js` — the injected sniffer guard (all capture logic).
- `lib/sniffer/media_enricher.dart` — enriches sniffed media (size/duration/codecs).
- `lib/sniffer/controllers/tab_lifecycle_controller.dart` — tab load/save,
  video poll, media save scheduling.
- `lib/sniffer/controllers/tab_manager.dart` — `switchToActiveTab` freeze/thaw.
- `lib/downloader/hls_downloader.dart` — HLS variant pipeline.
- `lib/log_server.dart` — debug-only HTTP server exposing `DownloadLogger` (release tree-shaken).
- `lib/downloader/download_splitter.dart` — parallel segmented download.
- `lib/downloader/torrent_downloader.dart` — torrent (native libtorrent_flutter + synthetic Dart fallback).
- `lib/backup/*` — auto-backup feature (consolidated JSON format, models/service/state).
- `android/app/src/main/cpp/adblock/*` — native C++ adblock engine.

## Feature Status (audit 2026-07-14)
| Feature | Status | Notes |
|---|---|---|
| Segmented splitting | Implemented | Parallel Range chunks, resume, 429/403/401, SHA-256, stall salvage. |
| Native Adblocking | Implemented | C++ `.so` + Dart fallback, active by default. Cosmetic hiding Dart-only. |
| HLS variant downloading | Implemented | Master→variant select, .ts dl+AES decrypt+merge+TS→MP4 remux. **User quality picker added** (add-queue dialog dropdown, resolves master playlist variants). |
| Torrent support | Partial (documented limitation) | Metadata/magnet parsing + native engine present but OFF by default; Dart fallback is synthetic (no real BT protocol); no UI toggle. Tracked as a known limitation, not a defect. |
| Log Server | Implemented (debug-only) | `lib/log_server.dart` HTTP server exposing `DownloadLogger` buffer (HTML + `/json`). Started only in debug builds via `startLogServerIfDebug()` (guarded by `kDebugMode`, tree-shaken from release). Reachable at `http://localhost:8080`. |

## Known Refinement Items
- Timer leaks on frozen tabs (FIXED 2026-07-14): `_guardRefreshTimer` and
  `_loadResourceTimer` now cancelled in `freeze()`, guard timer restarted in `thaw()`.
- HLS response-stream drains (FIXED 2026-07-14): drain before throw on non-403
  path and on HEAD probe to release HTTP connections.
- `_saveTabs` debounced (FIXED 2026-07-14): 3s coalesce on page-finish path.
- Guard `postUrl` does not normalize → relative + absolute duplicates for
  `src`-setter / XHR paths (benign; engine resolves relative URLs). Candidate tidy-up.
- Audit-flagged "High" concurrency races (A1 media_enricher, C1 hls_downloader,
  C2 download_splitter) investigated and determined FALSE POSITIVES — Dart's
  single-threaded event loop makes those synchronous `+=`/`add`/`remove`/list
  assignments atomic; no `await` splits a read/write. No change made.
- Backup UI restructured (2026-07-14): top-level Settings card is now "Backup"
  (Manual + Auto) → `_buildBackupPage()` with manual Backup (Back up now /
  Restore) plus a nested "Auto Backup" section (enable + frequency). Manual
  backup was preserved, not removed.
- HLS quality picker added (2026-07-14): add-queue dialog now shows a Quality
  dropdown populated from master-playlist variant resolution
  (`_fetchMasterPlaylistVariants`); defaults to highest bandwidth, user-selectable.
- Debug-only Log Server added (2026-07-14): `lib/log_server.dart`, started via
  `startLogServerIfDebug()` in `main.dart` after logger init; no-op in release.
- Consolidated Backup (2026-07-15): backup data files merged into a single consolidated `aurora_backup.json` to avoid multi-file copy issues, with backward-compatible fallback for restoring older backups.

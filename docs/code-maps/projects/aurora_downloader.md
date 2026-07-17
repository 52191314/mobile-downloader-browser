# Aurora Downloader — Code Map

> Maintained per AGENTS.md. Last updated: 2026-07-17.

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
  dock; hosts Capture sheet via `showSniffedMediaSheet` + `_showAddQueueDialog`
  (`Future<bool>` for batch cancel-stop).
- `lib/sniffer/widgets/capture_widgets.dart` — `part of` sniffer_screen; **live
  dock only**: `_BrowserDock` / `_CompactNavButton` / `_DockDot` (`mini_dock_*`
  keys). Dead Capture dual-path tiles removed in PR4 hygiene.
- `lib/sniffer/sheets/sniffed_media_sheet.dart` — Capture sheet orchestrator
  (displayedGroups pipeline, sticky batch bar, stream rebuilds).
- `lib/sniffer/sheets/media_info_sheet.dart` — Capture → Details journey;
  dual-theme tokens via `context.ac` + type chip `mediaAccentFor` (token/
  contrast only; no structural redesign).
- `lib/sniffer/capture/` — Capture UI library (dual-theme chrome):
  `media_accent.dart` / `media_filter.dart`,
  `capture_sheet_header.dart`, `capture_filter_bar.dart`,
  `capture_options_row.dart` (show-all + sort + display mode; KD25–26),
  `capture_group_sort.dart` (post-filter `sortCaptureGroups` by
  `SniffedMediaSort` on primary media — overrides analyzer confidence order),
  `capture_stats_row.dart`, `capture_media_row.dart` (subtitle honors
  `SniffedMediaDisplayMode`), `capture_batch_bar.dart`, `capture_empty_state.dart`.
- `lib/sniffer/controllers/media_catch_controller.dart` — group-index selection
  into the **displayed** list (`recommendedGroupIndices` / `selectedFrom`).
- `lib/sniffer/browser_controller.dart` — `SnifferWebViewControllerImpl`
  (freeze/thaw, resource timer, dispose lifecycle).
- `lib/sniffer/browser_guard_installer.dart` — injects guard JS, 20s refresh timer.
- `assets/browser_guard.js` — the injected sniffer guard (all capture logic).
- `lib/sniffer/media_enricher.dart` — enriches sniffed media (size/duration/codecs).
- `lib/sniffer/controllers/tab_lifecycle_controller.dart` — tab load/save,
  video poll, media save scheduling.
- `lib/sniffer/controllers/tab_manager.dart` — `switchToActiveTab` freeze/thaw.
- `lib/downloader/hls_downloader.dart` — HLS variant pipeline.
  Playlist fetch order (2026-07-16): cache → WebView body → headless → Dart → native.
- `lib/sniffer/hls_playlist_cache_lookup.dart` — exact + host/path playlist cache
  lookup; rejects CF/HTML block pages.
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
| Battery Optimization | Implemented | Prompt on launch to exclude from optimization, with "Never ask again" settings option. |

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
- Surrit/Cloudflare playlist gap (2026-07-16): sniffer already fetched real
  `#EXTM3U` via `fetchPlaylistBodyViaJavaScript` while downloader used weaker
  `fetchViaJavaScript`, no headless playlist fallback, exact-only cache →
  Dart:403. Fixed: download bridges use playlist-body path; headless before
  Dart; fuzzy cache; tests in `test/sniffer/hls_playlist_cache_lookup_test.dart`.
- TS→MP4 remux HW audio silence (2026-07-16): MX Player HW mute / HW+ OK.
  Native remux now time-interleaves A/V and synthesizes AAC `csd-0` when
  missing (`MainActivity.remuxTsToMp4`). Existing files need re-download or
  re-remux to pick up the fix.
- HLS stall at ~142KB / speed 0 (2026-07-16): segments never used native
  `streamSegmentToFile` (1DM-class CookieManager + media headers); only
  WebView base64 / headless (timeouts + disposed controller). Wired as
  primary path in `HlsDownloader._downloadSegment` via
  `NetworkBindingService.streamSegmentToFile`; full concurrency retained
  while native works.
- WebView performance optimizations (2026-07-15): disabled `transparentBackground` and `useOnLoadResource` bridge callback, added `rendererPriorityPolicy` set to `RENDERER_PRIORITY_IMPORTANT` and `waivedWhenNotVisible: true`, and migrated media sniffer detection from `onLoadResource` into `shouldInterceptRequestCallback` to reduce bridge chatter.
- WebView performance optimizations Phase 3 & 4 (2026-07-15): Added selective cookie cache clearing per host, optimized progress indicator with a ValueNotifier to eliminate full page rebuilds during load, implemented auto-cancellation of the periodic video poll timer after 3 consecutive empty cycles, and simplified browser guard re-injection logic.
- Three-way duplicate download choices (2026-07-16): Added `DuplicateChoice` (downloadAgain, updateExisting, skip) to prompt the user when a duplicate URL is detected, allowing them to update the existing download task (resetting progress if URL changed, and resuming) or create a separate one.
- Battery Optimization Check on Launch (2026-07-16): Added a custom dialog on launch to prompt users to disable battery optimization for uninterrupted background downloads, with a corresponding "neverAskBatteryOpt" setting/toggle switch in Settings.

# Session 2026-07-19 — Freeze Fixes & Performance Improvements

## Description
Implementation and verification of freeze/jank fixes, speed limiter enhancements, atomic progress updates, media sniffer acceleration, and stream ranking logic.

## Changes Log

### Cold start & tab-switch freeze fixes
- **Tab-switch liveness check:** Tab switch calls `resumeWebView(checkAlive: true)` to probe renderer status via JS `evaluateJavascript('1')`, triggering an auto-reload of the tab when Chromium's background renderer has been evicted.
- **Eviction cap:** Proactive background tab eviction reduced `_maxLiveWebViews` from 10 to 4 in `sniffer_screen.dart` to prevent background renderer kills.
- **JSON isolate offload:** Large `jsonDecode` of `AuroraLog` (capped at newest 2000 entries) offloaded to background isolate during app startup.
- **Queue restore speedup:** O(n²) duplicate URL check scanner bypassed in `DownloadQueue` while `_isLoading` is true (authoritative queue restoration).
- **Lazy downloader splitters:** Splitter instantiation deferred for paused and completed tasks until they are explicitly started.
- **Lazy adblock rules loading:** FFI `loadRules` call deferred to first intercept check rather than blocking `initState` of `AuroraHome`.
- **Worker pool prewarm:** Spawning of the worker isolate pool starts early during `main()` to prevent first-call latency.

### Performance & throughput
- **Token bucket speed limiter:** Speed limiter in `speed_limiter.dart` rewritten to support debt-carrying replenishment, eliminating throughput bursts or starvation.
- **Atomic progress accounting:** Segment progress byte updates in `HlsDownloader` committed only on successful rename/decrypt, preventing progress jumps or duplicate-counting on paused/failed segments.
- **Responsive pause checks:** Loop checks pause state every 100ms instead of waiting for exponential backoff up to 24s.
- **Shorter HTTP keep-alive:** Socket idle keep-alive timeout reduced from 90s to 15s to save battery.
- **Notification throttling:** Foreground data sync method channel notifications coalesced to <= 5/s.

### Media detection & enrichment
- **Detection flush speedup:** Sniffed media resources periodic flush reduced from 2s to 500ms, immediately sending playlist (`.m3u8`/`.mpd`) matches to the UI.
- **DASH representation deduplication:** Added check to prevent representation row duplicates when rescanning `.mpd` links.
- **Cap size probes:** Segment probes capped to max 2 HEAD requests (dropped Range-GET/JS fallback fallbacks).
- **Early WAF bypass:** Pure HTTP probe tiers bypassed immediately on 401/403/407 to directly trigger WebView JS scraping.
- **Global cache TTL restore:** Restored eviction timers for URLs reloaded during cache restorations.

### Player stream ranking
- Codec-aware scoring (favoring h264/h265), excluding audio-only streams from playback list, penalizing live streams in download context, and filtering anomalous bitrates.

### Headless Page Resniffer
- Added `HeadlessPageResniffer` (`lib/sniffer/headless_resniffer.dart`) for background page re-sniffing and token refresh without hijacking user browser tabs.

## Verification
- Run `dart analyze` to ensure clean static analysis on modified files.
- Run `flutter test` to check that all downloader, sniffer, and compliance unit tests pass successfully.

# Aurora Downloader — Performance Optimization Findings & Roadmap

Status: 2026-08-03 · Source: 5 parallel code audits (UI/rendering, download engine & I/O,
memory/CPU/crypto, app size & build, startup & lifecycle) plus targeted bug review.

**Update 2026-08-05:** Re-verified against the current tree — **the findings below are mostly
stale; the fixes have landed.** Confirmed fixed in code: §1 logging subsystem (removed outright,
see `archive/diagnostics_logging_2026-08-05/` — all call sites are now `debugPrint`), §2 HLS
decrypt (single reused CBC cipher + output buffer, `hls_decryptor.dart`), §3 queue persistence
(`_saveChain` + 5 s periodic flush close the spin-loop + durability gap, `download_queue.dart`),
§4 decrypt pool sized to segment concurrency (`hls_downloader.dart:360`), §5 queue status line
single-pass (`queue_page.dart:_buildStatusLine`), §7 HLS resume scan on `Isolate.run`
(`hls_downloader.dart:2202`), §8 schedule timer cancelled when idle. Still open: §6 shell
500 ms whole-tree rebuild (`main.dart:_queueRebuildTimer`).

## Executive summary

The codebase's **plumbing layer is now in good shape** (probe pooling, main-thread channel
replies, off-isolate merges, persistent decryption workers, `string_view` FFI, R8/ABI size
fixes). The **largest remaining wins** are: (1) the logging subsystem rewrites a 10k-entry
JSON file on the UI isolate for every log event, (2) the HLS decrypt hot loop churns
~23–40 GB of GC allocations per 2 GB video, (3) the queue page rebuilds whole subtrees on
500 ms ticks, and (4) the queue persistence layer has both a spin-loop and a crash
durability gap.

## What has been fixed

### Round 1 — verified findings from the original claim list
- **HTTP probe socket teardown** → probe streams are drained (not canceled) so connections
  return to the keep-alive pool. Guarded: if a server ignores `Range` and streams a large
  body, the connection is aborted instead of downloading the file to discard it.
  (`download_splitter.dart`, `hls_downloader.dart`, `url_filename_resolver.dart`)
- **UI-isolate file merging** → `FileCombiner.combineAndHash` and the HLS merge concat loop
  now run on background isolates; chunk-size validation stays on the caller so
  `FileSystemException` keeps its type; isolate errors cross as readable `Exception`s.
  (`file_combiner.dart`, `hls_downloader.dart`)
- **Fresh isolate per HLS segment** → persistent decryption worker pool
  (`hls_decrypt_pool.dart`), prewarmed at HLS start.
- **Native engine replies on worker threads** → `MethodChannel.Result` callbacks are posted
  to the main thread, with a try/catch so a torn-down engine can't crash the looper.
  (`NativeDownloadEngine.kt`)
- **C++ FFI `std::string` allocations** → per-request functions take `std::string_view`
  (zero-copy at the boundary; class lists split into `string_view` tokens).
  (`ffi_api.cpp`, `adblock_engine.*`, `url_matcher.*`)
- **Broad ProGuard keep** → narrowed to class-name keeps for the 4 app classes.
  (`proguard-rules.pro`)
- **x86/x86_64 `.so` in AAB** → removed from base packaging + all 3 on-demand modules;
  verified zero x86 entries in the debug AAB. (`app/build.gradle.kts`,
  `ffmpeg|torrent|mediakit/build.gradle.kts`)

### Round 2 — bugs surfaced by the audits (correctness, not just perf)
- **gzip corruption risk**: `NativeDownloadEngine` sent `Accept-Encoding: gzip` on ranged
  chunk downloads; a server honoring gzip would corrupt byte offsets. Now `identity`.
- **JetBrainsMono never loaded**: 21 code sites use `fontFamily: 'JetBrainsMono'` but the
  pubspec family was `'JetBrains Mono'` → most mono text rendered in the fallback font.
  Added a family alias (same TTF, bundled once).
- **Cosmetic adblocking broken**: `assets/adblock_cosmetic.js` + `assets/scriptlets.js`
  were loaded via `rootBundle` but never declared in pubspec → `loadString` threw at
  runtime. Now declared and verified present in the AAB.
- **Engine leak**: `NativeDownloadEngine.dispose()` had zero callers; the OkHttp pool and
  worker threads leaked on teardown. Now called from `MainActivity.onDestroy()`, and the
  unbounded `newCachedThreadPool()` is bounded (32).
- **Worker-isolate pool never prewarmed** → first queue/log restore stalled on 3 sequential
  `Isolate.spawn`s. Now prewarmed in `AuroraHome.initState`.
- **Decrypt "key schedule cache" overstated**: verified in PointyCastle source that
  `AESEngine.init` re-expands the key schedule on every call — the cache only avoids
  wrapper construction. Comment corrected; real fix is the direct-CBC rewrite below.

## Remaining findings (by subsystem, ranked by ROI)

### 1. Logging — `lib/logging/aurora_log.dart` (LARGE)
Every non-repeating log entry does `_entries.insert(0, …)` (O(n) shift) + `_saveToFile()`:
`jsonEncode` of up to 10,000 entries + full rewrite + flush on the **UI isolate**. HLS logs
several times per segment → hundreds of full rewrites per playlist.
**Fix:** debounce saves (~1–2 s dirty timer), offload `jsonEncode` to the worker pool,
drop `flush: true`, keep atomic temp-write + rename. Risk: safe.

### 2. HLS decrypt hot loop — `lib/downloader/hls_decryptor.dart` (LARGE)
Per 64 KB chunk: `combined` buffer → PointyCastle re-expands the AES key schedule on every
`init` → fresh output buffer → CBC per-block `Uint8List.view` objects (4096/chunk) →
`decryptBytes().toList()` boxed copy (~8× data) → `Uint8List.fromList`. ≈0.7–1.3 MB/chunk ×
32,768 chunks ≈ 23–40 GB allocated per 2 GB video.
**Fix:** drive `CBCBlockCipher(AESEngine())` directly with a **reused output buffer**,
keep CBC IV chaining across chunks without re-init, larger `openRead(1 << 20)` reads, strip
PKCS7 manually with the existing no-padding fallback. Must keep the pending-last-blocks
boundary logic. Add FIPS-197/NIST known-answer tests. Risk: medium (crypto) — gated on
passing KAT tests.

### 3. Queue persistence — `lib/downloader/download_queue.dart` (MEDIUM)
- `_waitAndSave` busy-waits `while (_isSaving) { await Future.delayed(50ms) }` (20 Hz).
- The save debounce (1 s timer, `download_queue.dart:~1995`) is **reset on every emit**, so
  the queue JSON is never written while a download streams → crash loses all progress since
  the last terminal/pause save (durability gap).
**Fix:** replace the spin with a chained-save future; a single periodic save timer (~5 s)
plus immediate save on terminal states and on app background.

### 4. Decrypt concurrency — `lib/downloader/hls_downloader.dart` / `hls_decrypt_pool.dart` (MEDIUM)
Pool size is 2 but `maxConcurrentSegments` is 4 → downloads serialize through the decrypt
workers on fast connections. **Fix:** size the pool to the effective segment concurrency
(min 2, capped).

### 5. Queue page rebuilds — `lib/ui/pages/queue_page.dart` (MEDIUM)
- `_buildStatusLine` runs 5 O(n) scans of the queue (each `allTasks`/`activeTasks` getter
  allocates a fresh list) on every build.
- Sectioned mode re-sorts 4 sections per build with a string-heavy comparator
  (`_compareTasks` → `taskDisplayName(...).compareTo(...)`).
**Fix:** cache the status-line aggregates and the last partition/sort result keyed on a
queue version counter; only recompute on add/remove/state-transition. Risk: medium.

### 6. Shell + player whole-tree rebuilds (MEDIUM)
- `lib/main.dart` shell: a 500 ms `_queueRebuildTimer` calls `setState` on `AuroraHome`,
  re-running **both** QueuePage and SnifferScreen `build()`s even when hidden.
- `lib/sniffer/aurora_video_player.dart`: the controller listener calls full-player
  `setState` up to 10×/s (`_lastProgressUiAt` 100 ms window); only the progress bar + clock
  change.
**Fix:** drive the dock/badge with existing `ValueNotifier`s; wrap the player's progress
bar + clock in a `ValueListenableBuilder<VideoPlayerValue>`. Risk: safe–medium.

### 7. HLS resume scan — `lib/downloader/hls_downloader.dart` (SMALL-MEDIUM)
On every retry, `tempDir.list()` + `length()` per file + a 376-byte read+parse per segment
(`_isSegmentValid`) all run on the UI isolate (≈1000 file ops for a 500-segment resume).
**Fix:** do the scan/validation in `Isolate.run`, return `{index → size, valid}`.

### 8. Timer hygiene (SMALL)
- 30 s `_scheduleTimer` starts on first scheduled task and never stops (process lifetime);
  cancel when no `scheduled` tasks remain, restart lazily.
- Per-chunk 500 ms `chunkFile.length()` poll (`download_splitter.dart:~918`) → adaptive
  (start 1–2 s, tighten only when no progress).
- Watcher service runs an immediate network pass at launch + a 5-min loop that never pauses
  in background; drop the startup pass and pause/resume on lifecycle.
- On app pause, the whole queue is re-saved even when undirtied + a full backup starts;
  gate backup on a minimum interval.

### 9. Build pipeline (MEDIUM, build-time)
- `android/gradle.properties`: `kotlin.incremental=false`; `org.gradle.parallel` and
  `org.gradle.caching` unset (AGENTS.md lists them as optional). Enable all three
  (configuration-cache is riskier — trial separately).

## Deferred (needs device / Play-track / release-build verification)

| Item | Win | Why deferred |
|---|---|---|
| Native AES-128-CBC in the existing CMake lib | ~10–30× decrypt | Only worth it after #2; needs KAT tests + profiling |
| Font subsetting (Inter/JetBrainsMono) | ~355 KB | `pyftsubset` available; visual fallback risk for user-content filenames |
| `extractNativeLibs=false` | ~24 MB storage | Needs Play internal-track test that FFmpeg/torrent/mpv still load |
| Drop non-NEON armv7 FFmpeg set | ~11 MB | Needs armv7 device smoke test |
| Remove okhttp/media3 R8 keeps | ~1–2 MB dex | Needs release build + device smoke |
| `libc++_shared.so` dedup in `:ffmpeg` | ~1.2 MB | Needs on-device FFmpeg load test |
| AdBlock cold-start defer | TTFF + battery | First page may briefly show ads |
| Per-card ValueListenableBuilder refactor | >95% queue rebuild reduction | Large UI change; needs manual QA |

## Verification notes
- Debug Play AAB rebuild is the structural gate: `flutter build appbundle --debug
  --dart-define=AURORA_BUILD_CHANNEL=play` (~1.5–6 min) compiles Dart + Kotlin + C++ and
  validates ABI/packaging.
- A release AAB (`~5–10 min`, R8 re-runs every time) is required to validate R8 changes.
  The first release build after the R8/ABI changes failed bundletool validation with
  "Module 'ffmpeg' has no dex files but hasCode is not false" — fixed by declaring
  `android:hasCode="false"` in the `:ffmpeg` / `:torrent` / `:mediakit` module manifests
  (all three are pure-native modules; the plugin classes live in the base). The release
  AAB (108.6 MB) now builds green with the narrowed ProGuard rules.
- Runtime behavior (downloads, decryption, FFmpeg module loading) needs a device.

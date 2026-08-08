# Aurora Downloader — Optimization Research (2026-08-07)

Branch: `optimize-perf-size` · Baseline: release AAB 109,955,061 bytes (~110 MB), built
2026-08-07 from commit fcee528.

Method: measured the release AAB directly (zip contents, per-module/per-ABI), read the
download engine, HLS pipeline, queue UI, FFmpeg feature surface and Gradle config myself,
and cross-checked against 2 parallel audit subagents. The 2026-08-03 audit
(`performance_optimization_findings.md`) was re-verified against the current tree; its
"still open" and "deferred" items were re-measured.

## 1. Measured baseline (verified, not estimated)

Release AAB (110 MB zip) breaks down uncompressed as:

| Module | Zip MB | What's inside (arm64 sizes) |
|---|---|---|
| BUNDLE-METADATA | ~46 MB zip / 121 MB raw | debug symbols (.sym) + proguard.map — **upload-only, never installed** |
| base | 57.3 | libflutter.so 11.1 MB + libapp.so 9.8 MB + dex 9.8 MB + assets ~1.8 MB + res 0.9 MB + libc++_shared 1.2 MB + libaurora_adblock 1.0 MB + libdartjni 0.1 MB |
| ffmpeg | 54.7 | libavcodec 11.2 MB, libavfilter 3.0, libavformat 2.1, swscale 0.5, avutil 0.5, swresample 0.1, avdevice 0.1, ffmpegkit 0.4, c++_shared 1.2 (arm64); **armeabi-v7a duplicates every lib as plain + `_neon`** |
| mediakit | 23.6 | libmpv 11.8 MB + helper 0.4 MB per ABI |
| torrent | 19.6 | liblibtorrent_flutter 11.7 MB (arm64) / 7.9 (v7a) |

Per-device reality (what Play delivers to an arm64 phone):
- Initial install (base module only): ~23 MB compressed / ~33 MB uncompressed.
- On-demand: ffmpeg module ~18.5 MB, mediakit ~12 MB, torrent ~12 MB — only downloaded
  when the user first opens FFmpeg Studio (Ultra), picks the libmpv player, or starts a
  torrent. The on-demand split is already doing its job: a typical user's *actual* app
  size is the base alone.

Notable: no `icudtl.dat` in this Flutter beta (3.46) — nothing to trim there. R8
minify + resource shrinking + obfuscation + split-debug-info + ABI filters
(arm64-v8a/armeabi-v7a only) are all already on. Tree-shaken Material icons (38 KB otf).

## 2. Size findings (ranked)

### S1. Inter variable font — subset it (EASY, ~0.55 MB in every install)
`assets/fonts/Inter.ttf` = 876,576 bytes, **variable font** (fvar/gvar/STAT/HVART/MVAR
tables present; 2,933 glyphs; wght axis drives the 6 weights the app uses — w400..w800,
175 call sites). It ships in the **base module**, so every install pays for it.
A Latin/Greek/Cyrillic subset keeps the wght axis via `pyftsubset
--flavor=woff2`-style glyph pruning; realistic result 250–350 KB. Missing glyphs (e.g.
CJK in user-content filenames) fall back to system fonts automatically — Flutter always
falls back. The 2026-08-03 audit estimated ~355 KB saved; my measurement of the file
says ~520–600 KB compressed in-AAB. Low risk; verify visually on device. JetBrainsMono
(187 KB) — optional, same treatment.

### S2. Drop armeabi-v7a (DECISION, ~50% of upload + CI, ~38 MB uncompressed)
minSdk 24. In 2026 the armv7 device share is ~1–2%. Dropping v7a from `abiFilters`:
- AAB upload shrinks ~110 → ~72 MB (upload + Play Console storage + review time).
- CI build time drops (one ABI to compile/strip).
- **Per-device download for arm64 users is unchanged** (they already get only arm64
  splits) — this is an upload/ops win, not a user-facing size win. Play Console's
  "app size" metric for the 98% arm64 audience won't move.
- v7a users lose the app. Bundletool keeps serving v7a only if the ABI is in the AAB.
Decision needed: acceptable coverage loss? (The `_neon` duplication in the ffmpeg
module only exists for v7a — dropping v7a also kills that 19 MB of duplicate libs.)

### S3. ffmpeg module — trim to the 5 ops actually used (MEDIUM-HIGH effort, ~8 MB/ABI)
Full feature surface (read `lib/premium/ffmpeg/ffmpeg_ops.dart`):
compress (libx264+aac+faststart), trim (stream copy), audio extract
(libmp3lame|aac), remux (copy), gif (fps/scale/palettegen/paletteuse). The bundled
ffmpeg-kit-min-gpl 2.2.2 AAR (com.antonkarpenko fork, found in the Gradle cache) ships
the **entire** ffmpeg — hundreds of codecs/muxers/filters, 11.2 MB libavcodec alone.
A custom ffmpeg-kit build with ~30 components (h264/hevc/vp8/9/av1 decoders, mp4/mkv/ts
demuxers, x264/aac/mp3/gif encoders, the 6 filters) lands ~3–4 MB libavcodec.
Impact is **on-demand-only** (Ultra FFmpeg Studio users). High effort: Android build
env for 2 ABIs, GPL obligations unchanged, Play module re-test. Worth scoping, not
worth doing before S1/S2.

### S4. mediakit module — user-selectable feature, keep (INFO)
libmpv is a deliberate second player ("System (ExoPlayer)" vs "libmpv" is a user
setting, `engine_factory.dart`). 12 MB/ABI, on-demand. Nothing to trim without
rebuilding mpv. Keep both players — removing one removes a user-facing setting.

### S5. torrent module — prebuilt, keep (INFO)
liblibtorrent_flutter 11.7 MB arm64 is a prebuilt GPL lib. Trimming means rebuilding
libtorrent without dht/encryption/etc. — very high effort for an on-demand module.

### S6. Dead dependencies (EASY cleanup, ~0 MB AAB impact)
`qr_flutter`, `animations`, `dynamic_color` are direct deps with **zero** imports in
lib/ or test/ (verified by package-import and class-name grep). Dart AOT tree-shakes
unused code, so removing them does not shrink the AAB — but it cuts pub resolution,
lock churn and maintenance. Clean them up.

### S7. BUNDLE-METADATA inflates the upload (INFO — keep)
`.sym` debug symbols (121 MB raw) + proguard.map (37.6 MB compressed!) ride in the AAB
for Play crash de-obfuscation. They are never installed. The proguard.map at 37.6 MB
compressed is unusually large — AGP 8.9 + R8 output. No action: dropping
`--obfuscate`/`--split-debug-info` would shrink the upload but destroy crash
de-obfuscation. (If upload size ever matters more, the map can be uploaded separately
via Play Console's mapping-file upload — the .sym files are the only part that must
ride in the AAB.)

### S8. Broad R8 keeps on gms/okhttp/media3 (MEDIUM, ~1–2 MB dex, deferred)
`proguard-rules.pro` keeps `com.google.android.gms.** { *; }`, `okhttp3.** { *; }`,
`androidx.media3.** { *; }`, `com.google.api.** { *; }` wholesale — each blocks R8 from
shrinking those trees. The 2026-08-03 audit flagged this (~1–2 MB dex); still open.
Narrowing is fiddly (google_sign_in + billing + media3 audioExtract use reflection-ish
paths) — must be validated by a release build + device smoke of sign-in, billing and
audio-extract. Low priority vs S1/S2.

## 3. Performance findings (ranked)

### P1. Full queue list rebuilds at ~2 Hz during downloads (MEDIUM)
Verified chain: `download_splitter.dart:480` — per-download `Timer.periodic(250 ms)`
calls `_emitTask()` every tick → `download_queue.dart:1931 _emitTask` re-emits to the
UI stream → `queue_page.dart:162` listener → 500 ms-throttled `setState` → full
`QueuePage.build()` → **every visible `DownloadCard` rebuilds** (each card is a
1,063-line build incl. `IntrinsicHeight` at `download_card.dart:376`, which forces two
layout passes per card). With 3 concurrent downloads: 12 engine emits/s, ~2 full-list
rebuilds/s. The list itself is lazy (`SliverChildBuilderDelegate`) and the
filter/sort is fingerprint-cached, so the cost is the per-card build + layout, not
O(n²). On low-end devices with 20+ cards this is the top jank vector during downloads.
Fixes, easiest first: (a) drop the splitter emit rate to 500 ms (speed display is
already quantized; the 250 ms timer exists for the stall watchdog, which can stay —
only the emit cadence needs to drop), (b) wrap each card's progress-dependent
subtree (progress bar + speed + ETA text) in a `ValueListenableBuilder` on a
per-task progress notifier so a tick rebuilds ~5 widgets instead of 1,063, (c) drop
`IntrinsicHeight` (replace with fixed min-height Row or `Row(crossAxisAlignment)` +
explicit sizing — the checkbox column makes it needed, but a `ConstrainedBox` +
`Align` pattern usually removes the double-pass). The 2026-08-03 audit's "per-card
ValueListenableBuilder refactor" is still the right end state (~95% rebuild reduction).

### P2. Shell 500 ms rebuild while queue tab is active (SMALL, partially fixed)
`main.dart:496` — `_queueRebuildTimer` setState on the whole shell. Already gated to
"queue tab visible or never visited" (the 2026-08-03 finding that it rebuilds hidden
tabs is fixed). Remaining cost: the shell rebuild still re-runs `QueuePage.build()`
(which the queue page's own 500 ms timer does anyway) — i.e. it doubles the rebuild
rate to effectively 2×2 Hz. Removing the shell timer (the dock badge can listen to a
`ValueNotifier<int>` of active-task count) removes the doubling.

### P3. HLS emit storm is already throttled downstream (VERIFIED OK)
`hls_downloader.dart` emits on every status change (12+ call sites). The queue's
save debounce (1 s), the foreground-service sync (200 ms coalesce + 1 s notification
gate, `download_queue.dart:2008`) and the queue-page rebuild throttle all protect the
hot paths. The comment "200+ state changes per second" refers to worst case; the
throttles hold. No change needed — but keep the 1 s save debounce + 5 s periodic
flush (already in place; the 2026-08-03 durability gap is fixed).

### P4. Sync I/O surface is small and isolated (VERIFIED OK)
`listSync`/`readAsStringSync` sites: `unified_backup_database.dart:173` (backup
restore, background service), `hls_downloader.dart:1999` (resume scan — already
wrapped in `Isolate.run` per the 2026-08-03 fix), `vault_service.dart` (2 sites, vault
listing on demand), `phase2_caps.dart:77` (vault count). All are user-triggered or
background, none in build()/paint. Isolate usage is exemplary (`file_combiner`,
`hls_decrypt_pool` persistent workers, backup DB JSON on `Isolate.run`).

### P5. Player progress rebuilds (SMALL, from 2026-08-03 §6, still open)
`aurora_video_player.dart` controller listener setState at up to 10×/s for the whole
player; only the progress bar + clock change. Wrap in
`ValueListenableBuilder<VideoPlayerValue>`. Same for `media_preview_widget.dart`.

### P6. AdBlock cold-start defer (SMALL, from deferred list)
Native adblock engine init happens on first blocking call (`ad_block_engine_native.dart`
— already lazy) but parse is on `Isolate.run`. Verified the FFI shouldBlock calls are
synchronous trie lookups (microseconds) — fine on the UI thread. The deferred "load
rules off the first frame" item remains: worth a look, small win, needs care (first
page may briefly show ads).

### P7. Watcher / automation cadence (VERIFIED OK)
5-min poll with 30 s per-check cap, automation rate-limited to 10 s windows — sane.

## 4. Deferred-list re-verification (2026-08-03 → 2026-08-07)

| Item (2026-08-03) | Status today |
|---|---|
| Logging subsystem | Removed 2026-08-05 (archive/) — done |
| HLS decrypt buffer/CBC reuse | Fixed (hls_decryptor.dart) — done |
| Queue persistence spin + durability | Fixed (`_saveChain` + 5 s flush) — done |
| Decrypt pool sizing | Fixed — done |
| Queue status line O(n) scans + re-sort | Fixed (fingerprint cache) — done |
| HLS resume scan off-isolate | Fixed — done |
| Shell 500 ms rebuild | **Partially** — tab-gated now, still doubles rebuilds on queue tab (P2) |
| Font subsetting | **Open** (S1) |
| Native AES-128-CBC in CMake lib | **Open** — 10–30× decrypt speedup, but HLS decrypt is now on persistent workers; bottleneck shifted. Re-profile before doing it |
| extractNativeLibs=false | Done (AndroidManifest.xml:23) |
| Drop non-NEON armv7 ffmpeg set | **Open** — moot if S2 (drop v7a) is taken; else ~11 MB, needs armv7 smoke test |
| okhttp/media3 R8 keeps | **Open** — media3 is genuinely used (audioExtract); okhttp used by native engine. Re-audit keeps, low priority |
| libc++_shared dedup in :ffmpeg | **Open** — ~1.2 MB, needs on-device FFmpeg load test |
| Per-card ValueListenableBuilder | **Open** (P1b) |

## 5. Verdict / recommended order

Do first (this batch):
1. **S1** Inter subset — one tooling script + rebuild, ~0.5 MB off every install. 
2. **P1b + P2** queue rebuild reduction — per-card progress notifier + shell timer
   removal (dock badge via ValueNotifier). Biggest UI-jank win.
3. **S6** drop the 3 dead deps.

Decide (product call):
4. **S2** drop armeabi-v7a — halves upload/CI; per-device size unchanged; ~1–2% of
   devices lose support. If yes, S3's v7a _neon duplication disappears too.

Scope later:
5. **S3** custom ffmpeg-kit build (~8 MB on-demand saving) — only after S2 decision;
   measure actual on-device FFmpeg Studio usage first.
6. **P5** player progress ValueListenableBuilder — small, safe.

Not worth it: S4/S5 (deliberate features), S7 (required for crash de-obfuscation).

## Verification steps used
- `unzip -l` on the release AAB; per-module and per-ABI byte accounting.
- Font table inspection via Python struct parse (fvar/gvar/STAT present = variable).
- `grep -rln "package:X"` for dependency usage; class-name grep as cross-check.
- Read: `download_splitter.dart` (emit + write hot path), `download_queue.dart`
  (throttles), `hls_downloader.dart` (worker pool), `queue_page.dart` +
  `download_card.dart` (rebuild path), `ffmpeg_ops.dart` (full FFmpeg surface),
  `engine_factory.dart` (player choice), Gradle configs (R8/ABI/modules).

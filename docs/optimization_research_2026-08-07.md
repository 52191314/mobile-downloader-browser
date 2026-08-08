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

---

## 6. Round-2 cross-check (2026-08-08) — perf audit subagent findings, all verified

The parallel performance audit (task-0) landed 10 findings; I re-read the cited code
for each. **Confirmed and added to the list** (new, not in §3):

### P8. Unthrottled notification `show()` per queue tick — VERIFIED, top perf bug
`download_notification_service.dart:265-317` — `_onTaskUpdated` → `_updateProgressNotification`
calls `_plugin.show(...)` **unconditionally** on every `downloading` event. The queue
emits every 250 ms per active splitter (`download_splitter.dart:480-549`), and per HLS
segment. 3 concurrent downloads = ~12 full platform-channel/Binder round trips/sec,
each building a fresh `AndroidNotificationDetails`, on the UI isolate. The comment at
:293 even documents the chronometer reset workaround for this re-show. The downstream
throttles (queue save 1 s, fg-service 200 ms, UI rebuild 500 ms) do **not** gate this
path — it is the one unthrottled hot path in the whole pipeline.
Fix: in `_updateProgressNotification`, skip `show()` unless ≥1 s elapsed AND progress
changed ≥1 point (keep exact updates for terminal states). Low risk, immediate win.

### P9. Flat-mode queue sort/search runs per rebuild — VERIFIED
`queue_page.dart:311-326 _computeFilteredTasks()` calls `queryTasks(...)` (full
materialize + O(n log n) sort, and O(tasks×tokens) lower/contains scans when searching)
on **every** `build()` — the sectioned-mode fingerprint cache does NOT cover flat mode.
Runs at ~2 Hz during downloads, plus each shell rebuild.
Fix: cache the flat-mode filtered list on the same fingerprint (`queue_page.dart:465-503`
pattern); pure progress ticks already mutate in place and are excluded from the
fingerprint. Medium risk (sorting correctness on state changes — cover with the
existing fingerprint invalidation paths).

### P10. Vault encrypt/decrypt = whole-file 3× memory copies on UI isolate — VERIFIED, OOM class
`vault_service.dart:248-266` — `source.readAsBytes()` (full file) → `encryptBytes`
(full ciphertext) → `Uint8List.fromList([...nonce.bytes, ...encrypted.bytes])` (3rd
copy), all on the UI isolate; export path :299 and `vault_sync_service.dart:196` the
same. A multi-GB video → multi-GB RSS spike → OOM kill (this is a Pro feature — the
worst user-visible failure mode). Fix: chunked stream encrypt (`openRead` →
`openWrite`, per-chunk AES-GCM with the 12-byte nonce + counter), whole pass in
`Isolate.run`. Medium risk (GCM chunk semantics — keep the v1 format for the first
chunk; add KAT tests).

### P11. Per-chunk `length()` watchdog poll + O(n) re-sum — VERIFIED (native-chunk path)
`download_splitter.dart:915-940` — per-chunk `Timer.periodic(500 ms)` stat-poll of
`chunkFile.length()` on the UI isolate (native download path only), plus the 250 ms
speed timer re-summing all chunks (`:1538-1546`). Up to 32 chunks × tasks = dozens of
async stats/sec. Fix: use the byte deltas already tracked in the stream listener
(`:1266-1268`) and let `NativeDownloadClient` report progress via callback; drop the
stat loop (stall detection can use the native callback or a single background sampler).

### P12. Player 1 Hz full-tree setState — VERIFIED (already reduced from 10 Hz)
`aurora_video_player.dart:199-201` — `Timer.periodic(1 s)` → `setState` on the whole
player for the entire playback session; only the clock changes. Wrap the clock in a
`ValueListenableBuilder<Duration>`. Small, safe.

### P13. Minor items — VERIFIED / plausible
- `main.dart:423` `_prevTaskStates` map never pruned (slow leak, cap/evict).
- UI-thread sync I/O: `vault_page.dart:224,347` `existsSync`, `filename_service.dart:476`
  `existsSync` per uniqueness candidate, `vault_service.dart:220-229` / `phase2_caps.dart:77`
  `listSync` — all user-triggered; convert to async or bulk off-isolate.
- `settings_page.dart:257,535,848,939,1096` — `ListView(children:)` of the 6k-line
  page; rebuilds the whole tree on each toggle. `ListView.builder`/const tiles.
- `media_binary_parsers.dart:203,234,343` + `media_enricher.dart` — byte-scan parsers
  on the UI isolate at sniff time; `sniffer_screen.dart:2164,2207` jsonDecode of
  JS-bridge payloads on the UI thread. Move to the existing `WorkerIsolatePool`.
- `hls_downloader.dart:1429,1496,1536,1601` — per-segment emits uncoalesced at source
  (the "200+/sec" input to P8); coalesce to one emit per 500 ms per task.

### Updated top-5 for the next implementation batch
1. **P8** notification throttle (1 s + ≥1% gate) — kills the biggest unthrottled channel flood.
2. **P1b/P2** per-card progress notifier + shell timer removal — the UI rebuild win.
3. **P9** flat-mode filter/sort cache — removes O(n log n) per tick.
4. **P10** vault chunked + isolate encrypt/decrypt — kills the OOM class bug.
5. **P11** watchdog deltas + callback progress — removes per-chunk stat churn.

## 7. Implementation status (2026-08-08, branch `optimize-perf-size`)

Batch 1 implemented and verified (flutter analyze clean on touched files, 453 tests
green, debug play AAB builds):

| Item | What landed | Verification |
|---|---|---|
| P8 | Notification `show()` throttled: ≥1 s AND ≥1% progress gate per task (`download_notification_service.dart`); throttle map cleared on cancel/dispose | analyze + tests |
| S6 | `qr_flutter`, `animations`, `dynamic_color` removed from pubspec (+4 packages incl. transitive `qr`) | pub get clean |
| S1 | `assets/fonts/Inter-subset.ttf` — variable font subset (Latin/ext/Greek/Cyrillic + UI symbol ranges, wght 100-900 kept, opsz pinned 14, tnum kept for the player clocks): 876 KB → 373 KB. Tooling: `tooling/subset_inter_font.sh` + `tooling/check_font_subset.py` | fontTools checks PASS (glyph coverage vs original, wght axis, all app special chars) |
| P2 | Shell 500 ms `_queueRebuildTimer` removed (`main.dart`) — QueuePage self-throttles, dock badge is notifier-driven; also pruned the `_prevTaskStates` leak (P13) | analyze |
| P10 | New `lib/premium/vault_crypto.dart`: streaming AES-256-GCM (pointycastle `processBytes`/`doFinal`, 1 MiB chunks) — **byte-identical** to the old one-shot path. Vault store/export stream in `Isolate.run` (tmp-file + rename); sync upload/restore stream through chunked base64 + `StreamedRequest`. Legacy CBC export kept | 13 new tests incl. byte-compat both directions, tamper/wrong-key rejection, odd chunk sizes; legacy test still green |
| P1b | Per-task `ValueNotifier` on the queue (deduped no-op ticks) + `queueVersion` for the header; queue page rebuilds only on state transitions (speed-sort exception); `DownloadCard` live section (progress bar/percent/bytes/speed/ETA/status) rebuilt via `ValueListenableBuilder` | analyze + full suite |

Not in this batch: S2 (drop armeabi-v7a — product decision), S3 (custom ffmpeg-kit),
S8 (R8 keep narrowing), P9 (flat-mode filter/sort cache — deferred, needs the same
fingerprint machinery re-audit), P11 (native-chunk watchdog), P12 (player 1 Hz clock).

## 8. 16 KB page-size audit (2026-08-08) — ELF32 aligner bug found and fixed

Follow-up on the user question "does the 16 KB alignment work in theory?" —
the theory holds (see below), but a real bug was found in the tooling while
re-verifying:

**The bug (fixed in de1f9bf):** `tooling/align_elf_16k.py` parsed program
headers with the ELF64 field order for both ELF classes. ELF32 phdrs are
`(p_type, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_flags, p_align)` —
no `p_flags` gap — so for 32-bit libs:
- padding was computed from `(p_paddr - p_vaddr) % 0x4000` = always 0 → no
  inter-segment padding inserted;
- the "already 16 KB aligned" gate compared `p_paddr - p_vaddr` → always
  true for any file whose `p_align` was already ≥ 0x4000.

The vendored + pub-cache `armeabi-v7a` libtorrent prebuilt was exactly that
artifact: `p_align = 0x4000` but `(p_vaddr - p_offset) % 0x4000` =
0x1000/0x2000/0x3000 (4 KB-congruent only) — the naive p_align-bump failure
mode the script's own docstring warns about (passes Play's static check,
breaks on real 16 KB devices). It would have been packaged into the next
AAB (extractTorrentJni always re-runs from the package dir).

**What the shipped AABs contain:** both the release AAB (2026-08-07) and the
debug AAB (2026-08-08) carry the correctly aligned v7a (byte-congruent,
verified via llvm-readelf + independent ELF parse) — they packaged from the
Gradle transform cache, which held the good file. No shipped artifact was
affected.

**Fix + verification:** per-class `P_OFF`/`P_VADDR`/`p_filesz` indices
threaded through the aligner; `prepare_torrent_16k.sh` re-run — v7a now
gets +12288 bytes of padding and every PT_LOAD of both ABIs satisfies
`(p_vaddr - p_offset) % 0x4000 == 0` with `p_align = 0x4000`. Verified with
13 ad-hoc checks (synthetic ELF32 4 KB + naive-bump fixtures, ELF64
regression, idempotency, real vendored libs) plus llvm-readelf on the
artifacts. AGENTS.md's verify snippet now covers BOTH ABIs and the
congruence column, not just arm64 p_align.

**The theory, stated precisely** (why the fix is correct): the Android
linker maps each PT_LOAD with `mmap(load_bias + page_start(p_vaddr),
MAP_FIXED, fd, page_start(p_offset))`; the kernel requires
`(addr - offset) % PAGE_SIZE == 0`. On 16 KB-page devices that means
`page_start(p_vaddr) ≡ page_start(p_offset) (mod 0x4000)` — which the
byte-level `(p_vaddr - p_offset) % 0x4000 == 0` invariant implies. Virtual
addresses are never changed by the aligner, so no relocations, symbols, or
.dynamic entries move; only file offsets shift (loaders map segments
independently). 16 KB alignment is a superset of 4 KB, so aligned libs also
work on current 4 KB devices. The one thing not exercised is a live
16 KB-page device (Pixel with 16 KB mode / emulator) — no such device is
available in this environment; static + structural verification is complete.

## Verification steps used
- `unzip -l` on the release AAB; per-module and per-ABI byte accounting.
- Font table inspection via Python struct parse (fvar/gvar/STAT present = variable).
- `grep -rln "package:X"` for dependency usage; class-name grep as cross-check.
- Read: `download_splitter.dart` (emit + write hot path), `download_queue.dart`
  (throttles), `hls_downloader.dart` (worker pool), `queue_page.dart` +
  `download_card.dart` (rebuild path), `ffmpeg_ops.dart` (full FFmpeg surface),
  `engine_factory.dart` (player choice), Gradle configs (R8/ABI/modules).

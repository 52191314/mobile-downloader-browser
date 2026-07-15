# Aurora Downloader — Completeness & Refinement Audit + Remediation Plan

> Generated: 2026-07-14
> Mode: Read-only audit performed; remediation plan below is for the execution phase.
> Spec basis: The 5 features explicitly named by the user (HLS variant downloading, Torrent support, Segmented splitting, Native Adblocking, Log Server). The original spec files (`.agents/ORIGINAL_REQUEST.md`, `docs/code-maps/`) are **absent** from this repo and were not available; the 5 named features were used as the spec per user direction.

---

## 1. Fully Completed Features

- **Segmented Splitting (`DownloadSplitter`)** — fully implemented: parallel Range-based chunk downloads (default 8, configurable 1–16), resume via `meta.json`, 429/403/401 handling, SHA-256 verify, stall detection + partial salvage.
- **Native Adblocking** — implemented: C++ engine (domain trie + Aho-Corasick + regex) compiled into `libaurora_adblock.so`; Dart FFI auto-detects and falls back to Dart rule matching. Active by default.
- **HLS Variant Downloading (core pipeline)** — implemented: master playlist resolution, variant selection (highest bandwidth), concurrent `.ts` download + AES-128 decrypt + merge + TS→MP4 remux, token refresh via WebView.
- **Torrent (metadata + native engine)** — `.torrent`/magnet parsing, bencode decoder, and native `libtorrent_flutter` integration all present and functional *when enabled*.

## 2. Incomplete / Missing Specs (or TODOs)

- **Log Server — MISSING.** No `HttpServer`/port/log-serving endpoint anywhere in `lib/`. Only `DownloadLogger` (file-based JSON ring buffer, max 500 entries at `lib/downloader/download_logger.dart`). If a log server was in the original spec, it is not built.
- **Torrent — Partial (not working out-of-the-box).** Native engine defaults **OFF** (`useNativeTorrentEngine = false` in `download_queue.dart`); the Dart fallback `_tick()` is **synthetic** (generates fake bytes — no real BitTorrent wire protocol / peer discovery). Real torrents only happen if the user enables the native engine, and there is **no UI toggle** to do so.
- **HLS — no user variant/quality picker.** Auto-selects highest bandwidth; no `MediaType.hls` (uses `playlist`); no SAMPLE-AES/Widevine.
- **Native Adblock — cosmetic element hiding is Dart-only** (native `shouldHideElement` exists but is never called from `ad_block_engine_native.dart`).
- **Literal TODO/FIXME markers:** none real in `lib/`. Only benign "placeholder" comments (lazy WebView placeholders in `sniffer_screen.dart`/`browser_widget.dart`, DASH segment-templating "intentionally not implemented" in `dash_playlist_parser.dart`, form-fill aliases in `browser_controller.dart`). The real gaps above are **silent** (unmarked).
- **Docs missing:** `docs/code-maps/projects/aurora_downloader.md` and `docs/sessions/` were never created (AGENTS.md requires them).

## 3. Performance & Refinement Recommendations

### High severity (concurrency races on shared mutable state)
- **A1** `lib/sniffer/media_enricher.dart:906-957` — `enrich()` looks up an index then writes `host.mutableDetectedMedia[index]`; up to 3 concurrent `enrich()` calls can `add`/`removeAt`, invalidating the index → wrong overwrites / `RangeError`. Fix: key by URL or serialize writes.
- **C1** `lib/downloader/hls_downloader.dart:688-691` — concurrent segment workers do `task.downloadedBytes +=` / `task.totalBytes +=`; event-loop interleaving can lose updates. Fix: accumulate per-worker, merge after `Future.wait`.
- **C2** `lib/downloader/download_splitter.dart:599-654` — concurrent chunks mutate shared `_subscriptions`/`_sinks`/`_completers`; `pause()` copies lists during concurrent `remove` → `IndexError`/missing elements. Fix: per-chunk state with unique keys.

### Medium severity
- **A2** `lib/sniffer/browser_guard_installer.dart:75-81` — non-active tab `_guardRefreshTimer` (20s) never cancelled on freeze → leaks forever. Cancel in `freeze()`, restart in `thaw()`.
- **A3** `lib/sniffer/browser_controller.dart:480-497` — non-active tab `_loadResourceTimer` (2s) leaks on freeze. Same fix.
- **C3** `lib/downloader/download_splitter.dart:770-797` — `_handleStall` completes completers while streams still active → sink races. Cancel subs first, then complete.
- **C7** `lib/downloader/hls_downloader.dart:732-735` — non-403 error path throws without draining response stream → HTTP connection leak. Drain before throw on all paths.
- **C8** `lib/downloader/hls_downloader.dart:759-767` — `break` on pause abandons stream subscription without draining → leak. Cancel subscription before break.

### Low severity
- **A4** `lib/sniffer/sniffer_screen.dart:1348` — `saveTabs()` on every page finish, no debounce → redundant writes. Debounce 3s (mirror `scheduleMediaSave`).
- **B3** `lib/sniffer/webview_fetch_delegate.dart:397-411` — binary segments base64-encoded (3× memory) for JS↔Dart transfer. Stream/chunk on low-end devices (add TODO).
- **C6** `lib/downloader/hls_downloader.dart:276-288` — HEAD probe response stream not drained on error.

### Headless WebView bypass (step 3) — verified OK
`media_enricher.dart` does **not** create headless WebViews; the WAF/bypass is pure JS XHR executed in the existing visible WebView via `evaluateJavascript`. No extra lifecycle → no freezing from that path. Design is sound (only the B3 memory note applies).

## 4. Git / Repository Audit

- Active branch `ui/redesign-2.0` (matches remote `origin/ui/redesign-2.0`). Single author, linear history, **no merge commits, no tags**.
- Recent commits use conventional commits (`feat:`/`fix:`/`refactor:`/`chore:`) — consistent. AGENTS.md defines **no** git commit format, so no compliance violation.
- **Working tree is dirty**: 29 modified files + new `lib/backup/`, `lib/ui/animations/`, `lib/ui/notifications/`, `assets/fonts/`, and `lib/ui/widgets/edge_swipe_card.dart`. These are the uncommitted UI-redesign + Auto-Backup changes from prior sessions.
- Anomaly: catch-all commit `1991137` added 30 files at once; `2edfe31` bundles 3 concerns. Recommend smaller scoped commits going forward.

---

# Execution Plan — Remediation

**Preconditions:** Build is already green (`app-debug.apk` built & installed). Keep all builds in **debug** mode per AGENTS.md. Re-run `flutter build apk --debug --target-platform android-arm64` after each phase as the verification gate.

**Agent assignment:** High-severity concurrency fixes → **MiniMax M3** (subtle Dart async race reasoning). Medium/Low fixes, Playwright harness, and docs → **DeepSeek v4 Flash**.

## Phase 1 — High-severity concurrency fixes (MiniMax M3)
1. **A1 `media_enricher.dart:906-957`** — Replace index-based write with a URL-keyed map (or a mutex/serial queue) so concurrent `enrich()` calls (max 3) can't invalidate indices. Verify: no `RangeError` under concurrent enrichment; unit test with 3 parallel `enrich()` calls on overlapping hosts.
2. **C1 `hls_downloader.dart:688-691`** — Accumulate per-worker local byte counters, merge into `task` once after `Future.wait`. Verify: downloaded byte count matches sum of segment sizes exactly.
3. **C2 `download_splitter.dart:599-654`** — Give each chunk its own state object keyed by index; make `pause()` snapshot under a guard. Verify: `pause()`/`resume()` under 8 parallel chunks doesn't throw `IndexError` or drop chunks.

## Phase 2 — Medium/Low fixes (DeepSeek v4 Flash)
4. **A2 `browser_guard_installer.dart:75-81`** — cancel `_guardRefreshTimer` in `freeze()`, restart in `thaw()`.
5. **A3 `browser_controller.dart:480-497`** — cancel `_loadResourceTimer` in `freeze()`; reschedule in `thaw()`.
6. **C3 `download_splitter.dart:770-797`** — in `_handleStall`, cancel active subscriptions (drain) *before* completing completers.
7. **C7 `hls_downloader.dart:732-735`** — drain `response.stream` before throwing on all non-2xx error paths (not just 403/401).
8. **C8 `hls_downloader.dart:759-767`** — on pause `break`, cancel the stream subscription before leaving the `await for`.
9. **Low:** **A4** `sniffer_screen.dart:1348` debounce `saveTabs()` (3s); **C6** `hls_downloader.dart:276-288` drain HEAD probe stream on error; **B3** add a TODO comment for future streaming (leave behavior as-is).

## Phase 3 — Playwright verification (DeepSeek v4 Flash + Playwright)
10. **JS guard logic:** Extract the injected guard script from `browser_controller.dart` (`_installBrowserGuards`), load it in a Playwright-controlled headless page against test fixtures (`<video src>`, dynamic `HTMLMediaElement.prototype.src` setter, `fetch`/`XHR`, `MutationObserver` DOM injection). Assert the guard captures all media URLs and reports them via the expected callback.
11. **Dart poll + persistence:** Use `flutter test integration_test` (or drive the installed debug APK on the connected S22) to confirm (a) the 2s `evaluateJavaScript` poll retrieves `video.currentSrc`, and (b) browser tabs survive app restart (`browser_tabs.json`).
12. Report pass/fail per check.

## Phase 4 — Spec-gap decisions (confirm with user, then implement or document)
13. **Log Server** — missing. Confirm if it was in the original spec; if yes, add a minimal `HttpServer` serving `DownloadLogger` output; else document as known limitation.
14. **Torrent** — native engine defaults OFF + no UI toggle + synthetic Dart fallback. Confirm: add a Settings toggle and default native engine ON (where `libtorrent_flutter` prebuilt is present), or document the limitation.
15. **HLS picker** — confirm whether a user-facing quality/variant selector is required; if yes, add one (currently auto highest-bandwidth).

## Phase 5 — Docs (DeepSeek v4 Flash)
16. Create `docs/code-maps/projects/aurora_downloader.md` (architecture, key files, the 5 features' status) and a `docs/sessions/` entry logging this audit + command. AGENTS.md requires this.

## Phase 6 — Commit hygiene
17. Commit the 29 currently-dirty files + the fixes in **scoped** commits (UI redesign, Auto-Backup, audit fixes separately). Add a release tag. Avoid the prior catch-all pattern.

## Verification gate (after every phase)
- `flutter build apk --debug --target-platform android-arm64` → must succeed with zero errors.
- For Phase 1/2: targeted unit/integration tests for the fixed race/leak paths.

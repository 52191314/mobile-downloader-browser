# Critique Remediation Plan

**Source:** [codebase_technical_critique.md](./codebase_technical_critique.md)  
**Created:** 2026-07-18  
**Last updated:** 2026-07-18  

Track implementation of every critique item. Update status checkboxes and the **Progress log** when work lands.

**Legend**

| Mark | Meaning |
|------|---------|
| `[x]` | Done (merged / landed in tree) |
| `[~]` | Partial / in progress |
| `[ ]` | Not started |
| `N/A` | Deferred by design (see notes) |

---

## Overall status

| # | Item | Status | Priority |
|---|------|--------|----------|
| 2 | UI thread / main isolate congestion | **Done** | High |
| 3 | `HlsDecryptor` AES / GC churn | **Done** | High |
| 4 | AdBlock FFI bridge allocation churn | **Done** | Medium |
| 6 | Simulated torrent / magnet hard-fail | **Done** | Critical |
| 1 | Monolithic `sniffer_screen.dart` | **Partial** (B1–B5 slices landed) | High |
| 5 | Fragile `browser_guard.js` overrides | **Done** (hardened) | Medium |

**Score:** 5 themes closed fully; §1 substantially reduced (B1–B5 extraction slices); residual shell still large.

---

## Phase A — Hot-path performance & correctness (DONE)

### A1. HLS decrypt AES reuse + isolate offload — `[x]`

- [x] Reuse one PKCS7 + one no-pad `Encrypter` per segment
- [x] Run `HlsDecryptor.decryptInPlace` via `Isolate.run`
- [x] Unit test: PKCS7 round-trip (`test/downloader/hls_decryptor_test.dart`)

### A2. SHA-256 off main isolate — `[x]`

- [x] `FileCombiner.combineAndHash` hashes on background isolate

### A3. AdBlock FFI scratch buffers — `[x]`

- [x] `_Utf8Scratch` for URL / host / request-type
- [x] Capped string cache for element-hide
- [x] Free in `destroy()`

### A4. Torrent hard-fail — `[x]`

- [x] Hard-fail without native engine → `nativeEngineUnavailable`
- [x] No production zero-fill mock
- [x] Synthetic path test-only
- [x] Defaults `useNativeEngine = true`
- [x] Unit tests (`test/downloader/torrent_hard_fail_test.dart`)

---

## Phase B — Monolith split: `sniffer_screen.dart` (PARTIAL)

**Baseline:** ~6837 lines → **~4840 lines** after B1–B5 residual (~2000 lines relocated).

### B1. Consolidate download headers / UA helpers — `[x]`

- [x] Expanded `lib/sniffer/sniffer_url_utils.dart`
- [x] Unit tests: `test/sniffer/sniffer_url_utils_test.dart`

### B2. Extract formatters / labels — `[x]`

- [x] `lib/sniffer/sniffer_formatters.dart`

### B3. Extract strict-redirect prompt — `[x]`

- [x] `lib/sniffer/sheets/strict_redirect_prompt.dart`

### B4. Extract picker cancel chip — `[x]`

- [x] `lib/sniffer/widgets/picker_cancel_chip.dart`

### B5. Follow-on extractions — `[x]` (residual also landed)

- [x] Library export/import UI + apply logic → `sheets/library_transfer_sheets.dart`, `library_transfer.dart`
- [x] Browser menu grid → `sheets/browser_menu_sheet.dart`
- [x] Playback quality helpers → `playback_quality.dart`
- [x] Floating player overlay → `widgets/floating_player_overlay.dart`
- [x] Favorites add/edit dialogs → `sheets/favorite_dialogs.dart`
- [x] Enqueue orchestration → `enqueue_download.dart` + duplicate dialog
- [x] Find-in-page bar → `widgets/find_in_page_bar.dart`
- [x] Phishing warning dialog → `sheets/phishing_warning_dialog.dart`
- [x] Capture sort → `capture_sort.dart`
- [x] Tests: `test/sniffer/library_transfer_test.dart`, `capture_sort_test.dart`
- [ ] Optional later: split `_setupTabCallbacks` / `build` into host shells — **see [sniffer_further_refactor_plan.md](./sniffer_further_refactor_plan.md)**

---

## Phase C — `browser_guard.js` hardening (DONE)

### C1. Safer `shouldInterceptRedirect` — `[x]`

- [x] User gesture → do not intercept (unless play-ad suppress)
- [x] Silent cross-origin still intercepted
- [x] Force intercept during play-ad suppress
- [x] Hash-only + same-origin + allow-next still respected

### C2. Auth / payment allowlist — `[x]`

- [x] Host suffix list (Google, Microsoft, Apple, FB, GitHub, Stripe/PayPal, IdPs)
- [x] Path hints: oauth / authorize / signin / sso / checkout / pay
- [x] Skip unless play-ad suppress armed

### C3. Cap script text scanning — `[x]`

- [x] `scanTextForUrls` truncates at 250k chars
- [x] Initial scan: max 40 inline scripts; skip oversized bodies
- [x] Existing match budget (100) retained

### C4. Location override hygiene — `[x]`

- [x] Only wrap when descriptor `configurable !== false`
- [x] Preserve `enumerable` where possible
- [x] try/catch retained; History API not overridden

### C5. Checks — `[x]`

- [x] Smoke checklist documented (below)
- [x] Analyzer: no new errors on touched Dart files
- [x] `flutter test test/downloader/` + `test/sniffer/sniffer_url_utils_test.dart`

**Smoke checklist**

| Scenario | Expected |
|----------|----------|
| Normal HTTPS site | Loads; no spurious prompts |
| Click external link with gesture | Allowed (not silent-ad block) |
| Silent `location.href` cross-origin | Still blocked / reported |
| Play-ad suppress window | Still suppressed |
| Heavy SPA inline scripts | Caps limit jank |
| OAuth host hop | Not blocked as invisible redirect |

---

## Phase D — Docs & verification

- [x] Critique doc linked to this plan
- [x] This plan updated for B1–B4 + C
- [x] Critique §1 / §5 status notes refreshed
- [x] Downloader + sniffer util tests green
- [ ] Optional: deeper UI integration tests for redirect prompt (manual smoke OK)

---

## Out of scope

| Item | Reason |
|------|--------|
| Full rewrite of `sniffer_screen` build | Multi-week; tracked under B5 |
| Platform-native AES | Separate crypto decision |
| Remove location intercept entirely | Defeats ad-redirect product goal |

---

## Progress log

| Date | Change |
|------|--------|
| 2026-07-18 | Phase A completed (HLS, SHA-256, AdBlock FFI, torrent hard-fail). |
| 2026-07-18 | Plan file created. |
| 2026-07-18 | Phase B1–B4: headers/formatters/redirect dialog/picker chip extracted; screen ~6837→~6043 lines. Phase C: browser_guard gesture/auth allowlist + scan caps + descriptor hygiene. Tests added/updated. |
| 2026-07-18 | Phase B5: library transfer + browser menu + playback quality + floating overlay extracted; screen ~5330 lines. |
| 2026-07-18 | B5 residual: favorite dialogs, enqueue orchestration, find bar, phishing/duplicate dialogs, capture sort; screen ~4840 lines. |

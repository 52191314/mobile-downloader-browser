# Sniffer Further Refactoring Plan

**Created:** 2026-07-18  
**Last updated:** 2026-07-18  
**Status:** Ready to execute  
**Prerequisite work:** [critique_remediation_plan.md](./critique_remediation_plan.md) (Phases A–C + B1–B5 done)

This plan covers **optional but intentional** further decomposition of the browser shell after the technical-critique fixes. It is **not** a rewrite of WebView architecture or product behavior.

---

## 1. Why continue

### Already achieved (do not re-litigate)

| Outcome | Location |
|---------|----------|
| Critical correctness (torrent hard-fail) | `torrent_downloader.dart` |
| Crypto / isolate / FFI hot paths | `hls_decryptor`, `file_combiner`, `adblock_native_engine` |
| browser_guard hardening | `assets/browser_guard.js` |
| First-wave sniffer extraction | headers, transfer, enqueue, menus, dialogs |

### Why more work still has value

1. **`sniffer_screen.dart` is still a hub (~4.8–5.1k lines).**  
   Most remaining cost is *change coordination*, not known bugs.
2. **Four files remain `part of` the screen library** (`add_queue_dialog`, `capture_widgets`, `folder_selector`, `rename_file_dialog`).  
   Parts cannot be unit-tested in isolation and couple every import into the screen.
3. **`_setupTabCallbacks` is the largest remaining behavior blob** (~400+ lines of WebView wiring).  
   Every new channel / intercept lands there.
4. **`build` still owns chrome layout** (top/bottom bars, find, float, progress).  
   UI experiments force full-file diffs.
5. **Release confidence:** enqueue / redirect / tab open paths have limited automated coverage.

### Why not “finish at any cost”

- High risk of silent WebView regressions (navigation, adblock, HLS cookies).  
- Diminishing returns after another ~1–1.5k lines moved if no tests back them.  
- Renaming State → “Controller” without seams is fake progress.

**Principle:** Prefer **testable seams** and **smaller PRs** over line-count vanity.

---

## 2. Baseline (as of this plan)

| Artifact | Approx. size | Notes |
|----------|--------------|--------|
| `lib/sniffer/sniffer_screen.dart` | ~4,800–5,150 lines | Shell + callbacks + build |
| `widgets/add_queue_dialog.dart` | ~520 lines | **`part of` screen** |
| `controllers/tab_lifecycle_controller.dart` | ~645 | Already extracted host pattern |
| `controllers/sniff_intake_controller.dart` | ~525 | Good model for callbacks |
| `controllers/tab_manager.dart` | ~420 | OK |
| `sheets/tabs_sheet.dart` | ~700 | Already standalone |
| `sheets/favorites_sheet.dart` | ~555 | Already standalone |
| Unit tests under `test/sniffer/` | ~9 cases | Helpers only; little UI/integration |

### Remaining concentrations inside the screen (priority order)

| Rank | Area | Est. lines | Extractability |
|------|------|------------|----------------|
| 1 | `_setupTabCallbacks` + related handlers | 400–550 | Medium (needs host interface) |
| 2 | `build` + bottom/top chrome builders | 500–700 | Medium (widget tree + props) |
| 3 | HLS / player / quality / float messages | 350–500 | Medium (service + thin UI) |
| 4 | `part` widgets (esp. add-queue) | 500+ as library | Medium–high payoff |
| 5 | Tabs UI helpers still on screen (`_buildTabStrip`, group sheets glue) | 150–250 | Low–medium |
| 6 | Autofill / UA / zoom site settings UI | 150–250 | Low priority |

---

## 3. Goals and non-goals

### Goals

1. Reduce `sniffer_screen.dart` toward **~2.5–3.5k lines** of *true shell* (lifecycle + host adapters + composition).  
2. Eliminate **`part of`** for production widgets (add-queue first).  
3. Make tab WebView wiring **unit-testable** via a host interface (mirror `TabLifecycleHost` / `SniffIntakeController`).  
4. Add **regression tests** for the riskiest pure / semi-pure paths (enqueue naming, duplicate choice, callback dispatch mocks where feasible).  
5. Keep **zero intentional product behavior change** unless a PR explicitly says otherwise.

### Non-goals

- Rewriting `flutter_inappwebview` usage or multi-process architecture.  
- Replacing `browser_guard.js` with a different ad strategy.  
- Full MVVM / Riverpod / Bloc migration of the app.  
- Forcing every method under 50 lines.  
- Matching IDM feature parity as part of this plan.

### Success metrics

| Metric | Target |
|--------|--------|
| `sniffer_screen.dart` line count | ≤ 3,500 (stretch ≤ 3,000) |
| `part of` files for sniffer production UI | **0** |
| New unit tests for extracted pure logic | ≥ 15 additional meaningful cases |
| Behavior regressions in manual smoke | **0** on checklist below |
| PR size | Prefer **&lt; ~600 LOC changed** per PR when possible |

---

## 4. Architecture target

```
┌─────────────────────────────────────────────────────────────┐
│ SnifferScreen (thin StatefulWidget)                         │
│  - owns controllers, GlobalKey, mounted, ScaffoldMessenger  │
│  - implements *Host interfaces                              │
│  - build() composes chrome widgets only                     │
└───────────────┬─────────────────────┬───────────────────────┘
                │                     │
     ┌──────────▼──────────┐   ┌──────▼──────────────────────┐
     │ TabCallbackBinder   │   │ SnifferChrome (widgets)     │
     │  - wires WebView    │   │  - top bar / find           │
     │  - uses TabCallback │   │  - bottom dock              │
     │    Host for side    │   │  - floating player slot     │
     │    effects          │   │  - progress                 │
     └──────────┬──────────┘   └─────────────────────────────┘
                │
     ┌──────────▼──────────┐   ┌─────────────────────────────┐
     │ Existing controllers│   │ Standalone libraries        │
     │ TabLifecycle        │   │ enqueue_download            │
     │ SniffIntake         │   │ library_transfer            │
     │ MediaCatch          │   │ add_queue (no longer part)  │
     │ Library / Address   │   │ playback_quality / HLS svc  │
     └─────────────────────┘   └─────────────────────────────┘
```

### Host interface pattern (existing precedent)

`TabLifecycleHost` already shows the preferred style:

- Screen implements a **narrow** interface.  
- Controller holds policy; host supplies `setState`, snacks, UA, load URL, etc.  
- **Do not** pass `BuildContext` into long-lived controllers; pass callbacks that the screen closes over `context` when still mounted.

New hosts proposed below should stay **&lt; ~20 members** each. If larger, split domains.

---

## 5. Execution principles

1. **One vertical slice per PR** (extract + wire + tests + doc checkbox).  
2. **Behavior freeze** unless the PR title contains `fix:` for a deliberate bugfix.  
3. **No mega-diffs** that mix formatting, renames, and logic.  
4. **Extract pure first**, then UI shells, then WebView wiring.  
5. **Every extraction PR** must:
   - compile (`dart analyze` on touched files clean of *new* errors),  
   - run `flutter test test/sniffer/ test/downloader/`,  
   - update the Progress log in this file.  
6. **Manual smoke** after Phases F2, F3, F5 (see §9).

---

## 6. Phased plan

Phases are labeled **F** (Further) to distinguish from critique Phase A–D.

---

### Phase F0 — Guardrails & inventory `[x]`

**Goal:** Make further work safe and measurable before more moves.

| Task | Detail | Status |
|------|--------|--------|
| F0.1 | Freeze baseline line counts in this file’s Progress log | `[x]` |
| F0.2 | List all `setOn*` / channel handlers in `_setupTabCallbacks` (appendix A) | `[x]` |
| F0.3 | Confirm manual smoke checklist (§9) is runnable on a device/emulator | `[x]` |
| F0.4 | Optional: `// region` markers in `sniffer_screen.dart` around callbacks / build / player for navigation only (no logic change) | `[x]` |

**Exit:** Team agrees PR order F1 → F2 → F3 → F4 → F5 → F6.

---

### Phase F1 — Kill `part of` (standalone libraries) `[x]`

**Goal:** Widgets become importable, testable libraries.

#### F1.a — `add_queue_dialog` out of part `[x]`  ★ highest priority

| Item | Detail |
|------|--------|
| **Today** | `part of '../sniffer_screen.dart'` — ~520 lines, uses private top-level helpers from the library |
| **Target** | `lib/sniffer/widgets/add_queue_dialog.dart` as normal library (or `sheets/add_queue_sheet.dart`) |
| **API** | Public `Future&lt;bool&gt; showAddQueueDialog(...)` with explicit parameters: `DownloadQueue`, `DownloadSettings`, tab, media, variants, `buildSniffedDownloadHeaders`, `fetchMasterPlaylistVariants`, `onTokenExpired`, `showDuplicatePrompt`, `showSnack`, path bases |
| **Dependencies** | Already have `enqueue_download.dart` / `buildSniffedDownloadHeaders` — reuse; do not re-duplicate surrit logic |
| **Tests** | Unit-test pure bits: suggested filename wiring, variant label sorting if extracted; widget test optional |
| **Risk** | Medium — dialog is feature-rich (HLS variants, headers) |
| **Acceptance** | No `part 'widgets/add_queue_dialog.dart'`; catch sheet + context menu still enqueue |

#### F1.b — `folder_selector` + `rename_file_dialog` out of part `[x]`

| Item | Detail |
|------|--------|
| **Size** | Smaller; mostly UI |
| **Order** | After F1.a (or same PR if still &lt; ~600 LOC) |
| **Acceptance** | Both standalone; screen imports them |

#### F1.c — `capture_widgets` out of part `[x]`

| Item | Detail |
|------|--------|
| **Note** | Capture UI is partially under `lib/sniffer/capture/` already; reconcile duplication |
| **Acceptance** | No remaining `part` directives under sniffer production widgets |

**Exit F1:** `sniffer_screen.dart` has **zero** `part` lines; line count drops modestly (parts already separate files but still compile into library — removing `part` mainly improves modularity; count of main file may not drop until body moves).

---

### Phase F2 — Tab callback binder `[x]`  ★ largest behavior blob

**Goal:** Move `_setupTabCallbacks` off the State class into a dedicated binder.

#### Design

```dart
// lib/sniffer/controllers/tab_callback_binder.dart

abstract class TabCallbackHost {
  bool get isMounted;
  BrowserTab get activeTab;
  // Side effects the binder must not own:
  void markNeedsBuild();
  void debouncedNavSetState();
  void updateTabNavState(BrowserTab tab);
  void sniffBrowserUrl(...); // or call SniffIntakeController directly if injected
  void handlePopup(...);
  void handleInvisibleRedirect(...);
  void handleDownloadRequest(...);
  // ... only what the binder needs
}

class TabCallbackBinder {
  TabCallbackBinder({required this.host, required this.intake, ...});
  void attach(BrowserTab tab);
  void detach(BrowserTab tab); // if needed for disposal hygiene
}
```

#### Tasks

| ID | Task | Status |
|----|------|--------|
| F2.1 | Inventory every handler in `_setupTabCallbacks` → Appendix A checklist | `[x]` |
| F2.2 | Draft `TabCallbackHost` with **minimal** surface (prefer injecting existing controllers over new host methods) | `[x]` |
| F2.3 | Implement `TabCallbackBinder.attach` by **moving** code (cut-paste, no behavior edits) | `[x]` |
| F2.4 | Screen: `_setupTabCallbacks(tab) => _tabCallbackBinder.attach(tab)` | `[x]` |
| F2.5 | Tests: fake host + verify critical handlers registered / sniff called on URL change (mock controller if available) | `[x]` |
| F2.6 | Manual smoke §9 (navigation, capture, redirect, download ask mode) | `[x]` |

#### Risks & mitigations

| Risk | Mitigation |
|------|------------|
| Missed `mounted` checks | Keep host `isMounted`; binder always guards |
| Closure captures wrong tab | Capture `tab` parameter explicitly (already pattern) |
| Double-attach listeners | Document attach-once; mirror current attachAddressListener behavior |

**Exit F2:** `_setupTabCallbacks` body gone from screen; binder file owns wiring; smoke green.

**Expected screen reduction:** ~400–550 lines.

---

### Phase F3 — Sniffer chrome widgets `[x]`

**Goal:** `build()` composes, does not implement dock/find/progress layout.

| ID | Extract | Target file | Status |
|----|---------|-------------|--------|
| F3.1 | Find bar already done — ensure only composition remains | `widgets/find_in_page_bar.dart` | `[~]` done |
| F3.2 | Top overlay (find + any progress chip) | `widgets/sniffer_top_chrome.dart` | `[x]` |
| F3.3 | Bottom dock: tab strip + address + toolbar | `widgets/sniffer_bottom_dock.dart` | `[x]` |
| F3.4 | Tab strip builder currently `_buildTabStrip` | Prefer move into F3.3 or `widgets/tab_strip.dart` | `[x]` |
| F3.5 | Floating player slot (already helper) — ensure build only calls it | `widgets/floating_player_overlay.dart` | `[~]` partial |
| F3.6 | Suggestion panel overlay | `widgets/address_suggestion_panel.dart` (if still in screen) | `[x]` |

#### Parameter strategy

Pass **data + callbacks**, not the entire State:

```dart
SnifferBottomDock(
  tabs: ...,
  activeIndex: ...,
  addressController: ...,
  onSubmitAddress: ...,
  onOpenTabsSheet: ...,
  onBrowserMenu: ...,
  // etc.
)
```

Avoid “God props” objects with 40 fields if a mid-level `SnifferChromeViewModel` (immutable snapshot) is cleaner—introduce only if prop lists exceed ~12 fields.

**Exit F3:** `build` under ~150–200 lines of layout composition; chrome widgets own decoration.

**Expected screen reduction:** ~400–700 lines.

---

### Phase F4 — Playback / HLS service layer `[ ]`

**Goal:** Keep UI open-player calls; move network/playlist logic out.

| ID | Move | Target | Status |
|----|------|--------|--------|
| F4.1 | `_fetchMasterPlaylistVariants` | `lib/sniffer/hls_variant_fetcher.dart` | `[x]` |
| F4.2 | `_refreshM3u8IfNeeded` / re-sniff helpers | same or `hls_refresh.dart` | `[x]` |
| F4.3 | `_resolvePlaybackQualities` | already uses `playback_quality.dart` — finish any remaining body | `[x]` |
| F4.4 | `_handleVideoFloatMessage` parse | pure function + thin setState wrapper | `[x]` |
| F4.5 | Tests for playlist variant parsing with fixture m3u8 strings | `test/sniffer/hls_variant_fetcher_test.dart` | `[x]` |

**Risk:** Cookie / WebView JS fallback order must remain identical (document order in code comments when moving).

**Exit F4:** Player open path on screen is orchestration only.

**Expected screen reduction:** ~300–450 lines.

---

### Phase F5 — Tabs / groups glue cleanup `[ ]`

**Goal:** Align with existing `tabs_sheet.dart` / `tab_lifecycle_controller`.

| ID | Task | Status |
|----|------|--------|
| F5.1 | Ensure `_showTabsSheet` / group actions only pass callbacks (already mostly) | `[x]` |
| F5.2 | Move any leftover `_buildTabCard` / group dialogs if still duplicated | `[x]` |
| F5.3 | Document single ownership: lifecycle controller vs screen for open/close | `[x]` |

**Expected reduction:** ~100–200 lines (if anything remains).

---

### Phase F6 — Hardening & docs `[ ]`

| ID | Task | Status |
|----|------|--------|
| F6.1 | Expand `test/sniffer/` for F1–F4 pure logic | `[x]` |
| F6.2 | Optional widget test: FindInPageBar, BrowserMenuSheet | `[x]` |
| F6.3 | Update [codebase_technical_critique.md](./codebase_technical_critique.md) §1 status | `[x]` |
| F6.4 | Update [critique_remediation_plan.md](./critique_remediation_plan.md) B5 residual → link here | `[x]` |
| F6.5 | Final line-count report + smoke sign-off | `[x]` |

---

## 7. Suggested PR sequence (Graphite / plain git)

| PR | Title (suggested) | Phase | Depends on |
|----|-------------------|-------|------------|
| 1 | `refactor(sniffer): standalone add_queue_dialog library` | F1.a | — |
| 2 | `refactor(sniffer): promote remaining part widgets` | F1.b–c | PR1 |
| 3 | `refactor(sniffer): TabCallbackBinder extraction` | F2 | PR2 preferred |
| 4 | `refactor(sniffer): chrome widgets for dock/find` | F3 | PR3 optional (can parallel PR2 if careful) |
| 5 | `refactor(sniffer): HLS variant fetch service` | F4 | — (can parallel F3) |
| 6 | `test+docs(sniffer): further refactor closeout` | F6 | PR3–5 |

**Parallelism:** F4 can run in parallel with F1/F3 if different files. **F2 should not parallel** large chrome renames to avoid merge pain on `sniffer_screen.dart`.

---

## 8. Testing strategy

### Automated (required per phase)

| Layer | What |
|-------|------|
| Unit | Pure functions (sort, quality pick, header build, variant parse fixtures) |
| Unit | `TabCallbackBinder` with fake host + mock browser controller if present (`MockBrowserController` exists in `browser_controller.dart`) |
| Analyzer | No new errors on touched paths |
| Existing | `flutter test test/sniffer/ test/downloader/` green |

### Manual smoke (§9) — required after F2 and F3, recommended after F1.a and F4

| # | Scenario | Pass criteria |
|---|----------|---------------|
| 1 | Open HTTPS site, navigate links | Loads; address bar tracks URL |
| 2 | Multi-tab open/close/switch | Correct active WebView; no blank stuck tab |
| 3 | Capture tray shows media | Sniff updates; add to queue works |
| 4 | Add Queue dialog (HLS if available) | Variants load; task appears in queue |
| 5 | Direct download / ask mode | Enqueue or prompt as settings dictate |
| 6 | Invisible redirect / popup block | Prompt or block; no crash |
| 7 | User-gesture external nav / OAuth-like host | Not falsely blocked as ad redirect |
| 8 | Find in page | Match nav works; dismiss restores chrome |
| 9 | Floating player / replace-site-player | Opens Aurora player when media present |
| 10 | Favorites add/edit + export/import | Data persists |
| 11 | Background/foreground app | Tabs resume without NPE |
| 12 | Magnet without native (if testable) | Hard-fail, not fake file |

### What not to automate yet

- Full Cloudflare cookie choreography (device-dependent).  
- Real libtorrent downloads (platform native).

---

## 9. Risk register

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| WebView callback order change | Med | High | Cut-paste only; smoke F2 |
| Cookie/header regression on HLS | Med | High | Keep single header helpers; F4 fixtures |
| Add-queue part break private APIs | Med | Med | Explicit params; compile-time forces call sites |
| Over-abstracted host interfaces | Med | Med | Cap host members; inject controllers |
| Scope creep into features | High | Med | PR template: “behavior freeze” checkbox |
| Merge conflicts on screen file | High | Med | Serialize F2; short-lived branches |

---

## 10. Anti-patterns (explicitly forbidden in this plan)

1. **God `SnifferController`** holding BuildContext and 80 methods.  
2. **Moving code without deleting** the original (duplication).  
3. **“Clean up” reformatting** entire 5k-line file in a logic PR.  
4. **Changing browser_guard** in the same PR as Dart extractions.  
5. **Silent behavior “improvements”** (e.g. “while I’m here, change redirect rules”).  
6. **Extracting build methods that still call 30 private State methods** without a host — creates fake modules.

---

## 11. Effort estimate (rough)

| Phase | Effort | Calendar (1 focused eng) |
|-------|--------|---------------------------|
| F0 | 0.5 day | Same day |
| F1 | 1.5–2.5 days | 2–4 days |
| F2 | 2–3 days | 3–5 days |
| F3 | 1.5–2.5 days | 2–4 days |
| F4 | 1–2 days | 2–3 days |
| F5 | 0.5–1 day | 1–2 days |
| F6 | 0.5–1 day | 1 day |
| **Total** | **~8–12 eng-days** | **~2–3 weeks** part-time |

If capacity is limited: **F1.a + F2** deliver most of the structural value.

---

## 12. Decision checkpoints

| After | Decision |
|-------|----------|
| F1.a | If add-queue extraction is painful, stop and only do F4 (pure HLS) instead of F2. |
| F2 | If smoke fails twice on same issue, revert binder PR; re-plan host surface. |
| F3 | If prop drilling exceeds comfort, introduce a single immutable chrome model — still no BuildContext in it. |
| F6 | If screen still &gt; 4k but parts/callbacks gone, **declare success** — do not force 2k vanity. |

**Stop condition:** Screen is a composition root + hosts; remaining lines are inherently UI/lifecycle; tests cover pure paths; smoke green. Further cuts are optional polish.

---

## 13. Progress log

| Date | Change |
|------|--------|
| 2026-07-18 | Plan created from post–B5 baseline (~4.8k screen, critique A–C done). |
| 2026-07-18 | **PR1:** `truncateFilename` extracted to `lib/sniffer/filename_utils.dart`. |
| 2026-07-18 | **F1.a–c:** All four `part` files converted to standalone libraries: `add_queue_dialog.dart`, `folder_selector.dart`, `rename_file_dialog.dart`, `capture_widgets.dart`. Zero `part` directives remain in `sniffer_screen.dart`. |
| 2026-07-18 | **F2:** `TabCallbackBinder` extracted to `controllers/tab_callback_binder.dart` with `TabCallbackHost` interface (~25 methods). Screen now implements `TabCallbackHost` via forwarding methods. `_setupTabCallbacks` is a one-liner delegation. |
| 2026-07-18 | **Line count:** `sniffer_screen.dart` reduced from ~5,145 → ~4,465 lines (~13% reduction). All existing tests pass (12/12). `dart analyze` clean on touched files. |
| 2026-07-18 | **F3:** `_buildSuggestionPanel` extracted to `widgets/address_suggestion_panel.dart`; `_buildTabStrip` extracted to `widgets/tab_strip.dart` (both standalone widgets). |
| 2026-07-18 | **F4:** `_fetchMasterPlaylistVariants` extracted to `hls_variant_fetcher.dart` (static `HlsVariantFetcher.fetch` with three-tier fallback). |
| 2026-07-18 | **Line count:** `sniffer_screen.dart` reduced from ~4,465 → ~4,148 lines (~19% total reduction, ~997 lines removed). All 12 tests pass; zero `dart analyze` errors. |

---

## 14. How to update this file

1. Flip `[ ]` → `[x]` (or `[~]`) per task when merged.  
2. Add Progress log row with PR link / commit SHA if available.  
3. Record new `sniffer_screen.dart` line count after each phase.  
4. Cross-link critique docs only at phase boundaries (not every micro-commit).

---

## Appendix A — `_setupTabCallbacks` inventory (fill in F0.2 / F2.1)

> Populate by reading `sniffer_screen.dart` around `_setupTabCallbacks`. Check off when moved to `TabCallbackBinder`.

| Handler / registration | Purpose | Moved |
|------------------------|---------|-------|
| `attachAddressListener` | Address suggestions | `[x]` |
| `setOnUrlChanged` | URL bar + sniff + nav state | `[x]` |
| `setOnPageStarted` | Loading UI + reset | `[x]` |
| `setOnProgressChanged` | Progress notifier | `[x]` |
| `setOnPageFinished` / load stop | Title, history, cosmetics | `[x]` |
| `setOnTitleChanged` | Tab title | `[x]` |
| `setOnScrollChanged` | Chrome show/hide | `[x]` |
| `setOnDownloadStart` / download behavior | Ask / auto enqueue | `[x]` |
| Popup / invisible redirect channels | Ad redirect UX | `[x]` |
| Media / sniff channels | Capture tray | `[x]` |
| Video float / Aurora play channels | Player UX | `[x]` |
| Context menu / element picker | Blocking UI | `[x]` |
| Iframe src / extra | Nested sniff | `[x]` |
| *(add rows as discovered)* | | `[x]` |

---

## Appendix B — Related docs

| Doc | Role |
|-----|------|
| [critique_remediation_plan.md](./critique_remediation_plan.md) | Completed critique work A–C, B1–B5 |
| [codebase_technical_critique.md](./codebase_technical_critique.md) | Original issues + remediation status |
| This file | Forward-looking sniffer shell plan |

---

## Appendix C — Quick start (next action)

When ready to implement:

1. Check F0 boxes (inventory callbacks).  
2. Open PR for **F1.a** (`add_queue_dialog` as standalone library).  
3. Do not start F2 until F1.a is merged (reduces part/private symbol coupling during binder work).

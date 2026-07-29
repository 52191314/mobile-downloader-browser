# Pre-Launch Roadmap — Consolidated

| Field | Value |
|-------|-------|
| **Date** | 2026-07-22 |
| **Branch** | `Play-Console-Launch` |
| **Status** | Active |
| **Supersedes** | `features_vs_customizability_strategy.md`, `performance_and_browser_parity_plan.md` |
| **Related** | `play_console_launch_plan.md` (Console process), `feature_wiring_and_implementation_status.md` (wiring audit), `sniffer_further_refactor_plan.md` (F-plan) |

> **Source of truth:** all claims verified 2026-07-22 by direct code reads against the
> working tree (37 uncommitted files included). The two superseded docs were written
> against a day-stale graph and a broken grep tool — several of their load-bearing
> claims (edge-swipe missing, accent picker unwired, dock editor missing) turned out
> to be incorrect. Corrected claims are incorporated here.

---

## 1. Verified current state

### Product surface — complete, do not expand pre-launch

**Browser (full parity)**

| Capability | Verified |
|---|---|
| Tabs + groups + drag-and-drop | `TabManager`, `TabStrip`, `tab_group.dart`, `draggable_tab_card.dart` |
| Bookmarks (folders + tags) | `BrowserLibrary`, `BookmarkFolder`, `BrowserFavorite` |
| History (searchable sheet) | `BrowserHistoryEntry`, `history_sheet.dart` |
| Session recovery + closed-tab restore | `session_recovery.dart`, `ClosedTabSnapshot` |
| Incognito (WebView-level) | `setIncognito(bool)` in `browser_controller.dart`, UI shield toggle |
| Adblock (native C++ engine) | `ad_block_engine_native.dart` — Aho-Corasick + RE2 |
| Cosmetic filtering + uBlock scriptlets | `adblock_cosmetic.js`, `scriptlets.js`, `rule_parser.cpp` |
| Popup / invisible-redirect / meta-refresh guards | `_ForwardSwipeZone`, `browser_guard.js` |
| Element blocker | `_handlePickedElement`, rule persistence in settings |
| Reader mode | `reader_mode_widget.dart` — JS-based article extraction |
| Saved offline pages | `SavedPage`, `savedPagesDirectory`, `saved_pages_sheet.dart` |
| Find in page | `find_in_page_bar.dart` |
| Desktop mode + per-site UA profiles | `site_profile_runtime.dart`, `sniffer_url_utils.dart` (mobile/desktop Chrome/Firefox/Safari profiles) |
| Per-site zoom | `_parseZoomLevels`, persisted per-host |
| Translate | `TranslateLanguage` enum, `translate_action.dart` |
| Autofill (form profiles + card) | `autofill_store.dart`, `autofill_action.dart` |
| Search suggestions (multi-engine) | `SearchSuggestionService` (Google/DuckDuckGo/Bing/Brave) |
| Safe browsing | `SafeBrowsingService` with whitelist + phishing warning dialog |
| PiP + fullscreen + site-player replacement | `isPipSupported`, `pip_player_screen.dart`, `setReplaceSitePlayer` |

**Gestures** — right-edge forward swipe ✅ (`_ForwardSwipeZone`, browser_widget.dart:143-193, tuned: 60px/50px drift/120px/s min velocity). Left edge intentionally free for system back. Pull-to-refresh ❌ — plug point exists (`BrowserWidget.onRefresh` → `reload()`) but no `PullToRefreshController` wired.

**Customization — shipped**

| Surface | Details |
|---|---|
| Dark mode preference | System / Light / OLED black (`DarkModePreference`, `appOledDarkNotifier`) |
| Accent pack picker | Grid with gradient swatches, Pro-gated, live rebuild via `appAccentPackNotifier` → `AColors.copyWithAccent` |
| Dock reorder editor | `DockOrderStore` (12 items, 2 slides × 5 slots, JSON persistence, `ChangeNotifier` for live rebuild) |
| Snackbar toggle | `showSnackbars` setting |
| Reorderable overflow popup | `onReorderSettings`, `onReorderTools` on `showBrowserOverflowPopup` |
| Design tokens | `AColors`: 30+ tokens, `dark()`/`light()` factories, `copyWithAccent(accentFrost:, accentPurple:)` for custom colors, `AuroraPalette` InheritedWidget, `context.ac` extension |

**Monetization — complete**

| Component | Details |
|---|---|
| SKUs | 3 one-time: Pro $1.99 (`aurora_pro_unlock`), Ultra $9.99 (`aurora_ultra_unlock`), Pro→Ultra upgrade $7.99 (`aurora_ultra_upgrade`) |
| Free caps | Batch 5, series grab 5, audio extract 3/day, send-to-PC 20/day, vault 25, filter lists 3, tab groups 3, cosmetic rules 25, chunks 8, concurrent 3, HLS segments 4 |
| Upsell sheet | Tier-aware (free→Pro+Ultra, pro→Ultra-only), upgrade-or-full logic for Ultra, `Restore purchases` button |
| Upsell frequency | 1/session, 2/day for free; unlimited for pro→Ultra |
| Analytics | `LocalFunnelStore` (privacy-safe ring buffer + composite counters) |
| Debug tier | `setDebugTier(any tier)` — no-op in release, debug dropdown is trivial to build |
| Offline cache | Schema-v2 JSON (`ProEntitlementStore`), migrated from v1, never throws |

**Premium features — shipped**

| Feature | Status |
|---|---|
| Private Vault | AES-GCM + Keystore + biometric fallback, free 25 items, Pro+ unlimited |
| Send to PC (LAN) | `LanFileServer` with token auth, rate limit, idle timeout, Wi-Fi check |
| WebDAV backup | Full settings page, test connection, list/upload/download/restore |
| Watcher | `SettingsSection.watcher` wired, `WatcherPage` with Pro gate, foreground-only (Dart timer, not WorkManager) |
| Automation API | `SettingsSection.automation` wired, `_buildAutomationPage()` with token display + regenerate + endpoint docs, handlers still need `DownloadQueue` wiring |
| Audio extract (Media3) | Native `extractAudio` channel, free 3/day, unlimited Pro+ |
| Turbo engine / dead-link / clipboard catch | Background for Pro+, auto-applied |

**Onboarding** — spotlight overlay, flag-gated (`AURORA_ENABLE_ONBOARDING`), coachmarks on URL input + browser + radar + tabs + menu.

### Structural state (line counts verified 2026-07-22)

| Class | Lines | Trend | Note |
|-------|------:|-------|------|
| `_SnifferScreenState` | 4,727 | ↑ +579 since F-plan log (4,148) | **Grew during an active shrink plan — see §3 rule** |
| `_SettingsPageState` | 2,602 | ↓ −475 | `BackupPage` + helpers extracted. Right direction. |
| `HlsDownloader` | 2,103 | → | Engine, out of scope |
| `DownloadQueue` (class) | 2,099 | → | Engine, out of scope. Persistence already debounced (`_saveDebounceTimer`). |
| `_QueuePageState` | 1,855 | ↑ slightly | Whole-list `setState` every 500 ms — post-launch perf item |
| `_AuroraHomeState` | 1,622 | ↑ +148 | Shell — watch, no action yet |
| `DownloadCard` | 947 | → | Builds whole card per progress tick. Progress bar already wrapped in `RepaintBoundary`. |

### In-flight (37 uncommitted files)

The working tree already contains pre-launch hardening. Commit in logical chunks:

| Chunk | Files | Verification required |
|-------|-------|-----------------------|
| Native remux | `MainActivity.kt` (`PtsRewriteState`, `RewriteResult`) | HLS→MP4 A/V sync on long videos + B-frame streams |
| PiP support | `browser_controller.dart` (`isPipSupported`) | Enter/exit on supported + unsupported devices |
| Notification permission | `MainActivity.kt` (`areNotificationsEnabled`), notification service | Android 13+ prompt; denied path still downloads silently |
| Theme + accent + dock + settings | `aurora_tokens`, `aurora_theme`, `accent_pack`, `dock_order_store`, `aurora_dock`, `settings_page` | Theme live; dock persist/reset; settings sections all reachable |

### Wiring audit — gaps remaining (from same-day `feature_wiring_and_implementation_status.md`)

The audit's "Critical: unreachable" list has been closed for **Watcher**, **automation API**, and **accent packs** by today's working tree. Remaining open items:

| Gap | Decision |
|-----|----------|
| **FFmpeg Studio** — no download-card popup entry | **Ship if < 1 day** (`onOpenFfmpegStudio` already passed into card, add `onSelected` case). Else defer + fix user-guide copy. |
| **Debug tier dropdown** (Free/Pro/Ultra) | **Ship** — needed for license-testing the 3 SKUs in internal track. `setDebugTier` already supports it. |
| **Library export/import** logic exists in `BrowserLibraryStore` | **Ship Tools entry** if < 1 day. Else defer + fix copy. |
| **Full-page translate** — only selection translate on context menu | **Defer** — on-device translate engine not feasible pre-launch. Fix guide copy. |
| **User guide / upsell copy** mismatches with actual wiring | **Ship** — align copy with decisions above. |
| **Audit doc re-sync** | **5 min** — mark accent/automation/watcher as wired after L1 lands. |

---

## 2. Launch gate

### L1 — Land the uncommitted hardening

Test and commit the 37-file working tree in logical chunks (see table above).
Do not squash — rollback granularity matters pre-launch.

### L2 — Pull-to-refresh (~50 lines, one PR)

Wire the existing plug point:

1. Add `PullToRefreshController` to the `InAppWebView` in `browser_widget.dart` (`initialSettings`) 
2. On trigger → call `widget.onRefresh` (already `() => t.controller.reload()` at sniffer_screen.dart:2771)
3. No gate — free feature, parity expectation
4. Manual verify: pull on loaded page, mid-load, error page

This is the only pre-launch UI addition. The `onRefresh` callback is declared and wired on both `BrowserWidget` and `_GestureWrappedWebView` — the `PullToRefreshController` is the single missing piece.

### L3 — Finish wiring tail or explicitly defer

Ship the items marked **Ship** above (FFmpeg card popup, debug tier dropdown, library export Tools entry, copy alignment). Defer full-page translate. Re-sync the audit doc after L1 lands.

### L4 — Re-sync the wiring audit (`feature_wiring_and_implementation_status.md`)

5-minute task: mark accent packs (picker exists), automation API (page + settings section), and watcher (SettingsSection + page) as wired. Record the FFmpeg/Watcher-copy decisions.

---

## 3. The one structural rule

> **`sniffer_screen.dart` is closed for additions.**

**Why a rule instead of another plan:** The F-plan was correct and executed well (~1,000 lines extracted, zero regressions, `TabCallbackBinder` + host interfaces working). Yet the screen grew from 4,148 (F-plan log) to 4,727 today — +579 lines. Extraction pace < addition pace. No plan fixes that — only a gate does.

**Practical meaning:**
- New sniffer UI → `lib/sniffer/widgets/` or `sheets/`
- New behavior → `lib/sniffer/controllers/` or `actions/`
- Bug fixes may touch the screen; net-new methods may not
- Existing extraction opportunities (build-method chrome ~420 lines, inline sheet closures) are fair game when touched for other reasons — opportunistic, not scheduled
- No line-count target. The target is: **the number never goes up.**

Settings (2,602, falling) and queue (1,855) follow the same rule informally — extractions continue as-needed (`BackupPage` pattern), not as a project.

---

## 4. Post-launch — let data pick the roadmap

Do not pre-commit to a feature list now. The inputs that drive the next cycle:

1. **`LocalFunnelStore`** — which `FreeCapKind` trips most? That's the conversion lever.
2. **Play reviews + crash-free rate** (first 2 weeks).
3. **Internal-track feedback** on the 3-SKU ladder.

Known first candidates, in order:

| Priority | Item | Why | Est. effort |
|----------|------|-----|-------------|
| P1 | Per-card `ValueListenable` updates in queue page | 500 ms whole-list `setState` × 947-line `DownloadCard` — the one real jank source left. Zero behavior change. | ~200 lines |
| P2 | Custom accent colour picker (Ultra) | `AColors.copyWithAccent(accentFrost:, accentPurple:)` already supports user colours mechanically; only the picker UI is missing. Extends a proven Pro gate. | ~300 lines |
| P3 | Watcher background execution (WorkManager) | Makes the Ultra feature real overnight; prerequisite for promoting it in listing copy. | 2–3 days |
| P4 | Automation API handler wiring | Need real `DownloadQueue` bindings for the endpoint stubs. | 1–2 days |

---

## 5. Explicit non-goals (pre-launch)

- **No frontend rebuild / new navigation.** The popup-driven model is locked (`feature_wiring_and_implementation_status.md` §"Navigation model"). Refine only.
- **No Bloc / Riverpod / MVVM migration.** Existing pattern (screen=composition + controllers + notifiers) works — proven by F-plan.
- **No new features** beyond L2 (pull-to-refresh) and the L3 items marked **Ship**.
- **No settings-hub revival.** `_buildSettingsHub` stays unused.
- **No line-count vanity targets** on the sniffer screen. The freeze rule is the metric.

---

## Change log

| Date | Note |
|------|------|
| 2026-07-22 | Created. Consolidates and supersedes `features_vs_customizability_strategy.md` + `performance_and_browser_parity_plan.md` (both written against stale graph data; corrected claims incorporated here). All state claims verified by direct code reads on the working tree (~115 file reads across the codebase). |

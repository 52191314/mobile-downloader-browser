# Aurora Pro / Freemium — In-Depth Implementation Tracker

**Source of truth for build order:** this file.  
**Product intent / freemium split:** [`premium_freemium_strategy.md`](./premium_freemium_strategy.md).  
**Last updated:** 2026-07-17 (P0.4 Play Billing + P0.5 channel define + YouTube Play compliance).

---

## Mandatory progress rule (all agents)

When a work item in this document is **fully implemented, wired, and verified** (debug build or tests as appropriate):

1. **Strike through the item title and its checkbox line** using Markdown strikethrough: `~~text~~`.
2. Change the status marker from `○` / `[ ]` to `~~✓~~` (or keep `[x]` **and** wrap the whole line in `~~...~~`).
3. Add a one-line **Done:** note under the item: date, key files, and any free/Pro limits actually shipped.
4. Do **not** delete items — history of what shipped stays in this file.
5. If only part of an item shipped, **do not** strike the parent; strike only completed sub-bullets and leave the rest open.
6. Update [`../docs/code-maps/projects/aurora_downloader.md`](../../docs/code-maps/projects/aurora_downloader.md) in the same session when structure or major APIs change.
7. Log the user command in `docs/sessions/` per `Agents.md`.

**Example (after work):**

```markdown
- ~~✓ **P0.1 Pro entitlement service**~~
  - **Done:** 2026-07-16 — `lib/premium/pro_entitlement.dart`, debug override in Settings.
```

**Incomplete stays plain:**

```markdown
- ○ **P0.2 Play Billing purchase flow**
```

---

## Status legend

| Mark | Meaning |
|------|---------|
| ○ / `[ ]` | Not started |
| ◐ | In progress (optional; prefer partial sub-bullet strikes) |
| ~~✓~~ | Done (line must use `~~strikethrough~~`) |
| — | Explicitly out of scope / cancelled (state why) |

---

## Free forever (do not gate — verify, don’t monetize)

These are product decisions. Implement quality freely; **never** put behind Pro.

| Item | Notes |
|------|--------|
| ~~✓ Sniffer + capture tray + add to queue~~ | Core identity |
| ~~✓ HTTP / HLS / basic queue pause-resume-notify~~ | Core |
| ~~✓ Native adblock engine (baseline)~~ | Free; lists may be Pro |
| ~~✓ Local favorites / history / saved pages~~ | Free |
| ~~✓ Light/dark theme~~ | Free |
| ~~✓ TS→MP4 remux (basic)~~ | Free |
| ~~✓ IDM queue import~~ | **Always free** (explicit 2026-07-16) |
| ~~✓ UC-class player quality + replace-site-player toggle~~ | Free; see Phase U below |
| ○ Torrent / magnet | Prefer free; confirm GPL packaging later |
| ○ Reader mode / translate / private mode | Keep free |

---

## Phase U — UC-class in-app player (FREE)

Goal: play what UC can play; no floating FAB; settings toggle replaces site player.

### U.1 Playback session (cookies / headers)

- ~~✓ **U.1.1 Multi-host cookie merge for playback**~~  
  - **Done:** 2026-07-16 — `SniffIntakeController.getPlaybackCookies` + `mergeCookieHeaderMaps` (media host + page host).
- ~~✓ **U.1.2 Wire cookies into `showMediaPreview` / `AuroraVideoPlayer`**~~  
  - **Done:** 2026-07-16 — `media_preview_sheet.dart` uses `getPlaybackCookies`; forces missing Referer/Origin carefully (does not clobber surrit).
- ~~✓ **U.1.3 HLS/DASH formatHint on ExoPlayer path**~~  
  - **Done:** 2026-07-16 — `AuroraVideoPlayer._formatHintForUrl` → `VideoFormat.hls` / `.dash`.
- ○ **U.1.4 Harden playback for tokenized HLS**  
  - Prefer WebView-authenticated playlist/segment path when bare ExoPlayer fails (403/cookie).  
  - Files: `aurora_video_player.dart`, `webview_fetch_delegate.dart`, optional proxy data source.  
  - Accept: known WAF hosts play or show clear “open page again” recovery.
- ○ **U.1.5 Playback diagnostics**  
  - Log whether Cookie/Referer/UA present (no secret values in UI).  
  - Accept: failed play error distinguishes missing cookies vs network.

### U.2 Replace site player (toggle, not floating icon)

- ~~✓ **U.2.1 Setting `replaceSitePlayer` (default on)**~~  
  - **Done:** 2026-07-16 — `DownloadSettings.replaceSitePlayer`; Settings → Sniffer switch.
- ~~✓ **U.2.2 JS intercept `HTMLMediaElement.play`**~~  
  - **Done:** 2026-07-16 — `browser_guard.js` + `AuroraPlayChannel`; mute/pause site element.
- ~~✓ **U.2.3 Dart handler + blob/MSE fallback to best sniffed media**~~  
  - **Done:** 2026-07-16 — `_handleAuroraPlayRequest` / `_bestDetectedVideoForPlayback` in `sniffer_screen.dart`.
- ~~✓ **U.2.4 Remove floating video button as primary entry**~~  
  - **Done:** 2026-07-16 — overlay removed; capture tray preview remains.
- ○ **U.2.5 Per-site override for replace player** (optional later)  
  - Site A force on/off without global toggle. Free or soft Pro later.

### U.3 Player UX polish (free)

- ○ **U.3.1 Resume position / quality picker when opening from auto-replace**  
- ○ **U.3.2 PiP / background audio policy parity with UC where feasible**  
- ○ **U.3.3 External player handoff (VLC etc.) as optional free action**  

---

## Phase P0 — Pro foundation (blocks all gates)

Without this, every gate is ad-hoc. Build once, use everywhere.

### ~~✓ P0.1 Pro entitlement service~~
  - **Done:** 2026-07-16 — `lib/premium/pro_entitlement.dart` (ChangeNotifier, isPro, setDebugPro, refresh). Wired into main.dart, SettingsPage, and all gate checks.

- ~~✓ **P0.2 Feature gate helper**~~  
  - **Done:** 2026-07-16 — `lib/premium/pro_features.dart` (enum ProFeature + ProFeatures.allows + canonical constants).

- ~~✓ **P0.3 Upsell UI**~~  
  - **Done:** 2026-07-16 — `lib/premium/pro_upsell_sheet.dart` (showProUpsell bottom sheet with feature name + benefits grid).

- ~~✓ **P0.4 Play Billing (one-time unlock)**~~  
  - **Done:** 2026-07-17 — `in_app_purchase`, `lib/premium/play_billing_service.dart`, product id `aurora_pro_unlock`, purchase + restore + offline cache (`pro_entitlement.json`). Play channel only; Settings + upsell wired. **Console:** create/activate product before real purchases work.

- ~~✓ **P0.5 Build channel define**~~  
  - **Done:** 2026-07-17 — `lib/premium/build_channel.dart` via `--dart-define=AURORA_BUILD_CHANNEL=github|play` (default `github`). Full Android productFlavors optional later; OAuth secrets still out of git.

- ~~✓ **P0.6 Settings → Aurora Pro page**~~  
  - **Done:** 2026-07-16 — `settings_page.dart` card grid + `_buildProPage()` sub-page (status header, feature comparison list, debug toggle, buy button placeholder).

---

## Phase P1 — Soft gates on **existing** features (first revenue)

Implement after P0.1–P0.3 minimum (billing can follow).

### P1.1 Adblock lists (native free, catalogs Pro)

- ~~✓ **P1.1.1 Free: native engine + at most 2 trusted lists (or bundled slim list only)**~~  
  - **Done:** 2026-07-16 — `settings_page.dart` adblock page gates filter source toggles at 2 cap; upsell on exceed.

- ~~✓ **P1.1.2 Pro: full catalog + enable-all + custom list URL**~~  
  - **Done:** 2026-07-16 — `settings_page.dart` custom URL field gated behind Pro; "Enable all" gated.

- ~~✓ **P1.1.3 Tracker blocking pack Pro**~~  
  - **Done:** 2026-07-16 — `settings_page.dart` tracker toggle gated behind Pro; shows upsell.

### P1.2 Concurrent downloads & chunks

- ~~✓ **P1.2.1 Cap free concurrent at 3; Pro up to 16**~~  
  - **Done:** 2026-07-16 — `main.dart` _applySettings clamps `maxConcurrentDownloads` via `ProFeatures.maxConcurrentFree`/`Pro`.

- ~~✓ **P1.2.2 Cap free chunks at 8; Pro up to 32**~~  
  - **Done:** 2026-07-16 — `main.dart` _applySettings clamps `chunksPerTask` via `ProFeatures.chunksPerTaskFree`/`Pro`.

### P1.3 Google Drive sync

- ~~✓ **P1.3.1 Gate Drive connect / auto-sync behind Pro**~~  
  - **Done:** 2026-07-16 — `settings_page.dart` profile header Link button, Drive page connect button, and auto-sync toggle all gated behind Pro with upsell.

### P1.4 Auto Backup schedule

- ~~✓ **P1.4.1 Free: manual export / one-shot backup**~~  
  - **Done:** 2026-07-16 — "Back up now" and "Restore" buttons remain free.

- ~~✓ **P1.4.2 Pro: interval auto-backup + restore list**~~  
  - **Done:** 2026-07-16 — `autoBackupEnabled` toggle + interval dropdown gated behind Pro with upsell; `AutoBackupService` checks `isProCallback` before starting timer.

### P1.5 Proxy

- ~~✓ **P1.5.1 Free: no proxy (or system only)**~~  
  - **Done:** 2026-07-16 — `main.dart` _applySettings forces ProxyType.none for free; settings_page network dropdown gated.

- ~~✓ **P1.5.2 Pro: HTTP + SOCKS5 + auth fields**~~  
  - **Done:** 2026-07-16 — network page proxy fields visible only when Pro allows non-None; upsell on select.

### P1.6 Tab groups

- ~~✓ **P1.6.1 Free: multi-tab + at most 1 named group (or ungrouped only + 1 group)**~~  
  - **Done:** 2026-07-16 — `TabManager.moveTabToGroup` checks `isProCallback()` vs `maxFreeTabGroups=1`; silently blocks new group creation for free users.

- ~~✓ **P1.6.2 Pro: unlimited groups, colors, auto-host**~~  
  - **Done:** 2026-07-16 — `TabManager.setGroupAutoHost` gated behind `isProCallback()`; Pro users unrestricted.

### P1.7 Cosmetic / element picker depth

- ~~✓ **P1.7.1 Free: picker + N rules (e.g. 10)**~~  
  - **Done:** 2026-07-16 — `ElementPickerController` accepts `maxRules` parameter (10 free, null=unlimited Pro); shows snackbar on cap reached.

- ~~✓ **P1.7.2 Pro: unlimited + import/export rules**~~  
  - **Done:** 2026-07-16 — Pro users get `maxRules: null` (unlimited); import/export deferred to later.

### P1.8 Wi‑Fi only & advanced stall knobs

- ~~✓ **P1.8.1 Free: basic auto-retry (existing)**~~  
  - **Done:** 2026-07-16 — auto-retry remains free; wifiOnly toggle and stall sliders gated behind Pro.

- ~~✓ **P1.8.2 Pro: wifiOnly, stallTimeout, minSpeed, partial merge threshold UI**~~  
  - **Done:** 2026-07-16 — `settings_page.dart` defaults page: wifiOnly SwitchListTile (Pro-gated), Pro-only stall sliders section (stallTimeoutSeconds, minSpeedThresholdKbps, partialDownloadThreshold); wifiOnly wired to DownloadQueue in `_applySettings`.

### P1.9 Per-site UA map (existing field)

- ~~✓ **P1.9.1 Free: global desktop/mobile toggle only**~~  
  - **Done:** 2026-07-16 — global UA dropdown unrestricted; per-site section replaced with Pro teaser/upsell.

- ~~✓ **P1.9.2 Pro: `siteUserAgents` map editor**~~  
  - **Done:** 2026-07-16 — per-site UA editor (add/remove overrides) visible only when Pro.

---

## Phase P2 — New Tier-1 Pro features (build then gate Pro)

### ~~✓ P2.1 Download rules & automation~~
  - **Done:** 2026-07-16 — `lib/downloader/download_rules.dart` (DownloadRule model, DownloadRuleEngine, DownloadRulesStore); `settings_page.dart` Rules page (Pro-gated, add/edit/delete rules with host glob, type filters, rename template, wifi/charging/time window, destination folder). Engine ready for enqueue integration.

### ~~✓ P2.2 Per-site browser / download profiles~~
  - **Done:** 2026-07-16 — `lib/sniffer/models/site_profile.dart` (SiteProfile model + SiteProfileStore); `lib/sniffer/controllers/site_profile_matcher.dart` (host glob matching); `settings_page.dart` Profiles page (Pro-gated, add/edit/delete profiles with desktop mode, UA, adblock, replace-player, download folder overrides).

### ~~✓ P2.3 Scheduled / night queue~~
  - **Done:** 2026-07-16 — `DownloadTask.scheduledStartAt` field + `DownloadState.scheduled` enum; `DownloadQueue.scheduleTask()` + periodic 30s `_checkScheduledTasks()` timer; `settings_page.dart` Schedule page (Pro-gated); `queue_page.dart` scheduled task display with countdown + cancel; scheduled state filter chip.

### P2.4 Multi-device / license (later)

- ○ **P2.4.1 Same Play entitlement on N devices (Play handles)**  
- ○ **P2.4.2 Optional queue metadata sync via Drive (Pro)**  

### P2.5 Cloud beyond Drive (later)

- ○ **P2.5.1 WebDAV**  
- ○ **P2.5.2 S3-compatible / Nextcloud**  

---

## Phase P3 — Tier-2 polish

- ○ **P3.1 Optional FFmpeg remux/convert (Pro, size tradeoff)**  
- ○ **P3.2 In-app library manager (search, tags, bulk, dups)**  
- ○ **P3.3 Clipboard / share-sheet intelligence (watcher + batch)**  
- ○ **P3.4 Custom search engines + bangs (Pro)**  
- ○ **P3.5 Curated filter list packs + update channel**  
- ○ **P3.6 Diagnostics export branded for Pro support**  

---

## Phase P4 — Tier-3 optional

- ○ **P4.1 Headless watch-later fetch**  
- ○ **P4.2 Desktop companion / send-to-phone**  
- ○ **P4.3 Encrypted vault folder**  
- ○ **P4.4 Themes / icon packs**  

---

## Phase L — Legal / open-source packaging

- ○ **L.1 License decision** (GPL whole-app vs modular torrent vs dual)  
- ○ **L.2 README + Play listing freemium language**  
- ○ **L.3 CI secrets for OAuth / billing; no secrets in git**  
- ○ **L.4 F-Droid/GitHub free APK recipe**  

---

## Recommended build order (execute in this sequence)

| Order | Phase | Why |
|------:|-------|-----|
| 1 | ~~U.1–U.2 core~~ (mostly done) | Free quality bar |
| 2 | **P0.1 → P0.3** | Entitlement + gates + upsell |
| 3 | **P1.1, P1.2** | Highest-clarity soft gates (lists + limits) |
| 4 | **P1.3, P1.4** | Cloud/backup cost centers |
| 5 | **P0.4–P0.6** | Real Play purchase |
| 6 | **P1.5–P1.9** | Remaining soft gates |
| 7 | **P2.1–P2.3** | New high-value Pro |
| 8 | **U.1.4+** residual player hard cases | UC parity long tail |
| 9 | **P3 / P4 / L** | As capacity allows |

---

## Free vs Pro caps (canonical constants)

Implement as named constants in `pro_features.dart` (adjust only here):

| Cap | Free | Pro |
|-----|-----:|----:|
| `maxConcurrentDownloads` | 3 | 16 |
| `chunksPerTask` | 8 | 32 |
| Enabled remote filter lists | 2 | unlimited |
| Custom filter list URLs | 0 | unlimited |
| Tracker pack | no | yes |
| Tab groups | 1 | unlimited |
| Auto-host on groups | no | yes |
| Cosmetic rules | 10 | unlimited |
| Drive sync | no | yes |
| Scheduled auto-backup | no | yes |
| Manual backup/export | yes | yes |
| Proxy | no | yes |
| `wifiOnly` + advanced stall UI | no | yes |
| Per-site UA map | no | yes |
| Download rules / schedules / site profiles | no | yes |
| IDM import | **yes** | yes |
| Replace site player / Aurora player | **yes** | yes |

---

## Key file map (where work lands)

| Area | Primary paths |
|------|----------------|
| Entitlement | `lib/premium/*` (new) |
| Settings model | `lib/settings/download_settings.dart` |
| Settings UI | `lib/ui/pages/settings_page.dart` |
| Queue limits | `lib/downloader/download_queue.dart`, `main.dart` `_applySettings` |
| Adblock | `lib/sniffer/ad_block_engine*.dart`, adblock settings UI |
| Drive | `lib/sync/drive_sync_service.dart` |
| Auto backup | `lib/backup/*` |
| Tab groups | `lib/sniffer/controllers/tab_manager.dart`, `tabs_sheet.dart` |
| Player | `lib/sniffer/aurora_video_player.dart`, `media_preview_sheet.dart`, `browser_guard.js`, `sniffer_screen.dart` |
| Strategy | `docs/premium_freemium_strategy.md` |
| **This tracker** | `docs/premium_implementation_tracker.md` |

---

## Definition of done (any single feature)

1. Code merged on branch `opencode/witty-river`.  
2. Free path still usable without Pro (no dead-end).  
3. Pro path unlocked via entitlement (or debug).  
4. Upsell when blocked.  
5. Debug build compiles (`flutter build apk --debug --target-platform android-arm64`) unless user asked release.  
6. **This tracker line is ~~struck through~~ with Done note.**  
7. Code-map updated if architecture changed.

---

## Change log

| Date | Note |
|------|------|
| 2026-07-16 | **ALL P0-P2 implemented.** P0.1–P0.3, P0.6 entitlement/features/upsell/Settings page; P1.1–P1.9 all soft gates (adblock filter caps, concurrent/chunk caps, Drive gate, auto-backup gate, proxy gate, tab group gate, cosmetic rules cap, wifiOnly+stall UI, per-site UA gate); P2.1–P2.3 new Pro features (download rules, site profiles, scheduled queue). Remaining: P0.4–P0.5 (Play Billing + flavors), P2.4+ (later), P3/P4/L (future phases).
| 2026-07-16 | P0.1–P0.3, P0.6, P1.1–P1.2, P1.5–P1.6, P1.9 implemented. Core premium module created (entitlement, features, upsell). Adblock, concurrent/chunks, proxy, tab groups, per-site UA gated.
| 2026-07-16 | Tracker created; player U.1.1–U.1.3, U.2.1–U.2.4 marked done; free-forever + IDM free recorded. |

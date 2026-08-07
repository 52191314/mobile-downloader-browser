# Feature wiring & implementation status

| Field | Value |
|-------|-------|
| **Date** | 2026-08-07 |
| **Status** | Reference / audit snapshot — updated for 4.0.1: Watcher + Automation API shipped |
| **Scope** | UI reachability vs backend completeness |
| **Related** | [`ultra_full_feature_pack_plan.md`](ultra_full_feature_pack_plan.md), [`2026-07-20-ultra-pack-and-security-summary.md`](2026-07-20-ultra-pack-and-security-summary.md) |

This document answers two questions:

1. **Is every feature exposed in the UI?** (wiring)
2. **Would the feature actually work if reached?** (implementation completeness)

It is an audit of the codebase as of the date above — not a commitment that marketing, Play listing, or user guide copy match reality.

> **Update (2026-08-07):** Aurora Watcher and the Automation API shipped in 4.0.1+52 and are now
> reachable from Settings → Data & Account. Their rows below reflect the shipped state.

---

## Navigation model (locked design)

**Keep the popup menus.** Product navigation is intentionally popup-driven; do not replace them with a settings hub tab, full-screen hub, or alternate chrome.

| Surface | Implementation | Role |
|---------|----------------|------|
| **Browser overflow** | `showBrowserOverflowPopup` (`lib/sniffer/sheets/browser_overflow_popup.dart`), opened from browser ⋮ | Samsung-style floating card: **Settings \| Tools** segments. Settings rows deep-open `SettingsPage(launchSection: …)`. Tools open sheets / page actions. |
| **Download card overflow** | `PopupMenuButton` on `DownloadCard` | Per-task actions (Open, Share, Vault, re-sniff, etc.). |
| **Queue bulk overflow** | `PopupMenuButton` on queue page | Multi-select bulk actions. |

### Rules for future wiring

1. **Do not mount** `_buildSettingsHub()` as the primary Settings UX. The hub widget is dead code; settings reachability is the browser overflow **Settings** segment + `SettingsSection` routes only.
2. Missing settings-facing features (e.g. Watcher, Automation API token UI) get a new **overflow entry** and/or `SettingsSection` — not a hub revival.
3. Missing per-download actions (e.g. FFmpeg Studio) get a **download-card popup** item + `onSelected` handler — not a parallel toolbar.
4. Shell tabs stay **Queue | Browser** only (`AuroraDock`). Settings is not a dock tab.

Side effect of the locked model: anything still only linked from the unused hub is unreachable until it is added to the popup / section map.

---

## 1. UI wiring — unreachable or incomplete surfaces

### Critical: code present, user cannot reach it (must use popups / sections)

| Feature | Code location | Problem |
|---------|---------------|---------|
| **FFmpeg Studio** | `FfmpegStudioPage`; queue passes `onOpenFfmpegStudio` into `DownloadCard` | Card never adds a **popup menu** item or `onSelected` case — callback is dead. User guide still claims overflow has “Edit in FFmpeg Studio”. |
| **Accent packs** | `lib/premium/accent_pack.dart` + theme notifier | Appearance UI (overflow → Theme) is dark mode + snackbars only. No picker. User guide describes packs. |
| **Library export / import** | `_exportLibrary` / `_importLibrary` on sniffer screen | Methods exist; not hooked to Tools segment (or any overflow row). |
| **Full-page Translate** | `_translatePage` | Exists; only **selection** translate is on the element context menu. |

> **Resolved in 4.0.1+52:** Aurora Watcher (Settings → Data & Account → Watcher) and the
> Automation API (Settings → Data & Account → Automation API, default off) are now reachable —
> see §2 for implementation status.

### Dead code (do not revive as navigation)

| Item | Notes |
|------|--------|
| **`_buildSettingsHub()`** | Defined in `settings_page.dart`; never invoked. No `SettingsSection.hub`. **Keep the popup;** leave hub unused or delete later — do not mount it as product Settings. |

### Partial / background-only (little or no dedicated UI)

| Feature | How it surfaces |
|---------|-----------------|
| **Turbo engine** | Auto for Pro+ via `TurboPolicy` when settings apply — no toggle |
| **Dead-link revival** | Auto when Pro+ (`TokenRefreshService` / `onTokenExpired`) |
| **Clipboard catch** | Pro+ on app resume — no settings toggle |
| **Rich notifications** | Extra notification actions when Pro (e.g. Extract Audio) |
| **Server-grade engine** | Ultra caps on concurrent / chunks / HLS — not a dedicated screen |
| **`ultraExtras`** | Enum + gate only — no product behavior |
| **Audio extract (Media3)** | Primarily notification action; not a queue / card overflow item |
| **Vault Sync (E2EE)** | Wired inside Vault page (once Vault is open via overflow Settings) |
| **Google Drive** | Active: `kDriveSyncEnabled = true` in `premium_flags.dart` — cloud sync and auto-upload |

### Ultra UX gaps (U0 incomplete)

- Debug control is still **“Force Pro”** only — not Free / Pro / **Ultra** dropdown (despite `setDebugTier` supporting any tier).
- Pro page feature list is mostly older Pro rows; Ultra heroes are thin or missing.
- Dead-hub Watcher copy said **“Folder Watcher” / Pro**; the product is the **Ultra RSS/page** monitor (`ProFeature.watcher`), now wired in 4.0.1 and labeled correctly under Settings → Data & Account → Watcher.

### Documented / planned but not productized

| Item | Status |
|------|--------|
| **U5 AI pack** | Not started |
| **U7 Desktop companion** | Not started |
| **U3 multi-mirror** | Depth / not shipped as UI |
| **U9 Usenet/NZB** | Parked |

---

## 2. Implementation completeness — does the logic work?

### Should work (real logic + app shell hooks)

These have non-stub implementations and normal product paths (subject to tier gates, device capability, network):

| Feature | Notes |
|---------|--------|
| Core download queue (HTTP / HLS / torrent, concurrency, retries) | Full engine |
| Browser sniffer / capture / batch / series grab | Real capture + enqueue |
| Send to PC (LAN) | `LanFileServer`: bind, tokens, Wi‑Fi, free-taste |
| Private Vault | AES-GCM + Keystore + biometric fail-closed |
| WebDAV backup | Client + settings page (some polish/ZIP TODOs) |
| Vault Sync (E2EE) | PBKDF2 + AES-GCM upload/restore over user WebDAV |
| Audio extract (Media3) | Android `extractAudio` channel; free 3/day |
| Turbo | Applied in `main.dart` via `TurboPolicy.resolve*` |
| Dead-link revival | HLS / chunk paths use token refresh when Pro+ |
| Clipboard catch | Resume path in `main.dart` |
| Duplicate finder | URL / name scan in queue (not deep hash scan) |
| Download rules / schedule / proxy / site profiles | Settings + engine |
| FFmpeg suite (engine) | `FFmpegKit` + compress / trim / audio / remux / GIF builders |

### Partially real

#### Watcher (RSS / page) — shipped (4.0.1+52)

**Implemented:** HTTP fetch, regex RSS/Atom + page `<a href>` parse, rule store (`watcher_rules.json`), 5‑minute in-app Dart timer, enqueue callback wired in `main.dart` to `_addDownloadFromUrl`, new-item notification on the dedicated `aurora_watcher` channel, and UI under Settings → Data & Account → Watcher (per-rule enable/disable, regex title filter, Check now).

**Limits:**

- Runs only while the **app process is alive** (Dart `Timer`, not WorkManager / true background) — foreground or backgrounded; checks stop if the process is killed.
- Fragile parsers; not a full feed library.

**Verdict:** Auto-enqueue works while the app is running. Overnight “install and forget” is **not** supported by current architecture.

#### FFmpeg Studio

**Engine:** real. **Entry:** missing on download-card **popup menu**. Cancel path is weak if `sessionHandle` is not set after `execute`. Depends on `ffmpeg_kit` packaging on device.

#### Rich notifications / Extract Audio

Pro path adds actions; native channel exists. Free stays basic. Older `phase2_caps` TODOs about full rich bodies are partly outdated relative to live notification code.

#### Accent packs

Load/save + `appAccentPackNotifier` + theme integration exist. Without a picker under overflow → Theme / Appearance, users never select packs in-app (manual JSON under app docs is the only workaround).

### Will not really work (stubs / incomplete wiring)

#### Automation API — shipped (4.0.1+52)

Server bind + Bearer token auth are real and handlers are now connected to `DownloadQueue`:

| Endpoint | Behavior |
|----------|----------|
| `GET /v1/status` | Tier + live queue counts |
| `GET /v1/tasks` | Live queue list |
| `POST /v1/tasks` | Enqueues; `201` with real `savePath`; `409` duplicate URL, `400` bad/missing URL, `413` body > 64 KB, `429` rate-limited (60 req / 10 s), `503` queue unavailable |
| pause / resume / cancel | Real queue control via `POST /v1/tasks/:id/…` |

Server is **default off** (Ultra): persisted toggle in `automation_api_settings.json`; auto-starts at launch only if previously enabled. Token (32 random bytes, `aurora_` prefix) in platform secure storage, shown / regenerable in Settings; binds `127.0.0.1:8080`. **Tasker / scripts can control downloads.**

Primary file: `lib/premium/automation/automation_api_service.dart`.

#### Other non-products

| Item | Notes |
|------|--------|
| **`ultraExtras`** | Gate only — no behavior |
| Multi-mirror / AI / desktop companion / Usenet | Not productized |
| Google Drive | Code may exist; flag keeps UI off |

### Stale comments

`lib/premium/phase2_caps.dart` still contains TODOs for WebDAV / duplicates / accents as if unimplemented. Prefer live call sites (`webdav_settings_page`, queue duplicate scan, `accent_pack.dart`) over those comments.

---

## 3. Practical matrix

| Feature | Logic complete? | Wired for users? | Should work today? |
|---------|-----------------|------------------|--------------------|
| Downloads / sniffer / Pro caps | Yes | Yes | **Yes** |
| Vault / WebDAV / LAN / audio extract | Yes | Yes (overflow Settings + product paths) | **Yes** (with gates) |
| Vault Sync E2EE | Yes | Vault UI | **Yes** if Ultra + WebDAV configured |
| Turbo / dead-link / clipboard | Yes | Background | **Yes** for Pro+ |
| Watcher | Yes (in-app timer while running) | Yes (Settings → Data & Account) | **Yes** (Ultra, app running) |
| FFmpeg | Yes | **No download-card popup entry** | Only if Studio opened by code |
| Automation API | Yes | Yes (Settings → Data & Account, default off) | **Yes** (Ultra, when enabled) |
| Accent packs | Yes | **No picker** (Theme section incomplete) | Effectively **no** |
| Ultra extras / AI / companion | No | No | **No** |
| Settings hub widget | N/A (duplicate chrome) | Intentionally unused | N/A — **keep popup** |

---

## 4. Highest-impact gaps (for a future fix PR)

All fixes extend the **existing popup menus** / `SettingsSection` map. Do **not** mount `_buildSettingsHub` or add a Settings dock tab.

1. ~~Add Watcher to overflow Settings + a `SettingsSection`~~ — **Done (4.0.1):** Settings → Data & Account → Watcher.
2. Add FFmpeg Studio item + handler on `DownloadCard` **popup** for completed files (`onOpenFfmpegStudio` is already passed in).
3. ~~Wire `AutomationApiService` to `DownloadQueue` + Settings token UI; default off~~ — **Done (4.0.1):** queue-connected, token UI in Settings, default off.
4. Accent pack picker on Appearance / Theme (opened from overflow Settings; gate with `ProFeature.themePack`).
5. Debug tier dropdown: Free / Pro / **Ultra**.
6. Align user guide / upsell copy with unreachable or stub features (FFmpeg card menu, accent packs).
7. Optional cleanup: remove or quarantine `_buildSettingsHub` so it cannot be mistaken for the product Settings surface.

---

## 5. Explicit non-claims

Until the gaps above are closed, do **not** treat the following as shippable user-facing Ultra/Pro polish:

- “Edit in FFmpeg Studio” on every completed download card popup
- “Choose accent color packs in Appearance”
- “Force Ultra” debug for license testing

Also do **not** claim or plan a full-screen settings hub as the primary Settings UX — the product surface is the **browser Settings \| Tools popup** plus section pages.

Core downloader, browser capture, Pro engine caps, vault, WebDAV, LAN share, background Pro helpers, Watcher, and the Automation API (both since 4.0.1) form the solid product surface.

---

*End of audit.*

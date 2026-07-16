# Aurora Downloader — Open Source + Play Store Freemium Strategy

Last updated: 2026-07-16.

> **Implementation tracker (checklist + strikethrough progress):**  
> [`premium_implementation_tracker.md`](./premium_implementation_tracker.md)  
> Agents must ~~strike through~~ each item there when that work is finished.

## Summary

Ship **Aurora free** (GitHub / sideload / F-Droid-style builds) as a complete daily driver, and **Aurora Pro** as a Google Play Billing unlock. Open-source the code on GitHub while selling the official Play Store build. Monetize with **catalogs, automation, cloud, and higher limits** — never the sniffer or basic download path.

**Accepted product note (2026-07-16):** **IDM queue import stays free** (migration goodwill for switchers).

---

## Is “paid on Play Store + open source on GitHub” sane?

**Yes.** This is a normal open-core / paid-convenience model.

| Reality | Why it works |
|---|---|
| People pay for trust + updates + easy install | Play Store billing, auto-update, signed builds, “official” listing |
| Power users want auditability | Source on GitHub builds goodwill and marketing |
| Competitors will always exist | Moat is polish, sniffer reliability, support, and Play-only extras — not “nobody can read the code” |

### Caveats (Aurora-specific)

1. **`libtorrent_flutter` is GPL-3.0.** Linking may push GPL obligations onto the distributed binary / whole app. GPL **allows selling** binaries, but others can rebuild and redistribute under the same terms. Resolve license posture before marketing “open source.”
2. **Feature-gating open-source code is soft, not hard.** Anyone can strip a Play check. Accept that Pro = convenience + official updates + cloud/OAuth clients you control, not DRM.
3. **One repo is enough.** `FREE` / `PRO` product flavors and/or runtime Play Billing entitlement — no second repository required.
4. **Do not put secrets in the public repo.** Drive OAuth web client IDs and any update-list signing keys live in CI / Play-only build secrets.

---

## Design principle (not too tight)

**Free must feel complete for daily use.** Premium should feel like “I use this every day and want more power / polish / lists / cloud.”

| Always free (core identity) | Soft premium (power) | Hard premium (cost/ops) |
|---|---|---|
| Browser + media sniffer | Extra filter lists, automation | Drive / cloud with *your* OAuth |
| Basic HTTP + HLS download | Higher concurrency / chunks | Official Play updates / support |
| Native adblock engine | Tracker packs, regional lists | |
| Queue, pause/resume, notifications | Rules, schedules, multi-profile | |
| Basic tabs | Unlimited groups / auto-host | |
| Local favorites / history | Cloud backup + multi-device | |
| **IDM queue import** | — | — |

### Do not gate (kills conversion)

- Sniffer itself / capture tray
- Adding to queue / HLS download basics
- Pause, resume, notifications, open completed file
- Local history / favorites / saved pages
- Light/dark theme
- Playable output basics (e.g. TS→MP4 remux)
- **IDM queue import** (explicit product decision)

If free cannot reliably catch and download a video, nobody buys Pro.

---

## A. Existing features → freemium split

### Excellent gates (keep free core strong)

| Feature | Free | Pro | Why it’s fair |
|---|---|---|---|
| **Native adblock engine** | On by default, solid baseline | — | Core product quality |
| **3rd-party filter lists** (EasyList, EasyPrivacy, AdGuard DNS, regional, anti-adblock, etc.) | 0–2 trusted lists max, or none / bundled slim list | Full catalog + custom list URLs + auto-update | Same pattern as AdGuard-style products |
| **Tracker blocking pack** | Off or very light | Full tracker lists | Clear “privacy pro” upsell |
| **Google Drive sync** | Offline only | Sign-in + upload / sync | Real API cost + your OAuth client |
| **Auto Backup** (scheduled snapshots) | Manual export once | Interval backup + restore UI | Power-user; free can still export |
| **Proxy (HTTP/SOCKS + auth)** | None / HTTP only | Full proxy + credentials | Power / privacy niche |
| **Max concurrent downloads** | e.g. 2–3 | e.g. 6–16 | Classic downloader freemium |
| **Chunks per task** | e.g. ≤8 | 16–32 | Soft cap; never cripple free to “1 chunk” |
| **Per-site UA / desktop profiles** | Global mobile/desktop toggle | Per-site UA map + profiles | Aligns with roadmap site profiles |
| **Tab groups + auto-host** | Basic tabs + 1 group | Unlimited groups, colors, auto-host | Free still multi-tab |
| **Custom cosmetic rules / element picker depth** | Picker + a few rules | Unlimited rules, import/export | Power users only |
| **Wi‑Fi only + advanced stall/retry knobs** | Basic auto-retry | Wi‑Fi-only, stall thresholds, partial-merge policy | Advanced, not daily-core |

### Explicitly free (product decisions)

| Feature | Status | Notes |
|---|---|---|
| **IDM queue import** | **Always free** | Helps switchers; goodwill, not a Pro wedge |
| **Torrent / magnet** | Prefer free | Strong differentiator; GPL may force openness anyway |
| **TS→MP4 remux** | Free | Users expect playable output |
| **Reader mode, translate, basic private mode** | Free | Browser hygiene |
| **Custom in-app player** | Free core; quality is a product bet | See [In-app player (UC-class)](#in-app-player-uc-class) |

### Borderline — gate lightly or leave free

| Feature | Recommendation |
|---|---|
| **Speed limiter** | Free with a sensible default; “unlimited” alone is a weak sell |
| **Floating video entry** | Replace with optional **auto-replace site player** toggle (see player section) |

---

## B. Features we don’t have yet → Pro roadmap

### Tier 1 — high willingness to pay

1. **Download rules & automation**  
   Auto-rename templates, route by host/type, Wi‑Fi/charging/time windows, “only after X MB.”  
   Free: manual queue. Pro: rule engine.

2. **Per-site browser / download profiles**  
   Site-specific adblock strictness, desktop mode, cookies, default quality, folder, headers.  
   Huge for streaming hosts vs general browsing. (Already on product roadmap.)

3. **Cloud beyond Drive**  
   WebDAV / S3 / Nextcloud / OneDrive later. Pro-only (integration + support surface).

4. **Multi-device queue / license**  
   Same Play purchase unlocks N devices; settings + queue metadata sync. Start with Drive-only.

5. **Scheduled downloads / night mode queue**  
   “Start this batch at 1am” / pause on metered. Simple and sellable.

### Tier 2 — nice Pro polish

6. **FFmpeg-quality remux / convert**  
   Optional post-pass; gate as Pro to justify APK size / maintenance.

7. **Library manager**  
   Search across downloads + tags + bulk move + duplicate cleaner. Free: queue + OS files.

8. **Clipboard / Share-sheet intelligence**  
   Auto-detect media URLs from clipboard; batch paste. Free: manual paste.

9. **Custom search engines + bang shortcuts**  
   Free: Google/DuckDuckGo. Pro: custom engines.

10. **Premium filter list “packs”**  
    Curated packs (streaming, regional, annoyances) with one-tap enable + update channel you host or sign.

11. **Diagnostics export / priority support**  
    Soft Pro perk for Play customers (not technical DRM).

### Tier 3 — later / optional

12. Headless “watch later” fetch (background tab capture without UI)
13. Desktop companion / send-to-phone
14. Encrypted vault folder for completed sensitive media
15. Themes / icon packs

---

## C. Concrete freemium sketch

**Product:** Aurora free / **Aurora Pro**  
**Billing preference:** one-time Play unlock first (downloaders dislike subscriptions unless ongoing cloud/list hosting costs justify it).

### Free (GitHub APK ≈ free flavor)

- Full sniffer + browser tabs
- Native adblock on
- HTTP + HLS + torrent (if kept free)
- Concurrent downloads: **3**, chunks: **8**
- Local library, auto-classify, remux, notifications
- Manual backup/export
- **IDM queue import**
- UC-class in-app player (see below) as free quality bar

### Pro (Play Billing)

- All filter lists + custom list URLs + tracker pack
- Concurrent **16**, chunks **32**
- Drive sync + scheduled auto-backup
- Proxy + Wi‑Fi-only automation
- Unlimited tab groups + auto-host
- Download rules / schedule (when built)
- Per-site profiles (when built)
- *(not IDM import — free)*

---

## D. Open-source packaging tips

1. **License banner:** “Source available under X; official builds and Pro unlock only via Google Play.”
2. **Billing only in Play build:** compile-time flag / product flavor so GitHub APKs are free-tier by design.
3. **Secrets out of git:** OAuth client IDs, signing keys in CI only.
4. **Accept forks:** free marketing; compete on UX, list curation, Play reliability.
5. **Resolve GPL early** before marketing open source.

---

## E. Implementation priority (minimal, not greedy)

1. Ship free as fully usable (sniffer + downloads + native adblock + IDM import free).
2. Gate only: filter-list catalog + tracker pack + concurrent/chunk soft caps + Drive/auto-backup.
3. Build next Pro features: download rules + per-site profiles.
4. Monetize as one-time Pro unlock first; subscription only if ongoing cloud/list update hosting costs appear.
5. Raise in-app player to UC Browser parity (cookies / headers / auto-replace site player).

---

## In-app player (UC-class)

Goal: custom player as reliable as **UC Browser’s** — play anything the sniffer catches, without a floating icon as the main entry.

### Current gaps (hypothesis + product intent)

| Issue | Likely cause | Direction |
|---|---|---|
| Playback fails on many CDNs | Missing **Cookie**, **Referer**, **User-Agent**, or other headers that the page’s own player gets from the WebView | Feed the player the same cookie jar + referer + UA as the capturing tab; prefer WebView-bound fetch / ExoPlayer with full `httpHeaders` |
| Floating play button | Extra UI; easy to miss; doesn’t feel like “the site just works” | Replace as primary UX with a **settings toggle** |

### Desired UX

- **Setting toggle:** *Replace site player with Aurora* (Settings → Sniffer). Default **on**.
- When **on**: intercept site `HTMLMediaElement.play()` and open Aurora player with session cookies/headers.
- When **off**: site player unchanged; user can still open from capture tray / media sheet.
- Floating video icon **removed** (replaced by the toggle).

### Implementation status (2026-07-16)

- Setting: `DownloadSettings.replaceSitePlayer` (default true).
- JS: `assets/browser_guard.js` hooks `HTMLMediaElement.prototype.play` + `AuroraPlayChannel`.
- Dart: `_handleAuroraPlayRequest` in `sniffer_screen.dart`; multi-host cookies via `getPlaybackCookies`; HLS/DASH `formatHint` in `AuroraVideoPlayer`.
- Floating button removed from browser stack.

### Freemium stance

- **Player quality and auto-replace toggle: free.** This is core browser/downloader identity, not a Pro wedge.
- Optional later Pro: advanced codec packs, external player handoff presets, or per-site player profiles.

---

## Related docs

- **`docs/premium_implementation_tracker.md`** — in-depth phased checklist; **strike through items when done**
- `ROADMAP.md` — per-site profiles, download rules, HLS remux, library manager
- `README.md` — GPL note for `libtorrent_flutter`
- Session: `docs/sessions/2026-07-16-premium-freemium-strategy.md`
- Session: this file’s decisions also recorded under sessions for the 2026-07-16 follow-up

# Plan: Expand Play-only restricted hosts (copyright / policy high-risk)

**Branch:** `Play-Console-Launch`  
**Channel:** enforce **only** when `AURORA_BUILD_CHANNEL=play`  
**GitHub / default builds:** **no change** — full sniffer stays open  

**Goal:** On the Play edition, hard-block media sniff + download for **major DRM / ToS / Play-policy hotspots** (YouTube already). Leave **all other websites** capturable as today.

Related:

- Implementation today: `lib/compliance/restricted_media_policy.dart`  
- Compliance notes: `docs/play_store_compliance.md`  
- Launch checklist: `docs/play_console_launch_plan.md`  

---

## Principles

| Principle | Meaning |
|-----------|---------|
| **Play-only** | GitHub sideload can still sniff freely; Play binary is conservative. |
| **Hotspots only** | Block services that are classic Play-ban / copyright nightmares — not the open web. |
| **Host + page + Referer** | Block if media URL **or** page **or** Referer/Origin is restricted (CDN + player page). |
| **Prefer hosts, not brands in UI** | User message stays generic: Play policy / not supported — no “download from X” marketing. |
| **Avoid over-block** | Do **not** block entire `amazon.com`, `google.com`, `cloudfront.net`, random CDNs used by indie sites. |
| **Cache purge** | Persist + load + YouTube-style page open must drop restricted items (already started for YT). |

---

## Phase 0 — Keep as-is (already planned / done)

| Item | Status |
|------|--------|
| YouTube surfaces + `googlevideo.com` + UI assets (`success.mp3`) | Done |
| Wave 1 host groups + generic messages | Done |
| Gate only on Play channel | Done |
| **Site-level hard-off** (`tab.sniffingEnabled` + `shouldHardOffSniffing`) | Done |
| URL/CDN backstop (`isBlocked`) on intake/queue/paste/cache | Done |
| Listing never markets “grabber for TikTok/IG/…” | Product / listing (ongoing) |

---

## Phase 1 — Expand host lists (implementation)

Refactor `RestrictedMediaPolicy` from “YouTube-only” to **platform groups**, still one `isBlocked()` API.

### 1.1 Platform groups to **block on Play**

| Group | Why | Host suffixes / patterns (illustrative) |
|-------|-----|----------------------------------------|
| **YouTube / Google video** | Google ToS + Play DNA | `youtube.com`, `youtu.be`, `youtube-nocookie.com`, `googlevideo.com`, `ytimg.com`, `ggpht.com`, `youtube.googleapis.com`, `youtubei.googleapis.com` |
| **TikTok** | Heavy ToS / copyright enforcement | `tiktok.com`, `tiktokv.com`, `tiktokcdn.com`, `musical.ly`, `byteoversea.com`, `ibytedtos.com`, `ttlivecdn.com` (tune from real captures) |
| **Meta (FB / IG)** | Copyright + ToS; not a “file host” | `facebook.com`, `fb.com`, `fbcdn.net`, `fbcdn.com`, `instagram.com`, `cdninstagram.com`, `ig.me` |
| **Netflix** | DRM / commercial VOD | `netflix.com`, `nflxvideo.net`, `nflximg.net`, `nflxso.net`, `nflxext.com` |
| **Disney+ / Hulu / ESPN streaming** | DRM VOD | `disneyplus.com`, `disney.com` *(video CDN hosts only — avoid blocking all disney.com static if possible)*, `bamgrid.com`, `hulu.com`, `hulustream.com`, `espn.com` / ESPN stream CDNs as observed |
| **Max / HBO** | DRM VOD | `max.com`, `hbomax.com`, `hbo.com`, warn on shared Warner CDNs only if specific |
| **Amazon Prime Video** | DRM VOD | `primevideo.com`, `aiv-cdn.net`, `aiv-delivery.net` — **not** generic `amazon.com` shopping |
| **Apple TV+ / iTunes video** | DRM | `tv.apple.com`, known Apple video CDN host suffixes used for HLS (validate before ship) |
| **Spotify** | Music ToS / copyright | `spotify.com`, `pscdn.co`, `scdn.co`, `spotifycdn.com` |
| **Twitch** | Live/VOD ToS | `twitch.tv`, `ttvnw.net`, `jtvnw.net` |
| **Crunchyroll / big anime streamers** | DRM / licensed | `crunchyroll.com`, related CDN hosts as observed |

### 1.2 Explicitly **do not** block (keep sniffer)

Examples (non-exhaustive):

- Generic file hosts, personal sites, blogs, docs, OSS, school portals  
- Wikimedia / Internet Archive / clearly free/demo streams  
- Random `.mp4` on indie sites  
- User’s own server / NAS / direct CDN links that are not the table above  
- Google Drive / Docs (user’s own cloud — not “pirate stream grabber”) unless we later decide otherwise  
- **Whole-cloud** wildcards: `cloudfront.net`, `akamai`, `fastly` (too many legitimate uses)

### 1.3 API / message shape

```text
userMessageRestricted =
  "Downloading from this service is not supported in compliance with Google Play Store policies."

pageNoticeRestricted =
  "Media capture and download are disabled on this site for Play compliance."
```

Keep `userMessageYouTube` as an alias or retire it after call sites use the generic string.

Reasons enum (optional detail for logs):

- `youtube`, `tiktok`, `meta`, `netflix`, `disney`, `spotify`, `twitch`, `primeVideo`, `otherLicensed`  

Call sites keep using `RestrictedMediaPolicy.isBlocked(...)` only.

### 1.4 Wire points (no new isolate spawns)

Same places as YouTube:

| Layer | File |
|-------|------|
| Policy | `restricted_media_policy.dart` |
| WebView resource / download-start / HLS capture | `browser_controller.dart` |
| Engine `sniff()` | `media_sniffer_engine.dart` |
| Intake | `sniff_intake_controller.dart` |
| Queue | `download_queue.dart` |
| Paste URL | `main.dart` |
| Capture sheet | `add_queue_dialog.dart` |
| Cache load + purge | `sniffed_media_cache.dart` |
| Page notice + purge | `sniffer_screen.dart` |

---

## Phase 2 — Correctness & false positives

| Task | Accept |
|------|--------|
| Unit tests per group (host + page + Referer) | Green tests |
| `success.mp3` / YT UI assets still blocked | Yes |
| Random `example.com/video.mp4` allowed under `forceEnforce` | Yes |
| Amazon **shopping** image/PDF not blocked by Prime-only hosts | Spot-check |
| Meta: block `cdninstagram` / `fbcdn` media, not every random site embedding a FB like button script as “download” | Prefer media path + host list |
| Live capture pass on Play debug APK | TikTok/IG/Netflix page → no useful media cards; indie site → still works |
| GitHub build still sniffs YT/TikTok if desired | `AURORA_BUILD_CHANNEL` unset/github |

---

## Phase 3 — Product / listing alignment

| Task | Notes |
|------|--------|
| Listing copy already generic | `play_store_listing.md` — keep no brand-grabber claims |
| In-app snackbar generic | No “Netflix blocked” brand spam; one policy message |
| Optional Settings blurb (Play only) | “Some commercial streaming sites disable capture for Play policy” |
| Do **not** add “supported sites” that name TikTok/IG as download targets | |

---

## Phase 4 — Docs & ship

| Task | Notes |
|------|--------|
| Update `play_store_compliance.md` with full Play host groups | |
| Update `play_console_launch_plan.md` checkbox | Phase A compliance |
| Commit on `Play-Console-Launch` | No secrets |
| Rebuild Play AAB / debug APK | `--dart-define=AURORA_BUILD_CHANNEL=play` |
| Internal smoke | YT + one social + one VOD + one random site |

---

## Out of scope (this plan)

| Out | Why |
|-----|-----|
| Blocking “all social + all video sites forever” | Kills product; not required |
| DRM circumvention / Widevine cracking | Never |
| System-wide adblock / VPN | Separate policy; already in-app only |
| Changing GitHub edition behavior | User wants full sniffer there |
| Legal advice on every CDN on earth | Host list is best-effort; review with real traffic |

---

## Suggested implementation order (when coding)

1. Refactor policy to **grouped host lists** + generic message (keep YT behavior).  
2. Add TikTok + Meta + Netflix + Spotify + Twitch (highest “grabber” association).  
3. Add Prime Video / Disney+ / Max / Crunchyroll with **narrow** CDN hosts.  
4. Tests + cache purge already required.  
5. Play debug smoke.  
6. Docs + AAB.

---

## Success criteria

- Play build: no useful capture/download from **listed** nightmares (incl. UI crumbs like YT `success.mp3`).  
- Play build: normal web / direct files / non-listed sites still work.  
- GitHub build: unrestricted sniffer (unless user later asks otherwise).  
- Listing + app name stay **browser & downloader**, not multi-platform grabber.

---

## Decisions (resolved)

| # | Topic | Decision |
|---|--------|----------|
| 1 | Message unification | **Single generic message only.** Retire `userMessageYouTube` / `pageNoticeYouTube` at call sites; keep temporary aliases only if needed for a one-commit migrate, then delete. |
| 2 | Host list validation | **Ship plan lists as v1**, then tune from Play smoke (not a long research phase). Document “observed in smoke” when adding CDN hosts. |
| 3 | `disney.com` | **Do not block `disney.com`.** Start with `disneyplus.com`, `bamgrid.com`, Hulu/ESPN stream hosts only. |
| 4 | Apple TV+ | **Start empty or stub group** until we have one real capture/log; no inventing CDN suffixes. |
| 5 | Crunchyroll | **Wave 2** (with VOD/DRM), not wave 1. Wave 1 = YT + TikTok + Meta + Netflix + Spotify + Twitch. |
| 6 | Tests | **One (or few) tests per group** + shared negatives (`example.com`, shopping Amazon) + one page/Referer case. Not one test per host. |

### Revised implementation waves

| Wave | Platforms |
|------|-----------|
| **Wave 1** | YouTube (existing), TikTok, Meta (FB/IG), Netflix, Spotify, Twitch |
| **Wave 2** | Prime Video (narrow), Disney+ / Hulu (no bare `disney.com`), Max/HBO, Crunchyroll |
| **Wave 3** | Apple TV+ only after real host evidence |

### Message strings (canonical)

```text
userMessageRestricted =
  "Downloading from this service is not supported in compliance with Google Play Store policies."

pageNoticeRestricted =
  "Media capture and download are disabled on this site for Play compliance."
```

---

## Change log

| Date | Note |
|------|------|
| 2026-07-17 | Plan written: expand Play-only restricted hosts; keep other websites. |
| 2026-07-17 | Resolved open questions: generic messages; v1 lists + smoke; no bare disney.com; Apple deferred; Crunchyroll wave 2; tests per group + negatives. |

# 2026-07-16 — Download failure investigation (localhost:8080)

### 2026-07-16 — User command

> *Playwright http://localhost:8080/ why is my download failing?*

- **Agent:** Grok (parent)
- **Task:** Investigate live download failures via log server + adb logcat + local queue snapshot

## Findings

### Log server / Playwright

- `adb forward tcp:8080 tcp:8080` is active; device listens on `0.0.0.0:8080`.
- HTTP to `http://127.0.0.1:8080/` accepts TCP but never returns bytes (timeout). Dashboard unusable until app/log server recovers.
- Playwright MCP browser was already locked by another session (`mcp-chrome-bd5f7da`).

### Live failure (logcat, app PID 20278)

Repeated for ~7 min:

```
[HlsDownloader] Initial playlist fetch failed: HttpException: HLS playlist request failed (403).
Fallback results: Dart:403 Native:null
uri = https://surrit.com/2e9fae52-639b-47c0-807f-233407050577/1080p/video.m3u8
```

Also tried `480p` variant — same 403. App still had `active downloads: 1–2` while retries looped.

### Queue snapshot (local_download_queue.json paused)

| Item | Host | Error |
|------|------|--------|
| MIMK-056 / MIMK-186 / cloudwish | mycloudz / cloudwish | HLS playlist 403; Dart fallback **410 Gone** |
| HOMA-077 / SIRO-4960 | surrit.com | HLS playlist 403 after 10 auto-retries |
| HOMA-123 | surrit.com | `Token expired, refreshing...` (partial) |
| rapidgator homa-123.bin | rapidgator | HTTP **404** |
| EBON-006 | mycloudz | paused partial (~6 MB / 1.1 GB), no error string |

## Root cause

CDN / host signed HLS URLs expired. Server returns **403** (and sometimes **410**). Auto-retry cannot mint a new token; need re-sniff / Update link from the source page.

## Follow-up: Surrit CF block page vs Aurora (user correction)

User noted: opening `https://surrit.com/.../480p/video.m3u8` shows Cloudflare "You have been blocked", yet the stream still works when played/fetched from `missav.ws` — and they expect Aurora to behave like that.

### Clarified root cause (not "link dead")

| Path | Result |
|------|--------|
| Browser address bar → surrit m3u8 (document nav) | Cloudflare **block HTML** |
| WebView XHR from missav context (`fetchPlaylistBodyViaJavaScript`) | **SUCCESS** — real `#EXTM3U` (~78k chars, 2400 segs) |
| Dart HTTP / native HTTP | **403** (TLS fingerprint / WAF) |
| HlsDownloader at fail time | Cache miss + `WebView JS fetch returned null/empty` → falls through to Dart:403 |

Live log at failure:

```
Cache MISS ... (hlsPlaylistCache is set but returned null)
WebView JS fetch returned null/empty
All fetch attempts failed ... Dart:403 Native:null
```

Earlier same session: `fetchViaJavaScript failed: ERROR:EXCEPTION:network error` while sniffer's playlist body fetch later succeeded.

### Gaps

1. Sniffer uses `fetchPlaylistBodyViaJavaScript`; downloader uses `fetchViaJavaScript` (stricter / can return null).
2. `_fetchPlaylist` has **no** headless-WebView fallback (segments do).
3. After WebView fails, Dart HTTP is useless against Cloudflare — wastes retries and looks like a dead link.
4. Playlist cache can miss for the exact quality URL even when another quality was just cached.

### Fix (Post-Gate-Production, same session)

> *Sure, but use this branch (Post-Gate-Production). AND YOU SAID OUR SNIFFER AND DOWLOADER WERE GREAT ALREADY.*

- **Agent:** Grok (parent)
- **Task:** Close sniffer/downloader gap for Cloudflare HLS playlists

Implemented:
1. Download task bridges → `fetchPlaylistBodyViaJavaScript` (sniffer path).
2. `HlsDownloader._fetchPlaylist`: cache → WebView → **headless** → Dart → native; usable-body check; accurate error detail.
3. `lookupHlsPlaylistCache` exact + host/path match; reject CF HTML.
4. Unit tests pass for cache lookup.

Honest note: sniffer path was solid; downloader path was **not** at the same level for WAF playlists — that was the bug, not the stream being dead.

### 2026-07-16 — User command

> *Setting screen is a mess.*

- **Agent:** Grok (parent)
- **Task:** Redesign Settings hub navigation

Hub was a 2-col card grid under a single wrong "Downloads" label, with empty half-rows for Rules/Pro, uneven subtitles, Drive only via a mislabeled Sync button that actually disconnected. Replaced with grouped full-width nav lists (Downloads / Browser / Appearance / Data & account / About), Pro badges, Drive as a real row, profile header opens Drive page.

### 2026-07-16 � User command

> *Ohh and our downloaded videos usually has no sound when played using HW mode in MX Player, but it does in HW+*

- **Agent:** Grok (parent)
- **Task:** Fix TS?MP4 remux for HW decoder audio silence

Root cause: native remuxTsToMp4 wrote tracks sequentially (not interleaved) and often lacked AAC csd-0. Pure HW decoders drop silent audio; HW+ falls back to SW parsing.
Fix: interleave samples by PTS, A/V tracks only, synthesize AudioSpecificConfig when missing.

### 2026-07-16 � User command

> *It is still not working, it downloaded 142KB and then stay at 0 while for the same source https://missav.ws/en/lulu-099-uncensored-leak, 1DM is downloading stably at around 5MB/s*

- **Agent:** Grok (parent)
- **Task:** Wire native streamSegmentToFile into HLS (1DM-class path)

Live: Speed 0 for 200s+; Headless XHR timeouts; WebView controller disposed.
Root cause: native streamSegmentToFile existed but was never called from Dart HLS; segments used WebView base64/headless only.
Fix: primary path NetworkBindingService.streamSegmentToFile; high concurrency; native bg thread + identity encoding.

### 2026-07-16 � User command

> *Do we really need the refreshing link after clicking the download button in the download confirmation?*
> *I do.* (remove it)

- **Agent:** Grok (parent)
- **Task:** Remove pre-download m3u8 refresh from add-queue confirmation

Enqueue selectedMedia.url immediately; spinner only for quality loading; mid-download onTokenExpired remains for real 403 recovery.

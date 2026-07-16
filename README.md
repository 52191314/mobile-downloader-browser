# Aurora Downloader

**Android download manager + media sniffer** — inspired by [1DM](https://play.google.com/store/apps/details?id=idm.internet.download.manager), built with Flutter.

Segmented multi-thread HTTP downloads, HLS/DASH capture, an in-app browser that sniffs media as you browse, native BitTorrent/magnet support, a UC-style in-app player, hybrid adblock, and a Nordic glass UI.

| | |
|---|---|
| **Platform** | Android only (API 24+) |
| **Version** | 2.4.0+23 |
| **License** | [GPL-3.0](LICENSE) |
| **Repo** | [github.com/52191314/Aurora-Downloader](https://github.com/52191314/Aurora-Downloader) |

> **Open source + freemium:** Source is public under GPL-3.0. Core downloading and sniffing stay free. Optional **Aurora Pro** gates power features (extra filter lists, higher concurrency, Drive sync, proxy, etc.). Play Billing is planned; debug builds can force Pro for development.

---

## Why Aurora?

- **Catch media while browsing** — not only paste a URL. The browser hooks DOM, `fetch`/`XHR`, media elements, and resource loads.
- **Survive real CDNs** — cookies, Referer, User-Agent, WebView-bound fetches for WAF/Cloudflare-style hosts, HLS token refresh.
- **Finish the job** — pause/resume, multi-chunk HTTP, HLS segment download + AES-128, TS→MP4 remux, auto-classify into folders, notifications + foreground service.
- **Stay usable** — floating dock, queue + browser + settings, tab groups, capture tray, Nordic light/dark UI.

---

## Features

### Downloads (queue)

- Multi-threaded **segmented HTTP** downloads (range requests, configurable chunks per task)
- **Concurrent downloads** (soft-capped free; higher caps on Pro)
- Pause / resume / cancel / priority queueing
- **Speed limiter** (token-bucket style)
- **Auto-retry** with configurable retry limit
- Stall detection: min-speed threshold, stall timeout, partial-download merge suggestions
- **SHA-256** verification path for completed files
- **Force merge** salvage for incomplete chunk/HLS sets
- **Wi‑Fi only** downloads (Pro-gated)
- **HTTP / SOCKS5 proxy** with optional credentials (Pro-gated)
- **Auto-classify** completed files into Videos / Audio / Images / Documents / … (custom extension→folder maps)
- **Quality suffix** in filenames (e.g. ` (720p)`) when resolution is known
- **Page-title-aware naming** (prefers `og:title` / full page title over URL slug)
- Collision-safe unique paths (` (1)`, ` (2)`, …)
- **IDM queue import** (always free)
- Manual URL / magnet / torrent intake into the queue
- Open / share / export completed files to public Downloads
- Queue search, sort, filters, bulk pause/resume/retry/cancel
- Swipe actions on task cards (pause/resume, delete)
- Per-task properties dialog
- Duplicate URL detection (including token-refreshed same-path media)
- “Refresh download” / update existing task URL after re-sniff
- External open from queue: refresh link, scan in browser, view source page
- Android **share / open-with / intent** routing (URL → queue or browser; magnets/torrents → queue)
- Download **history** retention with stale failed-temp GC
- Structured **error classification** with user-facing fix hints

### HLS / DASH / streaming

- Master + media playlist parse (HLS)
- **DASH MPD** parse (representations / dimensions / codecs)
- Multi-quality / variant expansion in the capture UI
- Segment download with concurrency limits (esp. WebView-bound paths)
- **AES-128** decryption for encrypted HLS
- fMP4 vs MPEG-TS segment validation
- **Sampled size estimation** (not “HEAD every segment”)
- Progressive size refine while downloading
- **TS → MP4 remux** after merge (Android MediaExtractor/Muxer; setting-controlled)
- Host-specific hardening (e.g. same-origin Referer for surrit-style CDNs)
- Circuit breaker / 403 handling; skip bare HTTP when CDN blocks, fall back to WebView path
- Headless WebView fetcher for WAF-bound segments
- Disguised segment filtering (e.g. TS under `.woff2` / image extensions)

### Torrents

- Native **BitTorrent / magnet** via [`libtorrent_flutter`](https://pub.dev/packages/libtorrent_flutter) (GPL-3.0)
- Deterministic simulated torrent path for automated tests

### In-app browser & media sniffer

- Full **WebView browser** (flutter_inappwebview)
- **Multi-tab** browsing with session restore (`browser_tabs.json`)
- **Samsung-style tab groups**: colors, drag-and-drop, list/grid, auto-host grouping (limits on free; full on Pro)
- Bottom (or top) **address bar**, suggestions, search engines
- Desktop mode + **User-Agent profiles** (mobile / Chrome / Firefox / Safari)
- **Per-site User-Agent** overrides (Pro-gated)
- Private mode
- Reader mode
- Find-in-page
- Zoom per site
- **Safe browsing** checks
- Popup blocking
- Invisible redirect interception + choice dialog (foreground / background / current tab / ignore)
- Session recovery after crash
- Context menu (link / image / media / text): open, download, copy, search, translate, block element
- **Element picker** — tap page elements to build cosmetic block rules
- Autofill helpers
- In-page **translate** target language setting
- Favorites / bookmarks with folders
- History
- Saved pages
- Library **export / import** (selective backup of favorites, history, queue, settings)
- Sniffed media **cache** per tab (persisted)
- Capture tray / media catch sheet: filters, sort, multi-select, details, preview, add to queue
- Media enrichment: size, duration, dimensions, codecs, frame rate, live flag, container format
- Persistent **worker isolate pool** for probes / JSON / binary media parse (avoids spawn storms)
- JS guard: DOM scan, media `src` hooks, `fetch`/`XHR` intercept, MutationObserver, page meta (`og:title`, etc.)
- Dart-side video `currentSrc` poll as CSP bypass
- Background tab timer pause for battery
- Performance-minded adblock intercept (main-frame / allowlist / early exits)

### In-app player (free)

- Custom **Aurora video player** (full-screen controls, speed, lock, aspect fit)
- **Replace site player** toggle — intercept page `play()` and open Aurora with session cookies/headers
- Multi-host **cookie merge** + Referer / UA for CDN playback
- HLS/DASH format hints for ExoPlayer
- Capture-tray preview for non-video media
- PiP fallback path retained for resilience

### Adblock & privacy

- Hybrid **native C++ adblock** (`libaurora_adblock.so`: domain trie + Aho-Corasick) with **Dart fallback**
- Remote **filter list catalog** (EasyList-family and others) — free slot cap; full catalog on Pro
- **Custom filter list URL** (Pro)
- **Tracker blocking pack** (Pro)
- Manual network rules + **cosmetic** rules
- Per-site **adblock allowlist**
- Do Not Track preference
- Popup / invisible-redirect controls

### Google Drive & backup

- **Google Drive** sign-in + upload/sync (Pro-gated; needs OAuth client IDs)
- **Manual** backup/export & restore (free)
- **Scheduled auto-backup** of app data JSON to Downloads (Pro-gated interval)
- Backup retention / restore UI for snapshots

### Notifications & reliability

- Local notifications for progress / completion / failures
- **Foreground download service** (dataSync) for background survival
- Battery optimization exemption prompt + **OEM autostart** guidance (Xiaomi, Huawei, OPPO, Vivo, OnePlus, Samsung, …)
- Wake lock where needed for long downloads
- Network process binding helper (e.g. Secure Folder DNS edge cases)

### UI / shell

- **Aurora Glass** theme: Nordic dark + light (Snow Storm), optional OLED black
- Floating **dock** navigation: Queue | Browser | Settings
- Queue metrics / progress visualization
- Settings dashboard cards (Defaults, Adblock, Search, Sniffer, Appearance, Network, Backup, Drive, About, **Aurora Pro**)
- Diagnostics page / logging
- Snackbar coalescing, spring animations, hold-to-swipe cards
- Brand logo on About

### Aurora Pro (freemium)

Implemented gates (see `docs/premium_implementation_tracker.md` and `docs/premium_freemium_strategy.md`):

| Area | Free | Pro |
|------|------|-----|
| Concurrent downloads | up to 3 | up to 16 |
| Chunks per task | up to 8 | up to 32 |
| Remote filter lists | up to 2 enabled | unlimited + custom URLs |
| Tracker pack | no | yes |
| Tab groups | limited | unlimited + auto-host |
| Proxy | no | HTTP + SOCKS5 + auth |
| Wi‑Fi only / advanced stall knobs | basic retry | full |
| Per-site UA map | global only | per-site |
| Drive sync | no | yes |
| Scheduled auto-backup | manual only | intervals |
| Sniffer, player, core download, IDM import | **yes** | yes |

- Play Billing one-time unlock: **planned** (not required for source builds).
- Debug builds: **Settings → Aurora Pro → Debug: Force Pro** (not persisted; resets on restart).

### Developer / internals

- Structured app logging (`AuroraLog`) with verbosity
- Optional debug log server
- Session logs under `docs/sessions/`
- Code map: `docs/code-maps/projects/aurora_downloader.md`
- Unit/widget tests under `test/`
- Agent notes: `AGENTS.md`

---

## Screenshots

_Add screenshots here when ready (queue, browser capture tray, player, settings)._

---

## Requirements

- Flutter SDK (project uses Dart `^3.8.1`)
- Android SDK / NDK for builds  
  - Min SDK: **24**  
  - Compile SDK: **36**  
  - NDK: **27.0.12077973** (as configured in the Android project)
- Physical device or emulator (arm64 recommended for daily testing)

---

## Build

### Debug (fast iteration)

```powershell
flutter build apk --debug --target-platform android-arm64
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

### Release

```powershell
flutter build apk --release --target-platform android-arm64
```

APKs land in `build/app/outputs/flutter-apk/`.

### Google Drive (optional)

Needs an Android OAuth client (`com.personal.aurora_downloader` + SHA-1) and a **Web** client ID at build time:

```powershell
flutter run --dart-define=AURORA_GOOGLE_SERVER_CLIENT_ID="YOUR_WEB_CLIENT_ID.apps.googleusercontent.com"

flutter build apk --release --dart-define=AURORA_GOOGLE_SERVER_CLIENT_ID="YOUR_WEB_CLIENT_ID.apps.googleusercontent.com"
```

Use the Web application **Client ID** only. Do **not** commit client secrets.

---

## Verify

```powershell
flutter analyze
flutter test
flutter build apk --debug --target-platform android-arm64
```

---

## Project layout (high level)

```text
lib/
  downloader/   # HTTP splitter, HLS, torrent, queue, naming
  sniffer/      # browser, capture, adblock, player, tabs
  premium/      # Pro entitlement + feature gates + upsell
  backup/       # auto-backup
  sync/         # Google Drive
  settings/     # DownloadSettings model
  ui/           # queue, settings, dock, widgets
  theme/        # Aurora colors / glass
  platform/     # native bridges (downloads, remux, FGS)
  native/       # adblock FFI
assets/         # browser_guard.js, brand, etc.
android/        # Kotlin + native adblock C++
docs/           # strategy, implementation tracker, sessions
```

---

## License

This project is licensed under the **GNU General Public License v3.0** — see [LICENSE](LICENSE).

You may run, study, share, and modify the software under GPL-3.0. If you distribute binaries (including modified versions), you must provide corresponding source under the same license.

**Note:** BitTorrent support uses `libtorrent_flutter`, which is also **GPL-3.0**. That dependency is a primary reason this app is GPL-3.0 as a whole.

Commercial use (including selling on Google Play) is allowed under GPL-3.0; freemium feature gates do not replace or restrict the GPL rights to the source.

---

## Contributing

Issues and PRs are welcome. Please:

1. Stay on topic (download manager / sniffer / Android).
2. Prefer small, reviewable changes.
3. Run `flutter analyze` and relevant tests before submitting.
4. Do not commit secrets, local queue dumps, or device-only JSON.

---

## Disclaimer

Aurora Downloader is a general-purpose download and browsing tool. You are responsible for complying with applicable laws and the terms of service of sites and services you access. The authors are not liable for misuse.

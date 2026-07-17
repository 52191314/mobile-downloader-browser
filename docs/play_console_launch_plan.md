# Play-Console-Launch — planned work

**Branch:** `Play-Console-Launch`  
**Purpose:** First Google Play publish path + residual freemium/player work that is **not** required before internal testing.

Related docs (detail, not this plan):

| Doc | Role |
|-----|------|
| [`play_store_console_runbook.md`](./play_store_console_runbook.md) | Day-by-day Console steps |
| [`play_store_listing.md`](./play_store_listing.md) | Title, description, screenshots |
| [`play_store_compliance.md`](./play_store_compliance.md) | Policy gates (YouTube, billing, storage) |
| [`play_signing.md`](./play_signing.md) | Upload keystore / release AAB |
| [`play_console_app_content.md`](./play_console_app_content.md) | App content form answers (privacy, ads, rating, data safety, …) |
| [`play_restricted_hosts_plan.md`](./play_restricted_hosts_plan.md) | Expand Play-only blocks (YT, TikTok, Meta, Netflix, …); keep other sites |
| [`build_channels_and_defines.md`](./build_channels_and_defines.md) | `AURORA_BUILD_CHANNEL` |
| [`premium_implementation_tracker.md`](./premium_implementation_tracker.md) | Full freemium backlog (strike items when done) |

When an item below is finished: mark it here **and** ~~strike~~ the matching tracker line if it lives in the freemium tracker.

---

## Priority order (do in this sequence)

1. **Play Console internal testing** (get a green install from Play)  
2. **Only fix what Console / review / billing break**  
3. **Residual product** (player polish, P2.4+, P3/P4, legal packaging) as capacity allows  

Do **not** block first upload on U/P3/P4.

---

## Phase A — First Play upload (launch-critical)

### A.1 Signing & binary

| # | Task | Status | Notes |
|---|------|--------|--------|
| A.1.1 | Upload keystore + `android/key.properties` | Done locally | **Backup both** — never commit |
| A.1.2 | Release AAB not debug-signed | Done | `flutter build appbundle --release --dart-define=AURORA_BUILD_CHANNEL=play` |
| A.1.3 | YouTube block on Play channel (sniffer + engine + queue) | Done in tree | `RestrictedMediaPolicy` + `browser_controller` / `media_sniffer_engine` |
| A.1.4 | Re-upload AAB after any compliance code change | ○ | Rebuild + Console “Create new release” |
| A.1.5 | Confirm Play App Signing enabled in Console | ○ | After first accepted upload |

### A.2 Play Console app setup

| # | Task | Status | Notes |
|---|------|--------|--------|
| A.2.1 | Create app (if missing) | ○ | Name from listing doc |
| A.2.2 | Privacy policy URL live + linked | ○ | Required for store listing |
| A.2.3 | Short + full description | ○ | Copy: `play_store_listing.md` |
| A.2.4 | Icon + feature graphic | ○ | Brand assets under `assets/brand/` |
| A.2.5 | Phone screenshots (clean, no platform-grab marketing) | ○ | Generic / free demo streams only |
| A.2.6 | Content rating questionnaire | ○ | Honest about unrestricted web |
| A.2.7 | Target audience / news / ads declarations | ○ | Ads: none unless you add them |
| A.2.8 | Data safety form | ○ | Align with real behavior |
| A.2.9 | App access / contact details | ○ | Support email |
| A.2.10 | FGS / notification permission declarations | ○ | Downloads use `dataSync` FGS |

### A.3 Monetization (Play)

| # | Task | Status | Notes |
|---|------|--------|--------|
| A.3.1 | Merchant / payments profile | ○ | If selling Pro |
| A.3.2 | Create IAP **`aurora_pro_unlock`** (one-time) + activate | ○ | Must match code |
| A.3.3 | License testers | ○ | Your Gmail(s) |
| A.3.4 | Smoke: buy + restore on Play-channel install | ○ | Internal testing track |

### A.4 Internal testing track

| # | Task | Status | Notes |
|---|------|--------|--------|
| A.4.1 | Upload signed AAB → Internal testing | ○ | Move track Inactive → Active |
| A.4.2 | Join as tester, install from Play | ○ | |
| A.4.3 | Smoke: queue download (non-YouTube) | ○ | |
| A.4.4 | Smoke: YouTube → no capture / no download | ○ | Play build only |
| A.4.5 | Smoke: Pro upsell / purchase (tester) | ○ | |
| A.4.6 | Fix rejects only; re-cut AAB as needed | ○ | Stay on this branch |

### A.5 Production (after internal is green)

| # | Task | Status | Notes |
|---|------|--------|--------|
| A.5.1 | Closed / open testing (optional) | ○ | |
| A.5.2 | Production release | ○ | Same signing key forever |
| A.5.3 | Monitor policy + crashes 48h | ○ | |

---

## Phase B — Residual freemium / product (not launch-critical)

Track detail and Done notes in [`premium_implementation_tracker.md`](./premium_implementation_tracker.md). Summary only here.

### B.1 Player residual (Phase U)

| # | Task | Tracker | Status |
|---|------|---------|--------|
| B.1.1 | Tokenized HLS playback harden | U.1.4 | ○ |
| B.1.2 | Playback diagnostics | U.1.5 | ○ |
| B.1.3 | Per-site replace-player override | U.2.5 | ○ |
| B.1.4 | Resume / quality from auto-replace | U.3.1 | ○ |
| B.1.5 | PiP / background audio | U.3.2 | ○ |
| B.1.6 | External player handoff | U.3.3 | ○ |

### B.2 Pro later (P2.4+)

| # | Task | Tracker | Status |
|---|------|---------|--------|
| B.2.1 | Multi-device entitlement notes (Play handles) | P2.4.1 | ○ |
| ~~B.2.2~~ | ~~Queue metadata sync via Drive~~ | ~~P2.4.2~~ | ~~—~~ (Cancelled) |
| B.2.3 | WebDAV | P2.5.1 | ○ |
| B.2.4 | S3 / Nextcloud | P2.5.2 | ○ |

### B.3 Tier-2 / Tier-3 (P3 / P4)

| # | Area | Status |
|---|------|--------|
| B.3.1 | P3.1–P3.6 (FFmpeg, library, clipboard, bangs, filter packs, diagnostics) | ○ |
| B.3.2 | P4.1–P4.4 (watch-later, desktop companion, vault, themes) | ○ |

### B.4 Legal / packaging (L)

| # | Task | Tracker | Status |
|---|------|---------|--------|
| B.4.1 | License decision (GPL / modular torrent / dual) | L.1 | ○ |
| B.4.2 | README + listing freemium language polish | L.2 | ○ partial |
| B.4.3 | CI secrets for OAuth / billing (no secrets in git) | L.3 | ○ |
| B.4.4 | F-Droid / GitHub free APK recipe | L.4 | ○ |

---

## Phase C — Hygiene on this branch

| # | Task | Status | Notes |
|---|------|--------|--------|
| C.1 | Commit Play compliance + signing Gradle + gitignore on this branch | ○ | Don’t commit `key.properties` / `*.jks` |
| C.2 | Keep `AURORA_BUILD_CHANNEL=play` for store validation builds | ongoing | Default/GitHub channel for sideload |
| C.3 | Merge back to `Post-Gate-Production` when user asks | ○ | Not automatic |

---

## Build cheat sheet (this branch)

```bash
# Play-shaped release AAB (Console upload)
flutter build appbundle --release --dart-define=AURORA_BUILD_CHANNEL=play

# Play-shaped debug (device smoke, not for Console)
flutter build apk --debug --target-platform android-arm64 --dart-define=AURORA_BUILD_CHANNEL=play
adb install -r build/app/outputs/flutter-apk/app-debug.apk

# GitHub / full sniffer (YouTube allowed)
flutter build apk --debug --target-platform android-arm64
```

AAB path:

```text
build/app/outputs/bundle/release/app-release.aab
```

---

## Backup (before more Console work)

See conversation checklist; minimum:

1. `android/upload-keystore.jks`  
2. `android/key.properties`  
3. Play developer + Google account recovery  

---

## Out of scope on this branch (unless user says otherwise)

- Unrelated Capture/UI redesigns that belong on general production without a Play need  
- Random side branches  
- Committing signing secrets or logcat dumps  

---

## Change log

| Date | Note |
|------|------|
| 2026-07-17 | Plan created for `Play-Console-Launch`. Phase A = Console first; Phase B = residual tracker. |

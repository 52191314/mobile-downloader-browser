# Google Play Store Compliance Guide — Aurora Downloader

Essential engineering, listing, and billing rules to keep Aurora Downloader on Google Play without policy rejection or account risk.

**Status (2026-07-17):** Core engineering gates implemented (YouTube block, Play Billing channel, MediaStore storage, listing copy).  
Still required before production: live privacy policy URL, Play Console forms, IAP product activation, clean screenshots, internal test pass.  
See [Verdict](#verdict) and [`play_store_listing.md`](./play_store_listing.md).

---

## Policy sources (use these)

### Binding legal / full policy

| Link | Role |
|------|------|
| [Developer Distribution Agreement (DDA)](https://play.google.com/about/developer-distribution-agreement.html) | Legal contract. §4.1 requires Developer Program Policies; §4.9 bans unauthorized interference with devices/networks/services. |
| [Developer Program Policy (full)](https://support.google.com/googleplay/android-developer/answer/17190352) | Master policy document (content, IP, device abuse, monetization, etc.). |

### Policies this checklist actually depends on

| Link | Why it matters for Aurora |
|------|---------------------------|
| [Device and Network Abuse](https://support.google.com/googleplay/android-developer/answer/9888379) | No ToS-violating use of third-party services/APIs; no blocking other apps’ ads; WebView security rules. |
| [Intellectual Property](https://support.google.com/googleplay/android-developer/answer/9888072) | No copyright/trademark abuse; no apps or listings that encourage unauthorized local copies of copyrighted media. |
| [Payments](https://support.google.com/googleplay/android-developer/answer/9858738) | Digital upgrades must use Play Billing; no steering users to external checkout. |
| [Understanding Payments policy](https://support.google.com/googleplay/android-developer/answer/10281818) | FAQ on external links, reader apps, regional exceptions. |
| [All files access (`MANAGE_EXTERNAL_STORAGE`)](https://support.google.com/googleplay/android-developer/answer/10467955) | Broad storage almost always rejected for ordinary downloaders; use MediaStore/SAF. |

### Operational (not policy proof)

| Link | Role |
|------|------|
| [Play Console](https://play.google.com/apps/publish) | Publishing, declarations, listing. |
| [Play Developer APIs](https://developer.android.com/google/play/developer-api) | Publishing / IAP / reporting automation only. |

---

## Compliance checklist

### 1. Block YouTube media download/sniff (mandatory, incomplete if only two domains)

**Policies:** Device and Network Abuse (ToS-violating service use); Intellectual Property (unauthorized local copies / encouraging infringement).

YouTube’s terms disallow unauthorized download. Google enforces this aggressively for Play apps.

**Required behavior**

* Disable media sniffing and download when the page, referrer, or media URL is YouTube-related.
* Show a clear notice, e.g.  
  > *“Downloading from YouTube is not supported in compliance with Google Play Store policies.”*

**Do not stop at `youtube.com` / `youtu.be` only.** Harden host checks to cover common properties and CDNs, for example:

* `youtube.com`, `m.youtube.com`, `music.youtube.com`, `youtube-nocookie.com`, `youtu.be`
* `googlevideo.com` and other known YouTube media hosts when tied to YouTube playback

Also block media whose **origin/referrer** is YouTube even if the file URL is on a CDN.

**Implemented (2026-07-17):**

* `lib/compliance/restricted_media_policy.dart` — host + page + Referer/Origin evaluation  
* **Enforced only when `AURORA_BUILD_CHANNEL=play`.** GitHub / default builds keep YouTube sniff + download enabled.  
* **Primary sniffer gates (required for Play AAB):**
  * `lib/sniffer/browser_controller.dart` — `onLoadResource`, download-start, native HLS playlist capture  
  * `lib/sniffer/media_sniffer_engine.dart` — `sniff()` entry rejects YouTube / CDN / YouTube page context  
* Also: sniffer intake, `DownloadQueue`, paste URL, capture sheet, page-load notice  
* Unit tests: `test/compliance/restricted_media_policy_test.dart`

**Important limit:** YouTube blocking is **necessary**, not **sufficient**. DNA also bans using **any** service/API in a way that violates **its** terms. IP policy also targets apps that facilitate unauthorized offline copies of copyrighted works in general — not only YouTube. Product + listing must not be positioned as a multi-platform “grabber” for locked services (Netflix, TikTok, Instagram, etc.).

---

### 2. Keep ad-blocking confined to Aurora’s WebViews

**Policy:** Device and Network Abuse — “Apps that block or interfere with another app displaying ads.”

**Required behavior**

* Adblock only filters network requests **inside Aurora’s built-in browser WebViews**.
* No system-wide blocking: no local VPN, private DNS takeover, proxy for other apps, or accessibility-based ad interception.

**Status note:** Native engine (`libaurora_adblock.so` / `ad_block_engine_native.dart`) is the intended compliant design **if** it remains WebView-request-only. Do not claim “fully compliant” without verifying nothing system-wide is installed or enabled.

---

### 3. Store listing and metadata (trademarks + copyright encouragement)

**Policy:** Intellectual Property (trademark + “encouraging copyright infringement”); Store Listing rules.

**Required behavior**

* **Screenshots / promo video:** Do **not** show downloading from YouTube, Netflix, TikTok, Instagram, Facebook, etc. Use generic sites or clearly free/royalty-safe demo streams.
* **Title / short description:** Generic product terms only. Avoid  
  *“Universal TikTok & Insta Video Grabber”*  
  Prefer e.g. *“Aurora: Private Web Browser & Download Manager”* or *“Fast Web Downloader”*.
* **No trademark keyword stuffing** in long description or tags (Facebook, Instagram, Netflix, …).
* **Do not encourage unauthorized downloads** in copy (IP policy cites listing text and screenshots that push users to grab copyrighted media as violations).

Position the Play app as a **browser + download manager for user-authorized / personal files**, not a pirate streaming toolkit.

---

### 4. Google Play Billing for digital upgrades (Play build)

**Policy:** Payments §§2–4; Understanding Payments FAQ.

**Required behavior (default worldwide rule)**

* Premium / Pro / digital feature unlocks in the **Play-distributed** app must use **Google Play Billing**.
* No Stripe, PayPal, or other external checkout for digital features **inside** the Play app.
* Play build must **not** link or steer to GitHub/donate/external pages that sell or unlock the same digital features (listing, buttons, webviews, CTAs, signup flows).

**Implemented (2026-07-17):**

* `in_app_purchase` + `lib/premium/play_billing_service.dart`  
* Product id: `aurora_pro_unlock`  
* Channel flag: `--dart-define=AURORA_BUILD_CHANNEL=play|github` (`lib/premium/build_channel.dart`)  
* GitHub channel: no purchase path; CTA text points at Play edition only (no external checkout URL)  
* Offline entitlement cache: `pro_entitlement.json`  
* Settings → Aurora Pro buy/restore + upsell sheet wiring  

**Console still required:** create/activate IAP `aurora_pro_unlock`, license testers, signed Play AAB.

**Allowed nuance**

* Separate non-Play builds (e.g. GitHub APK) may omit billing; **parity is not required**.
* Enrolled **regional** programs (EEA / US / India / Korea) can change rules **only** if enrolled. Default remains: Play Billing + no external digital checkout steering.

---

### 5. Storage permissions: MediaStore, not All files access

**Policy:** [All files access (`MANAGE_EXTERNAL_STORAGE`)](https://support.google.com/googleplay/android-developer/answer/10467955).

**Required behavior**

* Write downloads via **MediaStore** (or SAF where the user picks a location).
* Do **not** request `MANAGE_EXTERNAL_STORAGE` for a standard downloader. “Media files access” is an **invalid** use case for All files access; approval is rarely granted and often rejected.

**Audit (2026-07-17):** `AndroidManifest.xml` has **no** `MANAGE_EXTERNAL_STORAGE`. Writes use MediaStore (`MainActivity.kt` / `PublicDownloadsService`). `WRITE_EXTERNAL_STORAGE` is limited with `maxSdkVersion="28"` only.

---

## Listing & Console docs

| Doc | Purpose |
|-----|---------|
| [`play_store_listing.md`](./play_store_listing.md) | Title, short/full description, screenshots, Data safety notes |
| [`play_store_console_runbook.md`](./play_store_console_runbook.md) | First-publish order of operations |

---

## Gaps not covered by the five bullets alone

Still required for a serious Play launch (not exhaustive):

* **Data safety form** + privacy policy URL in listing  
* Accurate **permission declarations** in Play Console  
* **WebView** DNA rules (e.g. untrusted content + `JavascriptInterface`)  
* Foreground service / background download declarations if used  
* Content rating questionnaire accuracy  
* No DRM circumvention paths  
* Clear product framing so the app is not reviewed as an unauthorized media-grabber  

---

## Verdict

| Area | Assessment |
|------|------------|
| Policy sources | Use DDA + Developer Program Policy + DNA / IP / Payments / storage pages. Console + Developer APIs are operational only. |
| YouTube block | **Mandatory**; domain list must be hardened. **Not** full DNA/IP coverage alone. |
| ~~Other locked platforms / general unauthorized media~~ | ~~**Not solved** by YouTube-only logic.~~ **Stale — corrected 2026-07-28.** `lib/compliance/restricted_media_policy.dart` now covers **six platform groups** with surface + CDN + Referer + Origin matching, channel-gated. The code is ahead of this doc; see `play_review_audit_2026-07-27.md` "Things that are correct". |
| Torrent / magnet intake | **Not a policy violation.** No Play rule bans BitTorrent clients. Aurora is transport-only — no search, no indexer, no bundled sites (verified 2026-07-28). Residual risk is reviewer gestalt, not rules — see `play_store_listing.md` §Torrent and Play policy |
| Content rating | Live is **3+** with `Unrestricted Internet`. **Correct** — IARC rates the app's own content, and a browser ships none. The section that actually matters is Target audience (must be 18+, unverified) |
| In-app adblock only | **Likely OK** if truly WebView-only. |
| Listing brands / screenshots | **Correct direction** and high impact. |
| Play Billing / no external Pro checkout | **Correct** under default Payments rules. |
| Storage (MediaStore, no MES) | **Correct**. |
| Privacy, Data safety, FGS, WebView security, etc. | **Outside** this short checklist — still needed. |

**Conclusion:** Engineering gates for YouTube, billing channel, storage, and listing copy are in place. **Submission-ready** only after privacy policy URL, Console declarations, live IAP product, clean screenshots, and a successful internal-test purchase + YouTube-block smoke test.

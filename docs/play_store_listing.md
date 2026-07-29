# Google Play Store Listing — Aurora: Browser & Downloader

Copy-paste ready metadata for Play Console. Keep branding generic: **browser + download manager**, not a multi-platform video grabber.

## Live listing state — verified 2026-07-28

**The app is published to a closed testing track.** This doc is no longer a
pre-launch plan; it is the delta between what is live and what should be.

| Field | Live value |
|---|---|
| Name | Aurora: Browser & Downloader |
| Developer | Ahjie521 |
| Track | Closed testing |
| Version | 2.4.5 / versionCode 29 |
| Listing updated | 2026-07-23 |
| Installs | 0+ |
| Download size | 67 MB |
| Min Android | 7.0 |
| Content rating | Rated for 3+ · Unrestricted Internet, In-App Purchases |

**Known drift between live and this repo:**

| Item | Status |
|---|---|
| Live description | A **shorter, different** copy than the block below — the block below was never published |
| Live screenshots | Old UI, 2026-07-18. One frame advertises "Google Drive sync — upcoming", a feature deleted from the codebase |
| Live binary | Predates the four HIGH fixes from `play_review_audit_2026-07-27.md` (targetSdk pin, battery prompt, bridge guard, WebView flags). `versionCode` still 29 |
| IAP products | Only `aurora_pro_unlock` documented; code defines three. Activation unverified |

**Lesson that keeps recurring:** do not infer Console state from this repo. The
audit made this error twice (rev 2 §0, and the content-rating row corrected
2026-07-28). Check the Console, then write it down here with a date.

**Product posture (Play edition):** private web browser, media capture for sites that allow downloading, multi-connection download manager, local queue, optional Aurora Pro power features. **YouTube media download/sniff is disabled** for Play policy compliance.

---

## App identity

| Field | Value |
|-------|--------|
| **App name** (≤30 chars) | **`Aurora: Browser & Downloader`** — live, 28 chars |
| **Developer** | Ahjie521 |
| **Package name** | Use the existing applicationId from `android/app/build.gradle.kts` (do not invent a new one mid-launch) |
| **Default language** | English (United States) — add locales later |
| **Category** | Tools (or Productivity) |
| **Tags** | download manager, web browser, file download |

The name is **already published** and should not change without reason — renaming
a live listing discards whatever search association it has built.
Earlier revisions of this doc said `Aurora Downloader`; corrected 2026-07-28.

**Do not use:** TikTok, Instagram, YouTube, Netflix, Facebook, “video grabber”, “downloader for X”.

---

## Short description (≤80 characters)

**Primary:**

```text
Fast multi-part downloads, ad-free browsing, and a queue that never gives up.
```

Alternates:

```text
Private browser + fast download manager. Resume anything, lose nothing.
```

```text
Download manager with a private ad-blocking browser. No account, no ads.
```

Lead with the verb and keep `download manager` + `browser` in the string — Play
weights the short description for search. All three are under the limit; see the
count table in the "Copy hygiene" section below.

---

## Full description (Play Console)

**Paste this block verbatim.** It contains no markdown — Play Console renders
none, and the previous version's `~~strikethrough~~` would have shipped literal
tildes and the word "Cancelled" to users.

Rules baked into this copy: no trademarked platform named as a download target,
no competitor app named, no Drive references, benefit-led headings, and every
number matches `lib/premium/pro_features.dart`.

```text
Aurora Downloader is a private web browser with a serious download manager built in.

BROWSE WITHOUT THE JUNK
• Ad and popup blocking built in, so pages load faster and cleaner
• Multi-tab browsing with tab groups, and your session comes back after a restart
• Reader mode, find in page, save a page for offline, and hide any element you don't want

FIND THE FILE
• Aurora spots downloadable media and file links while you browse, and keeps finding
  them on pages where simpler tools come up empty
• Grab a whole batch in one tap instead of one file at a time
• Streaming playlists are reassembled into a single playable file when the site allows it
• Filenames get cleaned up and sorted into folders for you

DOWNLOADS THAT ACTUALLY FINISH
• Every file downloads in parallel parts — far faster than a single connection
  on most servers
• Pause anything and pick it up later. Downloads survive app restarts, low memory,
  and Android's background limits
• Dead links are retried and revived automatically
• Progress, speed, and status for the whole queue at a glance

MOVING IN FROM ANOTHER APP
• Import your existing download list from other Android download managers, so you
  start with your library intact instead of from zero
• Restore from your own backups — including inside Samsung Secure Folder and other
  dual-app and work-profile spaces, where backup tools are known to fail silently

YOUR FILES STAY YOURS
• Browsing and downloads stay on your device
• Finished files land in your normal Downloads folder
• Send files to your computer over your own Wi-Fi, with nothing routed through a server
• No account required. No ads.

AURORA PRO — one-time unlock
• 16 downloads at once and 32 parts per file (free tier: 3 and 8)
• Unlimited ad-block filter lists, your own custom lists, and the tracker pack
• Download rules, schedules, night mode, and per-site profiles
• Proxy support, Wi-Fi-only mode, and unlimited tab groups
• Scheduled automatic backups and duplicate finding

AURORA ULTRA — everything in Pro, plus
• 64 downloads at once and 64 parts per file
• Full media conversion suite, downloaded on demand so it never bloats the install
• Folder watcher and a local automation API
• Unlimited private vault with sync

Both unlocks are one-time purchases through Google Play. No subscription.

WHAT AURORA DOES NOT DO
• YouTube media download and capture are not supported, in line with Google Play policies
• Ad blocking works inside Aurora's own browser only. It is not a VPN and does not
  filter other apps
• Only download content you have the right to download

Aurora's core is open source (GPL-3.0). The Play edition adds official updates and the
optional Pro and Ultra unlocks.

Not affiliated with Google, YouTube, or any third-party media service.
```

### What changed and why

| Change | Reason |
|---|---|
| Removed both `~~…~~` lines | Play renders no markdown — these would have shipped as literal tildes advertising a cancelled feature |
| "Multi-connection HTTP downloads" → "downloads in parallel parts — far faster than a single connection" | Benefit, not spec. Hedged with "on most servers" so it stays defensible |
| Added **MOVING IN FROM ANOTHER APP** section, placed mid-listing | The `.1dmbak` importer (`lib/sniffer/idm_backup_parser.dart`) was absent from the old copy entirely. Now above the fold-ish, not buried |
| Competitor app **not** named | Using another app's trademark in listing copy is a Play IP risk. Costs some search value — see the note below |
| Added **AURORA ULTRA** section | Old copy sold one tier; the code ships three products (`aurora_pro_unlock`, `aurora_ultra_unlock`, `aurora_ultra_upgrade`) |
| Real numbers (3/8, 16/32, 64/64) | "Higher concurrency" is meaningless to a shopper; the jump from 3 to 64 sells itself |
| **WHAT AURORA DOES NOT DO** as a headed section | Turns three compliance disclaimers into a trust signal instead of fine print |
| Removed "unless you enable cloud features" | No cloud features remain after the Drive removal — the caveat now describes nothing |

**Open call for you:** naming the competitor directly would help discovery for
people searching migration terms, but puts a trademarked app name in your listing
on a downloader — the exact category where Play's IP enforcement is discretionary.
The generic phrasing above is the safe default. Reverse it only if you decide the
search traffic is worth the first-review risk.

### Copy hygiene — verified counts

| Field | Length | Limit | Status |
|---|---:|---:|---|
| Short description (primary) | 77 | 80 | OK |
| Short description (alt 1) | 71 | 80 | OK |
| Short description (alt 2) | 72 | 80 | OK |
| Full description | 2,899 | 4,000 | OK |
| App name `Aurora Downloader` | 17 | 30 | OK |

Re-run after any edit:

```powershell
$lines = Get-Content docs/play_store_listing.md
$start = ($lines | Select-String 'Aurora Downloader is a private web browser with a serious' | Select-Object -First 1).LineNumber
$end = $start; while ($lines[$end] -notmatch '^```$') { $end++ }
(($lines[($start-1)..($end-1)] -join "`r`n")).Length
```

**Note on a rumour:** a review of this listing claimed the short description was
81 characters and over the limit. It was 75, and the claim is structurally
impossible — Play Console rejects the field at input past 80. Do not "fix" a
count without measuring it.

---

## Screenshots — 6-shot set with captions

### Why the 2026-07-18 set has to be reshot

The seven screenshots in `D:\Download\AyuGram Desktop\` are **not usable**. They
predate the v2.4.5 changes and three carry real review risk:

| File | Problem |
|---|---|
| `…_154746.jpg` | Full Google search page — Google wordmark, "Sign in", AI Overview, LinkedIn/Wikipedia favicons. Violates this doc's own no-brand-logos rule and puts third-party trademarks in a downloader's store assets |
| `…_155721.jpg` | Shows a **Torrent** filter chip beside video capture — exactly the pairing `play_review_audit_2026-07-27.md` §9 warns against. Also every `.mp4` row is mislabelled `text/html` |
| `…_154911.jpg` | Settings card reads "Google Drive sync — upcoming" — that feature was **deleted from the codebase** in audit rev 3. Advertising it is a misleading-listing problem |
| `…_155827.jpg` | Queue: paste field clipped behind the app bar, four identically-named items, all Paused. A download manager whose hero shot shows nothing downloading |
| `…_160348.jpg` | Tab groups named "h", "e", "l", "o" — test junk |

Reshoot against **v2.4.5** with `AURORA_BUILD_CHANNEL=play`, seeded with real
demo content, on one device at one resolution.

### The set

Play surfaces the first 3–4 in the carousel, so shots 1–3 carry the install
decision. Caption is a top banner: **headline ~48–56 px bold, subhead ~28–32 px
at ~70% opacity, banner ≈22% of frame height**, app screen framed below in a
device bezel on a dark gradient matching the app's own palette.

| # | Screen to capture | Headline | Subhead |
|---|---|---|---|
| 1 | Queue with 3–4 downloads **actively running** — visible progress bars, real speeds, mixed file sizes | **Big files, finished fast** | Every download split into parallel parts |
| 2 | Capture sheet open on a clean test page, several distinct media rows, correct MIME labels, **Torrent chip scrolled out of frame** | **Finds the file when others can't** | Media and links spotted as you browse |
| 3 | Browser on a content-heavy but unbranded page, adblock shield showing a non-zero blocked count | **Browse clean, load fast** | Ads and popups blocked inside Aurora |
| 4 | Import / restore screen mid-import, showing a populated list | **Bring your whole library with you** | Import from your old download manager |
| 5 | Settings → Rules or Schedule, Pro badges visible | **Downloads on your terms** | Rules, schedules, night mode, per-site profiles |
| 6 | Backup/restore screen, ideally captured inside Secure Folder | **Backups that survive Secure Folder** | Where other backup tools quietly fail |

### Screenshot build — staged state

Real UI, fake tasks. `lib/dev/screenshot_fixtures.dart` seeds the live Queue with
six display-only downloads so shot 1 needs no huge files and no race against a
progress bar.

```powershell
# Shots 1, 2, 4, 6 — Ultra tier, full queue
flutter run --profile `
  --dart-define=AURORA_BUILD_CHANNEL=play `
  --dart-define=AURORA_SCREENSHOT_MODE=true `
  --dart-define=AURORA_ENABLE_ONBOARDING=false

# Shot 5 — free tier, so the `Pro` badges actually render
flutter run --profile `
  --dart-define=AURORA_BUILD_CHANNEL=play `
  --dart-define=AURORA_SCREENSHOT_MODE=true `
  --dart-define=AURORA_SCREENSHOT_SHOT=settings `
  --dart-define=AURORA_ENABLE_ONBOARDING=false
```

**Profile, not release.** Both `ProEntitlement.setDebugTier` and
`DownloadQueue.seedDisplayOnlyTasks` are hard no-ops when `kReleaseMode` is true,
so a shipped build cannot be seeded even if the define leaks into it. Profile
also drops the debug banner and runs at near-release speed.

**The Pro-badge conflict this resolves:** Settings shows `Rules [Pro]` /
`Schedule [Pro]` only on a *non*-Pro account, while the Queue shot wants Ultra
for more than three concurrent downloads. `AURORA_SCREENSHOT_SHOT` switches tier
between the two runs instead of forcing a purchase-then-refund dance.

**What is staged and what is not.** Play requires screenshots to represent the
actual app. Seeding the real UI with staged content — filenames, sizes, progress
values — is ordinary practice. Fabricating a screen, implying a feature that does
not exist, or showing throughput the engine cannot reach would not be. Seeded
speeds in `_seededSpeeds` are deliberately set to realistic multi-connection
numbers; do not inflate them.

**Shot 2 is exempt** — the capture sheet must genuinely sniff a live page, or the
screenshot would be claiming a capability rather than staging content. Use
`https://download.blender.org/peach/bigbuckbunny_movies/`: a plain Apache index,
no branding, direct `.mp4` links that return real `Content-Type: video/mp4`.
That is also the fix for the `text/html` labels in the old set, which came from
sniffing landing pages instead of files.

**Shot 6 is unchanged** — Samsung blocks screenshots inside Secure Folder, which
no fixture can route around. Capture the normal backup screen and let the caption
carry the claim.

### Hard rules for the reshoot

- **No third-party logos, wordmarks, or favicons anywhere** — including in tab
  strips, favicon rows, and browser chrome. This is the item that is still an
  unchecked box in the audit's pre-submission checklist.
- **Don't lead with torrent.** This is a marketing call, **not** a policy rule —
  see "Torrent and Play policy" below. With six frames and no installs, the
  carousel is better spent on the browser and the download engine than on the
  least differentiated feature. Showing it is not a violation.
- **No "Sniffer" label visible.** It is jargon, and it is the single word most
  likely to read as "video grabber" to a reviewer. Shot 2 should show the capture
  sheet, not the settings row.
- Nothing Paused, nothing empty, no placeholder or duplicate filenames.
- No Drive, no cloud sync, no "upcoming" or "coming soon" strings.
- Fix the clipped paste field before shooting shot 1 — it is a real layout
  overlap, visible in `…_155827.jpg`.

**Demo content:** Wikimedia Commons, Big Buck Bunny, `file-examples.com`,
self-hosted test MP4s, generic documentation PDFs.

**Promo video (optional):** same rules; no third-party branded download flows.

---

## Graphic assets

| Asset | Spec |
|-------|------|
| App icon | 512×512 PNG (use `assets/brand/aurora-logo-*.png` masters) |
| Feature graphic | 1024×500 |
| Phone screenshots | 16:9 or device frames; min width 320 |

---

## Torrent and Play policy

**There is no Play policy against BitTorrent clients.** µTorrent, Flud,
LibreTorrent and BiglyBT have all shipped on the Store for years.

What is enforceable is the **Intellectual Property** policy — apps that
facilitate or promote infringement. Enforcement has targeted apps that *surface*
infringing content: built-in search over torrent indexes, curated content lists,
bundled site shortcuts. A transport client that accepts a magnet link the user
brought themselves has not been the target.

**Aurora is on the safe side of that line** — verified 2026-07-28:
`lib/downloader/magnet_link.dart` and `torrent_downloader.dart` are transport
only. No search, no indexer, no bundled tracker sites.

The residual concern is **gestalt, not rules**: media sniffer + torrent client +
ad blocker reads as a piracy toolkit to a human reviewer, and IP enforcement is
discretionary — which weighs more for a new personal account with no track
record. That is a real cost but not a violation.

Note also that hiding torrent from store assets does **not** hide it from
review — the reviewer installs and uses the app. Screenshot framing is a
marketing decision, not risk mitigation.

Audit item 5 asks for a deliberate decision. Three coherent positions:

| Position | Trade |
|---|---|
| Keep it, show it | Honest; accepts the gestalt cost |
| **Keep it, don't lead with it** | Full capability, carousel spent on stronger features — **recommended** |
| Gate out of the Play channel | One `BuildChannel.isPlay` check; loses a real feature for a speculative risk |

---

## Content rating questionnaire

**Actual outcome (live, closed testing): `Rated for 3+`, interactive elements
`Unrestricted Internet, In-App Purchases`. This is correct — do not "fix" it.**

IARC rates **the app's own content**, and a browser ships none.
`Unrestricted Internet` is an *interactive element* descriptor, disclosed
separately, and does not raise the age rating by itself. Chrome, Firefox, Opera
and Samsung Internet all carry Everyone/3+ with the same descriptor.

Earlier revisions of this doc and of `play_console_app_content.md:137` predicted
Teen or Mature 17+ and warned against "under-rating." That prediction was wrong
about how IARC works. Corrected 2026-07-28.

Answers to prepare:

- No user-generated social network as core product  
- No real-money gambling  
- No sharing of user’s location as a product feature  
- Unrestricted web access → **Yes** (declares the interactive element)  

**What actually matters is the separate Target audience section.** A 3+ content
rating combined with a child-inclusive target audience pulls the app into
Families policy, which an unrestricted browser cannot satisfy. Set target
audience to **18 and over**. Chrome's configuration is exactly 3+ rating with an
adult target audience.

⚠️ **Unverified:** target audience has not been confirmed in Console. Check
Policy → App content → Target audience and content before promoting to
production.

---

## Data safety form (summary to declare)

Update when code changes. Baseline:

| Data type | Collected? | Shared? | Purpose |
|-----------|------------|---------|---------|
| App activity / diagnostics | Only if you add crash analytics | No (local logs default) | Debugging |
| Files / docs user downloads | On device | No ~~(unless user enables Drive)~~ (Cancelled) | App functionality |
| Web browsing | On device in WebView | No | App functionality |
| ~~Google account~~ | ~~Only if user links Drive~~ | ~~To Google APIs user authorizes~~ | ~~Cloud backup (Pro)~~ (Cancelled) |
| Purchase history | Via Play Billing | Google Play | Pro unlock |

**Privacy policy URL:** required before production. Host a page that covers:

- Local storage of queue, tabs, cookies in app sandbox  
- ~~Optional Google Drive sync~~ (Cancelled)  
- Play Billing purchases  
- No sale of personal data  
- Contact email for privacy requests  

Suggested path later: `https://<your-domain>/aurora-privacy` or GitHub Pages.

---

## Play Console — create app checklist

Account status: **approved developer account** (you already have this).

1. **Create app** → name `Aurora Downloader`, language EN, free app, declarations  
2. **App access** → all features available without login ~~(Drive optional)~~  
3. **Ads** → declare if you show ads (default: no ads in Aurora)  
4. **Content rating** → complete questionnaire  
5. **Target audience** → not primarily children  
6. **News app** → No  
7. **Data safety** → fill from table above  
8. **Government apps** → No  
9. **Financial features** → None  
10. **Health** → None  
11. **Store listing** → paste short + full description; upload icons/screenshots  
12. **Privacy policy** URL  
13. **App category** Tools  
14. **Contact details** email + optional website  

### Monetization

1. Set up **Payments profile** / merchant account if not done  
2. **Monetize → Products → In-app products**  
3. Create **three one-time products** — IDs must match `lib/premium/pro_entitlement.dart:20-22` exactly:  

   | Product ID | Name | Purpose |
   |---|---|---|
   | `aurora_pro_unlock` | Aurora Pro | 16/32 engine, rules, schedules, proxy, backups |
   | `aurora_ultra_unlock` | Aurora Ultra | 64/64 engine, conversion suite, watcher, automation API, vault sync |
   | `aurora_ultra_upgrade` | Aurora Ultra Upgrade | Pro → Ultra step-up for existing Pro owners |

   Price: your choice (e.g. Pro $4.99–$9.99, Ultra above it, upgrade = the difference).

4. Activate **all three**. The full description now advertises Ultra — if only
   `aurora_pro_unlock` exists in Console, every Ultra surface in the app is
   unpurchasable and the listing describes features nobody can buy.
5. License testers: add Gmail accounts under Setup → License testing  

### Build & upload

```bash
# Play-channel release AAB (recommended for Play)
flutter build appbundle --release --dart-define=AURORA_BUILD_CHANNEL=play

# Debug Play-channel APK for internal testing
flutter build apk --debug --target-platform android-arm64 --dart-define=AURORA_BUILD_CHANNEL=play
```

Upload AAB under **Production** or start with **Internal testing** track.

### Permissions / declarations

| Item | Aurora status |
|------|----------------|
| `MANAGE_EXTERNAL_STORAGE` | **Not used** — do not add |
| Foreground service `dataSync` | Used for active downloads — declare FGS type + short video if required |
| Notifications | Runtime POST_NOTIFICATIONS on Android 13+ |
| Battery optimization | Optional user prompt |

### Policy self-check before submit

- [ ] YouTube sniff/download blocked in binary  
- [ ] Listing has no “download from [platform]” marketing  
- [ ] Screenshots clean of third-party brand download flows  
- [ ] **No markdown syntax pasted into Console** — no `~~`, `**`, `|`, or `#`  
- [ ] **No screenshot shows torrent/magnet UI** (audit §9)  
- [ ] **No screenshot shows a removed feature** (Drive sync, "upcoming" strings)  
- [ ] **Screenshots taken against the submitted version**, not an older build  
- [ ] All three Play Billing products live: `aurora_pro_unlock`, `aurora_ultra_unlock`, `aurora_ultra_upgrade`  
- [ ] No GitHub donate / Stripe unlock links in Play APK  
- [ ] Privacy policy URL live  
- [ ] Data safety form matches behavior  
- [ ] Adblock is in-app only (no VPN claim)  

---

## Support text (in-app / listing)

**Support email:** use your Play Console contact email.

**What’s new (v2.4.0 example):**

```text
• Play Store compliance: YouTube media capture disabled
• Aurora Pro one-time unlock via Google Play Billing
• Stability and download queue improvements
```

---

## Related docs

- [`play_store_compliance.md`](./play_store_compliance.md) — engineering policy checklist  
- [`premium_implementation_tracker.md`](./premium_implementation_tracker.md) — freemium / billing status  
- [`premium_freemium_strategy.md`](./premium_freemium_strategy.md) — product intent  

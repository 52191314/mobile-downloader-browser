# Google Play Store Listing — Aurora Download Manager

Copy-paste ready metadata for Play Console. Keep branding generic: **browser + download manager**, not a multi-platform video grabber.

## Live listing state — verified 2026-07-28

**The app is published to a closed testing track.** This doc is no longer a
pre-launch plan; it is the delta between what is live and what should be.

| Field | Live value |
|---|---|
| Name | Aurora Download Manager (renamed 2026-08-08; was Aurora: Browser & Downloader) |
| Developer | Ahjie521 |
| Track | Closed testing |
| Version | 1.0.1 / versionCode 54 (2026-08-08) |
| Listing updated | 2026-07-23 (text refresh pending 2026-08-08 — this doc) |
| Installs | 0+ |
| Download size | ~26 MB arm64 base install (AAB upload 103.6 MB incl. on-demand modules + symbols; see "Known drift") |
| Min Android | 7.0 |
| Content rating | Rated for 3+ · Unrestricted Internet, In-App Purchases |

**Known drift between live and this repo:**

| Item | Status |
|---|---|
| Live description | A **shorter, different** copy than the block below — the block below was never published. It also **sells Google Drive sync** ("BACK UP TO GOOGLE DRIVE"), which this repo's canonical copy dropped — see the 2026-08-08 Drive correction below |
| Live screenshots | 8-shot set, **passed Play policy review** (2026-07-xx, verified 2026-08-08). Old UI (2026-07-18); conversion issues remain (see Screenshots section) but they are not a policy risk |
| Live binary | versionCode 54 (1.0.1) — **now includes** the four HIGH fixes from `play_review_audit_2026-07-27.md` (targetSdk pin, battery prompt, bridge guard, WebView flags), the torrent publish fix, and the 16 KB page-size alignment. Previous live binary was versionCode 29 |
| IAP products | Only `aurora_pro_unlock` documented; code defines three. Activation unverified |

**Lesson that keeps recurring:** do not infer Console state from this repo. The
audit made this error twice (rev 2 §0, and the content-rating row corrected
2026-07-28). Check the Console, then write it down here with a date.

**Product posture (Play edition):** private web browser, media capture for sites that allow downloading, multi-connection download manager, local queue, optional Aurora Pro power features. **YouTube media download/sniff is disabled** for Play policy compliance.

---

## App identity

| Field | Value |
|-------|--------|
| **App name** (≤30 chars) | **`Aurora Download Manager`** — 23 chars, chosen 2026-08-08 (was `Aurora: Browser & Downloader`) |
| **Developer** | Ahjie521 |
| **Package name** | Use the existing applicationId from `android/app/build.gradle.kts` (do not invent a new one mid-launch) |
| **Default language** | English (United States) — add locales later |
| **Category** | Tools (or Productivity) |
| **Tags** | download manager, web browser, file download |

Name rationale (2026-08-08): the app has **zero users** (0+ installs, closed
testing), so renaming is free — no search association exists to protect. The
old doc rule ("don't rename a live listing") applied to a listing with
history; it does not apply here. Chosen: `Aurora Download Manager` — keeps the
Aurora brand (About page, UI, privacy policy all say "Aurora Downloader"),
adds the exact **"download manager"** search phrase Play weights, and avoids
the exact-name collision with the existing "Mobile Download Manager" developer
brand on Play (publisher of IDM+ Download Manager). Dropped the browser-first
framing — the short description and full description still carry the browser.

**Do not use:** TikTok, Instagram, YouTube, Netflix, Facebook, "video grabber", "downloader for X".

---

## Short description (≤80 characters)

**Primary (2026-08-08 refresh):**

```text
Download manager, ad-free browser, torrents. A queue that never gives up.
```

Alternates:

```text
Fast multi-part downloads, ad-free browsing, and a queue that never gives up.
```

```text
Private browser + fast download manager. Resume anything, lose nothing.
```

Lead with the verb and keep `download manager` + `browser` in the string — Play
weights the short description for search. All are under the limit; see the
count table in the "Copy hygiene" section below. The pre-1.0.1 primary
("Fast multi-part downloads…") is kept as an alternate — the torrent mention
moved into the primary only because the 1.0.1 release ships torrent support.

---

## Full description (Play Console)

**Paste this block verbatim.** It contains no markdown — Play Console renders
none, and the previous version's `~~strikethrough~~` would have shipped literal
tildes and the word "Cancelled" to users.

Rules baked into this copy: no trademarked platform named as a download target,
no competitor app named, benefit-led headings, and every number matches
`lib/premium/pro_features.dart`. **Google Drive sync IS a shipped feature** (see
the 2026-08-08 correction below) — the block includes it as the live listing does.

```text
Aurora Downloader is a web browser with a serious download manager built in.

BROWSE WITHOUT THE JUNK
• Ad and popup blocking built in, so pages load faster and cleaner
• Multi-tab browsing with tab groups, and your session comes back after a restart
• Reader mode, find in page, save a page for offline, and hide page elements you
  don't want

FIND THE FILE
• Aurora spots downloadable media and file links while you browse, and keeps finding
  them on pages where simpler tools come up empty
• Grab a batch in one tap — up to 5 files per tap on free, unlimited with Pro
• Streaming playlists are reassembled into a single playable file when the site allows it
• Preview a video before you commit to downloading it, in a built-in player with
  gesture seek, speed control and picture-in-picture
• Filenames get cleaned up and sorted into folders for you

DOWNLOADS THAT ACTUALLY FINISH
• Every file downloads in parallel parts — far faster than a single connection
  on most servers
• Pause anything and pick it up later. Downloads survive app restarts, low memory,
  and Android's background limits
• Refresh a link that has gone stale, and let Pro revive dead links automatically
• Progress, speed, and status for the whole queue at a glance

TORRENTS, INCLUDED
• Download torrents and magnet links with a fast native engine
• Finished torrents save straight to your Downloads folder — multi-file torrents included
• Pause, resume, and seed from your device

BACK UP TO GOOGLE DRIVE
• Connect your Google account and completed downloads sync to your personal Google Drive automatically
• Choose your schedule — instant, every 15 minutes, hourly, or daily
• Your files go to a dedicated Aurora folder on your Drive, organized and ready to access from any device

MOVING IN FROM ANOTHER APP
• Import your existing download list from other Android download managers, so you
  start with your library intact instead of from zero
• Restore from your own backups — including inside Samsung Secure Folder and other
  dual-app and work-profile spaces

YOUR FILES STAY YOURS
• Browsing and downloads stay on your device
• Finished files land in your normal Downloads folder
• Send files to your computer over your own Wi-Fi, with nothing routed through a
  server — 20 files a day on free, unlimited with Pro
• Google Drive sync is optional and uses only the files Aurora creates — nothing
  else on your Drive is touched
• No account required. No ads.

AURORA PRO — one-time unlock
• 16 downloads at once and 32 parts per file (free tier: 3 and 8)
• Higher Google Drive sync limits — 50 files a day (free tier: 15)
• Unlimited ad-block filter lists, your own custom lists, unlimited element-hiding
  rules, and the tracker pack
• Download rules, schedules, night mode, and per-site profiles
• Automatic dead-link revival and unlimited batch capture
• Proxy support, Wi-Fi-only mode, and unlimited tab groups
• Scheduled automatic backups and duplicate finding
• Unlimited audio extraction, series auto-grab, clipboard capture, and private vault

AURORA ULTRA — everything in Pro, plus
• 64 downloads at once and 64 parts per file
• Up to 1,000 Google Drive syncs a day
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
| Removed "unless you enable cloud features" | The caveat described nothing by itself; the Google Drive sync bullet carries the cloud story now |

#### Revision 2026-08-08 — 1.0.1 release pass (torrents + state refresh)

| Change | Reason |
|---|---|
| Added **TORRENTS, INCLUDED** section after DOWNLOADS THAT ACTUALLY FINISH | 1.0.1 ships the native torrent engine fix: completed torrents now publish to Downloads (multi-file included). Honest, benefit-led, and decoupled from media capture (the pairing the review audit warns about) |
| Short description primary swapped to "Download manager, ad-free browser, torrents. A queue that never gives up." (73) | Torrent support is now a headline capability; keeps `download manager` + `browser` search terms. Pre-1.0.1 primary kept as alternate |
| Live-state table: version 1.0.1/54, download size, live-binary drift row | Release 54 shipped; old rows described versionCode 29 |
| **App name changed** to `Aurora Download Manager` (23) | Zero users → renaming is free (no search association to protect). Keeps the Aurora brand, adds the exact "download manager" search phrase, and avoids the "Mobile Download Manager" developer-brand collision on Play. Browser-first framing dropped from the name; short + full descriptions still carry the browser |

#### Revision 2026-07-30 — tier-accuracy pass

The claim above that "every number matches `pro_features.dart`" held for the raw
numbers but not for which *tier* three features sit in. Each of these advertised a
Pro feature as though it were base, which is what generates refund requests and
"advertised feature is paywalled" reviews.

| Change | Reason |
|---|---|
| "Dead links are retried and revived automatically" → "Refresh a link that has gone stale, and let Pro revive dead links automatically" | `ProFeature.deadLinkRevival` is `EntitlementTier.pro`; its own doc says "Free: manual refresh only" |
| "Grab a whole batch in one tap" → "up to 5 files per tap on free, unlimited with Pro" | `batchCapture` is pro, `freeBatchCaptureItems = 5` |
| Send-to-PC bullet gained "20 files a day on free, unlimited with Pro" | `sendToPc` is pro, `freeSendToPcPerDay = 20` |
| Pro block gained dead-link revival, unlimited batch capture, element-hiding rules, audio extraction, series grab, clipboard capture, private vault | These were gated in code but sold nowhere — the Pro block understated what the unlock buys |
| Dropped "where backup tools are known to fail silently" | A reliability claim about competitors' software. Play's metadata policy is unfriendly to disparaging comparisons, and the Secure Folder differentiator survives without it |
| "hide any element you don't want" → "hide page elements you don't want" | `maxFreeCosmeticRules = 25`, so "any" overclaims. Pro's bullet now states unlimited |
| Added the built-in player to FIND THE FILE | Not a `ProFeature` at all, so free — and shot 4 now leads on it, so the copy should too |
| Opening line dropped "private" | "Not a VPN" is admitted three sections later; leading on "private" invites the reading the disclaimer then walks back |

The count script's `Select-String` pattern was updated with the opening line — it
keys off that literal string and would otherwise have silently measured nothing.

Still unsold, gated in code, deliberately omitted for density: `videoLibrary`
(pro, `freeVideoLibraryItems = 10`), `themePack`, `richNotifications`, `noNag`.

**Open call for you:** naming the competitor directly would help discovery for
people searching migration terms, but puts a trademarked app name in your listing
on a downloader — the exact category where Play's IP enforcement is discretionary.
The generic phrasing above is the safe default. Reverse it only if you decide the
search traffic is worth the first-review risk.

#### Revision 2026-08-08 — Google Drive sync restored (docs were stale, not the app)

Earlier revisions of this doc and of `play_console_app_content.md` declared
Google Drive sync **cancelled/deleted**, and this doc's canonical copy dropped
the Drive section to match. **That was stale documentation.** The truth:
`kDriveSyncEnabled` (`lib/premium/premium_flags.dart:4`) was `false` from
2026-07-20 to 2026-08-02 (pending GCP OAuth verification — the 2026-07-27
audit's "archived" conclusion was correct *then*), and was flipped back to
`true` in commit d2584a2 (2026-08-02). Since then the feature is **live**:
`lib/sync/drive_sync_service.dart` is fully wired (`lib/main.dart:363`,
Settings → Drive page, `google_sign_in ^6.2.2` +
`extension_google_sign_in_as_googleapis_auth` in pubspec), uploads the user's
completed downloads + vault media to a dedicated Aurora folder in *their own*
Google Drive (`uploadFile` / `uploadDirectory`), and enforces daily limits from
`lib/premium/pro_features.dart:182-198` (free 15 / Pro 50 / Ultra 1000). The
live listing's "BACK UP TO GOOGLE DRIVE" section is **accurate** — the local
docs were stale, not the listing. Drive bullets restored to the canonical copy
above (they match the live text verbatim).

### Copy hygiene — verified counts

| Field | Length | Limit | Status |
|---|---:|---:|---|
| Short description (primary, 2026-08-08) | 73 | 80 | OK |
| Short description (alt 1) | 77 | 80 | OK |
| Short description (alt 2) | 71 | 80 | OK |
| Full description | 3,867 | 4,000 | OK |
| App name `Aurora Download Manager` | 23 | 30 | OK |

Counts measured 2026-08-08 with the same block-extraction logic as the
PowerShell snippet below (full description = opening line through the closing
fence).

Re-run after any edit:

```powershell
$lines = Get-Content docs/play_store_listing.md
$start = ($lines | Select-String 'Aurora Downloader is a web browser with a serious' | Select-Object -First 1).LineNumber
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
| `…_154911.jpg` | Settings card reads "Google Drive sync — upcoming". Drive sync shipped (see the 2026-08-08 correction above) — the "upcoming" wording is now itself stale, and this old UI is long gone |
| `…_155827.jpg` | Queue: paste field clipped behind the app bar, four identically-named items, all Paused. A download manager whose hero shot shows nothing downloading |
| `…_160348.jpg` | Tab groups named "h", "e", "l", "o" — test junk |

Reshoot against **v2.4.5** with `AURORA_BUILD_CHANNEL=play`, seeded with real
demo content, on one device at one resolution.

### The set

Play surfaces the first 3–4 in the carousel, so shots 1–3 carry the install
decision. Caption is a top banner: **headline ~48–56 px bold, subhead ~28–32 px
at ~70% opacity, banner ≈22% of frame height**, app screen framed below in a
device bezel on a dark gradient matching the app's own palette.

Captions live in `tools/make_store_screenshots.py` (`CAPTIONS`), paid-tier
disclosure in `BADGES` beside it. That file is the source of truth; this table
mirrors it.

| # | Screen to capture | Headline | Subhead | Disclosure |
|---|---|---|---|---|
| 1 | Queue with 3–4 downloads **actively running** — visible progress bars, real speeds, mixed file sizes | **Big files, finished fast** | Every download split into parallel parts | — free |
| 2 | Capture sheet open on a clean test page, several distinct media rows, correct MIME labels, **Torrent chip scrolled out of frame** | **Finds the file when others can't** | Media and links spotted as you browse | — free |
| 3 | Browser on a content-heavy but unbranded page, adblock shield showing a non-zero blocked count | **Browse clean, load fast** | Ads and popups blocked inside Aurora | — free |
| 4 | Video player on a landscape clip, controls visible | **Watch it before you download** | Gestures, speed control and picture-in-picture | — free |
| 5 | Settings → Rules or Schedule, Pro badges visible | **Downloads on your terms** | Rules, schedules, night mode, per-site profiles | in-app `[Pro]` labels — free-tier capture |
| 6 | Backup/restore screen, ideally captured inside Secure Folder | **Never lose your queue** | Full backup and restore, kept on your device | caption badge: *Auto backup requires Aurora Pro* |

**Why 5 and 6 disclose differently.** Shot 5 gets its labels from the app: on a
non-Pro account Settings already renders `Rules [Pro]` / `Schedule [Pro]`, so the
free-tier run below produces the disclosure for free and no caption badge is
needed. Shot 6 cannot do that — `autoBackupEnabled` is Pro-gated, so a free-tier
capture shows the toggle *off*, which undersells a feature that does exist. The
caption badge is what lets that shot show the feature working while still saying
it is paid.

**Shot 4 changed subject.** It was specified as the import/restore screen with
"Bring your whole library with you". It is now the video player — the player is
free (not in `ProFeature` at all) and is a stronger third-or-fourth impression
than an import list. Import is no longer in the six.

**Shot 6's old caption was dropped on policy grounds.** It read "Backups that
survive Secure Folder / Where other backup tools quietly fail". That is a
reliability claim about competitors, and Play's metadata policy is unfriendly to
disparaging comparisons — the same reason the equivalent sentence came out of the
full description in the 2026-07-30 tier-accuracy pass. The Secure Folder
differentiator still belongs in the description, just not as a swipe at rivals.

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
- No "upcoming" or "coming soon" strings. (Google Drive sync itself is fine to
  show — it ships; the old "— upcoming" wording is what was stale.)
- **Policy note (2026-08-08):** the live 8-shot set already **passed Play policy
  review** — the reshoot below is a conversion improvement, not a policy fix.
  Do not block a Play upload on it; the current set is compliant.
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
| Files / docs user downloads | On device; **optional upload to the user's own Google Drive** if Drive sync enabled | To Google APIs, user-authorized | App functionality / backup |
| Web browsing | On device in WebView | No | App functionality |
| Google account (name/email) | **Optional** — only if user links Drive | To Google APIs user authorizes | Drive sync (Pro/Ultra tier limits) |
| Purchase history | Via Play Billing | Google Play | Pro unlock |

**Why the live data-safety card says what it says (2026-08-08):** the live
declaration ("Personal info, Photos and videos and 3 others", "Data can't be
deleted") is **explained by Google Drive sync**, not over-declared. Personal
info = the Google account used for Sign-In; Photos and videos = vault media /
downloaded media uploaded to the user's own Drive; "can't be deleted" = the app
cannot delete files from the user's personal Drive — only the user can
(uninstall removes local copies; Drive copies persist until the user deletes
them). This is the accurate and defensible reading; do not "fix" the form to
look smaller.

**Privacy policy URL:** required before production. Host a page that covers:

- Local storage of queue, tabs, cookies in app sandbox  
- Optional Google Drive sync — user's own Drive, only the files Aurora creates  
- Play Billing purchases  
- No sale of personal data  
- Contact email for privacy requests  

Suggested path later: `https://<your-domain>/aurora-privacy` or GitHub Pages.

---

## Play Console — create app checklist

Account status: **approved developer account** (you already have this).

1. **Create app** → name `Aurora Downloader`, language EN, free app, declarations  
2. **App access** → all features available without login; Drive sync optional (Google Sign-In only if the user enables it)  
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
- [ ] **No screenshot shows a removed feature** ("upcoming" strings; Drive sync itself is live, so showing it is fine)  
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

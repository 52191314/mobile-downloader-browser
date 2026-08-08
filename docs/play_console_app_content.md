# Play Console — App content declarations (Aurora Downloader)

Fill these in **Play Console → Policy → App content** (wording may vary slightly by Console UI version).  
Answers match the **Play-channel** product as of 2026-08-08 (Drive sync restored in this doc; see change log).

**Package:** `com.personal.aurora_downloader`  
**Name:** Aurora Downloader  

---

## 1. Let us know about the content of your app / App access

**Question (typical):** Are all features available without special access? Do reviewers need a login?

| Answer | Use this |
|--------|----------|
| **All features available without login** | **Yes** for core browser, sniffer, queue, downloads, settings. |
| **Special access / login required?** | **No login required** (optional Google Sign-In for Drive sync, only if the user enables it). |
| **Instructions for reviewers** | Paste something like: |

```text
No login required for core features (browser, media capture tray, download queue).

Optional Google Drive sync: only if the user chooses to connect their Google account
in Settings → Drive. Core features never require it.

YouTube media download/sniff is intentionally disabled for Play policy compliance.
```

**Restricted content categories (if asked):** You are **not** primarily a dating, gambling, or UGC social network.  
You **are** a **web browser + download tool** — users can navigate the open web (including mature sites). Answer honestly on content rating (below).

---

## 2. Privacy policy

| Field | What to do |
|-------|------------|
| **Privacy policy URL** | **Required.** Must be a public `https://` page. |
| **Status** | Host a page, then paste the URL here. |

### Minimum policy content (host this yourself)

Publish a page that includes:

1. **Developer / contact email**  
2. **What the app does:** private browser + download manager; local queue; optional Play purchase.  
3. **Data collected:**  
   - On device: browsing state (tabs, history/favorites if used), download queue, settings, cookies in WebView.  
   - **Not** sold to advertisers.  
   - Optional: Google account (name/email) **only if the user links Drive** for cloud sync.  
Purchase status via Google Play Billing (Google processes payment).  
4. **Permissions:** Internet, notifications, foreground service for downloads, legacy storage on old Android only; MediaStore for Downloads.  
5. **Third parties:** Google (Play Billing); websites the user chooses to visit.  
6. **Children:** App not directed at children under 13.  
7. **Contact / deletion:** email to request help deleting local data (uninstall clears most local data).  

**You must replace** `YOUR_EMAIL` and host the HTML/Markdown somewhere (GitHub Pages, your site, Notion public page, etc.).

Draft body:

```text
Privacy Policy — Aurora Downloader

Last updated: 2026-07-17
Contact: YOUR_EMAIL

Aurora Downloader is a private web browser and download manager for Android.

Data we process
• On your device: browser tabs and related session data, download queue and file paths, app settings, and WebView cookies for sites you visit.
• Optional Google account (name/email): only if you choose to connect Google Drive for backup/sync. Files Aurora creates (downloads, vault media) are uploaded to your personal Drive; nothing else on your Drive is touched.
• Purchases: one-time Aurora Pro unlock is processed by Google Play Billing. We do not receive your full payment card details.

What we do not do
• We do not sell your personal information.
• We do not show third-party ads in the app.
• We do not require an account to use core download features.

Permissions
• Internet and network state — browse and download.
• Notifications — download progress and completion.
• Foreground service (data sync) — keep downloads running reliably.
• Storage (legacy on older Android) / MediaStore — save completed files to Downloads.

Web content
The built-in browser can open sites you choose. Content on those sites is controlled by third parties, not by us.

Children
Aurora Downloader is not directed at children under 13.

Your choices
• Uninstalling the app removes local app data on your device.
• Disconnect Drive in settings to stop cloud access; files already uploaded stay in your personal Drive until you delete them.
• Contact us at YOUR_EMAIL with privacy questions.
```

---

## 3. App access / Sign-in details

| Question | Answer |
|----------|--------|
| All functionality available without special access? | **Yes** (core app). |
| Login credentials for Google? | **Optional** — only if the user enables Drive sync (Google Sign-In). Core features need no login. |
| Any geo / paid wall? | Pro features are IAP; free tier is fully usable. License testers for purchase testing. |

---

## 4. Ads

| Question | Answer |
|----------|--------|
| Does your app contain ads? | **No** |

(In-app ad**blocking** is not “containing ads.” Do **not** declare as an ads app.)

If asked about ad SDKs: none (no AdMob/etc. in `pubspec.yaml`).

---

## 5. Content rating

Complete the **IARC questionnaire** honestly.

| Topic | Suggested answer direction |
|-------|----------------------------|
| User-generated content shared with others? | **No** (local browser/downloader; not a social network) |
| Users communicate with each other? | **No** |
| Share location? | **No** |
| Share personal info online? | Not as a product feature (user may type into websites they visit) |
| Violence / sexual content **in the app itself**? | App does not **include** such content as packaged media |
| **Unrestricted web access?** | **Yes** — built-in browser can reach the open web |
| Online content from third parties? | **Yes** — web pages the user navigates to |
| Gambling / simulated gambling? | **No** |
| Can users purchase digital items? | **Yes** — one-time Pro unlock (if questionnaire asks) |

**Actual outcome (live, verified in Console 2026-07-28): `Rated for 3+`,
interactive elements `Unrestricted Internet, In-App Purchases`. This is correct.
Do not re-take the questionnaire to "fix" it.**

~~Expected outcome: often Teen or Mature 17+ because of unrestricted web access.~~
**That prediction was wrong** and is corrected here.

IARC rates the app's **own packaged content**, and a browser ships none.
`Unrestricted Internet` is an *interactive element* descriptor — disclosed
separately on the listing, and it does not raise the age rating by itself.
Chrome, Firefox, Opera and Samsung Internet all carry Everyone/3+ with exactly
this descriptor. A low content rating for a browser is normal, not under-rating.

---

## 6. Target audience and content

**This — not the content rating — is the section that carries real risk.**

A 3+ content rating combined with a child-inclusive target audience pulls the app
into **Families policy**, which an unrestricted browser cannot satisfy. Chrome's
configuration is 3+ content rating **with an adult target audience**; match it.

| Field | Answer |
|-------|--------|
| Target age group | **18 and over** (or “18+” / exclude under-13). **Not** primarily children. |
| Appeal to children? | **No** |
| Store presence | Do **not** enroll in Designed for Families / Kids |
| News app? | **No** (if asked as separate form) |

Rationale: unrestricted browser + downloads is inappropriate as a children’s primary app.

⚠️ **Unverified in Console as of 2026-07-28.** Target audience is not visible on
the public listing page. Check Policy → App content → Target audience and content
before promoting to production, and record the result here with a date.

---

## 7. Data safety

Declare **what the app actually does**. Approximate form answers:

### Data collection

| Data type | Collected? | Shared? | Purpose | Optional? | Encrypted in transit? | Deletable? |
|-----------|------------|---------|---------|-----------|----------------------|------------|
| App activity (e.g. app interactions) | **No** as analytics product | — | — | — | — | — |
| Web browsing history | **Yes — on device** | No | App functionality | Required for browser features | HTTPS for network | Uninstall / clear app data |
| Files and docs (downloads) | **Yes — on device** | No | App functionality | User-initiated | — | User deletes files / uninstall |
| App info and performance (crash) | Only if you add a crash SDK later → today **No** third-party crash service assumed | No | — | — | — | — |
| Personal info — name/email | **Optional** — via Google Sign-In if user connects Drive for cloud sync | To Google APIs authorized by user | Cloud backup & sync | Optional | Yes (HTTPS) | Disconnect in app / Google Account settings |
| Financial info | **No** card data in app; Play handles purchase | Google Play | — | — | — | — |
| Photos/videos | User-downloaded media stored as files they chose | No | App functionality | User-initiated | — | User control |

### Toggles / statements

| Statement | Answer |
|-----------|--------|
| Data is encrypted in transit | **Yes** for network APIs you use (HTTPS). Local disk is normal app/MediaStore storage. |
| Users can request data deletion | **Yes** — uninstall + contact email. Note: files already synced to the user's *own* Drive persist until the user deletes them — the app cannot delete from the user's Drive. This is why the live card says "Data can't be deleted" for Drive-synced data |
| Independent security review | **No** (unless you paid for one) |
| Committed to Play Families Policy | **No** (not a kids app) |

### Data safety — live card explained (2026-08-08)

The live Console declaration ("Personal info, Photos and videos and 3 others",
"Data can't be deleted") is **explained by Google Drive sync**, not an
over-declaration. Personal info = Google account used for Sign-In; Photos and
videos = vault media / downloaded media uploaded to the user's own Drive; "Data
can't be deleted" = the app cannot delete files from the user's personal Drive
(uninstall removes local copies only). Keep the declaration as-is.

### Data sharing

- **Do not** claim “no data collected” if you have purchases.  
- Prefer: **data collected**, **not sold**, **shared with Google only** for Play Billing as the user uses those features.

---

## 8. Government apps

| Question | Answer |
|----------|--------|
| Is this a government app? | **No** |

---

## 9. Financial features

| Question | Answer |
|----------|--------|
| Financial features? | **No** banking, trading, loans, wallets, etc. |
| In-app purchases? | **Yes** — digital **Aurora Pro** unlock via Play Billing (often declared under monetization / IAP, not “financial services”). |

If the form lists “In-app purchases / digital goods” separately from “Financial services,” mark **IAP yes**, **financial services no**.

---

## 10. Health

| Question | Answer |
|----------|--------|
| Health features? | **No** |
| Fitness, medical, clinical? | **No** |

---

## Quick checklist before “Save”

- [ ] Privacy policy URL opens in a private/incognito browser  
- [ ] Ads = No  
- [ ] Government = No  
- [ ] Health = No  
- [ ] Financial services = No (IAP separate if asked)  
- [ ] Target audience not children  
- [ ] Content rating completed with unrestricted web = Yes  
- [ ] Data safety mentions optional Google account + Play purchase + on-device files  
- [ ] App access instructions mention no login for core features  

---

## Change log

| Date | Note |
|------|------|
| 2026-07-17 | Initial App content answers for Play-Console-Launch. |
| 2026-08-08 | **Drive sync is LIVE** — flag `kDriveSyncEnabled = true` since commit d2584a2 (2026-08-02); before that it was `false` (2026-07-20 → 08-02, pending GCP OAuth verification — the 2026-07-27 audit's "archived" conclusion was correct at the time). Verified wired: `lib/sync/drive_sync_service.dart`, `lib/main.dart:363`, `google_sign_in ^6.2.2` in pubspec. Data-safety live card explained by Drive sync: "Personal info" = Google account, "Photos and videos" = vault/downloaded media in the user's own Drive, "Data can't be deleted" = app cannot delete from the user's Drive. Earlier "(Cancelled)" edits here were stale after the re-enable. |

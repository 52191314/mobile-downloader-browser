# Google Play Store Listing — Aurora Downloader

Copy-paste ready metadata for Play Console. Keep branding generic: **browser + download manager**, not a multi-platform video grabber.

**Product posture (Play edition):** private web browser, media capture for sites that allow downloading, multi-connection download manager, local queue, optional Aurora Pro power features. **YouTube media download/sniff is disabled** for Play policy compliance.

---

## App identity

| Field | Value |
|-------|--------|
| **App name** (≤30 chars) | `Aurora Downloader` |
| **Package name** | Use the existing applicationId from `android/app/build.gradle.kts` (do not invent a new one mid-launch) |
| **Default language** | English (United States) — add locales later |
| **Category** | Tools (or Productivity) |
| **Tags** | download manager, web browser, file download |

### Alternative titles (if `Aurora Downloader` is taken or needs differentiation)

- `Aurora: Web Download Manager`
- `Aurora Browser & Downloads`

**Do not use:** TikTok, Instagram, YouTube, Netflix, Facebook, “video grabber”, “downloader for X”.

---

## Short description (≤80 characters)

```text
Private browser + fast multi-connection download manager. Sniff, queue, finish.
```

Alternates:

```text
Web browser with smart media capture and a powerful download queue.
```

```text
Download manager with built-in browser, HLS support, and ad blocking.
```

---

## Full description (Play Console)

Paste as-is or lightly edit. **No trademarked platform names as download targets.**

```text
Aurora Downloader is a private web browser and download manager for Android.

BROWSE
• Multi-tab browser with session restore
• Built-in ad blocking (in-app WebView only — not system-wide)
• Optional reader mode and page tools
• Site preferences for how pages load

CAPTURE & DOWNLOAD
• Detect media and file links while you browse
• Add items to a clear download queue
• Multi-connection HTTP downloads with pause and resume
• HLS playlist support for streamable media when the site provides it
• Filename cleanup and organized folders under Downloads

QUEUE & FILES
• Progress, speed, and status at a glance
• Notifications for finished work
• Publish completed files to public Downloads via MediaStore
• Optional Google Drive backup for Pro users

AURORA PRO (optional one-time unlock)
• Higher concurrent downloads and chunk counts
• Extra adblock filter lists and tracker pack
• Download rules, schedules, and per-site profiles
• Drive sync and automatic backups
• Sold only via Google Play Billing in the Play edition

PRIVACY & COMPLIANCE
• Downloads and browsing stay on your device unless you enable cloud features
• YouTube media download and capture are not supported, in line with Google Play policies
• Use Aurora only for content you are allowed to download

Open-source core (GPL-3.0). The Play edition adds official updates and optional Pro unlock.

Not affiliated with Google, YouTube, or any third-party media service.
```

---

## Screenshots guidance

Shoot **5–8** phone screenshots. Prefer clean Nordic UI (dark and/or light).

| # | Screen | Must show | Must not show |
|---|--------|-----------|---------------|
| 1 | Browser home / tabs | Address bar, multi-tab | Brand logos of social/video platforms |
| 2 | Capture tray | Generic media cards / filenames | YouTube, Netflix, TikTok, IG UI |
| 3 | Queue active | Progress bars, speeds | Trademarked source branding |
| 4 | Queue completed | Files under Downloads | Copyrighted cover art |
| 5 | Settings / Pro | Feature list, Play purchase only | Stripe/PayPal/GitHub donate CTAs |
| 6 | Adblock (optional) | In-app shield / blocked count | “Block ads in other apps” claims |
| 7 | Player (optional) | Aurora player on a free test stream | DRM-locked service UI |

**Demo content ideas:** Wikimedia / Big Buck Bunny / self-hosted test MP4 / generic documentation PDFs.

**Promo video (optional):** same rules as screenshots; no third-party branded download flows.

---

## Graphic assets

| Asset | Spec |
|-------|------|
| App icon | 512×512 PNG (use `assets/brand/aurora-logo-*.png` masters) |
| Feature graphic | 1024×500 |
| Phone screenshots | 16:9 or device frames; min width 320 |

---

## Content rating questionnaire (answers to prepare)

Typical for a tools browser/downloader (verify in IARC form):

- No user-generated social network as core product  
- No real-money gambling  
- No sharing of user’s location as a product feature  
- Web content can include anything the user navigates to → answer honestly about unrestricted web access  
- Age rating often Teen / Mature depending on unrestricted web + downloads  

Complete the questionnaire in Console honestly; do not under-rate unrestricted browser access.

---

## Data safety form (summary to declare)

Update when code changes. Baseline:

| Data type | Collected? | Shared? | Purpose |
|-----------|------------|---------|---------|
| App activity / diagnostics | Only if you add crash analytics | No (local logs default) | Debugging |
| Files / docs user downloads | On device | No (unless user enables Drive) | App functionality |
| Web browsing | On device in WebView | No | App functionality |
| Google account | Only if user links Drive | To Google APIs user authorizes | Cloud backup (Pro) |
| Purchase history | Via Play Billing | Google Play | Pro unlock |

**Privacy policy URL:** required before production. Host a page that covers:

- Local storage of queue, tabs, cookies in app sandbox  
- Optional Google Drive sync  
- Play Billing purchases  
- No sale of personal data  
- Contact email for privacy requests  

Suggested path later: `https://<your-domain>/aurora-privacy` or GitHub Pages.

---

## Play Console — create app checklist

Account status: **approved developer account** (you already have this).

1. **Create app** → name `Aurora Downloader`, language EN, free app, declarations  
2. **App access** → all features available without login (Drive optional)  
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
3. Create **one-time product**:  
   - Product ID: **`aurora_pro_unlock`** (must match code)  
   - Name: `Aurora Pro`  
   - Description: one-time unlock for premium power features  
   - Price: your choice (e.g. $4.99–$9.99)  
4. Activate the product  
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
- [ ] Play Billing product `aurora_pro_unlock` live  
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

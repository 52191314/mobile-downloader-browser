# Aurora Downloader — Complete User Guide

> **Version:** 4.0.1 (52)  
> **Platform:** Android  
> **License:** GPL-3.0

---

## Table of Contents

1. [Quick Start](#1-quick-start)
2. [Download Manager](#2-download-manager)
3. [Queue Page](#3-queue-page)
4. [Built-in Browser & Media Sniffer](#4-built-in-browser--media-sniffer)
5. [Settings Reference](#5-settings-reference)
6. [Download Rules](#6-download-rules)
7. [Schedule](#7-schedule)
8. [Ad Blocking](#8-ad-blocking)
9. [Extra Video Hosts](#9-extra-video-hosts)
10. [Themes & Accent Color Packs](#10-themes--accent-color-packs)
11. [Private Vault](#11-private-vault)
12. [Watcher (RSS/Page Monitoring)](#12-watcher-rsspage-monitoring)
13. [Automation API](#13-automation-api)
14. [Picture-in-Picture (PiP)](#14-picture-in-picture-pip)
15. [Incognito / Private Mode](#15-incognito--private-mode)
16. [FFmpeg Studio](#16-ffmpeg-studio)
17. [WebDAV Backup](#17-webdav-backup)
18. [Google Drive Sync](#18-google-drive-sync)
19. [Pro & Ultra Tiers](#19-pro--ultra-tiers)
20. [Troubleshooting](#20-troubleshooting)

---

## 1. Quick Start

### Install the App

Aurora Downloader is available on:
- **GitHub / F-Droid / Sideload:** Default build channel (no billing).
- **Google Play Store:** Play build with Play Billing integration for Pro upgrades.

### Basic Workflow

1. **Browse** — Use the built-in browser (middle tab) to navigate to any site.
2. **Sniff** — When the browser detects media (video/audio), a badge appears on the radar icon. Tap it to see all detected media URLs.
3. **Download** — Tap a detected media item to start downloading, or long-press for options.
4. **Monitor** — Switch to the Queue tab (left) to see downloading, completed, and scheduled tasks.
5. **Open** — Tap a completed download to open it, or long-press for share/move-to-vault options.

### Add a URL Manually

1. On the Queue page, type or paste a URL into the URL field at the top.
2. Tap the **Download** button (or the **Schedule** clock icon to set a download time).
3. The app probes the URL, determines the filename, and adds it to the queue.

---

## 2. Download Manager

Aurora Downloader supports three download engines:

### a) Segmented HTTP Download

The default engine for direct file URLs (`.mp4`, `.zip`, `.apk`, etc.).

- **How it works:** The file is split into chunks and downloaded in parallel. Chunks are reassembled after all parts complete.
- **Pause/Resume:** Fully supported. Partial downloads resume from where they left off.
- **Speed limiting:** Can be set globally in Settings → Downloads → Defaults.
- **Auto-retry:** Failed chunks retry automatically (configurable up to 24 retries).

**Configurable in Settings → Downloads → Defaults:**
- Max concurrent downloads (1–64, tier-dependent)
- Chunks per download (1–64, tier-dependent)
- Speed limit (unlimited to 500 MB/s)
- Auto-retry on/off + retry limit
- Stall timeout (5–120 seconds)
- Minimum speed threshold
- Partial merge threshold (when to merge partial downloads)

### b) HLS (m3u8) Download

For streaming video sites that serve HLS playlists.

- **How it works:** Parses the `.m3u8` playlist, downloads all `.ts` segments in parallel, decrypts AES-128 encrypted segments, and remuxes to MP4 via FFmpeg.
- **Quality selection:** When multiple variant playlists are detected, you can choose the desired quality.
- **Segment cap:** Free: 4, Pro: 8, Ultra: 64 (effectively unlimited).

### c) BitTorrent

For magnet links and `.torrent` files.

- **How it works:** Uses `libtorrent_flutter` for native BitTorrent support.
- **Metadata parsing:** Automatically extracts file list from torrent metadata.
- **Usage:** Paste a magnet link or upload a `.torrent` file. The queue page shows the torrent's file list.

### Download Behavior

When you tap a download link, the app follows your **Download link behavior** setting (Settings → Downloads → Defaults):

| Behavior | What happens |
|----------|--------------|
| **Save to tray** | Adds to queue silently. |
| **Download right away** | Starts immediately. |
| **Ask each time** | Shows a prompt: Download / Skip / Cancel. |
| **Block link** | Ignores all download links. |

---

## 3. Queue Page

The Queue page (left tab) is your download command center.

### State Filter Chips

Use the chips at the top to filter tasks by state:

| Chip | Shows |
|------|-------|
| **All** | Every task in the queue. |
| **Active** | Downloading, idle, and merging tasks. |
| **Scheduled** | Tasks with a future start time. |
| **Paused** | Manually paused downloads. |
| **Done** | Completed downloads. |
| **Failed** | Downloads that ended in error. |

### Sort Options

Tap the sort button to change ordering: **Date** / **Name** / **Size** / **Priority** / **State** / **Speed**. Toggle ascending/descending.

### View Mode

Toggle between **Sections** (grouped by state: Active, Scheduled, Paused, Completed, Failed) and **Flat list** (all tasks in one list).

### Search

Tap the search icon to filter tasks by name or URL in real time.

### Task Cards

Each download is displayed as a card showing:

- **Filename** and URL (truncated)
- **Progress bar** with percentage and bytes downloaded / total
- **Speed indicator** (current download speed)
- **State badge** (colored: blue=active, purple=scheduled, orange=paused, green=done, red=failed)
- **Primary action button** — contextual: Pause / Resume / Retry / Open / Cancel scheduled
- **Overflow menu** (three dots) — see below

### Card Actions

| Action | When available | What it does |
|--------|---------------|--------------|
| **Open** | Completed | Opens the file with the system default app. |
| **Share…** | Completed | Shares the file via Android share sheet. |
| **Send to PC…** | Completed (Pro) | Transfers the file over LAN to a desktop browser. |
| **Move to Vault…** | Completed (Pro) | Encrypts and moves the file to the Private Vault. |
| **Edit in FFmpeg Studio…** | Completed (Ultra) | Opens the file in FFmpeg Studio for processing. |
| **Redownload** | Not active | Downloads the file again from scratch. |
| **Force merge** | Incomplete, not active | Forces merging of downloaded chunks. |
| **Refresh link** | Failed, refreshable failure | Re-probes the URL and updates the task. |
| **Re-sniff on page** | Has source page | Re-opens the source page in the browser for sniffing. |
| **Open source page** | Completed + source URL | Opens the page the download came from. |
| **Remove / Cancel** | Always | Removes from queue (cancels if downloading). |
| **Properties** | Always | Shows detailed metadata: URL, save path, headers, cookies, timestamps. |

### Swipe Gestures

- **Swipe right:** Contextual action (Pause / Resume / Retry / Open / Cancel scheduled).
- **Swipe left:** Delete/cancel the task.

### Bulk Selection

Long-press a task card to enter multi-select mode. Select multiple tasks and apply batch actions: Cancel all scheduled, Delete selected, etc.

---

## 4. Built-in Browser & Media Sniffer

The browser (middle tab) is a full-featured WebView with media detection capability.

### Address Bar

- Type a URL or search term.
- Search suggestions appear as you type.
- Tap the **lock/globe** icon to view page info and certificate details.
- Tap the **star** icon to bookmark the current page.
- The address bar shows a **purple shield icon** when incognito mode is active.

### Browser Tools (Menu)

Tap the **Browser tools** button (dock, or menu in the address bar) to open the tools bottom sheet:

| Tool | Description |
|------|-------------|
| **Favorites** | View, edit, and open bookmarked pages. |
| **Saved Pages** | Offline-saved pages (full HTML snapshots). |
| **Save Page** | Save the current page for offline reading. |
| **History** | Browse navigation history. |
| **Find in Page** | Search for text on the current page. |
| **Autofill** | Manage autofill profiles (addresses, credentials). |
| **Reader Mode** | Strip clutter and view the page in a clean reading layout. |
| **Block Element** | Tap an element on the page to block it (adblock helper). |
| **Reset Blocks** | Remove all manually blocked elements. |
| **Adblock: On/Off** | Toggle ad blocking for the current page. |
| **Re-scan** | Force a re-scan of the page for media URLs. |
| **Clear Cookies** | Clear all cookies for the current page. |

### Customizable Dock

The bottom dock (in the browser) is fully customizable. Go to **Settings → Appearance → Bottom dock** to reorder buttons across two slides. Available dock buttons:

| Button | Function |
|--------|----------|
| Go back | Navigate back in history. |
| Go forward | Navigate forward in history. |
| Sniffed media | Opens the media detection panel. |
| Downloads | Opens the queue page. |
| Tabs | Shows tab switcher. |
| Home | Navigates to the home page. |
| Browser tools | Opens the tools menu sheet. |
| History | Shows browsing history. |
| Bookmarks | Shows bookmarks/favorites. |
| Settings | Opens settings. |
| Adblock | Opens adblock controls. |
| Reader mode | Toggles reader mode. |

Each slide can hold up to 5 buttons. You can add any button to either slide and reorder them freely.

### Tab Management

- **Open new tab:** Tap the tabs button → "+" or tap "New tab".
- **Switch tabs:** Tap the tabs button → tap a tab.
- **Close tab:** Swipe left on a tab, or tap the ×.
- **Tab groups:** Organize tabs into named groups (Pro feature — up to 3 groups free, unlimited Pro).

### Media Sniffing

The browser automatically detects media URLs (video, audio, HLS, images) on the pages you visit.

**Three detection mechanisms work together:**

1. **JavaScript injection** (`browser_guard.js`) — hooks into `fetch`, `XMLHttpRequest`, `HTMLMediaElement`, DOM mutations, and performance observers to catch media URLs as they load.

2. **Native WebView resource interception** — monitors page resources for media extensions and video-hosting CDN domains.

3. **Dart-side `MediaSnifferEngine`** — classifies detected URLs by type, deduplicates, and enriches with metadata via HEAD/Range probes.

**To view and download detected media:**

1. Tap the **radar icon** (with badge count) on the dock.
2. The sniffed media panel shows all detected media grouped by type (Video, Audio, HLS, Images, Documents, Archives).
3. Tap a media item to download it, or long-press for options:
   - **Download** — Start downloading immediately.
   - **Copy URL** — Copy the media URL to clipboard.
   - **Open in browser** — Navigate to the media URL.
   - **Info** — Show media metadata (size, resolution, codec, bandwidth).

### Site Profiles

Per-site settings override (Pro feature):

- **Custom download folders:** Downloads from a specific site go to a specific folder.
- **Custom headers:** Add extra HTTP headers for specific sites (e.g., authentication tokens).
- **User-Agent overrides:** Use a different User-Agent per site.

Configure in **Settings → Browser → Profiles**.

### Session Recovery

If the app is closed and reopened, your tabs are restored automatically (within the tab group limit).

### Safe Browsing

The browser checks visited URLs against a local blocklist of known phishing and malware sites. Warnings are shown for dangerous pages.

### Autofill

Save and auto-fill form data (addresses, login credentials). Manage profiles in **Browser Tools → Autofill**.

### Reader Mode

Strips ads, navigation, and clutter from articles for a clean reading experience. Tap **Reader mode** in the browser tools menu to toggle.

---

## 5. Settings Reference

### Downloads → Defaults

| Setting | Description | Default | Pro? |
|---------|-------------|---------|------|
| Max concurrent downloads | How many downloads run at once. | 3 (free), 16 (Pro), 64 (Ultra) | Tier cap |
| Chunks per download | Parallel chunks per task. | 8 (free), 32 (Pro), 64 (Ultra) | Tier cap |
| Destination folder | Where completed downloads are saved. | `Downloads/Aurora/completed` | No |
| Auto-retry | Automatically retry failed downloads. | On | No |
| Retry limit | Max retries before giving up (1–24). | 3 | No |
| Auto-classify | Sort downloads into sub-folders by type. | On | No |
| Custom extension mappings | Map file extensions to folder names. | Empty | No |
| Convert .ts to .mp4 | Remux HLS downloads to MP4. | On | No |
| Include quality suffix | Append quality label to filenames. | On | No |
| Max detected media | Max items the sniffer tracks per page (20–150). | 50 | No |
| Download link behavior | How the app handles download links. | Save to tray | No |
| Speed limit | Global download speed cap. | Unlimited | No |
| Wi‑Fi only | Only download on Wi‑Fi connections. | Off | **Pro** |
| Stall timeout | Seconds before a stalled download is retried. | 20s | **Pro** |
| Min speed threshold | Min bytes/sec before considering stalled. | 0 | **Pro** |
| Partial merge threshold | % complete before merging partial downloads. | 95% | **Pro** |

### Downloads → Network

| Setting | Description | Pro? |
|---------|-------------|------|
| Proxy type | None / HTTP / SOCKS5 | **Pro** |
| Proxy host | Proxy server address. | **Pro** |
| Proxy port | Proxy server port. | **Pro** |
| Proxy auth | Username + password for proxy. | **Pro** |
| Global User-Agent | Mobile Chrome / Desktop Chrome / Desktop Firefox / Safari | No |
| Per-site UA overrides | Map host → User-Agent profile. | **Pro** |

### Browser → Adblock

Full details in [Section 8 — Ad Blocking](#8-ad-blocking).

### Browser → Search

| Setting | Description |
|---------|-------------|
| Search engine | Google / DuckDuckGo / Bing / Brave / Custom |
| Custom URL template | Search URL with `%s` placeholder (for "Custom" engine). |

### Browser → Sniffer

| Setting | Description |
|---------|-------------|
| Auto-open Aurora on site play | When a site tries to play a video, automatically open Aurora's player. |
| Disabled media types | Hide specific media types from sniff results (Video, Audio, HLS, Image, Document, Archive, Torrent, Playlist, Subtitle, Font). |
| Extra Video Hosts | Additional domains to probe for video content (see [§9](#9-extra-video-hosts)). |

### Browser → Profiles (Pro)

See [Site Profiles](#site-profiles) under the browser section.

### Appearance → Theme

| Setting | Description | Pro? |
|---------|-------------|------|
| Dark mode preference | System default / Light / Dark (OLED black) | No |
| Accent color pack | Change the app's accent color scheme. | Free: 1, **Pro**: 4 |
| In-app snackbar alerts | Show slide-up alerts for queue events. | No |
| Bottom dock | Reorder browser dock buttons across 2 slides. | No |

### Data & Account

| Feature | Description | Tier |
|---------|-------------|------|
| Google Drive Sync | Sync queue to Google Drive. | **Pro** |
| Backup | Save/restore queue and settings. Auto: **Pro** | Free: manual |
| Private Vault | Encrypted file storage. | **Pro** (25 items free, unlimited Pro) |
| WebDAV Backup | Remote backup to your own server. | **Pro** |
| FFmpeg Studio | Compress, trim, convert, extract audio. | **Ultra** |
| Watcher | RSS/page monitor with auto-enqueue + new-item notifications. | **Ultra** |
| Automation API | Localhost REST API for Tasker (default off). | **Ultra** |
| Upgrades | View current tier and purchase Pro/Ultra. | — |

### About

| Item | Description |
|------|-------------|
| App version | Current version and build number. |
| Tier badge | Free / Pro / Ultra. |
| Battery optimization | Open system battery settings for the app. |
| Check battery on launch | Prompt about battery optimization at startup. |
| Diagnostics | View, filter, and export app logs. |
| Open source licenses | FFmpeg + x264 license information. |

---

## 6. Download Rules

**Tier:** Pro  
**Current status:** UI and storage are complete. The rule engine is defined but not yet wired into the download pipeline. This section describes the intended behavior.

Download Rules let you automate how downloads are handled based on the source URL and media type.

### Creating a Rule

1. Go to **Settings → Downloads → Rules**.
2. Tap **Add rule** (floating action button).
3. Fill in the following fields:

| Field | Description |
|-------|-------------|
| **Name** | A friendly label for the rule. |
| **Host pattern** | Glob pattern to match the URL host (e.g., `*.youtube.com`, `*cdn*`). Leave blank to match all hosts. |
| **Media types** | Filter chips: Video / Audio / HLS / Image. Only downloads matching these types trigger the rule. Leave all unselected to match any type. |
| **Rename template** | Template for renaming downloads (see tokens below). Leave blank to keep original name. |
| **Destination folder** | Sub-folder within the download directory. |
| **Require Wi‑Fi** | Only allow this download on Wi‑Fi. |
| **Require charging** | Only allow this download while charging. |
| **Time window start/end** | Only allow this download within these hours. |

### Rename Template Tokens

| Token | Replaced with |
|-------|---------------|
| `{host}` | The URL hostname. |
| `{ext}` | File extension (including the dot). |
| `{title}` | Filename without extension. |
| `{quality}` | Video quality label (e.g., `1080p`). |
| `{date}` | Current date in `YYYY-MM-DD` format. |

**Example template:** `{host}_{title}_{quality}.{ext}` → `youtube.com_MyVideo_1080p.mp4`

### Rule Matching

Rules are evaluated in order. The **first matching enabled rule** wins. A rule matches when:
- The URL's host matches the host pattern (glob-style: `*` = any sequence, `?` = any single char).
- The media type matches the type filter (if set).
- The rule is enabled.

### Applying Rules

Intended behavior:
1. When a download URL is submitted, the rule engine checks all enabled rules.
2. If a rule matches: the file is renamed per the template, saved to the destination folder, and subject to Wi‑Fi/charging/time-window constraints.
3. If the current time falls outside the time window, the download is **scheduled** for the start of the next window.

---

## 7. Schedule

**Tier:** Pro  
**Current status:** The scheduling engine is fully implemented. The UI entry points (clock icon on queue page, time picker) are planned but not yet built. This section describes the intended behavior.

### How Scheduling Works

1. When starting a download, tap the **clock icon** (next to the Download button on the Queue page, or in the download card menu).
2. A date picker appears — choose the desired start date.
3. A time picker appears — choose the desired start time.
4. The task is saved with status **Scheduled** and appears in the purple "Scheduled" section of the queue.
5. The engine checks every 30 seconds whether any scheduled task's start time has arrived.
6. When the time comes, the task transitions to **idle** and begins downloading.

### Managing Scheduled Tasks

- **View:** Scheduled tasks appear in their own queue section (purple) and under the "Scheduled" filter chip.
- **Cancel scheduling:** Tap **Cancel scheduled** on the task card, or use the overflow menu.
- **Batch cancel:** In multi-select mode, select all scheduled tasks and tap **Cancel all scheduled**.

### Night Mode / Time Window

Download Rules (see §6) can enforce time windows. If a rule matches a download and the current time is outside its window, the download is automatically scheduled for the start of the next window.

---

## 8. Ad Blocking

Aurora Downloader features a hybrid ad blocking engine: native C++ (domain trie + Aho-Corasick pattern matching) via FFI, with a Dart fallback.

### Basic Controls

| Setting | Description |
|---------|-------------|
| **Enable adblock** | Master switch for all ad blocking. |
| **Block popups** | Block unexpected popup windows. |
| **Block invisible redirects** | Intercept invisible redirect chains. |
| **Block trackers** | Block tracking scripts and analytics using EasyPrivacy. |
| **Extended tracker pack** (Pro) | Enable extended curated tracker lists & auto-updates. |

### Filter Lists

The app comes with pre-configured filter lists from uBlock Origin:

| List | Default | Description |
|------|---------|-------------|
| uBlock Filters | ✅ On | General ad blocking filters. |
| uBlock Privacy | ✅ On | Privacy-focused filters. |
| uBlock Badware | ✅ On | Blocks malware domains. |
| uBlock Annoyances | ❌ Off | Blocks cookie notices, social widgets. |
| uBlock Quick Fixes | ✅ On | Emergency fixes between releases. |

**Free users** can enable up to 3 filter lists simultaneously. **Pro users** have unlimited filter lists.

### Custom Filter Lists (Pro)

Add your own filter list URLs:
1. Go to **Settings → Browser → Adblock**.
2. Scroll to "Custom Filter URL" and enter a URL pointing to an Adblock-format filter list.
3. Tap **Add**.

### Per-Site Allowlist

Add domains to the allowlist to disable ad blocking on specific sites:
1. In the adblock settings, tap **Add domain** in the "Per-site allowlist" section.
2. Enter the domain (e.g., `example.com`).
3. To remove, tap the × next to the domain.

### Manual Block Element

1. Browse to a page with an element you want to block.
2. Tap **Browser Tools → Block Element**.
3. Tap the element on the page. It will be hidden and added to your manual block rules.

### Reset Blocks

Tap **Browser Tools → Reset Blocks** to remove all manually blocked elements and start fresh.

---

## 9. Extra Video Hosts

Some video-hosting CDNs serve videos without standard media extensions (`.mp4`, `.m3u8`, etc.) in the URL. The **Extra Video Hosts** setting lets you add custom domains that the media sniffer will probe for video content.

### How to Use

1. Go to **Settings → Browser → Sniffer**.
2. Find the **Extra Video Hosts** panel.
3. Enter one domain per line (e.g., `cdn.myvideos.com`).
4. URLs from these domains will be probed with an HTTP HEAD request to determine their content type.

### How It Works

The built-in detection recognizes ~30 known video CDNs (DoodStream, Streamtape, MixDrop, etc.). When you add a custom domain:

1. The browser intercepts resource loads from that domain.
2. Even if the URL has no recognizable media extension, a **G1 extensionless probe** fires.
3. The probe sends an HTTP HEAD request to check the `Content-Type` header.
4. If the content type indicates video, the URL appears in the sniffed media panel.

### Example

If you frequently download from `cdn.example.com`:

1. Go to Settings → Browser → Sniffer → Extra Video Hosts.
2. Type `cdn.example.com`.
3. Browse any page that loads videos from `cdn.example.com`.
4. The video URL will be detected even without `.mp4` in the path.

---

## 10. Themes & Accent Color Packs

### Dark Mode

Choose your preferred appearance:
- **System default** — Follows the system dark/light setting.
- **Light** — Always light mode.
- **Dark (OLED black)** — Pure black background for OLED screens, saving battery.

Set in **Settings → Appearance → Theme**.

### Accent Color Packs

Accent color packs change the primary and secondary accent colors throughout the app.

**Available packs:**

| Pack | Primary | Secondary | Tier |
|------|---------|-----------|------|
| **Nord Frost** (default) | Steel blue `#5E81AC` | Cyan `#88C0D0` | Free |
| **Aurora Green** | Moss green `#A3BE8C` | Red `#BF616A` | **Pro** |
| **Warm Sunset** | Orange `#D08770` | Yellow `#EBCB8B` | **Pro** |
| **Deep Purple** | Mauve `#B48EAD` | Blue `#81A1C1` | **Pro** |

To change:
1. Go to **Settings → Appearance → Theme**.
2. Tap **Accent Color Pack**.
3. Select a pack. Pro packs show a lock icon — tap to purchase Pro.
4. The accent changes immediately across the entire app.

The accent colors affect:
- Progress bars and sliders
- Icon colors throughout the UI
- Focused borders and highlights
- Premium/Pro feature indicators
- Tab strip active indicators

---

## 11. Private Vault

**Tier:** Pro  
**Inventory cap:** Free: 25 items. Pro and Ultra: unlimited.

The Private Vault stores your downloaded files in **AES-256-GCM encrypted form**, protected by your device's biometric authentication (fingerprint, face unlock) or PIN/pattern.

### Security Architecture

| Layer | Detail |
|-------|--------|
| **Encryption** | AES-256-GCM (Galois/Counter Mode) |
| **Key storage** | Android Keystore via `FlutterSecureStorage` |
| **Authentication** | Biometric (fingerprint/face) or device PIN/pattern via `local_auth` |
| **Session timeout** | 5 minutes of inactivity → re-authentication required |
| **Screenshot protection** | `FLAG_SECURE` enabled when vault is unlocked (Android) |
| **File format** | `0x01 | nonce (12 bytes) | ciphertext + GCM tag` |
| **Path traversal** | All filenames sanitized — rejects `/`, `\`, `..`, null bytes |

### How to Use

1. **First-time setup:**
   - Go to **Settings → Data & Account → Private Vault**.
   - Authenticate with your device biometric/PIN.
   - A recovery key is generated (shown once — write it down!).
   - The vault directory is initialized.

2. **Move a file to the vault:**
   - On any completed download card, tap the overflow menu.
   - Select **Move to Vault…**.
   - Authenticate with biometric/PIN.
   - The file is encrypted and the original plaintext is deleted.

3. **View vault contents:**
   - Open the vault page. Authenticate to unlock.
   - You'll see all stored files with name, size, and modification date.
   - Tap a file to **export** (decrypt and save outside the vault).

4. **Export a file:**
   - In the vault, tap a file entry.
   - Choose **Export**.
   - Authenticate (or use cached 5-minute session).
   - The decrypted file is saved to `Documents/vault_export/`.

5. **Delete a file:**
   - In the vault, long-press a file entry.
   - Tap **Delete**. Confirm.
   - The encrypted blob is permanently removed.

6. **Lock the vault:**
   - Tap the lock button to immediately lock the vault.
   - Or just leave the vault page — it auto-locks after 5 minutes.

### Recovery Key

On first unlock, a recovery key is shown. If you lose biometric access, this key can be used to recover your vault. **Store it somewhere safe.** It is shown only once.

### WebDAV Encrypted Vault Sync (Ultra)

Back up your vault to your own WebDAV server:
1. Go to **Private Vault → WebDAV Encrypted Vault Sync**.
2. Enter your sync passphrase (different from your vault PIN).
3. Choose **Upload Local Vault to WebDAV** to back up.
4. Choose **Restore Vault from WebDAV** to restore from a previous backup.
5. Choose **Delete Remote Vault Backup** to remove the remote copy.

The sync uses **PBKDF2-SHA256** key derivation with 600,000 iterations + AES-GCM encryption. The server never sees unencrypted data.

---

## 12. Watcher (RSS/Page Monitoring)

**Tier:** Ultra

The Watcher monitors RSS feeds and web pages for new links, automatically enqueues them as downloads, and notifies you when new items appear.

### How to Use

1. Go to **Settings → Data & Account → Watcher**.
2. Tap **Add Watch**.
3. Configure the watch rule:

| Field | Description |
|-------|-------------|
| **Label** | A friendly name for this watch (e.g., "Weekly podcasts"). |
| **URL** | The RSS feed URL or web page URL to monitor. |
| **Type** | **RSS** — parses `<item>` (RSS) and `<entry>` (Atom) elements. **Page** — extracts all `<a href>` links. |
| **Regex filter** (optional) | Only match items whose titles match this regular expression. E.g., `\\.mp4$` for video files only. |
| **Interval** | How often to check: 30 min / 1 hour (default) / 2 hours / 6 hours / 12 hours / 24 hours. |
| **Enabled** | Turn the watch on or off. |

4. Tap **Save**.

### How It Works

1. While the app is running (foreground or backgrounded), an in-app timer ticks every **5 minutes**.
   This is **not** an OS-scheduled background task — if the app process is killed, checks stop until the app is reopened.
2. For each enabled rule whose `minInterval` (default 1 hour) has elapsed since `lastCheckedAt`, the service:
   - Fetches the URL.
   - Parses RSS items or page links.
   - Filters by the rule's regex (if set) and compares against the rule's `seenIds` set (up to 500 entries, auto-evicted).
   - For each new, unseen item, calls the `onEnqueue` callback → the link is added to the download queue.
3. New items also fire a local notification on the dedicated **`aurora_watcher`** notification channel.
4. The new item's ID is added to `seenIds` so it won't be re-downloaded on the next check.

Rules are persisted in `watcher_rules.json`.

### Managing Watch Rules

| Action | How |
|--------|-----|
| **Check now** | Tap the refresh icon on a rule tile — forces an immediate check. |
| **Toggle on/off** | Tap the toggle switch on a rule tile. |
| **Edit** | Tap the rule tile to modify its configuration. |
| **Delete** | Swipe left or use the delete button in the edit dialog. |

### Use Cases

- **Podcast feeds:** Monitor an RSS feed for new episodes. Regex filter: `\.mp3$`.
- **Video series:** Monitor a page that lists new video uploads. Regex filter: `\.mp4$|\.m3u8`.
- **Software releases:** Monitor a GitHub releases page for new `.apk` downloads.

---

## 13. Automation API

**Tier:** Ultra

The Automation API provides a localhost REST interface for integrating Aurora Downloader with automation tools like **Tasker**, **MacroDroid**, or custom scripts.

### Security Features

- **Ultra tier required.**
- **Default off** — the server does not run unless you enable it in Settings. The toggle is
  persisted (`automation_api_settings.json`); at app launch the server only auto-starts if you
  previously enabled it.
- Binds to **127.0.0.1:8080 only** (loopback) — not accessible from other devices on your network.
- Uses a separate port (**8080**) from the Send-to-PC LAN server.
- **Bearer token** — 32 random bytes with an `aurora_` prefix, stored in the platform's secure
  storage (not hashed), shown and regenerable on the Settings page.

### How to Use

1. Go to **Settings → Data & Account → Automation API**.
2. Tap the toggle to **enable** the server (Ultra tier required). Your choice is remembered for
   future launches.
3. Copy the displayed **Bearer token** (or tap **Regenerate** for a new one).
4. Use any HTTP client to send requests to `http://127.0.0.1:8080/`.

### API Endpoints

#### `GET /v1/status`

Returns the current app status: your tier and live queue counts.

```bash
curl -H "Authorization: Bearer aurora_<token>" http://127.0.0.1:8080/v1/status
```

**Response:**
```json
{
  "status": "ok",
  "tier": "ultra",
  "queuePending": 1,
  "queueActive": 2
}
```

#### `GET /v1/tasks`

Returns the current download queue as a list of tasks.

```bash
curl -H "Authorization: Bearer aurora_<token>" http://127.0.0.1:8080/v1/tasks
```

#### `POST /v1/tasks`

Enqueue a new download URL.

```bash
curl -X POST \
  -H "Authorization: Bearer aurora_<token>" \
  -H "Content-Type: application/json" \
  -d '{"url": "https://example.com/video.mp4", "label": "My video"}' \
  http://127.0.0.1:8080/v1/tasks
```

- `url` (required) — the URL to download.
- `label` (optional) — a friendly label for the task.

**Response (201 Created):**
```json
{
  "status": "queued",
  "url": "https://example.com/video.mp4",
  "taskId": "…",
  "savePath": "/storage/emulated/0/Download/Aurora/completed/video.mp4"
}
```

`savePath` is the real destination under the app's completed-downloads directory.

**Errors:**

| Code | Meaning |
|------|---------|
| 400 | Missing/blocked URL, or malformed JSON body. |
| 409 | The URL is already queued. |
| 413 | Request body larger than 64 KB. |
| 429 | More than 60 requests within 10 seconds. |
| 503 | The download queue is unavailable. |

#### `POST /v1/tasks/:id/pause|resume|cancel`

Pause, resume, or cancel a task by its ID.

```bash
curl -X POST \
  -H "Authorization: Bearer aurora_<token>" \
  http://127.0.0.1:8080/v1/tasks/<taskId>/pause
```

### Tasker Integration Example

1. In Tasker, create a new **HTTP Request** action.
2. **Server:** `http://127.0.0.1:8080`
3. **Path:** `/v1/tasks`
4. **Method:** `POST`
5. **Headers:** `Authorization: Bearer aurora_<token>`
6. **Content-Type:** `application/json`
7. **Body:** `{"url": "%clip"}`
8. Trigger: Share → Tasker → run this task.

---

## 14. Picture-in-Picture (PiP)

**Status:** ✅ Fully implemented.

The built-in video player supports Android Picture-in-Picture mode, allowing you to watch videos in a floating window while using other apps.

### How to Use

1. When a video is playing in the Aurora player, tap the **PiP button** (the picture-in-picture icon in the player controls).
2. The video shrinks to a floating window in the corner of your screen.
3. You can navigate to other apps, browse the web, or check your download queue while the video continues playing.
4. To return to full-screen mode, tap the PiP window.

### PiP Controls

In PiP mode:
- **Tap** the window to show controls (play/pause, close).
- **Double-tap** to toggle between current and previous aspect ratio.
- **Drag** the window to reposition it.
- **Swipe down** or tap the close button to dismiss.

### Requirements

- Android 8.0+ (API 26+).
- PiP must be supported by your device (most modern Android devices support it).
- The video must be playing in Aurora's built-in player, not an external player.

---

## 15. Incognito / Private Mode

**Status:** Settings model exists, history suppression works. The UI toggle and WebView incognito flag are under development.

Incognito mode lets you browse without saving any history, cookies, or cached data.

### Current Behavior

When incognito mode is active:
- The address bar shows a **purple shield icon** (`visibility_off`).
- Tab strip indicators turn purple.
- **Browsing history is NOT recorded** — pages visited in incognito mode do not appear in the History panel.
- The library controller suppresses history entries.

### How to Enable

> **Note:** The settings toggle is currently being implemented. Check for updates in a future release.

Once the toggle is added:
1. Go to **Settings → Browser → Sniffer**.
2. Enable **Private / Incognito mode**.
3. Or, tap the incognito icon in the browser's address bar to toggle on/off per session.

### Planned Enhancements

- WebView-level incognito flag (`incognito: true` in `InAppWebViewSettings`) to prevent cookie and cache persistence at the engine level.
- Quick-toggle button in the address bar area.
- Visual indicator changes (dark purple theme for incognito tabs).

---

## 16. FFmpeg Studio

**Tier:** Ultra

FFmpeg Studio provides audio/video processing tools powered by FFmpeg.

### Tools

| Tool | Description |
|------|-------------|
| **Compress** | Reduce file size by re-encoding with configurable quality. |
| **Trim** | Cut a segment from a video/audio file by start/end time. |
| **Convert** | Change container format (e.g., MKV → MP4). |
| **Extract Audio** | Extract the audio track from a video file (Pro: up to 3/day, Ultra: unlimited). |

Note: Audio extraction is also available directly from the download card overflow menu.

### How to Use

1. On a completed download, tap the overflow menu → **Edit in FFmpeg Studio…**.
2. The file opens in FFmpeg Studio with its properties displayed:
   - Duration, resolution, codec, bitrate, file size.
3. Select the operation you want to perform.
4. Configure parameters (quality, trim points, output format).
5. Tap **Run** to process.
6. The output file is saved alongside the original.

### File Size Limits

- **Maximum input file size:** 4 GB (FFmpeg limitation on 32-bit ARM).
- Longer files may need to be processed in segments.

---

## 17. WebDAV Backup

**Tier:** Pro

Back up your download queue and settings to your own WebDAV server.

### Configuration

1. Go to **Settings → Data & Account → WebDAV Backup**.
2. Enter your WebDAV server details:

| Field | Description |
|-------|-------------|
| **Server URL** | Full URL to your WebDAV directory (e.g., `https://nextcloud.example.com/remote.php/dav/files/username/aurora-backup/`). |
| **Username** | Your WebDAV username. |
| **Password** | Your WebDAV password (stored securely in `FlutterSecureStorage`). |

3. Tap **Save**.

### Manual Backup

1. Go to **Settings → Data & Account → Backup**.
2. Tap **Backup Now**.
3. The queue JSON and settings are uploaded to your WebDAV server.

### Auto Backup (Pro)

With the Pro tier, you can enable **scheduled auto-backup**:
1. In the WebDAV backup settings, enable **Auto backup**.
2. Choose an interval (daily / weekly / monthly).
3. Backups run automatically in the background.

### Restore

1. Go to **Settings → Data & Account → Backup**.
2. Tap **Restore**.
3. Select a backup file from your WebDAV server.
4. The queue and settings are restored. The app rebuilds its state.

---

## 18. Google Drive Sync

**Tier:** Pro

> **Current status:** This feature is under consideration and may be implemented in a future release.

Sync your download queue to Google Drive for access across devices.

### Planned Features

- OAuth authentication with Google Drive.
- Automatic queue upload to a hidden app folder in Drive.
- Cross-device queue restoration.
- Conflict resolution for concurrent modifications.

---

## 19. Pro & Ultra Tiers

### Feature Comparison

| Feature | Free | Pro | Ultra |
|---------|------|-----|-------|
| Segmented HTTP downloads | ✅ | ✅ | ✅ |
| HLS (m3u8) downloads | ✅ | ✅ | ✅ |
| BitTorrent support | ✅ | ✅ | ✅ |
| Media sniffing browser | ✅ | ✅ | ✅ |
| Ad blocker | ✅ (3 lists) | ✅ (unlimited) | ✅ (unlimited) |
| Built-in video player + PiP | ✅ | ✅ | ✅ |
| Max concurrent downloads | 3 | 16 | 64 |
| Chunks per task | 8 | 32 | 64 |
| HLS segment cap | 4 | 8 | Unlimited |
| Tab groups | 3 | Unlimited | Unlimited |
| Cosmetic rules | 25 | Unlimited | Unlimited |
| Private Vault | 25 items | Unlimited | Unlimited |
| Audio extraction (daily) | — | 3/day | Unlimited |
| Download Rules | — | ✅ | ✅ |
| Scheduled downloads | — | ✅ | ✅ |
| Wi‑Fi only downloads | — | ✅ | ✅ |
| HTTP/SOCKS5 proxy | — | ✅ | ✅ |
| Per-site profiles | — | ✅ | ✅ |
| Per-site User-Agent | — | ✅ | ✅ |
| Batch capture / Grab All | 5 items | Unlimited | Unlimited |
| Series auto-grab | 5 eps | Unlimited | Unlimited |
| Send to PC (LAN) | 20/day | Unlimited | Unlimited |
| Extended tracker lists & auto-updates | — | ✅ | ✅ |
| Advanced stall controls | — | ✅ | ✅ |
| Clipboard URL catch | — | ✅ | ✅ |
| Rich notifications | — | ✅ | ✅ |
| Duplicate finder | — | ✅ | ✅ |
| Custom filter lists | — | ✅ | ✅ |
| WebDAV backup + auto | — | ✅ | ✅ |
| Theme & accent packs | 1 pack | 4 packs | 4 packs |
| No upsell nags | — | ✅ | ✅ |
| Google Drive Sync | — | ✅ | ✅ |
| FFmpeg Studio | — | — | ✅ |
| Watcher (RSS/page monitor) | — | — | ✅ |
| Automation API | — | — | ✅ |
| Server-grade engine (64/64) | — | — | ✅ |
| Ultra badge + beta channel | — | — | ✅ |

### Upgrading

1. Go to **Settings → Data & Account → Upgrades**.
2. View your current tier and the available upgrades.
3. Tap **Get Pro** or **Upgrade to Ultra**.
4. Complete the purchase (Google Play billing for Play Store builds).
5. Features unlock immediately without restarting.

On **GitHub/F-Droid/sideload builds**, the upsell screen is informational — Pro features are available to all users without payment.

---

## 20. Troubleshooting

### Common Issues

| Issue | Solution |
|-------|----------|
| **Downloads stall at 0%** | Check your network connection. Try disabling proxy. If using Wi‑Fi only, ensure you're on Wi‑Fi. |
| **Media not detected** | Ensure adblock isn't blocking media scripts. Try tapping **Re-scan** in browser tools. Add the site's CDN domain to **Extra Video Hosts**. |
| **Adblock not working** | Verify the filter lists are enabled and downloaded. Check the per-site allowlist. Try adding a custom filter URL. |
| **Vault won't unlock** | Ensure you have a device PIN/biometric set up. The vault fails closed on unsecured devices. Use your recovery key if you've lost biometric access. |
| **Scheduled tasks not starting** | The engine checks every 30 seconds. Ensure the task's state shows "Scheduled" and the start time has passed. |
| **Watcher not detecting new items** | Check that the rule is enabled and the interval has elapsed. Tap **Check now** to force an immediate check. Verify the RSS feed or page URL is accessible. |
| **Automation API won't start** | The server is off by default — enable it in Settings → Data & Account → Automation API (Ultra tier required). Ensure no other app is using port 8080. It binds to 127.0.0.1 only — you cannot access it from other devices. |
| **Downloads fail with "Restricted"** | The URL matches the Restricted Media Policy (blocks known piracy/proxy/token-leak domains). No workaround — this is a compliance feature. |
| **WebDAV backup fails** | Verify your WebDAV credentials. Check that the server URL includes the correct path. Ensure your server supports PUT requests. |

### Diagnostics

For advanced troubleshooting:
1. Go to **Settings → About → Diagnostics**.
2. View the log stream in real time.
3. Filter by category (Download, Sniffer, Adblock, Vault, etc.).
4. Tap **Export** to save logs for sharing with developers.

### Battery Optimization

If downloads stop when the screen turns off:
1. Go to **Settings → About → Battery optimization**.
2. Tap **Open settings** to navigate to your system's battery optimization settings.
3. Set Aurora Downloader to **Unrestricted** / **Don't optimize**.

### Getting Help

- **GitHub Issues:** Report bugs and request features at the project's issue tracker.
- **Documentation:** See the `docs/` directory in the repository for detailed design documents and security audit reports.

---

*Last updated: 2026-08-07*

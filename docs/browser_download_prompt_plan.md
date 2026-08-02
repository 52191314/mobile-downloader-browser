# Browser Download Prompt Plan (Firefox-style "Save this file?")

**Status:** Draft — plan only, no code changes yet.
**Target:** When a user taps a link that triggers a file download on any
website (`.apk`, `.zip`, `.pdf`, `.exe`, `<a download>`,
`Content-Disposition: attachment`, …), Aurora should behave like Firefox /
Chrome / 1DM: show a prompt asking **“Do you want to download <file>?”** with
Download / Not now, plus optional “Remember my choice” and “Open after
completion”.

---

## 1. Current state (what exists)

| Piece | File | What it actually does |
|-------|------|------------------------|
| Behavior enum | `lib/settings/download_settings.dart:40` | `DownloadLinkBehavior { capture, autoDownload, ask, block }` — default **capture** |
| Detection | `lib/sniffer/browser_controller.dart:1185` `onDownloadStartRequestCallback` | Fires on WebView download start (native `<a download>` / attachment). Routes to sniffer + `_onDownloadStartRequest`. |
| JS hook | `assets/browser_guard.js` fetch/XHR wraps | Sniffs media URLs from page JS. |
| Behavior switch | `lib/sniffer/controllers/tab_callback_binder.dart:535` | switches on `downloadLinkBehavior`: `capture` → snackbar; `autoDownload` → enqueue; `ask` → `handleDownloadPrompt`; `block` → ignore. |
| Prompt dialog | `lib/sniffer/enqueue_download.dart:293` `showDownloadBehaviorPrompt` | **Bare `AlertDialog`**: title “Start download?”, body “File: x”, buttons Download/Skip/Cancel (Skip == Cancel == no-op). No icon, no size, no source, no “remember”, no “open after”. |
| Existing UI pattern | `lib/sniffer/sheets/external_app_prompt_sheet.dart` | The sheet pattern we want to match (icon, title, source host, link preview, per-host “Don’t ask again”, Open / Don’t open). |
| Settings UI | `lib/ui/pages/settings_page.dart:759, 2819` | Dropdown to pick `DownloadLinkBehavior`. |
| Site profiles | `lib/sniffer/models/site_profile.dart` | Per-host override model (desktopMode, UA, adblock, replaceSitePlayer, downloadFolder, customHeaders) — **no `downloadLinkBehavior`/ask override yet.** |

---

## 2. The problem

- Default behavior is `capture` → link goes to sniffer tray with a faint
  snackbar; user never sees an explicit prompt. Feels like “nothing happened.”
- `ask` mode shows the bare AlertDialog above — no context, wrong actions.
- No per-host memory (“always ask”, “never ask”) → forces a global choice.
- No “Open after download” for documents/apps; users must go to Queue and
  tap open manually.

Firefox/1DM behavior we want:
1. Immediate prompt on any direct-download link: **“Download <filename>?”**
2. Icon + type badge (Archive / Installer / Document), file size when known.
3. Buttons: **Download** / **Not now**. (No confusing third option.)
4. Optional: **“Always ask on this site”** / **“Don’t ask on this site”**.
5. Optional: **“Open after download”** checkbox for documents/apks.

---

## 3. Design

### 3.1 Trigger path (unchanged)

Keep `onDownloadStartRequestCallback` → `_onDownloadStartRequest` →
`tab_callback_binder` switch. Add the new prompt as the default UX.

### 3.2 New behavior semantics

Re-map `DownloadLinkBehavior`:

| Enum | Behaviour |
|------|-----------|
| `capture` (default) | Silently capture to tray + snackbar (current). |
| `autoDownload` | Download immediately, no prompt. |
| `ask` | **New prompt sheet** (this plan). |
| `block` | Ignore. |

Plus a **per-host override** on `SiteProfile`: `downloadLinkBehavior?` (new
nullable field, backward compatible). Effective behavior:

```
profile?.downloadLinkBehavior ?? settings.downloadLinkBehavior
```

### 3.3 New prompt sheet: `DownloadPromptSheet`

Location: `lib/sniffer/sheets/download_prompt_sheet.dart` (new).

Layout mirrors `external_app_prompt_sheet.dart` (rounded top sheet):

- **Icon** by `MediaType`/`ContentType`:
  - `.apk`/`.exe` → `Icons.android_rounded` / system_app
  - `.zip/.rar/.7z` → `Icons.inventory_2_rounded` (archive)
  - `.pdf/.doc/.txt` → `Icons.description_rounded`
  - video/audio → `Icons.play_circle_rounded` / `Icons.audiotrack_rounded`
  - fallback → `Icons.download_rounded`
- **Title:** `Download this file?`
- **Subtitle:** `filename.apk ± humanized size` (if known from sniff or a quick
  HEAD).
- **Body row:** full URL in mono, truncated (like external_app prompt).
- **Source line:** `Requested by pageHost`.
- **Checkbox row:** `Always ask on host.com` / `Don't ask again on host.com`
  (mutually exclusive via a 3-state or two checkboxes → simpler: a single
  “Remember my choice for this site” toggle + the chosen action persists).
- **Optional checkbox:** `Open after download` (only for documents/archives/
  installs, not streaming media).
- **Buttons:** `Not now` (text / outlined) and `Download` (filled accent).

Returns an enum result:
`{ download, downloadAndOpen, cancel, alwaysAndDownload, neverAgain }`.

### 3.4 Metadata for the prompt

Need filename + size + type + source host:

1. **From sniffer first:** if the URL is already in `tab.snifferEngine.detectedMedia`,
   reuse `SniffedMedia.name`, `contentLengthBytes`, `contentType`, `MediaType`,
   `sourcePageUrl`. Zero network cost.
2. **Otherwise quick HEAD:** call existing probe —
   `tab.controller.fetchHeadersViaJavaScript(url)` (WebView-stack HEAD,
   correct Referer/cookies) with a **300 ms** timeout. On timeout, show prompt
   without size. Fall back to `WorkerIsolatePool` native probe if JS HEAD fails.
3. Never block the prompt UI longer than a short timeout; show a
   “Fetching size…” inline spinner if needed (max ~500 ms).

### 3.5 Where the prompt runs

- `handleDownloadPrompt` in `sniffer_screen.dart` calls
  `showDownloadPromptSheet(...)` instead of `showDownloadBehaviorPrompt(...)`.
- The `capture` snackbar path remains untouched for now; when `ask` is on (or
  site profile overrides), the **new** sheet runs.
- Deduplicate with `DuplicateDownloadDialog`: if the URL is already in the
  download queue, show `showDuplicateDownloadDialog` **instead of** the new
  prompt (same flow as auto-download mode).

### 3.6 Open-after-download

For `downloadAndOpen`:
- Enqueue with normal `enqueueDirectDownload` (headers, rules, subfolder).
- Register a completion listener on the resulting `DownloadTask` → on
  `published`, call `PublicDownloadsService.open(task)` (exists at
  `lib/platform/public_downloads_service.dart:109`).
- Show a snackbar “Downloaded — opening…”. Failure → “Saved, but couldn’t
  open”, no crash.

### 3.7 Site-profile integration

- Extend `SiteProfile` with `downloadLinkBehavior: String?` (stored as enum
  name) plus `autoOpenDownloads: bool?` maybe later.
- Settings → Site Profiles editor gains a “Download links” row with the same
  dropdown.
- Prompt’s “Remember my choice for this site” writes/updates the matching
  `SiteProfile` (host pattern = current page host) via `SiteProfileStore`.

### 3.8 Settings default

- Keep default `capture` for now (no disruptive change), but relabel the
  dropdown options clearer and add a help text: “ask = Firefox-style prompt,
  capture = sniffer tray”.
- Optional: after the new prompt ships, consider making `ask` the default.

---

## 4. Files to change

| File | Change |
|------|--------|
| `lib/sniffer/sheets/download_prompt_sheet.dart` | **New** — the sheet UI above. |
| `lib/sniffer/sniffer_screen.dart` | `handleDownloadPrompt` calls new sheet; pass sniffed size/type/host; call duplicate check first; implement open-after-download completion hook. |
| `lib/sniffer/controllers/tab_callback_binder.dart` | Unchanged; switch stays the same wiring point. (May pass extra context if needed.) |
| `lib/settings/download_settings.dart` | (optional) relabel dropdown copy only — no model change. |
| `lib/sniffer/models/site_profile.dart` | Add `downloadLinkBehavior` field + JSON; update editor in `settings_page.dart` site-profile section. |
| `lib/sniffer/enqueue_download.dart` | Delete or replace `showDownloadBehaviorPrompt` (keep for backward compat initially, mark `@Deprecated`). |
| `lib/ui/pages/settings_page.dart` | Site profile editor: add Download link behavior per profile. |
| `assets/browser_guard.js` | **No change.** |

---

## 5. Pseudocode flow

```dart
// tab_callback_binder.dart :526 (existing)
tab.controller.setOnDownloadStartRequest((url, suggestedFilename) async {
  await _sniffIntakeController.sniffWithLiveHeaders(tab, url,
      sourcePageUrl: tab.addressController.text);
  if (!_host.isMounted) return;

  final effectiveBehavior =
      navOverrideFor(url, profiles)?.downloadLinkBehaviorEnum ??
      settings.downloadLinkBehavior;
  switch (effectiveBehavior) {
    case DownloadLinkBehavior.capture: /* current snackbar */ break;
    case DownloadLinkBehavior.autoDownload: enqueueDirect(...); break;
    case DownloadLinkBehavior.ask:
      _host.handleDownloadPrompt(tab, url, suggestedFilename); break;
    case DownloadLinkBehavior.block: break;
  }
  ...
});

// sniffer_screen.dart
Future<void> handleDownloadPrompt(tab, url, suggestedFilename) async {
  // 1) already queued? → duplicate dialog instead
  // 2) size/type: from detectedMedia match, else fetchHeadersViaJavaScript(url)
  //    (300ms timeout)
  // 3) showDownloadPromptSheet(...) → result
  // 4) result:
  //    download        → _enqueueDirectDownload
  //    downloadAndOpen → _enqueueDirectDownload + on-complete open
  //    alwaysDownload  → save SiteProfile.downloadLinkBehavior=autoDownload, enqueue
  //    neverAgain      → save SiteProfile.downloadLinkBehavior=block
  //    cancel          → nothing
}
```

---

## 6. Success criteria

1. Tapping a `.zip`/`.apk`/`.pdf` link on a random site shows the new sheet
   with correct icon, filename, and (when quickly known) size.
2. `Download` enqueues immediately (existing direct path rules apply);
   `Not now`/`Cancel` dismisses with no action.
3. “Remember for this site” writes a `SiteProfile`; on next visit the site
   honours that choice without prompting.
4. “Open after download” opens the published file via the system when done.
5. No regression in `capture`/`autoDownload`/`block` modes, and existing
   sniffer/tray behavior is unchanged.

---

## 7. Out of scope

- Changing how media sniffing works (only the direct-link download prompt).
- A “Save to folder” picker in this sheet (can add later as item 5).
- Per-MIME-type global behaviors (e.g. “always ask for APKs, auto for images”).

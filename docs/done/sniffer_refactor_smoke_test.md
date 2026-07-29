# Sniffer Refactor — Smoke Test Checklist

**Created:** 2026-07-18  
**Purpose:** Manual verification that Phases F1–F4 did not introduce runtime regressions.  
**Pass bar:** All 5 core scenarios must succeed before merging.

---

## Core smoke tests (must pass)

| # | Scenario | Steps | Pass criteria |
|---|---|---|---|
| **1** | Browser navigation | Open any HTTPS page → tap links → watch address bar | URL updates; page loads without blank tabs; back/forward buttons enable correctly |
| **2** | Capture → Add Queue dialog | Visit a page with media → open capture tray → tap **Add to Queue** → rename the file → confirm | Dialog opens with correct filename/suggestions; rename pencil works; enqueue succeeds; task appears in queue |
| **3** | HLS variants | Visit a page with HLS video (e.g. a `.m3u8` source) → Add Queue → click the quality dropdown | Quality variants load within a few seconds; picking a variant and downloading works |
| **4** | Multi-tab lifecycle | Open 3+ tabs → switch between them → close one from the strip | Tab strip updates; switched tab loads its page; closed tab removed; no `NullPointerException` or blank WebView |
| **5** | Address suggestions | Type in the address bar → suggestions panel appears → tap a suggestion | Panel shows history/bookmarks/search rows; tapping navigates to that URL; panel dismisses |

---

## Risk-driven smoke (spot-check)

These cover the specific extraction seams that changed behavior:

### F1 — Part files → standalone libraries

| # | What | Why |
|---|---|---|
| F1-1 | Add Queue dialog on a page with long title | `RenameFileDialog` is now imported via `showRenameFileDialog` — verify the rename flow works |
| F1-2 | Folder selector dropdown populates subfolders under `completed/` | `FolderSelector` moved from `part` to standalone `dart:io` import |

### F2 — TabCallbackBinder extraction

| # | What | Why |
|---|---|---|
| F2-1 | Page with compliance-restricted media (e.g. certain adult sites) | `showComplianceNotice()` moved from inline `AuroraSnackbar.show(context, ...)` to a host forwarding method |
| F2-2 | Download link click → capture / auto-download / ask / block behavior | `setOnDownloadStartRequest` closure captures `_host` instead of `this` — verify all 4 `DownloadLinkBehavior` modes work |
| F2-3 | Invisible redirect / popup blocked | `handlePopupEvent` / `handleInvisibleRedirect` now go through host forwarding |
| F2-4 | Strict redirect prompt | `handleNativeStrictRedirect` passes `event as dynamic` cast |

### F3 — Chrome widget extraction

| # | What | Why |
|---|---|---|
| F3-1 | Private mode tab strip | `TabStrip` widget receives `isPrivateMode` via props — check purple shield icon appears |
| F3-2 | Suggestion panel scrolls when > 5 items | `AddressSuggestionPanel` uses `rowHeight` constant from new widget |

### F4 — HLS variant fetcher extraction

| # | What | Why |
|---|---|---|
| F4-1 | HLS playlist behind Cloudflare (403 on Dart HTTP) | `HlsVariantFetcher` uses 3-tier fallback — verify WebView JS / native HTTP still works |
| F4-2 | Cached playlist body reused | Browser-captured playlist body (0th attempt) should skip network entirely |

---

## Regression risk register

| Area | Risk | Likelihood | Mitigation |
|---|---|---|---|
| `TabCallbackBinder` closure captures | Callback closes over stale `tab` / `_host` | Low — each closure captures the `tab` parameter explicitly (same pattern as before) | Smoke #1, #2, #4 |
| `HlsVariantFetcher` native result parsing | `Map['statusCode']` vs `.statusCode` | Low — verified against `browser_controller.dart` usage | Smoke F4-1 |
| `showComplianceNotice` context validity | `context` may be stale in async gap | Very low — called synchronously from `onPageFinished` callback | Smoke F2-1 |
| Unused imports causing tree-shake issues | Build system strips seemingly-unused but actually-needed imports | Very low — Flutter tree-shaking is conservative | Full build test |
| `BrowserDock` public rename | External importers referencing old `_BrowserDock` | None — `_BrowserDock` was a private class, inaccessible externally | N/A |

---

## Quick command-line verification

```bash
# Analyze touched files for errors
dart analyze lib/sniffer/sniffer_screen.dart \
            lib/sniffer/controllers/tab_callback_binder.dart \
            lib/sniffer/hls_variant_fetcher.dart \
            lib/sniffer/widgets/add_queue_dialog.dart \
            lib/sniffer/widgets/capture_widgets.dart \
            lib/sniffer/widgets/address_suggestion_panel.dart \
            lib/sniffer/widgets/tab_strip.dart \
            lib/sniffer/filename_utils.dart

# Run existing tests
flutter test test/sniffer/ test/downloader/
```

---

## Sign-off

| Date | Tester | All 5 core tests pass? | Notes |
|---|---|---|---|
| | | ⬜ | |

# Custom Tab (Chrome) Fallback for WAF-blocked Hosts — Plan (xchina.co)

**Status:** Draft — plan only, no code changes yet.
**Target:** Route hosts that hard-block Android System WebView (xchina.co)
through a **Chrome Custom Tab (CCT)** so downloads still work via Aurora's
existing sniffer intake.
**Related:** `docs/cloudflare_stealth_bypass_plan.md` (Phase A header fixes —
still worth doing so *softer* CF sites don't need this fallback at all).

---

## Problem

On xchina.co:

| Client | Engine | Result |
|--------|--------|--------|
| Chrome | Full browser | Works |
| UC Browser | Full browser | Works |
| **Aurora** | Android System WebView | Hard block (`Sorry, you have been blocked`) |
| 1DM | WebView-class | Hard block |

Even after the v1 stealth fix, the app detects the block, retries once, and
reports "Cloudflare block persisted". The current stealth headers/JS cannot
get past Cloudflare Bot Management's scoring of the WebView on this host.

Downloads themselves already use the **native** stack
(`NativeDownloadEngine.kt` / `NetworkBindingService.streamSegmentToFile` via
`HttpURLConnection`) — they don't go through the WebView. The only part that
needs the WebView is **page rendering + media sniffing**.

---

## Why Chrome Custom Tabs

A **Custom Tab** (CCT) is real Chrome (or the user's default CCT browser)
embedded as a sheet inside Aurora — the same engine that already passes
Cloudflare on this device. Aurora gets:

- **Full CF pass** (real Chrome TLS/JA3 — identical to standalone Chrome).
- **2 custom toolbar action buttons** ("Sniff & Download").
- **Current page URL** via a bound session's navigation callback.

A CCT does **not** expose the page DOM or network requests, and we cannot
read Chrome's cookie jar — so it is not a drop-in replacement for the
internal sniffer WebView. It is a **fallback for hostile hosts only**.

---

## Sniffing pipeline (reuses existing code)

The button only yields a **page URL**. Aurora already has the resolver that
turns a page URL into media without the WebView:

```
CCT page URL (xchina.co/...)
        │
   tap "Sniff & Download"
        │
   ChromeIntentReceiver (new)           ← CCT action button PendingIntent
        │  snippet launchMode + intent-filter
        ▼
   MainActivity.onNewIntent(url)         ← existing at :655
        │  intentUrlChannel.invokeMethod("onNewUrl", url)   ← existing channel :230
        ▼
   lib/main.dart intent handler (:1527)  ← existing
        │  routes URL back into Browser
        ▼
   SnifferScreen._navigateActiveTabToExternalUrl(url)   ← exists at :1042
        │
        ├── WebView path (CCT host, may still load or stay blocked — fine)
        └── NativeHtmlMediaExtractor.extractMediaFromUrl(url)   ← exists at :1067
                │  native HttpURLConnection fetch (CF-accepted,
                │  see surrit.com/beeg24 use in docs) + Chrome UA
                │  + iframe recursion (depth ≤2) + Base64 decode
                ▼
        for each mediaUrl → tab.snifferEngine.sniff(mediaUrl, sourcePageUrl: url)
                ▼
        DownloadQueue (HlsDownloader etc.) via native engine
```

That same intake already runs for shared/clipboard URLs, so the CCT path adds
**zero new sniffer logic** — only the Chrome-tab front-end + routing.

---

## Implementation plan

### A. Native (Android)

1. **Dependency** — `androidx.browser:browser` (latest stable) in
   `android/app/build.gradle.kts` (deps block at :191).
2. **CCT launcher** in `MainActivity.kt`:
   - `CustomTabsClient.bindCustomTabsService` / optional warmup.
   - `CustomTabsIntent.Builder()`
       `.setToolbarColor(...)` (app accent),
       `.addActionItem(msg, icon, pendingIntent)` for **Sniff & Download**.
   - Extra: put the page URL into the PendingIntent data when possible; on
     CCT navigation URLs can change, so fallback is to also send
     `EXTRA_REFERRER`-style current URL via a `CustomTabsSession`
     `CustomTabsCallback` (`onNavigationEvent(url)`), tracked per tab and
     included in the broadcast.
3. **Receiver** `ChromeIntentReceiver` (new file) or reuse an existing
   intent-forwarder to re-intent into `MainActivity` (`singleTask` /
   `clear_top`) with `action=aurora.SNIFF_AND_DOWNLOAD` + `EXTRA_URL`.
4. **Route into Flutter** — in `MainActivity`, when that action arrives,
   push through the existing `intentUrlChannel` (`onNewUrl`) so `main.dart`
   routes it into the browser exactly like a shared link. This reuses all
   existing intake (`_navigateActiveTabToExternalUrl`).
5. Keep manifest small: no exported CCT activity needed beyond receiver +
   existing intent filters.

### B. Dart

1. `lib/sniffer/cct_browser.dart` — service wrapper:
   - `isSupported()` (query for CCT service).
   - `openCustomTab(url)` → MethodChannel `aurora_downloader/cct`.
   - Listen for the `"onNewUrl"`/`"onSniffDownload"` result (piggyback on
     the existing `aurora_downloader/intent` handler in `main.dart:1527` or
     add a tiny extra method call).
2. **Routing** — a new setting `externalBrowserCctHosts: List<String>` (auto
   or per-site profile). In `_loadUrlWithHostSettings` / `_navigate…`,
   when host matches → show CCT instead of an in-app load. Alternatively, a
   per-[site profile] `openInCct: true` fits the existing
   `site_profiles` system better than a new list.
3. **CF-block auto-offer** — extend the existing
   `setOnCloudflareBlockDetected` flow: when the block persists after stealth
   retry, show a bottom sheet with:
   - **Open in Chrome (Custom Tab)** — sniff via button.
   - **Always use CCT for this site** → writes `externalBrowserCctHosts`.
   - Keep plain "Open in system browser" as backup (no sniff).

---

## Sniffing caveats (be explicit)

| Concern | Reality | Mitigation |
|---------|---------|------------|
| CCT holds Chrome's cookies; Aurora cannot read them | `cf_clearance` earned in Chrome stays in Chrome | Sniffer fetches the page itself with native HttpURLConnection; media URLs on these hosts are usually not cleared-cookie bound (xchina patterns typically work) |
| Media requests still WebView-stack when user plays in-CCT | Not needed — playback stays in-CCT or in-Aurora player | Download engine takes the URL natively |
| Page fetch via `HttpURLConnection` could be blocked on some hostile host | Already the working pattern on surrit/beeg24 | Phase A header fixes make WebView loads succeed for milder sites anyway |
| POST-only flows | Rare on these video pages | Out of scope for v1 |

---

## Success criteria

1. From a CCT on xchina.co, tapping **Sniff & Download** surfaces real media
   in Aurora's sniffer list (m3u8/mp4).
2. Download completes via the native engine with `Referer` + Chrome UA.
3. Non-blocked hosts still browse fully in-app (no CCT).
4. Toggleable per-site (site profiles) and optional global default
   `preferCctForWaf`.

---

## Out of scope

- No Cronet/curl JA3 spoofing of the internal WebView.
- No Chrome-cookie extraction.
- Not a replacement for the internal sniffer on normal sites — fallback only.
- Android 11+ package-visibility queries for CCT support check
  (`<queries>` blocks needed for `androidx.browser` service discovery).

---

## Suggested implement order

1. Deps + native CCT launch + Sniff/Download action + intent forward.
2. Dart service + route into existing intake (`_navigateActiveTabToExternalUrl`).
3. Persist per-site `openInCct` (site profiles) + auto-offer on CF block.
4. Verify xchina.co end-to-end: video listed → HLS download OK.

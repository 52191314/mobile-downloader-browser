# Cloudflare Stealth Mode — Diagnosis & Bypass Plan (xchina.co)

**Status:** v2 — draft, plan only. No code changes yet.
**Target:** Make Stealth Mode actually bypass the Cloudflare hard block
(`Sorry, you have been blocked`) on `xchina.co`.
**Repro environment:** Android, Aurora WebView, Stealth Mode ON, still blocked
after v1 fix.

---

## Symptom

Aurora shows Cloudflare's static hard-block page:

> **Sorry, you have been blocked**
> You are unable to access xchina.co …
> Cloudflare Ray ID …

The current Stealth Mode does not prevent it. After the v1 fix, the app
detects the block, retries once, and reports:

> "Cloudflare block persisted… WebView fingerprint may be rejected."

---

## Key diagnostic facts (v2)

Tested on the same phone / same network:

| Client | Engine class | Result on xchina.co |
|--------|--------------|----------------------|
| **Chrome** | Full browser (own network stack) | Works |
| **UC Browser** | Full browser (own Chromium kernel) | Works |
| **Aurora** | Android System WebView | Hard block |
| **1DM** | WebView-class app | Hard block |

### Conclusion

This is **not** an IP / ASN reputation ban (Chrome + UC work). The site's
Cloudflare Bot Management is scoring **WebView-class clients** as bots:

1. Hard block happens **before** any Turnstile/JS challenge.
2. The block persists even after stealth header/metadata retry.
3. 1DM — a completely different app using the same engine class — fails the
   same way.

WebView-header spoofing (Sec-CH-UA, UA, `wv` stripping) is **necessary** and
likely **sufficient**: Android System WebView is built on Chromium — its TLS
stack (BoringSSL), HTTP/2 behavior, and JA3 fingerprint are Chrome-like, not
Java/Dart-like. The remaining gap is **header/config consistency** (the
hardcoded `Chrome/120` UA bug, Client-Hints race, WebView brand leakage),
not TLS. That means a correctly implemented stealth layer *can* let the
WebView load the page — keeping the sniffer intact.

---

## Remaining bugs found in the v1 implementation (Phase A scope)

| # | Issue | Location | Impact |
|---|-------|----------|--------|
| 1 | **`SnifferScreen.uaForProfile` shadows the real helper** | `lib/sniffer/sniffer_screen.dart:803` | Mobile profile returns hardcoded `Chrome/120.0.0.0` while stealth Client Hints use the real system WebView version (e.g. 131.x). CF cross-checks UA vs Sec-CH-UA and hard-blocks the mismatch. |
| 2 | **Native metadata apply can "fail open"** | `MainActivity.kt:applyStealthMetadataToAllWebViews` | Returns `false` immediately when the `decorView` walk finds 0 WebViews (platform view not attached yet), only scheduling 100/300/700 ms retries. Dart still completes `_ready` and navigates with WebView brands. |
| 3 | **Navigation not gated on successful apply** | `browser_controller.dart:onWebViewCreated` | `_ready` completes after the apply *attempt*, not after a *successful* patch of ≥1 WebView. |
| 4 | **Retry doesn't verify apply succeeded** | `browser_controller.dart:_checkCloudflareBlockPage` | Re-applies, clears cookies, reloads — but never confirms the metadata patch landed before the reload. |
| 5 | **Hardcoded `platformVersion: "10.0.0"`** | `MainActivity.kt:2609`, `stealth_injector.dart:59` | High-entropy `Sec-CH-UA-Platform-Version` mismatches the real Android version. |
| 6 | **Metadata always `mobile=true`** | `MainActivity.kt` | Mismatch when a desktop UA profile is active. (Lower priority — primary path is mobile.) |

### Verified strengths (keep)

- `requestedWithHeaderOriginAllowList: {}` prevents `X-Requested-With` package
  leak (`lib/sniffer/browser_widget.dart`).
- `applicationNameForUserAgent: ''` avoids app-name leakage in the UA.
- `stripWebViewUaMarkers` removes `; wv` / `wv` / `Version/4.0` markers.
- Adblock already allowlists `challenges.cloudflare.com` /
  `/cdn-cgi/challenge-platform/` in `shouldInterceptRequest`.

---

## Plan v2

### Goal tiers

| Tier | Goal | Expectation on xchina.co |
|------|------|---------------------------|
| **A** | Consistent Chrome-like WebView fingerprint (headers + metadata + UA) | Required; may still fail on this host |
| **B** | Prove what we send (fingerprint dump) | Stop guessing |
| **C** | Product path when WebView is rejected | Reliable UX: one-tap Open in Chrome / browser |

### Phase A — Fingerprint consistency (planned)

1. **Fix shadowed `uaForProfile`** (`sniffer_screen.dart`)
   - Delegate to the top-level `sniffer_url_utils.uaForProfile` with
     `customUserAgent`, so `mobile` returns the stripped **system** UA
     (real Chrome version), never stale `Chrome/120`.
2. **Blocking native apply + navigation gate**
   - Native `applyStealthMetadata` returns the patched **count** (-1 when the
     feature is unsupported) instead of a bool.
   - Dart polls until `count > 0` (or timeout / unsupported), and only then
     completes `_ready` so the first `loadRequest` waits for stealth.
3. **Real platform metadata**
   - `platformVersion` from `Build.VERSION.RELEASE` instead of `"10.0.0"`.
   - Full version passed end-to-end (system UA) for UA ↔ Sec-CH-UA alignment.
4. **Harder retry**
   - `_checkCloudflareBlockPage` re-applies stealth and only clears cookies +
     reloads when the patch succeeded.
   - If the block persists after a verified attempt → Phase C UX.

### Phase B — Fingerprint self-check (debug only)

On CF block / long-press Stealth: dump `navigator.userAgent`,
`navigator.userAgentData` brands, and the native apply count + chromeVersion
via logs. Success gate for Phase A: no `"Android WebView"` brand, UA major ==
Sec-CH-UA major. (Lightweight — log lines only.)

### Phase C — Accept WebView ceiling + useful fallback (planned)

Chrome + UC work; WebView-class apps are rejected. On a **persisted** CF block:

1. Bottom sheet with:
   - **Open in Chrome** (targets `com.android.chrome`)
   - **Open in browser** (system resolver chooser — UC appears if installed)
   - **Always open this site externally** (persists host → future
     navigations route to the system browser automatically)
2. Copy is honest: *"This site blocks in-app WebView (same class as 1DM).
   Full browsers like Chrome/UC work."*
3. Keep the in-app WebView for normal sites.

---

## Sniffing-preserving architecture (the media-sniffing angle)

**Goal:** keep Aurora's sniffer working on CF-blocked hosts instead of giving
up the WebView. Key insight: **downloads already use the native stack**
(`NativeDownloadEngine.kt` / `streamSegmentToFile` via `HttpURLConnection`),
so only **page loading + sniffing** depend on the WebView. And WebView is
Chromium → Chrome-like TLS. The block is header/config-evaluated → fixable.

### Layers

| Layer | What | Sniffer impact |
|-------|------|----------------|
| **1. Phase A fixes** | Consistent UA ↔ Sec-CH-UA ↔ metadata (real version, no Chrome/120), gated first load | Page loads in WebView; all existing sniffer hooks (guard JS, `onLoadResource`, fetch/XHR wraps) work unchanged |
| **2. Document proxy** (fallback) | If the document request is still blocked: intercept the main-frame request in `shouldInterceptRequest`, fetch the HTML via the **native stack** (CF-accepted per codebase's own experience on surrit.com/beeg24) with Chrome headers + cookies, return it as `WebResourceResponse` | Page renders in WebView → sniffer JS + hooks still see media requests |
| **3. Cookie sync** | Write `Set-Cookie` (incl. `cf_clearance`) from the native fetch into `CookieManager` so subsequent WebView subresources carry the session | Keeps media requests authenticated |

### How media is captured (unchanged happy path)

1. Page renders in the WebView (via Layer 1 or 2).
2. `browser_guard.js` + `onLoadResource` + fetch/XHR wraps sniff `.m3u8` /
   `.mp4` URLs and post them to `MediaSnifferChannel`.
3. User taps download → the **native download engine** fetches segments with
   `HttpURLConnection` (already CF-accepted, already carries cookies via
   `CookieManager`).

So Aurora does **not** need to download through the WebView — it only needs
the WebView to *render* the page and fire media requests, which the layers
above restore.

### Technical caveats (for Layer 2)

- `shouldInterceptRequest` on Android does **not** expose POST bodies → only
  proxy GET document/subresource requests; let POSTs pass through untouched.
- Must strip `Accept-Encoding` or decompress gzip in the native fetch before
  returning bytes (WebView expects raw body).
- `Set-Cookie` from intercepted responses may not auto-apply → write them into
  `CookieManager` natively.
- Enable Layer 2 **per-host only** after a detected CF hard block (reuse the
  existing `_checkCloudflareBlockPage` signal) — never globally.
- Only needed for the main document (and possibly same-origin JS/CSS); media
  requests can pass through the WebView stack normally.

### Last resort (only if all layers fail)

Phase C external-browser fallback — works, but **loses in-app sniffing** for
that host. Layers 1–3 are the sniffing-preserving path.

---

## Out of scope / honesty

- Cannot bypass a true IP/ASN ban (not this case).
- WebView ≈ Chrome TLS (both Chromium), so the fix is header/config
  consistency — **not** a TLS-stack rewrite. No Cronet/curl-impersonate
  needed for the sniffing path.
- No cookie theft from Chrome/UC into WebView.
- No WAF exploits.

---

## Success criteria

1. **General / softer CF sites:** stealth ON loads; fingerprint is internally
   consistent (UA major == Sec-CH-UA major, no WebView brand).
2. **xchina.co:** either loads after Phase A, **or** the user gets a one-tap
   "Open in Chrome / browser" path with an honest explanation — no silent
   dead end.
3. Stealth toggle is real (ON/OFF both observable).
4. No more `Chrome/120` mobile UA when the system WebView is 13x+.

---

## Implementation notes (v2, for when implementation starts)

- New setting: `DownloadSettings.externalBrowserHosts` (`List<String>`) —
  hosts that always open in the system browser.
- New native channel method: `openUrlInChrome` on
  `aurora_downloader/public_downloads` (ACTION_VIEW + `setPackage`).
- Stealth apply channel now returns `int` count; unsupported → `-1`.

---

## Suggested implement order

1. Phase A items 1–2 (fix `uaForProfile` shadow; blocking metadata apply +
   navigation gate).
2. Phase A items 3–4 (real platform version; retry only after verified patch).
3. Phase C (Open in Chrome / browser fallback + `externalBrowserHosts`).
4. Phase B (debug fingerprint dump) last — it is only diagnostic.
5. **Sniffing layers 2–3** (document proxy + cookie sync) only if Phase A
   alone is still blocked on a given host — this is the sniffing-preserving
   escalation path.

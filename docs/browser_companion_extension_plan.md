# Browser Companion Extension — Implementation Plan

| Field | Value |
|-------|-------|
| **Date** | 2026-07-27 |
| **Status** | Plan only (not implemented) |
| **Goal** | Let a desktop browser detect media and hand it to Aurora on the phone, so the "grab it on my laptop, it downloads on my phone" flow works without porting Aurora to desktop. |
| **Out of scope** | Porting the download engine to desktop · replacing the in-app sniffer · YouTube/DRM extraction |
| **Related** | `docs/desktop_companion_plan.md` (desktop *app* over LAN — this doc is the browser-side sibling) · `lib/premium/automation/automation_api_service.dart` (the API this reuses verbatim) · `lib/premium/lan_file_server.dart` (LAN-bind hardening pattern) |

---

## 1. Why this instead of "convert Aurora to a desktop IDM rival"

The competitive landscape is crowded on desktop and thin on Android:

| Project | Stack | Overlap with a hypothetical Aurora Desktop |
|---|---|---|
| [Gopeed](https://github.com/GopeedLab/gopeed) (~24.6k★) | Go + **Flutter**, all platforms, [official extension](https://github.com/GopeedLab/browser-extension) | Near-total. Same UI toolkit, same protocols, already shipped |
| [AB Download Manager](https://github.com/amir1376/ab-download-manager) | Kotlin/Compose MP | High — IDM-workflow clone, extension detects HLS |
| XDM 8 | Go + web UI | High — best "download this video" button parity |
| JDownloader 2 | Java | Hoster/captcha handling, dated UI |

Two structural facts make conversion a bad trade:

1. **A pure extension cannot rival IDM.** Chrome MV3 restricted *blocking* `webRequest` to force-installed enterprise extensions, so nothing can transparently take over a download any more. Every serious contender is extension **+ native host**. Converting means desktop binaries, per-browser native-messaging manifests, Windows/macOS code signing, and an auto-updater — a new product surface, not a port.
2. **Aurora's moat does not survive the move.** The differentiator is the in-app WebView sniffer holding live cookies/Referer/UA against WAF-protected hosts. On desktop the real browser already owns that session, so the advantage evaporates — and `flutter_inappwebview` has no Windows/Linux support anyway.

What *does* port: `lib/downloader` engine logic, HLS/DASH parsing, `lib/settings`, `lib/sync`. What doesn't: `flutter_inappwebview`, `libtorrent_flutter`, `ffmpeg_kit_flutter_new_min_gpl`, `in_app_purchase`, `video_player`/`chewie`, Android `MediaMuxer` remux, `libaurora_adblock.so`.

**Conclusion:** ship the reach without the rewrite. The extension is ~2 weeks; the conversion is a quarter plus a permanent second distribution pipeline.

---

## 2. Key enabling insight

MV3 removed *blocking* `webRequest`. **Observational `webRequest` still works.** Detection needs only observation:

- `chrome.webRequest.onHeadersReceived` → inspect `Content-Type` for `video/*`, `audio/*`, `application/vnd.apple.mpegurl`, `application/dash+xml`
- URL-pattern match on `.m3u8`, `.mpd`, `.mp4`, `.webm`, `.m4a`
- `chrome.webNavigation` for page context (title, page URL → becomes Referer)

So no native host is required for the detect-and-forward flow. That is the whole reason this is cheap.

---

## 3. Architecture

```text
┌──────────────────────────┐                      ┌────────────────────────┐
│ Desktop browser          │                      │ Phone (Aurora, Ultra)  │
│ ┌──────────────────────┐ │   LAN HTTP + Bearer  │ ┌────────────────────┐ │
│ │ Aurora Companion     │ │ ───────────────────► │ │ AutomationApi      │ │
│ │ (MV3 service worker) │ │   POST /v1/tasks     │ │ rebound to LAN IP  │ │
│ │  · webRequest observe │ │   GET  /v1/status    │ │ (opt-in, def. off) │ │
│ │  · badge + popup list│ │   GET  /v1/tasks     │ │                    │ │
│ └──────────────────────┘ │                      │ └─────────┬──────────┘ │
└──────────────────────────┘                      │           ▼            │
                                                  │     DownloadQueue      │
                                                  └────────────────────────┘
```

The phone side is **the existing `automation_api_service.dart` contract, unchanged** — `/v1/status`, `/v1/tasks`, `/v1/tasks/:id/{pause,resume,cancel}`, `Authorization: Bearer <token>`. The only phone-side work is the LAN rebind that `docs/desktop_companion_plan.md` P1 already specifies. **Both companions share that one phase.**

---

## 4. Required phone-side changes

### 4.1 LAN rebind (shared with desktop companion P1)

`automation_api_service.dart:83` currently hardcodes loopback:

```dart
_server = await HttpServer.bind(InternetAddress.loopbackIPv4, bindPort);
```

Needs an opt-in LAN mode copying `LanFileServer`'s pattern — bind the **specific LAN IPv4**, never `anyIPv4`. Carry over from `lan_file_server.dart`: per-IP rate limiting, absolute session TTL, and no queue contents in logs.

### 4.2 Enqueue path needs real save paths

`_handleEnqueue` (`automation_api_service.dart:245-252`) fabricates POSIX temp paths:

```dart
savePath: '/tmp/$id',
tempDir: '/tmp/${id}_tmp',
```

Those are wrong on Android — this must route through the same storage manager the sniffer intake uses, or every extension-submitted task lands somewhere unusable. **This is a real bug in the existing API, not new work.** Fix before either companion ships.

### 4.3 Accept the request context

Extend the POST body so the phone can reproduce the browser's session:

```json
{
  "url": "https://cdn.example/master.m3u8",
  "referer": "https://example.com/watch/123",
  "userAgent": "Mozilla/5.0 ...",
  "cookies": "sid=...; ...",
  "filename": "lecture-3.mp4",
  "pageTitle": "Lecture 3"
}
```

Cookies are the sensitive part — see §7. Route the result through `RestrictedMediaPolicy.evaluate()` with `referer`/`origin` populated, exactly like sniffer intake, so extension-submitted URLs get the same Play-channel gate. **Do not let the API become a bypass for `restricted_media_policy.dart`.**

---

## 5. Pairing — the honest constraint

The desktop-app plan uses QR: phone displays, desktop camera/screen-scan reads it. **An extension cannot scan a QR code**, and it cannot do mDNS discovery, so neither auto-discovery nor QR works here.

Options, ranked:

| Option | Flow | Verdict |
|---|---|---|
| **Paste-once** | Phone shows `192.168.1.42:8080` + token as one copyable string; user pastes into extension options once | **v1.** Zero infrastructure, honest, ~15s one-time cost |
| Extension shows QR, phone scans | Extension renders a QR of a secret it generated; phone scans it — but the phone still needs no address, and the *extension* still needs the phone's IP | Doesn't solve it; extension is the client |
| Relay-mediated | Both ends register with the VPS from `server_side_play_entitlement_plan.md` | Defer to P3, same as desktop plan |
| Hand off to the desktop app | Extension → loopback native messaging → desktop companion → LAN/QR → phone | **Best long-term.** Extension stops needing pairing at all |

The last row is the composite endgame: once `desktop_companion_plan.md` P2 exists, the extension talks to it over native messaging on `127.0.0.1` and the desktop app owns pairing. Until then, paste-once.

---

## 6. Phased delivery

| Phase | Work | Outcome |
|---|---|---|
| **E0** | Fix `_handleEnqueue` save paths (§4.2); route enqueue through `RestrictedMediaPolicy` (§4.3) | Existing automation API is actually usable and compliant |
| **E1** | LAN rebind + paste-once pairing string in settings — **shared with desktop P1** | `curl` from a laptop can enqueue to the phone |
| **E2** | MV3 extension: observational detection, badge count, popup list, "Send to Aurora" | Working end-to-end on Chrome/Edge |
| **E3** | Context forwarding (Referer/UA/cookies) with the §7 consent gate | Protected-host URLs actually download |
| **E4** | Firefox build (MV2-compatible manifest), status polling so the popup shows progress | Cross-browser + feedback loop |
| **E5** | Native-messaging handoff to the desktop companion, retiring paste-once | Zero-config pairing |

**Effort:** E0–E2 roughly 1.5–2 weeks. E3–E4 another week. E5 only after desktop P2.

---

## 7. Security rules (non-negotiable)

1. **LAN bind only** — the specific LAN IPv4, never `0.0.0.0`. Copy `lan_file_server.dart`.
2. **Off by default**, Ultra-gated, matching the existing `automationApi` gate.
3. **Cookie forwarding is opt-in per-send, never automatic.** An extension with `host_permissions` plus blanket cookie forwarding is a credential exfiltration channel onto the LAN. Default off; show exactly which host's cookies are being sent; never persist them on the phone beyond task lifetime.
4. **Never log** URLs, cookies, or tokens — `PlayPurchase.toString()` in `license_api_client.dart:30` is the precedent to follow.
5. **Token rotation + revoke-on-unpair** from phone settings.
6. Extension requests the **narrowest** permissions that work: `webRequest`, `storage`, `activeTab`, and `host_permissions` scoped to `http://*/*` for the LAN POST — not `<all_urls>` if avoidable.

---

## 8. Open choices (owner)

1. Extension in this GPL repo, or separate (the desktop plan leaned separate to keep control-plane code out of the public tree)?
2. Ultra-gate the extension, or make it free to drive adoption and gate only the desktop app?
3. Ship Firefox at E4 or defer — Firefox still allows blocking `webRequest`, so it could do strictly more, at the cost of a divergent codepath.

**Defaults if unanswered:** same repo (the extension carries no engine secrets worth hiding); Ultra-gated for consistency with `automationApi`; Firefox at E4 with feature parity only, no MV2-exclusive behaviour.

---

*End of plan.*

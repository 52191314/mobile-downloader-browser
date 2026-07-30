# Desktop Companion — Implementation Plan

| Field | Value |
|-------|-------|
| **Date** | 2026-07-24 |
| **Status** | Plan only (not implemented) |
| **Goal** | Give Ultra buyers a real desktop companion (Windows/macOS/Linux) that can view and control the phone's download queue, first over LAN, later remotely — a feature that's hard to clone by reading `lib/premium/` alone, unlike most gated code. |
| **Out of scope** | This doc | File transfer (already solved by `LanFileServer`) · mobile-to-mobile pairing · non-Ultra tiers |
| **Related** | `lib/premium/automation/automation_api_service.dart` (existing loopback-only REST API to extend) · `lib/premium/lan_file_server.dart` (hardening pattern to copy) · `docs/server_side_play_entitlement_plan.md` (P3 here can share its VPS) |

---

## 1. What already exists (reuse, don't rebuild)

| Piece | File | Reusable as |
|---|---|---|
| Ultra-gated REST API: status/tasks/pause/resume/cancel, Bearer token auth | `automation_api_service.dart` | The entire control-plane contract — currently bound to `127.0.0.1`, useless from another device |
| LAN-only bind, single-use tokens, absolute TTL, per-IP rate limit | `lan_file_server.dart` | Exact security pattern to copy for the LAN control-plane |
| `DownloadQueue` model | `downloader/download_queue.dart` | Data source for both |

**Conclusion:** this is primarily a wiring + pairing-UX problem, not a from-scratch build. The hard security precedent (LAN-only bind, TTL tokens, rate limits) is already shipped and audited in `lan_file_server.dart` — copy it rather than reinventing.

---

## 2. Product rules (lock these first)

| Decision | Recommendation |
|---|---|
| Gate | Ultra only — matches existing automation API tier, no new tier needed |
| Default state | Off. User must explicitly enable "Desktop Companion" in settings, same pattern as automation API |
| v1 scope | LAN-only. No remote reach, no new hosting cost |
| Pairing | QR code shown on phone, scanned by desktop app — no manually copying a token by hand |
| What the desktop app can do | View queue, add URL, pause/resume/cancel. **Not** file transfer — `LanFileServer` already owns that job |

---

## 3. Architecture (v1 — LAN only)

```text
┌────────────┐   QR pairing (one-time token)   ┌──────────────────┐
│ Phone app  │ ───────────────────────────────► │ Desktop companion │
│ (Ultra)    │                                  │ (Win/macOS/Linux) │
└─────┬──────┘                                  └─────────┬─────────┘
      │ LAN-bound HTTP, same hardening as LanFileServer    │
      │ GET /v1/status  GET/POST /v1/tasks  POST /v1/tasks/:id/{pause,resume,cancel}
      └─────────────────────────────────────────────────────┘
```

This is the existing `automation_api_service.dart` API surface, rebound from loopback to the LAN IPv4 address (opt-in, mirroring how `LanFileServer` already binds LAN-only rather than `0.0.0.0`), plus QR pairing instead of manual token copy-paste.

---

## 4. Phased delivery

| Phase | Work | Outcome |
|---|---|---|
| **P0 — Design freeze** | Confirm LAN-only v1 (no remote reach yet), Ultra gate, QR pairing UX | Written AC |
| **P1 — LAN control-plane** | New sibling to `LanFileServer`: bind the automation API's endpoint set to the LAN IPv4 address (opt-in toggle, default off), QR-code pairing token exchange instead of manual copy | Phone shows QR; a `curl` from another device on the LAN can authenticate and hit `/v1/status` |
| **P2 — Desktop companion app** | `flutter build windows/macos/linux` — new lightweight app in the same repo/monorepo. Queue view, add-URL box, pause/resume/cancel buttons. Read + control only, no file browsing | Installable desktop build, pairs with phone over LAN, controls the real queue |
| **P3 — Remote reach** | Only after the entitlement-server VPS (see `server_side_play_entitlement_plan.md`) is live and proven — add a thin WebSocket relay on the **same** box so phone and desktop can pair over the internet without port forwarding | Add-from-anywhere without LAN adjacency |
| **P4 — Hardening** | Pairing-token expiry, revoke-on-unpair, rate limits matching `LanFileServer`'s numbers, no queue contents in logs | Production-ready |

**Effort:** P1–P2 (LAN-only, zero new hosting) — roughly 2–3 weeks. The API surface and the security pattern both already exist in the codebase; this is wiring plus a new desktop UI, not new infrastructure. P3 is materially more expensive and should wait until the entitlement-server VPS exists, since it can share that box instead of standing up separate hosting.

---

## 5. Open choices (owner)

1. Single combined desktop app, or separate builds per OS with shared Dart core?
2. Should P2 ship inside the existing Aurora repo/CI, or a separate repo (relevant if the desktop app should stay closed-source while the mobile core is GPL)?
3. QR pairing: re-pairable indefinitely, or does pairing expire and require re-scan periodically for security hygiene?

**Defaults if unanswered:** single Flutter desktop target with shared Dart core; separate repo (keeps the companion's control-plane code out of the public GPL tree, consistent with the earlier license/piracy discussion); pairing valid until explicitly revoked from phone settings.

---

*End of plan.*

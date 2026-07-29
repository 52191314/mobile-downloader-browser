# Server-Side Play Entitlement — Implementation Plan

| Field | Value |
|-------|-------|
| **Date** | 2026-07-20 (reviewed 2026-07-24) |
| **Status** | **P1–P3 implemented** 2026-07-25. Server: [`license_server/`](../license_server/README.md) (Node 24 · Express 5 · TypeScript ESM; 31 tests). Client: `lib/premium/license/` (RS256 verify, offline grace, refresh, refund handling; 35 tests). **Not yet active in any build** — needs `AURORA_LICENSE_URL` + a trusted key, and a real Play test purchase end-to-end. P4/P5 open. Reviewed 2026-07-24 — architecture is sound. Five gaps (§15) must close before **P2/P3** (gating real users on it). GCP/Android Publisher API setup is **not blocked** — confirmed 2026-07-24 that the unrelated GCP account currently in dispute resolution is a different Google account entirely from the one tied to this app's Play Console listing. |
| **Goal** | Make the **Play** build’s Pro/Ultra unlock depend on a **verified purchase** (Google Play Developer API), not only local `pro_entitlement.json` / client honor |
| **Out of scope** | Implementing code in this doc · non-Play GitHub monetization · full DRM against patched APKs |
| **Related** | `docs/SECURITY_AUDIT.md` · `docs/ultra_full_feature_pack_plan.md` |

---

## 1. What “server-side” buys you

| Abuse | Without server | With server |
|--------|----------------|-------------|
| Edit `pro_entitlement.json` | Works (esp. offline) | Offline only until license expires / next check |
| Fake purchase stream | Often works | Token must verify at Google |
| Official APK + no real pay | Easy | Hard |
| Fully patched APK (skip all checks) | Easy | Still possible (client always crackable) |

**Outcome:** stop casual / “edit file” / fake IAP on the **stock Play app**. Not “unhackable.”

---

## 2. Product rules (lock these first)

| Decision | Recommendation |
|----------|----------------|
| Who uses the server? | **Play channel only** (`AURORA_BUILD_CHANNEL=play`) |
| GitHub / sideload builds | Stay free / cache / debug — **no** license server required |
| Offline paid use | Allowed for **N days** after last successful verify (default **7–14 days**) |
| Products | `aurora_pro_unlock` → pro; `aurora_ultra_unlock` / `aurora_ultra_upgrade` → ultra |
| Privacy | Purchase token + optional install id only; no browsing history |
| Hosting | Small always-on service (see §6) — **laptop 24/7 is possible but weak for prod** |

---

## 3. Architecture

```text
┌─────────────┐     buyNonConsumable      ┌──────────────┐
│  Play app   │ ─────────────────────────►│ Google Play  │
└──────┬──────┘                           └──────▲───────┘
       │ purchaseToken, productId, packageName    │
       │                                          │
       │  HTTPS POST /v1/license/activate         │ purchases.products.get
       ▼                                          │
┌──────────────────┐   service account JWT  ┌─────┴────────┐
│ License service  │ ──────────────────────►│ Android      │
│ (your VPS)       │                        │ Publisher API│
└────────┬─────────┘                        └──────────────┘
         │
         │ signed license blob (JWT)
         │ { tier, exp, install_id, jti }
         ▼
┌──────────────────┐
│ App stores blob  │  gates check blob (not raw tier JSON alone)
│ + offline until  │
│ exp              │
└──────────────────┘
```

**Periodic recheck:** app on resume / every 24h if online → `POST /v1/license/refresh` with install id + last token or refresh grant.

**Refund:** next Google query says not owned → server revokes → app gets free on next refresh (or 401 → clear local license).

---

## 4. API surface (minimal)

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/v1/license/activate` | Body: `{ purchaseToken, productId, packageName, installId }` → verify at Google → issue JWT |
| `POST` | `/v1/license/refresh` | Body: `{ installId, refreshProof? }` or re-send tokens from local Play query → new JWT |
| `GET` | `/v1/health` | Uptime check |

**Auth to your server:** optional API key in app (obfuscated) is **not** security; real security is **Google verifying the purchaseToken**.

**Response (success):**

```json
{
  "license": "<JWT>",
  "tier": "ultra",
  "expiresAt": "2026-08-03T12:00:00Z"
}
```

**JWT claims (example):** `sub=installId`, `tier`, `exp`, `iss=aurora-license`, `products=[...]`.  
Sign with **server private key** (Ed25519 or RS256). App embeds **public** key only.

---

## 5. App-side changes (plan)

| Piece | Change |
|-------|--------|
| After Play purchase / restore | Call `activate` with token(s) from BillingClient |
| Cold start | Load license JWT; if valid + not expired → tier; if online → refresh |
| Gate source of truth | `tier = max(debugOverride, license.tier, free)` — **not** raw store `tier` alone |
| Offline | Allow last good license until `exp` |
| Expired + offline | Free (or soft-nag “connect to verify”) |
| Non-Play channel | Skip license server; keep current free/debug behavior |
| Local JSON | Cache license + last reconcile metadata; treat as untrusted without valid JWT |

**Debug builds:** keep Free/Pro/Ultra force (never hits production license, or hits staging).

---

## 6. Hosting options

### A. Free/cheap cloud VPS (recommended for production)

| Provider | Notes |
|----------|--------|
| **Oracle Cloud Free Tier** | Ampere VM free forever (quota/region dependent); good if you can get an account |
| **AWS free tier / Lightsail** | 12 mo free or ~$3–5/mo small instance |
| **Fly.io / Railway / Render** | Easy deploy; free tiers limited; fine for low QPS |
| **Cloudflare Workers + D1/KV** | Very cheap; verify call from Worker to Google still needs secrets |

**Workload:** tiny — a few KB JSON, Google API call per activate/refresh. **One shared core / 512MB–1GB is plenty.** Thousands of users still trivial.

**Needs:**

- Always-on HTTPS (Caddy/nginx + Let’s Encrypt, or platform TLS)
- Secrets: Google service account JSON, JWT signing key
- Optional SQLite/Postgres: map `purchaseToken` → tier, revoke list

### B. Laptop 24/7 (possible, not recommended as primary production)

| Pros | Cons |
|------|------|
| $0 hardware if already on | Home IP changes, power, sleep, ISP CGNAT |
| Fine for **dev/staging** | Port forward / Cloudflare Tunnel required |
| Low CPU/RAM | Laptop theft, OS updates reboot, uptime ≈ “when home” |

**If you use a laptop anyway:**

1. Run service in Docker.  
2. Expose via **Cloudflare Tunnel** (no open router ports).  
3. Treat as **staging** or **temporary prod** until a free VPS works.  
4. Do **not** put production Google service account only on a flaky laptop without backup.

**Resource use:** idle ~50–150 MB RAM, near-zero CPU. Laptop is fine resource-wise; **reliability** is the issue.

### C. Hybrid

- **Prod:** Oracle/AWS free VPS (or cheap Lightsail)  
- **Dev:** laptop + Cloudflare Tunnel  
- Same API contract; different base URL via dart-define `AURORA_LICENSE_URL`

---

## 7. Google Cloud / Play Console setup (checklist)

1. Google Cloud project linked to Play Console.  
2. Enable **Google Play Android Developer API**.  
3. Service account with access to the app in Play Console → **API access**.  
4. Use [purchases.products.get](https://developers.google.com/android-publisher/api-ref/rest/v3/purchases.products/get) for one-time products (`packageName`, `productId`, `token`).  
5. Confirm purchase state = purchased; map productId → tier.  
6. Store `purchaseToken` server-side to detect reuse/refunds on refresh.  
7. App package name must match Play listing exactly.

---

## 8. Phased delivery

| Phase | Work | Outcome |
|-------|------|---------|
| **P0 — Design freeze** | Products, grace days, non-Play behavior, privacy blurb | Written AC |
| ~~**P1 — Server MVP**~~ ✅ | `/activate`, `/refresh`, `/health`, `/ready`, JWKS, Google verify, RS256 JWT issue, SQLite store, rate limiting, token redaction | Built in `license_server/`. Verified against the stub verifier end-to-end; **still needs a curl test with a real Play test purchase** once the service account is provisioned |
| ~~**P2 — App Play path**~~ ✅ | Activate after buy/restore; gate on JWT; offline grace; migration backfill | Built in `lib/premium/license/`. Gate is `ProEntitlement.tier`, now fed by the license; `storeTier` keeps purchase UX working. **Still needs the device test:** buy → kill app → still Pro offline within grace |
| ~~**P3 — Refresh + refund**~~ ✅ | Resume refresh (24h throttle, 30min retry backoff); revoked → free | `refreshIfDue()` on `AppLifecycleState.resumed`. **Still needs the device test:** refund test account drops tier online |
| **P4 — Hardening** | Rate limit, logging (no full tokens in logs), backup keys, uptime monitor | Production-ready |
| **P5 — Optional** | Play Integrity token checked **on server** when issuing license | Extra friction for modified devices |

**Rough effort:** 1–2 weeks part-time for P1–P3 if focused; less if API is tiny (Go/Node/Python FastAPI).

---

## 9. Security requirements for the service

| Requirement | Why |
|-------------|-----|
| HTTPS only | Tokens in transit |
| Never log full `purchaseToken` | Leak = abuse |
| Rate limit per IP / installId | Spam Google API |
| Validate `packageName` allowlist | Stop other apps hitting you |
| Validate `productId` ∈ { three SKUs } | |
| Secrets outside git | Service account JSON |
| Backup signing key offline | Lose key = reissue all licenses |
| Health + simple uptime ping | Know when laptop/VPS dies |

**Not required day one:** multi-region HA, Kubernetes, etc.

---

## 10. Privacy / Play listing

- Update privacy policy: purchase tokens / install id sent to **your** license host for verification.  
- No need for browse history.  
- Data safety form: “App activity / purchases” as applicable.  
- Prefer host you control (`license.yourdomain.com`) not raw IP long-term.

---

## 11. Failure modes (product)

| Event | Behavior |
|-------|----------|
| Server down, license still valid | App works until `exp` |
| Server down, license expired | Free + “Can’t verify purchase” (don’t brick forever without message) |
| User refunds | Next refresh → free |
| User clears app data | Restore purchases → Play tokens → activate again |
| Attacker patches app | Still free Ultra; accept residual risk |

---

## 12. Recommendation

1. **Plan for a free/cheap VPS (Oracle Free / small Lightsail) as production.**  
2. **Laptop + Cloudflare Tunnel only for development or interim**, not long-term sole prod.  
3. Ship **P1–P3**: verify purchaseToken → signed JWT → offline grace 7–14 days.  
4. Keep **GitHub builds offline/free** so open-source story stays clean.  
5. Do **not** expect this to stop dedicated cracked APKs; expect it to stop **cache forge and fake IAP on the official Play binary**.

---

## 13. Open choices (owner)

1. **Offline grace:** 7 vs 14 vs 30 days?  
2. **Host:** try Oracle free first vs pay ~$3–5 Lightsail for less friction?  
3. **Domain:** have a domain for TLS name?  
4. **GitHub APK:** always free, or same server later?  
5. **Integrity API:** skip for v1 or include in P5?

**Defaults if unanswered:** 14-day grace, Oracle free or cheapest stable VPS, staging on laptop+tunnel, GitHub free-only, Integrity later.

---

## 14. Also useful without a server (interim)

Even before the VPS:

1. On load: re-derive tier from `ownedProductIds` where possible.  
2. Play: reconcile on cold start + resume when online.  
3. Limited offline grace tied to last successful BC reconcile.

These shrink JSON forge while the license service is built.

---

## 15. Review findings (2026-07-24) — close before P2/P3

Architecture reviewed against the codebase and current launch state. Cleared to start P1 as written. These five gaps should close before gating real users on it (P2 onward), since they're the ones that generate support tickets and refund requests, not the ones that generate security incidents:

| Gap | Why it matters | Fix |
|---|---|---|
| **Multi-device / reinstall not addressed** | JWT is keyed on `sub=installId`. A user who buys Ultra then gets a new phone, or reinstalls, gets a new installId and the old JWT is meaningless. | `/activate` must re-verify the same `purchaseToken` against a *new* installId and reissue, driven by `restorePurchases()` — not just the first-purchase flow. Add as an explicit P2 acceptance criterion. |
| **Upgrade SKU combination logic undefined** | `aurora_ultra_upgrade` only makes sense combined with an existing `aurora_pro_unlock`. The doc's productId → tier table treats each SKU independently. | Compute entitlement from the *set* of all purchases Google returns for that account (via `purchases.products.get` per owned productId), not from the single token being activated. |
| **No key-rotation / compromise recovery** | "Backup signing key offline" is mentioned, but there's no procedure if the JWT signing key leaks — rotating it naively invalidates every legitimate offline license instantly. | Add a `kid` (key id) to the JWT header; client accepts 2 valid public keys at once so a rotation has a grace overlap instead of bricking paying users. |
| **No migration path for pre-existing buyers** | Launching in a week without this. When the server ships later, existing Pro/Ultra buyers on the current local-JSON check will hit "not verified" on update unless handled. | Add explicit P2 step: silent one-time `restorePurchases()` → `/activate` backfill on first launch after the update that introduces this system. |
| **Oracle Free Tier reliability vs. grace window** | Oracle's Ampere free tier has a known history of surprise capacity reclamation. Recommendation §12 pairs it with only a 7–14 day grace window — if the instance is reclaimed and it takes a while to notice, paying users lose Ultra mid-grace. | Either pick a paid $3–5/mo box (Lightsail/Fly) as primary from day one, or bias the grace window to 30 days until uptime is proven over a full billing cycle. |

**Status of these five after P1–P3 (2026-07-25): all closed in code.**

| Gap | State |
|---|---|
| Multi-device / reinstall | **Closed.** Server: `install_purchases` is many-to-many, so re-activating a token under a new `installId` reissues rather than failing. Client: `restorePurchases()` → `reconcileEntitlements` sends the full snapshot to `/activate`. |
| Upgrade SKU combination | **Closed.** Entitlement is the union of every purchase linked to the install, never the single token being activated. `/activate` takes a full `purchases[]` snapshot from `queryPurchases`. |
| Key rotation | **Closed.** JWTs carry `kid`; the server signs with `LICENSE_ACTIVE_KID` while publishing every key on the ring, and `LicenseConfig._bakedKeys` holds a list so the client trusts two keys at once. Rotation order (client update first) is documented in `license_server/README.md` §5. |
| Migration for pre-existing buyers | **Closed.** First launch after the update opens a `legacyGraceUntil` window (default 14 days) for an install that already owned Pro/Ultra; cold-start reconcile backfills a real license, which closes the window. |
| Host reliability vs grace | **Mitigated by default:** `LICENSE_TTL_DAYS` defaults to **30** and *is* the offline grace window. Host choice is still an owner decision. |

**Client behaviour worth knowing before enabling this:**

| Situation | Result |
|---|---|
| Licensing not configured (no URL / no key / GitHub build) | Gating off entirely — pre-existing behaviour, bit for bit |
| Valid cached license, offline | Works until `exp`, no network needed on cold start |
| Host down, license still valid | Works; refresh retries every 30 min |
| Host down, license expired | Free **with an explanation** in Settings, not a silent downgrade |
| Refund | Next refresh returns `entitlement_revoked` → license cleared → free |
| Hand-edited `pro_entitlement.json` | Grants nothing; the tier gate reads the signed license, not the file |
| Debug "Force Pro" | Still wins, debug/profile builds only |

**GCP status (confirmed 2026-07-24):** the GCP account currently in dispute resolution is unrelated to Aurora — different Google account than the one tied to Play Console. Android Publisher API / service-account setup for P1 can proceed on a fresh or existing GCP project without waiting on that dispute.

---

*End of plan.*

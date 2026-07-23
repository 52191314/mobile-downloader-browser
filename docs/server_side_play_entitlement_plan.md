# Server-Side Play Entitlement — Implementation Plan

| Field | Value |
|-------|-------|
| **Date** | 2026-07-20 |
| **Status** | Plan only (not implemented) |
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
| **P1 — Server MVP** | `/activate`, `/health`, Google verify, JWT issue, SQLite store | curl-tested with real test purchase |
| **P2 — App Play path** | Activate after buy/restore; gate on JWT; offline grace | License tester: buy → kill app → still pro offline within grace |
| **P3 — Refresh + refund** | Resume refresh; revoked purchase → free | Refund test account drops tier online |
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

*End of plan.*

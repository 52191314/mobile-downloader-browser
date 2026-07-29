# Aurora License Server

Verifies Google Play purchases server-side and issues short-lived, RS256-signed
license blobs the app can check offline.

This is **P1** of `docs/server_side_play_entitlement_plan.md`. It is the server
half only — the Flutter client changes (P2/P3) are not part of this directory.

| | |
|---|---|
| **Runtime** | Node.js **≥ 24** (uses the built-in `node:sqlite`; no native build step) |
| **Stack** | Express 5 · TypeScript ESM · googleapis · jsonwebtoken · zod |
| **Applies to** | `AURORA_BUILD_CHANNEL=play` builds only — GitHub/F-Droid builds never call this |
| **Storage** | One SQLite file. No external database. |

---

## 1. Quick start (local, no Google account needed)

```bash
cd license_server
npm install
npm run keys:generate          # writes keys/<kid>.key.pem + <kid>.pub.pem
cp .env.example .env           # then set LICENSE_ACTIVE_KID + PLAY_VERIFY_MODE=fake
npm run dev
```

With `PLAY_VERIFY_MODE=fake` no Google credentials are required and every token
verifies as purchased, except tokens prefixed `canceled:`, `pending:` or
`invalid:`. **Config refuses to start in `fake` mode when `NODE_ENV=production`.**

```bash
curl -s localhost:8080/v1/health

curl -s localhost:8080/v1/license/activate \
  -H 'content-type: application/json' \
  -d '{"packageName":"com.personal.aurora_downloader",
       "installId":"dev-install-0001",
       "productId":"aurora_pro_unlock",
       "purchaseToken":"dev-token-000001"}'
```

---

## 2. API

### `GET /v1/health`

Cheap liveness probe for an uptime monitor. Touches nothing.

```json
{ "status": "ok", "uptimeSeconds": 1234, "time": "2026-07-25T12:00:00.000Z" }
```

### `GET /v1/ready`

Deeper check — proves SQLite is readable and a signing key is loaded.
Returns `503` when storage is unavailable.

### `GET /v1/.well-known/jwks.json`

Public verification keys. **The app must not fetch this at runtime** — it ships
its public keys compiled in, otherwise anyone who can MITM the app also controls
what signs its licenses. The endpoint exists for tooling and rotation checks.

### `POST /v1/license/activate`

Two accepted body shapes:

```jsonc
// Single purchase (the plan's original shape)
{
  "packageName": "com.personal.aurora_downloader",
  "installId":   "<client UUID>",
  "productId":   "aurora_ultra_unlock",
  "purchaseToken": "<token from BillingClient>"
}

// PREFERRED: full ownership snapshot from BillingClient.queryPurchases()
{
  "packageName": "com.personal.aurora_downloader",
  "installId":   "<client UUID>",
  "purchases": [
    { "productId": "aurora_pro_unlock",     "purchaseToken": "..." },
    { "productId": "aurora_ultra_upgrade",  "purchaseToken": "..." }
  ]
}
```

Success (`200`):

```json
{
  "license": "<JWT>",
  "tier": "ultra",
  "products": ["aurora_pro_unlock", "aurora_ultra_upgrade"],
  "keyId": "aurora-20260725",
  "issuedAt": "2026-07-25T12:00:00.000Z",
  "expiresAt": "2026-08-24T12:00:00.000Z"
}
```

### `POST /v1/license/refresh`

```json
{ "packageName": "com.personal.aurora_downloader", "installId": "...", "purchases": [] }
```

`purchases` is optional. When omitted, every token already linked to that
install is re-verified against Google — this is what catches refunds. Returns
`404 unknown_install` when the server has never seen the install, so the client
knows to call `/activate` instead.

### Error codes

The `error` field is a stable machine string; branch on it, not on `message`.

| Status | `error` | Client should |
|---|---|---|
| 400 | `invalid_request` | Fix the payload — this is a bug, not a user state |
| 400 | `invalid_json` | Same |
| 400 | `unknown_product` | Same (productId isn't an Aurora SKU) |
| 403 | `package_not_allowed` | Same (wrong host or wrong build) |
| 403 | `no_valid_purchase` | Drop to free — nothing is owned |
| 403 | `entitlement_revoked` | Clear the stored license, drop to free (refund) |
| 404 | `unknown_install` | Call `/activate` with a fresh BillingClient snapshot |
| 429 | `rate_limited` | Back off; keep using the cached license |
| 502 | `upstream_unavailable` | **Keep the cached license** — Google is unreachable, not the user's fault |
| 500 | `internal_error` | Same as 502 |

> A `502`/`500` must never downgrade a paying user. Only `403` and a genuinely
> expired license do.

---

## 3. The license JWT

Header carries `kid`; the algorithm is always RS256.

```json
{
  "iss": "aurora-license",
  "aud": "aurora-app",
  "sub": "<installId>",
  "tier": "ultra",
  "products": ["aurora_pro_unlock", "aurora_ultra_upgrade"],
  "pkg": "com.personal.aurora_downloader",
  "jti": "<uuid>",
  "iat": 1785000000,
  "exp": 1787592000
}
```

**The client must check all of:** signature against a known `kid`, `iss`, `aud`,
`sub == its own installId`, and `exp`. Only then may it trust `tier`. Skipping
the `sub` check would let one user's license file unlock any device.

Tier is derived from `products` exactly as `lib/premium/pro_entitlement.dart`
does — `src/entitlement.ts` is a deliberate mirror of it. **Changing tier
mapping on one side requires the same change on the other**, or the UI and the
license will disagree.

---

## 4. Google Play setup (production)

1. Google Cloud project linked to the Play Console account.
2. Enable **Google Play Android Developer API** in that project.
3. Create a service account; download the JSON key.
4. Play Console → *Users and permissions* → invite the service account email,
   grant **View financial data, orders, and cancellation survey responses** on
   the app. (Permission propagation can take a few hours — a fresh grant that
   returns 401 usually just needs waiting.)
5. Put the JSON somewhere outside git and point
   `GOOGLE_SERVICE_ACCOUNT_JSON_PATH` at it, or inline it as
   `GOOGLE_SERVICE_ACCOUNT_JSON`.
6. Set `PLAY_VERIFY_MODE=google` and `ALLOWED_PACKAGE_NAMES` to the exact
   `applicationId` from `android/app/build.gradle.kts`.

Verification uses [`purchases.products.get`][ppg] and treats **only**
`purchaseState === 0` as owned — a *pending* purchase does not entitle.

[ppg]: https://developers.google.com/android-publisher/api-ref/rest/v3/purchases.products/get

---

## 5. Key management and rotation

```bash
npm run keys:generate                    # first key
npm run keys:generate -- --kid aurora-2  # rotation: adds a SECOND key
```

The script refuses to overwrite an existing key. Every keypair in
`LICENSE_KEY_DIR` is published in JWKS; only `LICENSE_ACTIVE_KID` signs.

Rotating without bricking paying users (plan §15 gap 3):

1. Generate a second keypair; leave the old one in place.
2. Ship an app update that trusts **both** public keys.
3. Once that update is broadly adopted, point `LICENSE_ACTIVE_KID` at the new
   key and restart.
4. Keep the old public key trusted for at least `LICENSE_TTL_DAYS` — offline
   licenses signed by it are still valid until they expire.
5. Only then remove the old key from the ring and from the app.

**Back up the private key offline.** Losing it means every issued license must
be reissued and every client updated.

---

## 6. Protecting the database

`DB_PATH` holds **raw purchase tokens** — refresh has to re-ask Google whether a
purchase still stands, which requires the original token. Treat the file as
secret material:

- Restrict permissions; don't put it on a shared volume.
- Back it up encrypted. Losing it is recoverable (clients re-activate from
  BillingClient), leaking it is not.
- Purchase tokens never reach logs: `logger.ts` exposes `tokenFingerprint()`
  (first 12 hex of SHA-256) and that is the only form ever logged.

---

## 7. Deployment

```bash
docker compose up -d --build
```

Compose binds to `127.0.0.1:8080` on purpose — terminate TLS in front of it
(Caddy, nginx + Let's Encrypt, or a Cloudflare Tunnel). The service speaks plain
HTTP and expects a proxy; set `TRUST_PROXY` to the number of proxies in front of
it or per-IP rate limiting will key every request to the proxy's address.

Host choice (plan §15 gap 5): a paid $3–5/mo box is the recommended primary.
If you run on a free tier with reclamation risk, keep `LICENSE_TTL_DAYS=30` so a
surprise outage doesn't cost paying users their Ultra mid-grace. `LICENSE_TTL_DAYS`
**is** the offline grace window — the app works without contact until `exp`.

---

## 8. What this does and doesn't stop

Stops: editing `pro_entitlement.json`, replaying a fake purchase stream, and
using the official Play binary without paying.

Does not stop: a patched APK that skips the check entirely. That is accepted
residual risk — see plan §1 and §11.

---

## 9. Tests

```bash
npm test         # 31 tests, no network, in-memory SQLite
npm run typecheck
```

Coverage includes the tier mirror, the reinstall/new-device path, the
Pro + Ultra-upgrade union, refund revocation on refresh, package/product
allowlisting, and JWKS never leaking private key material.

## 10. The client half

Implemented in `lib/premium/license/` (P2/P3). Enable it with
`--dart-define=AURORA_LICENSE_URL=...` plus a trusted key — see
`docs/build_channels_and_defines.md`. **Without those defines the app ignores
this server entirely**, so deploying the two halves is not a lockstep operation.

Cross-stack test fixtures are generated from this server's own issuer:

```bash
npm run build && node scripts/generate-test-fixtures.mjs
cd .. && flutter test test/premium/license
```

That regenerates `test/premium/license/license_fixtures.dart` with real signed
licenses (valid, expired, wrong-install, wrong-issuer, forged, tampered,
alg:none) so the Dart verifier is checked against genuine server output rather
than a Dart-side restatement of the same assumptions.

## 11. Not yet done (P4/P5)

- A real end-to-end run against a Play **test purchase** — everything so far is
  verified against the stub verifier.
- Rate-limit tuning, uptime monitoring, key backup drill (P4).
- Play Integrity token checked at issue time (P5).

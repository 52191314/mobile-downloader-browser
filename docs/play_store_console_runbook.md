# Play Console runbook — closed testing → production

**Current phase (2026-07-28):** app is live on a **closed testing** track as
*Aurora: Browser & Downloader* (Ahjie521), v2.4.5 / versionCode 29, 0+ installs,
listing last updated 2026-07-23.

Days 0–3 of the original first-publish runbook are complete — account, app
creation, App content forms, and the first upload all happened. This doc now
covers getting from closed testing to production. Live-state facts and known
drift live in [`play_store_listing.md`](./play_store_listing.md#live-listing-state--verified-2026-07-28).

---

## Gate 1 — what only closed testing can prove

**Verify all three IAP products.** This is the single highest-value thing this
track does and it cannot be tested any other way. IDs must match
`lib/premium/pro_entitlement.dart:20-22` exactly:

| Product ID | Tier |
|---|---|
| `aurora_pro_unlock` | Pro |
| `aurora_ultra_unlock` | Ultra |
| `aurora_ultra_upgrade` | Pro → Ultra step-up |

For each: product **active** in Console, price loads in-app, purchase completes
with a license-tester account, and restore works after a reinstall. If only
`aurora_pro_unlock` is active, every Ultra surface — FFmpeg suite, watcher,
automation API, vault sync, 64/64 engine — is unpurchasable, and the store
description now advertises them.

**Ship the hardened build.** The live artifact predates all four HIGH fixes from
[`play_review_audit_2026-07-27.md`](./play_review_audit_2026-07-27.md): pinned
`targetSdk 36`, battery-prompt removal, `bridge_url_guard.dart`, and
`allowFileAccess`/`allowContentAccess` false. Bump `versionCode` in
`android/local.properties`, then:

```powershell
flutter build appbundle --release --dart-define=AURORA_BUILD_CHANNEL=play
```

Pushing a new build does **not** reset the 14-day tester clock — that tracks
continuous tester opt-in, not build recency. Same for editing the store listing.

**Regression checks on device:**

- Settings → Aurora Pro → price loads for all three products
- Purchase + restore with a license tester
- Visit youtube.com → capture disabled, no media cards
- Paste a `youtu.be` / `googlevideo.com` URL into queue → blocked message
- A download survives app kill and resumes
- Long download on Android 15/16 — `dataSync` FGS is capped ~6h/24h (audit §10)

---

## Gate 2 — before requesting production access

- [ ] **Target audience** confirmed 18+ in Policy → App content *(unverified — see audit §0.3)*
- [ ] Screenshots reshot against the shipped build — see [`play_store_listing.md`](./play_store_listing.md) §Screenshots and `tools/make_store_screenshots.py`
- [ ] Final description pasted with **no markdown** (`~~`, `**`, `|`, `#` all render literally)
- [ ] Privacy policy URL live and verified in incognito; `YOUR_EMAIL` placeholders replaced
- [ ] Torrent-in-Play decision recorded (audit item 5)
- [ ] `AURORA_LICENSE_URL` state confirmed; Data Safety updated if set (audit item 8)
- [ ] Data safety form matches actual behaviour

**Timing:** a personal developer account needs 12 testers opted in for 14
continuous days before applying for production access, and the application
includes identity checks. Started 2026-07-23 → eligible around **2026-08-06**.

Confirm Play Console account recovery details are clean *before* submitting that
application rather than during it.

**Hard date:** Play raises the target-API floor for new apps to **API 36 on
2026-08-31**. The pinned `targetSdk 36` clears it, but only once shipped.

---

## Production

- Complete all **Policy** declarations
- Submit for review
- Monitor Policy status + crash vitals for 48h after go-live

Passing closed-testing review is not evidence the production review will pass —
the stale Drive-sync screenshot cleared one review already.

---

## GitHub / FOSS builds (separate)

```powershell
flutter build apk --release --dart-define=AURORA_BUILD_CHANNEL=github
```

- No Play Billing purchase path
- Pro stays free-tier unless debug override (debug builds only)
- Do not market the GitHub APK as the Play edition

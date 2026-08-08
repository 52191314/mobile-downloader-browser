# Build channels & compile-time defines

## Naming (not “flair”)

| Term | What it is | Aurora today |
|------|------------|--------------|
| **Flair** | Not a build term (often a misspelling of *flavor*) | — |
| **Product flavor** | Android Gradle `productFlavors { … }` — separate app variants (often different `applicationId`, resources, source sets) | **Not configured yet** in `android/app/build.gradle.kts` |
| **Build type** | `debug` / `release` / `profile` (minify, signing, etc.) | Standard Flutter/Android types |
| **Build channel** | Our name for the distribution edition of the binary | `github` (default) or `play` |
| **`--dart-define`** | Compile-time constant baked into Dart via `String.fromEnvironment` / `bool.fromEnvironment` | How the **build channel** and some secrets are set |

So: **`AURORA_BUILD_CHANNEL=play` is a dart-define that selects the Play *build channel*.**  
It is **not** an Android product flavor (yet). Calling it a “flavor” is informal but common; “**channel**” is the name used in code (`BuildChannel`).

If we later add real Gradle `productFlavors` (`play` / `github`), they should wire the same defines automatically so one command still produces the right edition.

---

## Active dart-defines

### `AURORA_BUILD_CHANNEL`

| Value | Default? | Purpose |
|-------|----------|---------|
| `github` | **Yes** (if unset) | Open-source / sideload / GitHub releases. Full sniffer (incl. YouTube). **No** Play Billing purchase path. **Release** builds default the entitlement tier to **Ultra** (everything unlocked) — debug/profile keep free-tier caps so the freemium UX stays testable. |
| `play` | No | Google Play edition. YouTube media sniff/download **blocked**. Play Billing for Aurora Pro. No external checkout links. |

**Code:** `lib/premium/build_channel.dart`  
**Consumers:**

- `BuildChannel.isPlay` / `isGithub`
- `RestrictedMediaPolicy.enforcementEnabled` (YouTube gate)
- `PlayBillingService` (init / buy / restore)
- Settings + upsell CTAs

**Examples:**

```bash
# GitHub / daily driver (default)
flutter build apk --debug --target-platform android-arm64

# Explicit GitHub channel
flutter build apk --debug --target-platform android-arm64 \
  --dart-define=AURORA_BUILD_CHANNEL=github

# Play Store edition
flutter build apk --debug --target-platform android-arm64 \
  --dart-define=AURORA_BUILD_CHANNEL=play

# Play release AAB for Console upload
flutter build appbundle --release \
  --dart-define=AURORA_BUILD_CHANNEL=play
```

**Install (debug, do not uninstall existing app):**

```bash
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

---

> **Removed 2026-07-28:** `AURORA_GOOGLE_SERVER_CLIENT_ID` was documented here for
> Google Sign-In + Drive. Drive sync was deleted from the codebase on 2026-07-27
> (`play_review_audit_2026-07-27.md` §0.1) and the define has **zero references
> in `lib/`**. Do not pass it.

Multiple defines: pass `--dart-define=KEY=value` once per key.

---

### `AURORA_SCREENSHOT_MODE` / `AURORA_SCREENSHOT_SHOT`

| | |
|--|--|
| **Required for** | Play Store screenshot capture — seeds the **real** Queue UI with display-only tasks |
| **Default** | `false` / `queue` |
| **Code** | `lib/dev/screenshot_fixtures.dart` |
| **Build mode** | **`--profile` only** |

| Define | Values | Purpose |
|---|---|---|
| `AURORA_SCREENSHOT_MODE` | `true` / unset | Seeds six display-only download tasks + forces a tier |
| `AURORA_SCREENSHOT_SHOT` | `queue` (default) / `settings` | `queue` → Ultra tier, four concurrent downloads. `settings` → free tier so the `Pro` badges on Rules/Schedule actually render |

**This is not a channel.** `AURORA_BUILD_CHANNEL` stays `play` — you screenshot
the edition you ship. Adding a third channel value would be actively wrong:
`BuildChannel.isGithub => !isPlay` (`build_channel.dart:23`), so anything other
than `play` silently becomes `github`, disabling Play Billing and
`RestrictedMediaPolicy` enforcement.

**Profile, not release.** Both `ProEntitlement.setDebugTier`
(`pro_entitlement.dart:138`) and `DownloadQueue.seedDisplayOnlyTasks` are hard
no-ops when `kReleaseMode` is true, so a shipped build cannot be seeded even if
the define leaks into the build command. Profile also drops the debug banner and
runs at near-release speed. Note there is **no hot restart in profile** — the two
shot configurations are two separate `flutter run` invocations.

```powershell
# Shots 1, 2, 4, 6 — Ultra tier, seeded queue
flutter run --profile `
  --dart-define=AURORA_BUILD_CHANNEL=play `
  --dart-define=AURORA_SCREENSHOT_MODE=true `
  --dart-define=AURORA_ENABLE_ONBOARDING=false

# Shot 5 — free tier so Pro badges render
flutter run --profile `
  --dart-define=AURORA_BUILD_CHANNEL=play `
  --dart-define=AURORA_SCREENSHOT_MODE=true `
  --dart-define=AURORA_SCREENSHOT_SHOT=settings `
  --dart-define=AURORA_ENABLE_ONBOARDING=false
```

Capture recipe and the staged-vs-fabricated line: [`play_store_listing.md`](./play_store_listing.md).

---

### `AURORA_DISABLE_ULTRA_UI`

| | |
|--|--|
| **Purpose** | Hides Ultra purchase/upsell surfaces without removing the tier |
| **Default** | `false` |
| **Code** | `lib/premium/play_billing_service.dart:49` |

Useful when the `aurora_ultra_unlock` product is not yet Active in Play Console
and you do not want testers hitting a product-not-found path.

---

### `AURORA_LICENSE_*` — server-side entitlement

| | |
|--|--|
| **Required for** | Verifying Play purchases against the license host instead of trusting the local cache |
| **Default** | All empty → **licensing is off**, and the app behaves exactly as it did before this system existed |
| **Code** | `lib/premium/license/` (`LicenseConfig`) |
| **Server** | `license_server/` · plan: `docs/server_side_play_entitlement_plan.md` |

| Define | Purpose |
|--------|---------|
| `AURORA_LICENSE_URL` | Base URL of the license host, e.g. `https://aurora-license-server.fly.dev`. Empty disables licensing. |
| `AURORA_LICENSE_KID` / `_KEY_N` / `_KEY_E` | Inject one trusted RSA public key without editing source. `npm run keys:generate` prints these. |
| `AURORA_LICENSE_ISSUER` | Must match the server's `LICENSE_ISSUER` (default `aurora-license`). |
| `AURORA_LICENSE_AUDIENCE` | Must match the server's `LICENSE_AUDIENCE` (default `aurora-app`). |
| `AURORA_LICENSE_LEGACY_GRACE_DAYS` | Migration window for users who bought before licensing shipped (default 14). |
| `AURORA_PACKAGE_NAME` | Overrides the package sent to the server; must be in its `ALLOWED_PACKAGE_NAMES`. |

**Licensing activates only when the channel is `play`, the URL is set, and at
least one trusted key is present.** Any of those missing and the build keeps the
old client-side-only behaviour — so shipping this code before the host is
deployed cannot brick paying users.

For production, prefer baking keys into `_bakedKeys` in `license_config.dart`
(two entries during a rotation) over passing them on the command line.

```bash
flutter build appbundle --release \
  --dart-define=AURORA_BUILD_CHANNEL=play \
  --dart-define=AURORA_LICENSE_URL=https://aurora-license-server.fly.dev \
  --dart-define=AURORA_LICENSE_KID=aurora-20260725 \
  --dart-define=AURORA_LICENSE_KEY_N=<modulus from keys:generate> \
  --dart-define=AURORA_LICENSE_KEY_E=AQAB
```

---

## Not dart-defines (related switches)

| Switch | Kind | Notes |
|--------|------|--------|
| `--debug` / `--release` / `--profile` | Flutter build mode | Debug for day-to-day testing per `AGENTS.md` |
| `--target-platform android-arm64` | ABI filter | Preferred for physical devices in this project |
| Pro free vs paid | **Runtime** entitlement | `ProEntitlement` + Play purchase / debug Force Pro — not a build channel |
| Debug “Force Pro” | Runtime, non-release only | Settings → Aurora Pro; never persisted |

---

## Channel behavior matrix

| Behavior | `github` (default) | `play` |
|----------|--------------------|--------|
| YouTube sniff / download | Allowed | **Blocked** |
| Play Billing buy/restore | No-op / “get on Play” copy | Active (`aurora_pro_unlock`) |
| External Pro checkout links | None | None |
| Free-tier Pro feature caps | Release: **none — Ultra unlocked**; debug/profile: Yes (unless debug Force Pro) | Yes until purchase |
| Typical distribution | GitHub Releases, F-Droid, sideload | Play Console AAB |

---

## Product IDs tied to the Play channel

| ID | Type | Notes |
|----|------|--------|
| `aurora_pro_unlock` | One-time IAP | Pro tier |
| `aurora_ultra_unlock` | One-time IAP | Ultra tier |
| `aurora_ultra_upgrade` | One-time IAP | Pro → Ultra step-up |

**All three** must exist and be **Active** in Play Console. If only
`aurora_pro_unlock` is active, every Ultra surface is unpurchasable — see
`play_store_console_runbook.md` Gate 1.

Constants: `kAuroraProProductId` / `kAuroraUltraProductId` /
`kAuroraUltraUpgradeProductId` in **`lib/premium/pro_entitlement.dart:20-22`**
(this doc previously pointed at `play_billing_service.dart` — corrected
2026-07-28).

---

## Adding a new define or channel

1. Document it **in this file** first (name, values, default, code path).  
2. Read it only via `String.fromEnvironment` / `bool.fromEnvironment` (or a thin wrapper like `BuildChannel`).  
3. Prefer a dedicated helper under `lib/premium/` or `lib/compliance/` — avoid scattering raw `fromEnvironment` calls.  
4. Never put secrets in git; document the define name only.  
5. Update `AGENTS.md` build examples if agents commonly need the flag.  
6. Update `README.md` / Play docs if user-facing.

### Reserved / future (not implemented)

| Name | Intent |
|------|--------|
| Gradle `productFlavors { play, github }` | Optional later: different applicationId, icons, or automatic dart-defines per flavor |
| ~~`AURORA_ENABLE_LOG_SERVER`~~ | ~~Possible compile-time debug tooling~~ — **removed 2026-08-05**: the debug log server was deleted with the logging subsystem (see `archive/diagnostics_logging_2026-08-05/`). Do not reintroduce. |
| `AURORA_ENABLE_FFMPEG_MODULE` | When `false` (default: `true`), the on-demand FFmpeg module download is disabled. Useful for internal testing without Play Feature Delivery. |

Do not invent new channel values (`beta`, `fdroid`, …) without documenting them here and handling unknown values safely (treat unknown like `github` unless explicitly designed otherwise).

---

## Quick reference for agents

```text
Daily test APK (full sniffer, no Play billing, fat APK — FFmpeg included):
  flutter build apk --debug --target-platform android-arm64
  adb install -r build/app/outputs/flutter-apk/app-debug.apk

Play compliance APK (still fat — FFmpeg included, local testing):
  flutter build apk --debug --target-platform android-arm64 --dart-define=AURORA_BUILD_CHANNEL=play
  adb install -r build/app/outputs/flutter-apk/app-debug.apk

Play release AAB (on-demand FFmpeg module — ~10 MB deferred):
  flutter build appbundle --release --dart-define=AURORA_BUILD_CHANNEL=play

Play internal testing AAB (must install via Play, not sideload, for on-demand):
  bundletool build-apks --bundle=build/app/outputs/bundle/release/app-release.aab \
    --output=build/app.apks --ks=android/upload-keystore.jks --ks-pass=pass:...
  # Then install via Play Console internal testing track OR bundletool install-apks

GitHub release APK (fat — everything included, no Play required):
  flutter build apk --release
```

### On-demand module notes

The FFmpeg on-demand module is only active when building an **AAB with `AURORA_BUILD_CHANNEL=play`**.  
Debug / profile APK builds are always fat (FFmpeg included) regardless of channel.

| Artifact | FFmpeg packaging | Download required? |
|----------|------------------|--------------------|
| Debug APK (any channel) | In APK (fat) | No |
| Release APK (github) | In APK (fat) | No |
| Release AAB (play) | On-demand module | Yes (~10 MB, one-time) |

For local testing of the on-demand download UX without Play Feature Delivery:
1. Build a debug APK (`flutter build apk --debug`) — fat, always ready.
2. ~~Simulate a missing module with `AURORA_ENABLE_FFMPEG_MODULE=false`.~~
   **Not implemented** — the define has zero references in `lib/` and is still
   listed under "Reserved / future" above. This step contradicted itself;
   corrected 2026-07-28.

Related:

- [`play_on_demand_modules_plan.md`](./done/play_on_demand_modules_plan.md) — archived
- [`play_store_compliance.md`](./play_store_compliance.md)  
- [`play_store_listing.md`](./play_store_listing.md)  
- [`play_store_console_runbook.md`](./play_store_console_runbook.md)  

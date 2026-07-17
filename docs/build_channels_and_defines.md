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
| `github` | **Yes** (if unset) | Open-source / sideload / GitHub releases. Full sniffer (incl. YouTube). **No** Play Billing purchase path. |
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

### `AURORA_GOOGLE_SERVER_CLIENT_ID`

| | |
|--|--|
| **Required for** | Google Sign-In + Drive on some setups (server/web client ID) |
| **Default** | Empty string if unset |
| **Code** | `lib/sync/drive_sync_service.dart` |
| **Secrets** | Never commit real client IDs; pass from local env / CI secrets |

```bash
flutter run --dart-define=AURORA_GOOGLE_SERVER_CLIENT_ID="YOUR_WEB_CLIENT_ID.apps.googleusercontent.com"

flutter build apk --release \
  --dart-define=AURORA_BUILD_CHANNEL=play \
  --dart-define=AURORA_GOOGLE_SERVER_CLIENT_ID="YOUR_WEB_CLIENT_ID.apps.googleusercontent.com"
```

Multiple defines: pass `--dart-define=KEY=value` once per key.

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
| Free-tier Pro feature caps | Yes (unless debug Force Pro) | Yes until purchase |
| Typical distribution | GitHub Releases, sideload | Play Console AAB |

---

## Product IDs tied to the Play channel

| ID | Type | Notes |
|----|------|--------|
| `aurora_pro_unlock` | One-time IAP | Must exist and be **Active** in Play Console for purchases to work |

Constant: `kAuroraProProductId` in `lib/premium/play_billing_service.dart`.

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
| `AURORA_ENABLE_LOG_SERVER` | Possible compile-time debug tooling (today log server is `kDebugMode` only) |

Do not invent new channel values (`beta`, `fdroid`, …) without documenting them here and handling unknown values safely (treat unknown like `github` unless explicitly designed otherwise).

---

## Quick reference for agents

```text
Daily test APK (full sniffer, no Play billing):
  flutter build apk --debug --target-platform android-arm64
  adb install -r build/app/outputs/flutter-apk/app-debug.apk

Play compliance APK:
  flutter build apk --debug --target-platform android-arm64 --dart-define=AURORA_BUILD_CHANNEL=play
  adb install -r build/app/outputs/flutter-apk/app-debug.apk

Play upload:
  flutter build appbundle --release --dart-define=AURORA_BUILD_CHANNEL=play
```

Related:

- [`play_store_compliance.md`](./play_store_compliance.md)  
- [`play_store_listing.md`](./play_store_listing.md)  
- [`play_store_console_runbook.md`](./play_store_console_runbook.md)  
- [`premium_implementation_tracker.md`](./premium_implementation_tracker.md)  

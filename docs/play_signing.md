# Play release signing (upload keystore)

Play Console rejects AABs signed with the **debug** key. Release builds must use a **release/upload keystore**.

## Files (never commit secrets)

| Path | Git | Purpose |
|------|-----|---------|
| `android/upload-keystore.jks` | **ignored** | Upload keystore |
| `android/key.properties` | **ignored** | Passwords + alias + store path |
| `android/key.properties.example` | tracked | Template only |

## Generate a keystore (one time)

```bash
cd android
keytool -genkeypair -v -storetype JKS -keyalg RSA -keysize 2048 -validity 10000 ^
  -alias upload ^
  -keystore upload-keystore.jks ^
  -dname "CN=Aurora Downloader, OU=Mobile, O=Aurora, C=US"
```

Create `android/key.properties` from the example with the passwords you chose.

## Build Play AAB

```bash
flutter build appbundle --release --dart-define=AURORA_BUILD_CHANNEL=play --obfuscate --split-debug-info=build/app/outputs/symbols
```
*Note: Upload the generated de-obfuscation symbol map from `build/app/outputs/symbols` to Play Console (under App bundle explorer > Downloads > De-obfuscation file) to keep crash reports symbolicated.*


Output:

```text
build/app/outputs/bundle/release/app-release.aab
```

## Backup (critical)

If you lose the keystore or passwords, you **cannot** update the same Play app with a new key (without Play App Signing recovery flows). Back up:

1. `upload-keystore.jks`
2. `key.properties` (or the passwords + alias in a password manager)

## Play App Signing

In Play Console, prefer **Play App Signing**:

- You upload with the **upload key** (this keystore).
- Google holds the **app signing key** for users.

First upload registers the upload certificate — keep the same keystore for all future releases.

## Debug builds

Debug APKs still use the automatic debug keystore. That is fine for `adb install` only — never upload those to Play.

# Aurora Downloader

Aurora Downloader is an Android-only Flutter download manager inspired by 1DM. It combines segmented HTTP downloads, an in-app browser sniffer, native BitTorrent/magnet support, Google Drive sync, and a minimalist Nordic dark dashboard.

## Features

- Multi-threaded HTTP downloads with range requests, pause/resume checkpoints, chunk combining, priority queueing, and SHA-256 verification.
- In-app browser with URL/media sniffing, fetch/XHR/media element hooks, ad-domain blocking, popup suppression, and one-tap queue handoff.
- Native Android torrent support through `libtorrent_flutter`, with the deterministic simulated torrent path kept for tests.
- Google Drive sign-in and Drive API upload support through `google_sign_in` and `googleapis`, plus mockable clients for automated tests.
- Nordic dark UI with queue metrics, progress chart, speed limiter control, browser tab, and Drive/settings tab.

## Android Notes

- Minimum Android SDK: 24.
- Compile SDK: 36.
- NDK: 27.0.12077973.
- Google Drive sign-in requires the Android OAuth client for `com.personal.aurora_downloader` plus a Web OAuth client ID passed as `AURORA_GOOGLE_SERVER_CLIENT_ID`.
- `libtorrent_flutter` is GPL-3.0 licensed; review distribution obligations before publishing.

## Google Drive Sign-In

The Android OAuth client identifies the installed app by package name and SHA-1. The Web OAuth client ID is passed to the Flutter app at build/run time:

```powershell
flutter run --dart-define=AURORA_GOOGLE_SERVER_CLIENT_ID="YOUR_WEB_CLIENT_ID.apps.googleusercontent.com"

flutter build apk --release --dart-define=AURORA_GOOGLE_SERVER_CLIENT_ID="YOUR_WEB_CLIENT_ID.apps.googleusercontent.com"
```

Use the **Client ID** from the Web application OAuth row. Do not use or bundle the client secret JSON.

## Verification

```powershell
flutter analyze
flutter test
flutter build apk --debug
flutter build apk --release
```

Debug and release APKs are generated in `build/app/outputs/flutter-apk/`.

# Play Console runbook — first publish

You already have an **approved** Google Play developer account. This is the order of operations for Aurora’s first listing.

## Day 0 — one-time Console setup

1. Open [Play Console](https://play.google.com/apps/publish).
2. Complete **Payments profile** if you will sell Aurora Pro.
3. Create app → **Aurora Downloader**.
4. Complete **App content** forms (privacy policy can be “draft URL” only after the page is live — prefer live first).
5. Create IAP product **`aurora_pro_unlock`** (managed product, one-time).
6. Add yourself as **license tester**.

## Day 1 — build Play channel

```bash
cd aurora_downloader
flutter build apk --debug --target-platform android-arm64 --dart-define=AURORA_BUILD_CHANNEL=play
# Internal testers:
# adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

Verify on device:

- Settings → Aurora Pro → price loads (or product-not-found if product inactive).
- Purchase / restore works with a license tester account.
- Visit youtube.com → notice that capture is disabled; no media cards from YT.
- Paste a `youtu.be` or `googlevideo.com` URL into queue → blocked message.

## Day 2 — store listing assets

Use copy from [`play_store_listing.md`](./play_store_listing.md):

- Short + full description  
- Icon + feature graphic  
- 5+ clean screenshots  

## Day 3 — internal testing track

```bash
flutter build appbundle --release --dart-define=AURORA_BUILD_CHANNEL=play
```

Upload AAB → Internal testing → add testers → promote when smoke tests pass.

## Production

- Complete all **Policy** declarations.  
- Submit for review.  
- Monitor Policy status + crash vitals for 48h after go-live.

## GitHub / FOSS builds (separate)

```bash
flutter build apk --release --dart-define=AURORA_BUILD_CHANNEL=github
```

- No Play Billing purchase path.  
- Pro stays free-tier unless debug override (debug builds only).  
- Do not market the GitHub APK as the Play edition.

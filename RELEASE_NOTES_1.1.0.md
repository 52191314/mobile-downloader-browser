# Aurora Downloader 1.1.0 Release Notes

**Build Version**: 1.1.0+56  
**Release Date**: August 10, 2026  
**Build Channel**: Google Play (Play Store release bundle)

## Major Enhancements

### Batch Listing Download — "Download all on this page"
- **One-tap batch download from any listing page**: the sniffer now crawls the
  active page (channel / tag / user / search pages), follows same-origin detail
  links and pagination, and enqueues every linked video in a single action.
- **Live progress dialog** with per-page counts and a cancel button.
- **Smart dedupe**: already-queued videos are skipped automatically; a summary
  snackbar reports how many were added vs already queued.
- **Generic by design**: no per-site patterns — works via link-structure
  heuristics (deeper sub-paths and numeric-ID detail pages), so it adapts to
  new sites without updates.
- **WAF-bypass transport**: page fetches ride the in-app browser's JavaScript
  network stack first (cookies + TLS fingerprint), falling back to the native
  HTTP path.
- **Premium gated**: routed through the same free-taste batch-capture gate as
  the capture sheet (first-N free, then Pro upsell).

### Multi-Language Internationalization (Batch 1)
- **10 Core Supported Languages**: Introduced full UI localization support for English, Spanish, Simplified Chinese, Hindi, Arabic, Indonesian, Japanese, Portuguese, Russian, and German.
- **System Language Auto-Detection**: Automatically detects and matches the Android device system locale on startup.
- **First-Launch Language Selection Dialog**: Displays a clean first-launch welcome modal allowing users to confirm or select their preferred language prior to the Onboarding Spotlight Tour.
- **In-App Settings Switcher**: Added an App Language dropdown preference inside Settings > Appearance for changing language preferences at any time.

## Technical Details & Infrastructure
- Integrated `flutter_localizations` with standard `.arb` dictionary files (`lib/l10n/`).
- Connected dynamic locale state notifier (`appLocaleNotifier`) to `MaterialApp` root.
- Maintained 16 KB page-size alignment for native `libtorrent_flutter` binaries on Android 64-bit/32-bit targets.

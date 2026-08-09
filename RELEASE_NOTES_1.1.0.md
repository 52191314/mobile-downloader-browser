# Aurora Downloader 1.1.0 Release Notes

**Build Version**: 1.1.0+55  
**Release Date**: August 10, 2026  
**Build Channel**: Google Play (Play Store release bundle)

## Major Enhancements

### Multi-Language Internationalization (Batch 1)
- **10 Core Supported Languages**: Introduced full UI localization support for English, Spanish, Simplified Chinese, Hindi, Arabic, Indonesian, Japanese, Portuguese, Russian, and German.
- **System Language Auto-Detection**: Automatically detects and matches the Android device system locale on startup.
- **First-Launch Language Selection Dialog**: Displays a clean first-launch welcome modal allowing users to confirm or select their preferred language prior to the Onboarding Spotlight Tour.
- **In-App Settings Switcher**: Added an App Language dropdown preference inside Settings > Appearance for changing language preferences at any time.

## Technical Details & Infrastructure
- Integrated `flutter_localizations` with standard `.arb` dictionary files (`lib/l10n/`).
- Connected dynamic locale state notifier (`appLocaleNotifier`) to `MaterialApp` root.
- Maintained 16 KB page-size alignment for native `libtorrent_flutter` binaries on Android 64-bit/32-bit targets.

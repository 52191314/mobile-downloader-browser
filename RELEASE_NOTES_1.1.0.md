# Aurora Downloader 1.1.0 Release Notes

**Build Version**: 1.1.0+62  
**Release Date**: August 10, 2026  
**Build Channel**: Google Play Store (`AURORA_BUILD_CHANNEL=play`)

## Major Enhancements

### Complete App-Wide Subpage & Screen Localization (10 Languages)
- **100% Full-App Localization**: Extended localization across all subpages, settings sections (Defaults, Speed, Adblock, Search, Sniffer, Appearance, Proxy, Backup, Private Vault, FFmpeg Studio, Watcher, WebDAV, User Guide), option descriptions, headers, radio items, status filters, and dialogs.
- **Supported Languages**: English (`en`), Chinese (`zh`), Japanese (`ja`), German (`de`), Spanish (`es`), Portuguese (`pt`), Russian (`ru`), Hindi (`hi`), Arabic (`ar`), and Indonesian (`id`).
- **Live Reactive Language Switching**: Changing the language instantly re-renders all active screens and subpages without requiring an app restart.

### Tab Management & Browser Fixes
- **Grid-View Tab Switcher Fix**: Resolved an index mismatch in `_GridCardLayout` where tapping a grouped or ungrouped tab in Grid View selected the wrong tab.
- **Eliminated White-Screen Gap**: Removed the 350ms artificial delay in `_ensureTabStartupReady` between mounting a deferred WebView and navigating to its URL.
- **10 Core Supported Languages**: Introduced full UI localization support for English, Spanish, Simplified Chinese, Hindi, Arabic, Indonesian, Japanese, Portuguese, Russian, and German.
- **System Language Auto-Detection**: Automatically detects and matches the Android device system locale on startup.
- **First-Launch Language Selection Dialog**: Displays a clean first-launch welcome modal allowing users to confirm or select their preferred language prior to the Onboarding Spotlight Tour.
- **In-App Settings Switcher**: Added an App Language dropdown preference inside Settings > Appearance for changing language preferences at any time.

## Technical Details & Infrastructure
- Integrated `flutter_localizations` with standard `.arb` dictionary files (`lib/l10n/`).
- Connected dynamic locale state notifier (`appLocaleNotifier`) to `MaterialApp` root.
- Maintained 16 KB page-size alignment for native `libtorrent_flutter` binaries on Android 64-bit/32-bit targets.

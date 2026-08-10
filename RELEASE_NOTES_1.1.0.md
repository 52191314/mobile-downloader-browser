# Aurora Downloader 1.1.0 Release Notes

**Build Version**: 1.1.0+68  
**Release Date**: August 10, 2026  
**Build Channel**: Google Play Store (`AURORA_BUILD_CHANNEL=play`)

## Build 68 - 100% Full French (Français) Localization Completion

### Complete French Translation
- **194 Untranslated Keys Resolved**: Audited French dictionary (`app_fr.arb`) against English (`app_en.arb`) and Chinese (`app_zh.arb`). Translated all 194 remaining untranslated keys into natural, native French across all subpages, settings sections, option descriptions, onboarding tour steps, tools menus, and dialogs.
- **100% Full App Coverage**: French localization now covers 100% of all UI strings in the app, matching the coverage of English, Simplified Chinese, Japanese, German, Spanish, Portuguese, Russian, Hindi, Arabic, and Indonesian.

## Build 67 - Capture Sheet Batch Download & Duplicate Wiring Fix

### Capture Sheet Multi-Select Batch Enqueuing
- **Direct Batch Enqueuing**: Fixed multi-select batch downloads from the caught-media bottom sheet (`SniffedMediaSheet`). Clicking "Download selected" or "Series grab" when multiple items are checked now streams all files directly to the queue with a shared `DuplicatePolicy`, instead of popping up the per-item `AddQueueDialog` for every single file.
- **Single Prompt Duplicate Handling**: If duplicate files exist within the batch, the WinRAR-style duplicate dialog displays **once** for the first duplicate. Picking an action (Skip / Replace / Create New) with "Apply to all duplicates" automatically applies that choice to all subsequent duplicates in the batch without repeating dialogs.
- **Repository Alignment**: Fully removed legacy GitHub channel fallbacks from the application logic so this repository operates strictly as a Play Store build with server-side Cloudflare Worker licensing and Play Billing.

## Build 65 - WinRAR-style Duplicate Download Handling

### Duplicate Download Dialog Redesign
- **Skip / Replace / Create New**: Replaced the old Cancel / Create New / Update Existing options with a clearer WinRAR-inspired set: Skip (do nothing), Replace (delete existing task and re-add fresh), Create New (add alongside).
- **"Apply to all duplicates" toggle**: Batch downloads (listing page crawl, capture sheet multi-select, series grab) now show a checkbox to apply the chosen action to all remaining duplicates in the batch, eliminating repeated prompts.
- **Batch duplicate policy**: The listing batch download (`_runListingBatchDownload`) and capture batch flows pass a `DuplicatePolicy` through the enqueue pipeline, so duplicates encountered mid-batch are handled according to the user's remembered preference.
- **Replace action**: Uses `cancelTaskAsync` to fully clean up the existing task (temp files, partial downloads) before adding the replacement, instead of the old URL-patch approach.
- **Localized in all 11 languages**: New dialog strings (dlgSkip, dlgReplace, dlgDuplicateContent, dlgApplyToAll) translated across en, zh, ja, de, es, pt, ru, hi, ar, id, fr.

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

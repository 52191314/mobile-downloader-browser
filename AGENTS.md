# Aurora Downloader — Builder Notes

## Read First

Before searching broadly, read:

1. `../docs/code-maps/README.md`
2. `../docs/code-maps/projects/aurora_downloader.md`
3. Recent `../docs/sessions/` entries for `aurora_downloader`

When changing Aurora structure, major features, important classes, or important methods, update `../docs/code-maps/projects/aurora_downloader.md` in the same session.

## Build (incremental — fast)

To keep development iteration fast, **always build and install in debug mode** for testing changes. Debug builds compile almost instantly and skip Proguard/R8 code shrinking:

```bash
flutter build apk --debug --target-platform android-arm64
```

Only use release builds (`--release` and `app-release.apk`) if explicitly requested.

**First build takes ~10 min** (compiles everything including Kotlin + native libs).
**Subsequent builds take ~1-2 min** (Gradle recompiles only changed files).

**NEVER clean the build directory before building.** Gradle handles incremental compilation.
Only clean if there's a file-locking issue (rare).

## Install

For debug builds:
```bash
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

Do NOT launch the app after install — the user will open it themselves.

For release builds:
```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

## Key Architecture

- Single `MaterialApp` with `IndexedStack` tab-based navigation — browser state preserved across tab switches
- 3 tabs: Queue (downloads), Browser (SnifferScreen), Settings
- Browser supports multiple tabs (`List<_BrowserTab>` in `_SnifferScreenState`)
- Each tab gets its OWN `MediaSnifferEngine` — no shared engines between tabs

## Sniffer JS Guard

Single JS script injected via `_installBrowserGuards()` in `browser_controller.dart`:
- DOM scanning (`video`, `audio`, `a[href]`, `img[src]`, `source[src]`)
- `HTMLMediaElement.prototype.src` setter interceptor
- `loadedmetadata` event listener
- `fetch`/`XMLHttpRequest` interceptor
- `MutationObserver` for dynamic DOM changes

**Plus Dart-side 2-second poll** via `evaluateJavaScript` — asks WebView directly for `video.currentSrc`.
This bypasses any CSP restrictions that might block injected JS.

## Do NOT use `shouldSuppressSniffedUrl`

The `_sniffBrowserUrl()` method must NOT filter any URLs. All sniffed URLs pass through unfiltered.
Any adblock-style filtering was too aggressive and blocked legitimate media CDN URLs.
Keep it simple: classify by extension only.

## Tab persistence

Tab URLs saved to `browser_tabs.json` in app support dir. Restored on next launch.
Sniffed media cached in `sniffed_media_cache.json`.

## APK Naming

If we need to build an APK for Aurora Downloader, it must be named `aurora_downloader.apk`. The native C++ adblock engine is now compiled and active by default — there is no longer a separate `OptionB` variant.

## Native Adblock

The app uses a hybrid adblock engine (`lib/sniffer/ad_block_engine_native.dart`) that auto-detects the native C++ library (`libaurora_adblock.so`) at runtime. If the `.so` loads, native C++ rule matching is used (domain trie + Aho-Corasick automaton). If it fails to load, the engine falls back to Dart-side rule matching automatically. No settings toggle is needed.

## Command Logging

When the user issues a command or request, log it in the session file:
- The **full exact quote** of what the user said
- The **timestamp** (ISO 8601, local time) when the user said it
- Which **agent type** (flash, hard-code, cheap-scout, etc.) was used to respond

Format:

```text
### YYYY-MM-DD HH:MM — User command

> *Full exact quote of what the user said*

- **Agent:** [agent type]
- **Task:** [brief description of what was done]
```

This applies regardless of whether the command was given directly or through the opencode interface.


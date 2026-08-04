# Original User Request

## Initial Request — 2026-08-02T15:16:31Z

# Teamwork Project Prompt — Play Store On-Demand Module Fix

Fix and verify the Play Store release build so the app does not crash at launch or when using BitTorrent / media_kit features. All three native modules (`:ffmpeg`, `:torrent`, `:mediakit`) must remain on-demand via Play Feature Delivery.

Working directory: D:\02_Projects\aurora_downloader
Integrity mode: development

## Context

The app crashes at launch when installed from the Play Store because native `.so` files (`liblibtorrent_flutter.so`, `libmpv.so`) live in on-demand dynamic feature modules but Dart tries to resolve FFI symbols at cold startup.

### Changes already made (verify these are correct):
- `lib/downloader/torrent_downloader.dart`: `deferred as lt hide TorrentStateX` + `FeatureModuleLoader.ensureInstalled('torrent')` before `lt.loadLibrary()`
- `lib/sniffer/player/engines/media_kit_engine.dart`: `deferred as media_kit` / `deferred as media_kit_video` + `FeatureModuleLoader.ensureInstalled('mediakit')` before loading
- `lib/premium/ffmpeg/ffmpeg_module_loader.dart`: Added `torrent` and `mediakit` display names and size estimates
- `pubspec.yaml`: Added `torrent` and `mediakit` to `deferred-components:`
- `android/app/build.gradle.kts`: JNI excludes for libtorrent and libmpv; `dynamicFeatures += listOf(":ffmpeg", ":torrent", ":mediakit")`

## Requirements

### R1. No crash at cold launch
The app must launch successfully on a fresh Play Store install where only `base.apk` is delivered. No native `.so` from `:ffmpeg`, `:torrent`, or `:mediakit` may be loaded at startup.

### R2. On-demand module download before native use
When the user first triggers a BitTorrent download or opens the media_kit player, `FeatureModuleLoader.ensureInstalled()` must download the on-demand module from Play Store before `lt.loadLibrary()` / `media_kit.loadLibrary()` is called. If the module download fails, the app must show a graceful error — not crash.

### R3. Release AAB builds cleanly
`flutter build appbundle --release --no-validate-deferred-components --dart-define=AURORA_BUILD_CHANNEL=play` must exit code 0 and produce an AAB with 4 modules: `base`, `ffmpeg`, `torrent`, `mediakit`.

## Acceptance Criteria

### Build Verification
- [ ] Release AAB compiles cleanly (exit code 0)
- [ ] AAB contains exactly 4 modules: `base`, `ffmpeg`, `torrent`, `mediakit`
- [ ] `base` module does NOT contain `liblibtorrent_flutter.so`, `libmpv.so`, or `libmediakitandroidhelper.so`

### Code Correctness
- [ ] `flutter analyze` on modified files reports 0 errors
- [ ] All existing unit/widget tests pass (`flutter test`)
- [ ] `_ensureLtLoaded()` calls `FeatureModuleLoader.ensureInstalled('torrent')` before `lt.loadLibrary()`
- [ ] `_ensureLoaded()` calls `FeatureModuleLoader.ensureInstalled('mediakit')` before `media_kit.loadLibrary()`
- [ ] No non-deferred imports of `libtorrent_flutter` or `media_kit` anywhere in the codebase

### Graceful Degradation
- [ ] If `FeatureModuleLoader.ensureInstalled()` returns false, the feature reports an error to the user instead of crashing
- [ ] GitHub/sideload builds (`AURORA_BUILD_CHANNEL=github`) still work normally (fat APK, all libs included)

## Follow-up — 2026-08-03T14:14:41Z

Comprehensive audit and analysis of the Aurora Downloader codebase to answer whether peak optimization has been achieved across all major subsystems, or if specific optimizations remain.

Working directory: D:\02_Projects\aurora_downloader
Integrity mode: development

## Requirements

### R1. Full-Stack Subsystem Optimization Audit
Evaluate all core subsystems of `aurora_downloader`:
- **Download Engine & I/O**: Isolates, concurrent chunk streaming, buffer allocation, disk I/O, socket connection handling.
- **Memory & CPU Efficiency**: RAM retention during active high-speed downloads, GC pressure, unneeded object allocations.
- **Native & JNI Bridge**: `libdartjni.so` bindings, dynamic module loader overhead, FFmpeg native integration.
- **App Size & Build Pipeline**: Channel split efficiency (`play` on-demand vs `github` fat APK), R8 minification rules, dependency footprint.
- **Flutter UI & Rendering**: Widget rebuild scope, repaint boundaries, state management efficiency.

### R2. Empirical Bottleneck & Opportunity Report
For each subsystem, produce empirical evidence showing either:
1. **Optimal State**: Rationale and technical proof why current code is at peak efficiency.
2. **Optimization Opportunity**: Identified bottlenecks, quantitative impact (e.g., latency, RAM, APK size), and concrete remediation plan.

## Acceptance Criteria

### Audit Quality & Findings
- [ ] Every core layer (`lib/`, `android/`, JNI native bindings, FFmpeg module) is thoroughly evaluated.
- [ ] Every finding provides technical rationale or code evidence rather than speculative recommendations.
- [ ] Final output delivers a definitive verdict on whether maximum optimization has been achieved and details all remaining optimization targets.

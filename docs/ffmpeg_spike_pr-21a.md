# Phase 0 Spike: FFmpeg on-demand module feasibility

| Field | Value |
|-------|-------|
| **Date** | 2026-07-23 |
| **Status** | **BLOCKED** — Flutter plugin native libs cannot be split into dynamic feature modules with current tooling |
| **PR** | PR-A per `play_on_demand_modules_plan.md` |
| **Spike scope** | Measure AAB size, verify if FFmpeg native libs can be deferred via Play Feature Delivery |

---

## 1. Measurements (arm64-v8a only)

| Metric | Baseline (before spike) | After changes | Delta |
|--------|------------------------|---------------|-------|
| AAB file size | 144.4 MB | 144.6 MB | +0.2 MB |
| Base module contribution | ~144 MB | ~144 MB | ~0 |
| FFmpeg module contribution | N/A | < 100 KB (manifest + dex only) | +0.1 MB |
| Device install size (estimated via bundletool) | ~134 MB (typical) | Same | ~0 |

**Conclusion:** The AAB size is **not reduced** because the native FFmpeg libraries remain in the base module.

---

## 2. AAB module contents

### Base module (arm64-v8a)
| File | Size (est.) | Source |
|------|------------|--------|
| `base/lib/arm64-v8a/libffmpegkit.so` | ~3 MB | `ffmpeg_kit_flutter_new_min_gpl` plugin |
| `base/lib/arm64-v8a/libavcodec.so` | ~4 MB | " |
| `base/lib/arm64-v8a/libavformat.so` | ~2 MB | " |
| `base/lib/arm64-v8a/libavutil.so` | ~1 MB | " |
| `base/lib/arm64-v8a/libswresample.so` | < 1 MB | " |
| `base/lib/arm64-v8a/libswscale.so` | < 1 MB | " |
| `base/lib/arm64-v8a/libavfilter.so` | < 1 MB | " |
| `base/lib/arm64-v8a/libavdevice.so` | < 1 MB | " |
| **Total FFmpeg native** | **~12 MB** | |

### FFmpeg dynamic feature module
| File | Size | Notes |
|------|------|-------|
| `ffmpeg/manifest/AndroidManifest.xml` | < 1 KB | `dist:on-demand` delivery |
| `ffmpeg/dex/classes.dex` | ~10 KB | Flutter deferred component stub |
| `ffmpeg/resources.pb` | < 1 KB | Module metadata |

The `:ffmpeg` module contains **no native `.so` files** — only manifest, dex, and resources. The native libs are still in `base/lib/`.

---

## 3. Why the split doesn't work

Root cause: **Flutter's Gradle plugin bundles plugin native libs into the base module automatically.**

The dependency chain is:

```
pubspec.yaml
  └── ffmpeg_kit_flutter_new_min_gpl: ^2.5.3
        └── android/ (plugin directory with .so files)
              └── Flutter Gradle plugin → base/lib/arm64-v8a/
```

The Flutter Gradle plugin (`flutter.groovy`) iterates all plugins and copies their native `.so` libraries into the **base** module's `jniLibs`. It does **not** check the `deferred-components` configuration when placing native libs — it only uses that config for Dart code splitting.

Related issues:
- [flutter#91556](https://github.com/flutter/flutter/issues/91556) - Deferred components + native plugins
- [flutter#100380](https://github.com/flutter/flutter/issues/100380) - Plugin native libs in dynamic features

---

## 4. What was implemented (architecture is correct)

The following **will work** once the native lib split is resolved:

| Layer | Status | What it does |
|-------|--------|--------------|
| **`FeatureModuleLoader`** | ✅ Shipped | Channel-aware `ensureInstalled()` with `FeatureModuleStatus` |
| **`GitHubModuleLoader`** | ✅ Shipped | Always returns `ready` (fat APK) |
| **`PlayModuleLoader`** | ✅ Shipped | Calls native `SplitInstallManager` via method channel |
| **Method channel** | ✅ Shipped | `aurora_downloader/feature_delivery` with real `startInstall/getModuleStatus/cancelInstall` |
| **Android manifest** | ✅ Shipped | `dist:on-demand` delivery + `dist:fusing` |
| **FFmpeg Studio wiring** | ✅ Shipped | Download prompt → progress → retry in `queue_page.dart` and `ffmpeg_studio_page.dart` |
| **`ffmpeg_runtime.dart`** | ✅ Shipped | Isolates `ffmpeg_kit` imports for future deferred loading |
| **`pubspec.yaml`** | ✅ Shipped | `deferred-components` section ready |
| **Gradle channel detection** | ✅ Shipped | `AURORA_BUILD_CHANNEL` env var + `-P` flag |
| **Play Core dependency** | ✅ Shipped | `feature-delivery:2.1.0` in base `build.gradle.kts` |
| **Native lib split** | ❌ **Blocked** | Flutter plugin bundles libs into base module |

---

## 5. Options to unblock

### Option A: Fork ffmpeg-kit Flutter plugin (recommended in plan)

Create a forked version of `ffmpeg_kit_flutter_new_min_gpl` that:
1. Uses a custom Gradle configuration to package native libs into the `:ffmpeg` dynamic feature module
2. Uses `dist:onDemand` manifest for the feature module
3. Ships the Dart wrapper as a **deferred** Flutter library

**Effort:** ~3–5 days  
**Risk:** Medium — fork maintenance burden  
**Upside:** Full size reduction (~12 MB), clean Play Feature Delivery integration

### Option B: Runtime download from CDN

Download the FFmpeg `.so` files at runtime from a CDN/hosted location:
1. Package the `.so` files as assets or host on a server
2. Download on first Ultra-gated Studio use
3. Load with `DynamicLibrary.open()` in Dart FFI

**Effort:** ~2–3 days  
**Risk:** Low — fully under your control  
**Downside:** Not Play Feature Delivery; works on both channels; extra network on first use  
**Note:** The `FeatureModuleLoader` abstraction already supports this pattern — `PlayModuleLoader.ensureInstalled()` would just download from a URL instead of calling SplitInstallManager.

### Option C: Accept current size (do nothing)

Keep the on-demand **Dart architecture** but remove the empty `:ffmpeg` Gradle module. The AAB stays at ~144 MB. The code is ready for when Flutter tooling supports plugin native lib splitting.

**Effort:** None  
**Risk:** None  
**Downside:** No install size reduction today

---

## 6. Recommendation

**Option B (runtime download)** is the pragmatic path forward:

- The `FeatureModuleLoader` abstraction is already designed for this
- Works on both Play and GitHub channels
- No plugin fork needed
- Can be implemented in 2–3 days
- Full size reduction without waiting for Flutter tooling

The Play Feature Delivery dynamic module (`:ffmpeg`) should be **removed** from the build since it currently contributes no native libs. The `FeatureModuleLoader` + method channel + Studio wiring remain.

---

## 7. Detailed size breakdown (AAB)

| Component | Size | % of total |
|-----------|------|------------|
| Flutter engine + framework | ~30 MB | 21% |
| InAppWebView + Chromium | ~25 MB | 17% |
| FFmpeg native libs (8 .so) | ~12 MB | 8% |
| libtorrent_flutter | ~8 MB | 6% |
| Dart kernel + assets | ~8 MB | 6% |
| AndroidX / Material / Play deps | ~20 MB | 14% |
| Resources (drawables, layouts, etc.) | ~25 MB | 17% |
| Other (dex, META-INF, etc.) | ~16 MB | 11% |
| **Total** | **~144 MB** | **100%** |

The FFmpeg share (~12 MB) is the largest single deferrable component. BitTorrent (~8 MB) is next.

---

## 8. References

- [`play_on_demand_modules_plan.md`](./play_on_demand_modules_plan.md) — original plan
- `android/ffmpeg/build.gradle.kts` — dynamic feature module build
- `lib/premium/ffmpeg/ffmpeg_module_loader.dart` — `FeatureModuleLoader` abstraction
- `android/app/.../MainActivity.kt` — `feature_delivery` method channel
- Flutter deferred components: https://docs.flutter.dev/perf/deferred-components
- Play Feature Delivery: https://developer.android.com/guide/playcore/feature-delivery/on-demand

---

## 9. Decision log

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Proceed with Phase 1? | **On hold** | Native lib split blocked by Flutter tooling |
| Keep `FeatureModuleLoader`? | **Yes** | Architecture is correct and useful |
| Remove `:ffmpeg` Gradle module? | **TBD** | Empty module adds no value |
| Fallback strategy | **Option B (runtime download)** | Pragmatic, works now, no plugin fork |

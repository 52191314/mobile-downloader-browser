# Option A: Gradle jniLibs redistribution for FFmpeg on-demand module

| Field | Value |
|-------|-------|
| **Status** | Implementation |
| **Approach** | Fork-lite — no plugin fork needed; Gradle redistributes .so after Flutter bundling |
| **Target** | Play channel only (`AURORA_BUILD_CHANNEL=play`) |
| **Size saving** | ~12 MB (FFmpeg native libs) from base install |

---

## 1. The problem

Flutter's Gradle plugin automatically copies all plugin native `.so` files into the **base** module. The `:ffmpeg` dynamic feature module exists with correct manifest and delivery config, but has no native libs.

**Before:**
```
AAB/
├── base/lib/arm64-v8a/
│   ├── libffmpegkit.so         ← ~3 MB  (should be deferred)
│   ├── libavcodec.so           ← ~4 MB  (should be deferred)
│   ├── libavformat.so          ← ~2 MB  (should be deferred)
│   ├── libavutil.so            ← ~1 MB
│   ├── libswresample.so        ← <1 MB
│   ├── libswscale.so           ← <1 MB
│   ├── libavfilter.so          ← <1 MB
│   ├── libavdevice.so          ← <1 MB
│   ├── libffmpegkit_abidetect.so
│   ├── libapp.so               ← keep in base
│   ├── libflutter.so           ← keep in base
│   ├── liblibtorrent_flutter.so← keep in base
│   └── ...                      ← keep in base
└── ffmpeg/                     ← empty (no native libs)
    ├── AndroidManifest.xml
    ├── classes.dex
    └── resources.pb
```

**After (target):**
```
AAB/
├── base/lib/arm64-v8a/
│   ├── libapp.so               ← unchanged
│   ├── libflutter.so           ← unchanged
│   ├── liblibtorrent_flutter.so← unchanged
│   └── ...                     ← no ffmpeg libs
└── ffmpeg/lib/arm64-v8a/       ← FFmpeg .so files live here
    ├── libffmpegkit.so
    ├── libavcodec.so
    ├── libavformat.so
    ├── libavutil.so
    ├── libswresample.so
    ├── libswscale.so
    ├── libavfilter.so
    ├── libavdevice.so
    └── libffmpegkit_abidetect.so
```

---

## 2. Approach: Gradle doLast hook

**No plugin fork required.** The redistribution happens at the Gradle intermediate output level — after Flutter bundles all `.so` files into the base module's `merged_jni_libs`, but before Bundletool assembles the final AAB.

### How it works

```
Flutter Gradle Plugin
    │
    ▼
:app:mergeReleaseJniLibs          ──►  base/intermediates/merged_jni_libs/
    │                                    (ALL .so files including ffmpeg)
    │
    ▼  Gradle doLast hook
:ffmpeg:moveFfmpegLibsFromBase    ──►  Copies ffmpeg .so → ffmpeg/intermediates/
    │                                    Deletes ffmpeg .so from base/intermediates/
    │
    ▼
:ffmpeg:mergeReleaseJniLibs       ──►  ffmpeg/intermediates/merged_jni_libs/
    │                                    (only ffmpeg .so)
    │
    ▼
bundleRelease                     ──►  AAB with split modules
```

### Key implementation

In `android/ffmpeg/build.gradle.kts`:

```kotlin
// After the base app merges all jniLibs (including ffmpeg-kit plugin),
// move the FFmpeg .so files from the base module to this dynamic feature
// module so they're delivered on-demand via Play Feature Delivery.
tasks.whenTaskAdded {
    if (name == "mergeReleaseJniLibs") {
        dependsOn(":app:mergeReleaseJniLibs")
        doFirst {
            val ffmpegLibs = listOf(
                "libffmpegkit.so",
                "libffmpegkit_abidetect.so",
                "libavcodec.so",
                "libavformat.so",
                "libavutil.so",
                "libswresample.so",
                "libswscale.so",
                "libavfilter.so",
                "libavdevice.so",
            )
            val baseJni = file("${project(":app").buildDir}/intermediates/merged_jni_libs/release/out/")
            val ffmpegJni = file("$buildDir/intermediates/merged_jni_libs/release/out/")

            for (abi in listOf("arm64-v8a")) {
                val srcAbi = baseJni.resolve(abi)
                val dstAbi = ffmpegJni.resolve(abi)
                if (!srcAbi.isDirectory) continue

                ffmpegLibs.forEach { lib ->
                    val src = srcAbi.resolve(lib)
                    if (src.exists()) {
                        dstAbi.mkdirs()
                        src.copyTo(dstAbi.resolve(lib), overwrite = true)
                        src.delete()
                        logger.info("[aurora] Moved $lib from base to ffmpeg module")
                    }
                }
            }
        }
    }
}
```

### ABI filter enforcement

The `abiFilters` in `android/app/build.gradle.kts` already limits to `arm64-v8a`. This is critical: shipping arm64-only means we move only the arm64 `.so` files instead of 3 ABIs worth.

---

## 3. Files to modify

| File | Change |
|------|--------|
| `android/ffmpeg/build.gradle.kts` | Add `doFirst` hook on `mergeReleaseJniLibs` to copy .so from base |
| `android/app/build.gradle.kts` | Already has `abiFilters = listOf("arm64-v8a")` — verify |
| None — pubspec.yaml stays as-is | ffmpeg-kit plugin dependency unchanged |

---

## 4. Validation

| Check | Method | Expected |
|-------|--------|----------|
| Base module has no ffmpeg .so | `tar -tf AAB \| grep "base.*lib.*ffmpeg"` | No results |
| ffmpeg module has ffmpeg .so | `tar -tf AAB \| grep "ffmpeg.*lib"` | 9 `.so` files |
| AAB base size reduced | Compare file sizes | ~12 MB smaller base |
| FFmpeg Studio works | Launch Studio → on-demand download → process job | Operates correctly |
| GitHub APK still fat | Build with default channel | FFmpeg included in APK |

---

## 5. Risk register

| Risk | Impact | Mitigation |
|------|--------|------------|
| Gradle intermediate paths change in Flutter/AGP update | Build breaks | CI pins Flutter/AGP version; documented in runbook |
| .so files load before module is installed | `UnsatisfiedLinkError` | `FeatureModuleLoader.ensureInstalled()` must complete before `FfmpegService` probes version |
| Plugin API change adds new .so files MissingPluginException | Missing .so, crash at runtime | Document the .so list as needing review when ffmpeg-kit updates |
| `doFirst` runs before base merge completes | Empty source | `dependsOn(":app:mergeReleaseJniLibs")` ensures ordering |

---

## 6. Effort

| Step | Time |
|------|------|
| Gradle hook implementation | 30 min |
| Build & validate AAB structure | 30 min |
| Test FFmpeg Studio end-to-end | 30 min |
| **Total** | **~1.5 hours** |

---

## 7. Comparison with other options

| | Option A (this) | Option B (runtime download) | Option C (accept) |
|--|-----------------|----------------------------|-------------------|
| Size reduction | ~12 MB | ~12 MB | 0 |
| Plugin fork needed | No | No | No |
| Play Feature Delivery | Yes | No | N/A |
| Works on GitHub | No (fat APK) | Yes | Yes |
| Effort | ~1.5 hours | ~2–3 days | None |
| Fragility | Medium (Gradle paths) | Low | None |
| FFmpeg Studio offline after install | Yes | No (needs network for first download) | Yes |

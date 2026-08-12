import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Firebase Analytics (Play-only repo). Requires android/app/google-services.json
    // (downloaded from the Firebase console; the file is gitignored).
    id("com.google.gms.google-services")
    // Crashlytics (Flutter + NDK symbol upload) + Performance Monitoring
    // (app-start + OkHttp auto-instrumentation). Same Play-only repo.
    id("com.google.firebase.crashlytics")
    id("com.google.firebase.firebase-perf")
}

// Release signing: load android/key.properties (gitignored). See docs/play_signing.md.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

// ---------------------------------------------------------------------------
// Build channel: computed once in settings.gradle.kts (single source of
// truth, stored on the Gradle object as `auroraPlayChannel`).
//   Play   → on-demand dynamic-feature modules (:ffmpeg, :torrent, :mediakit)
//   GitHub → fat builds; the feature modules' tasks are disabled.
// See: AGENTS.md, docs/play_on_demand_modules_plan.md
// ---------------------------------------------------------------------------
val isPlayChannel = gradle.extensions.getExtraProperties().has("auroraPlayChannel") &&
    (gradle.extensions.getExtraProperties().get("auroraPlayChannel") as Boolean)

// Channel switches (play <-> github) change which dynamic features are wired
// into :app, but AGP does not track that set as an input of
// generateDebugFeatureMetadata — its feature-metadata.json can go stale
// (featureSplits from the other channel), which breaks the feature modules'
// manifest tasks. Always regenerate; the task is cheap.
tasks.matching { it.name == "generateDebugFeatureMetadata" }.configureEach {
    outputs.upToDateWhen { false }
}

android {
    namespace = "com.personal.aurora_downloader"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.personal.aurora_downloader"
        minSdk = 24
        // Pinned, not inherited from `flutter.targetSdkVersion`: Play raises the
        // targetSdk floor for new app submissions to API 36 on 2026-08-31, and a
        // floating value silently changes with a Flutter SDK upgrade.
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a")
        }
    }

    // Native adblock engine — C++ implementation with domain trie + Aho-Corasick.
    externalNativeBuild {
        cmake {
            path = file("CMakeLists.txt")
        }
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                // storeFile is relative to the android/ directory when path is relative.
                storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    // Play Store AAB builds use dynamic feature modules for on-demand delivery.
    // GitHub / sideload APK builds are fat — everything in one APK.
    // Dynamic feature modules (:ffmpeg, :torrent, :mediakit) ship native libs separately.
    if (isPlayChannel) {
        dynamicFeatures += listOf(":ffmpeg", ":torrent", ":mediakit")
    }

    // Play only & AAB only: keep FFmpeg, BitTorrent, and MediaKit .so out of the *base* module.
    // The same natives are packaged into their respective dynamic feature modules
    // (:ffmpeg, :torrent, :mediakit). APK builds (debug/profile/release) omit this block
    // so the Flutter plugin libs remain in the APK.
    val isBundleTask = gradle.startParameter.taskNames.any { it.contains("bundle", ignoreCase = true) }
    if (isPlayChannel && isBundleTask) {
        packaging {
            jniLibs {
                // Keep FFmpeg kit + libav* out of base (all ABI / neon variants).
                // Same payload is packaged into :ffmpeg for on-demand install.
                excludes += listOf(
                    "**/libffmpegkit.so",
                    "**/libffmpegkit_abidetect.so",
                    "**/libffmpegkit_armv7a_neon.so",
                    "**/libavcodec.so",
                    "**/libavcodec_neon.so",
                    "**/libavformat.so",
                    "**/libavformat_neon.so",
                    "**/libavutil.so",
                    "**/libavutil_neon.so",
                    "**/libavfilter.so",
                    "**/libavfilter_neon.so",
                    "**/libavdevice.so",
                    "**/libavdevice_neon.so",
                    "**/libswresample.so",
                    "**/libswresample_neon.so",
                    "**/libswscale.so",
                    "**/libswscale_neon.so",
                    // BitTorrent dynamic feature module (:torrent)
                    "**/liblibtorrent_flutter.so",
                    "**/libtorrent*.so",
                    // MediaKit dynamic feature module (:mediakit)
                    "**/libmpv.so",
                    "**/libmpv*.so",
                    "**/libmediakitandroidhelper.so",
                    "**/libmediakitandroidhelper*.so",
                )
            }
        }
    }


    packaging {
        jniLibs {
            excludes += listOf(
                "**/mips/**",
                "**/mips64/**",
                // No x86/x86_64 anywhere — app ships arm64-v8a + armeabi-v7a
                // only. Keeps the AAB free of ~15 MB of emulator-only .so
                // (upload size) and keeps the base's ABI set in sync with the
                // on-demand feature modules (bundletool requires a match).
                "**/x86/**",
                "**/x86_64/**",
            )
        }
    }

    buildTypes {
        release {
            // Prefer upload keystore; fail closed if missing so we never
            // silently ship a debug-signed AAB to Play again.
            if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                throw GradleException(
                    "Missing android/key.properties — release builds must use a " +
                        "Play upload keystore. See docs/play_signing.md. " +
                        "Do not use the debug keystore for Play Console uploads.",
                )
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("androidx.media3:media3-transformer:1.5.1")
    implementation("androidx.media3:media3-muxer:1.5.1")
    // Play Feature Delivery (on-demand modules) — only used for Play AAB builds.
    // GitHub fat APK builds don't include this but it's harmless (no-op).
    implementation("com.google.android.play:feature-delivery:2.1.0")
    implementation("com.google.android.play:feature-delivery-ktx:2.1.0")
    implementation("androidx.webkit:webkit:1.12.0")
    implementation("androidx.browser:browser:1.8.0")
}

// Native payload for :ffmpeg is extracted in android/ffmpeg/build.gradle.kts.
// Base exclusion is packaging.jniLibs.excludes above (Play only).

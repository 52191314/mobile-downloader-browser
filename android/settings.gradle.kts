pluginManagement {
    val flutterSdkPath = run {
        val properties = java.util.Properties()
        file("local.properties").inputStream().use { properties.load(it) }
        val flutterSdkPath = properties.getProperty("flutter.sdk")
        require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
        flutterSdkPath
    }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
        maven { url = uri("https://jitpack.io") }
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.9.1" apply false
    id("org.jetbrains.kotlin.android") version "2.1.0" apply false
}

// ---------------------------------------------------------------------------
// Build channel detection — single source of truth for every module.
// Computed HERE (settings evaluate before any project script) and stored on
// the Gradle object, readable from :app and the feature modules via
// `gradle.extensions.getExtraProperties().get("auroraPlayChannel")`.
//   Play   → on-demand dynamic-feature modules (:ffmpeg, :torrent, :mediakit)
//   GitHub → fat builds; the feature modules' tasks are disabled.
// ---------------------------------------------------------------------------
fun isPlayBuildChannel(): Boolean {
    // 1. Env var (CI / shell): highest priority.
    //    $env:AURORA_BUILD_CHANNEL="play"   → Play (on-demand modules)
    //    $env:AURORA_BUILD_CHANNEL="github" → GitHub fat APK
    val envChannel = System.getenv("AURORA_BUILD_CHANNEL")?.lowercase()
    if (envChannel == "play") return true
    if (envChannel == "github") return false

    // 2. --dart-define=AURORA_BUILD_CHANNEL=... — Flutter passes dart-defines
    //    to Gradle as `-Pdart-defines=<base64 comma-joined list>`. Checked
    //    before `auroraBuildChannel` (android/gradle.properties defaults it to
    //    `github`, which would otherwise shadow the explicit define).
    val definesProp = providers.gradleProperty("dart-defines").orNull
    if (definesProp != null) {
        val decodedDefines = definesProp.split(',').mapNotNull { raw ->
            runCatching {
                String(java.util.Base64.getDecoder().decode(raw))
            }.getOrNull()
        }
        if (decodedDefines.contains("AURORA_BUILD_CHANNEL=play") ||
            definesProp.contains("QVVST1JBX0JVSUxEX0NIQU5ORUw9cGxheQ==")
        ) {
            return true
        }
        if (decodedDefines.contains("AURORA_BUILD_CHANNEL=github")) return false
    }

    // 3. Legacy single-encoded property, then the explicit -P property.
    val encodedProp = providers.gradleProperty("dart-defines-encoded").orNull
    val decoded = encodedProp?.let {
        runCatching { String(java.util.Base64.getDecoder().decode(it)) }.getOrNull()
    }
    if (decoded?.contains("AURORA_BUILD_CHANNEL=play") == true) return true
    if (decoded?.contains("AURORA_BUILD_CHANNEL=github") == true) return false

    val channelProp = providers.gradleProperty("auroraBuildChannel").orNull?.lowercase()
    if (channelProp == "play") return true
    if (channelProp == "github") return false

    // 4. Default: GitHub fat APK. Do NOT special-case bundle tasks here — doing
    //    so silently turned every `flutter build appbundle` into a Play build
    //    that stripped the FFmpeg/libmpv/libtorrent natives from the base and
    //    crashed on launch (builds 38-44).
    return false
}

gradle.extensions.getExtraProperties().set("auroraPlayChannel", isPlayBuildChannel())

include(":app")
include(":ffmpeg")
include(":torrent")
include(":mediakit")

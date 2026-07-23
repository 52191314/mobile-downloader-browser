import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing: load android/key.properties (gitignored). See docs/play_signing.md.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

// ---------------------------------------------------------------------------
// Build channel detection: Play Store AAB vs GitHub fat APK.
// Default is `github` (fat APK) so open-source builds never ship a dynamic
// feature module. Play builds set `--dart-define=AURORA_BUILD_CHANNEL=play`.
//
// The dart-define values are available via the Flutter extension's dartDefines
// list. We also check the Gradle project property (set via -P) as a fallback
// for CI scripts that may pass it directly.
// See: AGENTS.md, docs/play_on_demand_modules_plan.md
// ---------------------------------------------------------------------------
fun isPlayBuildChannel(): Boolean {
    // Primary path: Flutter's dart-defines from --dart-define=AURORA_BUILD_CHANNEL=play
    val flutterExt = project.extensions.findByName("flutter")
    val dartDefines = (flutterExt as? dynamic)?.dartDefines
    if (dartDefines is List<*>) {
        if (dartDefines.any { it.toString().lowercase() == "aurora_build_channel=play" }) {
            return true
        }
    }
    // Fallback: Gradle project property for CI (-PauroraBuildChannel=play).
    if (project.hasProperty("auroraBuildChannel")) {
        val channel = project.property("auroraBuildChannel") as? String
        if (channel?.lowercase() == "play") return true
    }
    return false
}
val isPlayChannel = isPlayBuildChannel()

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
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters += listOf("arm64-v8a")
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
    // The `:ffmpeg` dynamic feature module ships FFmpeg native libs separately.
    if (isPlayChannel) {
        dynamicFeatures += listOf(":ffmpeg")
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
}

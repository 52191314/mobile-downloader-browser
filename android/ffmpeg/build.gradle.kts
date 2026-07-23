plugins {
    id("com.android.dynamic-feature")
    id("kotlin-android")
}

android {
    namespace = "com.personal.aurora_downloader.ffmpeg"
    compileSdk = 36

    defaultConfig {
        minSdk = 24
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }
}

dependencies {
    implementation(project(":app"))
    // The ffmpeg-kit native libraries live in this dynamic feature module,
    // so they are NOT included in the base APK for Play builds.
    // GitHub / sideload builds ship everything in the fat APK instead.
    implementation("com.arthenica:ffmpeg-kit-min-gpl:6.0.LTS")

    // Native FFmpeg library is packaged here for Play AAB on-demand delivery.
    // The base app calls SplitInstallManager to trigger the download.
}

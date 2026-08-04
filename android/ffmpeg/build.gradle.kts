plugins {
    id("com.android.dynamic-feature")
    id("kotlin-android")
}

// ---------------------------------------------------------------------------
// FFmpeg native libs for on-demand Play Feature Delivery.
//
// The Flutter plugin `ffmpeg_kit_flutter_new_min_gpl` always merges its JNI
// into the *base* module. This dynamic feature re-packages the same natives
// (from the upstream Maven AAR) so Play can deliver them on demand.
//
// Base-module exclusion of these .so files is handled in :app (Play channel
// only). See android/app/build.gradle.kts and docs/ffmpeg_play_module_option_a_plan.md.
// ---------------------------------------------------------------------------

val ffmpegKitNativeVersion = "2.2.2"
val ffmpegNativeConfig = configurations.create("ffmpegNative") {
    isCanBeConsumed = false
    isCanBeResolved = true
    isTransitive = false
}

dependencies {
    implementation(project(":app"))
    // Same artifact the Flutter plugin uses — provides jni/**/*.so inside the AAR.
    add("ffmpegNative", "com.antonkarpenko:ffmpeg-kit-min-gpl:$ffmpegKitNativeVersion")
}

val extractFfmpegJni by tasks.registering {
    val outDir = layout.buildDirectory.dir("extracted-ffmpeg-jni")
    inputs.files(ffmpegNativeConfig)
    outputs.dir(outDir)
    doLast {
        val destRoot = outDir.get().asFile
        destRoot.deleteRecursively()
        destRoot.mkdirs()

        val aars = ffmpegNativeConfig.files.filter {
            it.extension == "aar" || it.name.endsWith(".aar")
        }
        if (aars.isEmpty()) {
            throw GradleException(
                "[aurora-ffmpeg] No ffmpeg-kit AAR resolved from " +
                    "com.antonkarpenko:ffmpeg-kit-min-gpl:$ffmpegKitNativeVersion",
            )
        }

        // Bundletool requires every module with natives to advertise the *same*
        // ABI set as base. Base ships arm64-v8a + armeabi-v7a only (see
        // :app abiFilters + packaging excludes), so extract the same set here.
        // Play still delivers only the device ABI at install time.
        val abis = listOf("arm64-v8a", "armeabi-v7a")
        var copied = 0
        aars.forEach { aar ->
            copy {
                from(zipTree(aar))
                // AAR layout: jni/<abi>/*.so
                abis.forEach { abi ->
                    include("jni/$abi/*.so")
                }
                into(destRoot)
            }
            abis.forEach { abi ->
                val dir = destRoot.resolve("jni/$abi")
                if (dir.isDirectory) {
                    copied += dir.listFiles()?.count { it.extension == "so" } ?: 0
                }
            }
        }
        if (copied == 0) {
            throw GradleException(
                "[aurora-ffmpeg] Extracted AAR but found no FFmpeg .so files",
            )
        }
        logger.quiet(
            "[aurora-ffmpeg] Extracted $copied FFmpeg .so file(s) into feature module jniLibs",
        )
    }
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

    sourceSets {
        getByName("main") {
            // jni/<abi>/*.so from extract task
            jniLibs.srcDir(layout.buildDirectory.dir("extracted-ffmpeg-jni/jni"))
        }
    }
}

// Always extract before preBuild so sourceSets jniLibs dir is populated.
tasks.named("preBuild").configure {
    dependsOn(extractFfmpegJni)
}

// GitHub/sideload channel: this module is never wired into :app
// (dynamicFeatures is only populated for Play), but Flutter invokes
// `gradlew assembleDebug` unqualified, which schedules this module's
// assembleDebug anyway — and its manifest task fails without a featureName
// in :app's feature-metadata.json. Disable the whole module instead.
val auroraPlay = gradle.extensions.getExtraProperties().has("auroraPlayChannel") &&
    (gradle.extensions.getExtraProperties().get("auroraPlayChannel") as Boolean)
if (!auroraPlay) {
    tasks.configureEach { enabled = false }
}

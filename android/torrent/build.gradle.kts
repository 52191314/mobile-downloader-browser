import java.io.File
import java.io.InputStream
import java.net.URI

plugins {
    id("com.android.dynamic-feature")
    id("kotlin-android")
}

val extractTorrentJni by tasks.registering {
    val outDir = layout.buildDirectory.dir("extracted-torrent-jni")
    outputs.dir(outDir)
    // The task's real inputs are the plugin's prebuilt .so files in the pub
    // cache (see findPrebuiltDir below), which Gradle cannot see as task
    // inputs (they live outside the build and are swapped by
    // tooling/prepare_torrent_16k.sh — notably for 16 KB page-size
    // alignment). Without this, the task is UP-TO-DATE after the first run
    // and the stale, unaligned libtorrent .so keeps getting packaged.
    // The copy is cheap (~2 files), so always re-run it.
    outputs.upToDateWhen { false }

    val torrentPlugin = findProject(":libtorrent_flutter")
    if (torrentPlugin != null) {
        dependsOn(torrentPlugin.tasks.matching { it.name == "preBuild" || it.name == "assemble" })
    }

    doLast {
        val destRoot = outDir.get().asFile
        destRoot.deleteRecursively()
        destRoot.mkdirs()

        // arm64-v8a only for the torrent feature. The closed-source BSD
        // libtorrent bridge is built for 64-bit; the armeabi-v7a vcpkg build is
        // blocked by a CMake 4.4 / NDK legacy-toolchain incompatibility on this
        // machine. 32-bit devices keep every other feature; torrent simply does
        // not install there.
        val abis = listOf("arm64-v8a")
        var copied = 0

        fun findPrebuiltDir(): File? {
            // Attempt 0: Vendored 16 KB-aligned binaries in tooling/torrent_16k
            val vendoredDir = rootProject.file("../tooling/torrent_16k")
            if (vendoredDir.exists() && File(vendoredDir, "arm64-v8a").isDirectory) return vendoredDir

            // Attempt 1: Gradle subproject reference
            val subprojectDir = findProject(":libtorrent_flutter")?.projectDir?.let { File(it.parentFile, "prebuilt/android") }
            if (subprojectDir != null && subprojectDir.exists()) return subprojectDir

            // Attempt 2: package_config.json
            val pkgConfigFile = rootProject.file("../.dart_tool/package_config.json")
            if (pkgConfigFile.exists()) {
                val jsonText = pkgConfigFile.readText()
                val match = Regex(""""name"\s*:\s*"libtorrent_flutter"\s*,\s*"rootUri"\s*:\s*"([^"]+)"""").find(jsonText)
                    ?: Regex(""""rootUri"\s*:\s*"([^"]+)"\s*,\s*"name"\s*:\s*"libtorrent_flutter"""").find(jsonText)
                if (match != null) {
                    var uriStr = match.groupValues[1]
                    if (uriStr.startsWith("file:///")) {
                        uriStr = uriStr.removePrefix("file:///")
                    } else if (uriStr.startsWith("file:")) {
                        uriStr = uriStr.removePrefix("file:")
                    }
                    val pkgDir = File(uriStr)
                    val candidate = File(pkgDir, "prebuilt/android")
                    if (candidate.exists()) return candidate
                }
            }

            // Attempt 3: Search PUB_CACHE directory search
            val pubCacheDirs = listOfNotNull(
                System.getenv("PUB_CACHE")?.let { File(it, "hosted/pub.dev") },
                File("D:/DevTools/PubCache/hosted/pub.dev"),
                File("${System.getProperty("user.home")}/.pub-cache/hosted/pub.dev"),
                System.getenv("LOCALAPPDATA")?.let { File(it, "Pub/Cache/hosted/pub.dev") },
            )
            for (baseDir in pubCacheDirs) {
                if (baseDir.exists()) {
                    val matching = baseDir.listFiles()?.filter { it.name.startsWith("libtorrent_flutter-") }
                    if (!matching.isNullOrEmpty()) {
                        val candidate = File(matching.first(), "prebuilt/android")
                        if (candidate.exists()) return candidate
                    }
                }
            }
            return null
        }

        val prebuiltDir = findPrebuiltDir()
        if (prebuiltDir != null && prebuiltDir.exists()) {
            abis.forEach { abi ->
                val abiSrcDir = File(prebuiltDir, abi)
                if (abiSrcDir.isDirectory) {
                    val abiDestDir = File(destRoot, "jni/$abi")
                    abiDestDir.mkdirs()
                    abiSrcDir.listFiles()?.filter { it.extension == "so" }?.forEach { soFile ->
                        soFile.copyTo(File(abiDestDir, soFile.name), overwrite = true)
                        copied++
                    }
                }
            }
        }

        // Closed-source build: the only sanctioned source is the vendored BSD
        // libtorrent build (tooling/torrent_16k). Never fall back to downloading
        // the GPL-3.0 libtorrent_flutter prebuilts — that would reintroduce a GPL
        // dependency into the proprietary app. Hard-fail instead so the mismatch
        // is caught, not silently packaged.
        if (copied == 0) {
            throw GradleException(
                "[aurora-torrent] No BSD libtorrent .so found in " +
                    "tooling/torrent_16k/<abi>/liblibtorrent_flutter.so. " +
                    "Build it from tooling (see android/torrent/src/main/cpp) " +
                    "and place the arm64-v8a + armeabi-v7a binaries into " +
                    "tooling/torrent_16k. Refusing to download GPL libtorrent."
            )
        }
        logger.quiet("[aurora-torrent] Successfully extracted $copied BSD libtorrent .so file(s) into feature module jniLibs")
    }
}

android {
    namespace = "com.personal.aurora_downloader.torrent"
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
            jniLibs.srcDir(layout.buildDirectory.dir("extracted-torrent-jni/jni"))
        }
    }
}

dependencies {
    implementation(project(":app"))
}

tasks.named("preBuild").configure {
    dependsOn(extractTorrentJni)
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

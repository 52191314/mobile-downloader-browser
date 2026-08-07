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

        // arm64-v8a + armeabi-v7a only — must match the base module's ABI set
        // (x86_64 is not shipped; Play never installs it on ARM devices).
        val abis = listOf("arm64-v8a", "armeabi-v7a")
        var copied = 0

        fun findPrebuiltDir(): File? {
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

        // Fallback Attempt 4: Download prebuilt native zips if not found in pub cache
        if (copied == 0) {
            val version = "1.9.2"
            abis.forEach { abi ->
                val abiDestDir = File(destRoot, "jni/$abi")
                abiDestDir.mkdirs()
                val zipUrl = "https://github.com/ayman708-UX/libtorrent_flutter/releases/download/v$version/android-native-lib-$abi.zip"
                val cacheZip = outDir.get().asFile.resolve("download-cache/torrent-$abi.zip")
                cacheZip.parentFile.mkdirs()
                if (!cacheZip.exists()) {
                    logger.quiet("[aurora-torrent] Downloading prebuilt $abi libtorrent from $zipUrl")
                    runCatching {
                        URI(zipUrl).toURL().openStream().use { input: InputStream ->
                            cacheZip.outputStream().use { output -> input.copyTo(output) }
                        }
                    }
                }
                if (cacheZip.exists()) {
                    copy {
                        from(zipTree(cacheZip))
                        into(abiDestDir)
                        include("**/lib*.so")
                        eachFile { path = name }
                        includeEmptyDirs = false
                    }
                    val count = abiDestDir.listFiles()?.count { it.extension == "so" } ?: 0
                    copied += count
                }
            }
        }

        if (copied == 0) {
            throw GradleException("[aurora-torrent] Extracted no libtorrent .so files into feature module jniLibs")
        }
        logger.quiet("[aurora-torrent] Successfully extracted $copied libtorrent .so file(s) into feature module jniLibs")
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

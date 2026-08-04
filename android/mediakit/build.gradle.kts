import java.io.File
import java.io.InputStream
import java.net.URI

plugins {
    id("com.android.dynamic-feature")
    id("kotlin-android")
}

val extractMediakitJni by tasks.registering {
    val outDir = layout.buildDirectory.dir("extracted-mediakit-jni")
    outputs.dir(outDir)

    doLast {
        val destRoot = outDir.get().asFile
        destRoot.deleteRecursively()
        destRoot.mkdirs()

        // arm64-v8a + armeabi-v7a only — must match the base module's ABI set
        // (x86_64 is not shipped; Play never installs it on ARM devices).
        val abis = listOf("arm64-v8a", "armeabi-v7a")
        var copied = 0

        val mediaKitProject = findProject(":media_kit_libs_android_video")
        val mediaKitBuildDir = mediaKitProject?.layout?.buildDirectory?.orNull?.asFile
            ?: rootProject.layout.buildDirectory.dir("media_kit_libs_android_video").get().asFile

        val jarDirs = listOf(
            File(mediaKitBuildDir, "output"),
            File(mediaKitBuildDir, "v1.1.7")
        )

        val jarFiles = jarDirs.flatMap { dir ->
            if (dir.exists()) dir.listFiles()?.filter { it.extension == "jar" } ?: emptyList()
            else emptyList()
        }.distinctBy { it.name }

        if (jarFiles.isNotEmpty()) {
            jarFiles.forEach { jarFile ->
                copy {
                    from(zipTree(jarFile))
                    abis.forEach { abi ->
                        include("lib/$abi/*.so")
                    }
                    into(destRoot)
                }
            }

            val libDir = File(destRoot, "lib")
            val jniDir = File(destRoot, "jni")
            if (libDir.exists() && !jniDir.exists()) {
                libDir.renameTo(jniDir)
            }

            abis.forEach { abi ->
                val dir = File(destRoot, "jni/$abi")
                if (dir.isDirectory) {
                    copied += dir.listFiles()?.count { it.extension == "so" } ?: 0
                }
            }
        }

        // Fallback: Download JARs directly from GitHub release if local JARs not found
        if (copied == 0) {
            val version = "v1.1.7"
            abis.forEach { abi ->
                val abiDir = File(destRoot, "jni/$abi")
                abiDir.mkdirs()
                val jarUrl = "https://github.com/media-kit/libmpv-android-video-build/releases/download/$version/default-$abi.jar"
                val cacheJar = outDir.get().asFile.resolve("download-cache/mediakit-$abi.jar")
                cacheJar.parentFile.mkdirs()
                if (!cacheJar.exists()) {
                    logger.quiet("[aurora-mediakit] Downloading libmpv $abi jar from $jarUrl")
                    runCatching {
                        URI(jarUrl).toURL().openStream().use { input: InputStream ->
                            cacheJar.outputStream().use { output -> input.copyTo(output) }
                        }
                    }
                }
                if (cacheJar.exists()) {
                    copy {
                        from(zipTree(cacheJar))
                        into(abiDir)
                        include("lib/$abi/*.so")
                        eachFile { path = name }
                        includeEmptyDirs = false
                    }
                    val count = abiDir.listFiles()?.count { it.extension == "so" } ?: 0
                    copied += count
                }
            }
        }

        if (copied == 0) {
            throw GradleException("[aurora-mediakit] Extracted no MediaKit (libmpv) .so files into feature module jniLibs")
        }
        logger.quiet("[aurora-mediakit] Successfully extracted $copied media_kit .so file(s) into feature module jniLibs")
    }
}

android {
    namespace = "com.personal.aurora_downloader.mediakit"
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
            jniLibs.srcDir(layout.buildDirectory.dir("extracted-mediakit-jni/jni"))
        }
    }
}

dependencies {
    implementation(project(":app"))
}

tasks.named("preBuild").configure {
    dependsOn(extractMediakitJni)
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

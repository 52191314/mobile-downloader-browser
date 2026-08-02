package com.personal.aurora_downloader

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.ContentUris
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.media.MediaScannerConnection
import android.Manifest
import android.net.ConnectivityManager
import android.net.Network
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.util.Log
import android.util.Rational
import android.view.WindowManager
import android.widget.Toast
import androidx.core.app.ActivityCompat
import com.google.android.play.core.splitcompat.SplitCompat
import com.google.android.play.core.splitinstall.SplitInstallManager
import com.google.android.play.core.splitinstall.SplitInstallManagerFactory
import com.google.android.play.core.splitinstall.SplitInstallRequest
import com.google.android.play.core.splitinstall.SplitInstallStateUpdatedListener
import com.google.android.play.core.splitinstall.model.SplitInstallSessionStatus
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
// Play on-demand plugin runtime registration (forked plugins omit pluginClass
// so they are NOT registered at launch — see packages/ffmpeg_kit_flutter_new_min_gpl
// and packages/media_kit_libs_android_video).
import com.antonkarpenko.ffmpegkit.FFmpegKitFlutterPlugin
import com.alexmercerind.media_kit_libs_android_video.MediaKitLibsAndroidVideoPlugin
import android.provider.DocumentsContract
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebView
import androidx.webkit.UserAgentMetadata
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewFeature
import androidx.browser.customtabs.CustomTabsIntent
import androidx.browser.customtabs.CustomTabsClient
import android.graphics.BitmapFactory
import android.graphics.Color
import android.app.PendingIntent
import java.io.BufferedReader
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.nio.ByteBuffer
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(newBase)
        // Required so feature-module native libs (FFmpeg) resolve after on-demand install.
        try {
            SplitCompat.installActivity(this)
        } catch (e: Throwable) {
            Log.w(TAG, "SplitCompat.installActivity failed: ${e.message}")
        }
    }

    private val channelName = "aurora_downloader/public_downloads"
    private val networkChannelName = "aurora_downloader/network"
    private val fgServiceChannelName = "aurora_downloader/foreground_service"
    private val intentChannelName = "aurora_downloader/intent"
    private val pipChannelName = "aurora_downloader/pip"
    private var intentUrlChannel: MethodChannel? = null
    private var pipChannel: MethodChannel? = null
    private var pendingImportResult: MethodChannel.Result? = null
    private var pendingExportResult: MethodChannel.Result? = null
    private var pendingExportSourcePath: String? = null
    private var pendingPickUriResult: MethodChannel.Result? = null
    private var pendingPickDirectoryResult: MethodChannel.Result? = null
    private lateinit var nativeDownloadEngine: NativeDownloadEngine

    /// Feature-module plugins registered at runtime after SplitInstall
    /// (module names tracked so we never double-register in one process).
    private val _registeredFeaturePlugins = mutableSetOf<String>()

    companion object {
        private const val TAG = "AuroraMain"
        private const val PICK_IMPORT_FILE = 1001
        private const val REQUEST_EXPORT_FILE = 1002
        private const val REQUEST_PICK_EXPORT_URI = 1003
        private const val REQUEST_PICK_DIRECTORY = 1004
        private const val NOTIFICATION_PERMISSION_REQUEST_CODE = 2001
        private const val NETWORK_TAG = "AuroraNet"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // One-time migration: rename "Aurora Downloads" → "Aurora Downloader"
        migrateOldDownloadPath()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "publishFile" -> publishFile(call, result)
                    "openUri" -> openUri(call, result)
                    "renamePublishedFile" -> renamePublishedFile(call, result)
                    "shareFile" -> shareFile(call, result)
                    "shareContentUri" -> shareContentUri(call, result)
                    "pickImportFile" -> pickImportFile(result)
                    "openUrl" -> openUrl(call, result)
                    "openUrlInChrome" -> openUrlInChrome(call, result)
                    "shareUrl" -> shareUrl(call, result)
                    "remuxTsToMp4" -> remuxTsToMp4(call, result)
                    "listBackupFiles" -> listBackupFiles(call, result)
                    "deleteBackupFile" -> deleteBackupFile(call, result)
                    "readBackupFile" -> readBackupFile(call, result)
                    "exportFile" -> exportFile(call, result)
                    "selectExportUri" -> selectExportUri(call, result)
                    "writeExportFile" -> writeExportFile(call, result)
                    "selectExportDirectory" -> selectExportDirectory(result)
                    "writeExportFileToDirectory" -> writeExportFileToDirectory(call, result)
                    "listAutoBackups" -> listAutoBackups(result)
                    "restoreAutoBackupFile" -> restoreAutoBackupFile(call, result)
                    else -> result.notImplemented()
                }
            }
        // Bind the process to the default active network so Dart's
        // getaddrinfo() resolves DNS through the same network the WebView
        // and OkHttp-based apps use. Fixes "Failed host lookup" inside
        // Samsung Secure Folder and similar restricted network environments.
        // See NetworkBindingService for the Dart side.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, networkChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "bindProcessToNetwork" -> {
                        val bound = bindProcessToDefaultNetwork()
                        Log.d(NETWORK_TAG, "bindProcessToNetwork result=$bound")
                        result.success(bound)
                    }
                    "fetchUrl" -> fetchUrl(call, result)
                    "fetchBinaryUrl" -> fetchBinaryUrl(call, result)
                    "streamSegmentToFile" -> streamSegmentToFile(call, result)
                    else -> result.notImplemented()
                }
            }

        // Native download engine channel: OkHttp-backed chunk downloads
        // with HTTP/2, connection pooling, and cancellation.
        nativeDownloadEngine = NativeDownloadEngine()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aurora_downloader/native_download")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "downloadChunk" -> nativeDownloadEngine.downloadChunk(call, result)
                    "cancelChunk" -> nativeDownloadEngine.cancelChunk(call, result)
                    else -> result.notImplemented()
                }
            }

        // Foreground service channel: Dart tells us to start, update, or
        // stop the persistent notification that keeps downloads alive.
        // Also handles battery-optimisation and notification-permission
        // requests.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, fgServiceChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val count = call.argument<Int>("count") ?: 1
                        val intent = Intent(applicationContext, DownloadForegroundService::class.java).apply {
                            putExtra("action", "start")
                            putExtra("count", count)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(null)
                    }
                    "update" -> {
                        val count = call.argument<Int>("count") ?: 1
                        val fileName = call.argument<String>("fileName")
                        val percent = call.argument<Int>("percent") ?: 0
                        val intent = Intent(applicationContext, DownloadForegroundService::class.java).apply {
                            putExtra("action", "update")
                            putExtra("count", count)
                            if (fileName != null) putExtra("fileName", fileName)
                            putExtra("percent", percent)
                        }
                        startService(intent)
                        result.success(null)
                    }
                    "stop" -> {
                        stopService(Intent(applicationContext, DownloadForegroundService::class.java))
                        result.success(null)
                    }
                    "requestNotificationPermission" -> {
                        requestNotificationPermission()
                        result.success(null)
                    }
                    "areNotificationsEnabled" -> {
                        result.success(areNotificationsEnabled())
                    }
                    "requestBatteryOpt" -> {
                        val oemInfo = requestBatteryOptimizationExemption()
                        result.success(oemInfo)
                    }
                    "openOemAutostartPage" -> {
                        openOemAutostartPage()
                        result.success(null)
                    }
                    "isIgnoringBatteryOptimizations" -> {
                        val packageName = applicationContext.packageName
                        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                        val isIgnoring = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            pm.isIgnoringBatteryOptimizations(packageName)
                        } else {
                            true
                        }
                        result.success(isIgnoring)
                    }
                    else -> result.notImplemented()
                }
            }

        intentUrlChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, intentChannelName)
        intentUrlChannel?.setMethodCallHandler { call, result ->
            if (call.method == "getInitialUrl") {
                result.success(getInitialUrl())
            } else {
                result.notImplemented()
            }
        }

        // P5 audioExtract: Media3 Transformer bridge.
        // Extracts the audio track from a video file using Android's hardware-
        // accelerated Media3 Transformer, producing an AAC audio file.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aurora_downloader/audio_extract")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "extractAudio" -> extractAudio(call, result)
                    else -> result.notImplemented()
                }
            }

        // Capture-sheet video thumbnails: decode one frame out of a remote
        // stream. The scraped-poster paths (a <video poster> attribute, a
        // nearby <img>, the page's og:image) only cover pages that happen to
        // publish artwork, and none of them is a frame of the file the user is
        // about to download. This is.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aurora_downloader/media_thumbnail")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "frameAt" -> videoFrameAt(call, result)
                    else -> result.notImplemented()
                }
            }

        // Sensitive screens (vault): FLAG_SECURE blocks screenshots / recents.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aurora_downloader/secure_window")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setSecure" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        runOnUiThread {
                            if (enabled) {
                                window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            } else {
                                window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            }
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // Video player window brightness. Scoped to this window only, so the
        // left-edge brightness drag never changes the device-wide setting and
        // is dropped automatically when the player closes. Pass a negative
        // value to hand control back to the system.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aurora_downloader/player_window")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setBrightness" -> {
                        val value = call.argument<Double>("value") ?: -1.0
                        runOnUiThread {
                            val lp = window.attributes
                            lp.screenBrightness = if (value < 0) {
                                WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                            } else {
                                // Never fully black — 0 would look like a crash.
                                value.toFloat().coerceIn(0.01f, 1.0f)
                            }
                            window.attributes = lp
                            result.success(null)
                        }
                    }
                    "getBrightness" -> {
                        runOnUiThread {
                            val override = window.attributes.screenBrightness
                            val value = if (override >= 0f) {
                                override.toDouble()
                            } else {
                                // No window override yet — seed from the system level
                                // so the first drag starts where the user already is.
                                try {
                                    android.provider.Settings.System.getInt(
                                        contentResolver,
                                        android.provider.Settings.System.SCREEN_BRIGHTNESS,
                                    ) / 255.0
                                } catch (e: android.provider.Settings.SettingNotFoundException) {
                                    0.5
                                }
                            }
                            result.success(value.coerceIn(0.0, 1.0))
                        }
                    }
                    // Keeps the display awake while a video is on screen.
                    // Scoped to this window and cleared when the player closes,
                    // so it can never leak into the rest of the app the way a
                    // device-wide wake lock would — and it needs no extra
                    // permission.
                    "setKeepScreenOn" -> {
                        val on = call.argument<Boolean>("value") ?: false
                        runOnUiThread {
                            if (on) {
                                window.addFlags(
                                    WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                                )
                            } else {
                                window.clearFlags(
                                    WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                                )
                            }
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // -------------------------------------------------------------------
        // Play Feature Delivery — on-demand module install for FFmpeg.
        // Uses SplitInstallManager to download the :ffmpeg dynamic feature
        // module on first Ultra-gated FFmpeg Studio use.
        // Only active for play-channel AAB builds; no-op for APK/fat builds.
        // -------------------------------------------------------------------
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aurora_downloader/feature_delivery")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getModuleStatus" -> {
                        val moduleName = call.argument<String>("module") ?: "ffmpeg"
                        try {
                            val manager: SplitInstallManager =
                                SplitInstallManagerFactory.create(applicationContext)
                            val sessions = manager.installedModules
                            result.success(sessions.contains(moduleName))
                        } catch (e: Exception) {
                            // Feature delivery not available (APK build, emulator, etc.)
                            result.success(true) // Assume installed (fallback)
                        }
                    }
                    "startInstall" -> {
                        val moduleName = call.argument<String>("module") ?: "ffmpeg"
                        val channel = MethodChannel(
                            flutterEngine.dartExecutor.binaryMessenger,
                            "aurora_downloader/feature_delivery_progress"
                        )
                        try {
                            val manager: SplitInstallManager =
                                SplitInstallManagerFactory.create(applicationContext)

                            // Register a listener for install progress.
                            // We use an object expression to avoid the self-reference
                            // issue (a lambda can't reference its own variable).
                            val installListener = object : SplitInstallStateUpdatedListener {
                                override fun onStateUpdate(state: com.google.android.play.core.splitinstall.SplitInstallSessionState) {
                                    val statusCode = state.status()
                                    val progress = if (state.totalBytesToDownload() > 0) {
                                        state.bytesDownloaded().toFloat() / state.totalBytesToDownload().toFloat()
                                    } else {
                                        0f
                                    }
                                    channel.invokeMethod("onProgress", mapOf(
                                        "status" to statusCode,
                                        "progress" to progress,
                                        "module" to moduleName,
                                    ))
                                    if (statusCode == SplitInstallSessionStatus.INSTALLED ||
                                        statusCode == SplitInstallSessionStatus.FAILED) {
                                        manager.unregisterListener(this)
                                    }
                                }
                            }
                            manager.registerListener(installListener)

                            val request = SplitInstallRequest.newBuilder()
                                .addModule(moduleName)
                                .build()

                            manager.startInstall(request)
                                .addOnSuccessListener { sessionId ->
                                    Log.d(TAG, "SplitInstall started: session=$sessionId module=$moduleName")
                                    result.success(sessionId)
                                }
                                .addOnFailureListener { exception ->
                                    Log.e(TAG, "SplitInstall failed: ${exception.message}")
                                    result.error("install_failed", exception.message, null)
                                }
                        } catch (e: Exception) {
                            Log.e(TAG, "SplitInstall exception", e)
                            result.error("install_error", e.message, null)
                        }
                    }
                    "cancelInstall" -> {
                        val sessionId = call.argument<Int>("sessionId") ?: 0
                        try {
                            val manager: SplitInstallManager =
                                SplitInstallManagerFactory.create(applicationContext)
                            manager.cancelInstall(sessionId)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("cancel_error", e.message, null)
                        }
                    }
                    "deferredInstall" -> {
                        val moduleName = call.argument<String>("module") ?: "ffmpeg"
                        try {
                            val manager: SplitInstallManager =
                                SplitInstallManagerFactory.create(applicationContext)
                            manager.deferredInstall(listOf(moduleName))
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("deferred_error", e.message, null)
                        }
                    }
                    "registerPlugin" -> {
                        // Registers the native plugin for an on-demand module in
                        // THIS process, after SplitInstall completed and
                        // SplitCompat made the module's .so loadable. Without this
                        // the plugin classes are never registered (they were
                        // stripped from GeneratedPluginRegistrant via the fork).
                        val moduleName = call.argument<String>("module") ?: "ffmpeg"
                        result.success(registerFeaturePlugin(moduleName))
                    }
                    else -> result.notImplemented()
                }
            }

        // Picture-in-Picture (PiP) channel
        pipChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, pipChannelName)
        pipChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "enterPip" -> {
                    val width = call.argument<Int>("width") ?: 16
                    val height = call.argument<Int>("height") ?: 9
                    result.success(enterPipMode(width, height))
                }
                "isPipSupported" -> {
                    result.success(isPipSupported())
                }
                else -> result.notImplemented()
            }
        }

        // -------------------------------------------------------------------
        // WebView Stealth — override Sec-CH-UA Client Hints to replace
        // "Android WebView" with "Google Chrome" in the brand list.
        // Uses AndroidX WebKit's WebSettingsCompat.setUserAgentMetadata().
        // -------------------------------------------------------------------
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aurora_downloader/webview_stealth")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "applyStealthMetadata" -> {
                        val chromeVersion = call.argument<String>("chromeVersion") ?: "131.0.6778.135"
                        runOnUiThread {
                            val count = applyStealthMetadataToAllWebViews(chromeVersion)
                            Log.d(TAG, "applyStealthMetadata: applied to $count WebView(s), chromeVersion=$chromeVersion")
                            result.success(count > 0)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // -------------------------------------------------------------------
        // Chrome Custom Tabs — in-app browser overlay with "Sniff & Download"
        // toolbar button for WAF-blocked hosts (xchina.co).
        // -------------------------------------------------------------------
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aurora_downloader/cct")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openCustomTab" -> openCustomTab(call, result)
                    "isCustomTabSupported" -> result.success(isCustomTabSupported())
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Registers the native plugin that backs an on-demand feature module in the
     * current process.
     *
     * The `ffmpeg_kit` and `media_kit_libs_android_video` plugins are forked
     * locally WITHOUT an Android `pluginClass`, so the base app never registers
     * them at launch (their static `System.loadLibrary(...)` calls would crash
     * before the on-demand module is installed). After [SplitInstallManager]
     * reports the module installed, the Dart side calls back through
     * `aurora_downloader/feature_delivery` → `registerPlugin`, which:
     *   1. Re-runs [SplitCompat.install] so the module's native libs become
     *      loadable via System.loadLibrary in this process.
     *   2. Adds the plugin instance to the Flutter engine, triggering
     *      `onAttachedToEngine` — which now finds its native libs present.
     */
    private fun registerFeaturePlugin(moduleName: String): Boolean {
        return try {
            val engine = flutterEngine ?: return false
            // Make the just-installed split's native libs loadable now.
            SplitCompat.install(this)
            if (!_registeredFeaturePlugins.add(moduleName)) {
                return true // Already registered in this process.
            }
            when (moduleName) {
                "ffmpeg" -> {
                    engine.plugins.add(FFmpegKitFlutterPlugin())
                    true
                }
                "mediakit" -> {
                    engine.plugins.add(MediaKitLibsAndroidVideoPlugin())
                    true
                }
                else -> {
                    Log.w(TAG, "registerPlugin: unknown module $moduleName")
                    false
                }
            }
        } catch (e: Throwable) {
            Log.e(TAG, "registerPlugin($moduleName) failed", e)
            false
        }
    }

    /**
     * P5 audioExtract: Uses Media3 Transformer to extract audio from a video
     * file and save as AAC.
     *
     * Arguments:
     *   - inputPath: String — full path to the source video file
     *   - outputPath: String — full path for the output audio file
     *
     * Returns the output path on success, or an error on failure.
     */
    /**
     * Two threads, because [MediaMetadataRetriever] on a remote URL is a
     * network read followed by a hardware decode. More would put a list scroll
     * in competition with itself for the same decoder; fewer would make a
     * screenful of rows resolve one at a time. Dart also caps its own in-flight
     * requests, so this is the second of two bounds, not the only one.
     */
    private val thumbnailExecutor: ExecutorService by lazy {
        Executors.newFixedThreadPool(2)
    }

    /**
     * Decodes a single frame of the video at `url` and returns it as JPEG bytes,
     * or null when the source cannot be read.
     *
     * `headers` matters as much as the URL: these links come out of a browsing
     * session, so without the referer and cookies the sniffer captured, most
     * CDNs answer 403 and no frame exists to decode.
     *
     * Failure is reported as a null success rather than an error. A CDN that
     * refuses range requests, a `blob:` URL that was never a real stream, a
     * codec the device cannot decode -- none of these are faults worth
     * surfacing, and the caller simply keeps its type icon.
     */
    private fun videoFrameAt(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")?.trim() ?: ""
        if (url.isEmpty()) {
            result.error("bad_args", "url is required", null)
            return
        }
        val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
        val atMs = (call.argument<Int>("atMs") ?: 0).toLong()
        val maxWidth = (call.argument<Int>("maxWidth") ?: 320).coerceIn(64, 1080)

        thumbnailExecutor.execute {
            var bytes: ByteArray? = null
            val retriever = MediaMetadataRetriever()
            try {
                if (headers.isEmpty()) {
                    retriever.setDataSource(url)
                } else {
                    retriever.setDataSource(url, headers)
                }

                // t=0 is a black frame, a fade-in or a distributor logo on a
                // great many files. Sample a tenth of the way in instead, and
                // cap that so a two-hour film is not read minutes deep.
                val durationMs = retriever
                    .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                    ?.toLongOrNull() ?: 0L
                val targetUs = 1000L * when {
                    atMs > 0 -> atMs
                    durationMs > 0 -> (durationMs / 10).coerceAtMost(10_000L)
                    else -> 0L
                }

                val frame: Bitmap? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                    // Scales during decode, so a 4K keyframe never exists at
                    // full size in memory (3840x2160 ARGB_8888 is ~33 MB).
                    retriever.getScaledFrameAtTime(
                        targetUs,
                        MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                        maxWidth,
                        maxWidth * 9 / 16
                    )
                } else {
                    // API 24-26 has no scaling variant. Downscale immediately
                    // and drop the full-size bitmap.
                    val full = retriever.getFrameAtTime(
                        targetUs,
                        MediaMetadataRetriever.OPTION_CLOSEST_SYNC
                    )
                    if (full == null) null else {
                        try {
                            if (full.width <= maxWidth) full else {
                                val h = (full.height.toLong() * maxWidth / full.width)
                                    .toInt().coerceAtLeast(1)
                                Bitmap.createScaledBitmap(full, maxWidth, h, true)
                            }
                        } finally {
                            // createScaledBitmap can hand back the original.
                            if (full.width > maxWidth) full.recycle()
                        }
                    }
                }

                if (frame != null) {
                    val out = ByteArrayOutputStream()
                    frame.compress(Bitmap.CompressFormat.JPEG, 80, out)
                    bytes = out.toByteArray()
                    frame.recycle()
                }
            } catch (e: Throwable) {
                // Includes OutOfMemoryError on a hostile frame size, which is
                // still not a reason to take the app down over a thumbnail.
                Log.d(TAG, "Frame decode failed for $url: ${e.message}")
            } finally {
                try {
                    retriever.release()
                } catch (_: Throwable) {
                }
            }

            val payload = bytes
            runOnUiThread { result.success(payload) }
        }
    }

    private fun extractAudio(call: MethodCall, result: MethodChannel.Result) {
        val inputPath = call.argument<String>("inputPath") ?: ""
        val outputPath = call.argument<String>("outputPath") ?: ""
        if (inputPath.isBlank() || outputPath.isBlank()) {
            result.error("bad_args", "inputPath and outputPath are required", null)
            return
        }

        try {
            val inputFile = File(inputPath)
            if (!inputFile.exists()) {
                result.error("file_not_found", "Input file not found: $inputPath", null)
                return
            }

            val outputFile = File(outputPath)
            // Ensure parent directory exists.
            outputFile.parentFile?.mkdirs()

            val transformer = androidx.media3.transformer.Transformer.Builder(this)
                .setAudioMimeType(androidx.media3.common.MimeTypes.AUDIO_AAC)
                .build()

            val mediaItem = androidx.media3.common.MediaItem.fromUri(Uri.fromFile(inputFile))
            val editedMediaItem = androidx.media3.transformer.EditedMediaItem.Builder(mediaItem).build()
            val sequence = androidx.media3.transformer.EditedMediaItemSequence.Builder(listOf(editedMediaItem)).build()
            val composition = androidx.media3.transformer.Composition.Builder(sequence).build()

            transformer.addListener(object : androidx.media3.transformer.Transformer.Listener {
                override fun onCompleted(
                    composition: androidx.media3.transformer.Composition,
                    exportResult: androidx.media3.transformer.ExportResult
                ) {
                    Log.d(TAG, "Audio extract completed: $outputPath")
                    result.success(outputPath)
                }

                override fun onError(
                    composition: androidx.media3.transformer.Composition,
                    exportResult: androidx.media3.transformer.ExportResult,
                    error: androidx.media3.transformer.ExportException
                ) {
                    Log.e(TAG, "Audio extract failed: ${error.message}", error)
                    result.error("extract_failed", error.message, null)
                }
            })

            transformer.start(composition, outputPath)
        } catch (e: Exception) {
            Log.e(TAG, "Audio extract exception", e)
            result.error("extract_error", e.message, null)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val url = getInitialUrl()
        if (url != null) {
            intentUrlChannel?.invokeMethod("onNewUrl", url)
        }
    }

    private fun getInitialUrl(): String? {
        val intent = intent ?: return null
        if (Intent.ACTION_VIEW == intent.action || "aurora.ACTION_SNIFF_AND_DOWNLOAD" == intent.action) {
            val url = intent.getStringExtra("url") ?: intent.data?.toString()
            if (url != null) {
                intent.action = null
                intent.data = null
                return url
            }
        } else if (Intent.ACTION_SEND == intent.action) {
            val text = intent.getStringExtra(Intent.EXTRA_TEXT)
            if (!text.isNullOrBlank()) {
                intent.action = null
                return text
            }
        }
        return null
    }

    /**
     * Fetches a URL using Android's native [HttpURLConnection] which
     * produces a TLS fingerprint (JA3) that Cloudflare and similar
     * WAFs consider legitimate — unlike Dart's [http.Client] which
     * triggers Cloudflare challenge pages.  Also applies the same
     * browser-like headers as the manual-paste path.
     */
    private fun fetchUrl(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url") ?: ""
        if (url.isBlank()) {
            result.error("bad_args", "url is required", null)
            return
        }
        val referer = call.argument<String>("referer") ?: ""
        val origin = call.argument<String>("origin") ?: ""
        val userAgent = call.argument<String>("userAgent") ?:
            "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
        val cookieHeader = call.argument<String>("cookie") ?: ""

        // Merge cookies from Android's system CookieManager (set by the
        // WebView when the user visited surrit.com) with any explicit
        // cookie header passed from Dart.  The WebView's cookies are
        // what makes 1DM's requests succeed while ours fail.
        val mergedCookies = buildString {
            // 1. System WebView cookies for this domain
            try {
                val webCookies = CookieManager.getInstance().getCookie(url)
                if (!webCookies.isNullOrBlank()) {
                    append(webCookies)
                }
            } catch (_: Exception) {}
            // 2. Explicit cookie header from Dart (if any)
            if (isNotEmpty() && cookieHeader.isNotBlank()) {
                append("; ")
            }
            if (cookieHeader.isNotBlank()) {
                append(cookieHeader)
            }
        }

        try {
            val connection = URL(url).openConnection() as HttpURLConnection
            connection.requestMethod = "GET"
            connection.setRequestProperty("User-Agent", userAgent)
            if (referer.isNotBlank()) connection.setRequestProperty("Referer", referer)
            if (origin.isNotBlank()) connection.setRequestProperty("Origin", origin)
            if (mergedCookies.isNotBlank()) connection.setRequestProperty("Cookie", mergedCookies)
            connection.setRequestProperty("Accept", "*/*")
            connection.setRequestProperty("Accept-Language", "en-US,en;q=0.9")
            connection.setRequestProperty("Accept-Encoding", "gzip, deflate, br")
            connection.setRequestProperty("Sec-Fetch-Dest", "empty")
            connection.setRequestProperty("Sec-Fetch-Mode", "cors")
            connection.setRequestProperty("Sec-Fetch-Site", "same-origin")
            connection.connectTimeout = 15000
            connection.readTimeout = 15000
            connection.instanceFollowRedirects = true

            val statusCode = connection.responseCode
            val body = if (statusCode in 200..399) {
                BufferedReader(InputStreamReader(connection.inputStream)).readText()
            } else {
                connection.errorStream?.let { BufferedReader(InputStreamReader(it)).readText() } ?: ""
            }
            connection.disconnect()

            result.success(mapOf(
                "statusCode" to statusCode,
                "body" to body
            ))
        } catch (e: Exception) {
            Log.w(NETWORK_TAG, "fetchUrl failed: ${e.message}")
            result.error("fetch_failed", e.message, null)
        }
    }

    /**
     * Fetches a binary resource (HLS .ts segment, DASH .m4s, etc.) through
     * Android's native HttpURLConnection with **media-player request headers**
     * (Accept: video/MP2T, Sec-Fetch-Dest: video, optional Range). This is the
     * fingerprint a real video player uses — unlike [fetchUrl] which sends
     * XHR-style headers (Sec-Fetch-Dest: empty). Some CDNs (e.g. TikTok CDN)
     * serve placeholder/PNG content to non-media requests, so segment
     * downloads must look like a media player request to get real video.
     *
     * Returns `{statusCode: int, data: String(base64)}` on success or
     * `{statusCode: int, data: ""}` on an error response, or `null` on a
     * thrown exception. Never throws to the Dart side.
     */
    private fun fetchBinaryUrl(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url") ?: ""
        if (url.isBlank()) {
            result.error("bad_args", "url is required", null)
            return
        }
        val referer = call.argument<String>("referer") ?: ""
        val origin = call.argument<String>("origin") ?: ""
        val userAgent = call.argument<String>("userAgent") ?:
            "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
        val cookieHeader = call.argument<String>("cookie") ?: ""
        val rangeHeader = call.argument<String>("range") ?: ""

        val mergedCookies = buildString {
            try {
                val webCookies = CookieManager.getInstance().getCookie(url)
                if (!webCookies.isNullOrBlank()) {
                    append(webCookies)
                }
            } catch (_: Exception) {}
            if (isNotEmpty() && cookieHeader.isNotBlank()) {
                append("; ")
            }
            if (cookieHeader.isNotBlank()) {
                append(cookieHeader)
            }
        }

        try {
            val connection = URL(url).openConnection() as HttpURLConnection
            connection.requestMethod = "GET"
            connection.setRequestProperty("User-Agent", userAgent)
            if (referer.isNotBlank()) connection.setRequestProperty("Referer", referer)
            if (origin.isNotBlank()) connection.setRequestProperty("Origin", origin)
            if (mergedCookies.isNotBlank()) connection.setRequestProperty("Cookie", mergedCookies)
            // Media-player fingerprint (NOT XHR):
            connection.setRequestProperty("Accept", "video/MP2T, video/mp4, application/vnd.apple.mpegurl, */*")
            connection.setRequestProperty("Sec-Fetch-Dest", "video")
            connection.setRequestProperty("Sec-Fetch-Mode", "no-cors")
            connection.setRequestProperty("Sec-Fetch-Site", "cross-site")
            connection.setRequestProperty("Accept-Language", "en-US,en;q=0.9")
            if (rangeHeader.isNotBlank()) connection.setRequestProperty("Range", rangeHeader)
            connection.connectTimeout = 30000
            connection.readTimeout = 30000
            connection.instanceFollowRedirects = true

            val statusCode = connection.responseCode
            val inputStream = if (statusCode in 200..399) {
                connection.inputStream
            } else {
                connection.errorStream
            }
            val bytes = inputStream?.readBytes() ?: ByteArray(0)
            inputStream?.close()
            connection.disconnect()

            val base64 = android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)
            result.success(mapOf(
                "statusCode" to statusCode,
                "data" to base64
            ))
        } catch (e: Exception) {
            Log.w(NETWORK_TAG, "fetchBinaryUrl failed: ${e.message}")
            result.error("fetch_failed", e.message, null)
        }
    }

    /**
     * Streams an HLS segment file (or any binary resource) directly to a file
     * path on disk using Android's native [HttpURLConnection], avoiding the
     * base64 encode/decode overhead and full-segment memory buffering of
     * [fetchBinaryUrl].
     *
     * This is the successor to [fetchBinaryUrl] for HLS segment downloads:
     * the native side opens an HTTP connection with media-player fingerprint
     * headers (Sec-Fetch-Dest: video), streams the response body directly to
     * the target file via a 64 KB buffer loop, and returns only the status
     * code + byte count — no base64, no full-segment memory allocation.
     *
     * Returns `{statusCode: int, bytesWritten: long}` on success, or
     * `{statusCode: int, bytesWritten: 0}` for a non-2xx response, or
     * `null` on a thrown exception.  Never throws to the Dart side.
     */
    private fun streamSegmentToFile(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url") ?: ""
        if (url.isBlank()) {
            result.error("bad_args", "url is required", null)
            return
        }
        val filePath = call.argument<String>("filePath") ?: ""
        if (filePath.isBlank()) {
            result.error("bad_args", "filePath is required", null)
            return
        }
        val referer = call.argument<String>("referer") ?: ""
        val origin = call.argument<String>("origin") ?: ""
        val userAgent = call.argument<String>("userAgent") ?:
            "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
        val cookieHeader = call.argument<String>("cookie") ?: ""
        val rangeHeader = call.argument<String>("range") ?: ""

        // Background thread: multi‑MB segments must not block the platform channel.
        Thread {
            try {
                val mergedCookies = buildString {
                    try {
                        val webCookies = CookieManager.getInstance().getCookie(url)
                        if (!webCookies.isNullOrBlank()) append(webCookies)
                    } catch (_: Exception) {}
                    if (isNotEmpty() && cookieHeader.isNotBlank()) append("; ")
                    if (cookieHeader.isNotBlank()) append(cookieHeader)
                }

                val connection = URL(url).openConnection() as HttpURLConnection
                connection.requestMethod = "GET"
                connection.setRequestProperty("User-Agent", userAgent)
                if (referer.isNotBlank()) connection.setRequestProperty("Referer", referer)
                if (origin.isNotBlank()) connection.setRequestProperty("Origin", origin)
                if (mergedCookies.isNotBlank()) connection.setRequestProperty("Cookie", mergedCookies)
                // Media-player fingerprint (NOT XHR) — same class of request 1DM uses.
                connection.setRequestProperty("Accept", "video/MP2T, video/mp4, application/octet-stream, */*")
                connection.setRequestProperty("Sec-Fetch-Dest", "video")
                connection.setRequestProperty("Sec-Fetch-Mode", "no-cors")
                connection.setRequestProperty("Sec-Fetch-Site", "cross-site")
                connection.setRequestProperty("Accept-Language", "en-US,en;q=0.9")
                // identity: avoid brotli/gzip wrapping binary TS segments.
                connection.setRequestProperty("Accept-Encoding", "identity")
                if (rangeHeader.isNotBlank()) connection.setRequestProperty("Range", rangeHeader)
                connection.connectTimeout = 30000
                connection.readTimeout = 120000
                connection.instanceFollowRedirects = true

                val statusCode = connection.responseCode
                val inputStream = if (statusCode in 200..399) {
                    connection.inputStream
                } else {
                    connection.errorStream
                }

                var bytesWritten = 0L
                val outFile = File(filePath)
                if (statusCode in 200..399 && inputStream != null) {
                    outFile.parentFile?.mkdirs()
                    val buffer = ByteArray(65536)
                    FileOutputStream(outFile).use { outputStream ->
                        var read: Int
                        while (inputStream.read(buffer).also { read = it } != -1) {
                            outputStream.write(buffer, 0, read)
                            bytesWritten += read
                        }
                    }
                    inputStream.close()
                } else {
                    // Don't leave a partial/error body as a "segment".
                    try { if (outFile.exists()) outFile.delete() } catch (_: Exception) {}
                    try { inputStream?.close() } catch (_: Exception) {}
                }
                connection.disconnect()

                Log.d(
                    NETWORK_TAG,
                    "streamSegmentToFile status=$statusCode bytes=$bytesWritten cookies=${mergedCookies.isNotBlank()}",
                )
                runOnUiThread {
                    result.success(
                        mapOf(
                            "statusCode" to statusCode,
                            "bytesWritten" to bytesWritten,
                        ),
                    )
                }
            } catch (e: Exception) {
                Log.w(NETWORK_TAG, "streamSegmentToFile failed: ${e.message}")
                try { File(filePath).delete() } catch (_: Exception) {}
                runOnUiThread {
                    result.error("stream_failed", e.message, null)
                }
            }
        }.start()
    }

    /**
     * Binds the calling process to Android's currently active default
     * network so that subsequent sockets (including those opened by
     * Dart's `dart:io` HTTP client) resolve DNS through the same
     * resolver the WebView uses. Returns `true` on success.
     *
     * Requires `ConnectivityManager.bindProcessToNetwork(Network)` which
     * is available from API 23 (Marshmallow). `minSdk` for this app is
     * 24, so no legacy fallback is needed; older devices get a `true`
     * no-op so the Dart caller does not surface an error.
     */
    private fun bindProcessToDefaultNetwork(): Boolean {
        return try {
            val cm = applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE)
                    as? ConnectivityManager ?: return false
            val active: Network? = cm.activeNetwork
            if (active == null) {
                Log.d(NETWORK_TAG, "no active network yet")
                return false
            }
            val ok = cm.bindProcessToNetwork(active)
            Log.d(NETWORK_TAG, "bound to network=$active ok=$ok")
            ok
        } catch (se: SecurityException) {
            Log.w(NETWORK_TAG, "SecurityException binding process to network: ${se.message}")
            false
        } catch (e: Exception) {
            Log.w(NETWORK_TAG, "bindProcessToNetwork failed: ${e.message}")
            false
        }
    }

    private fun mimeTypeForFileName(name: String): String {
        val lower = name.lowercase(Locale.US)
        return when {
            lower.endsWith(".mp4") || lower.endsWith(".m4v") -> "video/mp4"
            lower.endsWith(".webm") -> "video/webm"
            lower.endsWith(".mkv") -> "video/x-matroska"
            lower.endsWith(".ts") -> "video/mp2t"
            lower.endsWith(".mp3") -> "audio/mpeg"
            lower.endsWith(".m4a") -> "audio/mp4"
            lower.endsWith(".aac") -> "audio/aac"
            lower.endsWith(".wav") -> "audio/wav"
            lower.endsWith(".ogg") || lower.endsWith(".opus") -> "audio/ogg"
            lower.endsWith(".jpg") || lower.endsWith(".jpeg") -> "image/jpeg"
            lower.endsWith(".png") -> "image/png"
            lower.endsWith(".gif") -> "image/gif"
            lower.endsWith(".webp") -> "image/webp"
            lower.endsWith(".pdf") -> "application/pdf"
            lower.endsWith(".zip") -> "application/zip"
            lower.endsWith(".json") -> "application/json"
            lower.endsWith(".txt") || lower.endsWith(".log") -> "text/plain"
            lower.endsWith(".vtt") -> "text/vtt"
            lower.endsWith(".srt") -> "application/x-subrip"
            else -> {
                val guessed = android.webkit.MimeTypeMap.getSingleton()
                    .getMimeTypeFromExtension(lower.substringAfterLast('.', ""))
                guessed ?: "application/octet-stream"
            }
        }
    }

    /** Launch the system share sheet for an existing content:// (or file) URI. */
    private fun launchShareChooser(uri: Uri, mimeType: String, title: String) {
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = mimeType
            putExtra(Intent.EXTRA_STREAM, uri)
            clipData = android.content.ClipData.newRawUri(title, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(Intent.createChooser(intent, title))
    }

    private fun shareContentUri(call: MethodCall, result: MethodChannel.Result) {
        val uriStr = call.argument<String>("uri")
        val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
        val title = call.argument<String>("title") ?: "Share"
        if (uriStr.isNullOrBlank()) {
            result.error("bad_args", "uri is required.", null)
            return
        }
        try {
            launchShareChooser(Uri.parse(uriStr), mimeType, title)
            result.success(null)
        } catch (error: Exception) {
            result.error("share_failed", error.message, null)
        }
    }

    private fun shareFile(call: MethodCall, result: MethodChannel.Result) {
        val filePath = call.argument<String>("filePath")
        if (filePath.isNullOrBlank()) {
            result.error("bad_args", "filePath is required.", null)
            return
        }
        val source = File(filePath)
        if (!source.exists() || !source.isFile) {
            result.error("missing_file", "File not found: $filePath", null)
            return
        }

        val mimeType = call.argument<String>("mimeType")
            ?.takeIf { it.isNotBlank() }
            ?: mimeTypeForFileName(source.name)

        val resolver = applicationContext.contentResolver

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, source.name)
                    put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                    put(MediaStore.MediaColumns.RELATIVE_PATH, "Download/Aurora Downloader")
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                    ?: throw IllegalStateException("Could not create MediaStore item for sharing.")
                try {
                    resolver.openOutputStream(uri)?.use { output ->
                        FileInputStream(source).use { input -> input.copyTo(output) }
                    } ?: throw IllegalStateException("Could not open output stream.")

                    val done = ContentValues().apply {
                        put(MediaStore.MediaColumns.IS_PENDING, 0)
                    }
                    resolver.update(uri, done, null, null)
                    launchShareChooser(uri, mimeType, source.name)
                    result.success(null)
                } catch (error: Exception) {
                    resolver.delete(uri, null, null)
                    throw error
                }
            } else {
                // Pre-Q: copy into public Downloads then share via MediaScanner URI.
                val downloadsDir =
                    Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                val destDir = File(downloadsDir, "Aurora Downloader")
                if (!destDir.exists()) destDir.mkdirs()
                val destFile = File(destDir, source.name)
                source.copyTo(destFile, overwrite = true)
                MediaScannerConnection.scanFile(
                    this,
                    arrayOf(destFile.absolutePath),
                    arrayOf(mimeType),
                ) { path, uri ->
                    try {
                        val shareUri = uri ?: Uri.fromFile(File(path))
                        runOnUiThread {
                            try {
                                launchShareChooser(shareUri, mimeType, source.name)
                                result.success(null)
                            } catch (error: Exception) {
                                result.error("share_failed", error.message, null)
                            }
                        }
                    } catch (error: Exception) {
                        runOnUiThread {
                            result.error("share_failed", error.message, null)
                        }
                    }
                }
            }
        } catch (error: Exception) {
            result.error("share_failed", error.message, null)
        }
    }

    private fun getDisplayName(uri: Uri): String? {
        var name: String? = null
        try {
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (index != -1) {
                        name = cursor.getString(index)
                    }
                }
            }
        } catch (e: Exception) {
            Log.e("MainActivity", "Failed to query display name", e)
        }
        return name
    }

    private fun pickImportFile(result: MethodChannel.Result) {
        pendingImportResult = result
        // Do NOT set EXTRA_MIME_TYPES. Many DocumentsUI builds treat that list as an
        // exclusive allow-list, and `*/*` inside it is ignored — so unknown extensions
        // like `.1dmbak` (often application/zip or untyped) never appear. type=*/*
        // alone lets the user pick any file; the Dart side validates the content.
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
        }
        try {
            startActivityForResult(intent, PICK_IMPORT_FILE)
        } catch (error: ActivityNotFoundException) {
            // Fallback: some OEM builds only register GET_CONTENT for broad picks.
            try {
                val fallback = Intent(Intent.ACTION_GET_CONTENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                }
                startActivityForResult(fallback, PICK_IMPORT_FILE)
            } catch (error2: ActivityNotFoundException) {
                result.error("no_activity", "No file picker available.", null)
                pendingImportResult = null
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == PICK_IMPORT_FILE && pendingImportResult != null) {
            if (resultCode == Activity.RESULT_OK && data?.data != null) {
                val uri = data.data!!
                try {
                    val displayName = getDisplayName(uri) ?: ""
                    val is1dmBak = displayName.lowercase().endsWith(".1dmbak")
                    val ext = if (is1dmBak) ".1dmbak" else ".json"
                    val destFile = File(filesDir, "imported_library_${System.currentTimeMillis()}$ext")
                    contentResolver.openInputStream(uri)?.use { input ->
                        FileOutputStream(destFile).use { output -> input.copyTo(output) }
                    }
                    pendingImportResult?.success(destFile.absolutePath)
                } catch (error: Exception) {
                    pendingImportResult?.error("read_failed", error.message, null)
                }
            } else {
                pendingImportResult?.success(null)
            }
            pendingImportResult = null
        } else if (requestCode == REQUEST_EXPORT_FILE && pendingExportResult != null) {
            // pendingExportSourcePath is either an absolute filesystem path or a
            // content:// URI (after publish, the private app-data copy is deleted).
            val sourceRef = pendingExportSourcePath
            if (resultCode == Activity.RESULT_OK && data?.data != null && sourceRef != null) {
                val destUri = data.data!!
                try {
                    contentResolver.openOutputStream(destUri)?.use { output ->
                        openReadableSource(sourceRef).use { input -> input.copyTo(output) }
                    } ?: throw IllegalStateException("Could not open export destination.")
                    pendingExportResult?.success(true)
                } catch (error: Exception) {
                    pendingExportResult?.error("write_failed", error.message, null)
                }
            } else {
                pendingExportResult?.success(false)
            }
            pendingExportResult = null
            pendingExportSourcePath = null
        } else if (requestCode == REQUEST_PICK_EXPORT_URI && pendingPickUriResult != null) {
            if (resultCode == Activity.RESULT_OK && data?.data != null) {
                val uri = data.data!!
                val takeFlags = Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION
                try {
                    contentResolver.takePersistableUriPermission(uri, takeFlags)
                } catch (_: Exception) {}
                pendingPickUriResult?.success(uri.toString())
            } else {
                pendingPickUriResult?.success(null)
            }
            pendingPickUriResult = null
        } else if (requestCode == REQUEST_PICK_DIRECTORY && pendingPickDirectoryResult != null) {
            if (resultCode == Activity.RESULT_OK && data?.data != null) {
                val uri = data.data!!
                val takeFlags = Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION
                try {
                    contentResolver.takePersistableUriPermission(uri, takeFlags)
                } catch (_: Exception) {}
                pendingPickDirectoryResult?.success(uri.toString())
            } else {
                pendingPickDirectoryResult?.success(null)
            }
            pendingPickDirectoryResult = null
        }
    }

    private fun openUrl(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        if (url.isNullOrBlank()) {
            result.error("bad_args", "url is required.", null)
            return
        }
        try {
            val intent = buildViewIntent(url)
            startActivity(intent)
            result.success(null)
        } catch (_: ActivityNotFoundException) {
            // intent:// often embeds a browser_fallback_url — try that next.
            val fallback = extractBrowserFallbackUrl(url)
            if (!fallback.isNullOrBlank()) {
                try {
                    startActivity(
                        Intent(Intent.ACTION_VIEW, Uri.parse(fallback)).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                    )
                    result.success(null)
                    return
                } catch (_: ActivityNotFoundException) {
                    // fall through
                }
            }
            Toast.makeText(
                this,
                "No app found to open this link",
                Toast.LENGTH_SHORT
            ).show()
            result.error(
                "no_activity",
                "No app found to open this link.",
                null
            )
        }
    }

    private fun openUrlInChrome(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        val preferChrome = call.argument<Boolean>("preferChrome") ?: true
        if (url.isNullOrBlank()) {
            result.error("bad_args", "url is required.", null)
            return
        }
        val uri = Uri.parse(url)
        try {
            if (preferChrome) {
                try {
                    val intent = Intent(Intent.ACTION_VIEW, uri).apply {
                        setPackage("com.android.chrome")
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    startActivity(intent)
                    result.success(true)
                    return
                } catch (_: ActivityNotFoundException) {
                    // Chrome not installed — fall back to default browser chooser
                }
            }
            val intent = Intent(Intent.ACTION_VIEW, uri).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("open_failed", e.message, null)
        }
    }

    private fun openCustomTab(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        if (url.isNullOrBlank()) {
            result.error("bad_args", "url is required.", null)
            return
        }
        val uri = Uri.parse(url)
        try {
            val sniffIntent = Intent(this, MainActivity::class.java).apply {
                action = "aurora.ACTION_SNIFF_AND_DOWNLOAD"
                putExtra("url", url)
                data = uri
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
            val pendingIntent = PendingIntent.getActivity(
                this,
                url.hashCode(),
                sniffIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val iconBitmap = BitmapFactory.decodeResource(resources, android.R.drawable.ic_menu_save)
            val builder = CustomTabsIntent.Builder()
                .setShowTitle(true)
                .setShareState(CustomTabsIntent.SHARE_STATE_ON)
                .setToolbarColor(Color.parseColor("#1E1E2E"))
                .setActionButton(iconBitmap, "Sniff & Download", pendingIntent, true)

            val customTabsIntent = builder.build()
            customTabsIntent.launchUrl(this, uri)
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "Error launching Chrome Custom Tab: ${e.message}", e)
            result.error("cct_failed", e.message, null)
        }
    }

    private fun isCustomTabSupported(): Boolean {
        val packageName = CustomTabsClient.getPackageName(this, null)
        return !packageName.isNullOrEmpty()
    }

    /**
     * Builds an ACTION_VIEW intent for http(s) and custom app schemes
     * (tg:, market://, mailto:, …). intent:// URLs are parsed with
     * [Intent.parseUri] so package + extras + fallback survive.
     */
    private fun buildViewIntent(url: String): Intent {
        return if (url.startsWith("intent:", ignoreCase = true)) {
            Intent.parseUri(url, Intent.URI_INTENT_SCHEME).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        } else {
            Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        }
    }

    private fun extractBrowserFallbackUrl(url: String): String? {
        if (!url.startsWith("intent:", ignoreCase = true)) return null
        return try {
            Intent.parseUri(url, Intent.URI_INTENT_SCHEME)
                .getStringExtra("browser_fallback_url")
        } catch (_: Exception) {
            null
        }
    }

    private fun publishFile(call: MethodCall, result: MethodChannel.Result) {
        val sourcePath = call.argument<String>("sourcePath")
        val displayName = call.argument<String>("displayName")
        val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
        val relativePath = call.argument<String>("relativePath") ?: "Download/Aurora Downloader"

        if (sourcePath.isNullOrBlank() || displayName.isNullOrBlank()) {
            result.error("bad_args", "sourcePath and displayName are required.", null)
            return
        }

        val source = File(sourcePath)
        if (!source.exists() || !source.isFile) {
            result.error("missing_file", "Completed file was not found: $sourcePath", null)
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            publishWithMediaStore(source, displayName, mimeType, relativePath, result)
        } else {
            publishLegacy(source, displayName, mimeType, relativePath, result)
        }
    }

    private fun publishWithMediaStore(
        source: File,
        displayName: String,
        mimeType: String,
        relativePath: String,
        result: MethodChannel.Result
    ) {
        val resolver = applicationContext.contentResolver
        var formattedRelativePath = relativePath.replace('\\', '/')
        if (!formattedRelativePath.endsWith("/")) {
            formattedRelativePath = "$formattedRelativePath/"
        }

        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH, formattedRelativePath)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }

        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
        if (uri == null) {
            result.error("insert_failed", "Could not create MediaStore download item.", null)
            return
        }

        try {
            resolver.openOutputStream(uri)?.use { output ->
                FileInputStream(source).use { input -> input.copyTo(output) }
            } ?: throw IllegalStateException("Could not open MediaStore output stream.")

            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, values, null, null)

            val pathLabel = if (relativePath.startsWith("Download/")) {
                relativePath.replaceFirst("Download/", "Downloads/")
            } else if (relativePath.startsWith("Download")) {
                relativePath.replaceFirst("Download", "Downloads")
            } else {
                relativePath
            }

            result.success(
                mapOf(
                    "uri" to uri.toString(),
                    "pathLabel" to pathLabel.removeSuffix("/")
                )
            )
        } catch (error: Exception) {
            resolver.delete(uri, null, null)
            result.error("publish_failed", error.message, null)
        }
    }

    private fun publishLegacy(
        source: File,
        displayName: String,
        mimeType: String,
        relativePath: String,
        result: MethodChannel.Result
    ) {
        try {
            val downloads = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            val subFolder = if (relativePath.startsWith("Download/")) {
                relativePath.substring("Download/".length)
            } else if (relativePath.startsWith("Download")) {
                relativePath.substring("Download".length)
            } else {
                relativePath
            }
            val cleanSubFolder = subFolder.trim('/', '\\').replace('\\', '/')
            val destinationDir = if (cleanSubFolder.isNotEmpty()) {
                File(downloads, cleanSubFolder)
            } else {
                downloads
            }

            if (!destinationDir.exists()) destinationDir.mkdirs()
            val destination = uniqueFile(destinationDir, displayName)
            FileInputStream(source).use { input ->
                FileOutputStream(destination).use { output -> input.copyTo(output) }
            }

            MediaScannerConnection.scanFile(
                this,
                arrayOf(destination.absolutePath),
                arrayOf(mimeType)
            ) { _, scannedUri ->
                val uri = scannedUri ?: Uri.fromFile(destination)
                val pathLabel = if (relativePath.startsWith("Download/")) {
                    relativePath.replaceFirst("Download/", "Downloads/")
                } else if (relativePath.startsWith("Download")) {
                    relativePath.replaceFirst("Download", "Downloads")
                } else {
                    "Downloads/$cleanSubFolder"
                }
                result.success(
                    mapOf(
                        "uri" to uri.toString(),
                        "pathLabel" to pathLabel.removeSuffix("/")
                    )
                )
            }
        } catch (error: Exception) {
            result.error("publish_failed", error.message, null)
        }
    }

    private fun uniqueFile(directory: File, displayName: String): File {
        val base = displayName.substringBeforeLast('.', displayName)
        val extension = displayName.substringAfterLast('.', "")
        var candidate = File(directory, displayName)
        var counter = 1
        while (candidate.exists()) {
            val name = if (extension.isEmpty()) {
                "$base ($counter)"
            } else {
                "$base ($counter).$extension"
            }
            candidate = File(directory, name)
            counter++
        }
        return candidate
    }

    private fun openUri(call: MethodCall, result: MethodChannel.Result) {
        val uri = call.argument<String>("uri")?.let(Uri::parse)
        val mimeType = call.argument<String>("mimeType") ?: "*/*"
        if (uri == null) {
            result.error("bad_args", "uri is required.", null)
            return
        }
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mimeType)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            startActivity(intent)
            result.success(null)
        } catch (error: ActivityNotFoundException) {
            result.error("no_activity", "No app can open this file type.", null)
        }
    }

    private fun shareUrl(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        if (url.isNullOrBlank()) {
            result.error("bad_args", "url is required.", null)
            return
        }
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, url)
        }
        try {
            startActivity(Intent.createChooser(intent, "Share via"))
            result.success(null)
        } catch (error: ActivityNotFoundException) {
            result.error("no_activity", "No app available to share.", null)
        }
    }

    private fun renamePublishedFile(call: MethodCall, result: MethodChannel.Result) {
        val uri = call.argument<String>("uri")?.let(Uri::parse)
        val newDisplayName = call.argument<String>("newDisplayName")
        if (uri == null || newDisplayName.isNullOrBlank()) {
            result.error("bad_args", "uri and newDisplayName are required.", null)
            return
        }
        try {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, newDisplayName)
            }
            val rows = contentResolver.update(uri, values, null, null)
            result.success(rows > 0)
        } catch (error: Exception) {
            result.error("rename_failed", error.message, null)
        }
    }

    /**
     * Remuxes an MPEG-TS file to an MP4 container using Android's native
     * [MediaExtractor] + [MediaMuxer] APIs. No transcoding — just a
     * container change, so the operation is fast and lossless.
     *
     * Important for MX Player / HW decode:
     * - Samples must be **time-interleaved** across tracks (not all video then
     *   all audio). Sequential-track writes produce files that often play
     *   video-only in pure HW mode while HW+/SW still has sound.
     * - AAC tracks need `csd-0` (AudioSpecificConfig). MPEG-TS ADTS streams
     *   sometimes omit it; HW decoders then open silent audio tracks.
     * - HLS segment concatenation often yields **discontinuous PTS/PCR**
     *   (each segment restarts timestamps, or mid-stream #EXT-X-DISCONTINUITY).
     *   Passing those raw times into MediaMuxer creates multi-minute timeline
     *   gaps: players freeze on the last frame with no audio until the next
     *   sample's PTS. We re-stamp every sample onto a continuous timeline.
     *
     * Runs on a background thread because MediaMuxer.start() / writeSampleData()
     * can take noticeable time on large files.
     *
     * Returns `true` on success, `false` on any failure. The destination file
     * is deleted on failure so the caller can keep the original .ts as a
     * fallback rather than a half-written .mp4.
     */
    private fun remuxTsToMp4(call: MethodCall, result: MethodChannel.Result) {
        val sourcePath = call.argument<String>("sourcePath") ?: ""
        val destPath = call.argument<String>("destPath") ?: ""
        if (sourcePath.isBlank() || destPath.isBlank()) {
            result.success(mapOf("success" to false, "error" to "missing sourcePath/destPath"))
            return
        }
        Thread {
            var extractor: MediaExtractor? = null
            var muxer: MediaMuxer? = null
            try {
                extractor = MediaExtractor()
                extractor.setDataSource(sourcePath)

                // extractor track index → muxer track index (only A/V)
                val trackMap = LinkedHashMap<Int, Int>()
                // Default sample step (µs) when PTS is missing or after a discontinuity.
                val defaultStepUs = HashMap<Int, Long>()
                muxer = MediaMuxer(destPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

                for (i in 0 until extractor.trackCount) {
                    val format = ensureAacCsd0(extractor.getTrackFormat(i))
                    val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                    // Skip metadata / timed-text / unknown — HW players choke on junk tracks.
                    if (!mime.startsWith("video/") && !mime.startsWith("audio/")) {
                        Log.i("AuroraRemux", "skipping non A/V track $i mime=$mime")
                        continue
                    }
                    val muxerIndex = muxer.addTrack(format)
                    trackMap[i] = muxerIndex
                    defaultStepUs[i] = estimateSampleStepUs(format, mime)
                    Log.i(
                        "AuroraRemux",
                        "track $i → muxer $muxerIndex mime=$mime " +
                            "hasCsd0=${format.containsKey("csd-0")} " +
                            "sampleRate=${format.getIntegerOrNull(MediaFormat.KEY_SAMPLE_RATE)} " +
                            "channels=${format.getIntegerOrNull(MediaFormat.KEY_CHANNEL_COUNT)} " +
                            "stepUs=${defaultStepUs[i]}",
                    )
                }

                if (trackMap.isEmpty()) {
                    extractor.release()
                    muxer.release()
                    File(destPath).delete()
                    runOnUiThread {
                        result.success(
                            mapOf("success" to false, "error" to "no video/audio tracks found in source"),
                        )
                    }
                    return@Thread
                }

                // Select all A/V tracks so MediaExtractor returns samples
                // interleaved by presentation time (required by MediaMuxer).
                for (extractorIndex in trackMap.keys) {
                    extractor.selectTrack(extractorIndex)
                }
                extractor.seekTo(0, MediaExtractor.SEEK_TO_CLOSEST_SYNC)

                muxer.start()
                // Large HEVC/AVC keyframes from 1080p/4K HLS can exceed 2 MiB.
                var buffer = ByteBuffer.allocateDirect(4 * 1024 * 1024)
                val info = MediaCodec.BufferInfo()
                var sampleCount = 0
                var discontinuityCount = 0
                var maxGapClosedUs = 0L

                // Continuous output timeline for HLS-concatenated MPEG-TS.
                // See class docs: raw PTS gaps freeze HW playback for minutes.
                val ptsState = PtsRewriteState()

                while (true) {
                    val extractorTrack = extractor.sampleTrackIndex
                    if (extractorTrack < 0) break
                    val muxerTrack = trackMap[extractorTrack]
                    if (muxerTrack == null) {
                        // Selected only A/V tracks, so this should be rare.
                        extractor.advance()
                        continue
                    }
                    buffer.clear()
                    var size = extractor.readSampleData(buffer, 0)
                    if (size < 0) break
                    // readSampleData may report a size larger than the buffer;
                    // grow and re-read the same sample before advancing.
                    if (size > buffer.capacity()) {
                        val needed = (size + 64 * 1024).coerceAtMost(32 * 1024 * 1024)
                        Log.i(
                            "AuroraRemux",
                            "growing remux buffer ${buffer.capacity()} → $needed (sample=$size)",
                        )
                        buffer = ByteBuffer.allocateDirect(needed)
                        size = extractor.readSampleData(buffer, 0)
                        if (size < 0) break
                        if (size > buffer.capacity()) {
                            throw IllegalStateException(
                                "sample too large for remux buffer ($size bytes)",
                            )
                        }
                    }

                    val rawPts = extractor.sampleTime
                    val stepUs = defaultStepUs[extractorTrack] ?: 33_333L
                    val rewrite = ptsState.next(
                        extractorTrack = extractorTrack,
                        rawPtsUs = rawPts,
                        stepUs = stepUs,
                    )
                    if (rewrite.discontinuity) {
                        discontinuityCount++
                        if (rewrite.gapClosedUs > maxGapClosedUs) {
                            maxGapClosedUs = rewrite.gapClosedUs
                        }
                        if (discontinuityCount <= 8 || discontinuityCount % 50 == 0) {
                            Log.w(
                                "AuroraRemux",
                                "PTS discontinuity #$discontinuityCount track=$extractorTrack " +
                                    "raw=$rawPts out=${rewrite.outPtsUs} " +
                                    "closedGapUs=${rewrite.gapClosedUs}",
                            )
                        }
                    }

                    info.offset = 0
                    info.size = size
                    info.presentationTimeUs = rewrite.outPtsUs
                    info.flags = extractor.sampleFlags
                    // MediaMuxer requires buffer position/limit to describe the sample.
                    buffer.position(0)
                    buffer.limit(size)
                    muxer.writeSampleData(muxerTrack, buffer, info)
                    sampleCount++
                    extractor.advance()
                }

                muxer.stop()
                muxer.release()
                muxer = null
                extractor.release()
                extractor = null
                Log.i(
                    "AuroraRemux",
                    "remux OK samples=$sampleCount tracks=${trackMap.size} " +
                        "discontinuities=$discontinuityCount maxGapClosedUs=$maxGapClosedUs " +
                        "durationUs=${ptsState.maxOutPtsUs} → $destPath",
                )
                runOnUiThread { result.success(mapOf("success" to true, "error" to null)) }
            } catch (e: Exception) {
                Log.w("AuroraRemux", "remuxTsToMp4 failed: ${e.message}", e)
                try { muxer?.release() } catch (_: Exception) {}
                try { extractor?.release() } catch (_: Exception) {}
                try { File(destPath).delete() } catch (_: Exception) {}
                runOnUiThread {
                    result.success(
                        mapOf("success" to false, "error" to (e.message ?: "unknown native error")),
                    )
                }
            }
        }.start()
    }

    /**
     * Rough inter-sample duration used when input PTS is missing or after a
     * discontinuity rebase. Prefer format metadata; fall back to 30 fps / AAC frame.
     */
    private fun estimateSampleStepUs(format: MediaFormat, mime: String): Long {
        if (mime.startsWith("video/")) {
            // KEY_FRAME_RATE may be int or float depending on extractor.
            try {
                if (format.containsKey(MediaFormat.KEY_FRAME_RATE)) {
                    val fps = try {
                        format.getFloat(MediaFormat.KEY_FRAME_RATE).toDouble()
                    } catch (_: Exception) {
                        format.getInteger(MediaFormat.KEY_FRAME_RATE).toDouble()
                    }
                    if (fps > 1.0 && fps < 240.0) {
                        return (1_000_000.0 / fps).toLong().coerceIn(4_000L, 100_000L)
                    }
                }
            } catch (_: Exception) {
                // fall through
            }
            return 33_333L // ~30 fps
        }
        if (mime.startsWith("audio/")) {
            val sampleRate = format.getIntegerOrNull(MediaFormat.KEY_SAMPLE_RATE) ?: 48000
            // AAC-LC frame = 1024 samples.
            return ((1_000_000L * 1024L) / sampleRate.toLong()).coerceIn(10_000L, 64_000L)
        }
        return 33_333L
    }

    /**
     * Rewrites MediaExtractor presentation times into a continuous timeline.
     *
     * Concatenated HLS MPEG-TS almost always has PTS restarts / jumps. Without
     * this rewrite, MediaMuxer embeds multi-minute gaps and HW players freeze
     * on the last frame (with silence) until the next sample's absolute PTS.
     */
    private class PtsRewriteState {
        /** Added to every raw PTS: out = raw + offset (after first-sample base). */
        private var globalOffsetUs: Long = 0L
        private var baseSet = false
        private var firstRawPtsUs: Long = 0L

        /** Last *output* PTS written per extractor track index. */
        private val lastOutPtsUs = HashMap<Int, Long>()

        /** Highest output PTS across all tracks (approx. media duration). */
        var maxOutPtsUs: Long = 0L
            private set

        /**
         * Gaps larger than this (and any negative delta) are treated as
         * discontinuities and closed. ~1.5s is above one long HLS segment
         * delta while still catching multi-minute freezes.
         */
        private val maxGapUs = 1_500_000L

        /**
         * Largest backwards PTS step still explainable by B-frame reordering
         * rather than a stream discontinuity. A GOP's reorder depth is a handful
         * of frames, so 1s is generous even for 4fps-equivalent spacing.
         */
        private val maxReorderUs = 1_000_000L

        fun next(extractorTrack: Int, rawPtsUs: Long, stepUs: Long): RewriteResult {
            val step = stepUs.coerceIn(1_000L, 200_000L)
            // Missing timestamps (-1) — synthesize from last output + step.
            if (rawPtsUs < 0L) {
                val last = lastOutPtsUs[extractorTrack]
                val out = if (last == null) 0L else last + step
                lastOutPtsUs[extractorTrack] = out
                if (out > maxOutPtsUs) maxOutPtsUs = out
                return RewriteResult(outPtsUs = out, discontinuity = last != null, gapClosedUs = 0L)
            }

            if (!baseSet) {
                firstRawPtsUs = rawPtsUs
                globalOffsetUs = -rawPtsUs
                baseSet = true
            }

            var out = rawPtsUs + globalOffsetUs
            var discontinuity = false
            var gapClosed = 0L

            val last = lastOutPtsUs[extractorTrack]
            if (last != null) {
                val delta = out - last
                // A *small* negative delta is not a discontinuity: with B-frames
                // MediaExtractor returns presentation times in decode order, so
                // e.g. I(0) P(120) B(40) B(80) yields deltas +120, -80, +40.
                // Treating those as resets ratchets globalOffsetUs forward on
                // every reordered frame, which inflates the output duration and
                // drags the other track with it through the shared offset.
                // Only a jump beyond the reorder window is a real PTS reset.
                val isReorder = delta < 0L && -delta <= maxReorderUs
                if (!isReorder && (delta <= 0L || delta > maxGapUs)) {
                    val desired = last + step
                    // Shift the global offset so this sample lands on [desired].
                    // desired = raw + globalOffset  →  globalOffset = desired - raw
                    globalOffsetUs = desired - rawPtsUs
                    gapClosed = if (delta > maxGapUs) delta - step else 0L
                    out = desired
                    discontinuity = true
                }
            } else {
                // First sample of this track — if it's far ahead of other tracks'
                // timeline (e.g. audio starts after video), still allow it, but
                // clamp large negative (before zero) after offset.
                if (out < 0L) {
                    globalOffsetUs += -out
                    out = 0L
                    discontinuity = true
                }
            }

            // MediaMuxer requires non-decreasing PTS *per track*, so nudge a
            // reordered frame just past its predecessor. Deliberately does NOT
            // re-anchor globalOffsetUs: re-anchoring here would push the whole
            // timeline forward once per B-frame, and over a feature-length video
            // that compounds into a badly inflated duration (and audio that
            // drifts out of any relation to the video clock).
            val prev = lastOutPtsUs[extractorTrack]
            if (prev != null && out <= prev) {
                out = prev + 1_000L
            }

            lastOutPtsUs[extractorTrack] = out
            if (out > maxOutPtsUs) maxOutPtsUs = out
            return RewriteResult(
                outPtsUs = out,
                discontinuity = discontinuity,
                gapClosedUs = gapClosed,
            )
        }
    }

    private data class RewriteResult(
        val outPtsUs: Long,
        val discontinuity: Boolean,
        val gapClosedUs: Long,
    )

    /**
     * Ensures AAC [MediaFormat] has `csd-0` (AudioSpecificConfig). Pure HW
     * decoders (MX Player HW, many OEM codecs) refuse silent tracks without it;
     * HW+/SW often parse ADTS headers instead and still play sound.
     */
    private fun ensureAacCsd0(format: MediaFormat): MediaFormat {
        val mime = format.getString(MediaFormat.KEY_MIME) ?: return format
        if (mime != MediaFormat.MIMETYPE_AUDIO_AAC && mime != "audio/mp4a-latm") {
            return format
        }
        if (format.containsKey("csd-0")) return format

        val sampleRate = format.getIntegerOrNull(MediaFormat.KEY_SAMPLE_RATE) ?: return format
        val channelCount = format.getIntegerOrNull(MediaFormat.KEY_CHANNEL_COUNT) ?: 2
        // KEY_AAC_PROFILE: MediaCodecInfo.CodecProfileLevel.AACObjectLC = 2
        val profile = format.getIntegerOrNull(MediaFormat.KEY_AAC_PROFILE) ?: 2

        val csd = buildAacAudioSpecificConfig(profile, sampleRate, channelCount) ?: return format
        format.setByteBuffer("csd-0", ByteBuffer.wrap(csd))
        Log.i(
            "AuroraRemux",
            "synthesized AAC csd-0 profile=$profile rate=$sampleRate ch=$channelCount",
        )
        return format
    }

    /** Builds ISO 14496-3 AudioSpecificConfig for common AAC LC/HE profiles. */
    private fun buildAacAudioSpecificConfig(
        aacProfile: Int,
        sampleRate: Int,
        channelCount: Int,
    ): ByteArray? {
        val samplingFreqIndex = aacSamplingFrequencyIndex(sampleRate) ?: return null
        // Clamp channels to ISO table (0=defined in AOT specific config — skip)
        val ch = channelCount.coerceIn(1, 7)
        // audioObjectType (5 bits) | samplingFrequencyIndex (4) | channelConfiguration (4)
        // For AOT 1–31 this is 2 bytes.
        val objectType = aacProfile.coerceIn(1, 31)
        val csd = ByteArray(2)
        csd[0] = ((objectType shl 3) or (samplingFreqIndex shr 1)).toByte()
        csd[1] = (((samplingFreqIndex and 0x01) shl 7) or (ch shl 3)).toByte()
        return csd
    }

    private fun aacSamplingFrequencyIndex(sampleRate: Int): Int? {
        val table = intArrayOf(
            96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
            16000, 12000, 11025, 8000, 7350,
        )
        val idx = table.indexOf(sampleRate)
        return if (idx >= 0) idx else null
    }

    private fun MediaFormat.getIntegerOrNull(key: String): Int? {
        return try {
            if (containsKey(key)) getInteger(key) else null
        } catch (_: Exception) {
            null
        }
    }

    // ─── Permissions & battery opt ──────────────────────────────────

    /// Request the POST_NOTIFICATIONS runtime permission on Android 13+.
    /// Without this the foreground service notification is hidden,
    /// making the process more vulnerable to being killed by the OS.
    /// No-ops when already granted.
    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ActivityCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                != android.content.pm.PackageManager.PERMISSION_GRANTED
            ) {
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    NOTIFICATION_PERMISSION_REQUEST_CODE,
                )
            }
        }
    }

    /// True when the app can post notifications (permission granted on 13+,
    /// or NotificationManager reports enabled on older APIs).
    private fun areNotificationsEnabled(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ActivityCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        } else {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE)
                    as? android.app.NotificationManager
            nm?.areNotificationsEnabled() ?: true
        }
    }

    /// Open the system battery-optimisation exemption dialog so the user
    /// can whitelist Aurora.  This prevents Android's doze / app-standby
    /// from killing the process or throttling network during downloads.
    /// Returns a map with an optional "oem" key when the manufacturer has
    /// separate autostart / background-activity settings the user also
    /// needs to adjust.
    private fun requestBatteryOptimizationExemption(): Map<String, Any> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            try {
                val intent = Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:${applicationContext.packageName}")
                )
                startActivity(intent)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to open battery opt exemption", e)
            }
        }
        return detectOemBatteryHint()
    }

    private val _manufacturer: String by lazy {
        Build.MANUFACTURER.lowercase(Locale.ROOT)
    }

    /// Detects known OEMs that have separate autostart / background-activity
    /// permission screens outside of the standard AOSP battery optimisation
    /// whitelist.  Returns a map with "oem" set to the manufacturer key, or
    /// an empty map if none is detected.
    private fun detectOemBatteryHint(): Map<String, Any> {
        val result = mutableMapOf<String, Any>()
        when {
            _manufacturer.contains("xiaomi") -> result["oem"] = "xiaomi"
            _manufacturer.contains("huawei") -> result["oem"] = "huawei"
            _manufacturer.contains("oppo") || _manufacturer.contains("realme") -> result["oem"] = "oppo"
            _manufacturer.contains("vivo") -> result["oem"] = "vivo"
            _manufacturer.contains("oneplus") -> result["oem"] = "oneplus"
            _manufacturer.contains("samsung") -> result["oem"] = "samsung"
        }
        return result
    }

    /// Opens the manufacturer-specific autostart / background-activity
    /// settings page so the user can whitelist Aurora for background
    /// operation — a separate requirement from the standard battery
    /// optimisation exemption on many Chinese OEM ROMs.
    /// Tries known component aliases in order, then app-details fallback.
    private fun openOemAutostartPage() {
        val candidates: List<Intent> = when {
            _manufacturer.contains("xiaomi") || _manufacturer.contains("redmi") -> listOf(
                Intent().setComponent(
                    ComponentName(
                        "com.miui.securitycenter",
                        "com.miui.permcenter.autostart.AutoStartManagementActivity",
                    ),
                ),
                Intent().setComponent(
                    ComponentName(
                        "com.miui.securitycenter",
                        "com.miui.powercenter.PowerSettings",
                    ),
                ),
            )
            _manufacturer.contains("huawei") || _manufacturer.contains("honor") -> listOf(
                Intent().setComponent(
                    ComponentName(
                        "com.huawei.systemmanager",
                        "com.huawei.systemmanager.appcontrol.activity.StartupAppControlActivity",
                    ),
                ),
                Intent().setComponent(
                    ComponentName(
                        "com.huawei.systemmanager",
                        "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
                    ),
                ),
            )
            _manufacturer.contains("oppo") || _manufacturer.contains("realme") -> listOf(
                Intent().setComponent(
                    ComponentName(
                        "com.coloros.safecenter",
                        "com.coloros.safecenter.permission.startup.StartupAppListActivity",
                    ),
                ),
                Intent().setComponent(
                    ComponentName(
                        "com.oplus.safecenter",
                        "com.oplus.safecenter.permission.startup.StartupAppListActivity",
                    ),
                ),
                Intent().setComponent(
                    ComponentName(
                        "com.coloros.safecenter",
                        "com.coloros.safecenter.startupapp.StartupAppListActivity",
                    ),
                ),
            )
            _manufacturer.contains("vivo") -> listOf(
                Intent("vivo.intent.action.STARTUP_ENGINE").setComponent(
                    ComponentName("com.iqoo.secure", "com.iqoo.secure.MainActivity"),
                ),
                Intent().setComponent(
                    ComponentName(
                        "com.vivo.permissionmanager",
                        "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
                    ),
                ),
            )
            _manufacturer.contains("oneplus") -> listOf(
                Intent().setComponent(
                    ComponentName(
                        "com.oneplus.security",
                        "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity",
                    ),
                ),
                Intent().setComponent(
                    ComponentName(
                        "com.oplus.safecenter",
                        "com.oplus.safecenter.permission.startup.StartupAppListActivity",
                    ),
                ),
            )
            _manufacturer.contains("samsung") -> listOf(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                    .setData(Uri.parse("package:${applicationContext.packageName}")),
            )
            else -> emptyList()
        }

        val fallback = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
            .setData(Uri.parse("package:${applicationContext.packageName}"))

        for (intent in candidates + fallback) {
            try {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
                return
            } catch (e: Exception) {
                Log.w(TAG, "OEM autostart candidate failed for $_manufacturer: ${e.message}")
            }
        }
    }

    /** Matches any valid backup file (.json, .1dmbak, .bak) from Aurora or 1DM/ADM/IDM. */
    private fun isAuroraBackupFileName(name: String?): Boolean {
        if (name.isNullOrBlank()) return false
        val lower = name.lowercase()
        if (lower.endsWith(".1dmbak") || lower.endsWith(".bak")) return true
        if (lower.endsWith(".json")) {
            return lower == "aurora_backup.json" ||
                lower.startsWith("aurora_auto_backup_") ||
                lower.startsWith("aurora_backup_") ||
                lower.contains("aurora_backup") ||
                lower.contains("aurora_auto_backup") ||
                lower.contains("1dm_backup") ||
                lower.contains("idm_backup")
        }
        return false
    }

    private fun listBackupFiles(call: MethodCall, result: MethodChannel.Result) {
        val relativePath = call.argument<String>("relativePath") ?: "Download/Aurora Downloader/Backup/"
        val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

        Thread {
            val list = mutableListOf<Map<String, Any>>()
            val seenKeys = mutableSetOf<String>()

            fun addEntry(uriStr: String, name: String, size: Long, dateModified: Long, relPath: String) {
                val key = if (uriStr.isNotBlank()) uriStr else name
                if (seenKeys.add(key)) {
                    val kind = when {
                        relPath.contains("/Auto Backup", ignoreCase = true) ||
                            relPath.contains("Auto Backup/", ignoreCase = true) ||
                            name.lowercase().startsWith("aurora_auto_backup_") -> "auto"
                        else -> "manual"
                    }
                    list.add(mapOf(
                        "uri" to uriStr,
                        "displayName" to name,
                        "size" to size,
                        "dateModified" to dateModified,
                        "kind" to kind,
                        "relativePath" to relPath
                    ))
                }
            }

            // 1. Query MediaStore Downloads collection (API 29+)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                try {
                    val resolver = applicationContext.contentResolver
                    val uri = MediaStore.Downloads.EXTERNAL_CONTENT_URI
                    val projection = arrayOf(
                        MediaStore.MediaColumns._ID,
                        MediaStore.MediaColumns.DISPLAY_NAME,
                        MediaStore.MediaColumns.SIZE,
                        MediaStore.MediaColumns.DATE_MODIFIED,
                        MediaStore.MediaColumns.RELATIVE_PATH
                    )
                    val selection = "${MediaStore.MediaColumns.DISPLAY_NAME} LIKE '%.json' OR " +
                        "${MediaStore.MediaColumns.DISPLAY_NAME} LIKE '%.1dmbak' OR " +
                        "${MediaStore.MediaColumns.DISPLAY_NAME} LIKE '%.bak'"

                    resolver.query(uri, projection, selection, null, "${MediaStore.MediaColumns.DATE_MODIFIED} DESC")?.use { cursor ->
                        val idCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
                        val nameCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
                        val sizeCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
                        val dateCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED)
                        val relCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.RELATIVE_PATH)

                        while (cursor.moveToNext()) {
                            val name = cursor.getString(nameCol) ?: continue
                            if (!isAuroraBackupFileName(name)) continue
                            val id = cursor.getLong(idCol)
                            val size = cursor.getLong(sizeCol)
                            val date = cursor.getLong(dateCol) * 1000
                            val rel = cursor.getString(relCol) ?: ""
                            val contentUri = ContentUris.withAppendedId(uri, id)
                            addEntry(contentUri.toString(), name, size, date, rel)
                        }
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "MediaStore query in listBackupFiles failed: ${e.message}")
                }
            }

            // 2. Scan dedicated filesystem backup folders (avoiding deep recursive scan of entire root Downloads)
            try {
                val downloadsDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                val scanDirs = listOf(
                    File(downloadsDir, "Aurora Downloader/Backup"),
                    File(downloadsDir, "Aurora Downloader/Auto Backup"),
                    File(downloadsDir, "Aurora Downloader"),
                    File(downloadsDir, "Aurora Downloads/Backups"),
                    File(downloadsDir, "Aurora Downloads/Backup"),
                    File(downloadsDir, "Aurora Downloads"),
                    File(downloadsDir, "Aurora"),
                )

                for (dir in scanDirs) {
                    if (!dir.exists() || !dir.canRead()) continue
                    val files = dir.listFiles()?.filter { it.isFile } ?: emptyList()
                    for (file in files) {
                        if (isAuroraBackupFileName(file.name)) {
                            val fileUri = Uri.fromFile(file).toString()
                            val rel = file.parentFile?.name ?: ""
                            addEntry(fileUri, file.name, file.length(), file.lastModified(), rel)
                        }
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "Filesystem scan in listBackupFiles failed: ${e.message}")
            }

            // Sort descending by dateModified
            list.sortByDescending { (it["dateModified"] as? Number)?.toLong() ?: 0L }
            mainHandler.post {
                result.success(list)
            }
        }.start()
    }

    private fun deleteBackupFile(call: MethodCall, result: MethodChannel.Result) {
        val uriStr = call.argument<String>("uri")
        if (uriStr.isNullOrBlank()) {
            result.error("bad_args", "uri is required.", null)
            return
        }
        try {
            val uri = Uri.parse(uriStr)
            if (uri.scheme == "content") {
                val deleted = contentResolver.delete(uri, null, null)
                result.success(deleted > 0)
            } else {
                val file = File(uri.path ?: uriStr)
                if (file.exists()) {
                    result.success(file.delete())
                } else {
                    result.success(false)
                }
            }
        } catch (e: Exception) {
            result.error("delete_failed", e.message, null)
        }
    }

    private fun readBackupFile(call: MethodCall, result: MethodChannel.Result) {
        val uriStr = call.argument<String>("uri")
        if (uriStr.isNullOrBlank()) {
            result.error("bad_args", "uri is required.", null)
            return
        }
        try {
            val uri = Uri.parse(uriStr)
            val destFile = File(filesDir, "temp_restore_${System.currentTimeMillis()}.json")
            if (uri.scheme == "file" || uriStr.startsWith("/")) {
                val filePath = if (uri.scheme == "file") uri.path ?: uriStr else uriStr
                val srcFile = File(filePath)
                if (srcFile.exists()) {
                    srcFile.copyTo(destFile, overwrite = true)
                } else {
                    throw IllegalStateException("Backup file not found: $filePath")
                }
            } else {
                contentResolver.openInputStream(uri)?.use { input ->
                    FileOutputStream(destFile).use { output ->
                        input.copyTo(output)
                    }
                } ?: throw IllegalStateException("Could not open input stream for URI: $uriStr")
            }
            result.success(destFile.absolutePath)
        } catch (e: Exception) {
            result.error("read_failed", e.message, null)
        }
    }

    /**
     * Opens a readable stream for either an absolute file path or a content:// URI.
     * Completed downloads delete the private app-data copy after MediaStore publish,
     * so export/share must accept content URIs.
     */
    private fun openReadableSource(sourceRef: String): java.io.InputStream {
        return if (sourceRef.startsWith("content:", ignoreCase = true)) {
            contentResolver.openInputStream(Uri.parse(sourceRef))
                ?: throw IllegalStateException("Could not open content URI: $sourceRef")
        } else {
            val source = File(sourceRef)
            if (!source.exists() || !source.isFile) {
                throw IllegalStateException("File not found: $sourceRef")
            }
            FileInputStream(source)
        }
    }

    private fun sourceRefExists(sourceRef: String): Boolean {
        return try {
            if (sourceRef.startsWith("content:", ignoreCase = true)) {
                contentResolver.openInputStream(Uri.parse(sourceRef))?.use { true } ?: false
            } else {
                val f = File(sourceRef)
                f.exists() && f.isFile
            }
        } catch (_: Exception) {
            false
        }
    }

    private fun exportFile(call: MethodCall, result: MethodChannel.Result) {
        // sourcePath may be a filesystem path OR a content:// URI (published download).
        val sourcePath = call.argument<String>("sourcePath")
        val displayName = call.argument<String>("displayName")
        val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"

        if (sourcePath.isNullOrBlank() || displayName.isNullOrBlank()) {
            result.error("bad_args", "sourcePath and displayName are required.", null)
            return
        }

        if (!sourceRefExists(sourcePath)) {
            result.error(
                "missing_file",
                "Completed file not found (private copy may have been removed after publish): $sourcePath",
                null,
            )
            return
        }

        pendingExportResult = result
        pendingExportSourcePath = sourcePath

        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeType
            putExtra(Intent.EXTRA_TITLE, displayName)
        }

        try {
            startActivityForResult(intent, REQUEST_EXPORT_FILE)
        } catch (error: Exception) {
            result.error("picker_error", error.message, null)
            pendingExportResult = null
            pendingExportSourcePath = null
        }
    }

    private fun selectExportUri(call: MethodCall, result: MethodChannel.Result) {
        val displayName = call.argument<String>("displayName")
        val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"

        if (displayName.isNullOrBlank()) {
            result.error("bad_args", "displayName is required.", null)
            return
        }

        pendingPickUriResult = result

        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeType
            putExtra(Intent.EXTRA_TITLE, displayName)
        }

        try {
            startActivityForResult(intent, REQUEST_PICK_EXPORT_URI)
        } catch (error: Exception) {
            result.error("picker_error", error.message, null)
            pendingPickUriResult = null
        }
    }

    private fun writeExportFile(call: MethodCall, result: MethodChannel.Result) {
        val sourcePath = call.argument<String>("sourcePath")
        val exportUri = call.argument<String>("exportUri")

        if (sourcePath.isNullOrBlank() || exportUri.isNullOrBlank()) {
            result.error("bad_args", "sourcePath and exportUri are required.", null)
            return
        }

        if (!sourceRefExists(sourcePath)) {
            result.error("missing_file", "Source file not found: $sourcePath", null)
            return
        }

        try {
            val uri = Uri.parse(exportUri)
            contentResolver.openOutputStream(uri)?.use { output ->
                openReadableSource(sourcePath).use { input -> input.copyTo(output) }
            } ?: throw IllegalStateException("Could not open export destination.")
            result.success(true)
        } catch (error: Exception) {
            result.error("write_failed", error.message, null)
        }
    }

    private fun selectExportDirectory(result: MethodChannel.Result) {
        pendingPickDirectoryResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        try {
            startActivityForResult(intent, REQUEST_PICK_DIRECTORY)
        } catch (error: Exception) {
            result.error("picker_error", error.message, null)
            pendingPickDirectoryResult = null
        }
    }

    private fun writeExportFileToDirectory(call: MethodCall, result: MethodChannel.Result) {
        val sourcePath = call.argument<String>("sourcePath")
        val directoryUriStr = call.argument<String>("directoryUri")
        val displayName = call.argument<String>("displayName")
        val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"

        if (sourcePath.isNullOrBlank() || directoryUriStr.isNullOrBlank() || displayName.isNullOrBlank()) {
            result.error("bad_args", "sourcePath, directoryUri, and displayName are required.", null)
            return
        }

        if (!sourceRefExists(sourcePath)) {
            result.error("missing_file", "Source file not found: $sourcePath", null)
            return
        }

        try {
            val treeUri = Uri.parse(directoryUriStr)
            val documentId = DocumentsContract.getTreeDocumentId(treeUri)
            val parentDocumentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId)
            val newFileUri = DocumentsContract.createDocument(contentResolver, parentDocumentUri, mimeType, displayName)
            if (newFileUri == null) {
                result.error("create_failed", "Could not create document in tree.", null)
                return
            }
            contentResolver.openOutputStream(newFileUri)?.use { output ->
                openReadableSource(sourcePath).use { input -> input.copyTo(output) }
            } ?: throw IllegalStateException("Could not open document output stream.")
            result.success(true)
        } catch (error: Exception) {
            result.error("write_failed", error.message, null)
        }
    }

    private fun listAutoBackups(result: MethodChannel.Result) {
        val resolver = applicationContext.contentResolver
        val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.RELATIVE_PATH
        )
        val selection = "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ? OR ${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?"
        val selectionArgs = arrayOf("Aurora Downloader/Auto Backup/%", "Download/Aurora Downloader/Auto Backup/%")
        val entries = mutableListOf<Map<String, String>>()
        try {
            resolver.query(collection, projection, selection, selectionArgs, null)?.use { cursor ->
                val idCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
                val nameCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
                val relCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.RELATIVE_PATH)
                val prefixLegacy = "Aurora Downloader/Auto Backup/"
                val prefixModern = "Download/Aurora Downloader/Auto Backup/"
                while (cursor.moveToNext()) {
                    val name = cursor.getString(nameCol) ?: continue
                    val rel = cursor.getString(relCol) ?: continue
                    val timestamp = if (rel.startsWith(prefixModern)) {
                        rel.substring(prefixModern.length)
                            .trim('/')
                            .split("/")
                            .firstOrNull() ?: continue
                    } else if (rel.startsWith(prefixLegacy)) {
                        rel.substring(prefixLegacy.length)
                            .trim('/')
                            .split("/")
                            .firstOrNull() ?: continue
                    } else {
                        continue
                    }
                    if (timestamp.isEmpty()) continue
                    val id = cursor.getLong(idCol)
                    val uri = ContentUris.withAppendedId(collection, id).toString()
                    entries.add(mapOf("timestamp" to timestamp, "name" to name, "uri" to uri))
                }
            }
            result.success(entries)
        } catch (e: Exception) {
            result.error("list_failed", e.message, null)
        }
    }

    private fun restoreAutoBackupFile(call: MethodCall, result: MethodChannel.Result) {
        val uriString = call.argument<String>("uri")
        val destPath = call.argument<String>("destPath")
        if (uriString.isNullOrBlank() || destPath.isNullOrBlank()) {
            result.error("bad_args", "uri and destPath are required.", null)
            return
        }
        try {
            val uri = Uri.parse(uriString)
            val resolver = applicationContext.contentResolver
            resolver.openInputStream(uri)?.use { input ->
                File(destPath).outputStream().use { output ->
                    input.copyTo(output)
                }
            } ?: throw IllegalStateException("Could not open backup input stream.")
            result.success(true)
        } catch (e: Exception) {
            result.error("restore_failed", e.message, null)
        }
    }

    /// One-time migration: rename "Aurora Downloads" → "Aurora Downloader"
    /// so all app data lives under a single consistent path.
    private fun migrateOldDownloadPath() {
        try {
            val downloadsDir = Environment.getExternalStoragePublicDirectory(
                Environment.DIRECTORY_DOWNLOADS
            )
            val oldDir = File(downloadsDir, "Aurora Downloads")
            val newDir = File(downloadsDir, "Aurora Downloader")

            if (!oldDir.exists()) return // nothing to migrate

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // Q+: update MediaStore RELATIVE_PATH entries
                val resolver = applicationContext.contentResolver
                val uri = MediaStore.Downloads.EXTERNAL_CONTENT_URI
                val where = "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?"
                val args = arrayOf("Download/Aurora Downloads%")

                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.RELATIVE_PATH, "Download/Aurora Downloader")
                }
                val updated = resolver.update(uri, values, where, args)
                Log.i(TAG, "Migrated $updated MediaStore entries: Aurora Downloads → Aurora Downloader")

                // Also migrate backup sub-path
                val backupValues = ContentValues().apply {
                    put(MediaStore.MediaColumns.RELATIVE_PATH, "Download/Aurora Downloader/Backups")
                }
                val backupWhere = "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?"
                val backupArgs = arrayOf("Download/Aurora Downloads/Backups%")
                val backupUpdated = resolver.update(uri, backupValues, backupWhere, backupArgs)
                if (backupUpdated > 0) {
                    Log.i(TAG, "Migrated $backupUpdated backup entries")
                }
            }

            // Rename the actual directory (works on pre-Q; on Q+ this
            // is a belt-and-suspenders step for any files that weren't
            // registered in MediaStore).
            if (oldDir.exists()) {
                val renamed = oldDir.renameTo(newDir)
                if (renamed) {
                    Log.i(TAG, "Renamed $oldDir → $newDir")
                } else {
                    Log.w(TAG, "Could not rename $oldDir (may already be migrated on disk)")
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Path migration failed: ${e.message}")
        }
    }

    private fun isPipSupported(): Boolean {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
    }

    private fun enterPipMode(width: Int = 16, height: Int = 9): Boolean {
        if (!isPipSupported()) return false
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val num = if (width > 0) width else 16
                val den = if (height > 0) height else 9
                val builder = PictureInPictureParams.Builder()
                val ratioFloat = num.toFloat() / den.toFloat()
                if (ratioFloat in 0.418f..2.39f) {
                    builder.setAspectRatio(Rational(num, den))
                }
                enterPictureInPictureMode(builder.build())
            } else {
                false
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error entering PiP mode", e)
            false
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pipChannel?.invokeMethod("onPipModeChanged", isInPictureInPictureMode)
    }

    // -----------------------------------------------------------------
    // Stealth: override Sec-CH-UA Client Hints on all live WebViews.
    // -----------------------------------------------------------------

    /**
     * Walks the Activity's view hierarchy, finds all [WebView] instances,
     * and calls [WebSettingsCompat.setUserAgentMetadata] on each to replace
     * the default `"Android WebView"` brand with `"Google Chrome"`.
     *
     * Returns the number of WebViews that were successfully patched.
     */
    private fun applyStealthMetadataToAllWebViews(chromeVersionInput: String): Int {
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.USER_AGENT_METADATA)) {
            Log.w(TAG, "USER_AGENT_METADATA feature not supported on this device")
            return -1
        }

        val fullVer = if (chromeVersionInput.contains(".")) chromeVersionInput else "$chromeVersionInput.0.0.0"
        val majorVer = chromeVersionInput.split(".")[0]
        val releaseVersion = Build.VERSION.RELEASE ?: "14.0.0"

        fun doApply(): Int {
            val webViews = mutableListOf<WebView>()
            val rootView = window?.decorView
            if (rootView != null) {
                collectWebViews(rootView, webViews)
            }

            Log.i(TAG, "collectWebViews found ${webViews.size} WebViews (decorView=${rootView != null})")

            var patchedCount = 0
            for (wv in webViews) {
                try {
                    val metadata = UserAgentMetadata.Builder()
                        .setBrandVersionList(
                            listOf(
                                UserAgentMetadata.BrandVersion.Builder()
                                    .setBrand("Not_A Brand")
                                    .setMajorVersion("99")
                                    .setFullVersion("99.0.0.0")
                                    .build(),
                                UserAgentMetadata.BrandVersion.Builder()
                                    .setBrand("Chromium")
                                    .setMajorVersion(majorVer)
                                    .setFullVersion(fullVer)
                                    .build(),
                                UserAgentMetadata.BrandVersion.Builder()
                                    .setBrand("Google Chrome")
                                    .setMajorVersion(majorVer)
                                    .setFullVersion(fullVer)
                                    .build(),
                            )
                        )
                        .setFullVersion(fullVer)
                        .setPlatform("Android")
                        .setPlatformVersion(releaseVersion)
                        .setModel("K")
                        .setMobile(true)
                        .build()

                    WebSettingsCompat.setUserAgentMetadata(wv.settings, metadata)
                    patchedCount++
                    Log.i(TAG, "Stealth metadata successfully applied to WebView@${wv.hashCode()}")
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to apply stealth metadata to WebView: ${e.message}")
                }
            }
            return patchedCount
        }

        var count = doApply()
        if (count == 0) {
            // Post delayed retries in case PlatformView hasn't finished attaching to decorView
            val handler = android.os.Handler(android.os.Looper.getMainLooper())
            val delays = listOf(100L, 300L, 700L)
            for (delay in delays) {
                handler.postDelayed({
                    val retryCount = doApply()
                    if (retryCount > 0) {
                        Log.i(TAG, "Delayed stealth metadata applied successfully ($retryCount WebViews)")
                    }
                }, delay)
            }
        }
        return count
    }

    /** Recursively collects all [WebView] instances from the view tree. */
    private fun collectWebViews(view: View, out: MutableList<WebView>) {
        if (view is WebView) {
            out.add(view)
        }
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                collectWebViews(view.getChildAt(i), out)
            }
        }
    }
}

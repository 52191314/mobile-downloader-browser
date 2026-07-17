package com.personal.aurora_downloader

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.ContentUris
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
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
import android.util.Log
import android.widget.Toast
import androidx.core.app.ActivityCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import android.provider.DocumentsContract
import android.webkit.CookieManager
import java.io.BufferedReader
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.nio.ByteBuffer
import java.util.Locale

class MainActivity : FlutterActivity() {
    private val channelName = "aurora_downloader/public_downloads"
    private val networkChannelName = "aurora_downloader/network"
    private val fgServiceChannelName = "aurora_downloader/foreground_service"
    private val intentChannelName = "aurora_downloader/intent"
    private var intentUrlChannel: MethodChannel? = null
    private var pendingImportResult: MethodChannel.Result? = null
    private var pendingExportResult: MethodChannel.Result? = null
    private var pendingExportSourcePath: String? = null
    private var pendingPickUriResult: MethodChannel.Result? = null
    private var pendingPickDirectoryResult: MethodChannel.Result? = null
    private lateinit var nativeDownloadEngine: NativeDownloadEngine

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
                    "pickImportFile" -> pickImportFile(result)
                    "openUrl" -> openUrl(call, result)
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
        val intent = intent
        if (intent != null && Intent.ACTION_VIEW == intent.action) {
            val data = intent.data
            if (data != null) {
                val url = data.toString()
                intent.action = null
                intent.data = null
                return url
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

    private fun shareFile(call: MethodCall, result: MethodChannel.Result) {
        val filePath = call.argument<String>("filePath")
        if (filePath.isNullOrBlank()) {
            result.error("bad_args", "filePath is required.", null)
            return
        }
        val source = File(filePath)
        if (!source.exists()) {
            result.error("missing_file", "File not found: $filePath", null)
            return
        }

        val mimeType = if (source.name.endsWith(".json", ignoreCase = true)) {
            "application/json"
        } else {
            "text/plain"
        }

        val resolver = applicationContext.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, source.name)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH, "Download/Aurora Downloader")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }

        val uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
        } else {
            val downloadsDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            val destDir = File(downloadsDir, "Aurora Downloader")
            if (!destDir.exists()) destDir.mkdirs()
            val destFile = File(destDir, source.name)
            source.copyTo(destFile, overwrite = true)
            MediaScannerConnection.scanFile(this, arrayOf(destFile.absolutePath), null, null)
            result.success(null)
            return
        }

        if (uri == null) {
            result.error("insert_failed", "Could not create MediaStore item for sharing.", null)
            return
        }

        try {
            resolver.openOutputStream(uri)?.use { output ->
                FileInputStream(source).use { input -> input.copyTo(output) }
            } ?: throw IllegalStateException("Could not open output stream.")

            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, values, null, null)

            val intent = Intent(Intent.ACTION_SEND).apply {
                type = mimeType
                putExtra(Intent.EXTRA_STREAM, uri)
                clipData = android.content.ClipData.newRawUri(null, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(intent, source.name))
            result.success(null)
        } catch (error: Exception) {
            resolver.delete(uri, null, null)
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
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/json", "application/octet-stream", "application/zip"))
        }
        try {
            startActivityForResult(intent, PICK_IMPORT_FILE)
        } catch (error: ActivityNotFoundException) {
            result.error("no_activity", "No file picker available.", null)
            pendingImportResult = null
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
            val sourcePath = pendingExportSourcePath
            if (resultCode == Activity.RESULT_OK && data?.data != null && sourcePath != null) {
                val uri = data.data!!
                try {
                    val source = File(sourcePath)
                    contentResolver.openOutputStream(uri)?.use { output ->
                        FileInputStream(source).use { input -> input.copyTo(output) }
                    }
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
        // Resolve through the system default browser chooser instead of
        // hardcoding a specific vendor package like UC Browser. This lets
        // users pick their preferred browser on first run.
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            startActivity(intent)
            result.success(null)
        } catch (_: ActivityNotFoundException) {
            result.error("no_activity", "No browser found.", null)
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
                    Log.i(
                        "AuroraRemux",
                        "track $i → muxer $muxerIndex mime=$mime " +
                            "hasCsd0=${format.containsKey("csd-0")} " +
                            "sampleRate=${format.getIntegerOrNull(MediaFormat.KEY_SAMPLE_RATE)} " +
                            "channels=${format.getIntegerOrNull(MediaFormat.KEY_CHANNEL_COUNT)}",
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
                val buffer = ByteBuffer.allocateDirect(2 * 1024 * 1024)
                val info = MediaCodec.BufferInfo()
                var sampleCount = 0
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
                    val size = extractor.readSampleData(buffer, 0)
                    if (size < 0) break
                    info.offset = 0
                    info.size = size
                    info.presentationTimeUs = extractor.sampleTime.coerceAtLeast(0L)
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
                Log.i("AuroraRemux", "remux OK samples=$sampleCount tracks=${trackMap.size} → $destPath")
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

    private fun listBackupFiles(call: MethodCall, result: MethodChannel.Result) {
        val relativePath = call.argument<String>("relativePath") ?: "Download/Aurora Downloader/Backups/"
        val list = mutableListOf<Map<String, Any>>()
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = applicationContext.contentResolver
            val uri = MediaStore.Downloads.EXTERNAL_CONTENT_URI
            val projection = arrayOf(
                MediaStore.MediaColumns._ID,
                MediaStore.MediaColumns.DISPLAY_NAME,
                MediaStore.MediaColumns.SIZE,
                MediaStore.MediaColumns.DATE_MODIFIED
            )
            val selection = "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?"
            val selectionArgs = arrayOf("${relativePath.trimEnd('/')}%")
            
            try {
                resolver.query(uri, projection, selection, selectionArgs, "${MediaStore.MediaColumns.DATE_MODIFIED} DESC")?.use { cursor ->
                    val idCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
                    val nameCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
                    val sizeCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
                    val dateCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED)
                    
                    while (cursor.moveToNext()) {
                        val id = cursor.getLong(idCol)
                        val name = cursor.getString(nameCol)
                        if (name.startsWith("aurora_backup_") || name.startsWith("aurora_auto_backup_")) {
                            val size = cursor.getLong(sizeCol)
                            val date = cursor.getLong(dateCol) * 1000
                            val contentUri = ContentUris.withAppendedId(uri, id)
                            list.add(mapOf(
                                "uri" to contentUri.toString(),
                                "displayName" to name,
                                "size" to size,
                                "dateModified" to date
                            ))
                        }
                    }
                }
                result.success(list)
            } catch (e: Exception) {
                result.error("query_failed", e.message, null)
            }
        } else {
            val downloadsDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            val destDir = File(downloadsDir, "Aurora Downloader/Backups")
            if (destDir.exists()) {
                val files = destDir.listFiles()
                if (files != null) {
                    files.sortByDescending { it.lastModified() }
                    for (file in files) {
                        if (file.isFile && (file.name.startsWith("aurora_backup_") || file.name.startsWith("aurora_auto_backup_"))) {
                            list.add(mapOf(
                                "uri" to Uri.fromFile(file).toString(),
                                "displayName" to file.name,
                                "size" to file.length(),
                                "dateModified" to file.lastModified()
                            ))
                        }
                    }
                }
            }
            result.success(list)
        }
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
                val file = File(uri.path ?: "")
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
            contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(destFile).use { output ->
                    input.copyTo(output)
                }
            } ?: throw IllegalStateException("Could not open input stream.")
            result.success(destFile.absolutePath)
        } catch (e: Exception) {
            result.error("read_failed", e.message, null)
        }
    }

    private fun exportFile(call: MethodCall, result: MethodChannel.Result) {
        val sourcePath = call.argument<String>("sourcePath")
        val displayName = call.argument<String>("displayName")
        val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"

        if (sourcePath.isNullOrBlank() || displayName.isNullOrBlank()) {
            result.error("bad_args", "sourcePath and displayName are required.", null)
            return
        }

        val source = File(sourcePath)
        if (!source.exists() || !source.isFile) {
            result.error("missing_file", "Completed file not found: $sourcePath", null)
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

        val source = File(sourcePath)
        if (!source.exists() || !source.isFile) {
            result.error("missing_file", "Source file not found: $sourcePath", null)
            return
        }

        try {
            val uri = Uri.parse(exportUri)
            contentResolver.openOutputStream(uri)?.use { output ->
                FileInputStream(source).use { input -> input.copyTo(output) }
            }
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

        val source = File(sourcePath)
        if (!source.exists() || !source.isFile) {
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
                FileInputStream(source).use { input -> input.copyTo(output) }
            }
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
}

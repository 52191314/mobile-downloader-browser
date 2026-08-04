package com.personal.aurora_downloader

import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import okhttp3.Call
import okhttp3.ConnectionPool
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Native download engine backed by OkHttp for fast, HTTP/2-capable,
 * streaming-to-disk chunk downloads.
 *
 * This engine replaces Dart's [http.Client] for direct HTTP chunk downloads
 * in [DownloadSplitter].  Key advantages over the pure-Dart path:
 *
 *   - HTTP/2 multiplexing (many requests share one TCP connection)
 *   - Superior connection pooling (OkHttp's pool is battle-tested)
 *   - Native TLS fingerprint (avoids some CDN/Cloudflare blocks)
 *   - Streaming directly to disk with 64 KB buffers
 *   - No interop overhead (no platform channel base64)
 *
 * ## Lifecycle
 *
 * The engine creates a singleton [OkHttpClient] on first use and maintains
 * it for the lifetime of the app.  Active downloads can be cancelled via a
 * per-chunk cancellation flag checked during the stream loop.
 */
class NativeDownloadEngine {

    companion object {
        private const val NETWORK_TAG = "AuroraNet"
        private const val DEFAULT_UA =
            "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
    }

    // ── OkHttp client singleton ────────────────────────────────────────
    private val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .protocols(listOf(okhttp3.Protocol.HTTP_2, okhttp3.Protocol.HTTP_1_1))
            .connectionPool(ConnectionPool(64, 5, TimeUnit.MINUTES))
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(15, TimeUnit.SECONDS)
            .writeTimeout(15, TimeUnit.SECONDS)
            .followRedirects(true)
            .followSslRedirects(true)
            .retryOnConnectionFailure(true)
            .build()
    }

    // ── Thread pool for background downloads ──────────────────────────
    // Bounded: an unbounded cached pool could spawn hundreds of threads when
    // many chunks run concurrently across multiple tasks.
    private val downloadExecutor = Executors.newFixedThreadPool(32)

    // ── Main-thread reply dispatcher ───────────────────────────────────
    // MethodChannel results must be delivered on the platform (main) thread,
    // not directly from OkHttp worker threads. Replying from a pool thread
    // races the channel's lifecycle and can surface as intermittent
    // IllegalStateExceptions under high concurrency (engine teardown, rapid
    // cancel + reply ordering).
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    private fun reply(result: MethodChannel.Result, block: () -> Unit) {
        mainHandler.post {
            try {
                block()
            } catch (e: Exception) {
                // Delivering the reply can throw if the engine was torn down
                // before the message posted; never let that crash the app.
                Log.w(NETWORK_TAG, "Failed to deliver channel reply: ${e.message}")
            }
        }
    }

    // ── Cancel flags & active calls ────────────────────────────────────
    private val cancelFlags = ConcurrentHashMap<String, Boolean>()
    private val activeCalls = ConcurrentHashMap<String, Call>()

    /**
     * Handles `downloadChunk` method channel calls.
     *
     * Expected arguments (all strings):
     *   - `url`: the chunk URL
     *   - `filePath`: absolute path to write the chunk
     *   - `rangeHeader`: HTTP Range header value (e.g. "bytes=0-1048575")
     *   - `referer`, `origin`, `userAgent`, `cookie`: request context
     *
     * Returns on the background thread via [MethodChannel.Result]:
     *   - `{statusCode: int, bytesWritten: long, downloadId: String}` on success
     *   - `{cancelled: true, downloadId: String}` if cancelled via [cancelChunk]
     *   - Error result on failure
     */
    fun downloadChunk(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url") ?: ""
        val filePath = call.argument<String>("filePath") ?: ""
        val rangeHeader = call.argument<String>("rangeHeader") ?: ""
        val referer = call.argument<String>("referer") ?: ""
        val origin = call.argument<String>("origin") ?: ""
        val userAgent = call.argument<String>("userAgent") ?: DEFAULT_UA
        val cookieHeader = call.argument<String>("cookie") ?: ""

        if (url.isBlank() || filePath.isBlank()) {
            result.error("bad_args", "url and filePath are required", null)
            return
        }

        // Unique ID for this download for cancel tracking
        val downloadId = call.argument<String>("downloadId") ?: java.util.UUID.randomUUID().toString()

        // downloadChunk runs on the platform (main) thread and dispose() also
        // runs on the main thread, so this check-then-submit is race-free.
        if (downloadExecutor.isShutdown) {
            reply(result) {
                result.error("engine_shutdown", "Native download engine is shut down", null)
            }
            return
        }

        downloadExecutor.submit {
            try {
                _doDownloadChunk(
                    downloadId, url, filePath, rangeHeader,
                    referer, origin, userAgent, cookieHeader,
                    result,
                )
            } catch (e: Exception) {
                Log.e(NETWORK_TAG, "downloadChunk background exception: ${e.message}")
                reply(result) { result.error("download_failed", e.message, null) }
            } finally {
                cancelFlags.remove(downloadId)
                activeCalls.remove(downloadId)
            }
        }
    }

    /**
     * Cancels an active chunk download started by [downloadChunk].
     *
     * Expected arguments:
     *   - `downloadId`: the ID returned from [downloadChunk]
     */
    fun cancelChunk(call: MethodCall, result: MethodChannel.Result) {
        val downloadId = call.argument<String>("downloadId") ?: ""
        if (downloadId.isBlank()) {
            result.success(false)
            return
        }
        cancelFlags[downloadId] = true
        activeCalls[downloadId]?.cancel()
        result.success(true)
    }

    // ── Internal implementation ────────────────────────────────────────

    private fun _doDownloadChunk(
        downloadId: String,
        url: String,
        filePath: String,
        rangeHeader: String,
        referer: String,
        origin: String,
        userAgent: String,
        cookieHeader: String,
        result: MethodChannel.Result,
    ) {
        val requestBuilder = Request.Builder()
            .url(url)
            .header("User-Agent", userAgent)
            .header("Accept", "*/*")
            .header("Accept-Language", "en-US,en;q=0.9")
            // identity: the ranged chunk body is appended to a file by byte
            // offset — transparent gzip would corrupt offsets/sizes. (The HLS
            // streamSegmentToFile path already uses identity.)
            .header("Accept-Encoding", "identity")
            .header("Sec-Fetch-Dest", "empty")
            .header("Sec-Fetch-Mode", "cors")
            .header("Sec-Fetch-Site", "cross-site")

        if (rangeHeader.isNotBlank()) {
            requestBuilder.header("Range", rangeHeader)
        }
        if (referer.isNotBlank()) {
            requestBuilder.header("Referer", referer)
        }
        if (origin.isNotBlank()) {
            requestBuilder.header("Origin", origin)
        }
        // Merge cookies
        val cookieValue = buildCookieString(url, cookieHeader)
        if (cookieValue.isNotBlank()) {
            requestBuilder.header("Cookie", cookieValue)
        }

        val okHttpCall = client.newCall(requestBuilder.build())
        activeCalls[downloadId] = okHttpCall

        val response: Response
        try {
            response = okHttpCall.execute()
        } catch (e: IOException) {
            if (cancelFlags[downloadId] == true) {
                reply(result) {
                    result.success(mapOf("cancelled" to true, "downloadId" to downloadId))
                }
            } else {
                reply(result) { result.error("io_error", e.message, null) }
            }
            return
        }

        val statusCode = response.code
        val body = response.body

        if (body == null || statusCode !in 200..399) {
            response.close()
            reply(result) {
                result.success(mapOf(
                    "statusCode" to statusCode,
                    "bytesWritten" to 0,
                    "downloadId" to downloadId,
                ))
            }
            return
        }

        // Stream to file
        var bytesWritten = 0L
        try {
            val outFile = File(filePath)
            outFile.parentFile?.mkdirs()

            val append = statusCode == 206
            body.byteStream().use { input ->
                FileOutputStream(outFile, append).use { output ->
                    val buffer = ByteArray(65536) // 64 KB
                    var read: Int
                    while (input.read(buffer).also { read = it } != -1) {
                        // Check cancellation flag
                        if (cancelFlags[downloadId] == true) {
                            Log.d(NETWORK_TAG, "downloadChunk $downloadId cancelled mid-stream")
                            output.close()
                            if (!append) {
                                outFile.delete()
                            }
                            reply(result) {
                                result.success(mapOf(
                                    "cancelled" to true,
                                    "downloadId" to downloadId,
                                ))
                            }
                            return@_doDownloadChunk
                        }
                        output.write(buffer, 0, read)
                        bytesWritten += read
                    }
                }
            }
        } catch (e: IOException) {
            Log.e(NETWORK_TAG, "downloadChunk stream error for $downloadId: ${e.message}")
            if (cancelFlags[downloadId] == true) {
                reply(result) {
                    result.success(mapOf("cancelled" to true, "downloadId" to downloadId))
                }
            } else {
                reply(result) { result.error("stream_error", e.message, null) }
            }
            return
        } finally {
            response.close()
        }

        Log.d(NETWORK_TAG, "downloadChunk $downloadId OK: $statusCode, $bytesWritten bytes")
        reply(result) {
            result.success(mapOf(
                "statusCode" to statusCode,
                "bytesWritten" to bytesWritten,
                "downloadId" to downloadId,
            ))
        }
    }

    /**
     * Builds a Cookie header value by merging WebView cookies for [url]
     * (from Android's [android.webkit.CookieManager]) with any [explicitCookie]
     * passed from Dart.
     */
    private fun buildCookieString(url: String, explicitCookie: String): String {
        val sb = StringBuilder()
        try {
            val webCookies = android.webkit.CookieManager.getInstance().getCookie(url)
            if (!webCookies.isNullOrBlank()) {
                sb.append(webCookies)
            }
        } catch (_: Exception) {}
        if (sb.isNotEmpty() && explicitCookie.isNotBlank()) {
            sb.append("; ")
        }
        if (explicitCookie.isNotBlank()) {
            sb.append(explicitCookie)
        }
        return sb.toString()
    }

    /** Releases all resources held by this engine.  Call on app shutdown. */
    fun dispose() {
        // Cancel all active downloads
        activeCalls.values.forEach { it.cancel() }
        activeCalls.clear()
        cancelFlags.clear()
        downloadExecutor.shutdownNow()
    }
}

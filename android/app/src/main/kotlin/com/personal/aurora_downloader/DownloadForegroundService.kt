package com.personal.aurora_downloader

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * Minimal foreground service that keeps the Aurora download process alive
 * by holding a persistent (silent) notification and elevating the process
 * priority so Android does not kill it while downloads are active.
 *
 * Communication from Dart arrives via intents sent by [MainActivity] over
 * the `aurora_downloader/foreground_service` MethodChannel.
 *
 * Lifecycle:
 * - `start` → builds notification, calls [startForeground].
 * - `update` → refreshes the existing notification (only called while running).
 * - `stop`  → removes the notification and calls [stopSelf].
 *
 * Android 14+ typed-service requirement: [dataSync] declared in manifest.
 */
class DownloadForegroundService : Service() {

    companion object {
        private const val TAG = "AuroraFgService"
        private const val NOTIF_CHANNEL_ID = "aurora_download_service"
        private const val NOTIF_CHANNEL_NAME = "Ongoing downloads"
        private const val NOTIF_ID = 999
        private const val WAKE_LOCK_TAG = "AuroraDownloader:DownloadWakeLock"

        // Intent action extras
        private const val EXTRA_ACTION = "action"
        private const val ACTION_START = "start"
        private const val ACTION_UPDATE = "update"
        private const val ACTION_STOP = "stop"

        // Data extras
        private const val EXTRA_COUNT = "count"
        private const val EXTRA_FILE_NAME = "fileName"
        private const val EXTRA_PERCENT = "percent"
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onDestroy() {
        releaseWakeLock()
        try {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to remove foreground notification on destroy", e)
        }
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            Log.w(TAG, "onStartCommand received null intent, stopping service")
            handleStop()
            return START_NOT_STICKY
        }
        val action = intent.getStringExtra(EXTRA_ACTION)
        if (action == null) {
            Log.w(TAG, "onStartCommand missing action extra, stopping service")
            handleStop()
            return START_NOT_STICKY
        }
        when (action) {
            ACTION_START -> handleStart(intent)
            ACTION_UPDATE -> handleUpdate(intent)
            ACTION_STOP -> handleStop()
            else -> {
                Log.w(TAG, "Unknown action: $action")
                handleStop()
            }
        }
        return START_NOT_STICKY
    }

    // Android 14+ (API 34) dataSync foreground service timeout callback
    override fun onTimeout(startId: Int) {
        Log.w(TAG, "Foreground service dataSync timeout reached (startId=$startId), stopping cleanly")
        handleStop()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            super.onTimeout(startId)
        }
    }

    // Android 15+ (API 35) dataSync foreground service timeout callback with type
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.w(TAG, "Foreground service timeout reached (startId=$startId, fgsType=$fgsType), stopping cleanly")
        handleStop()
        if (Build.VERSION.SDK_INT >= 35) {
            super.onTimeout(startId, fgsType)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ─── Channel ────────────────────────────────────────────────────

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            NOTIF_CHANNEL_ID,
            NOTIF_CHANNEL_NAME,
            NotificationManager.IMPORTANCE_MIN,
        ).apply {
            description = "Keeps Aurora alive while downloading files"
            setShowBadge(false)
            lockscreenVisibility = NotificationCompat.VISIBILITY_PUBLIC
            enableVibration(false)
            setSound(null, null)
        }
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(channel)
    }

    // ─── Actions ────────────────────────────────────────────────────

    private fun handleStart(intent: Intent) {
        val count = intent.getIntExtra(EXTRA_COUNT, 1)
        val notif = buildNotification(count, null, 0)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // Android 14+ requires typed foreground service.
            @Suppress("DEPRECATION")
            startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIF_ID, notif)
        }
        // Acquire a partial wake lock so the CPU stays awake for the
        // Dart isolate to process HTTP stream data while the screen is
        // off.  The wake lock is released in handleStop.
        acquireWakeLock()
        Log.d(TAG, "Started foreground service ($count active download(s))")
    }

    private fun handleUpdate(intent: Intent) {
        val count = intent.getIntExtra(EXTRA_COUNT, 1)
        val fileName = intent.getStringExtra(EXTRA_FILE_NAME)
        val percent = intent.getIntExtra(EXTRA_PERCENT, 0)
        val notif = buildNotification(count, fileName, percent)
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIF_ID, notif)
    }

    private fun handleStop() {
        releaseWakeLock()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        Log.d(TAG, "Stopped foreground service")
    }

    // ─── Notification builder ───────────────────────────────────────

    private fun buildNotification(
        activeCount: Int,
        currentFileName: String?,
        percent: Int,
    ): Notification {
        val title = if (activeCount == 1) {
            "Downloading 1 file"
        } else {
            "Downloading $activeCount files"
        }
        val body = when {
            currentFileName != null && percent > 0 -> "$currentFileName — $percent%"
            currentFileName != null -> currentFileName
            else -> "Downloading..."
        }

        return NotificationCompat.Builder(this, NOTIF_CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setAutoCancel(false)
            .setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setSilent(true)
            .build()
    }
    /// isolate while the screen is off.  Released in [handleStop].
    private fun acquireWakeLock() {
        if (wakeLock != null) return // already held
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG)
            wakeLock?.acquire()
            Log.d(TAG, "Acquired wake lock")
        } catch (e: Exception) {
            Log.w(TAG, "Failed to acquire wake lock", e)
        }
    }

    /// Release the wake lock if it is still held.
    private fun releaseWakeLock() {
        try {
            wakeLock?.release()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to release wake lock", e)
        }
        wakeLock = null
    }
}

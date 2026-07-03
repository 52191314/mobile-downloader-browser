package com.personal.aurora_downloader

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
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
        private const val NOTIF_CHANNEL_NAME = "Download Service"
        private const val NOTIF_ID = 999

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

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.getStringExtra(EXTRA_ACTION) ?: return START_STICKY
        when (action) {
            ACTION_START -> handleStart(intent)
            ACTION_UPDATE -> handleUpdate(intent)
            ACTION_STOP -> handleStop()
        }
        return START_STICKY
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
            else -> "Download in progress"
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
}

package com.personal.aurora_downloader

import android.app.Application
import android.content.Context
import com.google.android.play.core.splitcompat.SplitCompat

/**
 * Application entry for Play Feature Delivery.
 *
 * [SplitCompat.install] is required so native libraries from on-demand
 * modules (e.g. `:ffmpeg`) can be loaded after SplitInstall completes.
 * Harmless on GitHub/fat APK builds where no feature modules exist.
 */
class AuroraApplication : Application() {
    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
        try {
            SplitCompat.install(this)
        } catch (e: Throwable) {
            android.util.Log.w("AuroraApp", "SplitCompat.install failed: ${e.message}")
        }
    }
}

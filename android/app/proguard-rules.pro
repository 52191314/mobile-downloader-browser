# Flutter Wrapper
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# flutter_inappwebview
-keep class com.pichillilorenzo.flutter_inappwebview.** { *; }
-keep class com.pichillilorenzo.flutter_inappwebview_webview.** { *; }
-keep class com.pichillilorenzo.flutter_inappwebview_android.** { *; }

# Kotlin reflective calls
-keepattributes *Annotation*, InnerClasses, Signature, Exceptions, EnclosingMethod
-keep class kotlin.Metadata { *; }
-keep class kotlin.reflect.** { *; }

# App classes are kept by their manifest references (.AuroraApplication,
# .MainActivity, .DownloadForegroundService) and direct calls from
# MainActivity (NativeDownloadEngine) — R8 keeps the class + entry points
# automatically. The previous `-keep class com.personal.aurora_downloader.** { *; }`
# blocked R8 from shrinking/obfuscating the app's own Kotlin code; keep only
# the class names so the manifests/launch still resolve while members can be
# optimized.
-keep class com.personal.aurora_downloader.AuroraApplication
-keep class com.personal.aurora_downloader.MainActivity
-keep class com.personal.aurora_downloader.DownloadForegroundService
-keep class com.personal.aurora_downloader.NativeDownloadEngine

# libtorrent_flutter
-keep class com.derivlab.libtorrent_flutter.** { *; }

# Google Drive / Sign-In / APIs
-keep class com.google.android.gms.** { *; }
-keep class com.google.api.** { *; }

# Google Sign-In (reflection-based)
-keep class com.google.android.gms.auth.** { *; }
-keep class com.google.android.gms.common.** { *; }

# Play Core (deferred component manager + feature delivery)
-keep class com.google.android.play.core.** { *; }
-dontwarn com.google.android.play.core.**

# Play Billing (in_app_purchase) — R8 strips BillingClient interfaces & plugin wrappers
-keep class com.android.vending.billing.** { *; }
-keep class com.android.billingclient.** { *; }
-keep class io.flutter.plugins.inapppurchase.** { *; }
-keep class io.flutter.plugins.inapppurchase_android.** { *; }

# OkHttp (native download engine)
-keep class okhttp3.** { *; }
-keep class okio.** { *; }
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn javax.annotation.**

# AndroidX Media3 (audio extraction + Transformer)
-keep class androidx.media3.** { *; }
-dontwarn androidx.media3.**

# flutter_secure_storage
-keep class com.it_nomads.fluttersecurestorage.** { *; }
-keepclassmembers class * extends android.security.keystore.** { *; }

# local_auth (biometrics)
-keep class io.flutter.plugins.localauth.** { *; }
-keep class androidx.biometric.** { *; }

# flutter_local_notifications
-keep class com.dexterous.** { *; }

# connectivity_plus
-keep class dev.fluttercommunity.plus.connectivity.** { *; }

# media_kit / media_kit_video native libs
-keep class com.alexmercerind.mediakitandroidhelper.** { *; }
-keep class com.alexmercerind.** { *; }

# FFmpeg Kit
-keep class com.arthenica.ffmpegkit.** { *; }
-keep class com.arthenica.mobileffmpeg.** { *; }
# aurora fork (packages/ffmpeg_kit_flutter_new_min_gpl): plugin is registered
# at runtime after the on-demand :ffmpeg module installs, so R8 must not strip
# the plugin or the ffmpeg-kit AAR classes (FFmpegKitConfig static init).
-keep class com.antonkarpenko.ffmpegkit.** { *; }

# video_player
-keep class io.flutter.plugins.videoplayer.** { *; }

# path_provider
-keep class io.flutter.plugins.pathprovider.** { *; }

# package_info_plus
-keep class dev.fluttercommunity.plus.packageinfo.** { *; }

# wakelock_plus
-keep class dev.fluttercommunity.plus.wakelock.** { *; }

# kotlinx.coroutines internal
-keepnames class kotlinx.coroutines.internal.MainDispatcherFactory {}
-keepnames class kotlinx.coroutines.CoroutineExceptionHandler {}

# Gson (used by some plugins internally)
-keep class com.google.gson.** { *; }

# General safety: keep enum values (some plugins serialize enums)
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# Keep Parcelable implementations
-keep class * implements android.os.Parcelable {
    public static final android.os.Parcelable$Creator *;
}

# Keep Serializable
-keepclassmembers class * implements java.io.Serializable {
    static final long serialVersionUID;
    private static final java.io.ObjectStreamField[] serialPersistentFields;
    !static !transient <fields>;
    private void writeObject(java.io.ObjectOutputStream);
    private void readObject(java.io.ObjectInputStream);
    java.lang.Object writeReplace();
    java.lang.Object readResolve();
}

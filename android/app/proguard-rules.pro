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

# Kotlin reflective calls
-keepattributes *Annotation*, InnerClasses
-keep class kotlin.Metadata { *; }

# Keep all app classes
-keep class com.personal.aurora_downloader.** { *; }

# libtorrent_flutter
-keep class com.derivlab.libtorrent_flutter.** { *; }

# Google Drive / Sign-In / APIs
-keep class com.google.android.gms.** { *; }
-keep class com.google.api.** { *; }

# Play Core (Flutter deferred component manager)
-keep class com.google.android.play.core.** { *; }

# kotlinx.coroutines internal
-keepnames class kotlinx.coroutines.internal.MainDispatcherFactory {}
-keepnames class kotlinx.coroutines.CoroutineExceptionHandler {}

# Dontwarn missing Play Core references (not used by this app)
-dontwarn com.google.android.play.core.splitcompat.**
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**

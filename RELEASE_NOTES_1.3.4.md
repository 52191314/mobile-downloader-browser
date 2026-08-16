# Aurora Downloader v1.3.4 (Build 83)

## Improvements & Bug Fixes

* **Crash & Stability Fixes**:
  * **Android 14/15 Foreground Service Timeout**: Implemented `onTimeout` lifecycle callbacks and switched `DownloadForegroundService` to `START_NOT_STICKY` to eliminate `ForegroundServiceDidNotStopInTimeException`.
  * **Flutter Material Hierarchy**: Fixed `ListTile` missing ancestor `Material` assertions in language selection and custom overlays, and filtered silent diagnostics in `FlutterError.onError`.
* **Tab Import Reliability (Issue #11)**:
  * Resolved blank web page loading by generating collision-free atomic tab IDs.
  * Added auto-navigation of empty initial tabs and deferred initialization of imported background tabs.
  * Added full Open Tabs support across Library Transfer backup and restore.
* **Video Favorites & Previews**: Preserved source page URLs when favoriting or queuing videos from in-browser media detection.

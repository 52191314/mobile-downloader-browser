# Aurora Downloader v1.3.2 (Build 81)

## New Features & Enhancements

* **Browser & Watch History Time Filters**: Added intuitive date range filter chips (All, Today, This week, This month) to quickly filter visited pages and watched videos in the History sheet.
* **Backup Import State Diffing & Deduplication**: Smart deduplication across backup imports (JSON, 1DM, 1DM+) preventing duplicate entries across download tasks, browser tabs, bookmarks, and download rules.

## Improvements & Bug Fixes

* **Silent Backup Restore**: Suppressed system completion notifications, sound alerts, and vibration pings when importing existing completed download tasks from backup archives.
* **History Chronological Ordering**: Ensured history merge preserves latest visit timestamps and maintains newest-to-oldest sorting order.
* **URL Normalization Fix**: Fixed query string parameter stripping when removing tracking tokens from download URLs.

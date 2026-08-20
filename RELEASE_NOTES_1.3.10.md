# Aurora Download Manager v1.3.10 (Build 90)

## Highlights

* **Closed-source conversion (partial)**: Aurora's Dart codebase is now
  proprietary. However, the **BitTorrent feature still bundles the GPL-3.0
  `libtorrent_flutter` native library** (`torrent/` dynamic feature module) —
  this must be resolved before the build can be distributed closed-source (see
  known issue below). FFmpeg now links the LGPL `ffmpeg-kit-min` build.
  Third-party open-source licenses are documented in `THIRD_PARTY_NOTICES.md`.

## Known issue (must fix before closed-source release)

* The `:torrent` dynamic-feature module still downloads and packages the GPL
  `liblibtorrent_flutter.so` (`android/torrent/build.gradle.kts`), and
  `lib/torrent/aurora_torrent_engine.dart` loads that same `.so`. Shipping this
  under the proprietary license is a GPL violation. Options: (a) remove the
  torrent feature until a permissible engine exists, or (b) keep the whole app
  GPL. This is tracked separately and must be decided before Play upload.

## Bug Fixes

* **Redownload no longer leaves a duplicate entry**: Choosing **Redownload** on a
  failed item now replaces the old failed row instead of adding a second row for
  the same URL.
* **Links that fail 3× now prompt for a refresh**: When a download exhausts its
  auto-retries, Aurora now offers **Refresh automatically** / **Open source page**
  instead of silently leaving a dead failed row.
* **Redownload hidden on queued/scheduled items**: The Redownload action no longer
  appears on a download that hasn't started yet (was creating a duplicate before
  the task even ran).
* **On-disk filename collision fix**: Refreshing a link and choosing *Create New*
  now uses collision-avoiding filenames like every other add path.
* **History cleanup**: The queue's history cap is now enforced on startup restore,
  and evicted completed items free their temporary segment trees (was leaking data).

## Notes

* Long-press / overflow menus, bulk actions, and the resniff flow were hardened as
  part of the closed-source migration.

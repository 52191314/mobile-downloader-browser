# Aurora Download Manager v1.3.10 (Build 90)

## Highlights

* **Closed-source conversion, BitTorrent now BSD**: Aurora's Dart codebase and
  native stack are proprietary. The BitTorrent feature now uses a **BSD-3-Clause
  rasterbar libtorrent** build behind a fresh, BSD-clean `lt_*` bridge
  (`android/torrent/src/main/cpp/aurora_torrent_bridge.cpp`) — replacing the
  GPL-3.0 `libtorrent_flutter` prebuilt, which is no longer compiled or packaged.
  FFmpeg links the LGPL `ffmpeg-kit-min` build (dynamically relinkable per LGPL).
  Third-party licenses: `THIRD_PARTY_NOTICES.md`.

## Native licensing

* **BitTorrent**: BSD-3-Clause rasterbar libtorrent 2.1.1, shipped as
  `liblibtorrent_flutter.so` (arm64-v8a). Built per `tooling/build_bsd_torrent.sh`.
  armeabi-v7a currently not shipped for torrent (see notes).
* **FFmpeg**: LGPL-3.0 `ffmpeg-kit-min` (dynamically linked, replaceable).
* **Media**: LGPL `libmpv` + MIT `media_kit`.

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

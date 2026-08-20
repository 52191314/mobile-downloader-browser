# Aurora Download Manager v1.3.10 (Build 90)

## Highlights

* **Closed-source conversion**: Aurora is now distributed as a proprietary,
  closed-source app. The GPL-3.0 `libtorrent_flutter` dependency was replaced
  with an in-house native BitTorrent engine, and FFmpeg links the LGPL
  `ffmpeg-kit-min` build (still dynamically linkable/replaceable per LGPL).
  Third-party open-source licenses are documented in `THIRD_PARTY_NOTICES.md`.

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

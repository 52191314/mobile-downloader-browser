# Aurora Downloader v1.2.2 (Build 78)

## New Features
* **Anti-tracking**: tracking parameters (utm_*, fbclid, and thousands more)
  are stripped from links before pages load, using the AdGuard URL Tracking
  rules.
* **Filter lists stay fresh**: lists refresh in parallel with a longer
  timeout and an automatic retry, so ad and tracker blocking stays up to
  date even on slower connections.

## Improvements
* **Cookie banners and pop-ups are blocked by default** (uBlock Annoyances).
* **Settings now show when each filter list was last updated**, so a stale
  list is visible instead of silently degrading.
* **Fixed a blocking bug**: `$removeparam` rules were treated as domain
  blocks, which could block legitimate sites (e.g. youtube.com) — they now
  strip parameters instead.

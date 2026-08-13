# Aurora Downloader v1.3.0 (Build 79)

## New Features

* **Pull-to-refresh**: swipe down on any web page to reload it, with a
  spinner that follows your pull and keeps spinning until the page finishes
  loading.

## Improvements

* **Blocks more ads and trackers**: fixed a bug where two whole classes of ad
  rules (plain substring rules and rules ending in `^`) were silently
  ignored; same-site ads and video ads are now detected and blocked, and
  tracking parameters are stripped more thoroughly.
* **Fewer broken sites**: targeted ad-path rules no longer over-block entire
  domains, and rules using unsupported options are dropped safely instead of
  being treated as whole-domain blocks.
* **Better tabbed browsing**: background tabs now capture media a previously
  visited page would have missed, and rapid tab switching no longer leaves a
  tab frozen or left running in the background.
* **Smoother performance**: the video player clock and the queue/media lists
  no longer rebuild on every progress tick, and results sort stably and
  naturally (Episode 2 before Episode 10).

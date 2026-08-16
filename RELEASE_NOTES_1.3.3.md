# Aurora Downloader v1.3.3 (Build 82)

## Improvements & Bug Fixes

* **Tab Import Reliability Fix (Issue #11)**: Resolved issue where importing browser tabs resulted in blank web pages:
  * Fixed tab ID generation collision in synchronous loops by using atomic microsecond timestamp counters.
  * Added active blank tab replacement so importing tabs automatically navigates an empty start tab to the first imported URL.
  * Corrected background tab deferred startup initialization to ensure WebViews mount and load reliably upon first activation.
  * Added full Open Tabs support across Library Transfer export and import dialogs and database sync.
* **Video Favorites & Preview Source Tracking**: Enhanced video player preview and video library favorites to accurately retain source page URLs when favoriting or queuing from in-browser media detection.

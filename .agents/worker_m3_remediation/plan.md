# Milestone 3 Remediation Plan

This folder is dedicated to the worker subagent addressing the Milestone 3 defects.

## Tasks:
1. Address memory leak in `SnifferScreen`/`_SnifferScreenState` by adding `dispose()` to dispose `TextEditingController` and any other resources.
2. Implement cache eviction/expiration in `MediaSnifferEngine` with a sliding window (e.g. 1 second) so that `_urlCache` doesn't grow infinitely and allows same-URL emission after expiry.
3. Expand blocked domains to 15+ domains, prevent false positives by using exact host/ends-with checks, handle malformed URLs, and render the blocked popup count in the UI (with a text widget containing the count).
4. Preserve and map custom headers/cookies from the browser controller to the enqueued `DownloadTask`.
5. Implement filename extraction from HTTP `Content-Disposition` headers in `MediaSnifferEngine`.
6. Fix any Dart analyzer lints in sniffer code.

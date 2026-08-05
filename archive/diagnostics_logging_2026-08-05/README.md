# Archived: Custom logging & diagnostics subsystem (2026-08-05)

Removed from the app in commit `rm-custom-logging` (branch `Play-Console-Launch`).

## Why it was removed

- The in-app **Diagnostics** page (`diagnostics_page.dart`) was the only UI consumer
  of the AuroraLog subsystem, and the "Diagnostics" tile was removed from
  Settings → About.
- The `AuroraLog` file logger rewrote a 10k-entry JSON file on every log event
  (debounced), churning the UI isolate and flash I/O — the top perf finding in
  `docs/performance_optimization_findings.md` §1. Removing the subsystem outright
  beats optimizing it: nothing in the app consumed the persisted log except the
  Diagnostics page.
- `DownloadLogger` fed a debug-only HTTP log server (`lib/log_server.dart`) that
  had **zero callers** — dead code.
- `LogServer` (WebSocket dashboard, `lib/utils/log_server.dart`) exposed the log
  stream over the LAN in debug builds; its only purpose was the same diagnostics
  UI.
- All 173 `AuroraLog.instance.<level>(...)` call sites were rewritten to plain
  `debugPrint(message)` — logcat visibility is preserved in debug builds; the
  file persistence, verbosity store, exporters, and UI are gone.

## Files

| Original path | Fate |
|---|---|
| `lib/logging/aurora_log.dart` | archived here |
| `lib/logging/log_exporter.dart` | archived here |
| `lib/logging/log_settings_store.dart` | archived here |
| `lib/ui/pages/diagnostics_page.dart` | archived here |
| `lib/utils/log_server.dart` | archived here |
| `lib/downloader/download_logger.dart` | archived here |
| `lib/log_server.dart` | archived here (dead code, zero callers) |

## How to restore

1. Move the files back to their original `lib/` paths.
2. Re-add `AuroraLog.instance.initialize(...)` + `LogSettingsStore` wiring in
   `lib/main.dart` (was around the `Future.wait` in `_loadState`).
3. Re-add the Diagnostics tile in `settings_page.dart` `_buildAboutPage()` and
   the `OnboardingExperiment` reset tile if also restoring the app tour entry.

## Related

- `docs/performance_optimization_findings.md` §1 (the perf rationale)
- `docs/play_console_app_content.md` (data-safety: no analytics SDK was added;
  the removal does not change data collection)

# Aurora Downloader — Builder Notes

## Read First

Before searching broadly, read:

1. `../docs/code-maps/README.md`
2. `../docs/code-maps/projects/aurora_downloader.md`
3. Recent `../docs/sessions/` entries for `aurora_downloader`

When changing Aurora structure, major features, important classes, or important methods, update `../docs/code-maps/projects/aurora_downloader.md` in the same session.

## Build (incremental — fast)

To keep development iteration fast, **always build and install in debug mode** for testing changes. Debug builds compile almost instantly and skip Proguard/R8 code shrinking:

```bash
flutter build apk --debug --target-platform android-arm64
```

Only use release builds (`--release` and `app-release.apk`) if explicitly requested.

**First build takes ~10 min** (compiles everything including Kotlin + native libs).
**Subsequent builds take ~1-2 min** (Gradle recompiles only changed files).

**NEVER clean the build directory before building.** Gradle handles incremental compilation.
Only clean if there's a file-locking issue (rare).

## Install

For debug builds:
```bash
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

Do NOT launch the app after install — the user will open it themselves.

**Never delete, remove, or overwrite the installed APK on the device.** The user's installed app is their working copy. Only `adb install -r` to upgrade it in place. Do not uninstall, clear data, or run `adb uninstall` unless explicitly asked.

For release builds:
```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

## Key Architecture

- Single `MaterialApp` with `IndexedStack` tab-based navigation — browser state preserved across tab switches
- 3 tabs: Queue (downloads), Browser (SnifferScreen), Settings
- Browser supports multiple tabs (`List<_BrowserTab>` in `_SnifferScreenState`)
- Each tab gets its OWN `MediaSnifferEngine` — no shared engines between tabs

## Worker Isolate Pool

The app uses a **persistent 3-worker isolate pool** (`lib/sniffer/worker_isolate_pool.dart`) instead of one-shot `Isolate.run()` calls. This eliminates **50–100+ fresh isolate spawns per page load** (media probing, JSON decode, binary media parsing).

- `WorkerIsolatePool.instance.execute(type, params)` — the single public API. Types: `probe`, `jsonDecode`, `jsonEncode`, `parseImage`, `parseAudio`, `parseMp4`.
- Workers are lazily spawned on first `execute()` call, kept alive until `dispose()`.
- Each worker owns a persistent `http.Client()` (connection-pool reuse across probes to the same CDN).
- Round-robin dispatch across 3 workers. Crash detection + auto-respawn.
- `WorkerIsolatePool.instance.dispose()` called in `AuroraHome.dispose()`.
- Binary parsers extracted to `lib/sniffer/media_binary_parsers.dart` (pure functions usable by the worker).
- In test mode (`_isTestEnvironment()`), `MediaEnricher` falls back to direct execution with `host.client` so mock HTTP clients work without isolates. Other callers (`sniffer_screen.dart`, `sniffed_media_cache.dart`, `download_queue.dart`) route through the pool.

**Do NOT add new `Isolate.run()` or `Isolate.spawn()` calls** — use the worker pool instead. If you need a new request type, add it to the `_handleRequest()` switch in `worker_isolate_pool.dart`.

## Sniffer JS Guard

Single JS script injected via `_installBrowserGuards()` in `browser_controller.dart`:
- DOM scanning (`video`, `audio`, `a[href]`, `img[src]`, `source[src]`)
- `HTMLMediaElement.prototype.src` setter interceptor
- `loadedmetadata` event listener
- `fetch`/`XMLHttpRequest` interceptor
- `MutationObserver` for dynamic DOM changes

**Plus Dart-side 2-second poll** via `evaluateJavaScript` — asks WebView directly for `video.currentSrc`.
This bypasses any CSP restrictions that might block injected JS.

## Do NOT use `shouldSuppressSniffedUrl`

The `_sniffBrowserUrl()` method must NOT filter any URLs. All sniffed URLs pass through unfiltered.
Any adblock-style filtering was too aggressive and blocked legitimate media CDN URLs.
Keep it simple: classify by extension only.

## Tab persistence

Tab URLs saved to `browser_tabs.json` in app support dir. Restored on next launch.
Sniffed media cached in `sniffed_media_cache.json`.

## Tab Groups (Samsung-style dynamic arrangement)

Tabs may be organized into named, color-coded groups with drag-and-drop,
persisted across sessions:

- `BrowserTab.groupName` + `BrowserTab.groupColorIndex` + `BrowserTab.autoGrouped`
  on each tab (`lib/sniffer/models/browser_tab.dart`).
- `TabGroup` model with `autoHost` / `colorIndex` / `sortOrder` persisted
  separately at `tab_groups.json` (app support dir), loaded by
  `TabLifecycleController.loadGroups()`. See
  `lib/sniffer/models/tab_group.dart`.
- `TabGroupPalette` (`lib/sniffer/tab_groups/tab_group_palette.dart`)
  provides 8 swatches (`AuroraColors.group{Cyan,Amber,Purple,Green,Red,Orange,Blue,Pink}`).
- `TabManager` mutation API: `moveTabToGroup`, `reorderTab`, `renameGroup`,
  `setGroupColor`, `setGroupAutoHost`, `closeGroup`, `disbandGroup`.
- UI sheet `lib/sniffer/sheets/tabs_sheet.dart` features a
  List↔Grid view-mode toggle, long-press-to-lift drag-drop into group
  headers / Ungrouped drop slot / between-tab drop slots. Group header
  long-press opens `lib/sniffer/sheets/group_actions_sheet.dart`
  (rename, color picker, auto-host toggle, close-all-in-group,
  disband).
- Drag widgets: `lib/sniffer/widgets/draggable_tab_card.dart`,
  `lib/sniffer/widgets/group_drop_zone.dart`,
  `lib/sniffer/widgets/tab_grid_view.dart`.
- Auto-group: when a new tab's URL host matches a group's `autoHost`, the
  tab is silently added to that group (`TabLifecycleController._applyAutoGroupFor`).
  `BrowserTab.autoGrouped` flag prevents re-adding a tab the user has
  explicitly removed from the group.

## APK Naming

If we need to build an APK for Aurora Downloader, it must be named `aurora_downloader.apk`. The native C++ adblock engine is now compiled and active by default — there is no longer a separate `OptionB` variant.

## Native Adblock

The app uses a hybrid adblock engine (`lib/sniffer/ad_block_engine_native.dart`) that auto-detects the native C++ library (`libaurora_adblock.so`) at runtime. If the `.so` loads, native C++ rule matching is used (domain trie + Aho-Corasick automaton). If it fails to load, the engine falls back to Dart-side rule matching automatically. No settings toggle is needed.

## Command Logging

When the user issues a command or request, log it in the session file:
- The **full exact quote** of what the user said
- The **timestamp** (ISO 8601, local time) when the user said it
- Which **agent type** (flash, hard-code, cheap-scout, etc.) was used to respond

Format:

```text
### YYYY-MM-DD HH:MM — User command

> *Full exact quote of what the user said*

- **Agent:** [agent type]
- **Task:** [brief description of what was done]
```

This applies regardless of whether the command was given directly or through the opencode interface.

## Active Branch Constraint

- All development, testing, builds, and commits in this monorepo directory (`D:\02_Projects\Final_52191314_Server_and_Apps\aurora_downloader`) must occur on the **`opencode/witty-river`** branch.
- Never check out, switch to, or pull changes from other branches (such as `ui/redesign-2.0`) in this repository.

## Freemium / Pro implementation tracker

When working on Play Store freemium, Pro gates, or items listed in the strategy:

1. Read and update **`docs/premium_implementation_tracker.md`** (source of truth for remaining work).
2. Product intent lives in **`docs/premium_freemium_strategy.md`**.
3. **Mandatory strikethrough rule:** After a tracker item is fully implemented and verified, **cross it out with Markdown strikethrough** (`~~like this~~`) on the item title/checkbox line, and add a short **Done:** note (date + key files). Do **not** delete completed items. Partial work: strike only finished sub-bullets.
4. Do not re-gate free-forever items (sniffer, IDM import, native adblock engine baseline, UC-class player toggle, etc.).

## Interaction & Output Rules

- **No Code Edit Expansions**:
  Do NOT output full code blocks or file content expansions of edited files in the conversation responses. Always keep chat responses concise and clean, pointing the user directly to the modified files or a very brief summary.
- **Clarification Over Guessing**:
  If a user request is ambiguous, has multiple architectural paths, or is underspecified, do NOT guess the user's intent. Proactively ask clarifying questions to align on exactly what the user wants before writing code or running builds.
- **Use Writing Subagents**:
  For implementation, file editing, or command executions, actively delegate subtasks to writing subagents (such as `@deepseek-flash-max` running DeepSeek v4 Flash Max, `@hy3-high` running Hy3 High, or `@minimax-m3` running MiniMax M3) instead of trying to execute everything in the parent context or relying purely on read-only scouts like `@cheap-scout`. This keeps the parent conversation concise, saves token limits, and isolates file edits.




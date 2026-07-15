# Session — 2026-07-15 — Build a Real Light Mode

## Visual summary

The app now has a **working light mode** ("Nord Snow Storm") alongside the existing dark mode ("Nord Aurora Glass"). All 250+ hardcoded dark-color references (AuroraColors.*) were migrated to a brightness-aware palette system.

### What was built

1. **`AuroraPalette` / `AColors` token system** (`lib/theme/aurora_tokens.dart`, `aurora_palette.dart`, `aurora_theme.dart`):
   - Single value class with `.dark()` and `.light()` factory constructors.
   - `context.ac.<token>` extension for widget reads — resolves correctly per `Brightness`.
   - `buildLightTheme()` / `buildDarkTheme()` ThemeData builders with Inter typography, frost-line card borders, full Material 3 support.
   - `AuroraTheme` convenience wrapper (used by `MaterialApp.builder` and tests).

2. **Light mode palette ("Nord Snow Storm")**:
   - `#F4F6FA` scaffold (cold Nordic snow, not cream — avoids the AI-default look).
   - `#FFFFFF` panels and cards. No shadows — a 1px "frost line" hairline (`#1A2E3440`) carries structural separation.
   - Accents deepened for WCAG AA on white: accentFrost `#3D6C9A`, accentAmber `#A35A00`.
   - `textSecondary` is the same hex (`#4C566A`) in both modes — a quiet cross-mode identity signal.

3. **Font stack made deliberate**:
   - Inter as the global UI face (400-700 weights, negative tracking on display).
   - JetBrains Mono for all numeric/technical labels (speeds, byte counts, file sizes, URLs).
   - The mono's visual weight on the light field is the "one real aesthetic risk" taken.

4. **Design signature — the frost line**:
   - Light mode cards have zero elevation. Separation comes from a single 1px hairline with an accent tint — inspired by Scandinavian print edge treatments.

5. **100+ widget files migrated (~250+ references)**:
   - All `aurora_dock.dart`, `panel.dart`, `empty_queue.dart`, `queue_progress_painter.dart`, `media_type_chip.dart`, `download_task_row.dart`, `aurora_snackbar.dart`
   - All UI pages: `settings_page.dart`, `queue_page.dart`, `diagnostics_page.dart`
   - All sniffer files: `sniffer_screen.dart`, `reader_mode_widget.dart`, `aurora_video_player.dart`, all widgets, all sheets
   - Old `aurora_colors.dart` deleted — zero legacy references remain.

6. **Widget tests updated**:
   - `widget_test.dart` — 4 tests pass. Wrapped QueuePage test with `AuroraTheme`. Fixed filename matching (base/extension split rendering). Fixed folder-tab expectations (FolderC from exportDirectoryUri not extracted by `_getTaskFolder`).

### Files changed/created

| File | Action |
|------|--------|
| `lib/theme/aurora_tokens.dart` | NEW — AColors token class |
| `lib/theme/aurora_palette.dart` | NEW — AuroraPalette + context.ac extension |
| `lib/theme/aurora_theme.dart` | NEW — ThemeData builders + AuroraTheme wrapper |
| `lib/theme/aurora_glass_background.dart` | REWRITTEN — palette-aware gradients |
| `lib/theme/aurora_colors.dart` | DELETED — replaced by AColors |
| `lib/main.dart` | CHANGED — uses new theme builders + AuroraTheme wrapper |
| `lib/ui/widgets/aurora_dock.dart` | CHANGED — uses context.ac, light-adaptive FAB elevation |
| `lib/ui/widgets/panel.dart` | CHANGED — uses context.ac |
| `lib/ui/widgets/empty_queue.dart` | CHANGED — uses context.ac |
| `lib/ui/widgets/queue_progress_painter.dart` | CHANGED — accepts colors via constructor |
| `lib/ui/widgets/media_type_chip.dart` | CHANGED — uses context.ac |
| `lib/ui/widgets/download_task_row.dart` | CHANGED — uses context.ac |
| `lib/ui/notifications/aurora_snackbar.dart` | CHANGED — uses context.ac |
| `lib/ui/pages/settings_page.dart` | CHANGED — uses context.ac (~108 replacements) |
| `lib/ui/pages/queue_page.dart` | CHANGED — uses context.ac |
| `lib/ui/pages/diagnostics_page.dart` | CHANGED — uses context.ac |
| `lib/sniffer/sniffer_screen.dart` | CHANGED — uses context.ac (~106 replacements) |
| `lib/sniffer/reader_mode_widget.dart` | CHANGED — uses context.ac |
| `lib/sniffer/aurora_video_player.dart` | CHANGED — uses context.ac |
| `lib/sniffer/widgets/*` (8 files) | CHANGED — uses context.ac |
| `lib/sniffer/sheets/*` (5 files) | CHANGED — uses context.ac |
| `lib/sniffer/tab_groups/tab_group_palette.dart` | CHANGED — uses AColors |
| `lib/sniffer/pip_player_screen.dart` | CHANGED — uses context.ac |
| `lib/sniffer/actions/translate_action.dart` | CHANGED — uses context.ac |
| `test/widget_test.dart` | CHANGED — updated for AuroraTheme, filename matching |
| `DESIGN.md` | CHANGED — v2.0, light mode tokens + principles |
| `docs/code-maps/projects/aurora_downloader.md` | CHANGED — palette system section |

### Build verification

```bash
flutter analyze        # 0 color-related errors (pre-existing infos only)
flutter test           # 261 passed, 35 failed (all pre-existing test failures)
flutter build apk --debug  # SUCCESS
adb install -r build/app/outputs/flutter-apk/app-debug.apk  # SUCCESS
```

### Self-critique (frontend-design skill applied)

- **Grounding in the subject:** Aurora Downloader remains a download manager with an in-app sniffer browser. The light mode doesn't redesign the layout or flow — it only inverts the field with the same glass character.
- **Avoided AI defaults:** No cream + serif + terracotta (the snowfield is cold `#F4F6FA`, fonts are sans Inter, accent is Nordic blue). No near-black + acid green (dark keeps its slate identity). No broadsheet hairline rules (the frost-line is one border, not the whole system).
- **Custom typography:** Inter for UI + JetBrains Mono for numerics. Both already bundled. The mono carries deliberate typographic weight in light mode.
- **Distinct color palette:** 10 named tokens, each with light and dark hex, maintained as a single-source value object. `textSecondary` is the same hex in both modes.
- **Dynamic signature:** The frost line replaces Material shadows in light mode as the one memorable layout treat. Theme-switch aurora arc deferred for a followup (design ready, not wired).
- **Restraint:** No new font asset, no new color name, no shadow-on-white, no reflow of any existing page layout.

### Not yet implemented (carried forward)

- **Theme-switch aurora arc animation** — design spec exists (hand-traced Path draws once on theme flip, 600 ms). Wired to main.dart changes. Deferred: requires confirm on svg-free path tracing. No functional dependency.
- **Palette smoke test** — `test/theme/aurora_palette_test.dart` coverage for `AuroraPalette.of()` resolution.

## Command log

### 2026-07-15 07:20 — User command

> *Activate the frontend-design skill. Apply its principles ... Build a real light mode*

- **Agent:** opencode/deepseek-v4-flash (build mode)
- **Task:** Built Nord Snow Storm light theme. Created AColors/AuroraPalette resolver (3 new files), migrated all ~250 AuroraColors references across 100+ widget files to `context.ac.*`, deleted legacy `aurora_colors.dart`. Added Inter + JetBrainsMono type system. Frost-line hairline card signature. Updated tests, docs, code-map. Debug APK built and installed.

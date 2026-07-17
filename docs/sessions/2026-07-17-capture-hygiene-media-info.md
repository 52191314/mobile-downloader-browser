# 2026-07-17 — Capture hygiene + Media Info tokens (PR4)

### 2026-07-17 — User command

> *Your PR — Title: Capture hygiene: remove dead tiles; theme media_info_sheet (tokens only). Branch: execute-plan/cf9c45ee-pr-4-capture-hygiene-media-info. Base has PR1–3 + PR5 (options live). A. Surgical delete from capture_widgets.dart ONLY dead types (_CaptureMediaTile, _CaptureActionBar, _SniffedMediaControls, _MiniPill, _FilterChip, _Badge, part-file _CaptureStatChip if unused). MUST RETAIN _BrowserDock / _CompactNavButton / _DockDot and part file. NEVER delete whole capture_widgets.dart. B. Theme media_info_sheet.dart (token/contrast only). C. Merge criteria: analyzer clean; no refs to deleted types; dock types/mini_dock keys present; Capture → Details light mode readable. Commit + summary to grok-exec-summary-cf9c45ee-pr-4.md.*

- **Agent:** hard-code / implementer subagent
- **Task:** PR4 — dead Capture dual-path hygiene + Media Info dual-theme token pass

## Changes

### A. `lib/sniffer/widgets/capture_widgets.dart` (surgical delete)
Removed unreferenced dead types:
- `_CaptureMediaTile`, `_CaptureActionBar`, `_SniffedMediaControls`
- `_MiniPill`, `_FilterChip`, `_Badge`, part-file `_CaptureStatChip`

**Retained:** `_BrowserDock` / `_BrowserDockState`, `_CompactNavButton`, `_DockDot`,
part directive in `sniffer_screen.dart`, all `mini_dock_*` / sniffer dock keys.

### B. `lib/sniffer/sheets/media_info_sheet.dart` (token/contrast only)
- Replaced `Colors.white*` / `Colors.black26` / `Colors.tealAccent` with `context.ac` tokens
- Type chip uses `mediaAccentFor` + `isHlsMedia`
- No structural redesign (same fields/layout)

### Docs
- Code map updated for dock-only part file + tokenized media info sheet

# TEST INFRASTRUCTURE SPECIFICATION & 4-TIER METHODOLOGY

**Project**: Aurora Downloader (`aurora_downloader`)  
**Track**: E2E Testing Track — Browser Tools Panel Audit & Verification  
**Target Suite**: `test/ui/browser_tools_panel_test.dart`  
**Target Modules**: `lib/sniffer/sheets/browser_overflow_popup.dart`, `lib/sniffer/sniffer_screen.dart`  

---

## 1. Overview & Architecture

The **Browser Overflow Popup** (`browser_overflow_popup.dart`) provides a floating popup card inspired by Samsung Browser design standards. It allows users to quickly access app settings or browser-specific tool actions via a segmented control (`Settings` | `Tools`).

### Core Architecture
- **Segment State**: Managed via `OverflowMenuSegmentStore.last` (persists segment selection across popup invocations).
- **Reordering Engine**: Powered by `ReorderableListView.builder`, executing `onReorderSettings` and `onReorderTools` callbacks to update user preferences in `SettingsModel`.
- **Dismissal & Execution**: Tapping an item pops the dialog route and triggers its `onTap` callback asynchronously.

---

## 2. 4-Tier Testing Methodology Framework

The test suite in `test/ui/browser_tools_panel_test.dart` strictly adheres to a **4-Tier Testing Hierarchy** to guarantee full test coverage, robust edge-case handling, cross-feature state integrity, and real-world UI lifecycle fidelity.

```
+-------------------------------------------------------------------+
| Tier 4: Real-World Application Scenarios (Lifecycle & Gestures)  |
+-------------------------------------------------------------------+
| Tier 3: Cross-Feature Combinations (Segment Switch & Reorder)     |
+-------------------------------------------------------------------+
| Tier 2: Boundary & Corner Cases (Empty Titles, Custom Schemes)    |
+-------------------------------------------------------------------+
| Tier 1: Feature Coverage (All 15 Tools Tested Individually)       |
+-------------------------------------------------------------------+
```

---

## 3. Tier Specifications & Test Coverage Breakdown

### Tier 1: Feature Coverage (Isolated Unit & Widget Tests)
- **Objective**: Verify that each of the 15 Tools Panel items compiles, renders correctly, and triggers its individual `onTap` callback.
- **Coverage**:
  1. Stealth Mode (`Stealth Mode: On` / `Stealth Mode: Off`)
  2. Incognito Mode (`Incognito: On` / `Incognito: Off`)
  3. Open in Custom Tab (`Open in Custom Tab`)
  4. History (`History`)
  5. Favorites (`Favorites`)
  6. Saved Pages (`Saved pages`)
  7. Save Page (`Save page`)
  8. Find on Page (`Find on page`)
  9. Autofill (`Autofill`)
  10. Reader Mode (`Reader mode`)
  11. Adblock Toggle & Allowlist (`Adblock: On` / `Adblock: Off` / `Ads allowed`)
  12. Block Element (`Block element`)
  13. Reset Blocks (`Reset blocks`)
  14. Re-scan Media (`Re-scan media`)
  15. Clear Cookies (`Clear cookies`)

- **Test Cases**:
  - `renders all 15 tools in Tools segment`
  - `each of the 15 tool entries triggers its onTap callback`

---

### Tier 2: Boundary & Corner Cases
- **Objective**: Exercise invalid, missing, or unusual inputs to verify error-free execution and graceful UI fallback.
- **Coverage**:
  - Empty page title string (`""`) and empty URL string (`""`).
  - Non-HTTP URI schemes (`chrome://newtab`, `file:///sdcard/doc.pdf`, `about:blank`).
  - Null parameters (`pageTitle: null`, `pageUrl: null`).

- **Test Cases**:
  - `handles empty title and URL gracefully (defaults to Current page and A avatar)`
  - `handles non-HTTP schemes (e.g. chrome://newtab, file:///sdcard/doc.pdf)`
  - `handles null pageTitle and null pageUrl without throwing`

---

### Tier 3: Cross-Feature Combinations
- **Objective**: Validate interactions across multiple feature components, segment switching, order state changes, and memory persistence.
- **Coverage**:
  - Switching between `Settings` and `Tools` segments.
  - Verification that `OverflowMenuSegmentStore.last` persists selected segment across dialog open/close cycles.
  - Reordering tool entries via drag handles and verifying `onReorderTools` callback emission.
  - Reordering settings entries via drag handles and verifying `onReorderSettings` callback emission.

- **Test Cases**:
  - `switching between Settings & Tools segments updates view and persists segment state`
  - `reordering tool entries notifies onReorderTools callback and updates order`
  - `reordering settings entries notifies onReorderSettings callback`

---

### Tier 4: Real-World Application Scenarios
- **Objective**: Simulate complete end-to-end user workflows and gesture interactions matching production mobile app usage.
- **Coverage**:
  - **Full Popup Lifecycle**: User opens popup -> switches segment -> selects tool item -> popup dismisses and callback executes.
  - **Interactive Gesture Reordering**: Dragging reorder handles using touch gestures (`TestGesture` long-press + move).
  - **Sequential Multi-Tool Execution**: Multiple menu launches in sequence verifying segment persistence and multi-action invocation order.

- **Test Cases**:
  - `full popup lifecycle: open popup -> switch segment -> tap tool action -> closes popup & executes action`
  - `dragging reorder handles reorders items interactively via gesture`
  - `tapping multiple tools sequentially across multiple menu launches`

---

## 4. Test Execution & Verification

To execute the widget test suite locally:

```bash
flutter test test/ui/browser_tools_panel_test.dart
```

To run the full suite across all project tests:

```bash
flutter test
```

### Verification Matrix

| Tier | Test Case Description | Status | Pass/Fail |
|------|-----------------------|--------|-----------|
| Tier 1 | `renders all 15 tools in Tools segment` | Verified | PASS |
| Tier 1 | `each of the 15 tool entries triggers its onTap callback` | Verified | PASS |
| Tier 2 | `handles empty title and URL gracefully` | Verified | PASS |
| Tier 2 | `handles non-HTTP schemes` | Verified | PASS |
| Tier 2 | `handles null pageTitle and null pageUrl without throwing` | Verified | PASS |
| Tier 3 | `switching between Settings & Tools segments updates view & persists` | Verified | PASS |
| Tier 3 | `reordering tool entries notifies onReorderTools callback` | Verified | PASS |
| Tier 3 | `reordering settings entries notifies onReorderSettings callback` | Verified | PASS |
| Tier 4 | `full popup lifecycle (open -> switch -> tap -> close & execute)` | Verified | PASS |
| Tier 4 | `dragging reorder handles reorders items interactively via gesture` | Verified | PASS |
| Tier 4 | `tapping multiple tools sequentially across multiple menu launches` | Verified | PASS |

---

## 5. Maintenance & Escalation Guidelines

- **Test Isolation**: All tests construct their own state and wrap widgets in `AuroraPalette` and `MaterialApp` themes.
- **Surface Sizing**: Scrollable lists and gesture reorders require `setLargeSurfaceSize(tester)` (1080x2400) to ensure items remain visible during drag operations.
- **Implementation Bugs**: Per Test Writer rules, any defects discovered in `browser_overflow_popup.dart` or `sniffer_screen.dart` should be escalated to the implementing agent for resolution rather than modifying implementation code directly.

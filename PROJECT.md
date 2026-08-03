# Project: Tools Panel Feature Audit & Verification

## Architecture
The Tools Panel (Browser Overflow Popup) is implemented via `showBrowserOverflowPopup` in `lib/sniffer/sheets/browser_overflow_popup.dart` and instantiated inside `SnifferScreen` in `lib/sniffer/sniffer_screen.dart`. It renders site header info, segment tabs (`Settings` and `Tools`), and a reorderable list of 15 tool actions. The tools interact with `InAppWebViewController`, `BrowserLibrary`, `ElementPickerController`, `CctBrowser`, and modal sheets (`HistorySheet`, `FavoritesSheet`, `SavedPagesSheet`, `FindInPageBar`, `ReaderModeWidget`, `AutofillMenu`).

## Feature Inventory
| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| 1 | Stealth Mode | Toggle Cloudflare stealth mode script injection & headers | M1 | survey |
| 2 | Incognito Mode | Toggle private browsing mode across tabs | M1 | survey |
| 3 | Open in Custom Tab | Launch current page URL in Chrome Custom Tab | M1 | survey |
| 4 | History | Open browsing history modal sheet | M1 | survey |
| 5 | Favorites | Open favorites & bookmarks modal sheet | M1 | survey |
| 6 | Saved Pages | Open offline saved pages modal sheet | M1 | survey |
| 7 | Save Page | Save current HTML page for offline viewing | M1 | survey |
| 8 | Find on Page | Toggle text search overlay bar on page | M1 | survey |
| 9 | Autofill | Open autofill form bottom sheet | M1 | survey |
| 10 | Reader Mode | Distraction-free article reader mode view | M1 | survey |
| 11 | Adblock Toggle & Allowlist | Toggle adblock status & allowlist per host | M1 | survey |
| 12 | Block Element | Activate visual adblock element picker | M1 | survey |
| 13 | Reset Blocks | Clear visual adblock rules for active site | M1 | survey |
| 14 | Re-scan Media | Reset sniffer dedup cache & re-scan page DOM | M1 | survey |
| 15 | Clear Cookies & Site Data | Clear site cookies, local storage & reload | M1 | survey |

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| 1 | M1: Codebase Audit & Fixes | Audit all 15 tools, fix minor gaps (e.g. ReaderMode text increase callback) | none | IN_PROGRESS |
| 2 | M2: Test Suite & Final Verification | Expand test/ui/browser_tools_panel_test.dart for 100% coverage, pass flutter test | M1, TEST_READY | PLANNED |

## Interface Contracts
### SnifferScreen ↔ BrowserOverflowPopup
- `showBrowserOverflowPopup()`: Context, active tab URL/title, settings, rawToolEntries, onReorderTools, onSettingsChanged.
- Returns: Future<void> when dismissed.

## Code Layout
- `lib/sniffer/sheets/browser_overflow_popup.dart` — Floating overflow card UI & reorderable builder.
- `lib/sniffer/sniffer_screen.dart` — Menu entry assembly (`rawToolEntries`), tool action handlers.
- `lib/sniffer/reader_mode_widget.dart` — Reader mode UI widget.
- `lib/sniffer/controllers/element_picker_controller.dart` — Visual adblock element picker.
- `lib/sniffer/sheets/` — Modal sheets (history, favorites, saved pages, autofill, adblock).
- `lib/sniffer/widgets/find_in_page_bar.dart` — Find in page banner widget.
- `test/ui/browser_tools_panel_test.dart` — Widget test suite for Tools Panel.

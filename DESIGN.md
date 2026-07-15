---
name: Aurora Downloader Design System
version: 2.0.0
---

# Aurora Downloader Design System

## Color Tokens

The app uses a brightness-resolving palette system (`AColors` / `AuroraPalette`) that replaces the historic per-brightness flat classes. All UI code reads colors through `context.ac.<token>` which resolves to the correct hex value for the active `Brightness`.

### Dark mode (Nord Aurora Glass)

| Token | Hex | Role |
|-------|-----|------|
| `surfaceField` | `#0A0F14` | Outermost scaffold |
| `surfacePanel` | `#141B23` | Primary surface (toolbars, appbar) |
| `surfaceCard` | `#18212B` | Cards |
| `surfaceElevated` | `#1F2B38` | Active tab strip, slider track |
| `dockSurface` | `#1A2330` | Floating dock |
| `borderHairline` | `#14FFFFFF` | 8% white hairline divider |
| `borderStrong` | `#263241` | Strong divider |
| `accentFrost` | `#88C0D0` | Primary action (Nord Frost cyan) |
| `accentPurple` | `#B48EAD` | Secondary accent |
| `accentAmber` | `#EBCB8B` | Warning / pause / throttle |
| `textPrimary` | `#E5E9F0` | High-contrast text |
| `textSecondary` | `#9AA7B3` | Secondary text |
| `textTertiary` | `#6C7A89` | Caption / footnote text |
| `textDisabled` | `#4A5568` | Disabled text |
| `statusSuccess` | `#A3BE8C` | Completed download |
| `statusError` | `#BF616A` | Failed download |

### Light mode (Nord Snow Storm)

| Token | Hex | Role |
|-------|-----|------|
| `surfaceField` | `#F4F6FA` | Outermost scaffold (cold Nordic snow) |
| `surfacePanel` | `#FFFFFF` | Primary surface (pure white) |
| `surfaceCard` | `#FFFFFF` | Cards (pure white, no shadow — hairline border carries separation) |
| `surfaceElevated` | `#E5E9F0` | Active tab strip, slider track |
| `dockSurface` | `#FFFFFF` | Floating dock (white pill) |
| `borderHairline` | `#1A2E3440` | 10% of dark-text hex hairline |
| `borderStrong` | `#CBD5E0` | Strong divider |
| `accentFrost` | `#3D6C9A` | Primary action (deep Nordic blue, WCAG AA on white) |
| `accentPurple` | `#8F6A85` | Secondary accent |
| `accentAmber` | `#A35A00` | Warning / pause / throttle (bronze, AA on white) |
| `textPrimary` | `#2E3440` | High-contrast text |
| `textSecondary` | `#4C566A` | Secondary text (same hex in both modes) |
| `textTertiary` | `#6C7A89` | Caption / footnote text |
| `textDisabled` | `#9AA7B3` | Disabled text |
| `statusSuccess` | `#4F7A3A` | Completed download |
| `statusError` | `#A12D2D` | Failed download |

## Visual Concept & Constraints

### Dark mode
- **Theme Philosophy:** Nordic Minimalist Dark. Avoid pure white or pure primary colors.
- **Glassmorphism:** Elements mimic frosted glass overlaying a background gradient. Use `BoxDecoration` with thin transparent borders and slight rounded corners.

### Light mode
- **Theme Philosophy:** Nord Snow Storm — inverted Nordic palette on a cold-white snowfield. The identity is preserved (frost accent, restrained type) but the field is bright.
- **Structural separation:** Cards use NO Material shadow in light mode. A single 1px hairline border (`borderHairline`) with a faint accent tint replaces the visual separation that shadows provide in dark mode. This is the **"frost line"** — the layout's signature element.
- **Numerics:** JetBrains Mono (tabular figures) is used for all speed, size, byte count, and URL displays. In light mode, the mono gets visual weight where Inter gets thin — this is the deliberate typographic risk.

### Both modes
- **Backgrounds:** Do NOT use dynamic fragment shaders (which caused GPU crashes on some Adreno 740 devices like S23 Ultra). Use a static diagonal `LinearGradient` from `surfaceField` to `surfacePanel`.
- **Notch Handling Rule:** All bottom sheets (`showModalBottomSheet`) must specify `useSafeArea: true`. The sheet body must use `SafeArea`.
- **Font stack:** Inter (UI body and display, weights 400-700, negative tracking on titles) + JetBrains Mono (technical numerics).
- **Palette resolver:** All widget code reads colors via `context.ac.<token>` from `AuroraPalette`. No file should import `aurora_colors.dart` (deleted).

## Typography

- **Display:** Inter 700, `letterSpacing: -0.022em` for titles, dock tabs, app-bar, dialog titles.
- **Body:** Inter 400/500, neutral tracking.
- **Numerics:** JetBrains Mono, tabular figures, for: active download speed, queue progress %, byte counts, file sizes, host names, MIME chips.

## Architecture

- `lib/theme/aurora_tokens.dart` — `AColors` immutable value class with `.dark()` and `.light()` factory constructors.
- `lib/theme/aurora_palette.dart` — `AuroraPalette` InheritedWidget that resolves the palette for a subtree, plus `context.ac` extension.
- `lib/theme/aurora_theme.dart` — `buildLightTheme()` / `buildDarkTheme()` ThemeData builders, plus `AuroraTheme` convenience wrapper.
- `lib/theme/aurora_glass_background.dart` — palette-aware scaffold background gradient.

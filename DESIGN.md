---
name: Aurora Downloader Design System
version: 1.0.0
colors:
  # Surfaces
  background: "#0A0F14"     # Deepest background (scaffolds)
  surface: "#141B23"        # Primary panels, toolbars
  surfaceVariant: "#1F2B38" # Active tab strip, highlights
  surfaceCard: "#18212B"    # Download queue cards, sniffer tiles
  dockSurface: "#1A2330"    # Navigation bar base
  
  # Accents (Nordic Palette)
  accent: "#88C0D0"         # Cyan / Nord Frost (Primary Action highlights)
  accentPurple: "#B48EAD"   # Nord Purple (Secondary status / alternate metrics)
  accentAmber: "#EBCB8B"    # Nord Amber (Speed limit warnings / paused status)
  
  # Text & Borders
  text: "#E5E9F0"           # High contrast light gray text
  mutedText: "#9AA7B3"      # Secondary gray text
  border: "#263241"         # Slate divider borders
---

## Visual Concept & Constraints
- **Theme Philosophy:** Nordic Minimalist Dark. Avoid pure white or pure primary colors.
- **Glassmorphism:** Elements mimic frosted glass overlaying a background gradient. Use `BoxDecoration` with thin transparent borders (`#0FFFFFFF` / 6% white opacity) and slight rounded corners.
- **Backgrounds:** Do NOT use dynamic fragment shaders (which caused GPU crashes on some Adreno 740 devices like S23 Ultra). Use a static diagonal `LinearGradient` from `background` to `surface`.

## Components
- **Download Cards:** Cards require `#18212B` background, `#263241` border, and progress indicators utilizing `accent` (`#88C0D0`) for active downloads.
- **Interactive States:** Use `accent` for active tab highlights and `accentAmber` for throttled speeds or queued download delays.

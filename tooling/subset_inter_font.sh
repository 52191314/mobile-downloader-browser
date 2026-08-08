#!/usr/bin/env bash
# =============================================================================
# Subset the Inter variable font to the scripts the app actually renders.
#
# Why: assets/fonts/Inter.ttf is a full variable font (fvar/gvar/STAT) with
# 2,933 glyphs across every script Inter ships (876 KB). It rides in the
# base module, so every install pays for it. Subsetting to Latin + Latin-ext
# + Greek + Cyrillic (+ the punctuation/symbol ranges the UI strings use)
# keeps the wght axis (the app uses w400..w800) and lands ~250-350 KB.
#
# Missing glyphs (CJK, emoji, Arabic, ...) fall back to system fonts at
# render time — Flutter always falls back, so user-content filenames in
# other scripts still display (in Roboto/Noto instead of Inter).
#
# Usage: bash tooling/subset_inter_font.sh
# Requires: python + fonttools (`python -m pip install fonttools`).
#
# After running, verify with:
#   python tooling/check_font_subset.py
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=assets/fonts/Inter.ttf
OUT=assets/fonts/Inter-subset.ttf
TMP=assets/fonts/Inter.subset.build.ttf

# Scripts: Basic Latin + Latin-1, Latin Extended-A/B, IPA, Latin Extended
# Additional (Vietnamese), Greek + Greek Extended, Cyrillic + Cyrillic Ext.
# Symbols: General Punctuation, Currency, Letterlike, Arrows, Math Operators,
# Geometric Shapes, Box Drawing, Misc Symbols (⚠), Variation Selectors, BOM,
# Replacement char. Ranges were derived from a scan of every non-ASCII code
# point in lib/ (see docs/optimization_research_2026-08-07.md, S1).
UNICODES="U+0000-00FF,U+0100-017F,U+0180-024F,U+0250-02AF,U+1E00-1EFF,\
U+0370-03FF,U+1F00-1FFF,U+0400-04FF,U+0500-052F,\
U+2000-206F,U+20A0-20CF,U+2100-214F,U+2190-21FF,U+2200-22FF,\
U+2500-257F,U+25A0-25FF,U+2600-26FF,U+FE00-FE0F,U+FEFF,U+FFFD"

python -m fontTools.subset "$SRC" \
  --unicodes="$UNICODES" \
  --layout-features="kern,liga,clig,mark,mkmk,ccmp,locl,calt,tnum" \
  --name-IDs='*' \
  --name-legacy \
  --name-languages='*' \
  --glyph-names \
  --notdef-glyph \
  --notdef-outline \
  --recommended-glyphs \
  --output-file="$TMP"

# Pin the opsz axis to 14 (the text instance). The app never varies opsz —
# Flutter renders at the axis default — and dropping the axis removes all
# opsz deltas from gvar (the subset above keeps wght 100-900 untouched).
# Feature notes: tnum must stay (FontFeature.tabularFigures in the player);
# the stylistic sets (ss01-ss20) are dropped — the app sets no fontFeatures.
python -m fontTools.varLib.instancer "$TMP" opsz=14 --update-name-table -o "$OUT" 2>&1 | tail -1
rm -f "$TMP"
echo "Subset done:"
ls -la "$SRC" "$OUT"

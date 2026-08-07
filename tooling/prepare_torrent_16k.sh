#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# prepare_torrent_16k.sh — make the libtorrent_flutter prebuilt .so files
# 16 KB page-size aligned before building the release AAB.
#
# Why: libtorrent_flutter ships prebuilt android-native-lib-*.zip binaries
# linked with `-Wl,-z,max-page-size=4096`. Google Play rejects any AAB whose
# native libraries are not aligned to >= 16 KB (the "Your app does not
# support 16 KB memory page sizes" error). Everything else in this project
# (Flutter, ffmpeg on-demand module, media_kit, jni) is already aligned.
#
# What this does, per ABI (arm64-v8a, armeabi-v7a):
#   1. Resolves the resolved libtorrent_flutter package dir from
#      .dart_tool/package_config.json (works with any PUB_CACHE).
#   2. Ensures the upstream prebuilt .so exists there (downloads the same
#      GitHub release zip the plugin's build.gradle would fetch).
#   3. Re-aligns it with tooling/align_elf_16k.py (pure-python, keeps every
#      virtual address — only file offsets/p_align change) and writes the
#      aligned copy to BOTH the package's prebuilt/android/<abi>/ dir (what
#      Gradle packages) and tooling/torrent_16k/<abi>/ (vendored in repo).
#   4. tooling/torrent_16k/VERSION records which package version the aligned
#      binaries were produced from; a mismatch forces a re-align.
#
# Idempotent and fast: on a healthy tree this is a no-op sync (~1 s).
# Run it before `flutter build appbundle`, and pair it with
# -PlibtorrentFlutterSkipDownload=true so a mid-build network hiccup can
# never trigger the plugin's slow CMake-from-source fallback.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="${PYTHON:-python}"
ALIGN="$REPO_ROOT/tooling/align_elf_16k.py"
OUT_DIR="$REPO_ROOT/tooling/torrent_16k"
ABIS=(arm64-v8a armeabi-v7a)
STAMP="$OUT_DIR/VERSION"

# Windows python cannot open MSYS-style /d/... paths
REPO_ROOT_WIN="$(cygpath -w "$REPO_ROOT")"
ALIGN_WIN="$(cygpath -w "$ALIGN")"

# --- locate the resolved package dir -----------------------------------------
PKG_DIR="$($PY - "$REPO_ROOT_WIN" <<'EOF'
import json, os, sys
root = sys.argv[1]
with open(os.path.join(root, ".dart_tool", "package_config.json")) as f:
    cfg = json.load(f)
for p in cfg["packages"]:
    if p["name"] == "libtorrent_flutter":
        uri = p["rootUri"]
        path = uri.replace("file://", "").lstrip("/")  # file:///D:/... -> D:/...
        print(os.path.normpath(path))
        sys.exit(0)
sys.exit("libtorrent_flutter not found in package_config.json")
EOF
)"
if [ ! -d "$PKG_DIR" ]; then
    echo "FATAL: package dir not found: $PKG_DIR" >&2
    exit 1
fi
PKG_VERSION="$(grep -m1 '^version:' "$PKG_DIR/pubspec.yaml" | awk '{print $2}')"
echo "libtorrent_flutter package: $PKG_DIR (v$PKG_VERSION)"

# --- version stamp: realign when the package version changed -----------------
if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" != "$PKG_VERSION" ]; then
    echo "note: vendored 16 KB binaries were built for $(cat "$STAMP"), package is now $PKG_VERSION — realigning"
    rm -f "$STAMP"
fi

for ABI in "${ABIS[@]}"; do
    SO="$PKG_DIR/prebuilt/android/$ABI/liblibtorrent_flutter.so"
    DST="$OUT_DIR/$ABI/liblibtorrent_flutter.so"

    # fetch upstream prebuilt if the cache copy is gone (mirrors plugin logic)
    if [ ! -f "$SO" ]; then
        ZIP_URL="https://github.com/ayman708-UX/libtorrent_flutter/releases/download/v${PKG_VERSION}/android-native-lib-${ABI}.zip"
        TMP_ZIP="$(mktemp -d)/lib-${ABI}.zip"
        echo "downloading $ZIP_URL"
        curl -fSL -o "$(cygpath -w "$TMP_ZIP")" "$ZIP_URL"
        mkdir -p "$(dirname "$SO")"
        unzip -o -q "$TMP_ZIP" -d "$(dirname "$SO")"
        rm -rf "$(dirname "$TMP_ZIP")"
    fi

    # realign (idempotent) and install into package + repo
    TMP_OUT="$(mktemp -d)/liblibtorrent_flutter.so"
    "$PY" "$ALIGN_WIN" "$(cygpath -w "$SO")" "$(cygpath -w "$TMP_OUT")" || exit 1
    if [ -f "$TMP_OUT" ]; then   # aligner wrote a new file -> install it
        cp "$TMP_OUT" "$SO"
    fi
    mkdir -p "$(dirname "$DST")"
    cp "$SO" "$DST"              # repo copy always mirrors the (aligned) package copy
    rm -rf "$(dirname "$TMP_OUT")"
    echo "installed 16 KB-aligned lib for $ABI (package + tooling/torrent_16k)"
done

echo "$PKG_VERSION" > "$STAMP"
echo "OK — libtorrent prebuilts are 16 KB page-size ready."

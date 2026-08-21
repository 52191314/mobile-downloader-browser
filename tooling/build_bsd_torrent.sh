#!/usr/bin/env bash
# build_bsd_torrent.sh — build the BSD-3-Clause torrent .so for Aurora.
#
# Replaces the GPL-3.0 libtorrent_flutter prebuilt with a clean build of
# rasterbar libtorrent (BSD-3-Clause) + our own lt_* bridge
# (android/torrent/src/main/cpp/aurora_torrent_bridge.{h,cpp}).
#
# Produces: tooling/torrent_16k/{arm64-v8a,armeabi-v7a}/liblibtorrent_flutter.so
#
# Prereqs:
#   - vcpkg (VCPKG_ROOT) with libtorrent installed for the target triplets:
#       ./vcpkg install libtorrent:arm64-android   (arm64-v8a)
#       ./vcpkg install libtorrent:arm-android     (armeabi-v7a)
#   - Android NDK (ANDROID_NDK_HOME)
#   - For armeabi-v7a, export ANDROID_USE_LEGACY_TOOLCHAIN_FILE=OFF (CMake 4)
set -euo pipefail

# --- config ---
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COROOT="$ROOT/android/torrent/src/main/cpp"
OUT="$ROOT/tooling/torrent_16k"
VCPKG_ROOT="${VCPKG_ROOT:-/d/01_Apps/DevTools/vcpkg}"
NDK="${ANDROID_NDK_HOME:-C:/01_Apps/DevTools/Android/Sdk/ndk/28.2.13676358}"
CC_PREFIX="$NDK/toolchains/llvm/prebuilt/windows-x86_64/bin"
INC="-I$VCPKG_ROOT/installed/arm64-android/include"
# static libs are identical across ABI for includes; per-ABI lib comes from the triplet install
STRIP="$CC_PREFIX/llvm-strip"

build_abi() {
    local triple=$1      # arm64-android / arm-android
    local clang=$2       # aarch64-linux-android24-clang++ / armv7a-linux-androideabi24-clang++
    local dstsub=$3      # arm64-v8a / armeabi-v7a
    local libdir="$VCPKG_ROOT/installed/$triple/lib"
    local incdir="$VCPKG_ROOT/installed/$triple/include"

    echo "=== Building BSD torrent .so for $dstsub ==="
    mkdir -p "$OUT/$dstsub"
    "$CC_PREFIX/$clang" -std=c++17 -fPIC -shared -O2 \
        "$COROOT/aurora_torrent_bridge.cpp" \
        -I"$incdir" \
        "$libdir/libtorrent-rasterbar.a" \
        -ldl -llog \
        -o "$OUT/$dstsub/liblibtorrent_flutter.so.tmp"
    "$STRIP" --strip-unneeded "$OUT/$dstsub/liblibtorrent_flutter.so.tmp"
    mv "$OUT/$dstsub/liblibtorrent_flutter.so.tmp" "$OUT/$dstsub/liblibtorrent_flutter.so"
    echo "  -> $OUT/$dstsub/liblibtorrent_flutter.so ($(stat -c%s "$OUT/$dstsub/liblibtorrent_flutter.so") bytes)"
}

build_abi "arm64-android" "aarch64-linux-android24-clang++" "arm64-v8a"
build_abi "arm-android"   "armv7a-linux-androideabi24-clang++" "armeabi-v7a"
echo "2.1.1-bsd" > "$OUT/VERSION"
echo "Done. BSD torrent libraries installed for arm64-v8a + armeabi-v7a."

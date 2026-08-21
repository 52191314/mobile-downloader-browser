# CMakeLists.txt — BSD-clean torrent bridge for Aurora Download Manager.
# Compiles aurora_torrent_bridge.cpp against rasterbar libtorrent
# (BSD-3-Clause), producing liblibtorrent_flutter.so so the existing
# Dart engine (aurora_torrent_engine.dart) works unchanged.
cmake_minimum_required(VERSION 3.14)

# The vcpkg toolchain (which chainloads the Android NDK toolchain) must be
# selected BEFORE project() so CMAKE_SYSTEM_NAME=Android is known in time.
if(DEFINED ENV{VCPKG_ROOT} AND NOT DEFINED CMAKE_TOOLCHAIN_FILE)
    set(CMAKE_TOOLCHAIN_FILE "$ENV{VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake"
        CACHE STRING "vcpkg toolchain")
endif()

project(aurora_torrent_bridge LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(libtorrent_flutter SHARED
    aurora_torrent_bridge.cpp
    aurora_torrent_bridge.h
)

find_package(LibtorrentRasterbar REQUIRED)
target_link_libraries(libtorrent_flutter PRIVATE
    LibtorrentRasterbar::torrent-rasterbar
    log
)

# On Android libtorrent 2.x tames a v2 namespace; the bridge uses public APIs
# so no extra defines needed beyond visibility for the exported C symbols.
target_compile_definitions(libtorrent_flutter PRIVATE
    TORRENT_BRIDGE_EXPORTS
)

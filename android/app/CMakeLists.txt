cmake_minimum_required(VERSION 3.18.1)

project(aurora_adblock)

add_library(aurora_adblock SHARED
    src/main/cpp/adblock/ffi_api.cpp
    src/main/cpp/adblock/adblock_engine.cpp
    src/main/cpp/adblock/rule_parser.cpp
    src/main/cpp/adblock/url_matcher.cpp
)

# Standard libraries
target_compile_features(aurora_adblock PRIVATE cxx_std_17)

# ---- Release optimization flags ----
target_compile_options(aurora_adblock PRIVATE
    $<$<CONFIG:Release>:-O3>
    $<$<CONFIG:Release>:-flto>
    $<$<CONFIG:Release>:-fno-rtti>
    $<$<CONFIG:Release>:-fno-exceptions>
    $<$<CONFIG:Release>:-DNDEBUG>
)
target_link_options(aurora_adblock PRIVATE
    $<$<CONFIG:Release>:-flto>
)

# ---- re2 (faster regex replacement) ----
# RE2 is not bundled with the Android NDK, so we fall back to the Dart-side
# adblock engine at runtime. Set HAVE_RE2=0 here; the C++ code must compile
# against this flag (see url_matcher.h).
# To enable native adblock, install re2 and absl into the NDK sysroot.
target_compile_definitions(aurora_adblock PRIVATE HAVE_RE2=0)

# Use std::regex as fallback. The url_matcher.h unconditionally includes
# <re2/re2.h>, so we provide a stub for native builds without RE2.
include(FetchContent)
FetchContent_Declare(
    re2_stub
    SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/src/main/cpp/adblock/re2_stub"
)
FetchContent_MakeAvailable(re2_stub)
target_include_directories(aurora_adblock PRIVATE ${re2_stub_SOURCE_DIR})

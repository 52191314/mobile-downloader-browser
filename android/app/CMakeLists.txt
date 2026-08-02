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

# Size & symbol optimization flags
target_compile_options(aurora_adblock PRIVATE -Os -fdata-sections -ffunction-sections -fvisibility=hidden)
target_link_options(aurora_adblock PRIVATE -Wl,--gc-sections -Wl,-s)


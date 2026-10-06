#!/bin/bash
# Keep compiler caches inside this project.
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
# Use the SDK for the running macOS version when a preview SDK is also installed.
if [ -z "${R2DESK_SDK_PATH:-}" ]; then
    macos_major="$(sw_vers -productVersion | cut -d. -f1)"
    matching_sdk="$(xcode-select -p)/SDKs/MacOSX${macos_major}.sdk"
    if [ -d "$matching_sdk" ]; then
        R2DESK_SDK_PATH="$matching_sdk"
    else
        R2DESK_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
    fi
fi
export R2DESK_SDK_PATH

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/swift-env.sh
swift run --disable-sandbox --cache-path "$PWD/.build/cache" --sdk "$R2DESK_SDK_PATH" --build-system native R2CoreChecks

swift run --disable-sandbox --cache-path "$PWD/.build/cache" --sdk "$R2DESK_SDK_PATH" --build-system native R2FinderChecks

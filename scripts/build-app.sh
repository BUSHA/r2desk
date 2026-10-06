#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/swift-env.sh
swift build --disable-sandbox --cache-path "$PWD/.build/cache" --sdk "$R2DESK_SDK_PATH" --build-system native -c release --product R2Man
binary_dir="$(swift build --disable-sandbox --cache-path "$PWD/.build/cache" --sdk "$R2DESK_SDK_PATH" --build-system native -c release --show-bin-path)"
app_dir="$PWD/dist/R2 Desk.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/R2Man" "$app_dir/Contents/MacOS/R2Man.new"
mv -f "$app_dir/Contents/MacOS/R2Man.new" "$app_dir/Contents/MacOS/R2Man"
cp scripts/Info.plist "$app_dir/Contents/Info.plist"
cp Assets/AppIcon.png "$app_dir/Contents/Resources/AppIcon.png"
cp Assets/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier com.busha.r2desk "$app_dir"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$PWD/dist/R2-Desk.zip"
printf 'App ready: %s\n' "$app_dir"

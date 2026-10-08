#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/swift-env.sh
swift build --disable-sandbox --cache-path "$PWD/.build/cache" --sdk "$R2DESK_SDK_PATH" --build-system native -c release --product R2Desk
binary_dir="$(swift build --disable-sandbox --cache-path "$PWD/.build/cache" --sdk "$R2DESK_SDK_PATH" --build-system native -c release --show-bin-path)"
app_dir="$PWD/dist/R2 Desk.app"
# Recreate the generated bundle so files from earlier builds are removed.
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/R2Desk" "$app_dir/Contents/MacOS/R2Desk.new"
mv -f "$app_dir/Contents/MacOS/R2Desk.new" "$app_dir/Contents/MacOS/R2Desk"
cp scripts/Info.plist "$app_dir/Contents/Info.plist"
cp Assets/AppIcon.png "$app_dir/Contents/Resources/AppIcon.png"
cp Assets/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"
bash scripts/build-finder-extension.sh
codesign --force --sign "${R2DESK_SIGNING_IDENTITY:--}" --identifier com.busha.r2desk "$app_dir"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$PWD/dist/R2-Desk.zip"
printf 'App ready: %s\n' "$app_dir"

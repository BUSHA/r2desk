#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/swift-env.sh
build_dir="$PWD/.build/finder"
extension_dir="$PWD/dist/R2 Desk.app/Contents/PlugIns/R2DeskFileProvider.appex"
mkdir -p "$build_dir" "$extension_dir/Contents/MacOS"
# Static modules keep the extension independent of the app process and SwiftPM build layout.
arch="$(uname -m)"
flags=(-sdk "$R2DESK_SDK_PATH" -target "$arch-apple-macosx14.0" -swift-version 5 -O -whole-module-optimization -parse-as-library)
swiftc "${flags[@]}" -module-name R2Core -emit-object -emit-module -emit-module-path "$build_dir/R2Core.swiftmodule" Sources/R2Core/*.swift -o "$build_dir/R2Core.o"
swiftc "${flags[@]}" -I "$build_dir" -module-name R2FinderShared -emit-object -emit-module -emit-module-path "$build_dir/R2FinderShared.swiftmodule" Sources/R2FinderShared/*.swift -o "$build_dir/R2FinderShared.o"
swiftc "${flags[@]}" -I "$build_dir" -module-name R2DeskFileProvider -emit-executable \
    -Xlinker -e -Xlinker _NSExtensionMain -application-extension \
    Sources/R2FileProvider/*.swift "$build_dir/R2Core.o" "$build_dir/R2FinderShared.o" \
    -o "$extension_dir/Contents/MacOS/R2DeskFileProvider"
cp scripts/FinderExtension-Info.plist "$extension_dir/Contents/Info.plist"
for key in CFBundleVersion CFBundleShortVersionString; do
    value=$(/usr/libexec/PlistBuddy -c "Print :$key" scripts/Info.plist)
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$extension_dir/Contents/Info.plist"
done
codesign --force --sign "${R2DESK_SIGNING_IDENTITY:--}" --entitlements scripts/FinderExtension.entitlements "$extension_dir"

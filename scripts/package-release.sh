#!/bin/bash
# Package a built app. This script does not publish or notarize it.
set -euo pipefail
cd "$(dirname "$0")/.."

app_dir="$PWD/dist/R2 Desk.app"
if [ ! -d "$app_dir" ]; then
    echo "Run bash scripts/build-app.sh first." >&2
    exit 1
fi

codesign --verify --strict --verbose=2 "$app_dir"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")
arch="${EXPECTED_ARCH:-$(uname -m)}"
case "$arch" in
    arm64|x86_64) ;;
    *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
esac
if [ "$(lipo -archs "$app_dir/Contents/MacOS/R2Man")" != "$arch" ]; then
    echo "App CPU does not match $arch" >&2
    exit 1
fi
if [ -n "${RELEASE_TAG:-}" ] && [ "$RELEASE_TAG" != "v$version" ]; then
    echo "Release tag must match the built app: v$version" >&2
    exit 1
fi

zip_name="R2-Desk-$version-$arch.zip"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$PWD/dist/$zip_name"
unzip -tq "$PWD/dist/$zip_name"
cd dist
shasum -a 256 "$zip_name" > "$zip_name.sha256"
shasum -a 256 -c "$zip_name.sha256"
printf 'Package ready: %s\n' "$zip_name"

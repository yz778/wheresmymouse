#!/bin/bash
set -eu
cd "$(dirname "$0")/.."

app=${1:-build/wheresmymouse.app}
arch=${BUILD_ARCH:-$(uname -m)}
executable="$app/Contents/MacOS/wheresmymouse"

compile() {
    xcrun swiftc -Osize -whole-module-optimization -target "$1-apple-macos13.0" \
        Sources/App.swift Sources/Hotkey.swift Sources/Cursor.swift Sources/PointerStyle.swift Sources/InstanceLock.swift Sources/Updates.swift -o "$2"
}

mkdir -p "$app/Contents/MacOS"
if [[ $arch == universal ]]; then
    slices=$(mktemp -d "${TMPDIR:-/tmp}/wheresmymouse.XXXXXX")
    trap 'rm -rf -- "$slices"' EXIT
    compile arm64 "$slices/arm64"
    compile x86_64 "$slices/x86_64"
    xcrun lipo -create "$slices/arm64" "$slices/x86_64" -output "$executable"
else
    compile "$arch" "$executable"
fi
cp "${BUILD_PLIST:-Resources/Info.plist}" "$app/Contents/Info.plist"
codesign --force --sign "${SIGN_IDENTITY:--}" "$app"
printf 'Built %s\n' "$app"

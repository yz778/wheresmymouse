#!/bin/bash
set -eu
cd "$(dirname "$0")/.."

mode=${1:-}
case "$mode" in
    ''|--current) ;;
    *) printf 'Usage: %s [--current]\n' "$0" >&2; exit 1 ;;
esac

version=$(plutil -extract CFBundleShortVersionString raw -o - Resources/Info.plist)
build_number=$(plutil -extract CFBundleVersion raw -o - Resources/Info.plist)
if [[ ! $build_number =~ ^[0-9]+$ || ! $version =~ ^([0-9]+)\.([0-9]+)(\.([0-9]+))?$ ]]; then
    printf 'Expected a major.minor[.patch] version and an integer build number in Info.plist.\n' >&2
    exit 1
fi
if [[ $mode != --current ]]; then
    version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((10#${BASH_REMATCH[4]:-0} + 1))"
    build_number=$((10#$build_number + 1))
fi
archive="build/wheresmymouse-$version-macos-universal.zip"
if [[ -e $archive ]]; then
    printf 'Release already exists: %s\n' "$archive" >&2
    exit 1
fi

mkdir -p build
stage=$(mktemp -d build/.release.XXXXXX)
trap 'rm -rf -- "$stage"' EXIT
plist=Resources/Info.plist
app="$stage/wheresmymouse.app"
if [[ $mode != --current ]]; then
    plist="$stage/Info.plist"
    cp Resources/Info.plist "$plist"
    plutil -replace CFBundleShortVersionString -string "$version" "$plist"
    plutil -replace CFBundleVersion -string "$build_number" "$plist"
fi
BUILD_ARCH=universal BUILD_PLIST="$plist" ./scripts/build.sh "$app"
ditto -c -k --keepParent "$app" "$stage/release.zip"
ln "$stage/release.zip" "$archive"
if [[ $mode != --current ]]; then
    mv "$plist" Resources/Info.plist
fi
printf 'Release %s (build %s): %s\n' "$version" "$build_number" "$archive"

#!/bin/bash
set -eu
cd "$(dirname "$0")/.."

scratch=$(mktemp -d "${TMPDIR:-/tmp}/wheresmymouse-tests.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
xcrun swiftc -target "$(uname -m)-apple-macos13.0" \
    Tests/Tests.swift Sources/Cursor.swift Sources/PointerStyle.swift Sources/InstanceLock.swift Sources/Updates.swift -o "$scratch/tests"
"$scratch/tests"

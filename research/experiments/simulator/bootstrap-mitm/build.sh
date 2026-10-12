#!/bin/sh
# Build the Ycode bootstrap MITM probe for the iOS simulator.
# Usage: build.sh <output-dir>   (output must be outside the repo; binaries are not committed)
set -e
OUT=${1:?output directory}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -O1 -g -Wall \
    -o "$OUT/bsmitm" "$HERE/bsmitm.c"
codesign -s - -f "$OUT/bsmitm" >/dev/null 2>&1 || true
echo "built $OUT/bsmitm"

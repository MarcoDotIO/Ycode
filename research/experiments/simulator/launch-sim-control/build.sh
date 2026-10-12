#!/bin/sh
# Build the Ycode liblaunch_sim control-channel probe (a macOS arm64 program).
# Usage: build.sh <output-dir>   (output must be outside the repo; binaries are not committed)
set -e
OUT=${1:?output directory}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"
xcrun --sdk macosx clang -arch arm64 -O1 -g -Wall -fblocks -Wl,-export_dynamic \
    -o "$OUT/lsprobe" "$HERE/lsprobe.c"
xcrun --sdk macosx clang -arch arm64 -O1 -g -Wall -dynamiclib \
    -o "$OUT/lsinterpose.dylib" "$HERE/lsinterpose.c"
codesign -s - -f "$OUT/lsprobe" "$OUT/lsinterpose.dylib" >/dev/null 2>&1 || true
echo "built $OUT/lsprobe"
# The guest-side helper (iOS simulator platform), run inside launchd_sim via launch_sim_spawn.
xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -O1 -g -Wall \
    -o "$OUT/lsguest" "$HERE/lsguest.c"
codesign -s - -f "$OUT/lsguest" >/dev/null 2>&1 || true
echo "built $OUT/lsguest"

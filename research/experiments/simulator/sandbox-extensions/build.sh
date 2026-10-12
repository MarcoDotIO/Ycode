#!/bin/sh
# Builds sbext for the iOS simulator. Usage: build.sh <output dir outside the repo>
set -e
OUT=${1:?output directory}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -O1 -Wall -o "$OUT/sbext" "$HERE/sbext.c"
echo "built $OUT/sbext"

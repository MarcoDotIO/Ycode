#!/bin/sh
# Builds exprobe for the iOS simulator platform (macOS only). Output: $OUT (default /tmp/yc-9-H-probes).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out="${OUT:-/tmp/yc-9-H-probes}"
mkdir -p "$out"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -fobjc-arc -O2 -Wall \
    -framework Foundation -o "$out/exprobe" "$here/exprobe.m"
echo "built $out/exprobe"

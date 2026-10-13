#!/bin/sh
# Builds the probe p_ca_render for the iOS simulator platform (macOS only).
# Output: $OUT (default ./out)/p_ca_render. Reference run on a Mac:
#   xcrun simctl spawn <throwaway booted device> out/p_ca_render /tmp/ca.png
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out="${OUT:-$here/out}"
mkdir -p "$out"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -fobjc-arc -O2 -Wall -Wextra -Werror \
    -framework Foundation -framework Metal -framework QuartzCore -framework CoreGraphics -framework CoreText -lz \
    -o "$out/p_ca_render" "$here/p_ca_render.m"
echo "built $out/p_ca_render"

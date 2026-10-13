#!/bin/sh
# Builds p_metal_linked and its metallib for the iOS simulator (macOS only). Output: $OUT (default ./out).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out="${OUT:-$here/out}"
mkdir -p "$out"
xcrun --sdk iphonesimulator metal -target air64-apple-ios27.0-simulator -O2 -c "$here/p_metal_linked.metal" -o "$out/a.air"
xcrun --sdk iphonesimulator metal -target air64-apple-ios27.0-simulator -O2 -c "$here/p_metal_linked_impl.metal" -o "$out/b.air"
xcrun --sdk iphonesimulator metallib "$out/a.air" "$out/b.air" -o "$out/p_metal_linked.metallib"
rm -f "$out/a.air" "$out/b.air"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -fobjc-arc -O2 -Wall -Wextra -Werror \
    -framework Foundation -framework Metal -o "$out/p_metal_linked" "$here/p_metal_linked.m"
echo "built $out/p_metal_linked"

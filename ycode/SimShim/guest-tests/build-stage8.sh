#!/bin/sh
# Builds the stage-8 guest probe p_metal_triangle (specs/simulator/stage8-contract.md
# §8, milestone 8a-T) for the iOS simulator platform. Runs on macOS only.
#   ../out/guest-tests/stage8/p_metal_triangle           arm64 command-line tool
#   ../out/guest-tests/stage8/p_metal_triangle.metallib  its shaders, precompiled
#       with the public Metal toolchain (the probe loads it with newLibraryWithURL:,
#       so the guest's shader compiler service is not needed)
# Copy the output directory to the Thor with rsync; run there with
#   ycode-simd --device D --oneshot <dir>/p_metal_triangle
# Reference run on a Mac: xcrun simctl spawn <booted device> <dir>/p_metal_triangle
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out="${OUT:-$here/../out/guest-tests/stage8}"
[ "$(uname -s)" = "Darwin" ] || { echo "build-stage8.sh: needs macOS" >&2; exit 1; }
mkdir -p "$out"
xcrun --sdk iphonesimulator metal -target air64-apple-ios27.0-simulator -O2 \
    -o "$out/p_metal_triangle.metallib" "$here/stage8/p_metal_triangle.metal"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -fobjc-arc -O2 -Wall -Wextra -Werror \
    -framework Foundation -framework Metal \
    -o "$out/p_metal_triangle" "$here/stage8/p_metal_triangle.m"
echo "$out/p_metal_triangle: $(wc -c < "$out/p_metal_triangle" | tr -d ' ') bytes"
echo "$out/p_metal_triangle.metallib: $(wc -c < "$out/p_metal_triangle.metallib" | tr -d ' ') bytes"
echo "build-stage8.sh: ok"

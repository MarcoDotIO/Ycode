#!/bin/sh
# compile-shaders.sh: compile our test shaders (tests/shaders/*.metal) to
# metallibs with the public Metal toolchain on macOS, for the iOS simulator
# (the AIR the simulator host receives). Outputs go to OUT_DIR, never into
# the repository. Install the toolchain with
# `xcodebuild -downloadComponent MetalToolchain` if `metal` is missing.
# Usage: compile-shaders.sh OUT_DIR
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$1
mkdir -p "$OUT"
for src in "$HERE"/shaders/*.metal; do
    n=$(basename "$src" .metal)
    xcrun -sdk iphonesimulator metal -std=metal3.1 "$src" -o "$OUT/$n.metallib"
done
ls "$OUT"

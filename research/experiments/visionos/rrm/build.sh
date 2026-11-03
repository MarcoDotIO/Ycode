#!/bin/sh
# Build the OBS-VISION-RRM tools (2026-11-01) for the visionOS simulator. Usage: build.sh OUTDIR (outside the repository).
#   rrmcli        probe run with `simctl spawn` (device answers on rate maps, host involvement, map creation)
#   rrmpeek.dylib recorder inserted into a boot (SIMCTL_CHILD_DYLD_INSERT_LIBRARIES, SIMCTL_CHILD_RP_DIR=<dir>)
#   mslog.dylib   the Metal-protocol recorder/test server of research/experiments/simulator/metal-sim, built for xrOS
set -e
OUT=${1:?output directory}; HERE=$(cd "$(dirname "$0")" && pwd); mkdir -p "$OUT"
cc() { xcrun --sdk xrsimulator clang -target arm64-apple-xros27.0-simulator -O1 -g "$@"; }
cc -fobjc-arc -framework Foundation -framework Metal -o "$OUT/rrmcli" "$HERE/rrmcli.m"
cc -dynamiclib -fobjc-arc -framework Foundation -framework Metal -Wl,-undefined,dynamic_lookup -o "$OUT/rrmpeek.dylib" "$HERE/rrmpeek.m"
cc -dynamiclib -framework IOSurface -o "$OUT/mslog.dylib" "$HERE/../../simulator/metal-sim/mslog.c"
for f in rrmcli rrmpeek.dylib mslog.dylib; do codesign -s - -f "$OUT/$f" >/dev/null; done
echo "built in $OUT"

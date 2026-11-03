#!/bin/sh
# Build camrec.dylib (guest recorder, OBS-VISION-FOV 2026-11-01). Usage: build.sh OUTDIR (outside the repository).
# Boot with SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=<OUTDIR>/camrec.dylib SIMCTL_CHILD_CR_DIR=<a folder in the device's data dir>;
# create <CR_DIR>/on to sample frames, remove it to stop. camstep.py analyses frames.*.bin against cr.backboardd.* poses.
set -e
OUT=${1:?output directory}; HERE=$(cd "$(dirname "$0")" && pwd); mkdir -p "$OUT"
xcrun --sdk xrsimulator clang -target arm64-apple-xros27.0-simulator -dynamiclib -fobjc-arc -O1 \
  -framework Foundation -framework IOSurface -framework IOKit -Wl,-undefined,dynamic_lookup \
  -o "$OUT/camrec.dylib" "$HERE/camrec.m"
codesign -s - -f "$OUT/camrec.dylib" >/dev/null
echo "built $OUT/camrec.dylib"

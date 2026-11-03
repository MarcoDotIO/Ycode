#!/bin/sh
# Build stereopeek.dylib (guest recorder, OBS-VISION-STEREO 2026-11-01). Usage: build.sh OUTDIR (outside the repository).
# Insert into a boot with SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=<OUTDIR>/stereopeek.dylib SIMCTL_CHILD_SP_DIR=<dir>;
# optional SP_CAPTURES (slice read-backs per array-texture size, default 3), SP_PASSES (passes logged per signature, default 6),
# SP_PROCS (backboardd,wakeboardd), SP_NO_UD (do not log wakeboardd's NSUserDefaults reads).
set -e
OUT=${1:?output directory}; HERE=$(cd "$(dirname "$0")" && pwd); mkdir -p "$OUT"
xcrun --sdk xrsimulator clang -target arm64-apple-xros27.0-simulator -dynamiclib -fobjc-arc -O1 \
  -framework Foundation -framework Metal -framework IOSurface -Wl,-undefined,dynamic_lookup \
  -o "$OUT/stereopeek.dylib" "$HERE/stereopeek.m"
codesign -s - -f "$OUT/stereopeek.dylib" >/dev/null
echo "built $OUT/stereopeek.dylib"

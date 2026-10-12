#!/bin/sh
# Build the R7 Metal-simulator research tools for the iOS simulator.
# Usage: build.sh <output-dir>   (outside the repo; binaries are not committed)
set -e
OUT=${1:?output directory}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"
cc() { xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -O1 -g -Wall "$@"; }
cc -dynamiclib -framework IOSurface -o "$OUT/mslog.dylib" "$HERE/mslog.c"
cc -dynamiclib -framework IOSurface -DMS_SFB -o "$OUT/mslog-sfb.dylib" "$HERE/mslog.c"
cc -fobjc-arc -framework Foundation -framework Metal -framework IOSurface -framework QuartzCore \
   -framework CoreGraphics -o "$OUT/mtltest" "$HERE/mtltest.m"
cc -fobjc-arc -framework Foundation -framework Metal -o "$OUT/mtlvary" "$HERE/mtlvary.m"
codesign -s - -f "$OUT/mtlvary" >/dev/null 2>&1
xcrun --sdk iphonesimulator metal -target air64-apple-ios27.0-simulator -o "$OUT/shaders.metallib" "$HERE/shaders.metal"
for f in mslog.dylib mslog-sfb.dylib mtltest; do codesign -s - -f "$OUT/$f" >/dev/null 2>&1; done
if [ -f "$HERE/msnames.m" ]; then
  cc -fobjc-arc -framework Foundation -o "$OUT/msnames" "$HERE/msnames.m"
  codesign -s - -f "$OUT/msnames" >/dev/null 2>&1
fi
echo "built in $OUT"

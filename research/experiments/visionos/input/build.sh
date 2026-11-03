#!/bin/sh
# Build the visionOS input probes (OBS-VISION-INPUT, 2026-10-31). Usage: build.sh <out> (outside the repo).
#   <out>/vhid          Mac: Indigo pose/selection/collection/dial/button/key sender (exported builders, legacy HID client)
#   <out>/bprobe        Mac: argument-order probe for an exported builder
#   <out>/vhm           Mac: vhmdd client over a sim-to-host XPC connection (one message, or many from stdin)
#   <out>/mkdev         Mac: create a device on a runtime chosen by build (when two builds share an identifier)
#   <out>/gvhm          guest (simctl spawn): vhmdd client from inside the device (refused by vhmdd)
#   <out>/hidrec.dylib  guest: recorder of dispatched HID events; boot with
#                       SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=<it> SIMCTL_CHILD_HIDREC_FILE=<log>
#   <out>/hidrec2.dylib guest: hidrec plus per-field values of each child; optional Ycode-style rewrite (OBS-VISION-POSE)
#   <out>/oprobe        guest (simctl spawn): which Orientation-event construction keeps a quaternion
# gen.py writes vhid script lines (tap, drag, hover, two-hand magnify/rotate, direct poke);
# glass.py fits glass = gain * blur(background) + offset on two screenshots.
set -e
OUT=${1:?output directory}; HERE=$(cd "$(dirname "$0")" && pwd); mkdir -p "$OUT"
for t in vhid vhm bprobe mkdev; do
  xcrun --sdk macosx clang -arch arm64 -fobjc-arc -O0 -framework Foundation -o "$OUT/$t" "$HERE/$t.m"
  codesign -s - -f "$OUT/$t" >/dev/null
done
xcrun --sdk xrsimulator clang -target arm64-apple-xros27.0-simulator -O1 -o "$OUT/gvhm" "$HERE/gvhm.c"
xcrun --sdk xrsimulator clang -target arm64-apple-xros27.0-simulator -dynamiclib -O1 \
  -framework CoreFoundation -framework IOKit -o "$OUT/hidrec.dylib" "$HERE/hidrec.c"
xcrun --sdk xrsimulator clang -target arm64-apple-xros27.0-simulator -dynamiclib -O1 \
  -framework CoreFoundation -framework IOKit -o "$OUT/hidrec2.dylib" "$HERE/hidrec2.c"
xcrun --sdk xrsimulator clang -target arm64-apple-xros27.0-simulator -O1 -include string.h \
  -framework CoreFoundation -o "$OUT/oprobe" "$HERE/oprobe.c"
codesign -s - -f "$OUT/gvhm" "$OUT/hidrec.dylib" "$OUT/hidrec2.dylib" "$OUT/oprobe" >/dev/null
echo "built in $OUT"

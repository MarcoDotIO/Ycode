#!/bin/sh
# Build the R4 SimFramebuffer research tools for the iOS simulator.
# Usage: [ALLOW=<allowlist>] build.sh <output-dir>   (outside the repo; binaries are not committed)
# ALLOW limits the interposer's exported functions to the listed names.
#
# Produces:
#   <out>/SimFramebuffer.framework/SimFramebuffer  the tracing interposer (sfbtrace.c +
#        generated stubs); point SIMULATOR_FRAMEBUFFER_FRAMEWORK at this file
#   <out>/objcdump    ObjC runtime metadata lister (objcdump.m)
#   <out>/hidprobe    loads the HID client bundle and calls its manager initializer (hidprobe.m)
#   <out>/sfbprobe    a direct client of the real library (sfbprobe.c)
#   <out>/dlsymtrace.dylib  dlopen/dlsym/lookup logger for our own probe (dlsymtrace.c)
#   <out>/headless/SimFramebuffer.framework/SimFramebuffer  headless prototype (sfbheadless.c)
set -e
OUT=${1:?output directory}
HERE=$(cd "$(dirname "$0")" && pwd)
REAL=/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Resources/Platforms/iphoneos/Library/PrivateFrameworks/SimFramebuffer.framework/SimFramebuffer
TARGET=arm64-apple-ios27.0-simulator
CC="xcrun --sdk iphonesimulator clang -target $TARGET"
mkdir -p "$OUT/gen" "$OUT/SimFramebuffer.framework"

sh "$HERE/gen_tramps.sh" "$REAL" "$OUT/gen" $ALLOW
$CC -dynamiclib -O1 -g -Wall -framework CoreFoundation \
    -install_name @rpath/SimFramebuffer.framework/SimFramebuffer \
    -o "$OUT/SimFramebuffer.framework/SimFramebuffer" \
    "$HERE/sfbtrace.c" "$HERE/tramp_common.s" "$OUT/gen/tramps.s" "$OUT/gen/tramps_table.c"
codesign -s - -f "$OUT/SimFramebuffer.framework/SimFramebuffer" >/dev/null

$CC -fobjc-arc -O1 -g -Wall -framework Foundation -o "$OUT/objcdump" "$HERE/objcdump.m"
$CC -fobjc-arc -O1 -g -Wall -framework Foundation -o "$OUT/hidprobe" "$HERE/hidprobe.m"
codesign -s - -f "$OUT/hidprobe" >/dev/null
codesign -s - -f "$OUT/objcdump" >/dev/null

if [ -f "$HERE/sfbprobe.c" ]; then
  $CC -O1 -g -Wall -framework CoreFoundation -framework IOSurface -o "$OUT/sfbprobe" "$HERE/sfbprobe.c" "$HERE/rawcall.s"
  codesign -s - -f "$OUT/sfbprobe" >/dev/null
fi
$CC -dynamiclib -O1 -Wall -o "$OUT/dlsymtrace.dylib" "$HERE/dlsymtrace.c"
mkdir -p "$OUT/headless/SimFramebuffer.framework"
$CC -dynamiclib -O1 -Wall -framework CoreFoundation -fvisibility=hidden \
    -install_name @rpath/SimFramebuffer.framework/SimFramebuffer \
    -o "$OUT/headless/SimFramebuffer.framework/SimFramebuffer" "$HERE/sfbheadless.c"
codesign -s - -f "$OUT/headless/SimFramebuffer.framework/SimFramebuffer" >/dev/null
codesign -s - -f "$OUT/dlsymtrace.dylib" >/dev/null
echo "built in $OUT"

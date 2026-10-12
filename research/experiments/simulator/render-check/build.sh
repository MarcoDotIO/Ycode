#!/bin/sh
# Build the R6 render-check tools for the iOS simulator.
# Usage: build.sh <output-dir>   (outside the repo; binaries are not committed)
# Produces:
#   <out>/capture/SimFramebuffer.framework/SimFramebuffer  headless framebuffer + capture (sfbcapture.c)
#   <out>/rcenv.dylib   getenv/dlopen logger and service deny list (rcenv.c)
#   <out>/isdump        R5 test IOSurface server + dump by surface ID (isdump.c)
#   <out>/mtlprobe      Metal device probe (mtlprobe.m)
#   <out>/YcodeProbe.app  the probe app (../ProbeApp, unmodified)
#   <out>/YcodeTick.app   TickApp/: content changes 5 times a second
set -e
OUT=${1:?output directory}
HERE=$(cd "$(dirname "$0")" && pwd)
TARGET=arm64-apple-ios27.0-simulator
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
CC="xcrun --sdk iphonesimulator clang -target $TARGET"
mkdir -p "$OUT/capture/SimFramebuffer.framework" "$OUT/YcodeProbe.app"
$CC -dynamiclib -O1 -Wall -framework CoreFoundation -framework IOSurface -fvisibility=hidden \
    -install_name @rpath/SimFramebuffer.framework/SimFramebuffer \
    -o "$OUT/capture/SimFramebuffer.framework/SimFramebuffer" "$HERE/sfbcapture.c"
$CC -dynamiclib -O1 -Wall -o "$OUT/rcenv.dylib" "$HERE/rcenv.c"
$CC -O1 -g -Wall -framework CoreFoundation -o "$OUT/isdump" "$HERE/isdump.c"
$CC -fobjc-arc -O1 -Wall -framework Foundation -framework Metal -o "$OUT/mtlprobe" "$HERE/mtlprobe.m"
xcrun --sdk iphonesimulator swiftc -target $TARGET -sdk "$SDK" -module-name YcodeProbe \
    -O -o "$OUT/YcodeProbe.app/YcodeProbe" "$HERE/../ProbeApp/main.swift"
cp "$HERE/../ProbeApp/Info.plist" "$OUT/YcodeProbe.app/Info.plist"
printf 'APPL????' > "$OUT/YcodeProbe.app/PkgInfo"
for f in capture/SimFramebuffer.framework/SimFramebuffer rcenv.dylib isdump mtlprobe YcodeProbe.app; do
  codesign -s - -f "$OUT/$f" >/dev/null
done
echo "built in $OUT"
# TickApp: an app whose content changes 5 times a second (liveness check)
mkdir -p "$OUT/YcodeTick.app"
xcrun --sdk iphonesimulator swiftc -target $TARGET -sdk "$SDK" -module-name YcodeTick \
    -O -o "$OUT/YcodeTick.app/YcodeTick" "$HERE/TickApp/main.swift"
cp "$HERE/TickApp/Info.plist" "$OUT/YcodeTick.app/Info.plist"
printf 'APPL????' > "$OUT/YcodeTick.app/PkgInfo"
codesign -s - -f "$OUT/YcodeTick.app" >/dev/null
echo "built $OUT/YcodeTick.app"

#!/bin/sh
# Build the stage-7 app install/launch experiments for the iOS simulator.
# Usage: build.sh <output-dir>   (output must be outside the repo; binaries are not committed)
#
# Produces:
#   <out>/YcodeProbe.app   the probe app (sources: ../ProbeApp, unmodified)
#   <out>/ylaunch          the guest-side install/launch helper (ylaunch.m), carrying the
#                          simulator entitlement in __TEXT,__entitlements (ylaunch.entitlements)
#   <out>/lookuptrace.dylib  optional interposer that logs Mach lookups (lookuptrace.c)
#   <out>/enttrace.dylib   optional interposer that logs code-signing/file calls (enttrace.c)
set -e
OUT=${1:?output directory}
HERE=$(cd "$(dirname "$0")" && pwd)
PROBE="$HERE/../ProbeApp"
TARGET=arm64-apple-ios27.0-simulator
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
mkdir -p "$OUT/YcodeProbe.app"

# Probe app: module name must be YcodeProbe (Info.plist names YcodeProbe.SceneDelegate).
xcrun --sdk iphonesimulator swiftc -target $TARGET -sdk "$SDK" -module-name YcodeProbe \
    -O -o "$OUT/YcodeProbe.app/YcodeProbe" "$PROBE/main.swift"
cp "$PROBE/Info.plist" "$OUT/YcodeProbe.app/Info.plist"
printf 'APPL????' > "$OUT/YcodeProbe.app/PkgInfo"
codesign -s - -f "$OUT/YcodeProbe.app" >/dev/null

# Guest helper: links only public frameworks; private classes are resolved by name at run time.
# The entitlements go into a section, NOT into the code signature: an ad-hoc signature that
# carries them makes the spawn fail (observed: SimXPCErrorDomain 163).
xcrun --sdk iphonesimulator clang -target $TARGET -fobjc-arc -O1 -g -Wall \
    -framework Foundation -framework Security -Wl,-sectcreate,__TEXT,__entitlements,"$HERE/ylaunch.entitlements" \
    -o "$OUT/ylaunch" "$HERE/ylaunch.m"
codesign -s - -f "$OUT/ylaunch" >/dev/null

xcrun --sdk iphonesimulator clang -target $TARGET -dynamiclib -O1 -Wall \
    -o "$OUT/lookuptrace.dylib" "$HERE/lookuptrace.c"
codesign -s - -f "$OUT/lookuptrace.dylib" >/dev/null
xcrun --sdk iphonesimulator clang -target $TARGET -dynamiclib -O1 -Wall \
    -o "$OUT/enttrace.dylib" "$HERE/enttrace.c"
codesign -s - -f "$OUT/enttrace.dylib" >/dev/null
echo "built $OUT/enttrace.dylib"
echo "built $OUT/YcodeProbe.app $OUT/ylaunch $OUT/lookuptrace.dylib"

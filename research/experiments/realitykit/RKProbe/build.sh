#!/bin/sh
# Build RKProbe.app for the iOS simulator without an Xcode project.
# Usage: build.sh <output-dir>   (outside the repository; output is not committed)
set -e
OUT=${1:?output directory}
HERE=$(cd "$(dirname "$0")" && pwd)
APP="$OUT/RKProbe.app"
rm -rf "$APP"; mkdir -p "$APP"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios27.0-simulator -sdk "$SDK" \
  -swift-version 5 -O -parse-as-library -module-name RKProbe \
  -o "$APP/RKProbe" "$HERE/main.swift"
xcrun --sdk iphonesimulator metal -target air64-apple-ios27.0-simulator -o "$APP/default.metallib" "$HERE/shaders.metal"
cp "$HERE/Info.plist" "$APP/Info.plist"
cp "$HERE"/assets/*.usda "$APP/"
( cd "$OUT" && rm -f cube.usdz && cp "$HERE/assets/cube.usda" . && usdzip cube.usdz cube.usda >/dev/null && cp cube.usdz "$APP/" )
# A .reality file compiled from our own cube.usda (realitytool; optional).
mkdir -p "$OUT/rc/Probe.rkassets" && cp "$HERE/assets/cube.usda" "$OUT/rc/Probe.rkassets/Scene.usda"
xcrun realitytool compile --output-reality="$OUT/rc/Probe.reality" --platform=iphonesimulator --deployment-target=27.0 -- "$OUT/rc/Probe.rkassets" >/dev/null 2>&1 \
  && cp "$OUT/rc/Probe.reality" "$APP/" || echo "realitytool compile failed; Probe.reality omitted"
codesign -s - -f "$APP" >/dev/null 2>&1
echo "built $APP"

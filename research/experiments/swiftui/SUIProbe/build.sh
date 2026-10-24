#!/bin/sh
# Build SUIProbe.app for the iOS simulator without an Xcode project, plus the
# svctrace.dylib service tracer and the hidsend input driver.
# Usage: build.sh <output-dir>   (outside the repository; output is not committed)
set -e
OUT=${1:?output directory}
HERE=$(cd "$(dirname "$0")" && pwd)
APP="$OUT/SUIProbe.app"
rm -rf "$APP"; mkdir -p "$APP"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios27.0-simulator -sdk "$SDK" \
  -swift-version 5 -Onone -g -parse-as-library -module-name SUIProbe \
  -o "$APP/SUIProbe" "$HERE"/App.swift "$HERE"/Layout.swift "$HERE"/Modes.swift "$HERE"/Anim.swift "$HERE"/DataFlow.swift "$HERE"/Env.swift
cp "$HERE/Info.plist" "$APP/Info.plist"
cp -R "$HERE"/res/*.lproj "$APP/"
xcrun actool --compile "$APP" --platform iphonesimulator --minimum-deployment-target 27.0 \
  --target-device iphone --output-format human-readable-text \
  --output-partial-info-plist "$OUT/assets-partial.plist" "$HERE/res/Assets.xcassets" >/dev/null
codesign -s - -f "$APP" >/dev/null 2>&1
xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -dynamiclib -O1 -Wall \
  -framework CoreFoundation -o "$OUT/svctrace.dylib" "$HERE/svctrace.c"
codesign -s - -f "$OUT/svctrace.dylib" >/dev/null 2>&1
# Input driver (shared research tool of the simulator track).
sh "$HERE/../../simulator/hid/build.sh" "$OUT/hid" >/dev/null
echo "built $APP"

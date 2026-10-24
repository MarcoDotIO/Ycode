#!/bin/sh
# Build MKProbe for the iOS simulator with the installed Xcode (ad-hoc signed,
# no team, no entitlements: MapKit needs none), plus the svctrace.dylib service
# tracer (research/experiments/swiftui/SUIProbe/svctrace.c) and the hidsend
# input driver (research/experiments/simulator/hid).
#   MKProbe.app        dev.ycode.mkprobe        location usage string, maps: query scheme
#   MKProbeNoLoc.app   dev.ycode.mkprobe.noloc  no location usage string
# Usage: build.sh OUTDIR   (OUTDIR on the Mac, not on the drive, outside the repo)
set -eu
SRC=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?usage: build.sh OUTDIR}
mkdir -p "$OUT"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)

xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios27.0-simulator -sdk "$SDK" \
  -swift-version 5 -parse-as-library -Onone -g \
  "$SRC/App.swift" "$SRC/Math.swift" "$SRC/MapModes.swift" "$SRC/Services.swift" "$SRC/SUI.swift" \
  -o "$OUT/MKProbe.bin"

plist() { # name bundle-id extra-xml
  cat <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundleExecutable</key><string>MKProbe</string>
<key>CFBundleName</key><string>$1</string>
<key>CFBundleDisplayName</key><string>$1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
<key>MinimumOSVersion</key><string>27.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
<key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict>
  <key>UIApplicationSupportsMultipleScenes</key><false/>
</dict>
<key>LSApplicationQueriesSchemes</key><array><string>maps</string><string>comgooglemaps</string><string>geo</string></array>
$3
</dict></plist>
XML
}
mk() { # app-name bundle-id extra-xml
  rm -rf "$OUT/$1.app"; mkdir -p "$OUT/$1.app"
  cp "$OUT/MKProbe.bin" "$OUT/$1.app/MKProbe"
  plist "$1" "$2" "$3" > "$OUT/$1.app/Info.plist"
  codesign -f -s - "$OUT/$1.app" >/dev/null 2>&1
}
LOC='<key>NSLocationWhenInUseUsageDescription</key><string>MKProbe shows your location on the map</string>'
mk MKProbe dev.ycode.mkprobe "$LOC"
mk MKProbeNoLoc dev.ycode.mkprobe.noloc ""

xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -dynamiclib -O1 \
  -framework CoreFoundation -o "$OUT/svctrace.dylib" "$SRC/../../swiftui/SUIProbe/svctrace.c"
codesign -f -s - "$OUT/svctrace.dylib" >/dev/null 2>&1
sh "$SRC/../../simulator/hid/build.sh" "$OUT/hid" >/dev/null
echo "built into $OUT"

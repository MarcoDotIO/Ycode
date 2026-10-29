#!/bin/sh
# Build VisionProbe.app for the visionOS simulator with the installed Xcode.
# Usage: build.sh OUTDIR   (OUTDIR on the Mac, outside the repository)
set -eu
SRC=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?usage: build.sh OUTDIR}
APP="$OUT/VisionProbe.app"
rm -rf "$APP"; mkdir -p "$APP"
SDK=$(xcrun --sdk xrsimulator --show-sdk-path)
xcrun --sdk xrsimulator swiftc -target arm64-apple-xros27.0-simulator -sdk "$SDK" \
  -parse-as-library -Onone -g "$SRC/main.swift" -o "$APP/VisionProbe"
cat > "$APP/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.ycode.visionprobe</string>
<key>CFBundleExecutable</key><string>VisionProbe</string>
<key>CFBundleName</key><string>VisionProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleSupportedPlatforms</key><array><string>XRSimulator</string></array>
<key>MinimumOSVersion</key><string>27.0</string>
<key>UIDeviceFamily</key><array><integer>7</integer></array>
<key>NSWorldSensingUsageDescription</key><string>VisionProbe world sensing test</string>
<key>NSHandsTrackingUsageDescription</key><string>VisionProbe hand tracking test</string>
<key>UIApplicationSceneManifest</key><dict>
  <key>UIApplicationSupportsMultipleScenes</key><true/>
  <key>UIApplicationPreferredDefaultSceneSessionRole</key><string>UIWindowSceneSessionRoleApplication</string>
  <key>UISceneConfigurations</key><dict/>
</dict>
</dict></plist>
PL
codesign -f -s - "$APP" >/dev/null 2>&1
echo "built $APP"

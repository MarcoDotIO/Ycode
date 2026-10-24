#!/bin/sh
# Build ARProbe for the iOS simulator with the installed Xcode, in three
# variants that differ only in Info.plist:
#   ARProbe.app        camera usage string present            dev.ycode.arprobe
#   ARProbeNoCam.app   no NSCameraUsageDescription            dev.ycode.arprobe.nocam
#   ARProbeReq.app     UIRequiredDeviceCapabilities = [arkit] dev.ycode.arprobe.req
# Usage: build.sh OUTDIR   (OUTDIR must be on the Mac, not on the drive)
set -eu
SRC=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?usage: build.sh OUTDIR}
mkdir -p "$OUT"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -isysroot "$SDK" \
  -fobjc-arc -fmodules -Wall -Wno-deprecated-declarations -O0 -g \
  -framework UIKit -framework ARKit -framework SceneKit -framework SpriteKit -framework Metal \
  -framework AVFoundation -framework CoreLocation -framework QuartzCore \
  "$SRC/main.m" -o "$OUT/ARProbe.bin"

plist() { # name bundle-id extra-xml
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundleExecutable</key><string>ARProbe</string>
<key>CFBundleName</key><string>$1</string>
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
$3
</dict></plist>
EOF
}

mk() { # app-name bundle-id extra-xml
  rm -rf "$OUT/$1.app"; mkdir -p "$OUT/$1.app"
  cp "$OUT/ARProbe.bin" "$OUT/$1.app/ARProbe"
  plist "$1" "$2" "$3" > "$OUT/$1.app/Info.plist"
  codesign -f -s - "$OUT/$1.app" >/dev/null 2>&1
}
CAM='<key>NSCameraUsageDescription</key><string>ARProbe camera test</string>'
mk ARProbe dev.ycode.arprobe "$CAM"
mk ARProbeNoCam dev.ycode.arprobe.nocam ""
mk ARProbeReq dev.ycode.arprobe.req "$CAM<key>UIRequiredDeviceCapabilities</key><array><string>arkit</string></array>"
echo "built into $OUT"

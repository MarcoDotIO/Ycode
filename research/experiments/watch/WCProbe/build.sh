#!/bin/sh
# Build WCProbe.app (iOS simulator) with WCProbeWatch.app (watchOS simulator)
# embedded at WCProbe.app/Watch/, the layout of an iOS app that carries a
# watch app. Our own code; ad-hoc signed.
# Usage: build.sh OUTDIR   (OUTDIR outside the repository, with no symlinks)
set -eu
SRC=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?usage: build.sh OUTDIR}
PHONE="$OUT/WCProbe.app"
WATCH="$PHONE/Watch/WCProbeWatch.app"
rm -rf "$PHONE"; mkdir -p "$WATCH"

xcrun --sdk watchsimulator swiftc -target arm64-apple-watchos27.0-simulator \
  -sdk "$(xcrun --sdk watchsimulator --show-sdk-path)" -D WATCH \
  -parse-as-library -Onone -g "$SRC/Probe.swift" -o "$WATCH/WCProbeWatch"
cat > "$WATCH/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.ycode.wcprobe.watchkitapp</string>
<key>CFBundleExecutable</key><string>WCProbeWatch</string>
<key>CFBundleName</key><string>WCProbe</string>
<key>CFBundleDisplayName</key><string>WCProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleSupportedPlatforms</key><array><string>WatchSimulator</string></array>
<key>MinimumOSVersion</key><string>27.0</string>
<key>UIDeviceFamily</key><array><integer>4</integer></array>
<key>WKApplication</key><true/>
<key>WKCompanionAppBundleIdentifier</key><string>dev.ycode.wcprobe</string>
</dict></plist>
PL
codesign -f -s - "$WATCH" >/dev/null 2>&1

xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios27.0-simulator \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" -D PHONE \
  -parse-as-library -Onone -g "$SRC/Probe.swift" -o "$PHONE/WCProbe"
cat > "$PHONE/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.ycode.wcprobe</string>
<key>CFBundleExecutable</key><string>WCProbe</string>
<key>CFBundleName</key><string>WCProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
<key>MinimumOSVersion</key><string>27.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UIApplicationSceneManifest</key><dict>
  <key>UIApplicationSupportsMultipleScenes</key><false/>
  <key>UISceneConfigurations</key><dict/>
</dict>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PL
codesign -f -s - "$PHONE" >/dev/null 2>&1
echo "built $PHONE"

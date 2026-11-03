#!/bin/sh
# Build HealthSim: HS.app (iOS simulator) with HSWatch.app embedded at
# HS.app/Watch/, plus a standalone copy of the watch app and a second phone
# app HSB.app (another data source, for cross-process tests).
# Entitlements go into the __TEXT,__entitlements section (simulator style);
# the ad-hoc signature carries none. No team, no profile.
# Usage: build.sh OUTDIR
set -eu
SRC=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?usage: build.sh OUTDIR}
mkdir -p "$OUT"
ent() { # appid extra
cat <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>application-identifier</key><string>$1</string>
<key>com.apple.developer.healthkit</key><true/>
<key>com.apple.developer.healthkit.background-delivery</key><true/>
$2
</dict></plist>
PL
}
USE='<key>NSHealthShareUsageDescription</key><string>HealthSim reads made-up test samples.</string>
<key>NSHealthUpdateUsageDescription</key><string>HealthSim writes made-up test samples.</string>'
build() { # sdk target define exe outdir entfile
  SDK=$(xcrun --sdk "$1" --show-sdk-path)
  xcrun --sdk "$1" clang -target "$2" -isysroot "$SDK" -fobjc-arc -fmodules -Wall -Wno-deprecated-declarations -O0 -g \
    -I "$SRC" -c "$SRC/core.m" -o "$OUT/core-$3.o"
  xcrun --sdk "$1" swiftc -target "$2" -sdk "$SDK" -D "$3" -parse-as-library -Onone -g \
    -import-objc-header "$SRC/HSBridge.h" "$SRC/App.swift" "$OUT/core-$3.o" \
    -framework HealthKit -framework CoreLocation \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker "$6" -o "$5/$4"
}
info() { # id exe name platform family extra
cat <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$1</string>
<key>CFBundleExecutable</key><string>$2</string>
<key>CFBundleName</key><string>$3</string>
<key>CFBundleDisplayName</key><string>$3</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleSupportedPlatforms</key><array><string>$4</string></array>
<key>MinimumOSVersion</key><string>27.0</string>
<key>UIDeviceFamily</key><array><integer>$5</integer></array>
$USE
$6
</dict></plist>
PL
}
PHONEX='<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/><key>UISceneConfigurations</key><dict/></dict>
<key>UILaunchScreen</key><dict/>'
WATCHX='<key>WKApplication</key><true/>
<key>WKCompanionAppBundleIdentifier</key><string>dev.ycode.hs</string>
<key>WKBackgroundModes</key><array><string>workout-processing</string></array>'

P="$OUT/HS.app"; W="$P/Watch/HSWatch.app"; B="$OUT/HSB.app"
rm -rf "$P" "$B" "$OUT/HSWatch.app"; mkdir -p "$W" "$B"
ent dev.ycode.hs.watchkitapp "" > "$OUT/watch.entitlements"
ent dev.ycode.hs "" > "$OUT/phone.entitlements"
ent dev.ycode.hs.b "" > "$OUT/phoneb.entitlements"
build watchsimulator arm64-apple-watchos27.0-simulator WATCH HSWatch "$W" "$OUT/watch.entitlements"
info dev.ycode.hs.watchkitapp HSWatch HealthSim WatchSimulator 4 "$WATCHX" > "$W/Info.plist"
codesign -f -s - "$W" >/dev/null 2>&1
build iphonesimulator arm64-apple-ios27.0-simulator PHONE HS "$P" "$OUT/phone.entitlements"
info dev.ycode.hs HS HealthSim iPhoneSimulator 1 "$PHONEX" > "$P/Info.plist"
codesign -f -s - "$P" >/dev/null 2>&1
xcrun --sdk iphonesimulator swiftc -version >/dev/null
cp "$P/HS" "$B/HS"
# HSB: same binary, other bundle and application-identifier (re-link for its entitlements).
build iphonesimulator arm64-apple-ios27.0-simulator PHONE HS "$B" "$OUT/phoneb.entitlements"
info dev.ycode.hs.b HS HealthSimB iPhoneSimulator 1 "$PHONEX" > "$B/Info.plist"
codesign -f -s - "$B" >/dev/null 2>&1
cp -R "$W" "$OUT/HSWatch.app"
echo "built into $OUT"

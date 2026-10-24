#!/bin/sh
# Build HealthProbe for the iOS simulator with the installed Xcode, in variants that
# differ in entitlements and Info.plist only:
#   HealthProbe.app         healthkit + background-delivery, usage strings     dev.ycode.healthprobe
#   HealthProbeB.app        same, second bundle (a second data source)          dev.ycode.healthprobe.b
#   HealthProbeNoEnt.app    application-identifier only, usage strings                     dev.ycode.healthprobe.noent
#   HealthProbeNoUsage.app  healthkit entitlement, no usage strings             dev.ycode.healthprobe.nousage
#   HealthProbeClin.app     healthkit + access=[health-records], clinical usage dev.ycode.healthprobe.clin
# Entitlements are embedded the way Xcode does for simulator builds (a
# __TEXT,__entitlements section); the ad-hoc signature carries none. No team or
# provisioning profile is involved.
# Usage: build.sh OUTDIR   (OUTDIR must be on the Mac, not on the drive)
set -eu
SRC=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?usage: build.sh OUTDIR}
mkdir -p "$OUT"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
# HealthKit names the app's data source from the application-identifier
# entitlement; without it, creating the default source throws. PREFIX is the
# team-identifier part ("" or e.g. "ABCDE12345."), made up, no real team.
PREFIX=${PREFIX-}

ent() { # extra-xml
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
$1
</dict></plist>
EOF
}
plist() { # name bundle-id extra-xml
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundleExecutable</key><string>HealthProbe</string>
<key>CFBundleName</key><string>$1</string>
<key>CFBundleDisplayName</key><string>$1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>7</string>
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
mk() { # app-name bundle-id entitlements-xml info-extra-xml
  A="$OUT/$1.app"; rm -rf "$A"; mkdir -p "$A"
  APPID="<key>application-identifier</key><string>$PREFIX$2</string>"
  ent "$APPID$3" > "$OUT/$1.entitlements"
  xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -isysroot "$SDK" \
    -fobjc-arc -fmodules -Wall -Wno-deprecated-declarations -Wno-unguarded-availability-new -O0 -g \
    -framework UIKit -framework HealthKit -framework CoreLocation -framework QuartzCore \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker "$OUT/$1.entitlements" \
    -I "$SRC" "$SRC/main.m" -o "$A/HealthProbe"
  plist "$1" "$2" "$4" > "$A/Info.plist"
  # Simulator builds carry entitlements only in the section above. Putting
  # developer entitlements into an ad-hoc signature makes the launch fail
  # (observed: "did not return a process handle").
  codesign -f -s - "$A" >/dev/null 2>&1
}
HK='<key>com.apple.developer.healthkit</key><true/>'
BG='<key>com.apple.developer.healthkit.background-delivery</key><true/>'
CLIN='<key>com.apple.developer.healthkit.access</key><array><string>health-records</string></array>'
USE='<key>NSHealthShareUsageDescription</key><string>HealthProbe reads made-up test samples.</string>
<key>NSHealthUpdateUsageDescription</key><string>HealthProbe writes made-up test samples.</string>'
CUSE='<key>NSHealthClinicalHealthRecordsShareUsageDescription</key><string>HealthProbe checks clinical record availability.</string>'
mk HealthProbe dev.ycode.healthprobe "$HK$BG" "$USE"
mk HealthProbeB dev.ycode.healthprobe.b "$HK$BG" "$USE"
mk HealthProbeNoEnt dev.ycode.healthprobe.noent "" "$USE"
mk HealthProbeNoUsage dev.ycode.healthprobe.nousage "$HK" ""
mk HealthProbeClin dev.ycode.healthprobe.clin "$HK$CLIN" "$USE$CUSE"
echo "built into $OUT"

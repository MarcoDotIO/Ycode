#!/bin/sh
# Build WKProbe for the iOS simulator with the installed Xcode, in variants
# that differ only in Info.plist and entitlements (all ad-hoc signed, no team):
#   WKProbe.app       location usage string, no entitlements      dev.ycode.wkprobe
#   WKProbeEnt.app    location usage string + com.apple.developer.weatherkit=true
#                                                                  dev.ycode.wkprobe.ent
#                     (entitlement in the __entitlements section only, as Xcode does)
#   WKProbeEntSig.app same, plus the entitlement in the ad-hoc signature
#                                                                  dev.ycode.wkprobe.entsig
#   WKProbeNoLoc.app  no location usage string, no entitlements   dev.ycode.wkprobe.noloc
#   WKProbeOwner.app  only when OWNER_BUNDLE_ID is set: that bundle ID (one the
#                     owner registered with WeatherKit enabled) + the entitlement
#                     section; for the entitled reference run (spec R0b)
# Usage: [OWNER_BUNDLE_ID=...] build.sh OUTDIR   (OUTDIR must be on the Mac, not on the drive)
set -eu
SRC=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?usage: build.sh OUTDIR}
mkdir -p "$OUT"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)

cat > "$OUT/ent.plist" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.developer.weatherkit</key><true/></dict></plist>
XML

xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios27.0-simulator -sdk "$SDK" \
  -swift-version 5 -parse-as-library -Onone -g "$SRC/main.swift" -o "$OUT/WKProbe.bin"
# Simulator builds carry entitlements in a __TEXT,__entitlements section (what
# Xcode does for simulator targets) as well as in the ad-hoc signature.
xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios27.0-simulator -sdk "$SDK" \
  -swift-version 5 -parse-as-library -Onone -g "$SRC/main.swift" -o "$OUT/WKProbeEnt.bin" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker "$OUT/ent.plist"

plist() { # name bundle-id extra-xml
  cat <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundleExecutable</key><string>WKProbe</string>
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
XML
}

mk() { # app-name bundle-id binary extra-xml [entitlements]
  rm -rf "$OUT/$1.app"; mkdir -p "$OUT/$1.app"
  cp "$OUT/$3" "$OUT/$1.app/WKProbe"
  plist "$1" "$2" "$4" > "$OUT/$1.app/Info.plist"
  if [ -n "${5:-}" ]; then
    codesign -f -s - --entitlements "$5" "$OUT/$1.app" >/dev/null 2>&1
  else
    codesign -f -s - "$OUT/$1.app" >/dev/null 2>&1
  fi
}
LOC='<key>NSLocationWhenInUseUsageDescription</key><string>WKProbe location test</string>'
mk WKProbe dev.ycode.wkprobe WKProbe.bin "$LOC"
# Entitlements only in the __entitlements section: an ad-hoc signature that
# carries this restricted entitlement is refused at launch (observed).
mk WKProbeEnt dev.ycode.wkprobe.ent WKProbeEnt.bin "$LOC"
mk WKProbeEntSig dev.ycode.wkprobe.entsig WKProbeEnt.bin "$LOC" "$OUT/ent.plist"
mk WKProbeNoLoc dev.ycode.wkprobe.noloc WKProbe.bin ""
if [ -n "${OWNER_BUNDLE_ID:-}" ]; then
  mk WKProbeOwner "$OWNER_BUNDLE_ID" WKProbeEnt.bin "$LOC"
fi
echo "built into $OUT"

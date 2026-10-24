#!/bin/sh
# Build HMProbe for the iOS simulator with the installed Xcode, in three
# variants that differ only in Info.plist and entitlements:
#   HMProbe.app         HomeKit entitlement + NSHomeKitUsageDescription   dev.ycode.hmprobe
#   HMProbeNoEnt.app    usage string only, no entitlement                 dev.ycode.hmprobe.noent
#   HMProbeNoUsage.app  entitlement only, no usage string                 dev.ycode.hmprobe.nousage
# For simulator builds, entitlements are embedded in the binary's
# __TEXT,__entitlements section (as Xcode does for "Sign to Run Locally")
# and the bundle is signed ad hoc without entitlements. No development
# team is involved.
# Usage: build.sh OUTDIR   (OUTDIR must be on the Mac, not on the drive)
set -eu
SRC=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?usage: build.sh OUTDIR}
mkdir -p "$OUT"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)

# Public constant names, taken from the SDK headers at build time (names only).
grep -h -o -E 'const (HM[A-Za-z0-9_]+)' "$SDK/System/Library/Frameworks/HomeKit.framework/Headers/"*.h \
  | awk '{print $2}' | sort -u > "$OUT/constnames.txt"

cat > "$OUT/hk.entitlements" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.developer.homekit</key><true/>
</dict></plist>
XML
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict/></plist>\n' > "$OUT/none.entitlements"

compile() { # out-binary entitlements-file
  xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -isysroot "$SDK" \
    -fobjc-arc -fmodules -Wall -Wno-arc-retain-cycles -O0 -g \
    -framework UIKit -framework HomeKit -framework CoreLocation -framework QuartzCore \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker "$2" \
    "$SRC/main.m" -o "$1"
}
compile "$OUT/HMProbe.ent.bin" "$OUT/hk.entitlements"
compile "$OUT/HMProbe.none.bin" "$OUT/none.entitlements"

plist() { # name bundle-id extra-xml
  cat <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundleExecutable</key><string>HMProbe</string>
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
$3
</dict></plist>
XML
}

mk() { # app-name bundle-id binary entitlements extra-xml
  rm -rf "$OUT/$1.app"; mkdir -p "$OUT/$1.app"
  cp "$OUT/$3" "$OUT/$1.app/HMProbe"
  cp "$OUT/constnames.txt" "$OUT/$1.app/"
  plist "$1" "$2" "$5" > "$OUT/$1.app/Info.plist"
  # Ad hoc signature WITHOUT entitlements: simulator processes are host
  # processes, and the host refuses to launch an ad hoc binary whose
  # signature carries the restricted HomeKit entitlement (observed: launch
  # fails with ESRCH). The simulator reads the __entitlements section.
  codesign -f -s - "$OUT/$1.app" >/dev/null 2>&1
}
USAGE='<key>NSHomeKitUsageDescription</key><string>HMProbe reads and changes test homes.</string>'
mk HMProbe        dev.ycode.hmprobe         HMProbe.ent.bin  hk.entitlements   "$USAGE"
mk HMProbeNoEnt   dev.ycode.hmprobe.noent   HMProbe.none.bin none.entitlements "$USAGE"
mk HMProbeNoUsage dev.ycode.hmprobe.nousage HMProbe.ent.bin  hk.entitlements   ""
echo "built into $OUT"

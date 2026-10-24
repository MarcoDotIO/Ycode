#!/bin/sh
# Build EKProbe and CNProbe for the iOS simulator with the installed Xcode, in
# variants that differ in Info.plist usage strings and entitlements only:
#   EKProbe.app        calendar full + write-only, reminders full strings   dev.ycode.ekprobe
#   EKProbeWO.app      calendar write-only string only                      dev.ycode.ekprobe.wo
#   EKProbeLegacy.app  pre-iOS-17 strings only (calendars, reminders)       dev.ycode.ekprobe.legacy
#   EKProbeNone.app    no usage strings                                     dev.ycode.ekprobe.none
#   CNProbe.app        contacts usage string                                dev.ycode.cnprobe
#   CNProbeLim.app     same (second client, answered with limited access)   dev.ycode.cnprobe.lim
#   CNProbeNone.app    no usage string                                      dev.ycode.cnprobe.none
#   CNProbeNotes.app   usage string + contacts notes entitlement            dev.ycode.cnprobe.notes
# Entitlements (if any) go into a __TEXT,__entitlements section as Xcode does
# for simulator builds; the ad-hoc signature carries none. No team, no
# provisioning profile, no account.
# Usage: build.sh OUTDIR   (OUTDIR on the Mac's internal disk)
set -eu
SRC=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?usage: build.sh OUTDIR}
mkdir -p "$OUT"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)

ent() {
  cat <<E2
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
$1
</dict></plist>
E2
}
plist() { # name bundle-id exe extra-xml
  cat <<E2
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundleExecutable</key><string>$3</string>
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
$4
</dict></plist>
E2
}
mk() { # app-name bundle-id src-dir exe frameworks entitlements-xml info-extra-xml
  A="$OUT/$1.app"; rm -rf "$A"; mkdir -p "$A"
  ent "<key>application-identifier</key><string>$2</string>$6" > "$OUT/$1.entitlements"
  FW=""; for f in $5; do FW="$FW -framework $f"; done
  # shellcheck disable=SC2086
  xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -isysroot "$SDK" \
    -fobjc-arc -fmodules -Wall -Wno-deprecated-declarations -Wno-unguarded-availability-new -O0 -g \
    $FW -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker "$OUT/$1.entitlements" \
    -I "$SRC/$3" "$SRC/$3/main.m" -o "$A/$4"
  plist "$1" "$2" "$4" "$7" > "$A/Info.plist"
  codesign -f -s - "$A" >/dev/null 2>&1
}
EKFW="UIKit EventKit EventKitUI CoreLocation QuartzCore"
CNFW="UIKit Contacts ContactsUI QuartzCore"
CALF='<key>NSCalendarsFullAccessUsageDescription</key><string>EKProbe reads and writes made-up test events.</string>'
CALW='<key>NSCalendarsWriteOnlyAccessUsageDescription</key><string>EKProbe adds made-up test events.</string>'
REMF='<key>NSRemindersFullAccessUsageDescription</key><string>EKProbe reads and writes made-up test reminders.</string>'
CALL='<key>NSCalendarsUsageDescription</key><string>EKProbe (legacy key) uses made-up test events.</string>'
REML='<key>NSRemindersUsageDescription</key><string>EKProbe (legacy key) uses made-up test reminders.</string>'
CNU='<key>NSContactsUsageDescription</key><string>CNProbe reads and writes made-up test contacts.</string>'
NOTES='<key>com.apple.developer.contacts.notes</key><true/>'
mk EKProbe dev.ycode.ekprobe EKProbe EKProbe "$EKFW" "" "$CALF$CALW$REMF"
mk EKProbeWO dev.ycode.ekprobe.wo EKProbe EKProbe "$EKFW" "" "$CALW"
mk EKProbeLegacy dev.ycode.ekprobe.legacy EKProbe EKProbe "$EKFW" "" "$CALL$REML"
mk EKProbeNone dev.ycode.ekprobe.none EKProbe EKProbe "$EKFW" "" ""
if [ -f "$SRC/CNProbe/main.m" ]; then
mk CNProbe dev.ycode.cnprobe CNProbe CNProbe "$CNFW" "" "$CNU"
mk CNProbeLim dev.ycode.cnprobe.lim CNProbe CNProbe "$CNFW" "" "$CNU"
mk CNProbeNone dev.ycode.cnprobe.none CNProbe CNProbe "$CNFW" "" ""
mk CNProbeNotes dev.ycode.cnprobe.notes CNProbe CNProbe "$CNFW" "$NOTES" "$CNU"
fi
echo "built into $OUT"

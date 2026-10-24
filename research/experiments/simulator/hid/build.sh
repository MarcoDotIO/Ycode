#!/bin/sh
# Build the HID research probes. Usage: build.sh <output-dir> (outside the repo).
#   <out>/hidmon   simulator-side HID service lister and event monitor (hidmon.m)
#   <out>/hidsend  Mac-side black-box driver of the reference input path (hidsend.m)
#   <out>/YcodeHIDProto.framework  prototype replacement HID manager bundle (hidproto.m);
#                  boot with SIMCTL_CHILD_SIMULATOR_HID_SYSTEM_MANAGER=<that directory>
set -e
OUT=${1:?output directory}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -fobjc-arc -O1 -g -Wall \
    -framework Foundation -framework IOKit -o "$OUT/hidmon" "$HERE/hidmon.m"
# Not given HID client entitlements: the simulator refuses to spawn an ad-hoc
# binary that claims them, and without them the client sees no services.
codesign -s - -f "$OUT/hidmon" >/dev/null
xcrun --sdk macosx clang -fobjc-arc -O1 -g -Wall -framework Foundation -framework CoreGraphics \
    -o "$OUT/hidsend" "$HERE/hidsend.m"
codesign -s - -f "$OUT/hidsend" >/dev/null
mkdir -p "$OUT/YcodeHIDProto.framework"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -fobjc-arc -O1 -g -Wall -dynamiclib \
    -framework Foundation -framework IOKit -framework QuartzCore -install_name @rpath/YcodeHIDProto.framework/YcodeHIDProto \
    -o "$OUT/YcodeHIDProto.framework/YcodeHIDProto" "$HERE/hidproto.m"
plutil -create xml1 "$OUT/YcodeHIDProto.framework/Info.plist"
for kv in CFBundleExecutable:YcodeHIDProto CFBundleIdentifier:com.ycode.research.hidproto \
          CFBundlePackageType:FMWK NSPrincipalClass:YcodeHIDProto CFBundleInfoDictionaryVersion:6.0; do
    plutil -insert "${kv%%:*}" -string "${kv#*:}" "$OUT/YcodeHIDProto.framework/Info.plist"
done
codesign -s - -f "$OUT/YcodeHIDProto.framework/YcodeHIDProto" >/dev/null
echo "built in $OUT"

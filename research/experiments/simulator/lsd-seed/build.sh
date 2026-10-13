#!/bin/sh
# Builds our probes for the iOS simulator platform (macOS only). Output: $OUT (default /tmp/yc-i4-probes).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out="${OUT:-/tmp/yc-i4-probes}"
mkdir -p "$out"
for p in fsprobe; do
  xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -fobjc-arc -O2 -Wall \
      -framework Foundation -o "$out/$p" "$here/$p.m"
done
echo "built in $out"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -O2 -Wall -o "$out/gadump" "$here/gadump.c"
echo "built gadump"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -O2 -Wall -o "$out/gabulk" "$here/gabulk.c"
echo "built gabulk"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -O2 -Wall -o "$out/timeprobe" "$here/timeprobe.c"
echo "built timeprobe"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -fobjc-arc -O2 -Wall -framework Foundation -o "$out/timeprobe2" "$here/timeprobe2.m"
echo "built timeprobe2"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -O2 -Wall -o "$out/growprobe" "$here/growprobe.c"
echo "built growprobe"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -O2 -Wall -Wno-deprecated-declarations -o "$out/clockprobe" "$here/clockprobe.c"
echo "built clockprobe"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -O2 -Wall -o "$out/trapbench" "$here/trapbench.c"
echo "built trapbench"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -fobjc-arc -O2 -Wall -framework Foundation -o "$out/prefprobe" "$here/prefprobe.m"
echo "built prefprobe"

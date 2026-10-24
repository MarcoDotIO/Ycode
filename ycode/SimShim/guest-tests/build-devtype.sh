#!/bin/sh
# Builds devtype/devprobe (specs/simulator/ipad.md §4.3 R4: the guest's view
# of its device type) for the iOS simulator platform. Runs on macOS only.
#   ../out/guest-tests/devtype/devprobe   arm64, iOS simulator platform
# Run it on the Thor as a one-shot: copy it into the device directory and
# pass ycode-simd --oneshot "<DEV path>/devprobe S" (it waits S seconds, then
# prints UIKit and MobileGestalt answers and `launchctl list`).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out="${OUT:-$here/../out/guest-tests/devtype}"
[ "$(uname -s)" = "Darwin" ] || { echo "build-devtype.sh: needs macOS" >&2; exit 1; }
mkdir -p "$out"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -fobjc-arc -O2 -Wall -Wextra -Werror -Wno-deprecated-declarations \
    -framework Foundation -framework UIKit -o "$out/devprobe" "$here/devtype/devprobe.m"
echo "$out/devprobe: $(wc -c < "$out/devprobe" | tr -d ' ') bytes"

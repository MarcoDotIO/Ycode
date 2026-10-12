#!/bin/sh
# Builds the stage-7 guest helper ylaunch (specs/simulator/stage7-contract.md
# §3.2 item 2) for the iOS simulator platform. Runs on macOS only.
#   ../out/guest-tests/stage7/ylaunch   arm64, LC_BUILD_VERSION platform 7,
#   stage7/ylaunch.entitlements in __TEXT,__entitlements (the simulator reads
#   entitlements from that section, not from the code signature;
#   app-install-launch.md §4.5), linker ad-hoc signature only.
# Copy the output directory to the Thor with rsync; ycode-simd --install-app
# and --launch find it with --guest-tools <dir> (default: SimShim/out/guest-tests/stage7).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out="${OUT:-$here/../out/guest-tests/stage7}"
[ "$(uname -s)" = "Darwin" ] || { echo "build-stage7.sh: needs macOS" >&2; exit 1; }
mkdir -p "$out"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -fobjc-arc -O2 -Wall -Wextra -Werror \
    -framework Foundation -Wl,-sectcreate,__TEXT,__entitlements,"$here/stage7/ylaunch.entitlements" \
    -o "$out/ylaunch" "$here/stage7/ylaunch.m"
xcrun otool -l "$out/ylaunch" | grep -q "sectname __entitlements" || { echo "build-stage7.sh: no __entitlements section" >&2; exit 1; }
echo "$out/ylaunch: $(wc -c < "$out/ylaunch" | tr -d ' ') bytes"
echo "build-stage7.sh: ok"

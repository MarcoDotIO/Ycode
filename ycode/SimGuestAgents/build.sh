#!/bin/sh
# Builds Ycode's guest agents for the iOS simulator platform
# (specs/simulator/simulator-features.md "Ycode implementation"). Runs on
# macOS only (the iOS simulator SDK's public headers and stubs).
#   out/ycode-settings-agent                 the settings agent (settings/): a launchd daemon
#       of the device; settings/ycode-settings-agent.entitlements is linked into
#       __TEXT,__entitlements (the simulator reads entitlements from that section,
#       app-install-launch.md §4.5)
#   out/libYcodeEnvironmentOverrides.dylib   Environment Overrides inside one app (overrides/)
# Copy out/ into the guest-tools directory on the simulator host (next to ylaunch);
# ycode-simd stages the agent into each device and runs it, and inserts the
# library into apps launched with --environment-overrides.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out="${OUT:-$here/out}"
[ "$(uname -s)" = "Darwin" ] || { echo "SimGuestAgents/build.sh: needs macOS" >&2; exit 1; }
mkdir -p "$out"
cc="xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -fobjc-arc -O2 -Wall -Wextra -Werror"
$cc -framework Foundation -framework CoreLocation \
    -Wl,-sectcreate,__TEXT,__entitlements,"$here/settings/ycode-settings-agent.entitlements" \
    -o "$out/ycode-settings-agent" "$here/settings/ycode-settings-agent.m"
xcrun otool -l "$out/ycode-settings-agent" | grep -q "sectname __entitlements" \
    || { echo "SimGuestAgents/build.sh: no __entitlements section" >&2; exit 1; }
$cc -dynamiclib -framework Foundation -framework UIKit -framework Accessibility -install_name @rpath/libYcodeEnvironmentOverrides.dylib \
    -o "$out/libYcodeEnvironmentOverrides.dylib" "$here/overrides/YcodeEnvironmentOverrides.m"
for f in ycode-settings-agent libYcodeEnvironmentOverrides.dylib; do echo "$out/$f: $(wc -c < "$out/$f" | tr -d ' ') bytes"; done
echo "SimGuestAgents/build.sh: ok"

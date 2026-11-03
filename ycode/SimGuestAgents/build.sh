#!/bin/sh
# Builds Ycode's guest agents for the iOS simulator platform
# (specs/simulator/simulator-features.md "Ycode implementation"). Runs on
# macOS only (the iOS simulator SDK's public headers and stubs).
#   out/ycode-settings-agent                 the settings agent (settings/): a launchd daemon
#       of the device; settings/ycode-settings-agent.entitlements is linked into
#       __TEXT,__entitlements (the simulator reads entitlements from that section,
#       app-install-launch.md §4.5)
#   out/libYcodeEnvironmentOverrides.dylib   Environment Overrides inside one app (overrides/)
#   out/libYcodeGauge.dylib                  Gauge's signpost agent inside a profiled app (gauge/;
#                                            specs/ide/profiler.md §3.1)
#   out/ycode-pairing-agent                  the pairing agent (pairing/; device-pairing.md P-4, §8): a launchd
#       daemon of every device; pairing/ycode-pairing-agent.entitlements in __TEXT,__entitlements
#   out/watchos/ycode-pairing-agent          the pairing agent built for the watchOS simulator (a signed
#       image is not retagged for another platform; watch devices use this one)
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
$cc -fobjc-arc-exceptions -framework Foundation \
    -Wl,-sectcreate,__TEXT,__entitlements,"$here/pairing/ycode-pairing-agent.entitlements" \
    -o "$out/ycode-pairing-agent" "$here/pairing/ycode-pairing-agent.m"
xcrun otool -l "$out/ycode-pairing-agent" | grep -q "sectname __entitlements" \
    || { echo "SimGuestAgents/build.sh: no __entitlements section in the pairing agent" >&2; exit 1; }
# The watchOS simulator's own builds of the daemons (platform 9): a signed
# image cannot be retagged (GuestImagePlatform), so watch devices get these.
wcc="xcrun --sdk watchsimulator clang -target arm64-apple-watchos27.0-simulator -fobjc-arc -O2 -Wall -Wextra -Werror"
mkdir -p "$out/watchos"
$wcc -fobjc-arc-exceptions -framework Foundation \
    -Wl,-sectcreate,__TEXT,__entitlements,"$here/pairing/ycode-pairing-agent.entitlements" \
    -o "$out/watchos/ycode-pairing-agent" "$here/pairing/ycode-pairing-agent.m"
$cc -dynamiclib -framework Foundation -framework UIKit -framework Accessibility -install_name @rpath/libYcodeEnvironmentOverrides.dylib \
    -o "$out/libYcodeEnvironmentOverrides.dylib" "$here/overrides/YcodeEnvironmentOverrides.m"
$cc -dynamiclib -install_name @rpath/libYcodeGauge.dylib -o "$out/libYcodeGauge.dylib" "$here/gauge/YcodeGauge.c"
for f in ycode-settings-agent ycode-pairing-agent libYcodeEnvironmentOverrides.dylib libYcodeGauge.dylib watchos/ycode-pairing-agent; do echo "$out/$f: $(wc -c < "$out/$f" | tr -d ' ') bytes"; done
echo "SimGuestAgents/build.sh: ok"

#!/bin/sh
# Builds the simulator's guest tools for the aarch64 release's simulator tree:
# ylaunch (installs and launches apps in a device) and Ycode's guest agents
# (settings, pairing, environment overrides, Gauge's signposts, camera,
# health). They are iOS- and watchOS-simulator programs of our own, so they
# build on a Mac with the simulator SDKs; build-flatpak.sh puts them in the
# tree with YCODE_GUEST_TOOLS=<dir> (the release's guest-tools job).
#
# Usage (macOS, from anywhere): packaging/flatpak/build-guest-tools.sh <out-dir>
# <out-dir> gets ylaunch and the agents side by side, as ycode-simd's
# --guest-tools folder expects (SimShim/out/guest-tests/stage7 in the tree).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
ycode=$(cd "$here/../../ycode" && pwd)
out=${1:?usage: build-guest-tools.sh <out-dir>}
[ "$(uname -s)" = Darwin ] || { echo "build-guest-tools: needs macOS (the simulator SDKs)" >&2; exit 1; }
mkdir -p "$out"
out=$(cd "$out" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

OUT="$tmp/stage7" sh "$ycode/SimShim/guest-tests/build-stage7.sh"
OUT="$tmp/agents" sh "$ycode/SimGuestAgents/build.sh"
OUT="$tmp/agents" sh "$ycode/SimGuestAgents/build-camera.sh"
OUT="$tmp/agents" sh "$ycode/SimGuestAgents/build-health.sh"

# Objects and the health agent's test app stay behind.
rm -rf "$tmp/agents"/obj-* "$tmp/agents/HealthCheck.app"
cp "$tmp/stage7/ylaunch" "$out/"
cp -R "$tmp/agents/." "$out/"

# What a run needs: ylaunch, and the agents ycode-simd stages into a device.
for f in ylaunch ycode-settings-agent ycode-pairing-agent watchos/ycode-pairing-agent libYcodeEnvironmentOverrides.dylib \
         libYcodeGauge.dylib libYcodeCamera.dylib YcodeHealth.app/YcodeHealth watchos/YcodeHealth.app/YcodeHealth; do
    [ -s "$out/$f" ] || { echo "build-guest-tools: $f is missing" >&2; exit 1; }
done
find "$out" -type f ! -name MANIFEST.txt | sed "s|^$out/||" | LC_ALL=C sort > "$out/MANIFEST.txt"
echo "build-guest-tools: $(wc -l < "$out/MANIFEST.txt" | tr -d ' ') files in $out"

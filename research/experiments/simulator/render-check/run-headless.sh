#!/bin/sh
# R6: boot a throwaway device with the capture framebuffer (sfbcapture) and the
# Metal host names denied, then capture the home screen, Settings, and the probe
# app. Original Ycode script.
# Usage: run-headless.sh <udid> <build dir> <run dir> [extra SIMCTL_CHILD_ K=V ...]
# Writes into <run dir>: frames.log, sfb.log, env/*.env.log, <name>.raw/.txt/.png, log-*.txt
set -e
UDID=${1:?udid}; B=${2:?build}; R=${3:?run dir}; shift 3
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$R/env"
cd /tmp
snap() {   # snap <name>: ask the framebuffer for the last presented surface
  rm -f "$R/$1.txt"; echo "$1" > "$R/snap"
  for i in $(seq 1 40); do [ -f "$R/$1.txt" ] && break; sleep 0.25; done
  sleep 0.5
  python3 -I "$HERE/raw2png.py" "$R/$1.raw" || cat "$R/$1.txt"
}
for kv in "$@"; do export "SIMCTL_CHILD_$kv"; done
export SIMCTL_CHILD_SIMULATOR_FRAMEBUFFER_FRAMEWORK="$B/capture/SimFramebuffer.framework/SimFramebuffer"
export SIMCTL_CHILD_SFBC_DIR="$R" SIMCTL_CHILD_SFBH_LOG="$R/sfb.log"
export SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$B/rcenv.dylib"
export SIMCTL_CHILD_RC_DIR="$R/env" SIMCTL_CHILD_RC_ONLY="backboardd,SpringBoard,Preferences,YcodeProbe"
export SIMCTL_CHILD_RC_DENY="${RC_DENY-com.apple.metal.simulator*,com.apple.gputools.service.simulator}"
T0=$(date +%s); touch "$R/t0.mark"   # crash reports newer than this
xcrun simctl boot "$UDID"
echo "booted; waiting 60 s"; sleep 60
snap home
xcrun simctl spawn "$UDID" log show --last 70s --style compact \
  --predicate 'process == "backboardd" AND (eventMessage CONTAINS[c] "screen size" OR eventMessage CONTAINS[c] "metal" OR eventMessage CONTAINS[c] "render" OR eventMessage CONTAINS[c] "software")' > "$R/log-boot.txt" 2>&1 || true
xcrun simctl launch "$UDID" com.apple.Preferences || echo "launch Settings failed"
sleep 8; snap settings
xcrun simctl terminate "$UDID" com.apple.Preferences || true
xcrun simctl install "$UDID" "$B/YcodeProbe.app" && xcrun simctl launch "$UDID" dev.ycode.probe || echo "probe launch failed"
sleep 8; snap probe
sleep 2; snap probe2
xcrun simctl terminate "$UDID" dev.ycode.probe || true
xcrun simctl install "$UDID" "$B/YcodeTick.app" && xcrun simctl launch "$UDID" dev.ycode.r6.tick || echo "tick launch failed"
sleep 5
F0=$(grep -c '^frame' "$R/frames.log"); sleep 10; F1=$(grep -c '^frame' "$R/frames.log")
echo "tick: frames presented in 10 s: $((F1 - F0))"
snap tick1; sleep 3; snap tick2
xcrun simctl terminate "$UDID" dev.ycode.r6.tick || true
echo "crash reports since boot:"
find ~/Library/Logs/DiagnosticReports -name '*.ips' -newer "$R/t0.mark" 2>/dev/null | sed 's|.*/||'
tail -3 "$R/frames.log"; grep -c '^frame' "$R/frames.log"

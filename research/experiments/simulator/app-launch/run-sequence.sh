#!/bin/sh
# Install and launch the probe app on a booted simulator device using only
# guest components plus ylaunch (no `simctl install` / `simctl launch`).
# `simctl spawn` is used only as the stand-in for Ycode's own "spawn a
# one-shot guest program" control operation.
#
# Usage: run-sequence.sh <device-udid> <build-dir>
#   <build-dir> is the output of build.sh and must be outside the repo
#   (spawning from the repo volume was seen to hang).
set -e
DEV=${1:?device udid}
OUT=${2:?build dir}
DATA="$HOME/Library/Developer/CoreSimulator/Devices/$DEV/data"
spawn() { xcrun simctl spawn "$DEV" "$OUT/ylaunch" "$@"; }

spawn uninstall-ix dev.ycode.probe || true          # start clean; failure is fine if absent
spawn install-ix "$OUT/YcodeProbe.app"              # IXAppInstallCoordinator simple install
spawn lookup dev.ycode.probe                         # LSApplicationProxy: bundle + data container
mkdir -p "$DATA/tmp/ycode"                           # guest /tmp is DEV/data/tmp for stdio paths
rm -f "$DATA/tmp/ycode/probe.err"
spawn open-fbs dev.ycode.probe --err /tmp/ycode/probe.err --out /tmp/ycode/probe.out \
    --arg FROM-YLAUNCH --env YCODE_PROBE=ylaunch      # FBSOpenApplicationService + __DebugOptions
sleep 3
sed -n '/== YCODE-PROBE BEGIN/,/== YCODE-PROBE END/p' "$DATA/tmp/ycode/probe.err" | grep -v '^env \|^image '

#!/bin/sh
# Runs the layout probe on the Mac it runs on (scripts/layout-probe.sh copies
# it to the Mac under test). Needs a logged-in GUI session for this user.
#
# Usage: layout-probe-run.sh <Ycode.app> <out-dir> [show 0|1] [timeout-seconds]
#
# The probe writes <report>.pid while it runs; after the timeout that exact
# process is ended.
set -eu
app=$1
dir=$2
show=${3:-0}
timeout=${4:-120}
rm -rf "$dir/shots" "$dir/probe.json" "$dir/probe.json.pid" "$dir/probe.log"
mkdir -p "$dir"
if ! open -n -g --env "YCODE_LAYOUT_PROBE=$dir/probe.json" --env "YCODE_LAYOUT_PROBE_SHOTS=$dir/shots" \
    --env "YCODE_LAYOUT_PROBE_SHOW=$show" --stdout "$dir/probe.log" --stderr "$dir/probe.log" "$app"; then
    # LaunchServices can refuse a copy it has seen before (error -10810).
    # From a shell inside the GUI session the executable runs directly.
    echo "layout-probe: open failed; running the executable directly" >&2
    exe=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")
    YCODE_LAYOUT_PROBE="$dir/probe.json" YCODE_LAYOUT_PROBE_SHOTS="$dir/shots" YCODE_LAYOUT_PROBE_SHOW="$show" \
        "$app/Contents/MacOS/$exe" >"$dir/probe.log" 2>&1 &
fi
waited=0
while [ ! -f "$dir/probe.json" ] && [ "$waited" -lt "$timeout" ]; do
    sleep 1
    waited=$((waited + 1))
done
if [ ! -f "$dir/probe.json" ]; then
    echo "layout-probe: no report after ${timeout}s" >&2
    pid=$(cat "$dir/probe.json.pid" 2>/dev/null || true)
    case "$pid" in
        "" | *[!0-9]*) ;;
        *) kill "$pid" 2>/dev/null || true ;;
    esac
    exit 1
fi
# The app quits right after writing the report.
waited=0
while [ -f "$dir/probe.json.pid" ] && [ "$waited" -lt 10 ]; do
    sleep 1
    waited=$((waited + 1))
done

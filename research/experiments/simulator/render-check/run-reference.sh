#!/bin/sh
# R6: normal CoreSimulator boot of the same throwaway device (no Ycode pieces):
# reference screenshots with `simctl io screenshot`, a Metal device check, and a
# stack sample of backboardd (frame NAMES only, to see which renderer runs).
# Original Ycode script. Usage: run-reference.sh <udid> <build dir> <run dir>
set -e
UDID=${1:?udid}; B=${2:?build}; R=${3:?run dir}
mkdir -p "$R"; cd /tmp
xcrun simctl boot "$UDID"
echo "booted; waiting 60 s"; sleep 60
xcrun simctl io "$UDID" screenshot "$R/ref-home.png"
xcrun simctl spawn "$UDID" "$B/mtlprobe" > "$R/mtlprobe.txt" 2>&1 || true
# this device's backboardd: the child of the launchd_sim whose command line names the UDID
LS=$(ps -ax -o pid=,command= | grep "launchd_sim .*Devices/$UDID/" | grep -v grep | awk '{print $1}' | head -1)
BB=$(ps -ax -o pid=,ppid=,command= | awk -v p="$LS" '$2==p && /usr\/libexec\/backboardd/ {print $1}' | head -1)
xcrun simctl launch "$UDID" com.apple.Preferences
sleep 8; xcrun simctl io "$UDID" screenshot "$R/ref-settings.png"
(xcrun simctl terminate "$UDID" com.apple.Preferences; sleep 1; xcrun simctl launch "$UDID" com.apple.Preferences) &
sample "$BB" 3 -file "$R/sample-bb-ref.txt" >/dev/null 2>&1 || true
wait
xcrun simctl terminate "$UDID" com.apple.Preferences || true
xcrun simctl install "$UDID" "$B/YcodeProbe.app"; xcrun simctl launch "$UDID" dev.ycode.probe
sleep 8; xcrun simctl io "$UDID" screenshot "$R/ref-probe.png"
grep -o "CA::[A-Za-z_]*::[A-Za-z_]*" "$R/sample-bb-ref.txt" | sort | uniq -c | sort -rn | head -15
cat "$R/mtlprobe.txt"

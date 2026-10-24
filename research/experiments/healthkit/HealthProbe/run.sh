#!/bin/sh
# Launch one HealthProbe variant with a phase on a test simulator, wait until
# the probe prints "DONE" (or SECONDS pass), save its report and a screenshot
# into OUTDIR, then terminate it.
# Usage: run.sh UDID BUNDLE-ID PHASE NAME OUTDIR SECONDS [keep]
#   keep: leave the app running (for an authorization sheet the user answers)
# simctl's --stderr path is resolved inside the guest, so /tmp/X lands in
# <device>/data/tmp/X on the Mac.
set -u
U=$1; B=$2; PH=$3; N=$4; OUT=$5; SECS=$6; KEEP=${7:-}
mkdir -p "$OUT"
DEV="$HOME/Library/Developer/CoreSimulator/Devices/$U/data"
rm -f "$DEV/tmp/healthprobe-$N.txt"
xcrun simctl terminate "$U" "$B" >/dev/null 2>&1
xcrun simctl launch --stderr="/tmp/healthprobe-$N.txt" "$U" "$B" -phase "$PH"
i=0
while [ $i -lt "$SECS" ]; do
  grep -q "DONE" "$DEV/tmp/healthprobe-$N.txt" 2>/dev/null && break
  sleep 1; i=$((i + 1))
done
xcrun simctl io "$U" screenshot "$OUT/$N.png" >/dev/null 2>&1
cp "$DEV/tmp/healthprobe-$N.txt" "$OUT/$N.txt" 2>/dev/null
[ -z "$KEEP" ] && xcrun simctl terminate "$U" "$B" >/dev/null 2>&1
echo "done $N after ${i}s: $(wc -l < "$OUT/$N.txt" 2>/dev/null) lines"

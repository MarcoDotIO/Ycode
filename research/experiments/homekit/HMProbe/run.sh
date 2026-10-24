#!/bin/sh
# Launch one HMProbe variant on a test simulator, wait, save its report and a
# screenshot into OUTDIR, then terminate it.
# Usage: run.sh UDID BUNDLE-ID NAME OUTDIR SECONDS [app args...]
#   e.g. run.sh $U dev.ycode.hmprobe model /path/out 60 -mode model
# simctl's --stderr path is resolved inside the guest, so /tmp/X lands in
# <device>/data/tmp/X on the Mac.
set -u
U=$1; B=$2; N=$3; OUT=$4; SECS=$5; shift 5
mkdir -p "$OUT"
DEV="$HOME/Library/Developer/CoreSimulator/Devices/$U/data"
rm -f "$DEV/tmp/hmprobe-$N.txt"
xcrun simctl terminate "$U" "$B" >/dev/null 2>&1
xcrun simctl launch --stderr="/tmp/hmprobe-$N.txt" "$U" "$B" "$@"
sleep "$SECS"
xcrun simctl io "$U" screenshot --display=LCD "$OUT/$N.png" >/dev/null 2>&1
cp "$DEV/tmp/hmprobe-$N.txt" "$OUT/$N.txt" 2>/dev/null
xcrun simctl terminate "$U" "$B" >/dev/null 2>&1
echo "done $N: $(wc -l < "$OUT/$N.txt" 2>/dev/null) lines"

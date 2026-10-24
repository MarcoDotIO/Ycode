#!/bin/sh
# Launch one probe variant with a phase on a test simulator, wait until the
# probe prints "DONE" (or SECONDS pass), save its report into OUTDIR
# (screenshots: the iPhone Duo's simctl io capture is the inner display and
# black; we capture the cover display with the simulator panel tool), then terminate it.
# Usage: run.sh UDID BUNDLE-ID PHASE NAME OUTDIR SECONDS [keep]
#   keep: leave the app running (for a system prompt answered by taps)
# simctl's --stderr path is resolved inside the guest: /tmp/X lands in
# <device>/data/tmp/X on the Mac.
set -u
U=$1; B=$2; PH=$3; N=$4; OUT=$5; SECS=$6; KEEP=${7:-}
mkdir -p "$OUT"
DEV="$HOME/Library/Developer/CoreSimulator/Devices/$U/data"
rm -f "$DEV/tmp/ekcn-$N.txt"
xcrun simctl terminate "$U" "$B" >/dev/null 2>&1
xcrun simctl launch --stderr="/tmp/ekcn-$N.txt" "$U" "$B" -phase "$PH" >/dev/null
i=0
while [ $i -lt "$SECS" ]; do
  grep -q "DONE" "$DEV/tmp/ekcn-$N.txt" 2>/dev/null && break
  sleep 1; i=$((i + 1))
done
cp "$DEV/tmp/ekcn-$N.txt" "$OUT/$N.txt" 2>/dev/null
[ -z "$KEEP" ] && xcrun simctl terminate "$U" "$B" >/dev/null 2>&1
echo "done $N after ${i}s: $(wc -l < "$OUT/$N.txt" 2>/dev/null) lines"

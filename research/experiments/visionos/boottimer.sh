#!/bin/sh
# Boot a simulator and report: simctl boot return, bootstatus terminal, and the
# first screenshot whose PNG is larger than THRESH bytes (the rendered room;
# the boot card is ~0.2 MB at 3840x2160, the room 6-7 MB).
# Usage: boottimer.sh <udid> <outdir> [THRESH]
U=$1; OUT=$2; TH=${3:-2000000}
now() { python3 -I -c 'import time;print(time.time())'; }
t0=$(now)
xcrun simctl boot "$U"
t1=$(now)
xcrun simctl bootstatus "$U" > "$OUT/bootstatus-timed.txt" 2>&1 &
bs=$!
done_bs=""; i=0
while :; do
  if [ -z "$done_bs" ] && ! kill -0 $bs 2>/dev/null; then done_bs=$(now); fi
  xcrun simctl io "$U" screenshot "$OUT/poll.png" >/dev/null 2>&1
  sz=$(stat -f %z "$OUT/poll.png" 2>/dev/null || echo 0)
  if [ "$sz" -gt "$TH" ]; then t3=$(now); break; fi
  i=$((i+1)); [ $i -gt 300 ] && { t3=never; break; }
  sleep 1
done
wait $bs; [ -z "$done_bs" ] && done_bs=$(now)
echo "boot_cmd $(echo "$t1-$t0"|bc) bootstatus $(echo "$done_bs-$t0"|bc) room_visible $( [ "$t3" = never ] && echo never || echo "$t3-$t0"|bc)"

#!/bin/sh
# Run one RKProbe mode on a booted test simulator and save its log and a screenshot.
# Usage: run.sh <device-udid> <build-dir> <out-dir> <mode> [max-seconds]
# The run ends when the log shows the mode's end markers (or after max-seconds).
# (simctl launch --stdout=<file> did not create the file for our scratch paths,
#  so the console of `simctl launch --console` is captured instead.)
DEV=$1; BUILD=$2; OUT=$3; MODE=$4; MAX=${5:-150}
mkdir -p "$OUT"
LOG="$OUT/$MODE.log"
case "$MODE" in
  rv-physics|rv-anim) NEED="RKP done=" ;;
  rv-usd) NEED="RKP usd.done=" ;;
  renderer) NEED="RKP renderer.px.floor" ;;
  *) NEED="RKP framecounter.done=" ;;
esac
xcrun simctl launch --console --terminate-running-process "$DEV" dev.ycode.rkprobe -mode "$MODE" > "$LOG" 2>&1 &
i=0
while [ $i -lt "$MAX" ]; do
  sleep 2; i=$((i + 2))
  if grep -q "$NEED" "$LOG" && { [ "$NEED" = "RKP framecounter.done=" ] || grep -q "RKP framecounter.done=" "$LOG" || [ "$MODE" = renderer ]; }; then break; fi
done
xcrun simctl io "$DEV" screenshot --type=png "$OUT/$MODE.png" >/dev/null 2>&1
xcrun simctl terminate "$DEV" dev.ycode.rkprobe >/dev/null 2>&1
sleep 1
echo "$MODE: $(grep -c '^RKP' "$LOG") lines, ${i}s"

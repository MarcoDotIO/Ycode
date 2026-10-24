#!/bin/sh
# Run one MKProbe mode on a booted ycode-test-mapkit* simulator and drive it:
# the app prints "SHOT <name>" (take a screenshot) and "READY <action>"
# (perform an input or host action); the run ends at "done".
# Usage: run.sh <udid> <build-dir> <out-dir> <mode> [variant]
#   TAG=<name> names the output files (default mode[-variant]); NOTRACE=1 skips svctrace.
#   APP=MKProbeNoLoc runs the variant without a location usage string.
DEV=$1; BUILD=$2; OUT=$3; MODE=$4; VAR=${5:-}
TAG=${TAG:-$MODE${VAR:+-$VAR}}
APP=${APP:-MKProbe}
BID=dev.ycode.mkprobe; [ "$APP" = MKProbeNoLoc ] && BID=dev.ycode.mkprobe.noloc
mkdir -p "$OUT"
LOG="$OUT/$TAG.log"
HS="$BUILD/hid/hidsend"
jobs() { xcrun simctl spawn "$DEV" launchctl list 2>/dev/null | awk '$1 != "-" && NR > 1 {print $3}' | sort; }
shot() { xcrun simctl io "$DEV" screenshot ${SHOTDISP:+--display=$SHOTDISP} --type=png "$OUT/$TAG-$1.png" >/dev/null 2>&1; }
drag() { "$HS" "$DEV" drag "$@" >/dev/null 2>&1; }
tap() { "$HS" "$DEV" tap "$1" "$2" >/dev/null 2>&1; }
dtap() { tap "$1" "$2" & P=$!; sleep 0.12; tap "$1" "$2"; wait $P; }
mark() { echo "MKPDRIVER $(date +%H:%M:%S) $1" >> "$OUT/$TAG.driver"; }
: > "$OUT/$TAG.driver"

jobs > "$OUT/$TAG.jobs.before"
ARGS="-mode $MODE"; [ -n "$VAR" ] && ARGS="$ARGS -variant $VAR"
if [ -n "${NOTRACE:-}" ]; then
  xcrun simctl launch --console --terminate-running-process "$DEV" $BID $ARGS > "$LOG" 2>&1 &
else
  SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$BUILD/svctrace.dylib" \
  xcrun simctl launch --console --terminate-running-process "$DEV" $BID $ARGS > "$LOG" 2>&1 &
fi
LP=$!
seen=0; t=0; LIMIT=${LIMIT:-420}
while [ $t -lt $((LIMIT * 4)) ]; do
  n=$(grep -c "^MKP \[" "$LOG" 2>/dev/null); n=${n:-0}
  if [ "$n" -gt "$seen" ]; then
    grep "^MKP \[" "$LOG" | sed -n "$((seen + 1)),${n}p" | while IFS= read -r line; do
      case "$line" in
        *"] SHOT "*) name=${line##*SHOT }; shot "$name"; mark "shot $name" ;;
        *"] READY "*) act=${line##*READY }; mark "action $act"
          case "$act" in
            gesture=drag-h) drag 0.3 0.5 0.7 0.5 20 ;;
            gesture=drag-v) drag 0.5 0.4 0.5 0.6 20 ;;
            gesture=fling) drag 0.3 0.5 0.7 0.5 3 ;;
            gesture=doubletap-center) dtap 0.5 0.5 ;;
            gesture=doubletap-offcenter) dtap 0.25 0.3 ;;
            gesture=long-press) drag 0.5 0.5 0.5 0.5 60 ;;
            gesture=edge-drag) HID_EDGE=2 drag 0.005 0.5 0.4 0.5 20 ;;
            tap=*) key=${act#tap=}; xy=$(grep "target $key=" "$LOG" | tail -1 | sed 's/.*=//'); tap ${xy%,*} ${xy#*,}; mark "tapped $xy" ;;
            location=stanford) xcrun simctl location "$DEV" set 37.4275,-122.1697 ;;
            location=clear) xcrun simctl location "$DEV" clear ;;
            drag-map|drag-look) drag 0.3 0.5 0.7 0.5 20 ;;
            stop-geod) xcrun simctl spawn "$DEV" launchctl bootout system/com.apple.geod >> "$OUT/$TAG.driver" 2>&1; mark "bootout rc=$?" ;;
          esac ;;
      esac
    done
    seen=$n
  fi
  grep -q "^MKP \[.*\] done$" "$LOG" 2>/dev/null && break
  kill -0 $LP 2>/dev/null || break
  sleep 0.25; t=$((t + 1))
done
jobs > "$OUT/$TAG.jobs.after"
xcrun simctl terminate "$DEV" $BID >/dev/null 2>&1
sleep 1; kill $LP 2>/dev/null
echo "$TAG: $(grep -c '^MKP' "$LOG") lines"

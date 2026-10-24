#!/bin/sh
# Run one SUIProbe mode on a booted test simulator, drive it from outside, and
# save its log, the service trace, launchd job diffs and screenshots.
# Usage: run.sh <device-udid> <build-dir> <out-dir> <mode> [extra launch arguments]
#   TAG=<name> names the output files (default: the mode).
#   NOTRACE=1 runs without the svctrace.dylib insertion.
# Driver steps are timed from the app's `root.onAppear` line.
DEV=$1; BUILD=$2; OUT=$3; MODE=$4; shift 4
TAG=${TAG:-$MODE}
mkdir -p "$OUT"
LOG="$OUT/$TAG.log"
HS="$BUILD/hid/hidsend"
BID=dev.ycode.suiprobe

jobs() { xcrun simctl spawn "$DEV" launchctl list 2>/dev/null | awk '$1 != "-" && NR > 1 {print $3}' | sort; }
shot() { xcrun simctl io "$DEV" screenshot --type=png "$OUT/$TAG-$1.png" >/dev/null 2>&1; }
waitfor() { # pattern max-seconds
  i=0; while [ $i -lt "$2" ]; do grep -q "$1" "$LOG" 2>/dev/null && return 0; sleep 1; i=$((i + 1)); done; return 1; }
tgt() { grep "^SUP target.$1=" "$LOG" | tail -1 | sed 's/.*=//' | tr ',' ' '; }
tap() { set -- $(tgt "$1"); [ -n "$1" ] && "$HS" "$DEV" tap "$1" "$2" >/dev/null 2>&1; }
mark() { echo "SUPDRIVER $(date +%H:%M:%S) $1" >> "$OUT/$TAG.driver"; }
: > "$OUT/$TAG.driver"

jobs > "$OUT/$TAG.jobs.before"
if [ -n "$NOTRACE" ]; then
  xcrun simctl launch --console --terminate-running-process "$DEV" $BID -mode "$MODE" "$@" > "$LOG" 2>&1 &
else
  SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$BUILD/svctrace.dylib" \
  xcrun simctl launch --console --terminate-running-process "$DEV" $BID -mode "$MODE" "$@" > "$LOG" 2>&1 &
fi
waitfor "root.onAppear" 90 || echo "$TAG: no onAppear within 90 s"

case "$MODE" in
  lifecycle)
    sleep 4; mark "launch Preferences (app to background)"; xcrun simctl launch "$DEV" com.apple.Preferences >/dev/null
    sleep 5; shot background
    mark "launch probe again (foreground)"; xcrun simctl launch "$DEV" $BID >/dev/null
    sleep 4; mark "openurl suiprobe://hello"; xcrun simctl openurl "$DEV" "suiprobe://hello?x=1"
    # SpringBoard asks "Open in ...?" (Cancel left, Open right); accept it.
    sleep 3; shot openPrompt; mark "tap Open in the prompt"; "$HS" "$DEV" tap 0.633 0.528 >/dev/null 2>&1
    sleep 4; jobs > "$OUT/$TAG.jobs.during"; mark "terminate"; xcrun simctl terminate "$DEV" $BID; sleep 2 ;;
  nav)
    sleep 3; shot pushed1
    sleep 9; mark "tap row 0"; tap nav.row0
    sleep 2; shot afterTap; mark "edge swipe back"; HID_EDGE=2 "$HS" "$DEV" drag 0.005 0.5 0.8 0.5 25 >/dev/null 2>&1
    waitfor "SUP t=.* done=" 30 ;;
  list)
    sleep 3; shot list
    sleep 1; mark "fling"; "$HS" "$DEV" drag 0.4 0.75 0.4 0.3 10 >/dev/null 2>&1
    waitfor "SUP t=.* done=" 30 ;;
  controls)
    sleep 2; shot form
    sleep 1; mark "tap toggle switch"; tap ctl.toggle
    sleep 1; mark "tap button"; tap ctl.button
    sleep 1; mark "tap slider at 80%"; tap ctl.slider
    sleep 1; mark "tap stepper plus"; tap ctl.stepper
    waitfor "SUP t=.* done=" 30 ;;
  keyboard)
    sleep 2.5; shot focused
    mark "keys h i"; "$HS" "$DEV" key 0x0b >/dev/null 2>&1; "$HS" "$DEV" key 0x0c >/dev/null 2>&1
    sleep 1.5; mark "key Return"; "$HS" "$DEV" key 0x28 >/dev/null 2>&1
    sleep 2; mark "tap field"; tap kb.field; sleep 1.5; shot tapped
    waitfor "SUP t=.* done=" 30 ;;
  gesture)
    sleep 2; mark "tap g.tap"; tap g.tap
    sleep 2; mark "double tap g.double"; set -- $(tgt g.double); "$HS" "$DEV" tap "$1" "$2" >/dev/null 2>&1 & P=$!; sleep 0.12; "$HS" "$DEV" tap "$1" "$2" >/dev/null 2>&1; wait $P
    sleep 2; mark "long press g.long"; set -- $(tgt g.long); "$HS" "$DEV" drag "$1" "$2" "$1" "$2" 50 >/dev/null 2>&1
    sleep 2; mark "drag g.drag"; set -- $(tgt g.drag); "$HS" "$DEV" drag 0.25 "$2" 0.75 "$2" 20 >/dev/null 2>&1
    sleep 2; mark "tap g.button"; tap g.button
    sleep 2; mark "drag g.simul"; set -- $(tgt g.simul); "$HS" "$DEV" drag 0.3 "$2" 0.7 "$2" 15 >/dev/null 2>&1
    waitfor "SUP t=.* done=" 30 ;;
  env)
    sleep 3; mark "appearance dark"; xcrun simctl ui "$DEV" appearance dark; sleep 1; shot dark
    sleep 2; mark "content_size accessibility-large"; xcrun simctl ui "$DEV" content_size accessibility-large
    sleep 3; mark "increase_contrast enabled"; xcrun simctl ui "$DEV" increase_contrast enabled
    sleep 3; mark "revert"; xcrun simctl ui "$DEV" appearance light; xcrun simctl ui "$DEV" content_size large; xcrun simctl ui "$DEV" increase_contrast disabled
    waitfor "SUP t=.* done=" 30 ;;
  persist)
    # BG=1: send the app to the background before it is terminated (scene state is saved then).
    waitfor "SUP t=.* done=" 60
    if [ -n "$BG" ]; then mark "launch Preferences (probe to background)"; xcrun simctl launch "$DEV" com.apple.Preferences >/dev/null; sleep 5; fi
    C=$(xcrun simctl get_app_container "$DEV" $BID data)
    find "$C" -type f | sed "s#^$C/##" | sort > "$OUT/$TAG.container-files"
    plutil -p "$C/Library/Preferences/$BID.plist" > "$OUT/$TAG.prefs" 2>&1 ;;
  *)
    waitfor "SUP t=.* done=" 200 ;;
esac
shot end
jobs > "$OUT/$TAG.jobs.after"
xcrun simctl terminate "$DEV" $BID >/dev/null 2>&1
sleep 1
echo "$TAG: $(grep -c '^SUP ' "$LOG") SUP lines, $(grep -c '^SUPX ' "$LOG") trace lines; new jobs: $(comm -13 "$OUT/$TAG.jobs.before" "$OUT/$TAG.jobs.after" | tr '\n' ' ')"

#!/bin/sh
# Closing windows and quitting from Welcome on the Linux IDE must end the
# process with status 0 (ShellDriver+WindowClose.swift, YCODE_IDE_WINDOWCLOSE9):
# the wizard's and Settings' close buttons, then File ▸ Quit; File ▸ Quit
# from Welcome alone; and with Settings open. Each part runs in a private
# configuration (no recent projects, no first-launch offer).
#
#     WAYLAND_DISPLAY=... XDG_RUNTIME_DIR=... OV_SDL3_LIBRARY=... \
#       run.sh <ycode-ide> <work folder> <shots folder>
#
# Prints one line per part and exits 1 when any part failed.
set -u
IDE=$1; WORK=$2; OUT=$3
mkdir -p "$OUT"
FAILED=0
for PART in close quit quit-settings; do
  rm -rf "$WORK/$PART"
  mkdir -p "$WORK/$PART"
  LOG="$OUT/windowclose9-$PART.log"
  XDG_CONFIG_HOME="$WORK/$PART/config" XDG_DATA_HOME="$WORK/$PART/data" YCODE_NO_FIRST_LAUNCH=1 \
    YCODE_IDE_WINDOWCLOSE9="$OUT/windowclose9-$PART" YCODE_IDE_WINDOWCLOSE9_PART=$PART OV_QUIT_AFTER=60 \
    timeout 90 "$IDE" > "$LOG" 2>&1
  STATUS=$?
  if [ $STATUS -ne 0 ]; then
    echo "$PART: FAIL exit $STATUS"; FAILED=1
  elif ! grep -q "windowclose9: quit with" "$LOG"; then
    echo "$PART: FAIL the walk did not reach the quit"; FAILED=1
  elif grep -q "still running after the quit shortcut" "$LOG"; then
    echo "$PART: FAIL the quit shortcut did not quit"; FAILED=1
  else
    echo "$PART: exit 0"
  fi
done
exit $FAILED

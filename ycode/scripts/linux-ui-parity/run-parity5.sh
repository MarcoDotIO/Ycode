#!/bin/sh
# The Linux half of the cross-platform parity audit
# (specs/ide/cross-platform-parity.md): makes the repositories of
# make-parity5.sh and runs ycode-ide's YCODE_IDE_PARITY5 walk in light and
# dark: the main window's states at 1400 x 880, the file at 1100 x 880, the
# merge alert and sheet, then Welcome, Settings and the runtime wizard's
# host step (no path; the first run made the repository the recent project).
#
#     WAYLAND_DISPLAY=... XDG_RUNTIME_DIR=... OV_SDL3_LIBRARY=... \
#       run-parity5.sh <ycode-ide> <work folder> <shots folder> [light dark]
#
# Writes <shots>/linux-<appearance>-<state>.png and .txt, and one log per run.
set -u
IDE=$1; WORK=$2; OUT=$3; shift 3
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"
for S in ${@:-light dark}; do
  rm -rf "$WORK/$S"
  "$HERE/make-parity5.sh" "$WORK/$S" > /dev/null
  export XDG_CONFIG_HOME="$WORK/$S/config" XDG_DATA_HOME="$WORK/$S/data" OV_COLOR_SCHEME=$S YCODE_IDE_PARITY5="$OUT/linux-$S"
  run() {  # <part> <size> <log> [path]
    PART=$1 SIZE=$2 LOG=$3; shift 3
    YCODE_IDE_PARITY5_PART=$PART YCODE_IDE_WINDOW_SIZE=$SIZE OV_QUIT_AFTER=150 timeout 200 "$IDE" "$@" > "$OUT/linux-$S-$LOG.log" 2>&1
    echo "$S $PART: exit $?"
  }
  run main 1400x880 main "$WORK/$S/rest/Merger"
  run narrow 1100x880 narrow "$WORK/$S/rest/Merger"
  run merge 1400x880 merge "$WORK/$S/merge/Merger"
  run welcome 1400x880 welcome
done

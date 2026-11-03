#!/bin/bash
# The Linux half of the paired screenshots (docs/PARITY.md §5.10): runs
# ycode-ide under an X server with YCODE_IDE_PARITY on a fresh copy of the
# Greeter package (make-demo.sh), light and dark, plus the Welcome screen.
#
#     DISPLAY=:N OV_SDL3_LIBRARY=<libSDL3.so.0> linux-run.sh <ycode-ide> <out folder> [light dark]
#
# Writes <out>/linux-<appearance>-<state>.png and the run's log.
set -u
IDE=$1; OUT=$2; shift 2
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"
for S in ${@:-light dark}; do
  WORK=$(mktemp -d)
  "$HERE/make-demo.sh" "$WORK" > /dev/null
  # A private home: the workspace run notes the package as the one recent
  # project, which Welcome then lists (as the macOS probe's Welcome does).
  export XDG_CONFIG_HOME="$WORK/config" XDG_DATA_HOME="$WORK/data" HOME="$WORK"
  OV_PLATFORM=sdl OV_COLOR_SCHEME=$S YCODE_IDE_PARITY="$OUT/linux-$S" \
    timeout 300 "$IDE" "$WORK/Greeter" > "$OUT/linux-$S.log" 2>&1
  echo "exit $?" >> "$OUT/linux-$S.log"
  # Welcome: no path.
  OV_PLATFORM=sdl OV_COLOR_SCHEME=$S YCODE_IDE_PARITY="$OUT/linux-$S" \
    timeout 60 "$IDE" > "$OUT/linux-$S-welcome.log" 2>&1
  rm -rf "$WORK"
done

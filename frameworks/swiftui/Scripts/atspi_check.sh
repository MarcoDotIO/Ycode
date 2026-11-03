#!/bin/bash
# OV-ATSPI: the AT-SPI client check on a Linux machine, without root.
#
#   Scripts/atspi_check.sh <out-dir>
#
# Runs, inside a private session bus (dbus-run-session), the mini IDE
# (.build/debug/ov-mini-ide, built beforehand) on $DISPLAY, then
# Scripts/atspi_client.py against it. The accessibility bus comes from the
# system's at-spi2-core (the bus launcher is activated on the private
# session bus; it starts its own bus daemon and the registry). Needs an X
# server on $DISPLAY (Xvfb is fine), $OV_SDL3_LIBRARY, python3 with the
# Atspi GObject bindings; $XDOTOOL (a command line) adds real clicks.
# Writes app.log, client.log and the final state to <out-dir>.
set -u
OUT=${1:?out dir}
HERE=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$OUT"
if [ -z "${INSIDE_SESSION:-}" ]; then
    INSIDE_SESSION=1 exec dbus-run-session -- "$0" "$OUT"
fi
pause() { timeout "$1" tail -f /dev/null; }
export OV_PLATFORM=sdl OV_ATSPI_TRACE=1 OV_SETTINGS_PORTAL=0
echo "session bus: $DBUS_SESSION_BUS_ADDRESS" > "$OUT/session.log"
gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus --method org.a11y.Bus.GetAddress >> "$OUT/session.log" 2>&1
cd "$HERE"
OV_QUIT_AFTER=${QUIT_AFTER:-45} OV_SCREENSHOT="$OUT/atspi-final.png" timeout 90 .build/debug/ov-mini-ide > "$OUT/app.log" 2>&1 &
APP=$!
for _ in $(seq 1 100); do grep -q "embedded" "$OUT/app.log" 2>/dev/null && break; pause 0.1; done
pause 1
if [ -n "${XDOTOOL:-}" ]; then X=(--xdotool "$XDOTOOL"); else X=(); fi
python3 -I Scripts/atspi_client.py ov-mini-ide "${X[@]}" > "$OUT/client.log" 2>&1
echo "client exit $?" >> "$OUT/client.log"
wait $APP
echo "app exit $?" >> "$OUT/app.log"
grep -E "^(PASS|FAIL|RESULT)" "$OUT/client.log"
grep -E "^state:" "$OUT/app.log"

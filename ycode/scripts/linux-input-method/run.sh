#!/bin/bash
# Tests text input through a real input method (IBus) in the Linux IDE,
# without touching the desktop you are logged in to: a headless GNOME Shell
# with its own D-Bus, dconf, IBus and runtime folders, under <work>.
# Keys go in through that shell's remote-desktop interface (type-keys.py), so
# they pass through IBus as typed keys do. ycode-ide reports the composition
# (YCODE_IDE_IME, ShellDriverInputMethod.swift).
#
# Usage: run.sh <work-dir> <ycode-ide> <package> <sources> <steps> [shot-dir]
#   sources  GNOME input sources, e.g. "[('ibus', 'table:cangjie5')]" or
#            "[('xkb', 'us+intl')]" (the engine needs to be installed)
#   steps    a type-keys.py steps file; LOG and SHOTS in it are replaced by
#            the IDE's log and the shot folder
# Environment: OV_SDL3_LIBRARY as for any run; QUIT_AFTER (default 20 s).
# Needs gnome-shell, ibus and PyGObject; no root. Wayland only: a headless
# shell with Xwayland does not finish starting without a session manager.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
work=$(mkdir -p "$1" && cd "$1" && pwd)
ide=$2 package=$3 sources=$4 steps=$5
shots=${6:-$work/shots}
mkdir -p "$work/config" "$work/data" "$work/cache" "$work/state" "$work/run" "$shots"
chmod 700 "$work/run"

# The shell and every service its bus starts get the private folders.
cat > "$work/session.sh" <<'EOF'
#!/bin/bash
gsettings set org.gnome.desktop.input-sources sources "$IME_SOURCES"
env | grep '^DBUS_SESSION_BUS_ADDRESS=' > "$IME_WORK/bus.env"
gnome-shell --headless --virtual-monitor 1400x926 --wayland-display ycode-ime --no-x11 > "$IME_WORK/shell.log" 2>&1 &
echo $! > "$IME_WORK/shell.pid"
wait
EOF
chmod +x "$work/session.sh"
env -u WAYLAND_DISPLAY -u DISPLAY XDG_CONFIG_HOME="$work/config" XDG_DATA_HOME="$work/data" \
    XDG_CACHE_HOME="$work/cache" XDG_STATE_HOME="$work/state" XDG_RUNTIME_DIR="$work/run" \
    XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=GNOME IME_SOURCES="$sources" IME_WORK="$work" \
    dbus-run-session -- "$work/session.sh" > "$work/session.log" 2>&1 &
for _ in $(seq 100); do [ -S "$work/run/ycode-ime" ] && [ -s "$work/bus.env" ] && break; sleep 0.2; done
sleep 4
shell=$(cat "$work/shell.pid")
trap 'kill "$shell" 2>/dev/null || true' EXIT

set -a
. "$work/bus.env"
set +a
export XDG_CONFIG_HOME="$work/config" XDG_DATA_HOME="$work/data" XDG_CACHE_HOME="$work/cache" \
    XDG_STATE_HOME="$work/state" XDG_RUNTIME_DIR="$work/run" WAYLAND_DISPLAY=ycode-ime
# The shell starts in its overview, which would take the keys.
gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell \
    --method org.freedesktop.DBus.Properties.Set org.gnome.Shell OverviewActive "<false>" > /dev/null
echo "input method engine: $(ibus engine 2>&1)"

log="$work/ide.log"
sed -e "s|LOG|$log|; s|SHOTS|$shots|" "$steps" > "$work/steps.txt"
OV_SHOT_REQUEST="$work/shot-request" YCODE_IDE_IME=1 OV_QUIT_AFTER="${QUIT_AFTER:-20}" \
    "$ide" "$package" > "$log" 2>&1 &
idepid=$!
OV_SHOT_REQUEST="$work/shot-request" python3 -I "$here/type-keys.py" "$work/steps.txt"
wait "$idepid" || true
grep '^ime' "$log"

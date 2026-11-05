#!/bin/bash
# Tests text input through a real input method (IBus) in the Linux IDE on
# Wayland, without touching the desktop you are logged in to: a headless GNOME
# Shell with its own D-Bus, dconf, IBus and runtime folders, under <work>.
# The input sources are written into that private dconf database before the
# shell starts (no settings call goes over any bus). Keys go in through that
# shell's remote-desktop interface (type-keys.py), so they pass through IBus as
# typed keys do. ycode-ide reports the composition and the caret rectangle it
# gives the input method (YCODE_IDE_IME, ShellDriverInputMethod.swift); the
# text-input-v3 cursor rectangles it sent are listed at the end (GNOME Shell
# 50 lets no test client take a screenshot, so the candidate window's place is
# known from them: the shell opens it below that rectangle).
#
# Usage: run.sh <work-dir> <ycode-ide> <package> <sources> <steps> [shot-dir]
#   sources  GNOME input sources, e.g. "[('ibus', 'table:cangjie5')]" or
#            "[('xkb', 'us+intl')]" (the engine needs to be installed)
#   steps    a type-keys.py steps file; LOG and SHOTS in it are replaced by
#            the IDE's log and the shot folder
# Environment: OV_SDL3_LIBRARY as for any run; QUIT_AFTER (default 25 s).
# Needs gnome-shell, ibus, dconf and PyGObject; no root. Wayland only: a
# headless shell with Xwayland does not finish starting without a session
# manager. X11, and Fcitx 5: run-isolated.sh.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
work=$(mkdir -p "$1" && cd "$1" && pwd)
ide=$2 package=$3 sources=$4 steps=$5
shots=${6:-$work/shots}
# Fresh folders each run (the IDE's crash recovery would bring back the last
# run's unsaved text).
rm -rf "$work/config" "$work/data" "$work/cache" "$work/state" "$work/run" "$work/package" "$work/dconf-keys"
mkdir -p "$work/config/dconf" "$work/data" "$work/cache" "$work/state" "$work/run" "$work/dconf-keys" "$shots"
chmod 700 "$work/run"
cp -a "$package" "$work/package"
cat > "$work/dconf-keys/00-test" <<KEYS
[org/gnome/desktop/input-sources]
sources=$sources
KEYS
dconf compile "$work/config/dconf/user" "$work/dconf-keys"

cat > "$work/session.sh" <<'SESSION'
#!/bin/bash
env | grep '^DBUS_SESSION_BUS_ADDRESS=' > "$IME_WORK/bus.env"
gnome-shell --headless --virtual-monitor 1400x926 --wayland-display ycode-ime --no-x11 > "$IME_WORK/shell.log" 2>&1 &
echo $! > "$IME_WORK/shell.pid"
wait
SESSION
chmod +x "$work/session.sh"
env -u WAYLAND_DISPLAY -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS -u IBUS_ADDRESS \
    XDG_CONFIG_HOME="$work/config" XDG_DATA_HOME="$work/data" \
    XDG_CACHE_HOME="$work/cache" XDG_STATE_HOME="$work/state" XDG_RUNTIME_DIR="$work/run" HOME="$work" \
    XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=GNOME IME_WORK="$work" NO_AT_BRIDGE=1 GTK_A11Y=none \
    dbus-run-session -- "$work/session.sh" > "$work/session.log" 2>&1 &
session=$!
for _ in $(seq 100); do [ -S "$work/run/ycode-ime" ] && [ -s "$work/bus.env" ] && break; sleep 0.2; done
sleep 4
shell=$(cat "$work/shell.pid")
cleanup() {
    kill "$shell" 2>/dev/null || true
    wait "$session" 2>/dev/null || true
    # Helpers the shell or its bus started (IBus, portals): exactly the
    # processes that run with this test's private runtime folder.
    for e in /proc/[0-9]*/environ; do
        p=${e#/proc/}; p=${p%/environ}
        if [ "$p" = $$ ] || [ ! -r "$e" ]; then continue; fi
        if { tr '\0' '\n' < "$e"; } 2>/dev/null | grep -qxF "XDG_RUNTIME_DIR=$work/run"; then
            echo "stopping leftover $p: $({ tr '\0' ' ' < "/proc/$p/cmdline"; } 2>/dev/null | cut -c1-80)"
            kill "$p" 2>/dev/null || true
        fi
    done
}
trap cleanup EXIT

set -a
. "$work/bus.env"
set +a
unset DISPLAY IBUS_ADDRESS
export XDG_CONFIG_HOME="$work/config" XDG_DATA_HOME="$work/data" XDG_CACHE_HOME="$work/cache" \
    XDG_STATE_HOME="$work/state" XDG_RUNTIME_DIR="$work/run" HOME="$work" WAYLAND_DISPLAY=ycode-ime
# The shell starts in its overview, which would take the keys.
gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell \
    --method org.freedesktop.DBus.Properties.Set org.gnome.Shell OverviewActive "<false>" > /dev/null

log="$work/ide.log"
sed -e "s|LOG|$log|; s|SHOTS|$shots|" "$steps" > "$work/steps.txt"
WAYLAND_DEBUG=client OV_PLATFORM=sdl SDL_VIDEO_DRIVER=wayland OV_SHOT_REQUEST="$work/shot-request" YCODE_IDE_IME=1 \
    OV_QUIT_AFTER="${QUIT_AFTER:-25}" "$ide" "$work/package" > "$log" 2>&1 &
idepid=$!
IME_KEYS=gnome OV_SHOT_REQUEST="$work/shot-request" python3 -I "$here/type-keys.py" "$work/steps.txt"
wait "$idepid" || true
grep '^ime' "$log"
echo "--- the IDE's caret rectangles (text-input-v3), window coordinates:"
grep -o 'set_cursor_rectangle([^)]*)' "$log" | uniq

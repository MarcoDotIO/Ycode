#!/bin/bash
# Tests text input through a real input method in the Linux IDE (issue 23) on a
# test display and session bus of its own, never on the desktop you are logged
# in to: an Xvfb X server or a headless sway, a private D-Bus, private XDG
# folders under <work>, and IBus or Fcitx 5 started for this run only. Keys go
# in as a keyboard's would (xdotool's XTEST on X11, wtype's virtual keyboard on
# sway), so they pass through the input method. ycode-ide reports the
# composition and the caret rectangle it gives the input method (YCODE_IDE_IME,
# ShellDriverInputMethod.swift).
#
# Usage: run-isolated.sh <x11|sway> <ibus|fcitx5> <engine> <layout> <work> <ycode-ide> <package> <steps> [shot-dir]
#   engine  IBus: an engine (table:cangjie5, xkb:us:intl:eng);
#           Fcitx 5: an input method (pinyin, keyboard-us-intl)
#   layout  the XKB layout, "us" or "us intl" (X11; sway takes wtype's keymap)
#   steps   a type-keys.py steps file; LOG and SHOTS in it are replaced by the
#           IDE's log and the shot folder
# Environment: OV_SDL3_LIBRARY as for any run; QUIT_AFTER (default 25 s);
# FCITX_XIM_ON_THE_SPOT=1 (X11 with Fcitx 5: composition drawn by the window);
# FCITX_VERBOSE (Fcitx 5's --verbose, e.g. "*=5").
# Needs Xvfb, xdotool, setxkbmap and PIL (X11), or sway and wtype (sway).
# IBus has no input-method-v2 client for sway; IBus on Wayland is tested in a
# test GNOME Shell (run.sh). On X11 the whole display is also saved
# (<shot>-screen.png) with the windows' geometry, for the candidate window.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
display_kind=$1 im=$2 engine=$3 layout=$4
work=$(mkdir -p "$5" && cd "$5" && pwd)
ide=$6 package=$7 steps=$8
shots=${9:-$work/shots}
case "$display_kind/$im" in
    x11/ibus|x11/fcitx5|sway/fcitx5) ;;
    *) echo "unsupported: $display_kind with $im" >&2; exit 2 ;;
esac
# Fresh folders each run: the IDE's crash recovery would bring back the last
# run's unsaved text.
rm -rf "$work/config" "$work/data" "$work/cache" "$work/state" "$work/run" "$work/package"
mkdir -p "$work/config" "$work/data" "$work/cache" "$work/state" "$work/run" "$shots"
chmod 700 "$work/run"
cp -a "$package" "$work/package"

pids=()
cleanup() {
    for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
    sleep 0.5
    # Helpers the test's input method or bus started outside this process
    # tree (ibus-x11, bus-activated services): exactly the processes that
    # run with this test's private runtime folder.
    for e in /proc/[0-9]*/environ; do
        p=${e#/proc/}; p=${p%/environ}
        if [ "$p" = $$ ] || [ ! -r "$e" ]; then continue; fi
        if { tr '\0' '\n' < "$e"; } 2>/dev/null | grep -qxF "XDG_RUNTIME_DIR=$work/run"; then
            echo "stopping leftover $p: $({ tr '\0' ' ' < /proc/$p/cmdline; } 2>/dev/null | cut -c1-80)"
            kill "$p" 2>/dev/null || true
        fi
    done
}
trap cleanup EXIT

# Everything below sees only the private folders and bus.
unset DISPLAY WAYLAND_DISPLAY SWAYSOCK DBUS_SESSION_BUS_ADDRESS IBUS_ADDRESS
export XDG_CONFIG_HOME="$work/config" XDG_DATA_HOME="$work/data" XDG_CACHE_HOME="$work/cache" \
    XDG_STATE_HOME="$work/state" XDG_RUNTIME_DIR="$work/run" HOME="$work" \
    GSETTINGS_BACKEND=memory NO_AT_BRIDGE=1 GTK_A11Y=none GTK_USE_PORTAL=0 GIO_USE_VFS=local
dbus-daemon --session --fork --print-address=4 --print-pid=5 4> "$work/bus" 5> "$work/bus.pid"
pids+=("$(cat "$work/bus.pid")")
export DBUS_SESSION_BUS_ADDRESS
DBUS_SESSION_BUS_ADDRESS=$(head -1 "$work/bus")

if [ "$display_kind" = x11 ]; then
    rm -f "$work/display"
    Xvfb -displayfd 3 -screen 0 1600x1000x24 -nolisten tcp 3> "$work/display" > "$work/xvfb.log" 2>&1 &
    pids+=("$!")
    for _ in $(seq 50); do [ -s "$work/display" ] && break; sleep 0.1; done
    export DISPLAY=":$(cat "$work/display")"
    # shellcheck disable=SC2086 # "us intl" is a layout and a variant
    setxkbmap $layout
    keys=xdotool
    export IME_SCREEN_SHOT="python3 -I $here/screen-x11.py"
else
    cat > "$work/sway.conf" <<CONF
output HEADLESS-1 resolution 1600x1000 position 0 0
xwayland disable
default_border none
CONF
    WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 sway -c "$work/sway.conf" > "$work/sway.log" 2>&1 &
    pids+=("$!")
    for _ in $(seq 50); do [ -S "$work/run/wayland-1" ] && break; sleep 0.1; done
    export WAYLAND_DISPLAY=wayland-1
    # A keyboard that stays: without one the seat has none between two wtype
    # runs, the window loses keyboard focus and the input method each time.
    wtype -s 3600000 &
    pids+=("$!")
    keys=wtype
fi

case "$im" in
    ibus)
        ibus-daemon --xim --replace --verbose > "$work/im.log" 2>&1 &
        pids+=("$!")
        for _ in $(seq 100); do ibus address > /dev/null 2>&1 && break; sleep 0.1; done
        # The daemon lists the engines it found a moment after it starts.
        for _ in $(seq 30); do
            ibus engine "$engine" 2> /dev/null && [ "$(ibus engine 2> /dev/null)" = "$engine" ] && break
            sleep 0.5
        done
        echo "input method engine: $(ibus engine)"
        export XMODIFIERS=@im=ibus GTK_IM_MODULE=ibus QT_IM_MODULE=ibus SDL_IM_MODULE=ibus
        ;;
    fcitx5)
        mkdir -p "$work/config/fcitx5"
        # The engine first: Fcitx 5 uses a group's first input method from
        # the start, without the trigger key. Traditional-Chinese conversion
        # (Ctrl+Shift+F) is off so that Find in Workspace's shortcut reaches
        # the IDE.
        # The group's layout is the one Fcitx 5 gives the X server: the test's
        # ("us intl" → us-intl), or keys a test maps (xdotool) read wrong.
        cat > "$work/config/fcitx5/profile" <<CONF
[Groups/0]
Name=Test
Default Layout=${layout// /-}
DefaultIM=$engine

[Groups/0/Items/0]
Name=$engine
Layout=

[GroupOrder]
0=Test
CONF
        cat > "$work/config/fcitx5/config" <<CONF
[Behavior/DisabledAddons]
0=chttrans
1=ibusfrontend
2=fcitx4frontend
3=notificationitem
4=kimpanel
5=clipboard
6=cloudpinyin
CONF
        # Fcitx 5's XIM shows the text being composed in its own window by
        # default; FCITX_XIM_ON_THE_SPOT=1 hands it to the window instead.
        mkdir -p "$work/config/fcitx5/conf"
        if [ "${FCITX_XIM_ON_THE_SPOT:-0}" = 1 ]; then
            printf 'UseOnTheSpot=True\n' > "$work/config/fcitx5/conf/xim.conf"
        fi
        if [ "$display_kind" = sway ]; then
            WAYLAND_DEBUG=client fcitx5 --replace ${FCITX_VERBOSE:+--verbose="$FCITX_VERBOSE"} > "$work/im.log" 2>&1 &
        else
            fcitx5 --replace ${FCITX_VERBOSE:+--verbose="$FCITX_VERBOSE"} > "$work/im.log" 2>&1 &
        fi
        pids+=("$!")
        sleep 3
        export XMODIFIERS=@im=fcitx GTK_IM_MODULE=fcitx QT_IM_MODULE=fcitx SDL_IM_MODULE=fcitx
        ;;
esac

log="$work/ide.log"
sed -e "s|LOG|$log|; s|SHOTS|$shots|" "$steps" > "$work/steps.txt"
if [ "$display_kind" = sway ]; then
    WAYLAND_DEBUG=client OV_PLATFORM=sdl SDL_VIDEO_DRIVER=wayland OV_SHOT_REQUEST="$work/shot-request" YCODE_IDE_IME=1 \
        OV_QUIT_AFTER="${QUIT_AFTER:-25}" "$ide" "$work/package" > "$log" 2>&1 &
else
    OV_PLATFORM=sdl SDL_VIDEO_DRIVER=x11 OV_SHOT_REQUEST="$work/shot-request" YCODE_IDE_IME=1 \
        OV_QUIT_AFTER="${QUIT_AFTER:-25}" "$ide" "$work/package" > "$log" 2>&1 &
fi
idepid=$!
pids+=("$idepid")
if [ "$display_kind" = x11 ]; then
    # No window manager: give the IDE's window the keyboard.
    for _ in $(seq 100); do grep -q '^ime: ready' "$log" 2>/dev/null && break; sleep 0.1; done
    for w in $(xdotool search --pid "$idepid" --name Ycode 2>/dev/null); do xdotool windowfocus "$w" 2>/dev/null || true; done
fi
IME_KEYS=$keys OV_SHOT_REQUEST="$work/shot-request" python3 -I "$here/type-keys.py" "$work/steps.txt"
wait "$idepid" || true
grep '^ime' "$log"
if [ "$display_kind" = sway ]; then
    echo "--- the IDE's caret rectangles (text-input-v3), window coordinates:"
    grep -o 'set_cursor_rectangle([^)]*)' "$log" | uniq
    echo "--- what the compositor told the input method (input-method-v2), surface coordinates:"
    grep -o 'text_input_rectangle([^)]*)' "$work/im.log" | uniq || true
fi

#!/usr/bin/env python3
"""Types keys into a test session so that they pass through the input method
as typed keys do.

Usage: type-keys.py <steps-file>
Back ends (IME_KEYS):
  gnome    (default) a test GNOME Shell's remote-desktop interface, on that
           shell's own bus (run.sh)
  xdotool  XTEST on $DISPLAY, a test X server (run-isolated.sh x11)
  wtype    the virtual-keyboard protocol on $WAYLAND_DISPLAY, a test sway
           (run-isolated.sh sway)
Steps, one per line:
  key <keysym-hex>[+<keysym-hex>...]   a chord, pressed in order, released in reverse
  text <ascii>                          one key per character (keysym = the character)
  wait <seconds>
  shot <path>                           a screenshot request, written to $OV_SHOT_REQUEST;
                                        with $IME_SCREEN_SHOT (a command) set, it also
                                        runs with the path's "-screen" twin: the whole
                                        test display, with the input method's windows
  until <regex> <file>                  wait for a line in a log
"""
import os
import re
import shlex
import subprocess
import sys
import time

# Modifier keysyms → wtype's modifier names.
WTYPE_MODIFIERS = {0xffe1: "shift", 0xffe2: "shift", 0xffe3: "ctrl", 0xffe4: "ctrl",
                   0xffe9: "alt", 0xffea: "alt", 0xffeb: "logo", 0xffec: "logo"}


def gnome_typist():
    import gi

    gi.require_version("Gio", "2.0")
    from gi.repository import Gio, GLib

    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    iface = "org.gnome.Mutter.RemoteDesktop.Session"

    def call(path, interface, method, args=None, reply=None):
        return bus.call_sync("org.gnome.Mutter.RemoteDesktop", path, interface, method, args,
                             GLib.VariantType(reply) if reply else None, Gio.DBusCallFlags.NONE, -1, None)

    session = call("/org/gnome/Mutter/RemoteDesktop", "org.gnome.Mutter.RemoteDesktop",
                   "CreateSession", None, "(o)").unpack()[0]
    call(session, iface, "Start")

    def chord(syms):
        for s in syms:
            call(session, iface, "NotifyKeyboardKeysym", GLib.Variant("(ub)", (s, True)))
            time.sleep(0.03)
        for s in reversed(syms):
            call(session, iface, "NotifyKeyboardKeysym", GLib.Variant("(ub)", (s, False)))
            time.sleep(0.03)

    def stop():
        call(session, iface, "Stop")

    return chord, stop


def xdotool_chord(syms):
    subprocess.run(["xdotool", "key", "--delay", "30", "+".join(hex(s) for s in syms)], check=True)


def wtype_chord(syms):
    mods = [WTYPE_MODIFIERS[s] for s in syms if s in WTYPE_MODIFIERS]
    keys = [s for s in syms if s not in WTYPE_MODIFIERS]
    args = ["wtype"]
    for m in mods:
        args += ["-M", m]
    for k in keys:
        args += ["-k", hex(k)]
    for m in reversed(mods):
        args += ["-m", m]
    subprocess.run(args, check=True)


def main():
    backend = os.environ.get("IME_KEYS", "gnome")
    stop = None
    if backend == "gnome":
        press, stop = gnome_typist()
    elif backend == "xdotool":
        press = xdotool_chord
    elif backend == "wtype":
        press = wtype_chord
    else:
        print("unknown IME_KEYS", backend)
        return 2

    def chord(syms):
        press(syms)
        time.sleep(0.15)

    with open(sys.argv[1]) as steps:
        for raw in steps:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            op, _, arg = line.partition(" ")
            if op == "key":
                chord([int(k, 16) for k in arg.split("+")])
            elif op == "text":
                for ch in arg:
                    chord([ord(ch)])
            elif op == "wait":
                time.sleep(float(arg))
            elif op == "shot":
                with open(os.environ["OV_SHOT_REQUEST"], "w") as request:
                    request.write(arg)
                time.sleep(0.6)
                screen = os.environ.get("IME_SCREEN_SHOT")
                if screen:
                    root, ext = os.path.splitext(arg)
                    subprocess.run(shlex.split(screen) + [root + "-screen" + ext], check=False)
            elif op == "until":
                pattern, path = arg.rsplit(" ", 1)
                for _ in range(300):
                    if os.path.exists(path) and re.search(pattern, open(path, errors="replace").read()):
                        break
                    time.sleep(0.1)
                else:
                    print("timed out waiting for", pattern)
                    return 1
            print("did", line, flush=True)
    if stop:
        stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())

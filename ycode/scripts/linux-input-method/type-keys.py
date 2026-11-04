#!/usr/bin/env python3
"""Types through a test GNOME Shell's remote-desktop interface (on that shell's own
bus), so the keys pass through the input method as typed keys do.

Usage: type-keys.py <steps-file>   (run.sh runs it inside the test session)
Steps, one per line:
  key <keysym-hex>[+<keysym-hex>...]   a chord, pressed in order, released in reverse
  text <ascii>                          one key per character (keysym = the character)
  wait <seconds>
  shot <path>                           a screenshot request, written to $OV_SHOT_REQUEST
  until <regex> <file>                  wait for a line in a log
"""
import os
import re
import sys
import time

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

BUS = Gio.bus_get_sync(Gio.BusType.SESSION, None)
SESSION_IFACE = "org.gnome.Mutter.RemoteDesktop.Session"


def call(path, iface, method, args=None, reply=None):
    return BUS.call_sync("org.gnome.Mutter.RemoteDesktop", path, iface, method, args,
                         GLib.VariantType(reply) if reply else None, Gio.DBusCallFlags.NONE, -1, None)


def main():
    session = call("/org/gnome/Mutter/RemoteDesktop", "org.gnome.Mutter.RemoteDesktop",
                   "CreateSession", None, "(o)").unpack()[0]
    call(session, SESSION_IFACE, "Start")

    def key(sym, down):
        call(session, SESSION_IFACE, "NotifyKeyboardKeysym", GLib.Variant("(ub)", (sym, down)))

    def chord(syms):
        for s in syms:
            key(s, True)
            time.sleep(0.03)
        for s in reversed(syms):
            key(s, False)
            time.sleep(0.03)
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
    call(session, SESSION_IFACE, "Stop")
    return 0


if __name__ == "__main__":
    sys.exit(main())

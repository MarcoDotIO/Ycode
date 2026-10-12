#!/usr/bin/env python3
# make_tbd.py - writes a text-based stub (.tbd, version 4) for one built host
# library, so that the next library can link against it.
#
# Clean-room Ycode code. The Swift toolchain's ld64.lld refuses Mach-O
# *inputs* (objects or dylibs) that carry a Darwin platform load command,
# but it accepts .tbd stubs. Linking against the stub records the same
# LC_LOAD_DYLIB (the install name) and two-level binds as linking against
# the dylib itself.
#
# Usage: python3 -I make_tbd.py --lib NAME --dylib PATH --nm PATH --out PATH

import argparse
import subprocess
import sys


def main():
    ap = argparse.ArgumentParser()
    for a in ("--lib", "--dylib", "--nm", "--out"):
        ap.add_argument(a, required=True)
    args = ap.parse_args()
    p = subprocess.run([args.nm, "-gU", "-j", args.dylib], stdout=subprocess.PIPE, universal_newlines=True)
    if p.returncode != 0:
        sys.exit("make_tbd.py: llvm-nm failed")
    names = sorted(set(l.strip() for l in p.stdout.splitlines() if l.strip()))
    if not names:
        sys.exit("make_tbd.py: %s exports nothing" % args.dylib)
    lines = [
        "--- !tapi-tbd",
        "tbd-version:     4",
        "targets:         [ arm64-ios-simulator ]",
        'install-name:    "/usr/lib/system/libsystem_%s.dylib"' % args.lib,
        "current-version: 1",
        "compatibility-version: 1",
        "exports:",
        "  - targets:     [ arm64-ios-simulator ]",
        "    symbols:",
    ]
    for n in names:
        lines.append('      - "%s"' % n.replace("\\", "\\\\").replace('"', '\\"'))
    lines.append("...")
    with open(args.out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()

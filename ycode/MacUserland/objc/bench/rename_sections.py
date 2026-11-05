#!/usr/bin/env python3
# rename_sections.py - renames every `__objc_*` section of a Mach-O image
# to `__ycob_*` (same length), in place, so that the Mac's own Objective-C
# runtime ignores the image and Ycode's runtime (built with the host-bench
# feature) loads it instead (specs/macos/objc-runtime.md §12). Only the
# section names in the load commands change; re-sign afterwards.
#
# The benchmark's category controls use another prefix (--to __none_) that
# neither runtime reads.
#
# Usage: python3 -I rename_sections.py [--to PREFIX] IMAGE...

import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19


def rename(path, to=b"__ycob_"):
    with open(path, "rb") as f:
        data = bytearray(f.read())
    magic, _cpu, _sub, _ftype, ncmds, _size, _flags, _res = struct.unpack_from("<IiiIIIII", data, 0)
    if magic != MH_MAGIC_64:
        sys.exit(f"{path}: not a 64-bit Mach-O image")
    off = 32
    count = 0
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from("<I", data, off + 64)[0]
            s = off + 72
            for _ in range(nsects):
                if data[s:s + 7] == b"__objc_":
                    data[s:s + 7] = to
                    count += 1
                s += 80
        off += cmdsize
    with open(path, "wb") as f:
        f.write(data)
    print(f"{path}: {count} sections renamed")


args = sys.argv[1:]
prefix = b"__ycob_"
if args[:1] == ["--to"]:
    prefix = args[1].encode()
    args = args[2:]
    if len(prefix) != 7:
        sys.exit("the prefix must have 7 characters")
for p in args:
    rename(p, prefix)

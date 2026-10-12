#!/usr/bin/env python3
# strip_platform.py - removes the platform load commands from Mach-O object
# files, in place.
#
# Clean-room Ycode code. Why: the Swift 6.4 toolchain's ld64.lld rejects
# every input that carries a Darwin platform tag ("This version of lld does
# not support linking for platform ..."), yet the objects must be compiled
# with a real Darwin triple (arm64-apple-ios27.0-simulator) so that clang
# uses Apple's arm64 calling convention (variadic arguments on the stack,
# stack arguments packed at natural size). The platform-less triple
# arm64-apple-none-macho uses generic AAPCS64 and is NOT ABI-compatible.
#
# The tag (LC_BUILD_VERSION, or an older LC_VERSION_MIN_*) is only
# metadata in an object file; code generation has already happened. The
# command is cut out of the load-command area, the later commands move up,
# ncmds/sizeofcmds shrink, and the freed bytes become zero padding. Section
# and symbol-table file offsets point past the load commands, so they stay
# valid. The linker writes the dylib's own LC_BUILD_VERSION from
# -platform_version.
#
# Usage: python3 -I strip_platform.py OBJECT...

import struct
import sys

PLATFORM_CMDS = {0x32, 0x24, 0x25, 0x2F, 0x30}  # BUILD_VERSION, VERSION_MIN_{MACOSX,IPHONEOS,TVOS,WATCHOS}


def strip(path):
    with open(path, "rb") as f:
        data = bytearray(f.read())
    magic, cputype, cpusub, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from("<IiiIIIII", data, 0)
    if magic != 0xFEEDFACF or filetype != 1:
        sys.exit("strip_platform.py: %s is not a 64-bit Mach-O object" % path)
    off, kept, removed = 32, [], 0
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if size < 8 or off + size > 32 + sizeofcmds:
            sys.exit("strip_platform.py: %s: malformed load commands" % path)
        if cmd in PLATFORM_CMDS:
            removed += 1
        else:
            kept.append(bytes(data[off:off + size]))
        off += size
    if removed == 0:
        return
    blob = b"".join(kept)
    data[32:32 + sizeofcmds] = blob + bytes(sizeofcmds - len(blob))
    struct.pack_into("<IiiIIIII", data, 0, magic, cputype, cpusub, filetype, len(kept), len(blob), flags, reserved)
    with open(path, "wb") as f:
        f.write(data)


for p in sys.argv[1:]:
    strip(p)

#!/usr/bin/env python3
# macho_tool.py - small Mach-O helpers for MacUserland/build.sh
# (specs/macos/libsystem.md §9, dyld.md §10). Clean-room Ycode code from
# the public <mach-o/loader.h> and <mach-o/fixup-chains.h> facts.
#
#   retag FILE PLATFORM MINOS SDK   rewrite the one LC_BUILD_VERSION of an
#                                   unsigned thin image (versions "14.0")
#   no-fixups FILE                  fail unless the image has no chained
#                                   fixups and no classic rebase/bind data
#   tbd OUT INSTALL_NAME SYMS...    write a tbd-v4 link stub for arm64-macos
#                                   whose exports are the symbol files' lines

import struct
import sys

MAGIC_64 = 0xFEEDFACF
LC_BUILD_VERSION = 0x32
LC_CODE_SIGNATURE = 0x1D
LC_DYLD_INFO = 0x22
LC_DYLD_INFO_ONLY = 0x80000022
LC_DYLD_CHAINED_FIXUPS = 0x80000034


def commands(data):
    magic, _, _, _, ncmds, sizeofcmds = struct.unpack_from("<6I", data, 0)
    if magic != MAGIC_64:
        raise SystemExit("not a thin 64-bit little-endian Mach-O image")
    at = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<2I", data, at)
        if size < 8 or at + size > 32 + sizeofcmds:
            raise SystemExit("malformed load commands")
        yield cmd, at, size
        at += size


def packed(version):
    parts = [int(p) for p in version.split(".")] + [0, 0]
    return parts[0] << 16 | parts[1] << 8 | parts[2]


def retag(path, platform, minos, sdk):
    data = bytearray(open(path, "rb").read())
    found = []
    for cmd, at, _ in commands(data):
        if cmd == LC_CODE_SIGNATURE:
            raise SystemExit(f"{path}: signed; a retag would break the signature")
        if cmd == LC_BUILD_VERSION:
            found.append(at)
    if len(found) != 1:
        raise SystemExit(f"{path}: expected one LC_BUILD_VERSION, found {len(found)}")
    struct.pack_into("<3I", data, found[0] + 8, int(platform), packed(minos), packed(sdk))
    open(path, "wb").write(data)


def no_fixups(path):
    data = open(path, "rb").read()
    for cmd, at, _ in commands(data):
        if cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
            rebase_size, bind_size = struct.unpack_from("<I", data, at + 12)[0], struct.unpack_from("<I", data, at + 20)[0]
            if rebase_size or bind_size:
                raise SystemExit(f"{path}: has classic rebase or bind data")
        if cmd == LC_DYLD_CHAINED_FIXUPS:
            off, size = struct.unpack_from("<2I", data, at + 8)
            blob = data[off:off + size]
            starts, imports_count = struct.unpack_from("<I", blob, 4)[0], struct.unpack_from("<I", blob, 16)[0]
            nsegs = struct.unpack_from("<I", blob, starts)[0]
            offsets = struct.unpack_from(f"<{nsegs}I", blob, starts + 4)
            if imports_count or any(offsets):
                raise SystemExit(f"{path}: has chained fixups (imports {imports_count}, segment starts {list(offsets)})")
    print(f"{path}: no fixups")


def tbd(out, install_name, symbol_files):
    names = set()
    for f in symbol_files:
        for line in open(f):
            line = line.strip()
            if line and not line.startswith("#"):
                names.add(line)
    lines = [
        "--- !tapi-tbd",
        "tbd-version:     4",
        "targets:         [ arm64-macos ]",
        f'install-name:    "{install_name}"',
        "current-version: 1",
        "compatibility-version: 1",
        "exports:",
        "  - targets:     [ arm64-macos ]",
        "    symbols:",
    ]
    lines += [f'      - "{n}"' for n in sorted(names)]
    lines.append("...")
    open(out, "w").write("\n".join(lines) + "\n")


def main(argv):
    if len(argv) >= 6 and argv[1] == "retag":
        retag(argv[2], argv[3], argv[4], argv[5])
    elif len(argv) == 3 and argv[1] == "no-fixups":
        no_fixups(argv[2])
    elif len(argv) >= 4 and argv[1] == "tbd":
        tbd(argv[2], argv[3], argv[4:])
    else:
        raise SystemExit(__doc__ or "usage: macho_tool.py retag|no-fixups|tbd ...")


if __name__ == "__main__":
    main(sys.argv)

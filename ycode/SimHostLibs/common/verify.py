#!/usr/bin/env python3
# verify.py - self-check of one Ycode host library (host-libraries.md
# sections 2-4). Fails (exit 1) on any mismatch.
#
# Clean-room Ycode code. Three independent views of the output are checked:
#   1. Ycode's own Mach-O reader:     ycode macho <dylib>
#   2. this script's header parser:   load commands, segments, flags
#   3. LLVM's tools:                  llvm-nm (exports, kinds, data spans)
#                                     llvm-objdump --macho --private-headers
#
# Usage: python3 -I verify.py --lib NAME --dylib PATH --data-dir DIR
#            --common DIR --ycode PATH --nm PATH --objdump PATH

import argparse
import json
import os
import re
import struct
import subprocess
import sys

INSTALL = "/usr/lib/system/libsystem_%s.dylib"
ALLOWED_DEPS = {
    "kernel": set(),
    "platform": {INSTALL % "kernel"},
    "pthread": {INSTALL % "kernel", INSTALL % "platform"},
}
ALLOWED_WEAK_DEPS = {"pthread": {"/usr/lib/system/libdyld.dylib"}}
PAGE = 0x4000

LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
LC_DYSYMTAB = 0xB
LC_LOAD_DYLIB = 0xC
LC_ID_DYLIB = 0xD
LC_UUID = 0x1B
LC_CODE_SIGNATURE = 0x1D
LC_DYLD_INFO = 0x22
LC_DYLD_INFO_ONLY = 0x80000022
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_LOAD_UPWARD_DYLIB = 0x80000023
LC_BUILD_VERSION = 0x32
LC_DYLD_EXPORTS_TRIE = 0x80000033
LC_DYLD_CHAINED_FIXUPS = 0x80000034
LC_FUNCTION_STARTS = 0x26
LC_DATA_IN_CODE = 0x29
KNOWN_LC = {LC_SEGMENT_64, LC_SYMTAB, LC_DYSYMTAB, LC_LOAD_DYLIB, LC_ID_DYLIB, LC_UUID,
            LC_DYLD_INFO, LC_DYLD_INFO_ONLY, LC_LOAD_WEAK_DYLIB, LC_BUILD_VERSION,
            LC_DYLD_EXPORTS_TRIE, LC_DYLD_CHAINED_FIXUPS, LC_FUNCTION_STARTS, LC_DATA_IN_CODE}

MH_DYLDLINK = 0x4
MH_TWOLEVEL = 0x80
MH_WEAK_DEFINES = 0x8000
MH_HAS_TLV_DESCRIPTORS = 0x800000
MH_DYLIB_IN_CACHE = 0x80000000
SG_READ_ONLY = 0x10

errors = []


def fail(msg):
    errors.append(msg)


def version(v):
    return "%d.%d.%d" % (v >> 16, (v >> 8) & 0xFF, v & 0xFF)


def cstr(data, off):
    end = data.index(b"\0", off)
    return data[off:end].decode("utf-8")


def parse_macho(path):
    with open(path, "rb") as f:
        data = f.read()
    magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, _ = struct.unpack_from("<IiiIIIII", data, 0)
    info = {"size": len(data), "segments": [], "sections": [], "dylibs": [], "lcs": []}
    if magic != 0xFEEDFACF:
        fail("not a 64-bit little-endian Mach-O (magic %#x)" % magic)
        return info
    if cputype != 0x0100000C:
        fail("cputype %#x is not arm64" % cputype)
    if cpusubtype != 0:
        fail("cpusubtype %#x is not CPU_SUBTYPE_ARM64_ALL (0, no capability bits)" % (cpusubtype & 0xFFFFFFFF))
    if filetype != 6:
        fail("filetype %d is not MH_DYLIB (6)" % filetype)
    for bit, name in ((MH_DYLDLINK, "MH_DYLDLINK"), (MH_TWOLEVEL, "MH_TWOLEVEL")):
        if not flags & bit:
            fail("header flag %s missing (flags %#x)" % (name, flags))
    for bit, name in ((MH_WEAK_DEFINES, "MH_WEAK_DEFINES"), (MH_HAS_TLV_DESCRIPTORS, "MH_HAS_TLV_DESCRIPTORS"),
                      (MH_DYLIB_IN_CACHE, "MH_DYLIB_IN_CACHE")):
        if flags & bit:
            fail("header flag %s must not be set (flags %#x)" % (name, flags))
    info["flags"] = flags
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        info["lcs"].append(cmd)
        if cmd not in KNOWN_LC:
            fail("unexpected load command %#x" % cmd)
        if cmd == LC_SEGMENT_64:
            name = data[off + 8:off + 24].rstrip(b"\0").decode()
            vmaddr, vmsize, fileoff, filesize, maxprot, initprot, nsects, sflags = struct.unpack_from(
                "<QQQQiiII", data, off + 24)
            if size != 72 + 80 * nsects:
                fail("segment %s: cmdsize %d is wrong" % (name, size))
            seg = dict(name=name, vmaddr=vmaddr, vmsize=vmsize, fileoff=fileoff, filesize=filesize,
                       maxprot=maxprot, initprot=initprot, flags=sflags)
            info["segments"].append(seg)
            for i in range(nsects):
                s = off + 72 + 80 * i
                sect = data[s:s + 16].rstrip(b"\0").decode()
                segn = data[s + 16:s + 32].rstrip(b"\0").decode()
                addr, ssize = struct.unpack_from("<QQ", data, s + 32)
                info["sections"].append(dict(sect=sect, seg=segn, addr=addr, size=ssize))
                if addr < vmaddr or addr + ssize > vmaddr + vmsize:
                    fail("section %s,%s lies outside its segment" % (segn, sect))
        elif cmd == LC_ID_DYLIB:
            name_off, _, cur, compat = struct.unpack_from("<IIII", data, off + 8)
            info["id"] = (cstr(data, off + name_off), cur, compat)
        elif cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LOAD_UPWARD_DYLIB):
            name_off = struct.unpack_from("<I", data, off + 8)[0]
            info["dylibs"].append((cmd, cstr(data, off + name_off)))
        elif cmd == LC_UUID:
            if size != 24:
                fail("LC_UUID size %d" % size)
            info["uuid"] = data[off + 8:off + 24]
        elif cmd == LC_BUILD_VERSION:
            platform, minos, sdk, ntools = struct.unpack_from("<IIII", data, off + 8)
            if size != 24 + 8 * ntools:
                fail("LC_BUILD_VERSION cmdsize %d with %d tools" % (size, ntools))
            info.setdefault("build", []).append((platform, minos, sdk))
        elif cmd in (LC_DYLD_EXPORTS_TRIE, LC_DYLD_CHAINED_FIXUPS, LC_FUNCTION_STARTS, LC_DATA_IN_CODE):
            if size != 16:
                fail("load command %#x size %d" % (cmd, size))
        off += size
    if off > 32 + sizeofcmds:
        fail("load commands overrun sizeofcmds")
    info["cmds_end"] = 32 + sizeofcmds
    return info


def check_layout(lib, info):
    want = INSTALL % lib
    ident = info.get("id")
    if ident is None:
        fail("no LC_ID_DYLIB")
    else:
        if ident[0] != want:
            fail("install name %r is not %r" % (ident[0], want))
        if ident[1] != 0x10000 or ident[2] != 0x10000:
            fail("versions current %s compat %s, want 1.0.0 / 1.0.0" % (version(ident[1]), version(ident[2])))
    if info["lcs"].count(LC_ID_DYLIB) != 1:
        fail("there must be exactly one LC_ID_DYLIB")
    if "uuid" not in info:
        fail("no LC_UUID")
    elif info["uuid"] == bytes(16):
        fail("LC_UUID is all zero")
    builds = info.get("build", [])
    if len(builds) != 1:
        fail("want exactly one LC_BUILD_VERSION, found %d" % len(builds))
    elif builds[0] != (7, 0x1B0000, 0x1B0100):
        p, m, s = builds[0]
        fail("LC_BUILD_VERSION platform %d minos %s sdk %s; want 7, 27.0.0, 27.1.0" % (p, version(m), version(s)))
    if LC_CODE_SIGNATURE in info["lcs"]:
        fail("LC_CODE_SIGNATURE present")
    if LC_DYLD_EXPORTS_TRIE not in info["lcs"] and not ({LC_DYLD_INFO, LC_DYLD_INFO_ONLY} & set(info["lcs"])):
        fail("no export trie (LC_DYLD_EXPORTS_TRIE or LC_DYLD_INFO)")
    for cmd, path in info["dylibs"]:
        if cmd == LC_LOAD_DYLIB and path in ALLOWED_DEPS[lib]:
            continue
        if cmd == LC_LOAD_WEAK_DYLIB and path in ALLOWED_WEAK_DEPS.get(lib, set()):
            continue
        fail("dependency %s (load command %#x) is not allowed for libsystem_%s" % (path, cmd, lib))
    paths = [p for _, p in info["dylibs"]]
    if len(paths) != len(set(paths)):
        fail("duplicate dependencies")

    segs = info["segments"]
    names = [s["name"] for s in segs]
    allowed_orders = (["__TEXT", "__LINKEDIT"], ["__TEXT", "__DATA", "__LINKEDIT"],
                      ["__TEXT", "__DATA_CONST", "__LINKEDIT"], ["__TEXT", "__DATA_CONST", "__DATA", "__LINKEDIT"])
    if names not in allowed_orders:
        fail("segment order %s is not __TEXT, [__DATA_CONST], [__DATA], __LINKEDIT" % names)
    prot = {"__TEXT": 5, "__DATA_CONST": 3, "__DATA": 3, "__LINKEDIT": 1}
    base = segs[0]["vmaddr"] if segs else 0
    prev_vm_end = prev_file_end = None
    for s in segs:
        n = s["name"]
        if n in prot and (s["initprot"] != prot[n] or s["maxprot"] != prot[n]):
            fail("segment %s protection %d/%d, want %d" % (n, s["initprot"], s["maxprot"], prot[n]))
        if (s["vmaddr"] - base) % PAGE or s["fileoff"] % PAGE:
            fail("segment %s vmaddr %#x / fileoff %#x not 16 KiB aligned" % (n, s["vmaddr"], s["fileoff"]))
        if n != "__LINKEDIT" and s["filesize"] % PAGE:
            fail("segment %s filesize %#x is not a multiple of 16 KiB" % (n, s["filesize"]))
        if s["filesize"] > s["vmsize"]:
            fail("segment %s filesize exceeds vmsize" % n)
        if s["fileoff"] + s["filesize"] > info["size"]:
            fail("segment %s extends beyond the end of the file" % n)
        if prev_vm_end is not None and (s["vmaddr"] < prev_vm_end or s["fileoff"] < prev_file_end):
            fail("segment %s overlaps or is out of order" % n)
        prev_vm_end = s["vmaddr"] + s["vmsize"]
        prev_file_end = s["fileoff"] + s["filesize"]
    if segs:
        text = segs[0]
        if text["name"] != "__TEXT" or text["fileoff"] != 0:
            fail("__TEXT must be first, at file offset 0")
        elif text["filesize"] < info["cmds_end"]:
            fail("load commands do not fit in __TEXT")
    for s in segs:
        if s["name"] == "__DATA_CONST" and not s["flags"] & SG_READ_ONLY:
            fail("__DATA_CONST lacks SG_READ_ONLY")


def run(cmd):
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    if p.returncode != 0:
        fail("%s failed: %s" % (" ".join(cmd), p.stderr.strip()))
    return p.stdout


def check_ycode_macho(lib, ycode, dylib):
    out = run([ycode, "macho", dylib])
    lines = out.splitlines()
    if not lines or not lines[0].startswith("arm64 dylib"):
        fail("ycode macho: first line %r, want 'arm64 dylib'" % (lines[0] if lines else ""))
    m = re.search(r"^platform (.+?)  minos (\S+)  sdk (\S+)$", out, re.M)
    if not m or m.group(2) not in ("27.0", "27.0.0") or m.group(3) not in ("27.1", "27.1.0"):
        fail("ycode macho: no 'platform ... minos 27.0 sdk 27.1' line")
    elif m.group(1).replace(" ", "").lower() not in ("iossimulator", "7"):
        fail("ycode macho: platform %r is not the iOS simulator (7)" % m.group(1))
    if ("install name %s" % (INSTALL % lib)) not in lines:
        fail("ycode macho: install name line missing")
    if not re.search(r"^uuid [0-9A-F-]{36}$", out, re.M):
        fail("ycode macho: no uuid line")
    if not re.search(r"^code signature: no ", out, re.M):
        fail("ycode macho: code signature present")
    segs = re.findall(r"^segment (\S+)\s+vm (\S+) \+(\S+)", out, re.M)
    if [s[0] for s in segs][:1] != ["__TEXT"] or [s[0] for s in segs][-1:] != ["__LINKEDIT"]:
        fail("ycode macho: segments %s" % [s[0] for s in segs])
    for name, vm, _ in segs:
        if int(vm, 16) % PAGE:
            fail("ycode macho: segment %s at %s is not 16 KiB aligned" % (name, vm))
    want_prot = {"__TEXT": "r-x/r-x", "__DATA_CONST": "rw-/rw-", "__DATA": "rw-/rw-", "__LINKEDIT": "r--/r--"}
    for name, prot in re.findall(r"^segment (\S+)\s+vm \S+ \+\S+\s+(\S+)", out, re.M):
        if want_prot.get(name) != prot:
            fail("ycode macho: segment %s protection %s" % (name, prot))
    return out


def check_objdump(objdump, dylib):
    out = run([objdump, "--macho", "--private-headers", dylib])
    m = re.search(r"MH_MAGIC_64\s+(\S+)\s+(\S+)\s+\S+\s+(\S+)", out)
    if not m or m.group(1) != "ARM64" or m.group(2) != "ALL" or m.group(3) != "DYLIB":
        fail("llvm-objdump header: %r" % (m.group(0) if m else out[:200]))
    if "LC_CODE_SIGNATURE" in out:
        fail("llvm-objdump shows LC_CODE_SIGNATURE")
    if not re.search(r"platform iossimulator\s+sdk 27\.1\s+minos 27\.0", out):
        fail("llvm-objdump: LC_BUILD_VERSION is not iossimulator / sdk 27.1 / minos 27.0")


def read_table(path, lib):
    rows = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.split()
            if parts[0] == lib:
                rows[parts[1]] = parts[2:]
    return rows


def check_symbols(lib, args, info):
    with open(os.path.join(args.data_dir, "host-lib-surface-%s.json" % lib), encoding="utf-8") as f:
        surface = json.load(f)
    rows = {r["name"]: r for r in surface}
    extra_ok = set(read_table(os.path.join(args.common, "extra-exports.txt"), lib))
    data_min = {k: int(v[0], 0) for k, v in read_table(os.path.join(args.common, "data-symbols.txt"), lib).items()}

    exports = {}
    for line in run([args.nm, "-gU", args.dylib]).splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3:
            exports[parts[2]] = (int(parts[0], 16), parts[1])
    missing = sorted(n for n in rows if n not in exports)
    surface_missing = [n for n in missing if rows[n]["importers"] > 0]
    if missing:
        fail("%d table symbols not exported (%d of them imported by the runtime): %s"
             % (len(missing), len(surface_missing), " ".join(missing[:20])))
    extras = sorted(n for n in exports if n not in rows and n not in extra_ok)
    if extras:
        fail("%d unexpected exports (add to common/extra-exports.txt if intended): %s"
             % (len(extras), " ".join(extras[:20])))
    for name, r in rows.items():
        if name not in exports:
            continue
        kind = exports[name][1]
        if r["kind"] == "data" and kind in ("T", "U"):
            fail("%s is data in the surface table but exported as %s" % (name, kind))
        if r["kind"] != "data" and kind != "T":
            fail("%s is a function in the surface table but exported as %s" % (name, kind))

    # Data spans: distance to the next symbol (local or external) in the same
    # section, or to the section end.
    addrs = sorted({int(l.split()[0], 16) for l in run([args.nm, "-n", "--defined-only", args.dylib]).splitlines()
                    if l.split() and re.match(r"^[0-9a-f]+$", l.split()[0])})
    for name, r in rows.items():
        if r["kind"] != "data" or name not in exports:
            continue
        addr = exports[name][0]
        sect = next((s for s in info["sections"] if s["addr"] <= addr < s["addr"] + s["size"]), None)
        if sect is None:
            fail("data symbol %s at %#x is in no section" % (name, addr))
            continue
        nxt = next((a for a in addrs if a > addr), None)
        end = sect["addr"] + sect["size"]
        span = min(end, nxt) - addr if nxt is not None else end - addr
        need = data_min.get(name, 1)
        if span < need:
            fail("data symbol %s has %d bytes before the next symbol; needs %d" % (name, span, need))
        if sect["seg"] == "__TEXT" and r.get("section", "").split(",")[0] not in ("__TEXT",):
            fail("data symbol %s is writable on the host but read-only here" % name)

    undefined = [l.split()[-1] for l in run([args.nm, "-u", args.dylib]).splitlines() if l.strip()]
    stats = dict(table=len(rows), surface=sum(1 for r in rows.values() if r["importers"] > 0),
                 exported=sum(1 for n in rows if n in exports), extras=len(exports) - sum(1 for n in rows if n in exports),
                 undefined=len(undefined))
    return stats


def main():
    ap = argparse.ArgumentParser()
    for a in ("--lib", "--dylib", "--data-dir", "--common", "--ycode", "--nm", "--objdump"):
        ap.add_argument(a, required=True)
    args = ap.parse_args()
    info = parse_macho(args.dylib)
    if not errors:
        check_layout(args.lib, info)
    check_ycode_macho(args.lib, args.ycode, args.dylib)
    check_objdump(args.objdump, args.dylib)
    stats = check_symbols(args.lib, args, info)
    segs = " ".join("%s@%#x+%#x" % (s["name"], s["vmaddr"], s["vmsize"]) for s in info["segments"])
    if errors:
        for e in errors:
            sys.stderr.write("verify libsystem_%s: FAIL: %s\n" % (args.lib, e))
        sys.exit(1)
    print("verify libsystem_%s: ok  %d bytes  exports %d/%d table rows (surface %d)  extra %d  imports %d  deps %s  %s"
          % (args.lib, info["size"], stats["exported"], stats["table"], stats["surface"], stats["extras"],
             stats["undefined"], ",".join(p.rsplit("/", 1)[-1] for _, p in info["dylibs"]) or "none", segs))


if __name__ == "__main__":
    main()

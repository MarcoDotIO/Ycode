#!/usr/bin/env python3 -I
"""metallib_dump.py: read the container tables of a .metallib file.

Ycode research tool (R8, stage 8a). Written from our own reading of the
file format (specs/simulator/metal-shaders.md section 2). It reads only
the header, the function list, the header extension, and the metadata
tag lists. It never interprets bitcode beyond the LLVM wrapper header and
the IDENTIFICATION block string.

Usage:
  metallib_dump.py FILE [--json] [--extract-dir DIR]

--extract-dir writes each distinct bitcode module to DIR/<n>.bc (for our
own compiled test shaders only; runtime extracts stay in scratch).
"""
import json
import struct
import sys
import os

PLATFORMS = {1: "macOS", 2: "iOS", 3: "tvOS", 4: "watchOS", 5: "bridgeOS",
             6: "macCatalyst", 7: "iOS-simulator", 8: "tvOS-simulator",
             9: "watchOS-simulator", 11: "visionOS", 12: "visionOS-simulator"}
FILE_TYPES = {0: "executable", 1: "core-image", 2: "dynamic", 3: "companion"}
FUNC_TYPES = {0: "vertex", 1: "fragment", 2: "kernel", 3: "unqualified",
              4: "visible", 5: "extern", 6: "intersection", 7: "mesh",
              8: "object"}


def u16(b, o): return struct.unpack_from("<H", b, o)[0]
def u32(b, o): return struct.unpack_from("<I", b, o)[0]
def u64(b, o): return struct.unpack_from("<Q", b, o)[0]


def parse_tags(b, o, end):
    """Parse a tag list: 4-char tag, u16 length, payload; ENDT ends it."""
    tags = []
    while o < end:
        t = b[o:o + 4].decode("latin-1")
        o += 4
        if t == "ENDT":
            break
        n = u16(b, o)
        o += 2
        tags.append((t, b[o:o + n]))
        o += n
    return tags, o


def decode_tag(t, d):
    if t == "NAME":
        return d.rstrip(b"\0").decode("utf-8", "replace")
    if t == "TYPE":
        return FUNC_TYPES.get(d[0], d[0])
    if t == "HASH":
        return d.hex()
    if t == "OFFT":
        return dict(zip(("public", "private", "bitcode"), struct.unpack("<3Q", d)))
    if t == "VERS":
        a = struct.unpack("<4H", d)
        return {"air": "%d.%d" % a[:2], "language": "%d.%d" % a[2:]}
    if t == "MDSZ":
        return u64(d, 0)
    if t in ("HDYN", "HSRD", "HSRC", "UUID") or len(d) > 64:
        return d.hex() if len(d) <= 64 else "<%d bytes>" % len(d)
    return d.hex()


def bitcode_ident(b, o, n):
    """Return (wrapper fields, producer string) of a bitcode module."""
    info = {}
    if u32(b, o) == 0x0B17C0DE:
        magic, ver, off, size, cpu = struct.unpack_from("<5I", b, o)
        info["wrapper"] = {"version": ver, "offset": off, "size": size,
                           "cputype": cpu}
        start = o + off
    else:
        start = o
    info["raw_magic"] = b[start:start + 4].hex()
    # The IDENTIFICATION block carries a printable producer string such as
    # "LLVM<ver>" or a vendor name; find the longest printable run near the
    # start without decoding the bitstream.
    window = b[start:start + 256]
    runs, cur = [], bytearray()
    for c in window:
        if 32 <= c < 127:
            cur.append(c)
        else:
            if len(cur) >= 4:
                runs.append(cur.decode())
            cur = bytearray()
    info["printable_near_start"] = runs[:4]
    return info, start


def fat_slices(b):
    """Slices of a universal file (big-endian header). Magic 0xCBFEBABE is
    the form MTLDynamicLibrary -serializeToURL: writes; 0xCAFEBABE (the
    Mach-O fat magic) appears in the runtime with several AIR slices."""
    if struct.unpack_from(">I", b, 0)[0] not in (0xCAFEBABE, 0xCBFEBABE):
        return None
    n = struct.unpack_from(">I", b, 4)[0]
    out = []
    for i in range(n):
        cpu, sub, off, size, align = struct.unpack_from(">5I", b, 8 + 20 * i)
        out.append({"cputype": hex(cpu), "cpusubtype": hex(sub), "offset": off,
                    "size": size, "align": align,
                    "magic": b[off:off + 4].hex()})
    return out


def dump(path, extract_dir=None):
    b = open(path, "rb").read()
    slices = fat_slices(b)
    if slices:
        mt = [s for s in slices if b[s["offset"]:s["offset"] + 4] == b"MTLB"]
        if not mt:
            raise SystemExit("no MTLB slice: %s" % slices)
        # Take the MTLB slice with the highest cpusubtype (newest AIR).
        pick = max(mt, key=lambda s: int(s["cpusubtype"], 16))
        b = b[pick["offset"]:pick["offset"] + pick["size"]]
    if b[:4] != b"MTLB":
        raise SystemExit("not a metallib: %s" % path)
    h = {
        "target_word": u16(b, 4),
        "macos_flag": bool(u16(b, 4) & 0x8000),
        "container_version": "%d.%d" % (u16(b, 6), u16(b, 8)),
        "file_type": FILE_TYPES.get(b[10] & 0x7F, b[10]),
        "stub_flag": bool(b[10] & 0x80),
        "platform_byte": b[11],
        "platform": PLATFORMS.get(b[11] & 0x7F, b[11] & 0x7F),
        "platform_high_bit": bool(b[11] & 0x80),
        "os_version": "%d.%d" % (u16(b, 12), u16(b, 14)),
        "file_size": u64(b, 16),
    }
    names = ("function_list", "public_metadata", "private_metadata", "bitcode")
    sec = {}
    for i, nm in enumerate(names):
        sec[nm] = {"offset": u64(b, 24 + 16 * i), "size": u64(b, 32 + 16 * i)}
    h["sections"] = sec
    o = sec["function_list"]["offset"]
    count = u32(b, o)
    o += 4
    funcs = []
    for _ in range(count):
        size = u32(b, o)
        tags, _ = parse_tags(b, o + 4, o + size)
        funcs.append({t: decode_tag(t, d) for t, d in tags})
        funcs[-1]["_tags"] = [t for t, _ in tags]
        o += size
    # Header extension: a tag list right after the function list.
    ext = []
    fl_end = sec["function_list"]["offset"] + sec["function_list"]["size"]
    if o < sec["public_metadata"]["offset"]:
        tags, o2 = parse_tags(b, o, sec["public_metadata"]["offset"])
        ext = [(t, decode_tag(t, d)) for t, d in tags]
    h["function_list_end"] = fl_end
    h["header_extension"] = ext

    # Public and private metadata: per function, u32 size + tag list.
    def md(kind):
        base = sec[kind]["offset"]
        out = []
        for f in funcs:
            off = f.get("OFFT", {}).get("public" if kind == "public_metadata" else "private")
            if off is None:
                out.append(None)
                continue
            p = base + off
            size = u32(b, p)
            tags, _ = parse_tags(b, p + 4, p + size)
            out.append([(t, len(d)) for t, d in tags])
        return out
    pub, priv = md("public_metadata"), md("private_metadata")
    for f, a, c in zip(funcs, pub, priv):
        f["_public_tags"] = a
        f["_private_tags"] = c
    # Bitcode modules (distinct offsets).
    mods = {}
    for f in funcs:
        off = f.get("OFFT", {}).get("bitcode")
        if off is None or off in mods:
            continue
        p = sec["bitcode"]["offset"] + off
        info, start = bitcode_ident(b, p, f.get("MDSZ", 0))
        info["offset"] = off
        info["size"] = f.get("MDSZ")
        mods[off] = info
    h["modules"] = list(mods.values())
    if slices:
        h["fat_slices"] = slices
    h["functions"] = funcs
    if extract_dir:
        os.makedirs(extract_dir, exist_ok=True)
        for i, (off, info) in enumerate(sorted(mods.items())):
            p = sec["bitcode"]["offset"] + off
            with open(os.path.join(extract_dir, "%d.bc" % i), "wb") as fh:
                fh.write(b[p:p + info["size"]])
    return h


if __name__ == "__main__":
    args = sys.argv[1:]
    xd = None
    if "--extract-dir" in args:
        i = args.index("--extract-dir")
        xd = args[i + 1]
        del args[i:i + 2]
    as_json = "--json" in args
    args = [a for a in args if a != "--json"]
    r = dump(args[0], xd)
    if as_json:
        print(json.dumps(r, indent=1, default=str))
    else:
        fs = r.pop("functions")
        print(json.dumps(r, indent=1, default=str))
        for f in fs[:20]:
            print(f.get("NAME"), f.get("TYPE"), f.get("VERS"), f.get("_tags"),
                  f.get("_public_tags"), f.get("_private_tags"))
        if len(fs) > 20:
            print("... %d functions" % len(fs))

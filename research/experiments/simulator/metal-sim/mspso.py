#!/usr/bin/env python3 -I
"""Decode the keyed descriptor blobs of pipeline-creation records (original Ycode code, R7).

Usage: mspso.py <capture dir or .bin files...>

Record bodies of op 14 (render pipeline) and op 11 (compute pipeline):
u32 0, u32 payload length, then the payload. A payload object is a u8 field
count followed by fields (u8 key, u8 type, value); type 4 carries a u32.
Some fields are offsets (from the start of the payload) of nested objects:
arrays (u32 count, u32 element offsets relative to the array, elements) and
objects. This tool prints the top-level fields and then walks every offset
that lands on a plausible object, printing what it finds, so the layout can
be checked against the variation runs.
"""
import glob
import os
import struct
import sys


def obj(p, off, depth, seen):
    if off >= len(p) or off in seen or depth > 6:
        return
    seen.add(off)
    n = p[off]
    q = off + 1
    pad = "  " * depth
    fields = []
    for _ in range(n):
        if q + 2 > len(p):
            print(pad + "<truncated>")
            return
        k, t = p[q], p[q + 1]
        q += 2
        if t in (1, 2, 4, 8):
            v = int.from_bytes(p[q:q + t], "little")
            q += t
        else:
            print(pad + "key %d unknown type %d at %d" % (k, t, q - 2))
            return
        fields.append((k, t, v))
    print(pad + "@%d object, %d fields: %s" % (off, n, " ".join("k%d=%#x" % (k, v) for k, t, v in fields)))
    tail = p[q:q + 24]
    if tail and tail[0] and all(32 <= c < 127 for c in tail[: tail.find(b"\0") if b"\0" in tail else len(tail)][:8]):
        s = tail.split(b"\0")[0]
        if len(s) >= 2:
            print(pad + "  string after fields: %r" % s.decode(errors="replace"))
    return fields, q


def array(p, off, depth, seen):
    if off + 8 > len(p):
        return
    cnt = struct.unpack_from("<I", p, off)[0]
    if cnt == 0 or cnt > 32:
        return
    offs = struct.unpack_from("<%dI" % cnt, p, off + 4)
    print("  " * depth + "@%d array count %d element offsets %s" % (off, cnt, offs))
    for o in offs:
        obj(p, off + o, depth + 1, seen)


def decode(b):
    op, ln = struct.unpack_from("<II", b, 0)
    if op not in (11, 14):
        return False
    w0, plen = struct.unpack_from("<II", b, 8)
    p = b[16:16 + plen]
    print("op %d len %d word0 %d payload %d bytes" % (op, ln, w0, plen))
    seen = set()
    r = obj(p, 0, 1, seen)
    if not r:
        return True
    fields, q = r
    for k, t, v in fields:
        if 0 < v < len(p) and k in (0, 3, 6, 7, 8, 9, 10, 12, 13, 14, 15, 16):
            print("    key %d -> offset %d:" % (k, v))
            if p[v] and p[v] < 32 and struct.unpack_from("<I", p, v)[0] > 32:
                obj(p, v, 3, seen)
            else:
                array(p, v, 3, seen)
                if v not in seen:
                    obj(p, v, 3, seen)
    print("    raw: %s" % p.hex())
    return True


def main():
    files = []
    for a in sys.argv[1:]:
        files += sorted(glob.glob(os.path.join(a, "*.bin"))) if os.path.isdir(a) else [a]
    for f in files:
        b = open(f, "rb").read()
        if len(b) >= 16:
            if decode(b):
                print("  (%s)" % os.path.basename(f))


if __name__ == "__main__":
    main()

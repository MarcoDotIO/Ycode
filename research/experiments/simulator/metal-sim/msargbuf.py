#!/usr/bin/env python3 -I
"""Decode op-16 layout descriptions (MTLPSBIN) in an mslog capture (original Ycode code, OBS-ARGBUF).

Usage: msargbuf.py <capture .log>

For every op-16 record (`messageType` 12) the tool prints the struct tree of
the description (metal-sim-protocol.md section 4.3.1) and the resulting table
from argument index to absolute byte offset, kind and size (section 4.3.2),
followed by the encoded length and alignment those rules give. The record
files are the data objects the recorder wrote (YC_MS_DUMP=1). Markers written
by our probes (mslog_mark) are shown, so each description can be matched to
the call that made it.
"""
import os
import re
import struct
import sys

END = 0xFFFFFFFFFFFFFFFF
KINDS = {1: "constant buffer", 2: "device buffer", 4: "texture", 5: "sampler", 8: "inline data"}


class Reader:
    def __init__(self, b):
        self.b, self.o = b, 0

    def u8(self):
        self.o += 1
        return self.b[self.o - 1]

    def u(self, fmt, n):
        v = struct.unpack_from(fmt, self.b, self.o)[0]
        self.o += n
        return v

    def u16(self):
        return self.u("<H", 2)

    def u32(self):
        return self.u("<I", 4)

    def u64(self):
        return self.u("<Q", 8)

    def cstr(self):
        e = self.b.index(b"\0", self.o)
        v = self.b[self.o:e].decode(errors="replace")
        self.o = e + 1
        return v


def argument(r, ind, out, off, idx):
    name = r.cstr()
    ka, _two, _z = r.u8(), r.u8(), r.u16()
    aidx, alen = r.u32(), r.u32()
    kind, acc = ka & 0x1F, ka >> 5
    size = 8
    if kind in (1, 2, 8):
        dt, _a, _b, align, sz, serial = r.u32(), r.u32(), r.u32(), r.u32(), r.u32(), r.u32()
        detail = "dataType %d align %d size %d" % (dt, align, sz)
        if kind == 8:
            size = sz
        if serial:
            r.o -= 4
            print("%s  pointee:" % ind)
            struct_(r, ind + "    ", [], 0, 0)
    elif kind == 4:
        _a, tt, _c = r.u32(), r.u32(), r.u32()
        detail = "textureType %d" % tt
    elif kind == 5:
        r.u32()
        detail = ""
    else:
        raise ValueError("unknown kind byte %#x at %d" % (ka, r.o))
    if r.u64() != END:
        raise ValueError("argument does not end with the terminator at %d" % r.o)
    print("%sargument %r %s access %d index %d arrayLength %d %s" % (ind, name, KINDS.get(kind, kind), acc, aidx, alen, detail))
    for k in range(alen):
        out.append((idx + k, off + 8 * k, KINDS.get(kind, kind), size))
    return size


def body(r, code, ind, out, off, idx):
    if code == 57:
        for _ in range(r.u32()):
            argument(r, ind, out, off, idx)
    elif code == 1:
        struct_(r, ind, out, off, idx)
        if r.u64() != END:
            raise ValueError("struct does not end with the terminator at %d" % r.o)
    elif code == 2:
        n, ec, stride, istride, _z = r.u32(), r.u32(), r.u32(), r.u32(), r.u64()
        print("%sarray of %d, element code %d, stride %d, index stride %d" % (ind, n, ec, stride, istride))
        sub = []
        body(r, ec, ind + "  ", sub, 0, 0)
        for e in range(n):
            for i, o, k, s in sub:
                out.append((idx + e * max(istride, 1) + i, off + e * stride + o, k, s))
    else:
        raise ValueError("unknown type code %d at %d" % (code, r.o))


def struct_(r, ind, out, off, idx):
    serial, n = r.u32(), r.u32()
    print("%sstruct %d, %d members" % (ind, serial, n))
    for _ in range(n):
        name, moff, midx, code, _z = r.cstr(), r.u32(), r.u32(), r.u32(), r.u64()
        print("%s  member %r offset %d index %d code %d" % (ind, name, moff, midx, code))
        body(r, code, ind + "    ", out, off + moff, idx + midx)


def decode(payload):
    if payload[:8] != b"MTLPSBIN":
        print("  not a layout description")
        return
    r = Reader(payload)
    r.o = 8
    print("  format %d" % r.u32())
    out = []
    struct_(r, "  ", out, 0, 0)
    if r.o != len(payload):
        print("  %d bytes left over" % (len(payload) - r.o))
    align = 1
    end = 0
    for i, o, k, s in sorted(out, key=lambda t: t[1]):
        a = s if k == "inline data" else 8
        align = max(align, min(a, 16) if k == "inline data" else 8)
        end = max(end, o + s)
        print("    index %5d -> offset %5d  %s, %d bytes" % (i, o, k, s))
    print("  end %d (inline data alignment approximated by size; op 17's reply is authoritative)" % end)


def main():
    log = sys.argv[1]
    d = os.path.dirname(log)
    mark = None
    for line in open(log, errors="replace"):
        m = re.search(r"MARK (.*)", line)
        if m:
            mark = m.group(1).strip()
        m = re.search(r'"command" = data len=\d+ -> (\S+)', line)
        if not m:
            continue
        b = open(os.path.join(d, m.group(1)), "rb").read()
        if len(b) < 20 or struct.unpack_from("<I", b, 0)[0] != 16:
            continue
        plen = struct.unpack_from("<I", b, 12)[0]
        print("== op 16 (last marker: %s), payload %d bytes" % (mark, plen))
        try:
            decode(b[20:20 + plen])
        except (ValueError, IndexError, struct.error) as e:
            print("  parse error: %s" % e)


if __name__ == "__main__":
    main()

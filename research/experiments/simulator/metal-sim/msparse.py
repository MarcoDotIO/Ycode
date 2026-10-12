#!/usr/bin/env python3 -I
"""Print the logical message sequence of an mslog capture (original Ycode code, R7).

Usage: msparse.py <log> [--words N] [--only-cb]

For each message: direction, connection, messageType, the other keys, and
for `command` data the record header (u32 op, u32 length) and the body as
u32 words. Command-buffer submissions (messageType 6) are split into
segments, and each segment into records (u32 op, u32 length, body).
"""
import os
import re
import struct
import sys


def records(buf, start):
    off = start
    out = []
    while off + 8 <= len(buf):
        op, ln = struct.unpack_from("<II", buf, off)
        if ln < 8 or off + ln > len(buf):
            out.append(("BAD", off, op, ln, b""))
            break
        out.append((op, off, op, ln, buf[off + 8: off + ln]))
        off += ln
    return out


def words(b, n):
    w = [struct.unpack_from("<I", b, i)[0] for i in range(0, len(b) - len(b) % 4, 4)]
    s = " ".join("%x" % x for x in w[:n])
    if len(w) > n:
        s += " ...(%d words)" % len(w)
    return s


def main():
    path = sys.argv[1]
    nw = 40
    if "--words" in sys.argv:
        nw = int(sys.argv[sys.argv.index("--words") + 1])
    only_cb = "--only-cb" in sys.argv
    d = os.path.dirname(path)
    text = open(path, errors="replace").read()
    for block in re.split(r"\n(?=== #|## )", text):
        head = block.split("\n", 1)[0]
        if head.startswith("## "):
            if not only_cb:
                print(head)
            continue
        m = re.match(r"== #(\d+) t=([\d.]+)ms conn (\d+) (\S+ \S+)", head)
        if not m:
            continue
        mt = re.search(r'"messageType" = u64 (\d+)', block)
        mt = int(mt.group(1)) if mt else None
        if only_cb and mt != 6:
            continue
        keys = re.findall(r'^  "(\w+)" = ([^\n]*)', block, re.M)
        other = [(k, v) for k, v in keys if k not in ("messageType", "command", "segments")]
        print("#%s c%s %s mt=%s %s" % (m.group(1), m.group(3), m.group(4), mt,
                                       " ".join("%s=%s" % (k, v.split(" ->")[0]) for k, v in other)))
        for k, v in keys:
            f = re.search(r"-> (\S+)", v)
            if k in ("command", "replyData") and f:
                b = open(os.path.join(d, f.group(1)), "rb").read()
                if k == "command":
                    for op, off, _, ln, body in records(b, 0):
                        print("    cmd op=%s len=%d: %s" % (op, ln, words(body, nw)))
                else:
                    print("    reply: %s" % words(b, nw))
        if mt == 6:
            for i, f in enumerate(re.findall(r"\[\d+\] data len=\d+ -> (\S+)", block)):
                b = open(os.path.join(d, f), "rb").read()
                used, tag = struct.unpack_from("<II", b, 0)
                print("  segment %d used=%d word1=%d" % (i, used, tag))
                for op, off, _, ln, body in records(b[:used], 8):
                    print("    @%d op=%s len=%d: %s" % (off, op, ln, words(body, nw)))


if __name__ == "__main__":
    main()

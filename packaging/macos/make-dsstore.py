#!/usr/bin/env python3
# Writes the .DS_Store of the disk image's root: window size, icon positions and
# the background picture. Finder is not involved, so this runs on a machine with
# nobody logged in and never takes over a screen. Standard library only.
#
# The file format (a buddy-allocated block file holding one B-tree of records)
# and the alias record are taken from public descriptions of those formats.
#
# usage: make-dsstore.py <mounted volume> <background path inside the volume> <config.json>
# config: {"window": [w, h], "icon_size": n, "icons": {"Ycode.app": [x, y], ...}}
import json
import os
import plistlib
import struct
import sys
import time

HFS_EPOCH_OFFSET = 2082844800  # seconds from 1904 to 1970


def hfs_time(t):
    return (int(t) + HFS_EPOCH_OFFSET) & 0xFFFFFFFF


def pascal(s, size):
    raw = s.encode("mac_roman", "replace")[: size - 1]
    return bytes([len(raw)]) + raw + b"\0" * (size - 1 - len(raw))


def alias_record(volume, relative):
    """A version 2 alias record for a file inside a mounted volume."""
    path = os.path.join(volume, relative)
    st, parent, vol = os.stat(path), os.stat(os.path.dirname(path)), os.stat(volume)
    name = os.path.basename(path)
    volume_name = os.path.basename(volume)
    fields = struct.pack(
        ">h28sI2shI64sII4s4shhI2s10s",
        0,  # a file
        pascal(volume_name, 28), hfs_time(vol.st_birthtime), b"H+", 5,  # 5: an ejectable disk image
        parent.st_ino, pascal(name, 64), st.st_ino, hfs_time(st.st_birthtime),
        b"\0\0\0\0", b"\0\0\0\0",
        1, 1,  # one folder level from the root in each direction is not searched for
        0, b"\0\0", b"\0" * 10,
    )

    def tag(number, data):
        pad = b"\0" if len(data) % 2 else b""
        return struct.pack(">hH", number, len(data)) + data + pad

    def ustr(s):
        encoded = s.encode("utf-16-be")
        return struct.pack(">H", len(s)) + encoded

    folder = os.path.basename(os.path.dirname(path))
    tags = tag(0, folder.encode("mac_roman", "replace"))
    tags += tag(1, struct.pack(">I", parent.st_ino))
    tags += tag(2, ":".join([volume_name] + relative.split("/")).encode("mac_roman", "replace"))
    tags += tag(14, ustr(name))
    tags += tag(15, ustr(volume_name))
    tags += tag(18, ("/" + relative).encode("utf-8"))
    tags += tag(19, ("/Volumes/" + volume_name).encode("utf-8"))
    tags += struct.pack(">hH", -1, 0)
    body = fields + tags
    return struct.pack(">4shh", b"\0\0\0\0", 8 + len(body), 2) + body


def record(filename, code, kind, value):
    head = struct.pack(">I", len(filename)) + filename.encode("utf-16-be") + code + kind
    if kind == b"blob":
        return head + struct.pack(">I", len(value)) + value
    if kind == b"long":
        return head + struct.pack(">I", value)
    if kind == b"type":
        return head + value
    raise ValueError(kind)


def sort_key(rec):
    filename, code = rec[0], rec[1]
    return (filename.lower(), code)


def free_lists(allocated):
    """The buddy allocator's free lists for an address space of 2**31 bytes."""
    lists = [[] for _ in range(32)]
    used = {(o, s) for o, s in allocated}

    def walk(offset, log):
        size = 1 << log
        if (offset, log) in used:
            return
        if not any(o < offset + size and offset < o + (1 << s) for o, s in used):
            lists[log].append(offset)
            return
        if log == 0:
            raise ValueError("block overlap")
        walk(offset, log - 1)
        walk(offset + size // 2, log - 1)

    walk(0, 31)
    return lists


def build(records):
    """The file: allocator block 0, tree header block 1, one leaf node block 2."""
    records = sorted(records, key=sort_key)
    leaf = struct.pack(">II", 0, len(records))
    for r in records:
        leaf += record(*r)
    if len(leaf) > 0x1000:
        raise ValueError("records do not fit one page")
    leaf += b"\0" * (0x1000 - len(leaf))
    header = struct.pack(">IIIII", 2, 0, len(records), 1, 0x1000)
    header += b"\0" * (32 - len(header))

    # (offset, log2 size). The first 32 bytes hold the file header. Offsets are
    # relative to the fourth byte of the file.
    alloc_block, header_block, leaf_block = (0x800, 11), (0x20, 5), (0x1000, 12)
    allocated = [(0, 5), alloc_block, header_block, leaf_block]
    free = free_lists(allocated)

    def address(block):
        return block[0] | block[1]

    root = struct.pack(">II", 3, 0)
    table = [address(alloc_block), address(header_block), address(leaf_block)]
    table += [0] * (256 - len(table))
    root += b"".join(struct.pack(">I", a) for a in table)
    root += struct.pack(">I", 1) + bytes([4]) + b"DSDB" + struct.pack(">I", 1)
    for entries in free:
        root += struct.pack(">I", len(entries)) + b"".join(struct.pack(">I", e) for e in entries)
    if len(root) > 0x800:
        raise ValueError("allocator block too small")
    root += b"\0" * (0x800 - len(root))

    image = bytearray(0x2000)
    image[0x20:0x40] = header
    image[0x800:0x1000] = root
    image[0x1000:0x2000] = leaf
    # The header: "Bud1", the allocator block's offset and size, the offset again.
    image[0:32] = b"Bud1" + struct.pack(">III", 0x800, 0x800, 0x800) + b"\0" * 16
    return struct.pack(">I", 1) + bytes(image)


def check(data, expected):
    """Reads the file back: the same walk a reader makes."""
    if data[:8] != b"\0\0\0\1Bud1":
        raise ValueError("bad magic")
    offset, size, again = struct.unpack(">III", data[8:20])
    if offset != again:
        raise ValueError("bad header")
    root = data[4 + offset:4 + offset + size]
    count = struct.unpack(">I", root[:4])[0]
    table = struct.unpack(">256I", root[8:8 + 1024])[:count]
    at = 8 + 1024
    if struct.unpack(">I", root[at:at + 4])[0] != 1 or root[at + 5:at + 9] != b"DSDB":
        raise ValueError("no DSDB directory")
    tree = struct.unpack(">I", root[at + 9:at + 13])[0]
    addr = table[tree]
    head = data[4 + (addr & ~31):]
    node, levels, records, nodes, page = struct.unpack(">IIIII", head[:20])
    if levels != 0 or nodes != 1 or page != 0x1000 or records != expected:
        raise ValueError("bad tree header")
    leaf = data[4 + (table[node] & ~31):]
    if struct.unpack(">II", leaf[:8]) != (0, expected):
        raise ValueError("bad leaf")


def main():
    volume, background = sys.argv[1], sys.argv[2]
    with open(sys.argv[3]) as f:
        config = json.load(f)
    width, height = config["window"]
    left, top = 200, 160
    bwsp = {
        "ContainerShowSidebar": False, "PreviewPaneVisibility": False, "ShowPathbar": False, "ShowSidebar": False,
        "ShowStatusBar": False, "ShowTabView": False, "ShowToolbar": False, "SidebarWidth": 0,
        "WindowBounds": "{{%d, %d}, {%d, %d}}" % (left, top, width, height),
    }
    icvp = {
        "arrangeBy": "none", "backgroundColorBlue": 1.0, "backgroundColorGreen": 1.0, "backgroundColorRed": 1.0,
        "backgroundImageAlias": alias_record(volume, background), "backgroundType": 2, "gridOffsetX": 0.0,
        "gridOffsetY": 0.0, "gridSpacing": 100.0, "iconSize": float(config["icon_size"]), "labelOnBottom": True,
        "scrollPositionX": 0.0, "scrollPositionY": 0.0, "showIconPreview": True, "showItemInfo": False,
        "textSize": 13.0, "viewOptionsVersion": 1,
    }
    records = [
        (".", b"bwsp", b"blob", plistlib.dumps(bwsp, fmt=plistlib.FMT_BINARY)),
        (".", b"icvp", b"blob", plistlib.dumps(icvp, fmt=plistlib.FMT_BINARY)),
        (".", b"vSrn", b"long", 1),
        (".", b"vstl", b"type", b"icnv"),
    ]
    for name, (x, y) in config["icons"].items():
        records.append((name, b"Iloc", b"blob", struct.pack(">II", x, y) + b"\xff\xff\xff\xff\xff\xff\0\0"))
    data = build(records)
    check(data, len(records))
    with open(os.path.join(volume, ".DS_Store"), "wb") as f:
        f.write(data)


if __name__ == "__main__":
    main()

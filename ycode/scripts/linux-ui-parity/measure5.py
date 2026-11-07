#!/usr/bin/env python3
"""Measures the cross-platform parity shots (specs/ide/cross-platform-parity.md).

    python3 -I measure5.py <shots folder> <out folder> [state ...]

<shots folder> holds mac-<appearance>-<state>.png/.txt
(CrossPlatformParityShotTests) and linux-<appearance>-<state>.png/.txt
(run-parity5.sh). Both images are brought to points (the macOS shot is
drawn at the window's backing scale, the Linux one at its desktop scale; the
Linux main window's in-window menu bar, 26 points, is cut off). For each
state and appearance it writes:

  <out>/<appearance>-<state>-pair.png   macOS left, Linux right, at 1x
  <out>/<appearance>-<state>-texts.tsv  every text present on both sides:
        the frame each side reports, the ink box found inside it (left, top,
        width, height in points) and the ink's colour, and the differences
  <out>/<appearance>-<state>-only.tsv   texts present on one side only

and prints a summary line per pair. Needs Pillow and NumPy.
"""
import os
import re
import sys

import numpy as np
from PIL import Image

MENU_BAR = 26
LINE = re.compile(r'^(text|button|segments) "(.*?)" (-?[\d.]+) (-?[\d.]+) ([\d.]+) ([\d.]+)(.*)$')


def parse(path):
    """(window (w, h), [(kind, text, (x, y, w, h), rest)])"""
    if not os.path.exists(path):
        return None, []
    lines = open(path, encoding="utf-8").read().splitlines()
    head = lines[0].split()
    size = (float(head[1]), float(head[2]))
    items = []
    for line in lines[1:]:
        m = LINE.match(line)
        if m:
            kind, text = m.group(1), m.group(2)
            box = tuple(float(m.group(i)) for i in range(3, 7))
            if kind == "segments":
                for part in text.split("|"):
                    items.append(("segment", part, box, m.group(7)))
            else:
                items.append((kind, text, box, m.group(7)))
    return size, items


def load(side, appearance, state, folder):
    png = os.path.join(folder, f"{side}-{appearance}-{state}.png")
    size, items = parse(png[:-4] + ".txt")
    if size is None or not os.path.exists(png):
        return None
    im = Image.open(png).convert("RGB")
    w, h = size
    if side == "linux":
        scale = im.width / w
        top = round((im.height / scale - h) * scale)  # the menu bar, when the image has one
        im = im.crop((0, top, im.width, im.height))
    target = (round(w), round(h))
    if im.size != target:
        im = im.resize(target, Image.LANCZOS)
    return {"image": im, "array": np.asarray(im, dtype=np.int16), "size": size, "items": items}


def ink(arr, box):
    """The ink inside a frame: pixels that depart from the box's most common
    colour by more than 60 (sum of channels). (left, top, width, height,
    '#RRGGBB' of the most departed decile) or None."""
    x, y, w, h = box
    H, W, _ = arr.shape
    x0, y0 = max(0, int(x) - 1), max(0, int(y) - 1)
    x1, y1 = min(W, int(x + w + 2)), min(H, int(y + h + 2))
    if x1 - x0 < 2 or y1 - y0 < 2:
        return None
    crop = arr[y0:y1, x0:x1].reshape(-1, 3)
    keys, counts = np.unique(crop // 4, axis=0, return_counts=True)
    bg = keys[counts.argmax()] * 4 + 2
    d = np.abs(arr[y0:y1, x0:x1] - bg).sum(axis=2)
    mask = d > 60
    if mask.sum() < 3:
        return None
    ys, xs = np.nonzero(mask)
    strong = arr[y0:y1, x0:x1][mask][d[mask] >= np.percentile(d[mask], 90)]
    c = np.median(strong, axis=0).astype(int)
    return (int(x0 + xs.min()), int(y0 + ys.min()), int(xs.max() - xs.min() + 1), int(ys.max() - ys.min() + 1),
            "#%02X%02X%02X" % tuple(c), "#%02X%02X%02X" % tuple(int(v) for v in bg))


def pair_image(mac, lin, path):
    a, b = mac["image"], lin["image"]
    out = Image.new("RGB", (a.width + b.width + 10, max(a.height, b.height)), (255, 0, 255))
    out.paste(a, (0, 0))
    out.paste(b, (a.width + 10, 0))
    out.save(path)


def measure(folder, out, appearance, state):
    mac = load("mac", appearance, state, folder)
    lin = load("linux", appearance, state, folder)
    if mac is None or lin is None:
        print(f"{appearance}-{state}: missing {'mac' if mac is None else 'linux'}")
        return
    pair_image(mac, lin, os.path.join(out, f"{appearance}-{state}-pair.png"))
    def index(items):
        d = {}
        for kind, text, box, rest in items:
            if text.strip():
                d.setdefault(text, []).append((kind, box, rest))
        return d
    mi, li = index(mac["items"]), index(lin["items"])
    rows = ["text\tmac frame\tlinux frame\tmac ink\tlinux ink\tmac colour\tlinux colour\tmac bg\tlinux bg\td ink x\td ink y\td ink h\tmac font"]
    big = 0
    def pairs(ms, ls):
        """A text that appears more than once is paired with the nearest
        frame on the other side."""
        out, free = [], list(ls)
        for m in ms:
            if not free:
                break
            best = min(free, key=lambda l: abs(l[1][0] - m[1][0]) + abs(l[1][1] - m[1][1]))
            free.remove(best)
            out.append((m, best))
        return out
    for text in sorted(set(mi) & set(li), key=lambda t: mi[t][0][1][1]):
        for (mk, mb, mrest), (lk, lb, _) in pairs(mi[text], li[text]):
            m_ink, l_ink = ink(mac["array"], mb), ink(lin["array"], lb)
            font = re.search(r"size=[\d.]+ weight=[-\d.]+( color=\S+)?", mrest)
            def f(b):
                return "%.1f %.1f %.1f %.1f" % b
            if m_ink and l_ink:
                dx, dy, dh = l_ink[0] - m_ink[0], l_ink[1] - m_ink[1], l_ink[3] - m_ink[3]
                if abs(dx) > 2 or abs(dy) > 2 or abs(dh) > 1:
                    big += 1
                rows.append(f"{text[:60]}\t{f(mb)}\t{f(lb)}\t{m_ink[:4]}\t{l_ink[:4]}\t{m_ink[4]}\t{l_ink[4]}\t{m_ink[5]}\t{l_ink[5]}\t{dx}\t{dy}\t{dh}\t{font.group(0) if font else '-'}")
            else:
                rows.append(f"{text[:60]}\t{f(mb)}\t{f(lb)}\t{m_ink}\t{l_ink}\t\t\t\t\t\t\t\t{font.group(0) if font else '-'}")
    open(os.path.join(out, f"{appearance}-{state}-texts.tsv"), "w").write("\n".join(rows) + "\n")
    only = ["side\ttext\tframe"]
    for text in sorted(set(mi) - set(li)):
        only.append(f"mac\t{text[:80]}\t%.1f %.1f %.1f %.1f" % mi[text][0][1])
    for text in sorted(set(li) - set(mi)):
        only.append(f"linux\t{text[:80]}\t%.1f %.1f %.1f %.1f" % li[text][0][1])
    open(os.path.join(out, f"{appearance}-{state}-only.tsv"), "w").write("\n".join(only) + "\n")
    print(f"{appearance}-{state}: mac {mac['size']} linux {lin['size']}; texts on both {len(set(mi) & set(li))}, "
          f"moved >2 pt {big}, mac only {len(set(mi) - set(li))}, linux only {len(set(li) - set(mi))}")


def main():
    folder, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    names = set()
    for n in os.listdir(folder):
        m = re.match(r"(mac|linux)-(light|dark)-(.+)\.png$", n)
        if m:
            names.add(m.group(3))
    states = sys.argv[3:] or sorted(names)
    for appearance in ["light", "dark"]:
        for s in states:
            measure(folder, out, appearance, s)


if __name__ == "__main__":
    main()

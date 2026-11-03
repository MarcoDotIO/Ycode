#!/usr/bin/env python3
"""Pairs the macOS IDE's and the Linux shell's screenshots (docs/PARITY.md
§5.10) and scores each pair.

    python3 -I compose.py <captures folder> <output prefix> <label>

<captures folder> holds mac-<appearance>-<state>.png (LinuxParityProbeTests)
and linux-<appearance>-<state>.png (linux-run.sh). For every state it writes
<output prefix>-<state>-<label>.png: macOS on the left, Linux on the right,
light over dark. It prints one line per pair with two scores: the share of
pixels that differ after a small blur (Gaussian, radius 1.5; a pixel
differs when a channel differs by more than 32 of 255), and the same
share among "ink" pixels only (where either image departs from its own
local background: text, icons, lines, fills). The Linux window's
in-window menu bar (the top MENU_BAR points) is left out of the score,
since the macOS menu bar is not part of the window. When the macOS window
is smaller than the Linux one (Welcome, Settings), the Linux window's
centred region of the same size is scored. Needs Pillow and NumPy.
"""
import sys
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

MENU_BAR = 26
STATES = ["welcome", "workspace", "file", "inspector-hidden", "find", "issues", "debug", "bezel",
          "product-menu", "sheet", "settings"]
NOTES = {
    "product-menu": "macOS: the system menu bar (not drawn by cacheDisplay)",
    "sheet": "macOS: the system open panel (not drawn by cacheDisplay)",
}


def load(path):
    return Image.open(path).convert("RGB") if os.path.exists(path) else None


def load_mac(path):
    """A macOS capture at one pixel per point: `cacheDisplay` draws at the
    backing scale of the screen the window would be on (2 for a window
    centred on a Retina screen), so the image is scaled to the window's
    size in points, read from the frame dump next to it."""
    im = load(path)
    dump = path[:-4] + ".txt"
    if im is None or not os.path.exists(dump):
        return im
    first = open(dump).readline()
    try:
        w, h = first.split("(")[1].split(")")[0].split(",")
        size = (round(float(w)), round(float(h)))
    except (IndexError, ValueError):
        return im
    return im if im.size == size else im.resize(size, Image.LANCZOS)


def linux_region(lin, size):
    """The Linux window below its menu bar, cut to `size` (centred when
    smaller than the window)."""
    w, h = lin.size
    body = lin.crop((0, MENU_BAR, w, h))
    bw, bh = body.size
    tw, th = size
    if (tw, th) == (1400, 900) or (tw >= bw and th >= bh):
        out = Image.new("RGB", size, (0, 0, 0))
        out.paste(body, (0, 0))
        return out
    x = max(0, (bw - tw) // 2)
    y = max(0, (bh - th) // 2)
    return body.crop((x, y, x + tw, y + th))


def score(mac, lin):
    """(differing pixels %, differing ink %): ink is where either image
    departs from its own local background (a 6-point blur) by more than
    24, so the second score ignores the plain areas that dominate the
    first."""
    region = linux_region(lin, mac.size)
    a = np.asarray(mac.filter(ImageFilter.GaussianBlur(1.5)), dtype=np.int16)
    b = np.asarray(region.filter(ImageFilter.GaussianBlur(1.5)), dtype=np.int16)
    diff = np.abs(a - b).max(axis=2) > 32
    def ink(im):
        sharp = np.asarray(im, dtype=np.int16)
        bg = np.asarray(im.filter(ImageFilter.GaussianBlur(6)), dtype=np.int16)
        return np.abs(sharp - bg).max(axis=2) > 24
    k = ink(mac) | ink(region)
    return 100.0 * diff.mean(), 100.0 * (diff & k).sum() / max(1, k.sum())


def main():
    folder, prefix, label = sys.argv[1], sys.argv[2], sys.argv[3]
    for state in STATES:
        rows = []
        line = [state]
        for look in ["light", "dark"]:
            mac = load_mac(os.path.join(folder, f"mac-{look}-{state}.png"))
            lin = load(os.path.join(folder, f"linux-{look}-{state}.png"))
            if mac is None and lin is None:
                continue
            s = score(mac, lin) if mac is not None and lin is not None else None
            line.append(f"{look} {s[0]:.1f} % (ink {s[1]:.0f} %)" if s is not None else f"{look} -")
            rows.append((look, mac, lin, s))
        if not rows:
            continue
        print("  ".join(line))
        pad, head = 16, 28
        cw = max((r[1].width if r[1] else 480) for r in rows) + max((r[2].width if r[2] else 480) for r in rows) + 3 * pad
        ch = sum(max(r[1].height if r[1] else 0, r[2].height if r[2] else 0) + head + pad for r in rows) + pad
        out = Image.new("RGB", (cw, ch), (128, 128, 128))
        d = ImageDraw.Draw(out)
        y = pad
        left_w = max((r[1].width if r[1] else 480) for r in rows)
        for look, mac, lin, s in rows:
            title = f"{state} ({look})  left: Ycode macOS IDE   right: ycode-ide on Linux"
            title += f"   differing pixels {s[0]:.1f} %, differing ink {s[1]:.0f} %" if s is not None else ""
            d.text((pad, y + 8), title, fill=(255, 255, 255))
            y += head
            if mac is not None:
                out.paste(mac, (pad, y))
            else:
                d.text((pad, y + 8), NOTES.get(state, "macOS: no capture"), fill=(255, 255, 255))
            if lin is not None:
                out.paste(lin, (2 * pad + left_w, y))
            else:
                d.text((2 * pad + left_w, y + 8), "Linux: none", fill=(255, 255, 255))
            y += max(mac.height if mac else 0, lin.height if lin else 0) + pad
        out.save(f"{prefix}-{state}-{label}.png")


if __name__ == "__main__":
    main()

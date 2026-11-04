#!/usr/bin/env python3
"""Measure the timing of a UI change from a screen recording.

Generic: it reads any video (ffmpeg decodes it) and knows nothing about the
app in it. The motion-diff harness uses the same functions.

    python3 -I motion.py VIDEO [--start S] [--end S] [--roi X,Y,W,H]
                               [--json OUT.json] [--plot OUT.png] [--displacement | --pixels]

Method (also in README.md, "Timing measurement"):
1. Decode every frame with its presentation time (variable frame rate is
   fine: a recorder that only writes changed frames gives exact change times).
2. Per frame, compare with the previous frame: mean absolute difference
   (0-255 scale), the fraction of pixels whose largest channel difference is
   above --threshold, and the bounding box of those pixels.
3. A frame is "active" when that fraction is above --min-fraction. Active
   frames closer than --gap seconds form one segment; the segment with the
   largest total difference is the primary change.
4. start = time of the first active frame minus one frame interval (the
   first changed frame already shows one step of motion); end = time of the
   last active frame; duration = end - start.
5. Progress: each frame in the segment is projected onto the line from the
   frame before the segment (0) to its last frame (1). For a cross-fade this
   is the opacity. The travel (dx, dy) is measured too, by phase correlation
   between consecutive frames, summed. When the change is a rigid move (the
   last frame is the first one shifted by that travel: a slide or a scroll),
   progress is the fraction travelled instead ("progress_method"); force
   either with --displacement or --pixels.
6. Easing: a cubic Bezier (x1, y1, x2, y2) and a spring (response, damping
   fraction) are fitted to progress over normalised time by least squares;
   the named CSS/Core Animation curves are scored too.

Output JSON: the per-frame series, the segments, the primary change with its
fits, and the parameters used. Lengths are in video pixels; divide by the
recorder's pixel_scale for points.
"""

import argparse
import json
import math
import pathlib
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

NAMED_CURVES = {
    "linear": (0.0, 0.0, 1.0, 1.0),
    "ease": (0.25, 0.1, 0.25, 1.0),
    "ease-in": (0.42, 0.0, 1.0, 1.0),
    "ease-out": (0.0, 0.0, 0.58, 1.0),
    "ease-in-out": (0.42, 0.0, 0.58, 1.0),
}
DEFAULTS = {"threshold": 2.5, "min_fraction": 0.00005, "gap": 0.12, "analysis_width": 1024}


# ---------------------------------------------------------------- decoding

def probe(video):
    """Width, height and every frame's presentation time (seconds)."""
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
         "stream=width,height:frame=best_effort_timestamp_time", "-of", "json", str(video)],
        check=True, capture_output=True, text=True).stdout
    info = json.loads(out)
    stream = info["streams"][0]
    times = [float(f["best_effort_timestamp_time"]) for f in info["frames"]
             if f.get("best_effort_timestamp_time") not in (None, "N/A")]
    return stream["width"], stream["height"], times


def decode(video, width, height, scale_width=None):
    """Yield frames as uint8 arrays (H, W, 3), one per encoded frame."""
    w, h = width, height
    filters = []
    if scale_width and scale_width < width:
        w = scale_width
        h = int(round(height * scale_width / width / 2)) * 2
        filters = ["-vf", f"scale={w}:{h}:flags=area"]
    proc = subprocess.Popen(
        ["ffmpeg", "-v", "error", "-i", str(video), "-fps_mode", "passthrough", *filters,
         "-pix_fmt", "rgb24", "-f", "rawvideo", "-"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    size = w * h * 3
    try:
        while True:
            buf = proc.stdout.read(size)
            if len(buf) < size:
                break
            yield np.frombuffer(buf, np.uint8).reshape(h, w, 3)
    finally:
        proc.kill()   # the caller may stop early
        proc.stdout.close()
        proc.wait()


def load(video, start=None, end=None, roi=None, analysis_width=DEFAULTS["analysis_width"]):
    """Frames (float32) and times inside [start, end], cropped to roi (video px)."""
    width, height, times = probe(video)
    factor = 1.0
    if analysis_width and analysis_width < width:
        factor = analysis_width / width
    frames, kept = [], []
    for t, frame in zip(times, decode(video, width, height, analysis_width)):
        if (start is not None and t < start) or (end is not None and t > end):
            continue
        if roi:
            x, y, w, h = (int(round(v * factor)) for v in roi)
            frame = frame[y:y + h, x:x + w]
        frames.append(frame.astype(np.float32))
        kept.append(t)
    return np.array(kept), frames, factor, (width, height)


# ---------------------------------------------------------------- measuring

def bbox(mask):
    ys, xs = np.nonzero(mask)
    if len(xs) == 0:
        return None
    return [int(xs.min()), int(ys.min()), int(xs.max() - xs.min() + 1), int(ys.max() - ys.min() + 1)]


def per_frame(frames, threshold):
    diff, fraction, boxes = [0.0], [0.0], [None]
    for a, b in zip(frames, frames[1:]):
        d = np.abs(b - a)
        mask = d.max(axis=2) > threshold
        diff.append(float(d.mean()))
        fraction.append(float(mask.mean()))
        boxes.append(bbox(mask))
    return diff, fraction, boxes


def segments(times, fraction, diff, min_fraction, gap):
    active = [i for i, f in enumerate(fraction) if f > min_fraction]
    groups = []
    for i in active:
        if groups and times[i] - times[groups[-1][-1]] <= gap:
            groups[-1].append(i)
        else:
            groups.append([i])
    out = []
    for g in groups:
        intervals = np.diff(times[max(0, g[0] - 1):g[-1] + 1]) if len(g) > 1 else np.array([])
        step = float(np.median(np.diff(times[g]))) if len(g) > 1 else (
            float(np.median(np.diff(times))) if len(times) > 1 else 0.0)
        start = float(times[g[0]] - step)
        end = float(times[g[-1]])
        out.append({"first_frame": g[0], "last_frame": g[-1], "frames": len(g),
                    "start_s": start, "end_s": end, "duration_ms": (end - start) * 1000,
                    "frame_interval_ms": step * 1000, "total_diff": float(sum(diff[i] for i in g)),
                    "longest_gap_ms": float(intervals.max() * 1000) if len(intervals) else 0.0})
    return out


def union_box(boxes):
    boxes = [b for b in boxes if b]
    if not boxes:
        return None
    x0 = min(b[0] for b in boxes); y0 = min(b[1] for b in boxes)
    x1 = max(b[0] + b[2] for b in boxes); y1 = max(b[1] + b[3] for b in boxes)
    return [x0, y0, x1 - x0, y1 - y0]


def progress(frames, first, last, box):
    x, y, w, h = box
    base = frames[max(0, first - 1)][y:y + h, x:x + w]
    final = frames[last][y:y + h, x:x + w]
    direction = (final - base).ravel()
    norm = float(direction @ direction)
    if norm == 0:
        return [0.0] * (last - first + 1)
    return [float((frames[i][y:y + h, x:x + w] - base).ravel() @ direction / norm) for i in range(first, last + 1)]


def rigid(crops, travel):
    """True when the last frame is the first one moved by the measured travel:
    a slide or scroll, not a fade or a reflow."""
    first, last = crops[0], crops[-1]
    dx, dy = (int(round(v)) for v in travel[-1])
    h, w = first.shape[:2]
    if abs(dx) >= w // 2 or abs(dy) >= h // 2:
        return True   # moved more than half the box: no overlap left to compare
    a = first[max(0, -dy):h - max(0, dy), max(0, -dx):w - max(0, dx)]
    b = last[max(0, dy):h - max(0, -dy), max(0, dx):w - max(0, -dx)]
    moved = float(np.abs(b - a).mean())
    still = float(np.abs(last - first).mean())
    return moved < 0.5 * still


def phase_shift(a, b):
    """Shift (dx, dy) that moves a onto b, by phase correlation, sub-pixel."""
    a = a.mean(axis=2); b = b.mean(axis=2)
    window = np.outer(np.hanning(a.shape[0]), np.hanning(a.shape[1]))
    fa = np.fft.fft2((a - a.mean()) * window); fb = np.fft.fft2((b - b.mean()) * window)
    r = fb * np.conj(fa)
    r /= np.abs(r) + 1e-9
    c = np.fft.ifft2(r).real
    py, px = np.unravel_index(np.argmax(c), c.shape)

    def refine(m, p, n, axis):
        lo = c[(p - 1) % n, px] if axis == 0 else c[py, (p - 1) % n]
        hi = c[(p + 1) % n, px] if axis == 0 else c[py, (p + 1) % n]
        denom = lo - 2 * m + hi
        off = 0.5 * (lo - hi) / denom if denom else 0.0
        v = p + off
        return v - n if v > n / 2 else v
    return refine(c[py, px], px, c.shape[1], 1), refine(c[py, px], py, c.shape[0], 0)


# ---------------------------------------------------------------- easing fits

def bezier_y(u, x1, y1, x2, y2):
    """y of the cubic Bezier (0,0)-(x1,y1)-(x2,y2)-(1,1) at x = u."""
    u = np.clip(np.asarray(u, dtype=float), 0, 1)
    lo, hi = np.zeros_like(u), np.ones_like(u)
    for _ in range(40):   # bisection: x(s) is monotonic for x1, x2 in [0, 1]
        s = (lo + hi) / 2
        x = 3 * (1 - s) ** 2 * s * x1 + 3 * (1 - s) * s ** 2 * x2 + s ** 3
        lo = np.where(x < u, s, lo); hi = np.where(x < u, hi, s)
    s = (lo + hi) / 2
    return 3 * (1 - s) ** 2 * s * y1 + 3 * (1 - s) * s ** 2 * y2 + s ** 3


def spring_progress(t, response, damping):
    """Step response of a unit spring: SwiftUI-style response (s) and damping fraction."""
    t = np.asarray(t, dtype=float)
    omega = 2 * math.pi / response
    if damping < 1:
        wd = omega * math.sqrt(1 - damping ** 2)
        return 1 - np.exp(-damping * omega * t) * (np.cos(wd * t) + damping * omega / wd * np.sin(wd * t))
    return 1 - np.exp(-omega * t) * (1 + omega * t)


def nelder_mead(f, x0, step=0.1, iterations=400):
    n = len(x0)
    simplex = [np.array(x0, float)] + [np.array(x0, float) + step * np.eye(n)[i] for i in range(n)]
    values = [f(x) for x in simplex]
    for _ in range(iterations):
        order = np.argsort(values); simplex = [simplex[i] for i in order]; values = [values[i] for i in order]
        centroid = np.mean(simplex[:-1], axis=0)
        reflected = centroid + (centroid - simplex[-1]); fr = f(reflected)
        if fr < values[0]:
            expanded = centroid + 2 * (centroid - simplex[-1]); fe = f(expanded)
            simplex[-1], values[-1] = (expanded, fe) if fe < fr else (reflected, fr)
        elif fr < values[-2]:
            simplex[-1], values[-1] = reflected, fr
        else:
            contracted = centroid + 0.5 * (simplex[-1] - centroid); fc = f(contracted)
            if fc < values[-1]:
                simplex[-1], values[-1] = contracted, fc
            else:
                simplex = [simplex[0] + 0.5 * (s - simplex[0]) for s in simplex]
                values = [f(s) for s in simplex]
    best = int(np.argmin(values))
    return simplex[best], values[best]


def rmse(a, b):
    return float(np.sqrt(np.mean((np.asarray(a) - np.asarray(b)) ** 2)))


def fit_easing(u, p, seconds):
    u = np.asarray(u); p = np.asarray(p)
    named = {k: rmse(bezier_y(u, *v), p) for k, v in NAMED_CURVES.items()}

    def bezier_cost(v):
        x1, y1, x2, y2 = v
        if not (0 <= x1 <= 1 and 0 <= x2 <= 1) or abs(y1) > 3 or abs(y2) > 3:
            return 1e9
        return rmse(bezier_y(u, x1, y1, x2, y2), p)
    best, cost = None, 1e9
    for seed in NAMED_CURVES.values():
        v, c = nelder_mead(bezier_cost, seed, 0.15)
        if c < cost:
            best, cost = v, c

    t = u * seconds

    def spring_cost(v):
        response, damping = v
        if response <= 0.01 or not (0.05 <= damping <= 2.0):
            return 1e9
        return rmse(spring_progress(t, response, damping), p)
    spring, spring_cost_value = None, 1e9
    for seed in ([seconds * 0.6, 1.0], [seconds * 0.8, 0.8], [seconds * 0.4, 0.7]):
        v, c = nelder_mead(spring_cost, seed, 0.1)
        if c < spring_cost_value:
            spring, spring_cost_value = v, c
    return {
        "cubic_bezier": {"x1": round(float(best[0]), 3), "y1": round(float(best[1]), 3),
                         "x2": round(float(best[2]), 3), "y2": round(float(best[3]), 3), "rmse": round(cost, 4)},
        "spring": {"response_s": round(float(spring[0]), 4), "damping_fraction": round(float(spring[1]), 3),
                   "rmse": round(spring_cost_value, 4)},
        "named_rmse": {k: round(v, 4) for k, v in sorted(named.items(), key=lambda kv: kv[1])},
        "overshoot": round(float(max(0.0, p.max() - 1.0)), 4),
    }


# ---------------------------------------------------------------- analysis

def analyze(video, start=None, end=None, roi=None, threshold=DEFAULTS["threshold"],
            min_fraction=DEFAULTS["min_fraction"], gap=DEFAULTS["gap"],
            analysis_width=DEFAULTS["analysis_width"], displacement=False, method="auto"):
    times, frames, factor, size = load(video, start, end, roi, analysis_width)
    result = {
        "video": str(video), "video_size_px": list(size), "analysis_scale": factor,
        "params": {"start": start, "end": end, "roi_px": roi, "threshold": threshold,
                   "min_fraction": min_fraction, "gap_s": gap, "analysis_width": analysis_width},
        "frame_count": len(frames), "segments": [], "primary": None, "frames": [],
    }
    if len(frames) < 2:
        return result
    diff, fraction, boxes = per_frame(frames, threshold)
    to_px = 1 / factor
    offset = roi[:2] if roi else [0, 0]

    def scaled(b):
        return None if b is None else [round(b[0] * to_px + offset[0]), round(b[1] * to_px + offset[1]),
                                       round(b[2] * to_px), round(b[3] * to_px)]
    result["frames"] = [{"t": float(t), "diff": round(d, 4), "changed": round(f, 6), "bbox_px": scaled(b)}
                        for t, d, f, b in zip(times, diff, fraction, boxes)]
    segs = segments(times, fraction, diff, min_fraction, gap)
    result["segments"] = segs
    if not segs:
        return result
    primary = max(segs, key=lambda s: s["total_diff"])
    first, last = primary["first_frame"], primary["last_frame"]
    box = union_box(boxes[first:last + 1])
    primary["bbox_px"] = scaled(box)
    p = progress(frames, first, last, box)
    t_seg = [primary["start_s"]] + [float(times[i]) for i in range(first, last + 1)]
    p_seg = [0.0] + p
    seconds = max(1e-6, primary["end_s"] - primary["start_s"])
    u = [(t - primary["start_s"]) / seconds for t in t_seg]
    primary["progress"] = [{"t": round(t, 5), "u": round(x, 4), "p": round(y, 4)} for t, x, y in zip(t_seg, u, p_seg)]
    primary["progress_method"] = "pixels"
    if len(u) >= 3:
        primary["easing"] = fit_easing(u, p_seg, seconds)
    if box and box[2] >= 8 and box[3] >= 8:
        # Frame-to-frame shifts stay small, so phase correlation does not wrap; their sum is the travel.
        x, y, w, h = box
        crops = [frames[i][y:y + h, x:x + w] for i in range(max(0, first - 1), last + 1)]
        dx = dy = 0.0
        travel = []
        for prev, cur in zip(crops, crops[1:]):
            sx, sy = phase_shift(prev, cur)
            dx += sx; dy += sy
            travel.append((dx, dy))
        primary["displacement_px"] = [{"t": round(float(times[i]), 5), "dx": round(tx * to_px, 2),
                                       "dy": round(ty * to_px, 2)} for i, (tx, ty) in zip(range(first, last + 1), travel)]
        total = math.hypot(*travel[-1])
        if displacement or (method == "auto" and total * to_px >= 8 and rigid(crops, travel)):
            ux, uy = travel[-1][0] / total, travel[-1][1] / total
            p_disp = [0.0] + [(tx * ux + ty * uy) / total for tx, ty in travel]
            primary["progress_pixels"] = primary["progress"]
            primary["progress"] = [{"t": round(t, 5), "u": round(x_, 4), "p": round(y_, 4)}
                                   for t, x_, y_ in zip(t_seg, u, p_disp)]
            primary["progress_method"] = "displacement"
            if len(u) >= 3:
                primary["easing"] = fit_easing(u, p_disp, seconds)
    result["primary"] = primary
    return result


# ---------------------------------------------------------------- plotting

SURFACE = (252, 252, 251)
INK = (11, 11, 11)
INK_2 = (82, 81, 78)
GRID = (226, 225, 221)
SERIES = [(42, 120, 214), (235, 104, 52), (27, 175, 122), (237, 161, 0)]


def font(size):
    try:
        return ImageFont.load_default(size=size)
    except TypeError:
        return ImageFont.load_default()


class Panel:
    def __init__(self, draw, box, x_range, y_range, title, y_label):
        self.d, self.box = draw, box
        self.x0, self.x1 = x_range
        self.y0, self.y1 = y_range
        left, top, right, bottom = box
        draw.text((left, top - 24), title, fill=INK, font=font(15))
        for k in range(5):
            yv = self.y0 + (self.y1 - self.y0) * k / 4
            yy = self.py(yv)
            draw.line([(left, yy), (right, yy)], fill=GRID, width=1)
            draw.text((left - 8, yy), f"{yv:.3g}", fill=INK_2, font=font(12), anchor="rm")
        span = self.x1 - self.x0
        tick = next(s for s in (0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 1e9) if span / s <= 10)
        t = math.ceil(self.x0 / tick) * tick
        while t <= self.x1 + 1e-9:
            xx = self.px(t)
            draw.line([(xx, bottom), (xx, bottom + 4)], fill=INK_2, width=1)
            draw.text((xx, bottom + 6), f"{t * 1000:.0f}", fill=INK_2, font=font(12), anchor="mt")
            t += tick
        draw.line([(left, bottom), (right, bottom)], fill=INK_2, width=1)
        draw.text((right, bottom + 22), "ms", fill=INK_2, font=font(12), anchor="rt")
        draw.text((left - 8, top - 24), "", fill=INK_2)
        draw.text((right, top - 24), y_label, fill=INK_2, font=font(12), anchor="ra")

    def px(self, x):
        left, _, right, _ = self.box
        return left + (x - self.x0) / max(1e-9, self.x1 - self.x0) * (right - left)

    def py(self, y):
        _, top, _, bottom = self.box
        return bottom - (y - self.y0) / max(1e-9, self.y1 - self.y0) * (bottom - top)

    def line(self, xs, ys, colour, width=2):
        pts = [(self.px(x), self.py(y)) for x, y in zip(xs, ys)]
        if len(pts) > 1:
            self.d.line(pts, fill=colour, width=width, joint="curve")

    def dots(self, xs, ys, colour, r=4):
        for x, y in zip(xs, ys):
            X, Y = self.px(x), self.py(y)
            self.d.ellipse([X - r, Y - r, X + r, Y + r], fill=colour, outline=SURFACE, width=2)

    def band(self, a, b, colour):
        _, top, _, bottom = self.box
        self.d.rectangle([self.px(a), top, self.px(b), bottom], fill=colour)


def tint(colour, amount=0.85):
    return tuple(int(c + (s - c) * amount) for c, s in zip(colour, SURFACE))


def plot(results, path, labels=None, align="start"):
    """One or more analyze() results, overlaid. align="start": each series'
    time is measured from its own detected start, so curves compare directly."""
    labels = labels or [pathlib.Path(r["video"]).stem for r in results]
    width, height = 1280, 980
    img = Image.new("RGB", (width, height), SURFACE)
    d = ImageDraw.Draw(img)
    d.text((70, 20), "Change timing", fill=INK, font=font(20))

    def origin(r):
        return r["primary"]["start_s"] if (align == "start" and r.get("primary")) else 0.0
    spans = [(f["t"] - origin(r)) for r in results for f in r["frames"]]
    ends = [r["primary"]["end_s"] - origin(r) for r in results if r.get("primary")]
    x0 = min(spans + [0.0]) if spans else 0.0
    x1 = max(spans + ends + [x0 + 0.1])
    x0 = max(x0, -0.15) if align == "start" else x0
    # legend
    lx = 70
    for i, (r, label) in enumerate(zip(results, labels)):
        prim = r.get("primary")
        text = f"{label}: " + (f"{prim['duration_ms']:.0f} ms" if prim else "no change found")
        if prim and prim.get("easing"):
            b = prim["easing"]["cubic_bezier"]
            text += f", bezier ({b['x1']}, {b['y1']}, {b['x2']}, {b['y2']})"
        colour = SERIES[i % len(SERIES)]
        d.rectangle([lx, 56, lx + 14, 70], fill=colour)
        d.text((lx + 20, 63), text, fill=INK, font=font(13), anchor="lm")
        lx += 40 + int(d.textlength(text, font=font(13)))

    max_diff = max([f["diff"] for r in results for f in r["frames"]] + [1e-3])
    a = Panel(d, (70, 120, width - 40, 330), (x0, x1), (0, max_diff * 1.1),
              "Per-frame change (mean absolute difference from the previous frame)", "0-255")
    for i, r in enumerate(results):
        if r.get("primary"):
            a.band(r["primary"]["start_s"] - origin(r), r["primary"]["end_s"] - origin(r), tint(SERIES[i % 4], 0.9))
    for i, r in enumerate(results):
        o = origin(r)
        xs = [f["t"] - o for f in r["frames"]]
        a.line(xs, [f["diff"] for f in r["frames"]], SERIES[i % 4])

    prog = [p["p"] for r in results if r.get("primary") for p in r["primary"].get("progress", [])]
    lo, hi = min(prog + [0.0]), max(prog + [1.0])
    b = Panel(d, (70, 400, width - 40, 640), (x0, x1), (min(lo, 0) - 0.05, max(hi, 1) + 0.05),
              "Progress (0 = before, 1 = after) with the fitted cubic Bezier", "progress")
    for i, r in enumerate(results):
        prim = r.get("primary")
        if not prim or not prim.get("progress"):
            continue
        o = origin(r)
        colour = SERIES[i % 4]
        if prim.get("easing"):
            e = prim["easing"]["cubic_bezier"]
            us = np.linspace(0, 1, 120)
            seconds = prim["end_s"] - prim["start_s"]
            b.line(prim["start_s"] - o + us * seconds, bezier_y(us, e["x1"], e["y1"], e["x2"], e["y2"]),
                   tint(colour, 0.45), width=2)
        b.dots([p["t"] - o for p in prim["progress"]], [p["p"] for p in prim["progress"]], colour)

    max_y = max([fr["bbox_px"][1] + fr["bbox_px"][3] for r in results for fr in r["frames"] if fr["bbox_px"]] + [1])
    c = Panel(d, (70, 710, width - 40, 930), (x0, x1), (0, max_y),
              "Changed region per frame: top and bottom edge (video px from the top)", "px")
    for i, r in enumerate(results):
        o = origin(r)
        pts = [(fr["t"] - o, fr["bbox_px"]) for fr in r["frames"] if fr["bbox_px"]]
        colour = SERIES[i % 4]
        for t, bb in pts:
            X = c.px(t)
            c.d.line([(X, c.py(bb[1])), (X, c.py(bb[1] + bb[3]))], fill=tint(colour, 0.5), width=3)
        c.dots([t for t, _ in pts], [bb[1] for _, bb in pts], colour, r=3)
        c.dots([t for t, _ in pts], [bb[1] + bb[3] for _, bb in pts], colour, r=3)
    d.text((70, height - 22), "Time axis: " + ("ms from each series' detected start" if align == "start" else "ms from the start of the video"),
           fill=INK_2, font=font(12))
    img.save(path)
    return path


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("video")
    ap.add_argument("--start", type=float, help="seconds into the video to start at")
    ap.add_argument("--end", type=float, help="seconds into the video to stop at")
    ap.add_argument("--roi", help="X,Y,W,H in video pixels")
    ap.add_argument("--threshold", type=float, default=DEFAULTS["threshold"])
    ap.add_argument("--min-fraction", type=float, default=DEFAULTS["min_fraction"])
    ap.add_argument("--gap", type=float, default=DEFAULTS["gap"])
    ap.add_argument("--analysis-width", type=int, default=DEFAULTS["analysis_width"],
                    help="downscale to this width for analysis (0 = full size)")
    ap.add_argument("--displacement", action="store_true",
                    help="always use the measured travel as progress (default: only when the change is a rigid move)")
    ap.add_argument("--pixels", action="store_true", help="always use the pixel projection as progress")
    ap.add_argument("--json", help="write the result here (default: print)")
    ap.add_argument("--plot", help="write a plot PNG here")
    a = ap.parse_args(argv)
    roi = [int(v) for v in a.roi.split(",")] if a.roi else None
    r = analyze(a.video, a.start, a.end, roi, a.threshold, a.min_fraction, a.gap, a.analysis_width or None,
                a.displacement, "pixels" if a.pixels else "auto")
    text = json.dumps(r, indent=1)
    if a.json:
        pathlib.Path(a.json).write_text(text)
    else:
        print(text)
    if a.plot:
        plot([r], a.plot)
    prim = r.get("primary")
    print(f"{a.video}: " + (f"change {prim['start_s']:.3f}-{prim['end_s']:.3f} s, {prim['duration_ms']:.0f} ms"
                            if prim else "no change found"), file=sys.stderr)


if __name__ == "__main__":
    main()

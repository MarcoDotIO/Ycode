#!/usr/bin/env python3
"""Measure the council round 1 captures (dirty room, read-only).

    python3 -I measure_captures.py SESSION_DIR [--app xcode|ycode] [--section NAME ...]

SESSION_DIR is a capture session folder (it holds `xcode/` and `ycode/`,
each with a manifest, 1x stills and videos with frame-time sidecars). The
script only reads it. It prints the numbers that `specs/ide/*` cite in
their "Council round 1 measurements (2026-11-04)" sections; how they were
taken is in `research/notes/council-r1-2026-11-04.md`.

Coordinates are window points from the top left (the stills are 1x, so one
pixel is one point). Colours are sRGB hex of fully covered pixels.

The pixel offsets below (code column, line pitch, region boxes) were found
on the stills first and are written here so the run can be repeated; each
section prints the raw runs it relies on so that a changed capture shows up
as a mismatch rather than a silently wrong number.
"""

import argparse
import json
import pathlib
import subprocess

import numpy as np
from PIL import Image

# Editor grid of the Xcode capture (found from glyph ink, checked per run).
CODE_X0 = 341          # left edge of column 0
ADVANCE = 8            # points per character at 1x
FIRST_ROW_TOP = 93     # top of visual line 1
LINE_PITCH = 18


# ---------------------------------------------------------------- pixels

def hexcolor(c):
    return "#%02X%02X%02X" % tuple(int(round(v)) for v in c)


def load_still(session, app, name):
    path = session / app / name
    return np.asarray(Image.open(path).convert("RGB")).astype(int)


def colour_runs(line, origin, tol=3, min_len=1):
    """Runs of near-equal colour along a 1-D pixel line: (start, end, hex)."""
    out, start, ref, acc = [], 0, line[0], [line[0]]
    for i in range(1, len(line)):
        if np.abs(line[i] - ref).max() > tol:
            out.append((origin + start, origin + i - 1, hexcolor(np.median(acc, axis=0))))
            start, ref, acc = i, line[i], [line[i]]
        else:
            acc.append(line[i])
    out.append((origin + start, origin + len(line) - 1, hexcolor(np.median(acc, axis=0))))
    return [r for r in out if r[1] - r[0] + 1 >= min_len]


def row_runs(im, y, x0, x1, **kw):
    return colour_runs(im[y, x0:x1], x0, **kw)


def column_runs(im, x, y0, y1, **kw):
    return colour_runs(im[y0:y1, x], y0, **kw)


def ink_colour(im, box, k=5):
    """Colour of the k pixels farthest from the box's median (its background)."""
    x0, y0, x1, y1 = box
    px = im[y0:y1, x0:x1].reshape(-1, 3)
    bg = np.median(px, axis=0)
    far = np.argsort(-np.abs(px - bg).sum(axis=1))[:k]
    return hexcolor(np.median(px[far], axis=0))


def ink_box(im, box, threshold=40):
    x0, y0, x1, y1 = box
    region = im[y0:y1, x0:x1]
    bg = np.median(region.reshape(-1, 3), axis=0)
    ink = np.abs(region - bg).max(axis=2) > threshold
    xs, ys = np.nonzero(ink.any(axis=0))[0], np.nonzero(ink.any(axis=1))[0]
    return (x0 + int(xs.min()), y0 + int(ys.min()), x0 + int(xs.max()), y0 + int(ys.max()))


def corner_coverage(radius, size, supersample=16):
    offsets = (np.arange(supersample) + 0.5) / supersample
    cov = np.zeros((size, size))
    for y in range(size):
        for x in range(size):
            px, py = x + offsets[None, :], y + offsets[:, None]
            in_corner = (px < radius) & (py < radius)
            inside = ~in_corner | ((px - radius) ** 2 + (py - radius) ** 2 <= radius ** 2)
            cov[y, x] = inside.mean()
    return cov


def fit_corner_radius(alpha):
    """Best circular radius for a top-left corner coverage patch."""
    size = alpha.shape[0]
    errors = {r: float(((corner_coverage(r, size) - alpha) ** 2).sum())
              for r in np.arange(1, 14, 0.5)}
    return min(errors, key=errors.get)


def capsule_spans(im, y, threshold=8):
    """x spans darker than the toolbar's own background (row 2) on row y."""
    darker = im[2].mean(axis=1) - im[y].mean(axis=1) > threshold
    xs = np.nonzero(darker)[0]
    spans, start, prev = [], xs[0], xs[0]
    for x in xs[1:]:
        if x > prev + 1:
            spans.append((int(start), int(prev)))
            start = x
        prev = x
    spans.append((int(start), int(prev)))
    return [s for s in spans if s[1] - s[0] >= 30]


# ---------------------------------------------------------------- video

def video_frames(session, app, name):
    """(t, frame) per recorded frame; t comes from the sidecar's pts."""
    path = session / app / f"{name}.mov"
    meta = json.loads(path.with_suffix(".mov.json").read_text())
    pts = [f["pts"] for f in meta["frames"]]
    width, height = meta["size_px"]
    proc = subprocess.Popen(
        ["ffmpeg", "-v", "error", "-i", str(path), "-fps_mode", "passthrough",
         "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
    size = width * height * 3
    for t in pts:
        buf = proc.stdout.read(size)
        if len(buf) < size:
            break
        yield t, np.frombuffer(buf, np.uint8).reshape(height, width, 3).astype(int)
    proc.stdout.close()
    proc.wait()


def bezier_progress(curve, u):
    """y of a CSS-style cubic Bezier at x = u (bisection, vectorised)."""
    x1, y1, x2, y2 = curve
    u = np.asarray(u, float)
    lo, hi = np.zeros_like(u), np.ones_like(u)
    for _ in range(40):
        s = (lo + hi) / 2
        x = 3 * (1 - s) ** 2 * s * x1 + 3 * (1 - s) * s ** 2 * x2 + s ** 3
        lo, hi = np.where(x < u, s, lo), np.where(x < u, hi, s)
    s = (lo + hi) / 2
    return 3 * (1 - s) ** 2 * s * y1 + 3 * (1 - s) * s ** 2 * y2 + s ** 3


def fit_bezier_grid(ts, progress, starts, ends):
    """Grid search over start, end and the four control values; best RMSE."""
    axes = (np.arange(0, 1.01, 0.05), np.arange(-0.2, 0.41, 0.05),
            np.arange(0, 1.01, 0.05), np.arange(0.6, 1.31, 0.05))
    grid = [a.ravel() for a in np.meshgrid(*axes, indexing="ij")]
    best = None
    for t0 in starts:
        for t1 in ends:
            u = np.clip((np.asarray(ts) - t0) / (t1 - t0), 0, 1)
            err = sum((bezier_progress(grid, np.full(grid[0].shape, uk)) - pk) ** 2
                      for uk, pk in zip(u, progress))
            i = int(np.argmin(err))
            rmse = float(np.sqrt(err[i] / len(ts)))
            if best is None or rmse < best["rmse"]:
                best = {"rmse": round(rmse, 4), "start": t0, "end": t1,
                        "curve": [round(float(g[i]), 2) for g in grid]}
    return best


def named_curve_rmse(ts, progress, curve, starts, ends):
    best = None
    for t0 in starts:
        for t1 in ends:
            u = np.clip((np.asarray(ts) - t0) / (t1 - t0), 0, 1)
            rmse = float(np.sqrt(np.mean((bezier_progress(curve, u) - progress) ** 2)))
            if best is None or rmse < best[0]:
                best = (round(rmse, 4), round(t0, 4), round(t1 - t0, 4))
    return best


# ---------------------------------------------------------------- sections

def editor(session, app):
    im = load_still(session, app, "01-editor-at-rest-after.png")
    row = lambda n: FIRST_ROW_TOP + LINE_PITCH * (n - 1)
    col = lambda c: CODE_X0 + ADVANCE * c
    return {
        "column x 290-345, rows 0-120": column_runs(im, 310, 0, 120, tol=1),
        "current line band row 95": row_runs(im, 95, 290, 1145, min_len=3),
        "line 18 glyph runs": row_runs(im, 590, 340, 560, tol=40, min_len=1)[:12],
        "cap height (S of Section00)": ink_box(im, (col(7), row(27), col(8), row(27) + 18)),
        "x-height (a, line 18)": ink_box(im, (col(29), row(28), col(30), row(28) + 18)),
        "gutter number 1": ink_box(im, (300, row(1), 336, row(1) + 18)),
        "gutter number 10": ink_box(im, (300, row(36), 336, row(36) + 18)),
        "code digits 10": ink_box(im, (col(23), row(38), col(25), row(38) + 18)),
        "band corner radius": fit_corner_radius(np.clip(
            (im[93:103, 304:314].mean(axis=2) - 255) / (0xEE - 255), 0, 1)),
        "wrapped continuation first glyph": ink_box(im, (330, row(7), 400, row(7) + 18)),
    }


def syntax_colours(session, app):
    im = load_still(session, app, "01-editor-at-rest-after.png")
    row = lambda n: FIRST_ROW_TOP + LINE_PITCH * (n - 1)
    col = lambda c: CODE_X0 + ADVANCE * c
    tokens = {  # name: (first column, last column, visual row)
        "keyword (import, struct, let, func)": (4, 7, 28),
        "plain text (module name)": (7, 17, 3),
        "comment (block)": (1, 70, 6),
        "comment (line, trailing)": (26, 52, 28),
        "string literal": (32, 44, 40),
        "number": (23, 24, 28),
        "type name (Int, String)": (17, 20, 28),
        "type declaration name": (7, 16, 27),
        "other declaration name": (8, 15, 28),
        "line number": (None, None, 28),
        "current line's number": (None, None, 1),
    }
    out = {}
    for name, (c0, c1, r) in tokens.items():
        box = (300, row(r), 336, row(r) + 18) if c0 is None else (col(c0), row(r), col(c1), row(r) + 18)
        out[name] = ink_colour(im, box)
    return out


def minimap(session, app):
    im = load_still(session, app, "01-editor-at-rest-after.png")
    return {
        "row 150 (inside visible-area shade)": row_runs(im, 150, 985, 1141),
        "row 230 (below the shade)": row_runs(im, 230, 985, 1141),
        "column 1005 (shade extent)": column_runs(im, 1005, 86, 400, tol=2, min_len=3),
        "column 1050 (line bars)": column_runs(im, 1050, 84, 120, tol=2)[:10],
    }


def toolbar(session, app):
    out = {}
    for still in ("01-editor-at-rest-after.png", "02-editor-scroll-down-after.png",
                  "08-inspector-toggle-after.png"):
        im = load_still(session, app, still)
        out[still] = {"capsule spans at y 26": capsule_spans(im, 26),
                      "column x 700": column_runs(im, 700, 0, 52, tol=2)}
    im = load_still(session, app, "01-editor-at-rest-after.png")
    out["title"] = ink_box(im, (405, 8, 592, 29), threshold=30)
    out["subtitle"] = ink_box(im, (405, 29, 592, 45), threshold=30)
    out["title colour"] = ink_colour(im, (412, 14, 483, 24))
    return out


def navigator(session, app):
    im = load_still(session, app, "01-editor-at-rest-after.png")
    bg = np.array([0xF2, 0xF2, 0xF3])
    rows = []
    ink = np.abs(im[84:300, 0:289] - bg).max(axis=2) > 30
    on, start = ink.any(axis=1), None
    for i, v in enumerate(list(on) + [False]):
        if v and start is None:
            start = i
        if not v and start is not None:
            xs = np.nonzero(ink[start:i].any(axis=0))[0]
            rows.append({"ink y": (84 + start, 84 + i - 1), "first ink x": int(xs.min())})
            start = None
    band = (im[198:208, 10:20].mean(axis=2) - bg.mean()) / (0xE7 - bg.mean())
    after_scroll = load_still(session, app, "07-navigator-scroll-after.png")
    return {
        "rows": rows,
        "selected band column x 200": column_runs(im, 200, 185, 230, tol=1),
        "selected band row 209": [row_runs(im, 209, 0, 300, tol=1)[i] for i in (0, 1, -2, -1)],
        "selected band corner radius": fit_corner_radius(np.clip(band, 0, 1)),
        "scroller row 500 (after scroll)": row_runs(after_scroll, 500, 250, 295, tol=2),
        "scroller column 281 (after scroll)": column_runs(after_scroll, 281, 40, 880, tol=3, min_len=2),
        "selected band row 815 with scroller": row_runs(after_scroll, 815, 0, 290, tol=2, min_len=3),
    }


def inspector(session, app):
    im = load_still(session, app, "01-editor-at-rest-after.png")
    return {
        "column x 1390": column_runs(im, 1390, 84, 840, tol=2),
        "rule row 158": row_runs(im, 158, 1141, 1400),
        "table top row 520": row_runs(im, 520, 1141, 1400),
        "label Name": ink_box(im, (1150, 112, 1222, 130)),
        "label Type": ink_box(im, (1150, 136, 1222, 154)),
        "label Location": ink_box(im, (1150, 163, 1222, 181)),
        "label Text Encoding": ink_box(im, (1145, 669, 1222, 687)),
        "label Line Endings": ink_box(im, (1145, 691, 1222, 709)),
        "disabled popup title colour": ink_colour(im, (1230, 670, 1330, 686)),
    }


def sticky_header(session, app):
    im = load_still(session, app, "02-editor-scroll-down-after.png")
    return {
        "column x 300": column_runs(im, 300, 80, 125, tol=1),
        "column x 700": column_runs(im, 700, 80, 125, tol=1),
        "separator row 106": row_runs(im, 106, 288, 1000, tol=1, min_len=3),
        "gutter number box": ink_box(im, (300, 86, 336, 104)),
        "gutter number colour": ink_colour(im, (300, 86, 336, 104)),
    }


def scroll_travel(session, app):
    """Content shift between the before and after stills, by matching rows."""
    out = {}
    for step in ("02-editor-scroll-down", "03-editor-flick-up"):
        a = load_still(session, app, f"{step}-before.png").mean(axis=2)[:, 350:980]
        b = load_still(session, app, f"{step}-after.png").mean(axis=2)[:, 350:980]
        best = None
        for shift in range(-900, 901):
            y0, y1 = max(110, 110 + shift), min(840, 840 + shift)
            if y1 - y0 < 100:
                continue
            err = float(np.mean(np.abs(a[y0:y1] - b[y0 - shift:y1 - shift])))
            if best is None or err < best[0]:
                best = (err, shift)
        out[step] = best[1]
    return out


def scroll_under(session, app):
    """Mean darkness (255 - grey) of bar regions over the scroll video."""
    regions = {"toolbar band above capsules": (700, 0, 990, 7),
               "toolbar band below capsules": (700, 45, 990, 52),
               "jump bar (no text columns)": (700, 53, 990, 84),
               "sticky header / top rows": (700, 86, 990, 105),
               "bottom bar": (330, 845, 900, 880),
               "content (reference)": (700, 120, 990, 840)}
    samples = {k: [] for k in regions}
    for _, frame in video_frames(session, app, "02-editor-scroll-down"):
        grey = frame.mean(axis=2)
        for k, (x0, y0, x1, y1) in regions.items():
            samples[k].append(float((255 - grey[y0:y1, x0:x1]).mean()))
    return {k: {"median": round(float(np.median(v)), 2), "max": round(max(v), 2)}
            for k, v in samples.items()}


def inspector_toggle(session, app):
    """Per frame: the inspector divider's x on row 500 and the image's left edge on row 300."""
    track = []
    for t, frame in video_frames(session, app, "08-inspector-toggle"):
        row = frame[500].mean(axis=1)
        divider = [x for x in range(900, 1398) if row[x] < row[x - 2] - 4 and row[x] < row[x + 2] - 4]
        r300 = frame[300].mean(axis=1)
        image = [x for x in range(292, 1390) if abs(r300[x] - 255) > 40]
        track.append((round(t, 4), divider[0] if divider else 1400, image[0] if image else None))
    moving = [i for i in range(1, len(track)) if track[i][1:] != track[i - 1][1:]]
    first, last = moving[0] - 1, moving[-1]
    span = track[first:last + 2]
    ts = [s[0] for s in span]
    p = [(s[1] - span[0][1]) / (span[-1][1] - span[0][1]) for s in span]
    starts, ends = np.arange(ts[0], ts[1] + 0.001, 0.005), np.arange(ts[-3], ts[-1] + 0.006, 0.005)
    return {"frames (t, divider x, image left x)": span,
            "free fit": fit_bezier_grid(ts, p, starts, ends),
            "ease-in-out (0.42,0,0.58,1)": named_curve_rmse(ts, p, (0.42, 0, 0.58, 1), starts - 0.02, ends),
            "ease-in (0.42,0,1,1)": named_curve_rmse(ts, p, (0.42, 0, 1, 1), starts - 0.02, ends),
            "linear": named_curve_rmse(ts, p, (0, 0, 1, 1), starts, ends)}


def image_open(session, app):
    """Which regions change in which frame after the open-document request."""
    regions = {"navigator rows": (0, 84, 290, 850), "toolbar title": (380, 0, 600, 52),
               "jump bar": (290, 52, 1140, 86), "editor": (290, 86, 1140, 843),
               "inspector": (1141, 84, 1400, 880)}
    manifest = json.loads((session / app / "manifest.json").read_text())
    step = next(s for s in manifest["steps"] if s["id"] == "open-stripes")
    events, prev = [], None
    for t, frame in video_frames(session, app, "04-open-stripes"):
        if prev is not None:
            changed = np.abs(frame - prev).max(axis=2) > 8
            hit = {k: int(changed[y0:y1, x0:x1].sum()) for k, (x0, y0, x1, y1) in regions.items()}
            hit = {k: v for k, v in hit.items() if v}
            if hit:
                events.append((round(t, 4), hit))
        prev = frame
    viewer = load_still(session, app, "04-open-stripes-after.png")
    return {"request at": step.get("t_action_in_video"), "changes": events,
            "viewer column x 700": column_runs(viewer, 700, 84, 880, tol=6),
            "image row 120": row_runs(viewer, 120, 290, 1140, tol=6)}


SECTIONS = {"editor": editor, "colours": syntax_colours, "minimap": minimap,
            "toolbar": toolbar, "navigator": navigator, "inspector": inspector,
            "sticky": sticky_header, "travel": scroll_travel, "under": scroll_under,
            "inspector-toggle": inspector_toggle, "image-open": image_open}


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("session", type=pathlib.Path)
    ap.add_argument("--app", default="xcode", choices=("xcode", "ycode"))
    ap.add_argument("--section", nargs="*", default=list(SECTIONS))
    args = ap.parse_args()
    for name in args.section:
        print(f"== {name} ({args.app})")
        print(json.dumps(SECTIONS[name](args.session, args.app), indent=1, default=str))


if __name__ == "__main__":
    main()

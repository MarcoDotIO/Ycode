#!/usr/bin/env python3
"""Measure the council round 2 captures (dirty room, read-only).

    python3 -I measure_r2.py SESSION_DIR [--app xcode|ycode] [--section NAME ...]

SESSION_DIR is the round 2 capture session (`xcode/` and `ycode/`, each with
a manifest, 1x stills and recordings with frame-time sidecars). It prints
the numbers behind the "Council round 2 measurements (2026-11-04)" sections
of `specs/ide/*`; the method is in `research/notes/council-r2-2026-11-04.md`.
Pixel helpers come from the round 1 script.
"""

import argparse
import json
import pathlib
import sys

import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "council-r1"))
import measure_captures as r1  # noqa: E402  (shared pixel and video helpers)

CONTENT_TOP = 86          # first editor row under the jump bar's separator
GUTTER_BOX = (300, 336)   # x range of the line numbers


def changed_frames(session, app, step, threshold=8):
    """(t, frame) for the first frame and every frame that differs from the one before."""
    prev = None
    for t, frame in r1.video_frames(session, app, step):
        if prev is None or (np.abs(frame - prev).max(axis=2) > threshold).any():
            yield t, frame
        prev = frame


def step_action_time(session, app, step):
    manifest = json.loads((session / app / "manifest.json").read_text())
    entry = next(s for s in manifest["steps"] if s.get("video", "").startswith(step))
    return entry.get("t_action_in_video")


def bars(session, app):
    """Mean colour of each bar region over the bands scroll: extremes over grey and red content."""
    regions = {"toolbar band y0-6": (700, 0, 850, 7), "toolbar band y45-51": (700, 45, 850, 52),
               "toolbar gap y20-30": (862, 20, 876, 31), "jump bar y53-83": (700, 53, 980, 84),
               "content y86-104": (700, 86, 980, 105), "bottom bar y846-879": (400, 846, 800, 880)}
    series = {k: [] for k in regions}
    for t, frame in r1.video_frames(session, app, "08-bands-scroll"):
        for k, (x0, y0, x1, y1) in regions.items():
            series[k].append(frame[y0:y1, x0:x1].reshape(-1, 3).mean(axis=0))
    out = {}
    for k, values in series.items():
        c = np.array(values)
        redness = c[:, 0] - c[:, 1]
        darkness = 255 - c.mean(axis=1)
        grey = np.where(np.abs(redness) < 4, darkness, -1)
        out[k] = {"start": r1.hexcolor(c[0]),
                  "over grey bands": r1.hexcolor(c[int(np.argmax(grey))]),
                  "over grey: darkness": round(float(grey.max()), 1),
                  "over red bands": r1.hexcolor(c[int(np.argmax(redness))])}
    return out


def sticky(session, app):
    """Scroll offset per frame (rows matched against the before and after stills) and the header's presence."""
    before = r1.load_still(session, app, "03-editor-scroll-down-before.png").mean(axis=2)[:, 345:980]
    after = r1.load_still(session, app, "03-editor-scroll-down-after.png")
    header = after.mean(axis=2)[86:104, 295:500]
    doc = np.full((2000, before.shape[1]), np.nan)
    doc[0:757] = before[CONTENT_TOP:843]
    doc[600 + 21:600 + 757] = after.mean(axis=2)[107:843, 345:980]
    rows, last = [], None
    for t, frame in r1.video_frames(session, app, "03-editor-scroll-down"):
        grey = frame.mean(axis=2)
        errors = [(np.mean(np.abs(grey[400:700, 345:980] - doc[s + 314:s + 614])), s)
                  for s in range(0, 620) if not np.isnan(doc[s + 314:s + 614]).any()]
        offset = min(errors)[1]
        pinned = float(np.mean(np.abs(grey[86:104, 295:500] - header))) < 3
        if (offset, pinned) != last:
            rows.append((round(t, 4), offset, pinned))
        last = (offset, pinned)
    return rows


def flick(session, app):
    """Offset per changed frame for the momentum flick, and a critically damped fit of the spring-back."""
    before = r1.load_still(session, app, "03-editor-scroll-down-before.png").mean(axis=2)[:, 345:980]
    doc = np.full((2000, before.shape[1]), np.nan)
    doc[200:957] = before[CONTENT_TOP:843]
    if app == "xcode":   # the reference's after still sits exactly 600 below (Ycode's does not)
        after = r1.load_still(session, app, "03-editor-scroll-down-after.png").mean(axis=2)[:, 345:980]
        doc[200 + 621:200 + 1357] = after[107:843]
    track = []
    for t, frame in changed_frames(session, app, "04-editor-flick-up"):
        grey = frame.mean(axis=2)[500:800, 345:980]
        errors = [(np.mean(np.abs(grey - doc[200 + s + 414:200 + s + 714])), s)
                  for s in range(-180, 640) if not np.isnan(doc[200 + s + 414:200 + s + 714]).any()]
        err, offset = min(errors)
        track.append((round(t, 4), offset if err < 3 else None, round(float(err), 2)))
    known = [(t, s) for t, s, _ in track if s is not None]
    if not known:
        return {"track (t, offset)": track}
    peak_t, peak = min(known, key=lambda p: p[1])
    back = [(t, -s) for t, s in known if t >= peak_t]
    ts, xs = np.array([p[0] for p in back]), np.array([p[1] for p in back], float)
    best = None
    for omega in np.arange(5, 25, 0.05):
        u = np.clip(ts - peak_t, 0, None) * omega
        rmse = float(np.sqrt(np.mean((-peak * (1 + u) * np.exp(-u) - xs) ** 2)))
        if best is None or rmse < best[0]:
            best = (rmse, omega)
    return {"track (t, offset)": track, "overscroll": peak, "at": peak_t,
            "spring-back omega": round(best[1], 2), "response s": round(2 * np.pi / best[1], 3),
            "rmse pt": round(best[0], 2)}


def inspector(session, app):
    """Per changed frame: the inspector's leading edge, the wrap of line 6, the first line number's top."""
    out = {}
    for step in ("10-inspector-hide", "11-inspector-show"):
        rows = []
        for t, frame in changed_frames(session, app, step):
            row = frame[856].astype(int)
            x = 1398
            while x > 300 and np.abs(row[x] - row[1396]).max() <= 4:
                x -= 1
            first = frame[187:200, 341:1000].mean(axis=2)
            cont = frame[205:218, 341:1000].mean(axis=2)
            gutter = frame[CONTENT_TOP:140, GUTTER_BOX[0]:GUTTER_BOX[1]].mean(axis=2)
            ink = lambda a: 341 + int(np.nonzero((a < 170).any(axis=0))[0].max()) if (a < 170).any() else None
            top = np.nonzero((gutter < 200).any(axis=1))[0]
            rows.append((round(t, 4), x, ink(first), ink(cont), CONTENT_TOP + int(top.min()) if len(top) else None))
        out[step] = {"action": step_action_time(session, app, step),
                     "frames (t, inspector edge x, line 6 row 1 end, row 2 end, first number top)": rows}
    return out


def cadence(session, app):
    """Median and worst interval between frames in which the content changed."""
    rois = {"03-editor-scroll-down": (300, 120, 980, 800), "04-editor-flick-up": (300, 120, 980, 800),
            "08-bands-scroll": (300, 120, 980, 800), "15-navigator-scroll": (0, 100, 280, 820)}
    out = {}
    for step, (x0, y0, x1, y1) in rois.items():
        times, prev = [], None
        for t, frame in r1.video_frames(session, app, step):
            region = frame[y0:y1, x0:x1]
            if prev is not None and (np.abs(region - prev).max(axis=2) > 8).sum() > 50:
                times.append(t)
            prev = region
        gaps = np.diff(times) * 1000
        out[step] = {"frames": len(times), "median ms": round(float(np.median(gaps)), 1),
                     "p90 ms": round(float(np.percentile(gaps, 90)), 1), "max ms": round(float(gaps.max()), 1)}
    return out


def navigator(session, app):
    rest = r1.load_still(session, app, "02-editor-at-rest-after.png")
    out = {"selected band column x 200": r1.column_runs(rest, 200, 210, 250, tol=2),
           "label colour": r1.ink_colour(rest, (76, 180, 155, 195)),
           "plain group glyph darkest": r1.hexcolor(sorted(rest[266:284, 40:60].reshape(-1, 3).tolist(), key=sum)[0])}
    for still in ("14-navigator-expand-before.png", "14-navigator-expand-after.png", "15-navigator-scroll-after.png"):
        im = r1.load_still(session, app, still)
        out[still] = r1.column_runs(im, 281, 40, 880, tol=3, min_len=3)
    a = r1.load_still(session, app, "15-navigator-scroll-after.png")
    b = r1.load_still(session, app, "15-navigator-scroll-before.png")
    diff = np.abs(a - b).max(axis=2)
    out["scroll-under max change"] = {name: int(diff[y0:y1, x0:x1].max()) for name, (x0, y0, x1, y1) in {
        "toolbar band": (0, 0, 290, 45), "selector capsule": (6, 51, 284, 81),
        "filter capsule": (42, 843, 284, 873)}.items()}
    return out


def separator_columns(im, x0, x1, y0=100, y1=800):
    """Columns that are a full-height 1-point line of about #E6E6E6 (the minimap's separator)."""
    band = im[y0:y1, x0:x1].astype(int)
    hit = (np.abs(band - 230).max(axis=2) <= 4).mean(axis=0)
    return [x0 + int(i) for i in np.nonzero(hit > 0.85)[0]]


def minimap(session, app):
    """Minimap separator and scroll-bar lane in three editor widths (the narrow window still is drawn at 0.898)."""
    out = {}
    for still in ("02-editor-at-rest-after.png", "10-inspector-hide-after.png"):
        im = r1.load_still(session, app, still)
        out[still] = {"separator x": separator_columns(im, 900, 1400),
                      "lane row 860": r1.row_runs(im, 860, 1100, 1400, tol=2, min_len=2)}
    path = session / app / "17-narrow-window-after.png"
    alpha = np.asarray(r1.Image.open(path))[:, :, 3]
    opaque = np.nonzero(alpha[400] == 255)[0]
    scale = (opaque.max() - opaque.min() + 1) / 1100   # the still may show the window shrunk
    narrow = r1.load_still(session, app, "17-narrow-window-after.png").mean(axis=2)
    top = int(np.nonzero(alpha[:, 500] == 255)[0].min())
    band = narrow[top + int(120 * scale):top + int(700 * scale)]
    local_min = (band[:, 1:-1] < band[:, :-2] - 4) & (band[:, 1:-1] < band[:, 2:] - 4) & (band[:, 1:-1] > 215)
    cols = [int(i) + 1 for i in np.nonzero(local_min.mean(axis=0) > 0.8)[0]]
    out["17-narrow-window-after.png"] = {"scale": round(float(scale), 3), "separator x (still)": cols,
                                         "separator x (points)": [round(c / scale) for c in cols]}
    return out


def welcome(session, app):
    im = r1.load_still(session, app, "18-welcome-window-after.png")
    return {"buttons row 178": r1.row_runs(im, 178, 500, 900, tol=3, min_len=2),
            "list column x 700": r1.column_runs(im, 700, 150, 560, tol=3),
            "separator row 314": r1.row_runs(im, 314, 520, 870, tol=3, min_len=2),
            "title ink": r1.ink_box(im, (600, 100, 800, 126), threshold=60)}


SECTIONS = {"bars": bars, "sticky": sticky, "flick": flick, "inspector": inspector,
            "cadence": cadence, "navigator": navigator, "minimap": minimap, "welcome": welcome}


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("session", type=pathlib.Path)
    ap.add_argument("--app", default="xcode", choices=("xcode", "ycode"))
    ap.add_argument("--section", nargs="*", default=list(SECTIONS))
    args = ap.parse_args()
    for name in args.section:
        print(f"== {name} ({args.app})")
        print(json.dumps(SECTIONS[name](args.session, args.app), default=str))


if __name__ == "__main__":
    main()

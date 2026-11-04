#!/usr/bin/env python3
"""Comparison sheets from capture-session manifests.

    python3 -I sheets.py OUT_DIR MANIFEST.json [MANIFEST.json ...]
            [--interval MS] [--frames N]

Generic: the manifests may come from any apps; each one is a column (or a
row, in frame strips) labelled with the manifest's "label". The manifest
format is described in README.md ("Session manifest"). For every step id:

- NN-id-before.png / NN-id-after.png: the stills side by side, at the same
  pixel scale (an image captured at a lower scale is enlarged, and the sheet
  says so).
- NN-id-strip.png: frames from each video at fixed intervals from the
  moment the step's first action was sent, one row per manifest.
- NN-id-detail.png: the same frames cropped to the region that changed.
- NN-id-timing.json / NN-id-timing.png: motion.py's measurement of each video
  and the curves overlaid.
- index.html: everything above on one page, with the measured durations.
"""

import argparse
import bisect
import html
import json
import pathlib
import sys

from PIL import Image, ImageDraw

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import motion  # noqa: E402

SURFACE = (252, 252, 251)
INK = (11, 11, 11)
INK_2 = (82, 81, 78)
RULE = (226, 225, 221)
GUTTER = 24
HEADER = 44


def load(manifest_path):
    path = pathlib.Path(manifest_path).resolve()
    m = json.loads(path.read_text())
    m["_dir"] = path.parent
    return m


def side_meta(directory, name):
    meta = directory / (name + ".json")
    return json.loads(meta.read_text()) if meta.exists() else {}


def scale_of(directory, name):
    return float(side_meta(directory, name).get("pixel_scale", 1.0)) if name else 1.0


def label_bar(draw, x, y, width, text, note=""):
    draw.text((x, y + HEADER / 2), text, fill=INK, font=motion.font(20), anchor="lm")
    if note:
        draw.text((x + width, y + HEADER / 2), note, fill=INK_2, font=motion.font(13), anchor="rm")


def side_by_side(images, labels, notes, out):
    """Images next to each other, tops aligned, each under its label."""
    width = sum(im.width for im in images) + GUTTER * (len(images) + 1)
    height = max(im.height for im in images) + HEADER + GUTTER * 2
    sheet = Image.new("RGB", (width, height), SURFACE)
    draw = ImageDraw.Draw(sheet)
    x = GUTTER
    for im, label, note in zip(images, labels, notes):
        label_bar(draw, x, GUTTER // 2, im.width, label, note)
        sheet.paste(im, (x, GUTTER + HEADER), im if im.mode == "RGBA" else None)
        x += im.width + GUTTER
    sheet.save(out)
    return out


def at_scale(image, scale, target):
    if abs(scale - target) < 1e-6:
        return image, ""
    factor = target / scale
    return image.resize((round(image.width * factor), round(image.height * factor)), Image.Resampling.LANCZOS), \
        f"captured at {scale:g}x, shown at {target:g}x"


def frames_at(video, times):
    """The frame on screen at each time (the last one presented at or before it)."""
    width, height, pts = motion.probe(video)
    wanted = {}
    for t in times:
        i = bisect.bisect_right(pts, t + 1e-6) - 1
        wanted.setdefault(max(0, i), []).append(t)
    out = {}
    for i, frame in enumerate(motion.decode(video, width, height)):
        if i in wanted:
            for t in wanted[i]:
                out[t] = Image.fromarray(frame)
        if i >= max(wanted):
            break
    return [out.get(t) for t in times], pts


def strip(rows, labels, times_ms, out, crop=None, thumb_width=640, per_row=4):
    """rows: one list of PIL images per manifest; crop in video px (per row).
    Times run left to right in bands of per_row frames; within a band each
    manifest has its own line, so the same instant sits in one column."""
    cells = []
    for row, c in zip(rows, crop or [None] * len(rows)):
        cells.append([None if im is None else (im.crop(c) if c else im) for im in row])
    sample = next(im for row in cells for im in row if im is not None)
    tw = min(thumb_width, sample.width)
    th = round(sample.height * tw / sample.width)
    label_w, gap, time_h = 130, 8, 26
    bands = [list(range(i, min(i + per_row, len(times_ms)))) for i in range(0, len(times_ms), per_row)]
    band_h = time_h + len(cells) * (th + gap) + GUTTER
    width = label_w + per_row * (tw + gap) + GUTTER
    sheet = Image.new("RGB", (width, len(bands) * band_h + GUTTER), SURFACE)
    draw = ImageDraw.Draw(sheet)
    for b, band in enumerate(bands):
        top = GUTTER + b * band_h
        for col, j in enumerate(band):
            x = label_w + col * (tw + gap)
            t = times_ms[j]
            draw.text((x, top + time_h / 2), f"{t:+.0f} ms", fill=INK_2 if t < 0 else INK, font=motion.font(14),
                      anchor="lm")
        for i, (row, label) in enumerate(zip(cells, labels)):
            y = top + time_h + i * (th + gap)
            draw.text((GUTTER // 2, y + th / 2), label, fill=INK, font=motion.font(15), anchor="lm")
            for col, j in enumerate(band):
                x = label_w + col * (tw + gap)
                im = row[j]
                if im is None:
                    draw.rectangle([x, y, x + tw, y + th], outline=RULE)
                    continue
                sheet.paste(im.convert("RGB").resize((tw, th), Image.Resampling.LANCZOS), (x, y))
    sheet.save(out)
    return out


def step_ids(manifests):
    seen, order = set(), []
    for m in manifests:
        for s in m["steps"]:
            if s["id"] not in seen:
                seen.add(s["id"]); order.append((s["index"], s["id"]))
    return order


def compare(manifest_paths, out_dir, interval_ms=1000 / 30, frame_count=16, timing_window=3.0):
    manifests = [load(p) for p in manifest_paths]
    labels = [m.get("label", m.get("target", "?")) for m in manifests]
    out = pathlib.Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    report = []
    for index, sid in step_ids(manifests):
        name = f"{index:02d}-{sid}"
        steps = [next((s for s in m["steps"] if s["id"] == sid), None) for m in manifests]
        item = {"name": name, "note": next((s.get("note", "") for s in steps if s), ""), "files": {}, "timing": []}
        # stills
        for kind in ("before", "after"):
            present = [(m, s) for m, s in zip(manifests, steps) if s and s.get(f"still_{kind}")]
            if not present:
                continue
            scales = [scale_of(m["_dir"], s[f"still_{kind}"]) for m, s in present]
            target = max(scales)
            ims, notes = [], []
            for (m, s), sc in zip(present, scales):
                im, note = at_scale(Image.open(m["_dir"] / s[f"still_{kind}"]), sc, target)
                ims.append(im); notes.append(note)
            item["files"][kind] = side_by_side(ims, [m.get("label", "?") for m, _ in present], notes,
                                               out / f"{name}-{kind}.png").name
        # videos: timing, then strips around the action
        present = [(m, s) for m, s in zip(manifests, steps) if s and s.get("video")]
        if not present:
            report.append(item); continue
        results, rows, crops, row_labels = [], [], [], []
        times_ms = [(k - 1) * interval_ms for k in range(frame_count)]
        for m, s in present:
            video = m["_dir"] / s["video"]
            t0 = s.get("t_action_in_video") or 0.0
            r = motion.analyze(video, start=max(0.0, t0 - 0.05), end=t0 + timing_window)
            r["label"] = m.get("label", "?")
            r["t_action_in_video"] = t0
            prim = r.get("primary")
            if prim:
                prim["latency_ms"] = (prim["start_s"] - t0) * 1000
            results.append(r)
            frames, _ = frames_at(video, [t0 + t / 1000 for t in times_ms])
            rows.append(frames); row_labels.append(m.get("label", "?"))
            crops.append(tuple(_pad(prim["bbox_px"], frames)) if prim and prim.get("bbox_px") else None)
            item["timing"].append({"label": r["label"], "duration_ms": prim and round(prim["duration_ms"], 1),
                                   "latency_ms": prim and round(prim["latency_ms"], 1),
                                   "easing": prim and prim.get("easing"),
                                   "progress_method": prim and prim.get("progress_method")})
        (out / f"{name}-timing.json").write_text(json.dumps(results, indent=1))
        motion.plot(results, out / f"{name}-timing.png", [r["label"] for r in results])
        item["files"]["timing"] = f"{name}-timing.png"
        item["files"]["timing_json"] = f"{name}-timing.json"
        if any(any(f is not None for f in row) for row in rows):
            item["files"]["strip"] = strip(rows, row_labels, times_ms, out / f"{name}-strip.png").name
            if all(crops) and _worth_detail(crops, rows):
                item["files"]["detail"] = strip(rows, row_labels, times_ms, out / f"{name}-detail.png", crops).name
        report.append(item)
    (out / "summary.json").write_text(json.dumps({"labels": labels, "steps": report}, indent=1))
    return write_index(out, labels, report)


def _pad(box, frames):
    sample = next((f for f in frames if f is not None), None)
    x, y, w, h = box
    pad = 24
    if sample is None:
        return x, y, x + w, y + h
    return max(0, x - pad), max(0, y - pad), min(sample.width, x + w + pad), min(sample.height, y + h + pad)


def _worth_detail(crops, rows):
    for c, row in zip(crops, rows):
        sample = next((f for f in row if f is not None), None)
        if sample and (c[2] - c[0]) * (c[3] - c[1]) < 0.6 * sample.width * sample.height:
            return True
    return False


def write_index(out, labels, report):
    def fmt(t):
        if not t["duration_ms"]:
            return "no change found"
        text = f"{t['duration_ms']:.0f} ms (starts {t['latency_ms']:.0f} ms after the action)"
        e = t.get("easing")
        if e:
            b, sp = e["cubic_bezier"], e["spring"]
            text += (f"; Bezier ({b['x1']}, {b['y1']}, {b['x2']}, {b['y2']}) rmse {b['rmse']}"
                     f"; spring response {sp['response_s']} s, damping {sp['damping_fraction']} rmse {sp['rmse']}"
                     f"; by {t['progress_method']}")
        return text
    parts = ["<!doctype html><meta charset=utf-8><title>Capture comparison</title>",
             "<style>body{font:14px system-ui;margin:24px;background:#fcfcfb;color:#0b0b0b}"
             "img{max-width:100%;border:1px solid #e2e1dd;margin:6px 0}h2{margin-top:40px}"
             "td,th{padding:4px 10px;text-align:left;vertical-align:top}</style>",
             f"<h1>{html.escape(' vs '.join(labels))}</h1>"]
    for item in report:
        parts.append(f"<h2>{html.escape(item['name'])}</h2><p>{html.escape(item['note'])}</p>")
        if item["timing"]:
            parts.append("<table><tr><th></th><th>Measured change</th></tr>" + "".join(
                f"<tr><td>{html.escape(t['label'])}</td><td>{html.escape(fmt(t))}</td></tr>" for t in item["timing"])
                + "</table>")
        for key in ("before", "after", "strip", "detail", "timing"):
            if key in item["files"]:
                parts.append(f"<h3>{key}</h3><img src='{item['files'][key]}'>")
    index = out / "index.html"
    index.write_text("\n".join(parts))
    return index


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("out_dir")
    ap.add_argument("manifests", nargs="+")
    ap.add_argument("--interval", type=float, default=1000 / 30, help="ms between strip frames")
    ap.add_argument("--frames", type=int, default=16, help="frames per strip")
    a = ap.parse_args()
    print(compare(a.manifests, a.out_dir, a.interval, a.frames))


if __name__ == "__main__":
    main()

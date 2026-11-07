#!/usr/bin/env python3
"""Extra comparison sheets for a session: the stills taken in the middle of
a step ("snap" actions: NN-step-<name>.png) and a detail of the after stills
(a step's "crop" [x, y, w, h] in window points, enlarged 2x: NN-step-crop.png).

    python3 -I research/tools/capture/extra_sheets.py OUT_DIR MANIFEST [MANIFEST ...]

Manifests in left-to-right order (Xcode first). Uses the sheet helpers of
tools/capture/sheets.py.
"""

import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "tools" / "capture"))
import sheets  # noqa: E402
from PIL import Image  # noqa: E402


def extras(manifest_paths, out_dir):
    manifests = [sheets.load(p) for p in manifest_paths]
    out = pathlib.Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    made = []
    for index, sid in sheets.step_ids(manifests):
        name = f"{index:02d}-{sid}"
        steps = [next((s for s in m["steps"] if s["id"] == sid), None) for m in manifests]
        for snap in dict.fromkeys(k for s in steps if s for k in (s.get("snaps") or {})):
            present = [(m, s) for m, s in zip(manifests, steps) if s and (s.get("snaps") or {}).get(snap)]
            scales = [sheets.scale_of(m["_dir"], s["snaps"][snap]) for m, s in present]
            ims, notes = [], []
            for (m, s), sc in zip(present, scales):
                im, note = sheets.at_scale(Image.open(m["_dir"] / s["snaps"][snap]), sc, max(scales))
                ims.append(im); notes.append(note)
            made.append(sheets.side_by_side(ims, [m.get("label", "?") for m, _ in present], notes,
                                            out / f"{name}-{snap}.png"))
        crop = next((s.get("crop") for s in steps if s and s.get("crop")), None)
        present = [(m, s) for m, s in zip(manifests, steps) if s and s.get("still_after")]
        if crop and present:
            top = max(sheets.scale_of(m["_dir"], s["still_after"]) for m, s in present)
            ims = []
            for m, s in present:
                sc = sheets.scale_of(m["_dir"], s["still_after"])
                x, y, w, h = (round(v * sc) for v in crop)
                im = Image.open(m["_dir"] / s["still_after"]).crop((x, y, x + w, y + h))
                f = 2 * top / sc
                ims.append(im.resize((round(im.width * f), round(im.height * f)), Image.NEAREST))
            made.append(sheets.side_by_side(ims, [m.get("label", "?") for m, _ in present],
                                            ["enlarged 2x"] * len(ims), out / f"{name}-crop.png"))
    return made


if __name__ == "__main__":
    for path in extras(sys.argv[2:], sys.argv[1]):
        print(path)

#!/usr/bin/env python3
"""Turns layout-probe reports (scripts/layout-probe.sh) into Markdown tables.

Usage: python3 -I scripts/layout-probe-table.py <probe.json> [<probe.json> ...]
           [--frames] [--only-misses]

One column per report (headed by its macOS version and backing scale), each
measure against its spec value, with the delta (value - spec; "ok" or "miss"
for a bound). A miss (outside the spec's tolerance) is marked with "!".
--frames adds every recorded frame; --only-misses keeps the rows with a miss.
"""

import json
import sys


def fmt(v):
    if v is None:
        return "-"
    return f"{v:.1f}".rstrip("0").rstrip(".") if abs(v - round(v)) > 1e-9 else str(int(round(v)))


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def main(argv):
    show_frames = "--frames" in argv
    only_misses = "--only-misses" in argv
    paths = [a for a in argv if not a.startswith("--")]
    if not paths:
        print(__doc__, file=sys.stderr)
        return 2
    reports = [load(p) for p in paths]
    heads = [f"macOS {r['macOSVersion']} ({fmt(r['backingScale'])}x)" for r in reports]

    print("| Report | macOS | Backing scale | Glass layout | Windows shown | Screen |")
    print("|---|---|---|---|---|---|")
    for h, r in zip(heads, reports):
        s = r.get("screen") or {}
        print(f"| {h} | {r['macOS']} | {fmt(r['backingScale'])} | {r['glass']} | {r['shown']} "
              f"| {fmt(s.get('w'))} x {fmt(s.get('h'))} |")
    for r in reports:
        for n in r.get("notes", []):
            print(f"\nNote ({r['macOSVersion']}): {n}")
    print()

    names = []
    for r in reports:
        for m in r["measures"]:
            if m["name"] not in names:
                names.append(m["name"])
    by = [{m["name"]: m for m in r["measures"]} for r in reports]
    cols = " | ".join(f"{h} | delta" for h in heads)
    print(f"| Element | Spec | {cols} | Source |")
    print("|---|---|" + "---|---|" * len(reports) + "---|")
    for n in names:
        ms = [b.get(n) for b in by]
        first = next(m for m in ms if m)
        if only_misses and all(m is None or m.get("ok") is not False for m in ms):
            continue
        spec = first.get("spec")
        op = first["op"]
        spec_text = "-" if spec is None else (fmt(spec) if op == "=" else f"{op} {fmt(spec)}")
        if spec is not None and first["tolerance"]:
            spec_text += f" (±{fmt(first['tolerance'])})"
        cells = []
        for m in ms:
            if m is None:
                cells += ["-", "-"]
                continue
            mark = " !" if m.get("ok") is False else ""
            if m.get("spec") is not None and m["op"] != "=":
                delta = "miss" if m.get("ok") is False else "ok"
            else:
                delta = fmt(m.get("delta"))
            cells += [fmt(m["value"]) + mark, delta]
        print(f"| {n} | {spec_text} | " + " | ".join(cells) + f" | {first['source']} |")

    if show_frames:
        print()
        keys = sorted({k for r in reports for k in r["frames"]})
        print("| Frame (x, y, w, h) | " + " | ".join(heads) + " |")
        print("|---|" + "---|" * len(reports))
        for k in keys:
            cells = []
            for r in reports:
                f = r["frames"].get(k)
                cells.append("-" if f is None else f"{fmt(f['x'])}, {fmt(f['y'])}, {fmt(f['w'])}, {fmt(f['h'])}")
            print(f"| {k} | " + " | ".join(cells) + " |")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

"""Summarise HealthProbe live sessions as aggregates only.

Reads `<out>/live/*.jsonl` written by healthprobe_receiver.py and writes
`<out>/live-summary.json`. The file and the console get counts, cadences (spacing between
sample start offsets), delivery delays and value quantiles (only with at least MIN_N
samples, never min or max), plus metadata key names with counts.

Usage: python3 -I summarize_live.py --out <dir>
"""
import argparse
import glob
import json
import math
import os
from collections import Counter, defaultdict

MIN_N = 10


def sig(x, d=4):
    if x is None or not math.isfinite(x):
        return None
    if x == 0:
        return 0.0
    return round(x, -int(math.floor(math.log10(abs(x)))) + d - 1)


def pct(sorted_vals, p):
    if not sorted_vals:
        return None
    k = (len(sorted_vals) - 1) * p / 100
    lo, hi = math.floor(k), math.ceil(k)
    return sorted_vals[lo] + (sorted_vals[hi] - sorted_vals[lo]) * (k - lo)


def q(vals):
    v = sorted(x for x in vals if x is not None and math.isfinite(x))
    n = len(v)
    if n < MIN_N:
        return {"n": n}
    mean = sum(v) / n
    sd = math.sqrt(sum((x - mean) ** 2 for x in v) / n)
    return {"n": n, "mean": sig(mean), "sd": sig(sd), **{f"p{p}": sig(pct(v, p)) for p in (5, 25, 50, 75, 95)}}


def summarize(events):
    out = {"events": len(events), "kinds": dict(Counter(e.get("kind") for e in events)),
           "transports": dict(Counter(e.get("transport") for e in events if e.get("transport"))),
           "session_notes": [e.get("note") for e in sorted(events, key=lambda e: e.get("seq", 0))
                             if e.get("kind") == "session" and e.get("origin") == "watch"]}
    groups = defaultdict(list)
    for e in events:
        if e.get("type"):
            groups[(e.get("kind"), e.get("type"))].append(e)
    per = {}
    for (kind, typ), es in sorted(groups.items()):
        starts = sorted(e["startOffset"] for e in es if "startOffset" in e)
        r = {"count": len(es), "units": dict(Counter(e.get("unit") for e in es if e.get("unit"))),
             "metadata_key_counts": dict(Counter(k for e in es for k in e.get("metadataKeys", []))),
             "spacing_s": q([b - a for a, b in zip(starts, starts[1:])]),
             "duration_s": q([e["endOffset"] - e["startOffset"] for e in es if "endOffset" in e and "startOffset" in e]),
             "delivery_delay_s": q([e["deliveredOffset"] - e["endOffset"] for e in es
                                    if "deliveredOffset" in e and "endOffset" in e]),
             "phone_receive_delay_s": q([e["phoneReceivedOffset"] - e["deliveredOffset"] for e in es
                                         if "phoneReceivedOffset" in e and "deliveredOffset" in e]),
             "value": q([e.get("value") for e in es]),
             "series_count": q([e.get("seriesCount") for e in es])}
        per[f"{kind}:{typ}"] = r
    out["by_kind_and_type"] = per
    return out


def main(out_dir):
    res = {}
    for i, path in enumerate(sorted(glob.glob(os.path.join(out_dir, "live", "*.jsonl")))):
        with open(path) as f:
            events = [json.loads(line) for line in f if line.strip()]
        res[f"session_{i + 1}"] = summarize(events)
    with open(os.path.join(out_dir, "live-summary.json"), "w") as f:
        json.dump(res, f, indent=1, sort_keys=True)
    print(json.dumps(res, indent=1, sort_keys=True))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    main(ap.parse_args().out)

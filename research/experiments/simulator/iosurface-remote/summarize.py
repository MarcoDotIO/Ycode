#!/usr/bin/env python3 -I
"""Summarize isproxy logs (original Ycode code, R5).

For each log: number of connections, count of requests per Method, the keys
seen per Method in requests and replies, ErrorCode values per Method, and the
distinct creation-property sets (Method 2 with PropertiesDictionary), with
the reply's shmem size and SurfaceState words. Usage: summarize.py <log>...
"""
import re
import sys
from collections import Counter, defaultdict


def messages(path):
    cur = None
    with open(path, errors="replace") as f:
        for line in f:
            if line.startswith("== #"):
                if cur:
                    yield cur
                cur = {"head": line.rstrip(), "lines": []}
            elif cur is not None:
                cur["lines"].append(line.rstrip("\n"))
    if cur:
        yield cur


def top_keys(lines):
    keys = {}
    for i, l in enumerate(lines):
        m = re.match(r'^    "([^"]+)" = (.*)$', l)
        if m:
            keys[m.group(1)] = (m.group(2), i)
    return keys


def main():
    for path in sys.argv[1:]:
        msgs = list(messages(path))
        meth = Counter()
        req_keys = defaultdict(set)
        rep_keys = defaultdict(set)
        errs = defaultdict(Counter)
        creates = Counter()
        create_examples = {}
        conns = sum(1 for m in msgs if "HANDSHAKE" in m["head"])
        pending = {}
        async_keys = Counter()
        for m in msgs:
            on = re.search(r" on=(0x[0-9a-f]+)", m["head"])
            on = on.group(1) if on else None
            rp = None
            for l in m["lines"]:
                r = re.search(r"reply right send-once proxied by (0x[0-9a-f]+)", l)
                if r:
                    rp = r.group(1)
            k = top_keys(m["lines"])
            if " C>S" in m["head"] and "HANDSHAKE" not in m["head"]:
                mv = k.get("Method", ("?",))[0]
                mnum = re.search(r"uint64 (\d+)", mv)
                mnum = int(mnum.group(1)) if mnum else -1
                meth[mnum] += 1
                req_keys[mnum].update(k.keys())
                if rp:
                    pending[rp] = mnum
                if mnum == 2 and "PropertiesDictionary" in k:
                    i = k["PropertiesDictionary"][1]
                    props = []
                    for l in m["lines"][i + 1:]:
                        if not l.startswith("      "):
                            break
                        props.append(l.strip())
                    sig = " | ".join(p for p in props if "IOSurfaceName" not in p)
                    creates[sig] += 1
                    nm = [p for p in props if "IOSurfaceName" in p]
                    create_examples.setdefault(sig, nm)
                elif mnum == 2:
                    creates["(lookup: " + ",".join(sorted(set(k) - {"Method"})) + ")"] += 1
            elif "S>C (reply)" in m["head"] and on in pending:
                mnum = pending.pop(on)
                rep_keys[mnum].update(k.keys())
                if "ErrorCode" in k:
                    errs[mnum][k["ErrorCode"][0].split()[1]] += 1
            elif "S>C" in m["head"]:
                async_keys[",".join(sorted(k))] += 1
        print(f"### {path}\n  messages {len(msgs)}, connections {conns}")
        for mnum in sorted(meth):
            print(f"  Method {mnum}: {meth[mnum]} requests; req keys {sorted(req_keys[mnum])}; "
                  f"reply keys {sorted(rep_keys[mnum])}; ErrorCode {dict(errs[mnum])}")
        for ks, n in async_keys.most_common():
            print(f"  server-initiated or unpaired: {n} x keys [{ks}]")
        print("  creates:")
        for sig, n in creates.most_common():
            print(f"    {n:4d} x {sig}  {create_examples.get(sig, '')}")


if __name__ == "__main__":
    main()

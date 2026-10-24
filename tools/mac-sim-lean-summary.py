#!/usr/bin/env python3
"""Summarizes tools/mac-sim-lean-boot.py output directories.

Usage: python3 -I tools/mac-sim-lean-summary.py [--diff A B] DIR [DIR...]

Prints, per group (device name without its run number, e.g.
ycode-test-L2-full) and boot (first/second): n, home_s (each, mean, sd),
bootstatus_s mean, processes alive at the sample time and distinct
processes seen, device CPU seconds in the sample window, launchd spawns (all programs,
whole TMP/launchd.log of the boot), crash reports
(by process), and `others` (mean cores used by
everything outside the device during the boot: contention); then, for the 23 lean labels, the CPU seconds and launchd
spawn counts of their programs in the `full` group (what the Mac spends on
them); then, with --diff A B (two group names, default the `full` and
`lean` groups), the process names whose mean CPU differs most between the
two, per boot (what accounts for the difference).
"""
import glob, json, os, re, statistics, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
text = open(os.path.join(ROOT, "ycode/Sources/ycode-simd/LeanBoot.swift")).read()
LABELS = re.findall(r'"([^"]+)"', re.search(r"defaultDisabledLabels: \[String\] = \[(.*?)\n    \]", text, re.S).group(1))


def program(label):
    name = label[len("com.apple."):] if label.startswith("com.apple.") else label
    return name.split(".", 1)[1] if name.startswith("accessibility.") else name


PROGRAMS = {program(l) for l in LABELS}


def proc_name(key):
    name = key.rsplit("[", 1)[0]
    return "launchd_sim" if name == "launchd_bootstrap.plist" else name


def mean(xs):
    xs = [x for x in xs if x is not None]
    return round(statistics.mean(xs), 1) if xs else None


def sd(xs):
    xs = [x for x in xs if x is not None]
    return round(statistics.stdev(xs), 1) if len(xs) > 1 else None


args = sys.argv[1:]
diff = None
if args[:1] == ["--diff"]:
    diff, args = (args[1], args[2]), args[3:]

def dedupe(cpu):
    """One entry per pid, named after the program it ran last. CPU time is
    cumulative per pid, so the largest value is the latest. The same pid
    can appear under several keys: as xpcproxy_sim and then as the daemon
    it exec'd (same pid), and, once it has exited but is not yet reaped, as
    "(name)" with the name cut to 16 characters. A pid only ever seen as
    "(name)" takes the full name of another process of the boot that starts
    with it."""
    by_pid = {}
    for k, v in cpu.items():
        name, pid = k.rsplit("[", 1)
        by_pid.setdefault(pid, []).append((v, not name.startswith("("), name))
    names = {n for entries in by_pid.values() for _, full, n in entries if full}
    out = {}
    for pid, entries in by_pid.items():
        v = max(e[0] for e in entries)
        full = [e for e in entries if e[1]]
        n = max(full)[2] if full else entries[0][2]
        if n.startswith("(") and n.endswith(")"):
            short = n[1:-1]
            n = next((m for m in sorted(names) if m.startswith(short)), short)
        out[f"{n}[{pid}"] = v
    return out


results = []
for d in args:
    for f in sorted(glob.glob(os.path.join(d, "*", "result.json"))):
        r = json.load(open(f))
        for b in r["boots"]:
            b["cpu"] = dedupe(b["cpu"])
            b["procs_seen"] = len(b["cpu"]) if "procs_seen" in b else None
            b["cpu_total_s"] = round(sum(b["cpu"].values()), 1)
        results.append(r)

groups = {}
for r in results:
    g = r["name"].rsplit("-", 1)[0]
    for b in r["boots"]:
        groups.setdefault((g, b["tag"]), []).append(b)

print(f"{'group':28} boot    n  {'home_s (each)':34}  mean    sd  bootst  procs  seen  cpu_s  spawns  crashes  others")
for (g, tag), bs in sorted(groups.items()):
    homes = [b["home_s"] for b in bs]
    print(f"{g:28} {tag:6} {len(bs):2}  {str(homes):34} {mean(homes)!s:>5} {sd(homes)!s:>5}"
          f" {mean([b['bootstatus_s'] for b in bs])!s:>7} {mean([b['procs'] for b in bs])!s:>6}"
          f" {mean([b.get('procs_seen') for b in bs])!s:>5} {mean([b['cpu_total_s'] for b in bs])!s:>6} {mean([sum(b['spawns'].values()) for b in bs])!s:>7}"
          f" {sum(b['crashes'] for b in bs):>8}  {mean([b.get('others_cores') for b in bs])!s:>6}")

print("\nCrash reports by process (all boots of the group):")
for (g, tag), bs in sorted(groups.items()):
    c = {}
    for b in bs:
        for n in b["crash_reports"]:
            p = n.split("@", 1)[0].split("-2026", 1)[0]
            c[p] = c.get(p, 0) + 1
    if c:
        print(f"  {g} {tag}: " + ", ".join(f"{k} {v}" for k, v in sorted(c.items(), key=lambda kv: -kv[1])))

full_groups = sorted({g for g, _ in groups if g.endswith("-full")})
for fg in full_groups:
    print(f"\nThe 23 lean labels in {fg} (mean per boot): CPU s in the sample window / launchd spawns")
    for tag in ("first", "second"):
        bs = groups.get((fg, tag), [])
        if not bs:
            continue
        rows = []
        for label in LABELS:
            prog = program(label)
            cpu = mean([sum(v for k, v in b["cpu"].items() if proc_name(k) == prog) for b in bs])
            sp = mean([b["spawns"].get(prog, 0) for b in bs])
            rows.append((cpu or 0, sp or 0, label))
        total = mean([b["cpu_total_s"] for b in bs])
        lab = sum(r[0] for r in rows)
        print(f"  {tag} boot (device total {total} s, the 23 programs {lab:.1f} s):")
        for cpu, sp, label in sorted(rows, key=lambda r: (-r[0], -r[1])):
            print(f"    {label:42} cpu {cpu:6.2f}  spawns {sp:5.1f}")


def by_name(bs):
    """Mean CPU seconds per process name (a boot without it counts 0)."""
    per_boot = []
    for b in bs:
        per = {}
        for k, v in b["cpu"].items():
            per[proc_name(k)] = per.get(proc_name(k), 0) + v
        per_boot.append(per)
    names = set().union(*per_boot)
    return {n: statistics.mean(p.get(n, 0.0) for p in per_boot) for n in names}


if diff is None and full_groups:
    base = full_groups[0][:-len("-full")]
    if (base + "-lean", "first") in groups:
        diff = (base + "-full", base + "-lean")
if diff:
    a, b = diff
    for tag in ("first", "second"):
        A, B = groups.get((a, tag)), groups.get((b, tag))
        if not A or not B:
            continue
        ma, mb = by_name(A), by_name(B)
        names = set(ma) | set(mb)
        rows = sorted(((ma.get(n, 0) - mb.get(n, 0), n) for n in names), key=lambda r: -abs(r[0]))
        tot = sum(ma.values()) - sum(mb.values())
        lab = sum(d for d, n in rows if n in PROGRAMS)
        print(f"\nCPU difference {a} - {b}, {tag} boot: total {tot:+.1f} s; "
              f"the 23 programs {lab:+.1f} s; all other processes {tot - lab:+.1f} s. Largest:")
        for d, n in rows[:25]:
            mark = " (lean label)" if n in PROGRAMS else ""
            print(f"    {n:44} {d:+7.2f}  ({ma.get(n, 0):.2f} vs {mb.get(n, 0):.2f}){mark}")

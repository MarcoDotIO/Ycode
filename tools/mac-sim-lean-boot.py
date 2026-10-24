#!/usr/bin/env python3
"""Black-box boot measurements of Apple's iOS Simulator on this Mac, with
the same lean profile Ycode uses (specs/simulator/lean-boot.md,
specs/simulator/parity-ladder.md). Uses only `xcrun simctl`, `ps` and files
the simulator writes (read as formats). Never touches devices it did not
create: every device it makes is named <prefix>-<mode>-<n> and deleted at
the end (unless --keep-device).

Usage:
  python3 -I tools/mac-sim-lean-boot.py --mode full|lean|lean-log --runs N --out DIR
         [--keep label,label]       # lean: these labels stay enabled (ladder step base+k)
         [--enable label,label]     # lean: only these are disabled (all-but-one with one label)
         [--order full,lean,...]    # interleave several modes, N rounds each
         [--sample-at 120] [--second-sample-at S] [--cpu-every 5] [--timeout 900] [--prefix ycode-test-L]

Per boot (first boot of a new device, then a second boot of the same device):
  home_s     first screenshot whose mean brightness (grey, 70x102) is > 60, the
             end point of Ycode's harness (SX/bin/homewatch.py); polled about
             once a second from the moment `simctl bootstatus -b` starts
  bootstatus_s  when `simctl bootstatus -b` returns
  cpu        per-process CPU seconds of the device's processes (descendants of
             the device's launchd_sim), sampled with `ps` every --cpu-every s
             until --sample-at s; the last value seen per pid, so processes
             that exited early count with the CPU they had at their last
             sample (at most --cpu-every s of work is missed per process)
  procs      number of those processes alive at --sample-at s
  procs_seen distinct pids seen in the first --sample-at s
  spawns     launchd's "Successfully spawned" count per program (TMP/launchd.log)
  crashes    crash reports in ~/Library/Logs/DiagnosticReports (and Retired/)
             that name the device UDID and whose header timestamp lies in the
             boot's window (boot start to end of measurement)
  others_booted, others_cores
             contention: other booted simulator devices at the start, and the
             mean number of cores used by all processes outside this device
             during the window (from cumulative `ps` CPU times)
--second-sample-at lengthens the second boot's window (e.g. 700 s, the length
of a Ycode harness run) to compare restart counts over the same wall time.
The lists come from ycode/Sources/ycode-simd/LeanBoot.swift, so the Mac and
Ycode always use the same labels and subsystems.
"""
import argparse, json, os, plistlib, re, shutil, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LEAN_SWIFT = os.path.join(ROOT, "ycode/Sources/ycode-simd/LeanBoot.swift")
DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-27-1"
DEVICES = os.path.expanduser("~/Library/Developer/CoreSimulator/Devices")
REPORTS = os.path.expanduser("~/Library/Logs/DiagnosticReports")


def swift_list(name):
    text = open(LEAN_SWIFT).read()
    m = re.search(r"static let " + name + r": \[String\] = \[(.*?)\n    \]", text, re.S)
    return re.findall(r'"([^"]+)"', m.group(1))


LABELS = swift_list("defaultDisabledLabels")
SUBSYSTEMS = swift_list("loggingOffSubsystems")


def run(*args, timeout=600, check=True):
    p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if check and p.returncode != 0:
        raise RuntimeError(f"{' '.join(args)}: {p.returncode} {p.stderr.strip()}")
    return p.stdout.strip()


def tmp_dir(udid):
    return f"/private/var/tmp/com.apple.CoreSimulator.SimDevice.{udid}"


def brightness(path):
    from PIL import Image, ImageStat
    im = Image.open(path).convert("L").resize((70, 102))
    return ImageStat.Stat(im).mean[0]


def parse_cputime(s):
    # [[dd-]hh:]mm:ss.cc
    days = 0
    if "-" in s:
        d, s = s.split("-", 1); days = int(d)
    parts = [float(x) for x in s.split(":")]
    sec = 0.0
    for x in parts:
        sec = sec * 60 + x
    return days * 86400 + sec


def device_processes(udid):
    out = run("ps", "-axww", "-o", "pid=,ppid=,time=,command=")
    rows = []
    for line in out.splitlines():
        p = line.split(None, 3)
        if len(p) < 4:
            continue
        rows.append((int(p[0]), int(p[1]), parse_cputime(p[2]), p[3]))
    roots = [r[0] for r in rows if "launchd_sim" in r[3] and udid in r[3]]
    children = {}
    for pid, ppid, _, _ in rows:
        children.setdefault(ppid, []).append(pid)
    keep, todo = set(roots), list(roots)
    while todo:
        for c in children.get(todo.pop(), []):
            if c not in keep:
                keep.add(c); todo.append(c)
    # Names from the executable path (`comm`); runtime paths contain spaces,
    # so the argument list cannot be split reliably.
    comm = {}
    for line in run("ps", "-axww", "-o", "pid=,comm=").splitlines():
        p = line.strip().split(None, 1)
        if len(p) == 2:
            comm[int(p[0])] = os.path.basename(p[1])
    procs = {}
    for pid, ppid, cpu, cmd in rows:
        if pid in keep:
            procs[f"{comm.get(pid, cmd[:40])}[{pid}]"] = cpu
    return procs


def host_context(udid):
    """Contention covariates: other booted simulator devices, and the CPU
    seconds used so far by every process outside this device (cumulative,
    so a difference over the window gives the cores others used)."""
    booted = sum(1 for line in run("xcrun", "simctl", "list", "devices", "booted", check=False).splitlines()
                 if "(Booted)" in line and udid not in line)
    total = 0.0
    for line in run("ps", "-axo", "time=").splitlines():
        try:
            total += parse_cputime(line.strip())
        except ValueError:
            pass
    return booted, total


def launchd_log_stats(udid):
    path = os.path.join(tmp_dir(udid), "launchd.log")
    spawns, exits = {}, {}
    try:
        for line in open(path, errors="replace"):
            m = re.search(r"Successfully spawned ([^\[]+)\[\d+\] because (.*)$", line)
            if m:
                spawns[m.group(1)] = spawns.get(m.group(1), 0) + 1
            m = re.search(r"\((?:user/\d+|system)/([^ \[\)]+)(?: \[\d+\])?\) <Notice>: exited (.*)$", line)
            if m:
                key = m.group(1) + ": " + m.group(2)[:60]
                exits[key] = exits.get(key, 0) + 1
    except OSError:
        pass
    return spawns, exits


def _ips_time(path):
    """Header timestamp of a .ips report ("YYYY-MM-DD HH:MM:SS.ss +ZZZZ")."""
    from datetime import datetime
    try:
        with open(path, "rb") as f:
            head = json.loads(f.readline())
        return datetime.strptime(head["timestamp"], "%Y-%m-%d %H:%M:%S.%f %z").timestamp(), head.get("name") or head.get("app_name")
    except Exception:
        return None, None


def crash_reports(udid, since, until):
    names = []
    for d in (REPORTS, os.path.join(REPORTS, "Retired")):
        try:
            entries = os.listdir(d)
        except OSError:
            continue
        for f in entries:
            p = os.path.join(d, f)
            try:
                if not f.endswith(".ips") or os.path.getmtime(p) < since - 5:
                    continue
                if udid.encode() not in open(p, "rb").read():
                    continue
            except OSError:
                continue
            t, proc = _ips_time(p)
            if t is None or since - 1 <= t <= until + 1:
                names.append(f"{proc or f}@{round(t - since, 1) if t else '?'}s")
    return len(names), sorted(names)


def write_lean(udid, mode, keep, enable):
    labels = [l for l in (enable if enable is not None else LABELS) if l not in keep]
    if mode in ("lean", "lean-log") and labels:
        d = tmp_dir(udid)
        os.makedirs(d, mode=0o700, exist_ok=True)
        path = os.path.join(d, "disabled.plist")
        current = {}
        if os.path.exists(path):
            current = plistlib.load(open(path, "rb"))
        for l in labels:
            current.setdefault(l, True)
        plistlib.dump(current, open(path, "wb"))
    if mode == "lean-log":
        sub = os.path.join(DEVICES, udid, "data/Library/Preferences/Logging/Subsystems")
        os.makedirs(sub, exist_ok=True)
        for s in SUBSYSTEMS:
            p = os.path.join(sub, s + ".plist")
            if not os.path.exists(p):
                plistlib.dump({"DEFAULT-OPTIONS": {"Level": {"Enable": "off", "Persist": "off"}}}, open(p, "wb"),
                              fmt=plistlib.FMT_BINARY)
    return labels


def measure_boot(udid, outdir, tag, sample_at, timeout, cpu_every):
    shots = os.path.join(outdir, "shots"); os.makedirs(shots, exist_ok=True)
    load = os.getloadavg()[0]
    others_booted, host_cpu0 = host_context(udid)
    t0 = time.time()
    bs = subprocess.Popen(["xcrun", "simctl", "bootstatus", udid, "-b"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    home = bootstatus = None; last_b = None; shot_timeouts = 0
    cpu, alive, pids, next_cpu, sampled = {}, {}, {}, 0.0, False
    shot = os.path.join(shots, f"{tag}.png")
    while time.time() - t0 < timeout:
        now = time.time() - t0
        if bootstatus is None and bs.poll() is not None:
            bootstatus = round(now, 1)
        if home is None:
            # The iPhone Duo type has several displays; "primary" (LCD, 1398x2034)
            # is the one Ycode renders. Without --display simctl picks LCD-1.
            try:
                r = subprocess.run(["xcrun", "simctl", "io", udid, "screenshot", "--display=primary", shot],
                                   capture_output=True, timeout=20)
                ok = r.returncode == 0
            except subprocess.TimeoutExpired:
                ok = False; shot_timeouts += 1
            if ok:
                try:
                    last_b = brightness(shot)
                    if last_b > 60:
                        home = round(time.time() - t0, 1)
                        shutil.copy(shot, os.path.join(shots, f"{tag}-home.png"))
                except Exception:
                    pass
        now = time.time() - t0
        if not sampled and now >= next_cpu:
            alive = device_processes(udid)
            for k, v in alive.items():
                # One entry per pid, named after the program it runs last
                # (xpcproxy_sim execs the daemon under the same pid); an
                # exited, unreaped process shows as "(name)" cut to 16
                # characters and keeps its earlier name.
                pid = k.rsplit("[", 1)[1]
                old = pids.get(pid)
                key = old if (old and k.startswith("(")) else k
                prev = cpu.pop(old, 0.0) if old else 0.0
                cpu[key] = max(prev, v); pids[pid] = key
            next_cpu = now + cpu_every
            if now >= sample_at:
                sampled = True
        if home is not None and bootstatus is not None and sampled:
            break
        time.sleep(0.5 if home is None else 1)
    if bs.poll() is None:
        bs.kill()
    t_end = time.time()
    _, host_cpu1 = host_context(udid)
    # Cores used by everything except this device during the window (the
    # device's own CPU is cpu_total_s up to the sample time).
    others_cores = max(0.0, (host_cpu1 - host_cpu0 - sum(cpu.values())) / (t_end - t0))
    spawns, exits = launchd_log_stats(udid)
    crashes, crash_names = crash_reports(udid, t0, t_end)
    return {"tag": tag, "home_s": home, "bootstatus_s": bootstatus, "sample_at": sample_at, "load1": round(load, 1),
            "load1_end": round(os.getloadavg()[0], 1),
            "others_booted": others_booted, "others_cores": round(others_cores, 2),
            "procs": len(alive), "procs_seen": len(cpu), "cpu_total_s": round(sum(cpu.values()), 1),
            "cpu": dict(sorted(cpu.items(), key=lambda kv: -kv[1])),
            "spawns": spawns, "exits": exits, "crashes": crashes, "crash_reports": crash_names[:40],
            "last_brightness": last_b, "screenshot_timeouts": shot_timeouts}


def one_device(mode, index, args, keep, enable):
    name = f"{args.prefix}-{mode}-{index}"
    udid = run("xcrun", "simctl", "create", name, DEVICE_TYPE, RUNTIME)
    outdir = os.path.join(args.out, name); os.makedirs(outdir, exist_ok=True)
    result = {"name": name, "udid": udid, "mode": mode, "keep": sorted(keep),
              "enable": enable, "boots": []}
    try:
        result["disabled"] = write_lean(udid, mode, keep, enable)
        for boot in ("first", "second"):
            at = args.second_sample_at if boot == "second" and args.second_sample_at else args.sample_at
            r = measure_boot(udid, outdir, boot, at, max(args.timeout, at + 60), args.cpu_every)
            result["boots"].append(r)
            print(f"{name} {boot}: home {r['home_s']} s, bootstatus {r['bootstatus_s']} s, "
                  f"procs {r['procs']}/{r['procs_seen']}, cpu {r['cpu_total_s']} s, crashes {r['crashes']}, others {r['others_booted']} booted/{r['others_cores']} cores", flush=True)
            run("xcrun", "simctl", "shutdown", udid, check=False, timeout=300)
            time.sleep(3)
            log = os.path.join(tmp_dir(udid), "launchd.log")
            if os.path.exists(log):
                shutil.copy(log, os.path.join(outdir, f"launchd-{boot}.log"))
    finally:
        json.dump(result, open(os.path.join(outdir, "result.json"), "w"), indent=1)
        if not args.keep_device:
            run("xcrun", "simctl", "shutdown", udid, check=False, timeout=300)
            run("xcrun", "simctl", "delete", udid, check=False, timeout=300)
            d = tmp_dir(udid)
            if udid in d and os.path.isdir(d):
                shutil.rmtree(d, ignore_errors=True)
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", default="full")
    ap.add_argument("--order", help="comma list of modes, interleaved per round")
    ap.add_argument("--runs", type=int, default=1)
    ap.add_argument("--out", required=True)
    ap.add_argument("--keep", default="")
    ap.add_argument("--enable", default=None)
    ap.add_argument("--sample-at", type=float, default=120)
    ap.add_argument("--timeout", type=float, default=900)
    ap.add_argument("--cpu-every", type=float, default=5)
    ap.add_argument("--second-sample-at", type=float, default=None,
                    help="sample window of the second boot (default --sample-at); e.g. 700 to match a Ycode harness run")
    ap.add_argument("--prefix", default="ycode-test-L")
    ap.add_argument("--start-index", type=int, default=1)
    ap.add_argument("--keep-device", action="store_true")
    args = ap.parse_args()
    assert args.prefix.startswith("ycode-test-"), "devices must be named ycode-test-*"
    keep = set(filter(None, args.keep.split(",")))
    enable = None if args.enable is None else list(filter(None, args.enable.split(",")))
    modes = args.order.split(",") if args.order else [args.mode]
    os.makedirs(args.out, exist_ok=True)
    for i in range(args.start_index, args.start_index + args.runs):
        for mode in modes:
            one_device(mode, i, args, keep, enable)


if __name__ == "__main__":
    main()

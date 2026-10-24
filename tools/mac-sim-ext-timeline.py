#!/usr/bin/env python3
"""Black-box timeline of process starts during a boot of Apple's iOS
Simulator on this Mac (specs/simulator/boot-profile.md §6). Uses only
`xcrun simctl` and `ps`. Works only on devices named ycode-test-*.

Usage:
  python3 -I tools/mac-sim-ext-timeline.py --device ycode-test-NAME --boots N --out DIR
         [--window 90] [--poll 0.25]

Each boot: shut the device down, boot it with `simctl bootstatus -b`, and
until --window s:
  home_s      first screenshot of the primary display with mean brightness
              (grey, 70x102) > 60 (the end point of parity-ladder.md §1)
  procs       every process of the device (descendants of its launchd_sim):
              first and last time seen (polled every --poll s), CPU seconds
              at the last sample, executable name
  extensions  the subset whose path contains ".appex/"; for these: how many
              started before home_s, the largest number alive at once, the
              largest number using CPU in the same poll interval, and their
              summed CPU
  busy        per poll interval, the device's cores in use (CPU delta of all
              its processes / interval)
Writes DIR/<device>-boot<k>.json and prints a summary line per boot.
"""
import argparse, json, os, subprocess, threading, time


def run(*args, timeout=600, check=True):
    p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if check and p.returncode != 0:
        raise RuntimeError(f"{' '.join(args)}: {p.returncode} {p.stderr.strip()}")
    return p.stdout.strip()


def cputime(s):
    days = 0
    if "-" in s:
        d, s = s.split("-", 1); days = int(d)
    sec = 0.0
    for x in s.split(":"):
        sec = sec * 60 + float(x)
    return days * 86400 + sec


def brightness(path):
    from PIL import Image, ImageStat
    return ImageStat.Stat(Image.open(path).convert("L").resize((70, 102))).mean[0]


def snapshot(udid):
    rows = []
    for line in run("ps", "-axww", "-o", "pid=,ppid=,time=,comm=").splitlines():
        p = line.strip().split(None, 3)
        if len(p) == 4:
            rows.append((int(p[0]), int(p[1]), cputime(p[2]), p[3]))
    roots = set()
    for line in run("ps", "-axww", "-o", "pid=,command=").splitlines():
        if "launchd_sim" in line and udid in line:
            roots.add(int(line.split(None, 1)[0]))
    kids = {}
    for pid, ppid, _, _ in rows:
        kids.setdefault(ppid, []).append(pid)
    keep, todo = set(roots), list(roots)
    while todo:
        for c in kids.get(todo.pop(), []):
            if c not in keep:
                keep.add(c); todo.append(c)
    return {pid: (cpu, comm) for pid, ppid, cpu, comm in rows if pid in keep}


def one_boot(udid, name, k, args):
    run("xcrun", "simctl", "shutdown", udid, check=False)
    time.sleep(3)
    shot = os.path.join(args.out, f"{name}-boot{k}.png")
    t0 = time.time()
    bs = subprocess.Popen(["xcrun", "simctl", "bootstatus", udid, "-b"],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    state = {"home": None, "bootstatus": None}

    def watch_home():
        while time.time() - t0 < args.window and state["home"] is None:
            r = subprocess.run(["xcrun", "simctl", "io", udid, "screenshot", "--display=primary", shot],
                               capture_output=True)
            if r.returncode == 0:
                try:
                    if brightness(shot) > 60:
                        state["home"] = round(time.time() - t0, 2)
                except Exception:
                    pass
            time.sleep(0.2)

    th = threading.Thread(target=watch_home, daemon=True); th.start()
    procs, busy, prev_cpu = {}, [], {}
    load0 = os.getloadavg()[0]
    while time.time() - t0 < args.window:
        if state["bootstatus"] is None and bs.poll() is not None:
            state["bootstatus"] = round(time.time() - t0, 2)
        t = round(time.time() - t0, 2)
        snap = snapshot(udid)
        delta = 0.0
        for pid, (cpu, comm) in snap.items():
            p = procs.setdefault(pid, {"pid": pid, "first": t, "comm": comm, "cpu": 0.0})
            p["last"] = t; p["cpu"] = max(p["cpu"], cpu)
            if not comm.startswith("("):
                p["comm"] = comm
            d = cpu - prev_cpu.get(pid, 0.0)
            if d > 0:
                delta += d
                if ".appex/" in p["comm"]:
                    p.setdefault("busy_at", []).append(t)
            prev_cpu[pid] = cpu
        busy.append((t, round(delta, 3), len(snap)))
        time.sleep(args.poll)
    if bs.poll() is None:
        bs.kill()
    th.join(timeout=30)
    home = state["home"]
    exts = [p for p in procs.values() if ".appex/" in p["comm"]]
    # alive / busy concurrency of extensions
    times = sorted({b[0] for b in busy})
    alive_max = max((sum(1 for p in exts if p["first"] <= t <= p["last"]) for t in times), default=0)
    busy_max = max((sum(1 for p in exts if t in p.get("busy_at", ())) for t in times), default=0)
    before = [p for p in exts if home is not None and p["first"] <= home]
    # cores used by the device before home
    cores = []
    for i in range(1, len(busy)):
        dt = busy[i][0] - busy[i - 1][0]
        if dt > 0:
            cores.append((busy[i][0], busy[i][1] / dt))
    pre = [c for t, c in cores if home is None or t <= home]
    res = {"device": name, "boot": k, "home_s": home, "bootstatus_s": state["bootstatus"], "load1": round(load0, 1),
           "procs_seen": len(procs), "ext_seen": len(exts), "ext_before_home": len(before),
           "ext_first_s": min((p["first"] for p in exts), default=None),
           "ext_alive_max": alive_max, "ext_busy_max": busy_max,
           "ext_cpu_s": round(sum(p["cpu"] for p in exts), 1),
           "ext_cpu_before_home_s": round(sum(p["cpu"] for p in before), 1),
           "device_cores_mean_before_home": round(sum(pre) / len(pre), 2) if pre else None,
           "procs": sorted(procs.values(), key=lambda p: p["first"]), "busy": busy}
    json.dump(res, open(os.path.join(args.out, f"{name}-boot{k}.json"), "w"), indent=1)
    print(f"{name} boot{k}: home {home} s, bootstatus {state['bootstatus']} s, load {res['load1']}, procs {len(procs)}, "
          f"extensions seen {len(exts)} (first at {res['ext_first_s']} s, {len(before)} before home), alive max {alive_max}, "
          f"busy max {busy_max}, ext cpu {res['ext_cpu_s']} s ({res['ext_cpu_before_home_s']} s before home), "
          f"device cores before home {res['device_cores_mean_before_home']}", flush=True)
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", required=True)
    ap.add_argument("--boots", type=int, default=1)
    ap.add_argument("--out", required=True)
    ap.add_argument("--window", type=float, default=90)
    ap.add_argument("--poll", type=float, default=0.25)
    args = ap.parse_args()
    assert args.device.startswith("ycode-test-"), "only devices named ycode-test-*"
    os.makedirs(args.out, exist_ok=True)
    udid = None
    for line in run("xcrun", "simctl", "list", "devices").splitlines():
        if line.strip().startswith(args.device + " ("):
            udid = line.split("(")[1].split(")")[0]
    assert udid, "device not found"
    for k in range(1, args.boots + 1):
        one_boot(udid, args.device, k, args)
    run("xcrun", "simctl", "shutdown", udid, check=False)


if __name__ == "__main__":
    main()

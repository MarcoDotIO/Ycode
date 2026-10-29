"""List the processes of one booted simulator (descendants of its launchd_sim).

Usage: python3 -I simprocs.py <device-udid>
Prints pid, rss (KiB), %cpu and a short command name, sorted by rss; then totals.
"""
import subprocess, sys
udid = sys.argv[1]
out = subprocess.run(["ps", "-axww", "-o", "pid=,ppid=,rss=,%cpu=,command="],
                     capture_output=True, text=True).stdout.splitlines()
rows = {}
for line in out:
    parts = line.split(None, 4)
    if len(parts) < 5:
        continue
    pid, ppid, rss, cpu, cmd = parts
    rows[int(pid)] = (int(ppid), int(rss), float(cpu), cmd)
root = [p for p, r in rows.items() if "launchd_sim" in r[3] and udid in r[3]]
if not root:
    sys.exit("no launchd_sim for " + udid)
keep = set(root)
changed = True
while changed:
    changed = False
    for p, r in rows.items():
        if p not in keep and r[0] in keep:
            keep.add(p); changed = True
total = 0
lst = []
for p in keep:
    ppid, rss, cpu, cmd = rows[p]
    if "RuntimeRoot" in cmd:
        short = cmd.split("RuntimeRoot", 1)[1].split(" ")[0]
    else:
        short = cmd.split(" ")[0].rsplit("/", 1)[-1]
    lst.append((rss, p, cpu, short))
    total += rss
for rss, p, cpu, short in sorted(lst, reverse=True):
    print(f"{p}\t{rss}\t{cpu}\t{short}")
print(f"# processes {len(lst)} total_rss_MiB {total/1024:.0f}")

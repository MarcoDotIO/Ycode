"""List launchd job labels of a simulator RuntimeRoot (metadata only).

Usage: python3 -I jobs.py <RuntimeRoot> > labels.tsv
Prints: kind<TAB>label<TAB>program<TAB>machservices(comma)
"""
import os, plistlib, sys
rr = sys.argv[1]
for kind in ("LaunchDaemons", "LaunchAgents", "LaunchAngels", "xpc"):
    d = os.path.join(rr, "System/Library", kind)
    if not os.path.isdir(d):
        continue
    for f in sorted(os.listdir(d)):
        if not f.endswith(".plist"):
            continue
        try:
            with open(os.path.join(d, f), "rb") as fh:
                p = plistlib.load(fh)
        except Exception as e:
            print(f"{kind}\t?{f}\terr {e}")
            continue
        prog = p.get("Program") or (p.get("ProgramArguments") or [""])[0]
        ms = ",".join(sorted((p.get("MachServices") or {}).keys()))
        print(f"{kind}\t{p.get('Label', f)}\t{prog}\t{ms}")

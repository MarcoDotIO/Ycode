"""Summarise svctrace lines (SUPX) of SUIProbe logs (KIT-SWIFTUI, original code).
Usage: python3 -I trace.py <baseline.log> <other.log>...
Prints the baseline's services, then per log the names not in the baseline."""
import re, sys, collections

def load(p):
    d = collections.defaultdict(dict)   # kind -> name -> first time
    for l in open(p, errors='replace'):
        m = re.match(r'^SUPX (\S+) (\S+) (\S+)(?: kr=(-?\d+))?', l)
        if not m:
            continue
        t, kind, name, kr = float(m.group(1)), m.group(2), m.group(3), m.group(4)
        kind = {'lookup2': 'lookup'}.get(kind, kind)
        if kr and kr != '0':
            name += f' (kr={kr})'
        d[kind].setdefault(name, t)
    return d

base = load(sys.argv[1])
print(f'== baseline {sys.argv[1]}')
for k in sorted(base):
    print(f'  {k} ({len(base[k])}):')
    for n, t in sorted(base[k].items(), key=lambda x: x[1]):
        print(f'    {t:7.3f} {n}')
for p in sys.argv[2:]:
    d = load(p)
    print(f'== {p}: names not in baseline')
    for k in sorted(d):
        extra = {n: t for n, t in d[k].items() if n not in base.get(k, {})}
        for n, t in sorted(extra.items(), key=lambda x: x[1]):
            print(f'    {k:16s} {t:7.3f} {n}')

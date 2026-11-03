# setprefs.py <plist> [key=val ...]: write a plist with hmd.preferred-languages and the given keys (int, float, or s:string)
import plistlib, sys
d = {'hmd.preferred-languages': ['en-US']}
for kv in sys.argv[2:]:
    k, v = kv.split('=', 1)
    if v.startswith('s:'): d[k] = v[2:]
    elif v in ('true', 'false'): d[k] = (v == 'true')
    elif '.' in v: d[k] = float(v)
    else: d[k] = int(v)
with open(sys.argv[1], 'wb') as f: plistlib.dump(d, f, fmt=plistlib.FMT_BINARY)
print(d)

# setdomain.py <prefs dir> <domain> [key=val ...] | --restore <prefs dir> <backup dir>
# Merge keys (int, float, true/false, s:string, j:<json>) into DEV/data/Library/Preferences/<domain>.plist,
# backing the original up first (once) into $FOV_BACKUP; --restore puts every backed-up domain back.
import plistlib, sys, os, json, shutil
if sys.argv[1] == '--restore':
    pd, bd = sys.argv[2], sys.argv[3]
    for f in os.listdir(bd):
        src = os.path.join(bd, f); dst = os.path.join(pd, f[:-len('.absent')] if f.endswith('.absent') else f)
        if f.endswith('.absent'):
            if os.path.exists(dst): os.remove(dst)
        else: shutil.copy2(src, dst)
    sys.exit(0)
pd, dom = sys.argv[1], sys.argv[2]; bd = os.environ['FOV_BACKUP']; os.makedirs(bd, exist_ok=True)
p = os.path.join(pd, dom + '.plist')
b = os.path.join(bd, dom + '.plist')
if not os.path.exists(b) and not os.path.exists(b + '.absent'):
    if os.path.exists(p): shutil.copy2(p, b)
    else: open(b + '.absent', 'w').close()
d = plistlib.load(open(p, 'rb')) if os.path.exists(p) else {}
for kv in sys.argv[3:]:
    k, v = kv.split('=', 1)
    if v.startswith('s:'): d[k] = v[2:]
    elif v.startswith('j:'): d[k] = json.loads(v[2:])
    elif v in ('true', 'false'): d[k] = (v == 'true')
    elif '.' in v or 'e' in v: d[k] = float(v)
    else: d[k] = int(v)
plistlib.dump(d, open(p, 'wb'), fmt=plistlib.FMT_BINARY)
print(dom, {k: d[k] for k in (kv.split('=', 1)[0] for kv in sys.argv[3:])})

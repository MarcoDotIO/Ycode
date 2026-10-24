#!/usr/bin/env python3 -I
"""Extract a NAME inventory (level 4 metadata) from the MapKit SDK headers.

Our own tool. It records only names, enum raw values, superclass names and
introduced/deprecated iOS versions. It never records declarations, types,
parameter lists or comments. Output: JSON on stdout (keep it in
research/dirty/mapkit/, it is a working file, not a spec).

Usage: python3 -I extract_names.py <MapKit.framework/Headers>
"""
import json, os, re, sys

hdr_dir = sys.argv[1]
AV = re.compile(r'ios\((\d+\.\d+)(?:\s*,\s*([\d.A-Z_]+))?\)')
def avail(s):
    m = AV.search(s)
    intro = m.group(1) if m else None
    dep = m.group(2) if m and m.group(2) else None
    if 'API_UNAVAILABLE' in s and re.search(r'API_UNAVAILABLE\([^)]*\bios\b', s):
        intro = 'unavailable'
    if 'DEPRECATED' in s and not dep:
        dep = 'yes'
    return intro, dep

def strip_comments(t):
    t = re.sub(r'/\*.*?\*/', '', t, flags=re.S)
    return re.sub(r'//[^\n]*', '', t)

out = {'constants': [], 'enums': [], 'classes': [], 'protocols': [], 'functions': []}
for fn in sorted(os.listdir(hdr_dir)):
    if not fn.endswith('.h'):
        continue
    t = strip_comments(open(os.path.join(hdr_dir, fn), encoding='utf-8').read())
    # constants
    for m in re.finditer(r'MK_EXTERN\s+(?:const\s+)?([A-Za-z_]\w*)\s*(?:\*\s*)?const\s+(MK\w+)([^;]*);', t):
        i, d = avail(m.group(3))
        out['constants'].append({'file': fn, 'kind': m.group(1), 'name': m.group(2), 'ios': i, 'deprecated': d})
    # functions
    for m in re.finditer(r'MK_EXTERN\s+[^;(]*?\b(MK\w+)\s*\(([^;]*);', t):
        i, d = avail(m.group(2))
        out['functions'].append({'file': fn, 'name': m.group(1), 'ios': i, 'deprecated': d})
    # enums
    for m in re.finditer(r'typedef\s+NS_(?:ENUM|OPTIONS|CLOSED_ENUM)\s*\(\s*\w+\s*,\s*(\w+)\s*\)\s*\{(.*?)\}([^;]*);', t, flags=re.S):
        name, body, tail = m.group(1), m.group(2), m.group(3)
        cases, cur, known = [], -1, {}
        parts, depth, cur_s = [], 0, ''
        for ch in body:
            if ch == '(':
                depth += 1
            elif ch == ')':
                depth -= 1
            if ch == ',' and depth == 0:
                parts.append(cur_s); cur_s = ''
            else:
                cur_s += ch
        parts.append(cur_s)
        for part in [p.strip() for p in parts]:
            if not part:
                continue
            cm = re.match(r'(\w+)(.*)', part, flags=re.S)
            if not cm:
                continue
            cname, rest = cm.group(1), cm.group(2)
            rest_nomacro = rest
            while re.search(r'\b[A-Z_]+\((?:[^()]|\([^()]*\))*\)', rest_nomacro):
                rest_nomacro = re.sub(r'\b[A-Z_]+\((?:[^()]|\([^()]*\))*\)', '', rest_nomacro)
            vm = re.search(r'=\s*([^=]+)$', rest_nomacro.strip())
            val = None
            if vm:
                expr = vm.group(1).strip()
                try:
                    expr2 = re.sub(r'\b([A-Za-z_]\w*)\b', lambda x: str(known.get(x.group(1), x.group(1))), expr)
                    expr2 = expr2.replace('UL', '').replace('ULL', '')
                    val = eval(expr2, {'__builtins__': {}}, {})
                except Exception:
                    val = expr
            else:
                val = cur + 1 if isinstance(cur, int) else None
            if isinstance(val, int):
                cur = val
                known[cname] = val
            i, d = avail(rest)
            cases.append({'name': cname, 'value': val, 'ios': i, 'deprecated': d})
        i, d = avail(tail)
        out['enums'].append({'file': fn, 'name': name, 'ios': i, 'deprecated': d, 'cases': cases})
    # classes and protocols
    for m in re.finditer(r'((?:MK_EXTERN\s+)?(?:API_\w+\([^@]*?\)\s*|MK_\w+\s*|NS_\w+(?:\([^)]*\))?\s*)*)@(interface|protocol)\s+(\w+)\b(?!\s*[;,])\s*(?:\(\s*(\w*)\s*\))?\s*(?::\s*(\w+))?(.*?)@end', t, flags=re.S):
        pre, kind, name, category, sup, body = m.groups()
        if kind == 'protocol' and body.strip().startswith(';'):
            continue
        seg = t[max(0, m.start(2) - 400):m.start(2)]
        seg = re.split(r'@end|;', seg)[-1]
        avs = [x for x in re.findall(r'API_\w+\((?:[^()]|\([^()]*\))*\)', seg) if 'ios' in x]
        i, d = avail(avs[-1] if avs else '')
        members = []
        for mm in re.finditer(r'^\s*@property\s*(\([^)]*\))?[^;]*?(\w+)\s*((?:API_|NS_|MK_)[^;]*)?;', body, flags=re.M):
            attrs = mm.group(1) or ''
            mi, md = avail(mm.group(3) or '')
            members.append({'k': 'class-prop' if 'class' in attrs else 'prop', 'name': mm.group(2), 'ios': mi, 'deprecated': md,
                            'readonly': 'readonly' in attrs})
        for mm in re.finditer(r'^\s*([-+])\s*\([^;{]*?\)\s*([^;{]*?);', body, flags=re.M | re.S):
            sig = mm.group(2)
            avs = ''
            am = re.search(r'\s((?:API_|NS_|MK_|__attribute__)[\s\S]*)$', sig)
            if am:
                avs = am.group(1); sig = sig[:am.start()]
            parts = re.findall(r'(\w+)\s*:', sig)
            sel = ''.join(p + ':' for p in parts) if parts else re.match(r'\s*(\w+)', sig).group(1)
            mi, md = avail(avs)
            members.append({'k': 'class-method' if mm.group(1) == '+' else 'method', 'name': sel, 'ios': mi, 'deprecated': md})
        entry = {'file': fn, 'name': name, 'category': category, 'super': sup, 'ios': i, 'deprecated': d, 'members': members}
        out['classes' if kind == 'interface' else 'protocols'].append(entry)

json.dump(out, sys.stdout, indent=1)

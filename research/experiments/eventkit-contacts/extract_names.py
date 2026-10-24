#!/usr/bin/env python3 -I
"""Extract a NAME inventory (level 4 metadata) from SDK framework headers.

Our own tool (generalized from research/experiments/healthkit/extract_names.py
for EventKit, EventKitUI, Contacts and ContactsUI). It records only names,
enum raw values, superclass names, adopted-protocol names and
introduced/deprecated iOS versions. It never records declarations, types,
parameter lists or comments. Output: JSON on stdout; keep it in
research/dirty/eventkit-contacts/ (a working file, not a spec).

Usage: python3 -I extract_names.py <Framework.framework/Headers> [...]
"""
import json, os, re, sys

def ver(s):
    if s == 'NA':
        return 'unavailable'
    return s.replace('_', '.') if s else s

def avail(s):
    """iOS introduction / deprecation from one annotation string."""
    intro = dep = None
    m = re.search(r'\bios\((\d+(?:\.\d+)*)(?:\s*,\s*([\d.]+|API_TO_BE_DEPRECATED))?\)', s)
    if m:
        intro, dep = m.group(1), m.group(2)
    m = re.search(r'\bNS_(?:CLASS_|ENUM_)?AVAILABLE\(\s*(\w+)\s*,\s*(\w+)\s*\)', s)
    if m and not intro:
        intro = ver(m.group(2))
    m = re.search(r'\bNS_(?:CLASS_|ENUM_)?AVAILABLE_IOS\(\s*(\w+)\s*\)', s)
    if m and not intro:
        intro = ver(m.group(1))
    m = re.search(r'\bEVENTKITUI_CLASS_AVAILABLE\(\s*(\w+)\s*\)', s)
    if m and not intro:
        intro = ver(m.group(1))
    m = re.search(r'\bNS_(?:ENUM_)?DEPRECATED\(\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)', s)
    if m:
        intro = intro or ver(m.group(3)); dep = dep or ver(m.group(4))
        if dep == 'unavailable': dep = None
    m = re.search(r'\bNS_DEPRECATED_IOS\(\s*(\w+)\s*,\s*(\w+)', s)
    if m:
        intro = intro or ver(m.group(1)); dep = dep or ver(m.group(2))
    if re.search(r'API_UNAVAILABLE\([^)]*\bios\b', s) or 'NS_UNAVAILABLE' in s:
        intro = 'unavailable'
    if re.search(r'API_DEPRECATED|NS_DEPRECATED|NS_ENUM_DEPRECATED', s) and not dep:
        dep = 'yes'
    return intro, dep

def strip_comments(t):
    t = re.sub(r'/\*.*?\*/', '', t, flags=re.S)
    return re.sub(r'//[^\n]*', '', t)

EXTERN = r'(?:EVENTKIT_EXTERN|EVENTKITUI_EXTERN|CONTACTS_EXTERN|extern|FOUNDATION_EXTERN)'
GKNOWN = {}
out = {'constants': [], 'enums': [], 'classes': [], 'protocols': [], 'functions': []}
for hdr_dir in sys.argv[1:]:
    fw = os.path.basename(os.path.dirname(hdr_dir.rstrip('/'))).replace('.framework', '')
    for fn in sorted(os.listdir(hdr_dir)):
        if not fn.endswith('.h'):
            continue
        t = strip_comments(open(os.path.join(hdr_dir, fn), encoding='utf-8').read())
        for m in re.finditer(EXTERN + r'\s+(?:const\s+)?([A-Za-z_]\w*)\s*(?:<[^>]*>\s*)?(?:\*\s*)?const\s+(\w+)([^;]*);', t):
            i, d = avail(m.group(3))
            out['constants'].append({'fw': fw, 'file': fn, 'kind': m.group(1), 'name': m.group(2), 'ios': i, 'deprecated': d})
        for m in re.finditer(r'typedef\s+NS_(?:ENUM|OPTIONS|CLOSED_ENUM|ERROR_ENUM)\s*\(\s*\w+\s*,\s*(\w+)\s*\)\s*([^{;]*)\{(.*?)\}([^;]*);', t, flags=re.S):
            name, pre, body, tail = m.group(1), m.group(2), m.group(3), m.group(4)
            cases, cur, known = [], -1, GKNOWN
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
                cm = re.match(r'(\w+)(.*)', part, flags=re.S)
                if not cm:
                    continue
                cname, rest = cm.group(1), cm.group(2)
                r2 = rest
                while re.search(r'\b[A-Z_]+\((?:[^()]|\([^()]*\))*\)', r2):
                    r2 = re.sub(r'\b[A-Z_]+\((?:[^()]|\([^()]*\))*\)', '', r2)
                vm = re.search(r'=\s*([^=]+)$', r2.strip())
                val = None
                if vm:
                    expr = vm.group(1).strip()
                    try:
                        e2 = re.sub(r'\b([A-Za-z_]\w*)\b', lambda x: str(known.get(x.group(1), x.group(1))), expr)
                        e2 = re.sub(r'(\d)(?:ULL|UL|U|L)\b', r'\1', e2)
                        val = eval(e2, {'__builtins__': {}}, {})
                    except Exception:
                        val = expr
                else:
                    val = cur + 1 if isinstance(cur, int) else None
                if isinstance(val, int):
                    cur = val; known[cname] = val
                i, d = avail(rest)
                cases.append({'name': cname, 'value': val, 'ios': i, 'deprecated': d})
            i, d = avail(pre + tail)
            out['enums'].append({'fw': fw, 'file': fn, 'name': name, 'ios': i, 'deprecated': d, 'cases': cases})
        for m in re.finditer(r'@(interface|protocol)\s+(\w+)\b(?!\s*[;,])\s*(?:\(\s*(\w*)\s*\))?\s*(?::\s*(\w+))?\s*(?:<([^>]*)>)?(.*?)@end', t, flags=re.S):
            kind, name, category, sup, protos, body = m.groups()
            seg = t[max(0, m.start(1) - 400):m.start(1)]
            seg = re.split(r'@end|;|\}', seg)[-1]
            i, d = avail(seg)
            members = []
            for mm in re.finditer(r'^\s*@property\s*(\([^)]*\))?([^;]*?)\b(\w+)\s*((?:API_|NS_|EK_|CN_|__)[^;]*)?;', body, flags=re.M):
                attrs = mm.group(1) or ''
                mi, md = avail(mm.group(4) or '')
                members.append({'k': 'class-prop' if re.search(r'\bclass\b', attrs) else 'prop', 'name': mm.group(3), 'ios': mi,
                                'deprecated': md, 'readonly': 'readonly' in attrs})
            for mm in re.finditer(r'^\s*([-+])\s*\([^;{]*?\)\s*([^;{]*?);', body, flags=re.M | re.S):
                sig = mm.group(2); avs = ''
                am = re.search(r'\s((?:API_|NS_|EK_|CN_|__attribute__|__OSX|__IOS)[\s\S]*)$', sig)
                if am:
                    avs = am.group(1); sig = sig[:am.start()]
                parts = re.findall(r'(\w+)\s*:', sig)
                sel = ''.join(p + ':' for p in parts) if parts else re.match(r'\s*(\w+)', sig).group(1)
                mi, md = avail(avs)
                members.append({'k': 'class-method' if mm.group(1) == '+' else 'method', 'name': sel, 'ios': mi, 'deprecated': md})
            entry = {'fw': fw, 'file': fn, 'name': name, 'category': category, 'super': sup,
                     'protocols': [p.strip() for p in (protos or '').split(',') if p.strip()],
                     'ios': i, 'deprecated': d, 'members': members}
            out['classes' if kind == 'interface' else 'protocols'].append(entry)
json.dump(out, sys.stdout, indent=1)

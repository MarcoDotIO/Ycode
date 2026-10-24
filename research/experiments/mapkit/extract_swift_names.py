#!/usr/bin/env python3 -I
"""Extract a NAME inventory (level 4 metadata) from a .swiftinterface file.

Our own tool. It records only declared names (types, extensions, members,
enum cases), the declaration kind and the iOS introduction version from
availability attributes. It never records signatures, parameter types,
bodies, default values or comments. Output: JSON on stdout (keep it in
research/dirty/mapkit/, it is a working file, not a spec).

Usage: python3 -I extract_swift_names.py <file.swiftinterface> <module-label>
"""
import json, re, sys

path, label = sys.argv[1], sys.argv[2]
lines = open(path, encoding='utf-8').read().split('\n')
AV = re.compile(r'@available\(\s*iOS\s+([\d.]+)|introduced:\s*([\d.]+)')
TYPE = re.compile(r'^\s*(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:public|open)\s+(?:final\s+|indirect\s+|nonisolated\s+)*(struct|class|enum|protocol|actor|typealias)\s+(\w+)')
EXT = re.compile(r'^\s*(?:@[\w.]+(?:\([^)]*\))?\s+)*extension\s+([\w.]+)')
MEM = re.compile(r'^\s*(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:(?:public|open|static|class|final|override|nonisolated|mutating|convenience|required|dynamic|@objc|optional|lazy)\s+)*(func|var|let|init|case|subscript|associatedtype|typealias)\b\s*([\w`]*)')
TOPFUNC = re.compile(r'^\s*(?:@[\w.]+(?:\([^)]*\))?\s+)*public\s+(?:static\s+)?(func|var|let)\s+([\w`]+)')

out = []
stack = []          # (entry or None, depth at open)
depth = 0
pending_av = None
unavailable = False
for raw in lines:
    s = re.sub(r'\b\w+::', '', raw.strip())  # drop module selectors (Module::Name)
    if s.startswith('//') or not s:
        continue
    if s.startswith('@available'):
        if re.search(r'iOS[^)]*unavailable', s) or re.search(r'\*\s*,\s*unavailable', s):
            unavailable = True
        m = re.search(r'iOS\s+([\d.]+)', s) or re.search(r'iOS,\s*introduced:\s*([\d.]+)', s)
        if m:
            pending_av = m.group(1)
        if s.endswith(')') and not re.search(r'\b(func|var|init|struct|class|enum|case)\b', s):
            continue
    cur = stack[-1][0] if stack else None
    mt, me = TYPE.match(s), EXT.match(s)
    if mt or me:
        if mt:
            e = {'module': label, 'kind': mt.group(1), 'name': (cur['name'] + '.' if cur and cur['kind'] != 'extension' else (cur['extends'] + '.' if cur else '')) + mt.group(2), 'ios': pending_av, 'unavailable': unavailable, 'members': []}
        else:
            e = {'module': label, 'kind': 'extension', 'name': me.group(1), 'extends': me.group(1), 'ios': pending_av, 'unavailable': unavailable, 'members': []}
        if e['kind'] != 'typealias':
            out.append(e)
        opens = s.count('{') - s.count('}')
        if opens > 0:
            stack.append((e, depth))
        depth += opens
        pending_av = None; unavailable = False
        continue
    if cur is not None and depth == stack[-1][1] + 1:
        mm = MEM.match(s)
        if mm and ('public' in s or 'open' in s or cur['kind'] in ('protocol',) or mm.group(1) == 'case'):
            kind, name = mm.group(1), mm.group(2).strip('`')
            if kind == 'case':
                for nm in re.findall(r'(?:case\s+|,\s*)(\w+)', s):
                    cur['members'].append({'k': 'case', 'name': nm, 'ios': pending_av, 'unavailable': unavailable})
            else:
                if kind in ('init', 'subscript'):
                    labels = re.match(r'^[^(]*\(([^)]*)', s[s.find(kind):])
                    lab = ''
                    if labels:
                        lab = ''.join(re.sub(r'\s.*', '', p.strip().split(':')[0]) + ':' for p in labels.group(1).split(',') if ':' in p)
                    name = f'{kind}({lab})'
                elif kind == 'func':
                    labels = re.match(r'^[^(]*\(([^)]*)', s[s.find('func'):])
                    lab = ''
                    if labels:
                        lab = ''.join(re.sub(r'\s.*', '', p.strip().split(':')[0]) + ':' for p in labels.group(1).split(',') if ':' in p)
                    name = f'{name}({lab})'
                static = bool(re.search(r'\b(static|class)\s+(func|var|let)', s))
                cur['members'].append({'k': kind, 'name': name, 'static': static, 'ios': pending_av, 'unavailable': unavailable})
    elif cur is None and depth == 0:
        mf = TOPFUNC.match(s)
        if mf:
            out.append({'module': label, 'kind': 'global-' + mf.group(1), 'name': mf.group(2), 'ios': pending_av, 'unavailable': unavailable, 'members': []})
    pending_av = None; unavailable = False
    opens = s.count('{') - s.count('}')
    depth += opens
    while stack and depth <= stack[-1][1]:
        stack.pop()

json.dump(out, sys.stdout, indent=1)

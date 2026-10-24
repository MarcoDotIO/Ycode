"""Name-only inventory of a .swiftinterface (KIT-SWIFTUI, original Ycode code).

Keeps, per public declaration: kind, name, argument labels, conformance names,
and the iOS availability (introduced / deprecated / unavailable). Everything
else (types of parameters, generic constraints, bodies, attributes, comments)
is dropped. Output is JSON lines on stdout:
  {"module","parent","kind","name","conf","ios","dep","unavail"}
Usage: python3 -I inv.py <module> <file.swiftinterface>
"""
import json, re, sys

module, path = sys.argv[1], sys.argv[2]
src = open(path, encoding='utf-8').read().split('\n')

KW = r'(struct|class|enum|protocol|actor|extension|typealias|var|let|func|init[?!]?|subscript|case|associatedtype|macro)'
MODS = r'(?:(?:public|open|final|nonisolated|static|class|override|convenience|required|indirect|mutating|nonmutating|dynamic|optional|package|borrowing|consuming|isolated|weak|unowned|lazy)\s+)*'
declre = re.compile(r'^\s*((?:@[\w.$]+(?:\([^)]*\))?\s+)*)(' + MODS + r')' + KW + r'\b\s*(.*)$')
TYPEKINDS = ('struct', 'class', 'enum', 'protocol', 'actor', 'extension')

def strip_strings(s):
    return re.sub(r'"(?:\\.|[^"\\])*"', '""', s)

def labels(rest):
    depth = 0; buf = ''; parts = []
    for ch in rest:
        if ch in '([<':
            depth += 1
            if depth == 1 and ch == '(':
                continue
        elif ch in ')]>':
            depth -= 1
            if depth == 0 and ch == ')':
                parts.append(buf); break
        if depth == 1 and ch == ',':
            parts.append(buf); buf = ''; continue
        if depth >= 1:
            buf += ch
    out = []
    for a in parts:
        a = re.sub(r'^(@[\w.]+(\([^)]*\))?\s+)+', '', a.strip())
        if not a or ':' not in a:
            continue
        lab = a.split(':')[0].strip().split()
        if lab:
            out.append(lab[0] + ':')
    return '(' + ''.join(out) + ')'

def ident(kind, rest):
    if kind.startswith('init'):
        return kind + labels(rest[rest.find('('):] if '(' in rest else '()')
    if kind == 'subscript':
        return 'subscript' + labels(rest)
    if kind in ('func', 'macro'):
        m = re.match(r'([^\s(<]+)\s*(<.*?>)?\s*(\(.*)', rest)
        if m:
            return m.group(1) + labels(m.group(3))
        return rest.split('(')[0]
    if kind == 'case':
        names = []
        for part in re.split(r',(?![^(]*\))', rest):
            n = re.split(r'[\s(=:]', part.strip())[0]
            if n:
                names.append(n + ('(…)' if '(' in part.split('=')[0] else ''))
        return ', '.join(names)
    if kind in ('var', 'let'):
        return rest.split(':')[0].strip()
    if kind == 'extension':
        return re.split(r'[\s:{]', rest.strip())[0]
    return re.split(r'[\s:<{=(]', rest.strip())[0]

def conformances(kind, rest):
    if kind not in TYPEKINDS:
        return []
    r = rest.split('{')[0]
    r = r.split(' where ')[0]
    if ':' not in r:
        return []
    after = r.split(':', 1)[1]
    names = []
    for c in re.split(r',(?![^<]*>)', after):
        c = re.sub(r'^\s*(@\w+\s+)*', '', c.strip())
        c = c.split('<')[0].strip()
        c = re.sub(r'^(Swift|SwiftUI|SwiftUICore|Foundation|Combine|CoreGraphics|CoreFoundation|UIKit|Observation)\.', '', c)
        if c and re.match(r'^[\w.~]+$', c):
            names.append(c)
    return names

def availability(attrs):
    ios = dep = None; unavail = False
    for a in attrs:
        if not a.startswith('@available'):
            continue
        body = a[a.find('(') + 1:a.rfind(')')] if '(' in a else ''
        items = [x.strip() for x in body.split(',')]
        if items and items[0] in ('iOS', 'iOSApplicationExtension'):
            if 'unavailable' in items:
                unavail = True
            for it in items[1:]:
                if it.startswith('introduced:'):
                    ios = ios or it.split(':')[1].strip()
                if it.startswith('deprecated'):
                    dep = it.split(':')[1].strip() if ':' in it else 'yes'
        for m in re.finditer(r'\biOS\s+([\d.]+)', body):
            ios = ios or m.group(1)
        if items and items[0] == '*' and 'unavailable' in items:
            unavail = True
        if items and items[0] == '*' and any(i.startswith('deprecated') for i in items):
            dep = dep or 'yes'
    return ios, dep, unavail

stack = []   # entries: ('type', name, ios) or ('body',)
pending = []
seen = set()
for raw in src:
    line = re.sub(r'\b\w+::', '', raw.strip())
    if not line or line.startswith('//') or line.startswith('#'):
        continue
    clean = strip_strings(line)
    in_type_ctx = not stack or stack[-1][0] == 'type'
    m = declre.match(clean) if in_type_ctx else None
    if in_type_ctx and line.startswith('@') and not m:
        pending.append(line)
        opens = clean.count('{') - clean.count('}')
        for _ in range(max(opens, 0)):
            stack.append(('body',))
        continue
    pushed_type = False
    if m:
        attrs = pending + re.findall(r'@[\w.$]+(?:\([^)]*\))?', m.group(1) or '')
        pending = []
        mods = (m.group(2) or '').split()
        kind = m.group(3); rest = m.group(4)
        name = ident(kind, rest)
        if kind == 'extension':
            name = re.sub(r'^(SwiftUI|SwiftUICore|Swift|Foundation|CoreGraphics|UIKit|Combine|Observation|CoreFoundation|CoreText|QuartzCore)\.', '', name)
        spi = any(a.startswith('@_spi') or a.startswith('@usableFromInline') or a.startswith('@_alwaysEmitIntoClient') and False for a in attrs)
        hidden = spi or name.startswith('_') or name.startswith('$') or 'internal' in mods
        ios, dep, unavail = availability(attrs)
        if ios is None:
            for s_ in reversed(stack):
                if s_[0] == 'type' and s_[2]:
                    ios = s_[2]; break
        parent = '.'.join(s[1] for s in stack if s[0] == 'type')
        if kind == 'extension':
            name = re.sub(r'^(SwiftUI|SwiftUICore|Swift|Foundation|CoreGraphics|UIKit|Combine|Observation)\.', '', name)
        if kind in TYPEKINDS and '{' in clean:
            stack.append(('type', name if not hidden else '_hidden', ios))
            pushed_type = True
            clean_rest = clean[clean.find('{') + 1:]
        else:
            clean_rest = clean
        if not hidden and not any(s[1] == '_hidden' for s in stack[:-1 if pushed_type else None] if s[0] == 'type'):
            rec = dict(module=module, parent=parent, kind=('static ' if 'static' in mods or ('class' in mods and kind != 'class') else '') + kind,
                       name=name, conf=conformances(kind, rest), ios=ios, dep=dep, unavail=unavail)
            key = (parent, rec['kind'], name)
            if key not in seen:
                seen.add(key)
                print(json.dumps(rec))
        opens = clean_rest.count('{') - clean_rest.count('}')
    else:
        pending = [] if not line.startswith('@') else pending
        opens = clean.count('{') - clean.count('}')
    if opens > 0:
        for _ in range(opens):
            stack.append(('body',))
    elif opens < 0:
        for _ in range(-opens):
            if stack:
                stack.pop()

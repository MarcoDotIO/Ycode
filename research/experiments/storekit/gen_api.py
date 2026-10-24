#!/usr/bin/env python3
"""Generate the NAME inventory of the StoreKit spec (level 4) from the public
Swift interface files of the SDK (StoreKit and StoreKitTest).

Our own tool. Output: Markdown listing, per public type (with its nesting
path), the kind and the names of its members: function names with argument
labels (e.g. `purchase(options:)`), property names, enum case names,
initializer labels, associated types. No types, no parameter types, no
bodies, no documentation, no attributes are emitted.

Usage: python3 -I gen_api.py StoreKit.swiftinterface StoreKitTest.swiftinterface HEADER.h... > api-inventory.md
"""
import re, sys

DECL = re.compile(r'^\s*(?:@[\w.:]+(?:\([^)]*\))?\s+)*(?:(?:public|open|final|indirect|nonisolated|@preconcurrency|dynamic|override|static|class|mutating|nonmutating|convenience|required|lazy|weak|unowned|consuming|borrowing)\s+)*'
                  r'(struct|enum|class|protocol|extension|actor|typealias|associatedtype|func|init|subscript|var|let|case)\b\s*(.*)$')


def label_list(params):
    # params: text inside the outermost parentheses; return "a:b:" labels
    depth, cur, parts = 0, '', []
    for ch in params:
        if ch in '([<{':
            depth += 1
        elif ch in ')]>}':
            depth -= 1
        if ch == ',' and depth == 0:
            parts.append(cur); cur = ''
        else:
            cur += ch
    if cur.strip():
        parts.append(cur)
    labs = []
    for p in parts:
        head = p.split(':', maxsplit=1)[0].strip().split()
        if not head:
            continue
        labs.append((head[0] if head[0] != '_' else '_') + ':')
    return ''.join(labs)


def paren_body(s):
    i = s.find('(')
    if i < 0:
        return None
    depth = 0
    for j in range(i, len(s)):
        if s[j] == '(':
            depth += 1
        elif s[j] == ')':
            depth -= 1
            if depth == 0:
                return s[i + 1:j]
    return s[i + 1:]


def strip_mod(name):
    return re.sub(r'^\w+::', '', name).replace('`', '')


def parse(path, module):
    types = {}   # path -> {"kind": k, "members": [..]}
    stack = []   # (path or None, depth)
    depth = 0
    for raw in open(path, encoding='utf-8'):
        line = raw.split('//')[0].rstrip() if not raw.lstrip().startswith('//') else ''
        if not line.strip():
            continue
        m = DECL.match(line)
        cur = stack[-1][0] if stack else None
        if m and (re.search(r'\b(public|open)\b', line) or m.group(1) == 'extension'
                  or (cur and m.group(1) in ('case', 'associatedtype'))):
            kind, rest = m.group(1), m.group(2)
            if kind in ('struct', 'enum', 'class', 'protocol', 'actor', 'extension'):
                mm = re.match(r'(?:\w+::)?\w+(?:\.(?:\w+::)?\w+)*', rest.strip())
                nm = mm.group(0) if mm else rest.strip()
                nm = '.'.join(strip_mod(x) for x in nm.split('.'))
                full = nm if (kind == 'extension' or not cur) else cur + '.' + nm
                if kind != 'extension' and '.' in nm:
                    full = nm
                t = types.setdefault(full, {'kind': kind if kind != 'extension' else None, 'members': []})
                if kind != 'extension':
                    t['kind'] = kind
                if '{' in line:
                    stack.append((full, depth))
            elif cur:
                t = types[cur]
                if kind == 'func':
                    nm = strip_mod(re.split(r'[\s(<]', rest.strip(), maxsplit=1)[0])
                    pb = paren_body(rest)
                    st = 'static ' if re.search(r'\b(static|class)\s+func\b', line) else ''
                    t['members'].append(f"{st}{nm}({label_list(pb or '')})")
                elif kind == 'init':
                    pb = paren_body(rest)
                    q = '?' if rest.startswith('?') else ''
                    t['members'].append(f"init{q}({label_list(pb or '')})")
                elif kind == 'subscript':
                    t['members'].append(f"subscript({label_list(paren_body(rest) or '')})")
                elif kind in ('var', 'let'):
                    nm = strip_mod(re.split(r'[\s:]', rest.strip(), maxsplit=1)[0])
                    st = 'static ' if re.search(r'\b(static|class)\s+(var|let)\b', line) else ''
                    t['members'].append(f"{st}{nm}")
                elif kind == 'case':
                    for c in re.split(r',(?![^(]*\))', rest):
                        cn = re.split(r'[\s(=]', c.strip(), maxsplit=1)[0]
                        if cn:
                            t['members'].append('case ' + strip_mod(cn))
                elif kind in ('typealias', 'associatedtype'):
                    nm = re.split(r'[\s=:]', rest.strip(), maxsplit=1)[0]
                    t['members'].append(f"{kind} {strip_mod(nm)}")
        depth += line.count('{') - line.count('}')
        while stack and depth <= stack[-1][1]:
            stack.pop()
    return types


def parse_objc(headers):
    classes = {}
    cur = None
    for h in headers:
        for raw in open(h, encoding='utf-8', errors='replace'):
            line = raw.split('//')[0].strip()
            m = re.match(r'@interface\s+(\w+)\s*(?::\s*(\w+))?\s*(\((\w*)\))?', line)
            if m:
                cur = classes.setdefault(m.group(1), {'super': None, 'members': []})
                if m.group(2):
                    cur['super'] = m.group(2)
                continue
            m = re.match(r'@protocol\s+(\w+)\b(?!;)', line)
            if m and not line.endswith(';'):
                cur = classes.setdefault(m.group(1), {'super': 'protocol', 'members': []})
                continue
            if line.startswith('@end'):
                cur = None
                continue
            if cur is None:
                continue
            m = re.match(r'@property\s*(\(([^)]*)\))?.*?(\w+)\s*(?:API_|NS_|__|;)', line)
            if m:
                attrs = m.group(2) or ''
                ro = ' (ro)' if 'readonly' in attrs else ''
                cls = '+' if 'class' in attrs.split(',') or ' class' in attrs else ''
                cur['members'].append(f"{cls}{m.group(3)}{ro}")
                continue
            m = re.match(r'([-+])\s*\([^)]*\)\s*(.*)', line)
            if m:
                body = re.split(r'\s+(?:API_|NS_|__|SK_)', m.group(2))[0]
                parts = re.findall(r'(\w+)\s*:', body)
                sel = ''.join(x + ':' for x in parts) if parts else re.match(r'(\w+)', body).group(1)
                cur['members'].append(('+' if m.group(1) == '+' else '') + sel)
    return classes


def main():
    out = ['<!-- Generated by research/experiments/storekit/gen_api.py; edit the generator, not this file. -->',
           '# StoreKit spec: Swift API name inventory', '',
           'Part of `specs/frameworks/storekit/`. Public Swift types of the iOS 27.1 SDK\'s',
           '`StoreKit` and `StoreKitTest` modules (simulator interface) with their kind and the',
           'names of their members: functions with argument labels, properties (`static`',
           'marked), enum cases, initializers, associated types. Names only (level 4);',
           'semantics are in the other files. Extensions are merged into the extended type.', '']
    swift = [p for p in sys.argv[1:] if p.endswith('.swiftinterface')]
    heads = [p for p in sys.argv[1:] if p.endswith('.h')]
    for path in swift:
        module = 'StoreKitTest' if 'StoreKitTest' in path else 'StoreKit'
        types = parse(path, module)
        out += [f'## Module `{module}`', '']
        for name in sorted(types, key=str.lower):
            t = types[name]
            mem = []
            for x in t['members']:
                if x not in mem:
                    mem.append(x)
            kind = t['kind'] or 'extension'
            out.append(f"### `{name}` ({kind})")
            out.append('')
            out.append('- ' + (', '.join(f'`{x}`' for x in mem) if mem else '(no members)'))
            out.append('')
    if heads:
        out += ['## Objective-C classes and protocols (StoreKit 1 and StoreKitTest headers)', '',
                'Selectors and property names; `+` marks class members, `(ro)` read-only properties.', '']
        cls = parse_objc(heads)
        for name in sorted(cls, key=str.lower):
            c = cls[name]
            if not c['members'] and not c['super']:
                continue
            sup = '' if not c['super'] else (' (protocol)' if c['super'] == 'protocol' else f" : `{c['super']}`")
            mem = []
            for x in c['members']:
                if x not in mem:
                    mem.append(x)
            out += [f"### `{name}`{sup}", '', '- ' + (', '.join(f'`{x}`' for x in mem) if mem else '(no members)'), '']
    out += ['## Evidence', '', 'Level 4: names extracted from the public SDK Swift interface files by our own',
            'generator. No declarations, types or documentation were copied.', '']
    sys.stdout.write('\n'.join(out))


if __name__ == '__main__':
    main()

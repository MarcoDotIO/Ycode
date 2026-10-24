import re, sys
# Inventory of a swiftinterface: names, kinds, availability only (no declarations).
path = sys.argv[1]
lines = open(path, encoding='utf-8').read().split('\n')
avail = []
attrs = []
stack = []  # (indent, label)
declre = re.compile(r'^(\s*)((?:@[\w.]+(?:\([^)]*\))?\s+)*)((?:(?:public|open|internal|private|fileprivate|final|nonisolated|static|class|override|convenience|required|indirect|mutating|nonmutating|dynamic|optional|weak|unowned|lazy|package|borrowing|consuming|isolated)\s+)*)(struct|class|enum|protocol|actor|extension|typealias|var|let|func|init[?!]?|subscript|case|associatedtype|macro|deinit)\b\s*(.*)$')
def ident(kind, rest):
    if kind.startswith('init') or kind=='subscript':
        m = re.match(r'(?:<[^>]*>)?\(', rest)
        return labels(rest)
    if kind=='func':
        m = re.match(r'([^\s(<]+)\s*(?:<[^(]*>)?\s*(\(.*)', rest)
        if m: return m.group(1) + labels(m.group(2))
        return rest.split('(')[0]
    if kind=='case':
        return re.split(r'[,(=]', rest)[0].strip() + ('(...)' if '(' in rest.split('=')[0] else '') + ((' +'+str(rest.count(',')) ) if ',' in rest and '(' not in rest else '')
    if kind in ('var','let'):
        return rest.split(':')[0].strip()
    if kind=='extension':
        return rest.split('{')[0].strip()
    return re.split(r'[\s:<{=]', rest)[0]
def labels(s):
    # crude: take first parenthesised group, collect argument labels
    depth=0; buf=''; out=[]; started=False
    for ch in s:
        if ch=='(':
            depth+=1
            if depth==1: started=True; continue
        elif ch==')':
            depth-=1
            if depth==0: out.append(buf); break
        if depth==1 and ch==',': out.append(buf); buf=''; continue
        if depth>=1: buf+=ch
    labs=[]
    for a in out:
        a=a.strip()
        if not a: continue
        a=re.sub(r'^@\w+\s+','',a)
        lab=a.split(':')[0].strip().split()
        if lab: labs.append(lab[0]+':')
    return '('+''.join(labs)+')'
def av(a):
    plats={}
    for x in a:
        for p,v in re.findall(r'\b(iOS|macOS|visionOS|tvOS|watchOS|macCatalyst)\s+([\d.]+)', x):
            plats.setdefault(p,v)
        if re.search(r'\biOS\s*,\s*unavailable|unavailable', x):
            for p in re.findall(r'\b(iOS|macOS|visionOS|tvOS)\b\s*,\s*unavailable', x): plats[p]='X'
        if 'deprecated' in x and 'iOS' in x: plats['dep']='y'
    return ' '.join(f'{k}{v}' for k,v in plats.items())
skipind=None
for ln in lines:
    ln=re.sub(r'\b\w+::','',ln)
    s = ln.strip()
    if skipind is not None:
        if s and (len(ln)-len(ln.lstrip()))>skipind: continue
        if s=='}' and (len(ln)-len(ln.lstrip()))==skipind: skipind=None; continue
        skipind=None
    if s.startswith('@available') or s.startswith('@_spi_available') or s.startswith('@backDeployed'):
        avail.append(s); continue
    if s.startswith('@') and not declre.match(ln):
        attrs.append(s); continue
    m = declre.match(ln)
    if m and not s.startswith('//'):
        ind=len(m.group(1)); kind=m.group(4); rest=m.group(5)
        if 'internal' in (m.group(3) or '').split() or 'private' in (m.group(3) or '').split() or 'fileprivate' in (m.group(3) or '').split() or any('usableFromInline' in a for a in attrs) or '@usableFromInline' in m.group(2):
            if kind in('struct','class','enum','protocol','actor','extension') and rest.rstrip().endswith('{'): skipind=ind
            avail=[]; attrs=[]; continue
        if '@_spi' in m.group(2) or any('@_spi' in a for a in attrs) or any('_spi' in a for a in avail):
            if kind in('struct','class','enum','protocol','actor','extension') and rest.rstrip().endswith('{'): skipind=ind
            avail=[]; attrs=[]; continue
        mods=(m.group(3) or '').split()
        k=('static ' if 'static' in mods or 'class' in mods and kind!='class' else '')+kind
        name=ident(kind,rest)
        if name.startswith('_') and kind not in('extension',):
            if kind in('struct','class','enum','protocol','actor') and rest.rstrip().endswith('{'): skipind=ind
            avail=[]; attrs=[]; continue
        extra=''
        if kind in('struct','class','enum','protocol','actor','extension'):
            mm=re.search(r':\s*([^{]*)', rest[len(name):]) if kind!='extension' else re.search(r':\s*([^{]*)', rest)
            if mm: extra=' : '+re.sub(r'\b(Swift|RealityFoundation|RealityKit|Foundation|CoreGraphics|simd|Metal)\.','',mm.group(1).strip())[:120]
            if kind=='extension': name=re.sub(r'\b(RealityFoundation|RealityKit|Swift|SwiftUI)\.','',name.split(':')[0].split(' where')[0].strip())
        if kind=='typealias': extra=' = '+re.sub(r'\b(Swift|RealityFoundation|RealityKit|Foundation|simd)\.','',rest.split('=',1)[-1].strip())[:80]
        print('  '*(ind//2) + f'{k} {name}{extra}' + (f'  [{av(avail)}]' if av(avail) else ''))
        avail=[]; attrs=[]

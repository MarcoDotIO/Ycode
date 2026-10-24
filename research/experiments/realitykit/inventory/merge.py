import re, sys, collections
types=collections.OrderedDict()  # name -> dict(kind, conf, av, members: list of (av, text))
def T(n):
    if n not in types: types[n]={'kind':'','conf':'','av':'','members':[]}
    return types[n]
def ios(a):
    m=re.search(r'iOS([\d.]+|X)',a); v=re.search(r'visionOS([\d.]+|X)',a)
    r=''
    if m: r='i'+m.group(1)
    if v: r+=' v'+v.group(1)
    if 'depy' in a: r+=' dep'
    return r.strip()
stack=[]  # (indent, typename, av)
for ln in open(sys.argv[1]):
    ln=ln.rstrip('\n')
    if not ln.strip(): continue
    ind=(len(ln)-len(ln.lstrip()))//2
    s=ln.strip()
    m=re.match(r'(.*?)(?:  \[(.*)\])?$', s); body=m.group(1); a=m.group(2) or ''
    while stack and stack[-1][0]>=ind: stack.pop()
    parent=stack[-1][1] if stack else None
    pav=stack[-1][2] if stack else ''
    km=re.match(r'(struct|class|enum|protocol|actor|extension)\s+([^\s:]+)(.*)',body)
    if km:
        kind,name,rest=km.groups()
        full=(parent+'.'+name) if parent else name
        t=T(full)
        if kind!='extension':
            t['kind']=kind; t['conf']=rest.strip(' :'); t['av']=ios(a)
        else:
            if rest.strip(' :'): t['members'].append((ios(a) or pav,'+conforms '+rest.strip(' :')))
        stack.append((ind,full,ios(a) or pav))
        continue
    if parent is None:
        T('<toplevel>')['members'].append((ios(a),body)); continue
    T(parent)['members'].append((ios(a) or pav, body))
for n,t in types.items():
    if not t['kind'] and not t['members']: continue
    print(f"## {t['kind'] or 'ext'} {n} {('['+t['av']+']') if t['av'] else ''} {(': '+t['conf']) if t['conf'] else ''}")
    groups=collections.OrderedDict()
    for a,b in t['members']:
        b=re.sub(r'^(static )?(func|var|let|init|case|typealias|subscript|associatedtype) ?',lambda m:('static ' if m.group(1) else '')+{'func':'','var':'','let':'','init':'init','case':'.','typealias':'alias ','subscript':'subscript','associatedtype':'assoc '}[m.group(2)],b)
        groups.setdefault(a,[]).append(b)
    for a,bs in groups.items():
        print(f"  {a or '-'}: "+'; '.join(dict.fromkeys(bs)))

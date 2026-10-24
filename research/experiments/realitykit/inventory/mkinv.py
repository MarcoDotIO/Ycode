import re, sys
# Build a name-only API inventory (markdown) from merged inventories.
out=[]
def avail_label(a):
    if not a or a=='-': return 'unannotated'
    m=re.match(r'(?:i([\d.]+|X))?\s*(?:v([\d.]+|X))?\s*(dep)?',a)
    i=m.group(1); v=m.group(2); dep=m.group(3)
    parts=[]
    if i=='X': parts.append('not iOS')
    elif i: parts.append('iOS '+i)
    if v=='X': parts.append('not visionOS')
    elif v: parts.append('visionOS '+v)
    if dep: parts.append('deprecated')
    return ', '.join(parts) or 'unannotated'
for fn,module in [(a,b) for a,b in zip(sys.argv[1::2],sys.argv[2::2])]:
    out.append(f'\n## Module `{module}`\n')
    cur=None
    for ln in open(fn):
        ln=ln.rstrip('\n')
        if ln.startswith('## '):
            m=re.match(r'## (\S+) (\S+) ?(\[[^\]]*\])? ?(: (.*))?',ln)
            kind,name,av,_,conf=m.groups()
            if name.startswith('__') or '.__' in name or name=='<toplevel>' or name.startswith('_'): cur=None; continue
            if kind=='ext' and name in ('Float','Double','SIMD2','SIMD3','SIMD4','simd_quatf','Bool','Int','String','simd_float4x4','Int32','UInt32','UInt','Int64','UInt64','Cancellable','AffineTransform3D','Rect3D','MTLCommandBuffer','View','Binding','Gesture','EnvironmentValues','MCPeerID'):
                cur=name; out.append(f'- extension of `{name}`'); continue
            cur=name
            conf=(conf or '').strip()
            conf=re.sub(r'\b(Swift|SwiftUI|Foundation|Combine)\.','',conf)
            conf=re.sub(r'_[A-Za-z]+,? ?','',conf).strip(', ')
            out.append(f'\n### `{name}` — {kind if kind!="ext" else "extension"}' + (f' ({avail_label(av.strip("[]"))})' if av else '') + (f'; conforms to {conf}' if conf else ''))
            continue
        if cur is None: continue
        m=re.match(r'\s+(\S[^:]*?):\s(.*)',ln)
        if not m: continue
        av,members=m.groups()
        items=[]
        for it in members.split('; '):
            it=it.strip()
            if not it or '=' in it and not it.startswith('alias') or it.startswith('alias') or it.startswith('+conforms _') : continue
            if re.search(r'hash\(into:\)|hashValue|^static ==|^static !=|^static <$|^encode\(to:\)|^init\(from:\)$|^deinit$', it): continue
            if it.startswith('+conforms'): it='conforms to '+re.sub(r'\b(Swift|SwiftUI|Foundation)\.','',it[10:]).replace('_ImplicitlyAnimatableBuiltinComponent','implicitly animatable')
            if '@' in it or '$' in it: continue
            items.append(it.replace('`',''))
        if items:
            out.append(f'  - {avail_label(av)}: ' + ', '.join(f'`{x}`' if not x.startswith('conforms') else x for x in items))
print('\n'.join(out))

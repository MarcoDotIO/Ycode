import re, sys, collections
# Tally an msparse.py listing (our recorder output): message types, device ops,
# textures (type, pixel format, usage, sample count), pipelines, record opcodes.
PF={1:'A8Unorm',10:'R8Unorm',11:'R8Unorm_sRGB',20:'R16Unorm',25:'R16Float',30:'RG8Unorm',53:'R32Uint',55:'R32Float',60:'RG16Unorm',65:'RG16Float',70:'RGBA8Unorm',71:'RGBA8Unorm_sRGB',80:'BGRA8Unorm',81:'BGRA8Unorm_sRGB',90:'RGB10A2Unorm',92:'RG11B10Float',93:'RGB9E5Float',103:'RG32Float',110:'RGBA16Unorm',115:'RGBA16Float',123:'RGBA32Uint',125:'RGBA32Float',252:'Depth32Float',253:'Stencil8',250:'Depth16Unorm',260:'Depth32Float_Stencil8',204:'ASTC_4x4_LDR',186:'ASTC_4x4_sRGB',554:'BGRA10_XR',552:'BGR10_XR'}
TT={0:'1D',1:'1DArray',2:'2D',3:'2DArray',4:'2DMS',5:'Cube',6:'CubeArray',7:'3D',8:'2DMSArray',9:'TexBuffer'}
mt=None; mtc=collections.Counter(); dev=collections.Counter(); tex=collections.Counter(); rec=collections.Counter(); misc=collections.Counter()
for ln in open(sys.argv[1], errors='replace'):
    m=re.match(r'#\d+ c\d+ C>S \w+ mt=(\d+)',ln)
    if m: mt=int(m.group(1)); mtc[mt]+=1; continue
    m=re.match(r'\s+cmd op=(\d+) len=\d+: (.*)',ln)
    if m and mt is not None:
        op=int(m.group(1)); w=[int(x,16) for x in m.group(2).split() if re.match(r'^[0-9a-f]+$',x)]
        if mt==12: dev[op]+=1
        elif mt==8 and op==1 and len(w)>5:
            ty=w[1]&15; usage=(w[1]>>8)&255; pf=w[1]>>16; mips=w[5]&0xffff; samples=w[5]>>16
            tex[(TT.get(ty,ty),PF.get(pf,pf),samples)]+=1
        elif mt==8: misc['mt8.op%d'%op]+=1
        elif mt==13: misc['iosurface texture']+=1
        continue
    m=re.match(r'\s+@\d+ op=(\d+) len',ln)
    if m: rec[int(m.group(1))]+=1
print('message types:', dict(sorted(mtc.items())))
print('device ops (mt 12):', dict(sorted(dev.items())))
print('textures (type, format, samples):')
for k,v in sorted(tex.items(), key=lambda x:-x[1]): print('  ',k,v)
print('other mt8/13:', dict(misc))
print('records:', dict(sorted(rec.items())))

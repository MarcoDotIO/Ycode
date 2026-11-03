# gen.py: writes vhid script lines for gaze/pinch sequences (our code).
#  tap dx dy [hold_ms]            gaze at head-space direction (dx,dy,-1), right pinch
#  drag dx dy hx0 hy0 hz0 hx1 hy1 hz1 steps   pinch, move the right hand from h0 to h1 (head space, m)
#  hover dx dy ms
#  rot  dx dy deg steps            pinch, rotate the right hand about z
#  two  dx dy sep0 sep1 steps     both hands pinch, hand separation sep0->sep1 (magnify)
import sys, math, os
O=os.environ.get("ORIGIN","0 0 0")
a=sys.argv[1:]; cmd=a[0]; v=[float(x) for x in a[1:]]
L=[-0.15,-0.35,-0.4]; R=[0.15,-0.35,-0.4]; Q=[0,0,0,1]
DZ=float(os.environ.get('DZ','-1'))
def coll(dx,dy,pl=0,pr=0,hl=L,hr=R,ql=Q,qr=Q,dz=None):
    dz=DZ if dz is None else dz
    h=' '.join(map(str,hl+ql+hr+qr))
    return f"coll 301 {O} {dx} {dy} {dz} 0 {pl} 0 0 {pr} 0 {h}"
def out(l): print(l)
def frame(l,ms=16): out(l); out(f"sleep {ms}")
if cmd=='tap':
    dx,dy=v[0],v[1]; hold=int(v[2]) if len(v)>2 else 100
    for _ in range(5): frame(coll(dx,dy))
    for _ in range(max(1,hold//16)): frame(coll(dx,dy,pr=1))
    for _ in range(5): frame(coll(dx,dy))
elif cmd=='hover':
    for _ in range(int(v[2])//16): frame(coll(v[0],v[1]))
elif cmd=='drag':
    dx,dy=v[0],v[1]; h0=v[2:5]; h1=v[5:8]; n=int(v[8])
    for _ in range(5): frame(coll(dx,dy,hr=h0))
    for i in range(n+1):
        t=i/n; h=[h0[k]+(h1[k]-h0[k])*t for k in range(3)]; frame(coll(dx,dy,pr=1,hr=h))
    for _ in range(5): frame(coll(dx,dy,hr=h1))
elif cmd=='rot':
    dx,dy,deg,n=v[0],v[1],v[2],int(v[3])
    for _ in range(5): frame(coll(dx,dy))
    for i in range(n+1):
        th=math.radians(deg*i/n)/2; q=[0,0,math.sin(th),math.cos(th)]; frame(coll(dx,dy,pr=1,qr=q))
    for _ in range(5): frame(coll(dx,dy))
elif cmd=='two':
    dx,dy,s0,s1,n=v[0],v[1],v[2],v[3],int(v[4])
    for _ in range(5): frame(coll(dx,dy))
    for i in range(n+1):
        s=s0+(s1-s0)*i/n; frame(coll(dx,dy,pl=1,pr=1,hl=[-s/2,-0.35,-0.4],hr=[s/2,-0.35,-0.4]))
    for _ in range(5): frame(coll(dx,dy))
elif cmd=='tworot':
    dx,dy,deg,n=v[0],v[1],v[2],int(v[3]); r=0.15
    for _ in range(5): frame(coll(dx,dy))
    for i in range(n+1):
        th=math.radians(deg*i/n); c,s=math.cos(th)*r,math.sin(th)*r
        frame(coll(dx,dy,pl=1,pr=1,hl=[-c,-0.35-s,-0.4],hr=[c,-0.35+s,-0.4]))
    for _ in range(5): frame(coll(dx,dy))
elif cmd=='poke':
    # poke dx dy hx hy hz0 hz1 steps pinch : right hand allowed direct (b7), moves along z
    dx,dy,hx,hy,z0,z1,n,pin=v[0],v[1],v[2],v[3],v[4],v[5],int(v[6]),int(v[7])
    h=' '.join(map(str,L+Q))
    def cd(z,p): return f"coll 301 {O} {dx} {dy} {DZ} 0 0 0 0 {p} 1 {h} {hx} {hy} {z} 0 0 0 1"
    for i in range(n+1): frame(cd(z0+(z1-z0)*i/n, 0))
    for i in range(4): frame(cd(z1, pin))
    for i in range(n+1): frame(cd(z1+(z0-z1)*i/n, 0))

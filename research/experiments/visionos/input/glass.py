# glass.py: fit glass = a*blur(bg, r) + c per channel over a box (full-res coords) (our analysis code)
import sys, numpy as np
from PIL import Image, ImageFilter
bg=Image.open(sys.argv[1]).convert('RGB'); gl=Image.open(sys.argv[2]).convert('RGB')
x0,y0,x1,y1=map(int,sys.argv[3:7])
G=np.asarray(gl.crop((x0,y0,x1,y1)),dtype=float)
print("glass mean",G.reshape(-1,3).mean(0).round(1),"std",G.reshape(-1,3).std(0).round(2))
B0=np.asarray(bg.crop((x0,y0,x1,y1)),dtype=float)
print("bg mean",B0.reshape(-1,3).mean(0).round(1),"std",B0.reshape(-1,3).std(0).round(2))
for r in [int(x) for x in (sys.argv[7] if len(sys.argv)>7 else "0,16,64,128,192,256,384").split(",")]:
    b=bg.filter(ImageFilter.GaussianBlur(r)) if r else bg
    B=np.asarray(b.crop((x0,y0,x1,y1)),dtype=float)
    res=[]
    for ch in range(3):
        x=B[...,ch].ravel(); y=G[...,ch].ravel(); A=np.vstack([x,np.ones_like(x)]).T
        sol,_,_,_=np.linalg.lstsq(A,y,rcond=None); pred=A@sol; r2=1-((y-pred)**2).sum()/((y-y.mean())**2).sum()
        res.append((round(sol[0],3),round(sol[1],1),round(r2,3)))
    print("blur",r,res)

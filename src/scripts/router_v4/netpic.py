"""netpic.py pcb out.png NET[,NET..]|BASE=<file> : whole board, grey copper, named nets (or the nets added after BASE) highlighted (F red, B blue, vias purple); CROP=x0,y0,x1,y1 mm"""
import os, sys; TOOLS=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,TOOLS)
from board import *
from PIL import Image, ImageDraw
pcb,out=sys.argv[1:3]; SC=int(os.environ.get('SC','4'))
b,nets,fps,pads,edges=load(pcb); nid={v:k for k,v in nets.items()}
if len(sys.argv)>3: hi={nid[n] for n in (([l.strip() for l in open(sys.argv[3][1:],encoding='utf-8') if l.strip()]) if sys.argv[3].startswith('@') else sys.argv[3].split(',')) if n in nid}
else:
    cut=len(open(os.environ['BASE']).read().rstrip())-2; tail=parse('(kicad_pcb '+open(pcb).read()[cut:])
    hi={int(one(x,'net')[1]) for x in find(tail,'segment')+find(tail,'via')}
o=outline(edges); X0=min(x for x,y in o)-1; Y0=min(y for x,y in o)-1; X1=max(x for x,y in o)+1; Y1=max(y for x,y in o)+1
if os.environ.get('CROP'): X0,Y0,X1,Y1=map(float,os.environ['CROP'].split(','))
im=Image.new('RGB',(int((X1-X0)*SC),int((Y1-Y0)*SC)),'white'); d=ImageDraw.Draw(im,'RGBA')
def T(x,y): return ((x-X0)*SC,(y-Y0)*SC)
d.polygon([T(*p) for p in o],outline=(0,0,0))
for p in pads:
    g=pad_poly(p); d.polygon([T(x,y) for x,y in g.exterior.coords],fill=(60,60,60,255) if p['net'] in hi else (200,200,200,255))
for s in find(b,'segment'):
    L=one(s,'layer')[1]; n=int(one(s,'net')[1])
    a=tuple(map(float,one(s,'start')[1:3])); e=tuple(map(float,one(s,'end')[1:3]))
    if n in hi: d.line([T(*a),T(*e)],fill=(255,0,0,255) if L=='F.Cu' else (0,0,255,255),width=3)
    elif L in ('F.Cu','B.Cu'): d.line([T(*a),T(*e)],fill=(215,215,215,255),width=1)
for v in find(b,'via'):
    if int(one(v,'net')[1]) in hi:
        cx,cy=T(*map(float,one(v,'at')[1:3])); d.ellipse([cx-4,cy-4,cx+4,cy+4],fill=(140,0,140,255))
for ref,x,y,a,name in fps:
    if ref[0] in 'UXJ' or ref.startswith('NT'): d.text(T(x,y),ref,fill=(0,110,0,255))
im.save(out); print(out)

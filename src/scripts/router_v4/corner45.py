"""corner45.py in out [NETS=@file|a,b] : 45-degree finishing. Every 90-degree corner of the scope nets' tracks (two
segments meeting, same layer, no via or pad at the corner) is chamfered with a diagonal of up to LMAX mm (LMAX=2, at most
half of each leg, at least LMIN=0.5) when the diagonal keeps clearance to every other net's copper, the board edge
rule and the mounting-hole bands. Checks use the original copper, so the result is conservative. The input file is not
modified. env: LMAX=2 LMIN=0.5 KEEP=GND,+5V (never touched)"""
import sys, os, re, math, uuid
TOOLS=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,TOOLS)
from board import load, outline, pad_poly
from rules import EDGE, hole_edge_keepouts
from shapely.geometry import LineString, Point, Polygon
from shapely.strtree import STRtree
E=os.environ.get
src,dst=sys.argv[1:3]; LMAX=float(E('LMAX','2')); LMIN=float(E('LMIN','0.5')); KEEP=set(E('KEEP','GND,+5V').split(',')); NETS=E('NETS')
W=0.3; CLR=0.25
b,nets,fps,pads,edges=load(src); nid={v:k for k,v in nets.items()}
txt=open(src,encoding='utf-8').read()
def netlist(spec):
    if spec and spec.startswith('@'): return [l.strip() for l in open(spec[1:],encoding='utf-8') if l.strip()]
    return spec.split(',') if spec else []
scope={nid[x] for x in netlist(NETS) if x in nid} if NETS else {n for n,name in nets.items() if n and name not in KEEP and not name.startswith('unconnected-')}
segre=re.compile(r'\n\t\(segment\n(?:.*\n)*?\t\)'); viare=re.compile(r'\n\t\(via\n(?:.*\n)*?\t\)')
def num(blk,key):
    m=re.search(r'\('+key+r' ([-\d.]+) ([-\d.]+)\)',blk); return (float(m.group(1)),float(m.group(2)))
segs=[]
for m in segre.finditer(txt):
    blk=m.group(0)
    segs.append(dict(span=(m.start(),m.end()),a=num(blk,'start'),e=num(blk,'end'),w=float(re.search(r'\(width ([\d.]+)\)',blk).group(1)),
                     layer=re.search(r'\(layer "([^"]+)"\)',blk).group(1),net=int(re.search(r'\(net (\d+)\)',blk).group(1))))
vias=[]
for m in viare.finditer(txt):
    blk=m.group(0); vias.append(dict(at=num(blk,'at'),d=float(re.search(r'\(size ([\d.]+)\)',blk).group(1)),net=int(re.search(r'\(net (\d+)\)',blk).group(1))))
# obstacle trees per layer: other nets' copper (segments, vias, pads) + edge band + hole bands
bp=Polygon(outline(edges)); band=bp.exterior.buffer(EDGE); holes=hole_edge_keepouts(pads,bp)
geoms={L:[] for L in ('F.Cu','B.Cu')}; owners={L:[] for L in geoms}
for s in segs:
    if s['layer'] in geoms: geoms[s['layer']].append(LineString([s['a'],s['e']]).buffer(s['w']/2,8)); owners[s['layer']].append(s['net'])
for v in vias:
    for L in geoms: geoms[L].append(Point(v['at']).buffer(v['d']/2,16)); owners[L].append(v['net'])
for p in pads:
    for L in geoms:
        if L in p['layers'] or '*.Cu' in p['layers']: geoms[L].append(pad_poly(p)); owners[L].append(p['net'] or -1)
for L in geoms:
    for hgeom in [band]+holes: geoms[L].append(hgeom); owners[L].append(-2)
trees={L:STRtree(geoms[L]) for L in geoms}
viapts={(round(v['at'][0],4),round(v['at'][1],4)) for v in vias}
padtree=STRtree([pad_poly(p) for p in pads])
def P(x,y): return (round(x,4),round(y,4))
ends={}
for i,s in enumerate(segs):
    if s['net'] not in scope or s['layer'] not in geoms or abs(s['w']-W)>1e-6: continue
    ends.setdefault((s['net'],s['layer'],P(*s['a'])),[]).append((i,'a')); ends.setdefault((s['net'],s['layer'],P(*s['e'])),[]).append((i,'e'))
new=[]; moved={}; done=0; tried=0
for (n,L,pt),lst in ends.items():
    if len(lst)!=2 or pt in viapts: continue
    if any(padtree.geometries.take(k).contains(Point(pt)) for k in padtree.query(Point(pt))): continue
    legs=[]
    for i,end in lst:
        s=segs[i]; other=s['e'] if end=='a' else s['a']; dx=other[0]-pt[0]; dy=other[1]-pt[1]; ln=math.hypot(dx,dy)
        if ln<1e-6: break
        if abs(dx)>1e-6 and abs(dy)>1e-6: break   # already diagonal
        legs.append((i,end,dx/ln,dy/ln,ln))
    if len(legs)!=2 or abs(legs[0][2]*legs[1][2]+legs[0][3]*legs[1][3])>1e-6: continue   # not perpendicular
    tried+=1
    Lc=min(LMAX,legs[0][4]/2,legs[1][4]/2)
    if Lc<LMIN: continue
    A=(pt[0]+legs[0][2]*Lc,pt[1]+legs[0][3]*Lc); B=(pt[0]+legs[1][2]*Lc,pt[1]+legs[1][3]*Lc)
    diag=LineString([A,B]).buffer(W/2+CLR,8)
    tree=trees[L]; own=owners[L]; ok=True
    for k in tree.query(diag):
        if own[k]!=n and tree.geometries.take(k).intersects(diag): ok=False; break
    if not ok: continue
    for i,end,_,_,_ in legs: moved[(i,end)]=A if (i,end)==(legs[0][0],legs[0][1]) else B
    new.append((n,L,A,B)); done+=1
# write: edited segment blocks + new diagonals before the final ')'
out=[]; pos=0; zero=0
for i,s in enumerate(segs):
    a=moved.get((i,'a'),s['a']); e=moved.get((i,'e'),s['e'])
    if a==s['a'] and e==s['e'] and math.dist(a,e)>1e-6: continue
    st,en=s['span']
    if math.dist(a,e)<=1e-6:   # a leg eaten by the chamfers at both ends (or an existing zero-length track): drop it
        out.append(txt[pos:st]); pos=en; zero+=1; continue
    blk=txt[st:en]
    blk=re.sub(r'\(start [-\d.]+ [-\d.]+\)',f'(start {a[0]:.4f} {a[1]:.4f})',blk,count=1); blk=re.sub(r'\(end [-\d.]+ [-\d.]+\)',f'(end {e[0]:.4f} {e[1]:.4f})',blk,count=1)
    out.append(txt[pos:st]); out.append(blk); pos=en
out.append(txt[pos:]); t=''.join(out)
i=t.rstrip().rfind(')'); head=t[:i].rstrip('\n')
add=[f'\t(segment\n\t\t(start {A[0]:.4f} {A[1]:.4f})\n\t\t(end {B[0]:.4f} {B[1]:.4f})\n\t\t(width {W})\n\t\t(layer "{L}")\n\t\t(net {n})\n\t\t(uuid "{uuid.uuid4()}")\n\t)' for n,L,A,B in new]
open(dst,'w',encoding='utf-8').write(head+'\n'+'\n'.join(add)+'\n)\n')
print(f'corners {tried}, chamfered {done} ({len(scope)} nets), zero-length tracks dropped {zero}; wrote {dst}')

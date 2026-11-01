"""score.py pcb [BASE=base.kicad_pcb] [NETS=a,b] [JSON=out.json] : one report for comparing router results.
Scope: the nets given by NETS, else the nets whose copper was added after BASE (same file prefix), else every signal net.
Per scope: open connections, track length, vias, detour ratio (track length / rectilinear spanning length of the pads),
wrong-way share (F.Cu vertical / B.Cu horizontal, by length), diagonal share, bends, rule breaks (copper < EDGE mm from the
outline, copper between a mounting hole and the edge), self-parallel places, clearance collisions, and the 8 worst nets."""
import sys, os, math, json, re, collections
TOOLS=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,TOOLS)
from board import *
from rules import EDGE, hole_edge_keepouts
from shapely.geometry import LineString, Point, Polygon
from shapely.strtree import STRtree
E=os.environ.get
pcb=sys.argv[1]; BASE=E('BASE'); NETS=E('NETS'); LAY=('F.Cu','B.Cu')
def netlist(spec):
    if spec and spec.startswith('@'): return [l.strip() for l in open(spec[1:],encoding='utf-8') if l.strip()]
    return spec.split(',') if spec else []
b,nets,fps,pads,edges=load(pcb); nid={v:k for k,v in nets.items()}
bp=Polygon(outline(edges))
segs=[]; vias=[]
for s in find(b,'segment'):
    a=tuple(map(float,one(s,'start')[1:3])); e=tuple(map(float,one(s,'end')[1:3]))
    segs.append((int(one(s,'net')[1]),one(s,'layer')[1],a,e,float(one(s,'width')[1])))
for v in find(b,'via'):
    vias.append((int(one(v,'net')[1]),tuple(map(float,one(v,'at')[1:3])),float(one(v,'size')[1])))
if NETS: scope={nid[x] for x in netlist(NETS) if x in nid}
elif BASE:
    cut=len(open(BASE).read().rstrip())-2; tail=parse('(kicad_pcb '+open(pcb).read()[cut:])
    scope={int(one(s,'net')[1]) for s in find(tail,'segment')+find(tail,'via')}
else: scope={n for n in nets if n and not nets[n].startswith('unconnected-') and nets[n] not in ('GND','+5V')}
scope={n for n in scope if n in nets}
# connectivity
from conn import conn
opens=conn(pcb); open_in_scope={k:v for k,v in opens.items() if nid.get(k) in scope}
# per-net length, vias, bends, wrong-way, diagonal
per=collections.defaultdict(lambda: dict(track=0.0,vias=0,wrong=0.0,diag=0.0,segs=0))
for n,L,a,e,w in segs:
    if n not in scope or L not in LAY: continue
    d=math.dist(a,e); dx=abs(e[0]-a[0]); dy=abs(e[1]-a[1]); p=per[n]; p['track']+=d; p['segs']+=1
    if dx>1e-6 and dy>1e-6: p['diag']+=d
    elif (L=='F.Cu' and dy>dx) or (L=='B.Cu' and dx>dy): p['wrong']+=d
for n,at,sz in vias:
    if n in scope: per[n]['vias']+=1
# bends: count direction changes along chains of same-layer segments (approximate: segments per net minus straight joins)
def rect_mst(pts):
    if len(pts)<2: return 0.0
    inT=[0]; d=[abs(p[0]-pts[0][0])+abs(p[1]-pts[0][1]) for p in pts]; tot=0.0
    for _ in range(len(pts)-1):
        j=min((i for i in range(len(pts)) if i not in inT),key=lambda i:d[i]); tot+=d[j]; inT.append(j)
        for i in range(len(pts)):
            if i not in inT: d[i]=min(d[i],abs(pts[i][0]-pts[j][0])+abs(pts[i][1]-pts[j][1]))
    return tot
padsby=collections.defaultdict(list)
for p in pads:
    if p['net'] in scope and p['kind']!='np_thru_hole': padsby[p['net']].append((p['x'],p['y']))
for n in scope:
    per[n]['mst']=rect_mst(padsby[n]); per[n]['pins']=len(padsby[n])
    per[n]['detour']=per[n]['track']/per[n]['mst'] if per[n]['mst']>0 else 0.0
# rule breaks: outline clearance and hole-edge bands (scope copper only)
inner=bp.buffer(-EDGE+1e-3,join_style=2); bands=hole_edge_keepouts(pads,bp,0.0)
edge_breaks=[]; band_breaks=[]
for n,L,a,e,w in segs:
    if n not in scope or L not in LAY: continue
    g=LineString([a,e]).buffer(w/2,8)
    if not inner.contains(g): edge_breaks.append((nets[n],L,a))
    if any(g.intersects(k) for k in bands): band_breaks.append((nets[n],L,a))
for n,at,sz in vias:
    if n not in scope: continue
    g=Point(at).buffer(sz/2,8)
    if not inner.contains(g): edge_breaks.append((nets[n],'via',at))
    if any(g.intersects(k) for k in bands): band_breaks.append((nets[n],'via',at))
# self-parallel (same layer, 0.3-0.9 mm apart, overlap >= 2 mm)
items=[(n,L,LineString([a,e])) for n,L,a,e,w in segs if n in scope and L in LAY and a!=e]
tree=STRtree([g for _,_,g in items]); selfpar=collections.Counter()
for i,(n,L,g) in enumerate(items):
    if g.length<2: continue
    for j in tree.query(g.buffer(0.9)):
        if j<=i: continue
        n2,L2,g2=items[j]
        if n!=n2 or L!=L2 or g2.length<2: continue
        d=g.distance(g2)
        if 0.3<d<0.9:
            p1=g.project(Point(g2.coords[0])); p2=g.project(Point(g2.coords[-1]))
            if abs(p1-p2)>=2 and abs(g.distance(g2.interpolate(0.5,normalized=True))-d)<0.05: selfpar[nets[n]]+=1
# clearance collisions of scope copper against everything (< 0.25 mm on F/B.Cu)
allit=[]
for n,L,a,e,w in segs:
    if L in LAY: allit.append((n,L,LineString([a,e]).buffer(w/2),'seg'))
for n,at,sz in vias:
    for L in LAY: allit.append((n,L,Point(at).buffer(sz/2),'via'))
for p in pads:
    if p['kind']=='np_thru_hole': continue
    for L in (LAY if '*.Cu' in p['layers'] else [l for l in p['layers'] if l in LAY]): allit.append((p['net'],L,pad_poly(p),'pad'))
tree=STRtree([g for _,_,g,_ in allit]); coll=[]; seen=set()
for i,(n,L,g,k) in enumerate(allit):
    if k=='pad' or n not in scope: continue
    for j in tree.query(g.buffer(0.25)):
        n2,L2,g2,k2=allit[j]
        if L==L2 and n!=n2 and g.distance(g2)<0.2499:
            key=tuple(sorted((i,int(j))))
            if key not in seen: seen.add(key); coll.append((nets[n],nets.get(n2,''),round(g.centroid.x,1),round(g.centroid.y,1),L))
tot=dict(nets=len(scope),open_nets=len(open_in_scope),open_connections=sum(len(v)-1 for v in open_in_scope.values()),
         track_m=round(sum(p['track'] for p in per.values())/1000,2),vias=sum(p['vias'] for p in per.values()),
         vias_board=len(vias),segments=sum(p['segs'] for p in per.values()),
         wrong_way_pct=round(100*sum(p['wrong'] for p in per.values())/max(1e-9,sum(p['track'] for p in per.values())),1),
         diagonal_pct=round(100*sum(p['diag'] for p in per.values())/max(1e-9,sum(p['track'] for p in per.values())),1),
         detour_mean=round(sum(p['detour'] for n,p in per.items() if p['mst']>0)/max(1,sum(1 for p in per.values() if p['mst']>0)),2),
         detour_over2=sorted([nets[n] for n,p in per.items() if p['detour']>2]),
         edge_breaks=len(edge_breaks),hole_band_breaks=len(band_breaks),self_parallel=sum(selfpar.values()),collisions=len(coll))
worst=sorted(per.items(),key=lambda kv:-kv[1]['track'])[:8]
print(f"# score {os.path.basename(pcb)}  (scope {tot['nets']} nets)")
print("| open nets | open conns | track | vias (scope / board) | wrong-way | diagonal | detour mean | detour>2 | edge | hole band | self-par | collisions |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|")
print(f"| {tot['open_nets']} | {tot['open_connections']} | {tot['track_m']} m | {tot['vias']} / {tot['vias_board']} | {tot['wrong_way_pct']} % | {tot['diagonal_pct']} % | {tot['detour_mean']} | {len(tot['detour_over2'])} | {tot['edge_breaks']} | {tot['hole_band_breaks']} | {tot['self_parallel']} | {tot['collisions']} |")
print('\nworst nets (track mm, vias, detour):',', '.join(f"{nets[n]} {p['track']:.0f}/{p['vias']}/{p['detour']:.1f}" for n,p in worst))
if tot['detour_over2']: print('detour > 2:',', '.join(tot['detour_over2']))
if open_in_scope: print('open:',', '.join(sorted(open_in_scope)))
if coll: print('collisions:',coll[:10])
if edge_breaks: print('edge:',edge_breaks[:5])
if band_breaks: print('hole band:',band_breaks[:5])
if E('JSON'):
    json.dump(dict(total=tot,nets={nets[n]:{k:(round(v,2) if isinstance(v,float) else v) for k,v in p.items()} for n,p in per.items()}),open(E('JSON'),'w'),indent=1)

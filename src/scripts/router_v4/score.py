"""score.py pcb [BASE=base.kicad_pcb] [NETS=a,b] [JSON=out.json] : one report for comparing router results.
Scope: the nets given by NETS, else the nets whose copper was added after BASE (same file prefix), else every signal net.
Per scope: open connections, track length, vias, detour ratio (track length / rectilinear spanning length of the pads),
wrong-way share (F.Cu vertical / B.Cu horizontal, by length), diagonal share, bends, rule breaks (copper < EDGE mm from the
outline, copper between a mounting hole and the edge), self-parallel places, clearance collisions, and the 8 worst nets.
BUDGET=budgets.json (budgets.py): also the track-length budget breaks (pairs over budget, measured on the real tracks).
Power-layer jumpers (tracks of scope nets on In2.Cu, the +5V plane; tidy JUMP=1): their number, length and longest run, the
smallest distance between two of them, clearance on that layer, and the plane check: the +5V zone is rebuilt from its
outline (0.3 mm clearance, 0.25 mm minimum width) and must stay one piece that still reaches every +5V through pad and via."""
import sys, os, math, json, re, collections
TOOLS=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,TOOLS)
from board import *
from rules import EDGE, hole_edge_keepouts
from shapely.geometry import LineString, Point, Polygon
from shapely.strtree import STRtree
E=os.environ.get
pcb=sys.argv[1]; BASE=E('BASE'); NETS=E('NETS'); LAY=('F.Cu','B.Cu'); JL='In2.Cu'; JPLANE='+5V'
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
jsegs=[(n,a,e,w) for n,L,a,e,w in segs if L==JL and n in scope]
CL=LAY+(JL,) if jsegs else LAY   # the jumper layer is checked like the outer layers when it carries tracks
allit=[]
for n,L,a,e,w in segs:
    if L in CL: allit.append((n,L,LineString([a,e]).buffer(w/2),'seg'))
for n,at,sz in vias:
    for L in CL: allit.append((n,L,Point(at).buffer(sz/2),'via'))
for p in pads:
    if p['kind']=='np_thru_hole': continue
    for L in (CL if '*.Cu' in p['layers'] else [l for l in p['layers'] if l in CL]): allit.append((p['net'],L,pad_poly(p),'pad'))
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
# power-layer jumpers and the plane they cut
jump=None
if jsegs:
    from shapely.ops import unary_union
    par=list(range(len(jsegs)))
    def jf(i):
        while par[i]!=i: par[i]=par[par[i]]; i=par[i]
        return i
    for i in range(len(jsegs)):
        for j in range(i+1,len(jsegs)):
            if jsegs[i][0]==jsegs[j][0] and {jsegs[i][1],jsegs[i][2]}&{jsegs[j][1],jsegs[j][2]}: par[jf(i)]=jf(j)
    runs=collections.defaultdict(list)
    for i,sg in enumerate(jsegs): runs[jf(i)].append(sg)
    rl=[(sum(math.dist(a,e) for _,a,e,_ in v),nets[v[0][0]],unary_union([LineString([a,e]) for _,a,e,_ in v])) for v in runs.values()]
    near=min((rl[i][2].distance(rl[j][2]) for i in range(len(rl)) for j in range(i+1,len(rl))),default=None)
    ZC=0.3; ZMIN=0.25; pn=nid.get(JPLANE)
    def plane(with_jumpers):
        obs=[]; own=[]
        for p in pads:
            if p['kind']=='np_thru_hole': obs.append(Point(p['x'],p['y']).buffer(p['drill']/2+ZC,16)); continue
            if '*.Cu' not in p['layers'] and JL not in p['layers']: continue
            (own if p['net']==pn else obs).append(pad_poly(p) if p['net']==pn else pad_poly(p).buffer(ZC,8))
        for n,at,sz in vias: (own if n==pn else obs).append(Point(at).buffer(sz/2,16) if n==pn else Point(at).buffer(sz/2+ZC,16))
        for n,L,a,e,w in segs:
            if L==JL and n!=pn and (with_jumpers or n not in scope): obs.append(LineString([a,e]).buffer(w/2+ZC,8))
        z=bp.buffer(-0.5).difference(unary_union(obs)).buffer(-ZMIN/2,8).buffer(ZMIN/2,8)   # opening: copper thinner than the minimum width goes
        parts=sorted((list(z.geoms) if hasattr(z,'geoms') else [z]),key=lambda g:-g.area)
        main=parts[0]; off=sum(1 for g in own if not g.buffer(0.5+ZMIN).intersects(main))   # 0.5 mm thermal gap around the pad
        return len([g for g in parts if g.area>0.5]),off,len(own)
    isl,off,nown=plane(True); isl0,off0,_=plane(False)
    jump=dict(jumpers=len(rl),jumper_mm=round(sum(r[0] for r in rl),1),jumper_max_mm=round(max(r[0] for r in rl),2),jumper_min_gap_mm=None if near is None else round(near,2),
              plane_pieces=isl,plane_pieces_without=isl0,plane_pads_off=off,plane_pads_off_without=off0,plane_pads=nown,jumper_nets=sorted(set(r[1] for r in rl)))
    tot.update(jump)
worst=sorted(per.items(),key=lambda kv:-kv[1]['track'])[:8]
print(f"# score {os.path.basename(pcb)}  (scope {tot['nets']} nets)")
print("| open nets | open conns | track | vias (scope / board) | wrong-way | diagonal | detour mean | detour>2 | edge | hole band | self-par | collisions |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|")
print(f"| {tot['open_nets']} | {tot['open_connections']} | {tot['track_m']} m | {tot['vias']} / {tot['vias_board']} | {tot['wrong_way_pct']} % | {tot['diagonal_pct']} % | {tot['detour_mean']} | {len(tot['detour_over2'])} | {tot['edge_breaks']} | {tot['hole_band_breaks']} | {tot['self_parallel']} | {tot['collisions']} |")
print('\nworst nets (track mm, vias, detour):',', '.join(f"{nets[n]} {p['track']:.0f}/{p['vias']}/{p['detour']:.1f}" for n,p in worst))
if jump:
    print(f"\npower-layer jumpers ({JL}): {jump['jumpers']} on {len(jump['jumper_nets'])} nets, {jump['jumper_mm']} mm in all, longest {jump['jumper_max_mm']} mm, closest pair {jump['jumper_min_gap_mm']} mm apart")
    print(f"{JPLANE} plane: {jump['plane_pieces']} piece(s) (without the jumpers {jump['plane_pieces_without']}), {jump['plane_pads_off']} of {jump['plane_pads']} {JPLANE} pads and vias off the main piece (without the jumpers {jump['plane_pads_off_without']})")
    print('jumper nets:',', '.join(jump['jumper_nets']))
if tot['detour_over2']: print('detour > 2:',', '.join(tot['detour_over2']))
if open_in_scope: print('open:',', '.join(sorted(open_in_scope)))
if coll: print('collisions:',coll[:10])
if edge_breaks: print('edge:',edge_breaks[:5])
if band_breaks: print('hole band:',band_breaks[:5])
if E('JSON'):
    json.dump(dict(total=tot,nets={nets[n]:{k:(round(v,2) if isinstance(v,float) else v) for k,v in p.items()} for n,p in per.items()}),open(E('JSON'),'w'),indent=1)
if E('BUDGET'):
    import tracklen
    J=json.load(open(E('BUDGET'),encoding='utf-8')); keys=[(net,a,b) for net,fr in J.get('max',{}).items() for a,tos in fr.items() for b in tos]
    keys=[k for k in keys if nid.get(k[0]) in scope]
    got=tracklen.measure((b,nets,fps,pads,edges),keys)
    over=sorted(((got[k]-J['max'][k[0]][k[1]][k[2]],k) for k in keys if got[k] is not None and got[k]>J['max'][k[0]][k[1]][k[2]]),reverse=True)
    mins=[(net,a,bb,mm,got2) for net,fr in J.get('min',{}).items() if nid.get(net) in scope for a,tos in fr.items() for bb,mm in tos.items()
          for got2 in [tracklen.measure((b,nets,fps,pads,edges),[(net,a,bb)])[(net,a,bb)]]]
    print(f"\nlength budgets ({E('BUDGET')}): {len(keys)} pairs in scope, {len(over)} over budget by {sum(o for o,_ in over):.0f} mm, {sum(1 for k in keys if got[k] is None)} not connected")
    for o,k in over[:12]: print(f'  {k[0]} {k[1]}->{k[2]}: {got[k]:.1f} mm, budget {J["max"][k[0]][k[1]][k[2]]:.1f} (+{o:.1f})')
    for net,a,bb,mm,v in mins: print(f'  minimum {net} {a}->{bb}: {v if v is None else round(v,1)} mm (needs {mm})')


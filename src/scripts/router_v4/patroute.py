"""patroute.py in out [NETS=a,b|@file] : pattern (lane) router, Justin's idea: every connection is laid as a straight run,
an L (one via) or a Z / U (two vias) on the preferred layers (F horizontal, B vertical), shortest connections first,
each run checked cell by cell against fixed copper, the rules and the routes already placed. A Z's middle run is put
as close to the start pin as the free space allows, so parallel nets pack into bundles. What no pattern can do is
left open for mroute4 (run mroute4 on the output; its routes become fixed copper there).
env: ORDER=short|long  ZMAX=60 (mm scanned for the Z middle run)  SAMPLE=48 (cells per group tried as end points)
     VIA=120 (via price in cells when ranking the candidate shapes)  KEEP as mroute4 (GND,+5V never routed)"""
import sys, os, time, math
import numpy as np
TOOLS=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,TOOLS)
from gridcore import *
from scipy.ndimage import label
E=os.environ.get
src,dst=sys.argv[1:3]; ORDER=E('ORDER','short'); ZMAX=int(float(E('ZMAX','60'))/G); SAMPLE=int(E('SAMPLE','48')); NETS=E('NETS')
T0=time.time()
g=Grid(src,None,scope=set()); nets=g.nets; nid=g.nid; nx,ny=g.nx,g.ny
S8=np.ones((3,3),bool)
def fixed_groups(n):
    masks=[(g.cop[L]==n) for L in LAY]
    labs=[label(m,S8)[0] for m in masks]; n0=int(labs[0].max()); labs[1]=np.where(labs[1]>0,labs[1]+n0,0)
    par=list(range(int(labs[1].max())+1))
    def f(i):
        while par[i]!=i: par[i]=par[par[i]]; i=par[i]
        return i
    both=g.thru&(labs[0]>0)&(labs[1]>0)
    for a,b in zip(labs[0][both],labs[1][both]):
        ra,rb=f(int(a)),f(int(b))
        if ra!=rb: par[rb]=ra
    lut=np.array([f(i) for i in range(len(par))],np.int32); la=lut[labs[0]]; lb=lut[labs[1]]
    ids=sorted(set(np.unique(la[la>0]).tolist())|set(np.unique(lb[lb>0]).tolist()))
    return la,lb,ids
want=None if not NETS else {nid[x] for x in ([l.strip() for l in open(NETS[1:],encoding='utf-8') if l.strip()] if NETS.startswith('@') else NETS.split(',')) if x in nid}
cands=[n for n in nets if n and not nets[n].startswith('unconnected-') and nets[n] not in ('GND','+5V') and (want is None or n in want)]
def sample(cells,k):
    if len(cells)<=k: return cells
    idx=np.linspace(0,len(cells)-1,k).astype(int); return [cells[i] for i in idx]
def group_points(la,lb,i):
    """end-point candidates of a group: (layers available, y, x). THT pads give both layers."""
    pts={}
    for l,lab in enumerate((la,lb)):
        ys,xs=np.nonzero(lab==i)
        for y,x in zip(ys.tolist(),xs.tolist()): pts.setdefault((y,x),set()).add(l)
    items=sorted(pts.items())
    return [(ls,y,x) for (y,x),ls in sample(items,SAMPLE)]
def free_h(bt,l,y,xa,xb):
    a,b=(xa,xb) if xa<=xb else (xb,xa); return not bt[l][y,a:b+1].any()
def free_v(bt,l,x,ya,yb):
    a,b=(ya,yb) if ya<=yb else (yb,ya); return not bt[l][a:b+1,x].any()
def runs_to_path(runs):
    """runs: list of (l,y0,x0,y1,x1) straight runs in order -> cell path"""
    path=[]
    for l,y0,x0,y1,x1 in runs:
        n=max(abs(y1-y0),abs(x1-x0)); dy=(y1>y0)-(y1<y0); dx=(x1>x0)-(x1<x0)
        for k in range(n+1):
            c=(l,y0+dy*k,x0+dx*k)
            if path and path[-1]==c: continue
            if path and path[-1][0]!=l and path[-1][1:]==c[1:]: path.append(c); continue
            path.append(c)
    return path
def try_pair(bt,bv,P,Q):
    """best pattern between end points P=(layers,y,x) and Q; returns (cost, runs) or None"""
    lsP,y1,x1=P; lsQ,y2,x2=Q; best=None; VIA=g.VIA_COST; A=g.AGAINST
    def consider(cost,runs):
        nonlocal best
        if best is None or cost<best[0]: best=(cost,runs)
    # straight
    if y1==y2:
        for l in (0,1):
            if l in lsP and l in lsQ and free_h(bt,l,y1,x1,x2): consider(abs(x2-x1)*(1 if l==0 else A),[(l,y1,x1,y2,x2)])
    if x1==x2:
        for l in (0,1):
            if l in lsP and l in lsQ and free_v(bt,l,x1,y1,y2): consider(abs(y2-y1)*(1 if l==1 else A),[(l,y1,x1,y2,x2)])
    if best is not None and best[0]<=VIA: return best
    if y1!=y2 and x1!=x2:
        # L: horizontal on F first, via at (y1,x2), vertical on B; or vertical on B first, via at (y2,x1), horizontal on F
        if 0 in lsP and 1 in lsQ and not bv[y1,x2] and free_h(bt,0,y1,x1,x2) and free_v(bt,1,x2,y1,y2):
            consider(abs(x2-x1)+abs(y2-y1)+VIA,[(0,y1,x1,y1,x2),(1,y1,x2,y2,x2)])
        if 1 in lsP and 0 in lsQ and not bv[y2,x1] and free_v(bt,1,x1,y1,y2) and free_h(bt,0,y2,x1,x2):
            consider(abs(x2-x1)+abs(y2-y1)+VIA,[(1,y1,x1,y2,x1),(0,y2,x1,y2,x2)])
        if best is not None and best[0]<=abs(x2-x1)+abs(y2-y1)+VIA: return best
    # Z: F run at y1 to xm, B run at xm from y1 to y2, F run at y2 to x2 (two vias); xm scanned outward from x1
    if 0 in lsP and 0 in lsQ and y1!=y2:
        lo=max(0,min(x1,x2)-ZMAX); hi=min(nx-1,max(x1,x2)+ZMAX)
        for d in range(0,ZMAX+abs(x2-x1)):
            for xm in ((x1+d,x1-d) if d else (x1,)):
                if xm<lo or xm>hi: continue
                if bv[y1,xm] or bv[y2,xm]: continue
                if not free_v(bt,1,xm,y1,y2): continue
                if not free_h(bt,0,y1,x1,xm) or not free_h(bt,0,y2,xm,x2): continue
                cost=abs(xm-x1)+abs(y2-y1)+abs(x2-xm)+2*VIA
                consider(cost,[(0,y1,x1,y1,xm),(1,y1,xm,y2,xm),(0,y2,xm,y2,x2)]); break
            else: continue
            break
    # U/Z the other way: B run at x1 to ym, F run at ym, B run at x2 (two vias); ym scanned outward from y1
    if 1 in lsP and 1 in lsQ and x1!=x2:
        lo=max(0,min(y1,y2)-ZMAX); hi=min(ny-1,max(y1,y2)+ZMAX)
        for d in range(0,ZMAX+abs(y2-y1)):
            for ym in ((y1+d,y1-d) if d else (y1,)):
                if ym<lo or ym>hi: continue
                if bv[ym,x1] or bv[ym,x2]: continue
                if not free_h(bt,0,ym,x1,x2): continue
                if not free_v(bt,1,x1,y1,ym) or not free_v(bt,1,x2,ym,y2): continue
                cost=abs(ym-y1)+abs(x2-x1)+abs(y2-ym)+2*VIA
                consider(cost,[(1,y1,x1,ym,x1),(0,ym,x1,ym,x2),(1,ym,x2,y2,x2)]); break
            else: continue
            break
    return best
# connections: per net, MST over its fixed groups by Manhattan distance between sampled points
todo=[]; conns=[]
for n in cands:
    la,lb,ids=fixed_groups(n)
    if len(ids)<2: continue
    todo.append(n); pts={i:group_points(la,lb,i) for i in ids}
    # MST (Prim) on group distance
    inT={ids[0]}; edges=[]
    dist={}
    def gdist(a,b):
        if (a,b) in dist: return dist[(a,b)]
        best=None
        for P in pts[a]:
            for Q in pts[b]:
                d=abs(P[1]-Q[1])+abs(P[2]-Q[2])
                if best is None or d<best[0]: best=(d,P,Q)
        dist[(a,b)]=best; return best
    while len(inT)<len(ids):
        bb=None
        for a in inT:
            for b in ids:
                if b in inT: continue
                d=gdist(a,b)
                if bb is None or d[0]<bb[0]: bb=(d[0],a,b)
        _,a,b=bb; inT.add(b); conns.append((bb[0],n,a,b))
    g.groups_pts=getattr(g,'groups_pts',{}); g.groups_pts[n]=(la,lb,pts)
print('nets',len(todo),'connections',len(conns),round(time.time()-T0),'s',flush=True)
conns.sort(key=lambda c:(c[0] if ORDER=='short' else -c[0]))
g.scope=set(todo); done=0; left=[]; nv=0; t1=time.time()
k=0
while k<len(conns):
    d,n,a,b=conns[k]; k+=1
    la,lb,pts=g.groups_pts[n]
    if a==b: continue
    bt,bv=g.blocked(n,hard=True)
    # own routes already placed are not obstacles but their cells are usable end points too: add them to both groups' candidates
    cand=[]
    for P in pts[a]:
        for Q in pts[b]:
            cand.append((abs(P[1]-Q[1])+abs(P[2]-Q[2]),P,Q))
    cand.sort(key=lambda t:t[0]); best=None
    for dd,P,Q in cand[:SAMPLE]:
        if best is not None and dd>best[0]: break
        r=try_pair(bt,bv,P,Q)
        if r and (best is None or r[0]<best[0]): best=r
    if best is None: left.append((n,a,b)); continue
    path=runs_to_path(best[1])
    if len(path)>=2:
        g.set_route(n,g.routes.get(n,[])+[path]); done+=1; nv+=g.path_vias(path)
        # the two groups are now one: merge labels so later connections of this net see the union
        la[la==b]=a; lb[lb==b]=a; pts[a]=pts[a]+pts[b]; pts[a]=sample(pts[a],2*SAMPLE)
        g.groups_pts[n]=(la,lb,pts)
        for j in range(k,len(conns)):   # later edges of this net that referenced b now reference a
            cd,cn,ca,cb=conns[j]
            if cn==n: conns[j]=(cd,cn,(a if ca==b else ca),(a if cb==b else cb))
    if k%100==0: print(f'  {k}/{len(conns)} placed {done} open {len(left)} {time.time()-t1:.0f} s',flush=True)
print(f'pattern routes placed {done} of {len(conns)} connections ({nv} vias), {len(left)} left for mroute4; nets with leftovers: {sorted({nets[n] for n,_,_ in left})}',flush=True)
g.write_out(dst)
open(dst+'.nets','w',encoding='utf-8').write('\n'.join(nets[n] for n in todo)+'\n')
print('total',round(time.time()-T0),'s')

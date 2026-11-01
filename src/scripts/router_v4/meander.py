"""meander.py in out NET:min_mm[,NET:min_mm..] [NETS=@scope] : minimum route length for delay nets (e.g. CLK_E:420).
Each named net's routed track is measured; when it is shorter than the minimum, trombone bumps are added on its
straight runs wherever the free space allows (amplitude up to AMP mm, bump width WIDTH mm, legs LEGGAP mm apart,
clearance to every other copper and the board edge checked on the grid) until the minimum is reached. When the route
is far below the minimum (DETOUR=0.9 x), its longest chain is first re-routed through a waypoint chosen so the net lands
near the minimum; the bumps then add the rest. The net must be
in the re-routable scope (copper added after BASE, or NETS=@file). Prints the length before and after; exit 1 when the
minimum cannot be reached. env: AMP=8 WIDTH=1 LEGGAP=0.625 MARGIN=1 (mm kept free at both ends of a run)"""
import sys, os, time
import numpy as np
TOOLS=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,TOOLS)
from gridcore import *
src,dst=sys.argv[1:3]; spec=sys.argv[3]; BASE=E('BASE'); NETS=E('NETS')
AMP=int(round(float(E('AMP','8'))/G)); WIDTH=int(round(float(E('WIDTH','1'))/G)); LEGGAP=int(round(float(E('LEGGAP','0.625'))/G)); MARG=int(round(float(E('MARGIN','1'))/G))
AMIN=LEGGAP
DETOUR=float(E('DETOUR','0.9')); BUMPSHARE=float(E('BUMPSHARE','0.15'))   # below DETOUR x minimum the longest chain is first re-routed through a waypoint, aiming at minimum/(1+BUMPSHARE); bumps add the rest
def netlist(s):
    if s and s.startswith('@'): return [l.strip() for l in open(s[1:],encoding='utf-8') if l.strip()]
    return s.split(',') if s else []
want={}
for item in spec.split(','):
    n,m=item.rsplit(':',1); want[n]=float(m)
b0,n0,_f,_p,_e=load(src); nid0={v:k for k,v in n0.items()}
scope={nid0[x] for x in netlist(NETS) if x in nid0} if NETS else None
if scope is not None: scope|={nid0[x] for x in want if x in nid0}
g=Grid(src,BASE,scope=scope)
def length_mm(n): return sum(len(p)-1-g.path_vias(p) for p in g.routes.get(n,[]))*G
def runs(path):
    """maximal straight runs of a path: (start index, end index, layer, (dy,dx))"""
    out=[]; i=0
    while i<len(path)-1:
        l,y,x=path[i]; l2,y2,x2=path[i+1]
        if l!=l2: i+=1; continue
        d=(y2-y,x2-x); j=i+1
        while j<len(path)-1 and path[j+1][0]==l and (path[j+1][1]-path[j][1],path[j+1][2]-path[j][2])==d: j+=1
        out.append((i,j,l,d)); i=j
    return out
def bump_cells(l,y,x,d,a,w,side):
    """cells of a trombone bump starting at (y,x) going w cells along d with amplitude a to the side: list of (l,y,x)"""
    py,px=(-d[1]*side,d[0]*side)   # perpendicular
    cells=[]
    for k in range(1,a+1): cells.append((l,y+py*k,x+px*k))
    for k in range(1,w+1): cells.append((l,y+py*a+d[0]*k,x+px*a+d[1]*k))
    for k in range(a-1,-1,-1): cells.append((l,y+d[0]*w+py*k,x+d[1]*w+px*k))
    return cells
def end_masks(n,path):
    """copper masks of the two components the chain joins (None when it is not a simple two-end chain)"""
    la,lb=g.components(n,skip=path); cF,cB=g.last_copper; labs=(la,lb)
    def lab_at(c):
        l,iy,ix=c; j0,j1,i0,i1=max(0,iy-2),iy+3,max(0,ix-2),ix+3
        u=set(np.unique(labs[l][j0:j1,i0:i1]).tolist()); u.discard(0); return u
    a=lab_at(path[0]); b=lab_at(path[-1])
    if len(a)!=1 or len(b)!=1 or a==b: return None,None
    ca=a.pop(); cb=b.pop()
    return {'F.Cu':(la==ca)&cF,'B.Cu':(lb==ca)&cB},{'F.Cu':(la==cb)&cF,'B.Cu':(lb==cb)&cB}
def detour(n,minmm):
    """re-route the net's longest chain through a waypoint so that the whole net reaches about minmm; returns gain mm"""
    paths=list(g.routes[n]); path=max(paths,key=len); others=[p for p in paths if p is not path]
    srcm,goalm=end_masks(n,path)
    if srcm is None: return 0.0
    Lo=sum(len(p)-1-g.path_vias(p) for p in others)*G; target=minmm-Lo        # length wanted for the new chain (mm)
    def cen(m):
        ys,xs=np.nonzero(m['F.Cu']|m['B.Cu']); return ys.mean(),xs.mean()
    sy,sx=cen(srcm); gy,gx=cen(goalm)
    g.set_route(n,others); bt,bv=g.blocked(n,hard=True); best=(0.0,None)
    ys=[p[1] for p in path]; xs=[p[2] for p in path]; R=int(80/G)
    j0,j1=max(0,min(ys)-R),min(g.ny,max(ys)+R); i0,i1=max(0,min(xs)-R),min(g.nx,max(xs)+R)
    win=(i0,i1,j0,j1); ct=[np.ones((g.ny,g.nx),np.float32) for _ in range(2)]; cvia=np.full((g.ny,g.nx),g.VIA_COST,np.float32)
    direct,_=g.astar(srcm,goalm,bt,bv,ct,cvia,win)
    if not direct: g.set_route(n,paths); return 0.0
    from scipy.ndimage import label as _label
    free=[_label(~bt[l])[0] for l in range(2)]; reach={(l,int(free[l][iy,ix])) for l,iy,ix in direct}   # free regions the chain can reach without a via
    step=int(4/G); cands=[]
    for l in range(2):
        for iy in range(j0,j1,step):
            for ix in range(i0,i1,step):
                if bt[l][iy,ix] or (l,int(free[l][iy,ix])) not in reach or bt[l][iy-1:iy+2,ix-1:ix+2].any(): continue
                est=(abs(iy-sy)+abs(ix-sx)+abs(iy-gy)+abs(ix-gx))*G
                cands.append((abs(est-target),l,iy,ix))
    cands.sort()
    for _,l,iy,ix in cands[:40]:
        wm={'F.Cu':np.zeros((g.ny,g.nx),bool),'B.Cu':np.zeros((g.ny,g.nx),bool)}; wm[LAY[l]][iy,ix]=True
        p1,_=g.astar(srcm,wm,bt,bv,ct,cvia,win)
        if not p1: continue
        bt2=[b.copy() for b in bt]; bv2=bv.copy()   # first leg blocks the second, except around the waypoint
        for cl,cy,cx in p1[:-(LEGGAP+2)]:
            bt2[cl][max(0,cy-LEGGAP):cy+LEGGAP+1,max(0,cx-LEGGAP):cx+LEGGAP+1]=True; bv2[max(0,cy-LEGGAP):cy+LEGGAP+1,max(0,cx-LEGGAP):cx+LEGGAP+1]=True
        sm={'F.Cu':np.zeros((g.ny,g.nx),bool),'B.Cu':np.zeros((g.ny,g.nx),bool)}; sm[LAY[p1[-1][0]]][p1[-1][1],p1[-1][2]]=True
        p2,_=g.astar(sm,goalm,bt2,bv2,ct,cvia,win)
        if not p2: continue
        new=p1+p2[1:]; Lmm=(len(new)-1-g.path_vias(new))*G
        if Lmm>best[0]: best=(Lmm,new)
        if Lmm>=target*0.98: break
    if best[1] is None: g.set_route(n,paths); return 0.0
    g.set_route(n,others+[best[1]]); return best[0]-(len(path)-1-g.path_vias(path))*G
def bumps(n,minmm):
    """trombone bumps on straight runs until minmm; returns mm added"""
    L0=length_mm(n); need=minmm-L0; added=0.0
    paths=list(g.routes[n]); newpaths=[]
    for pi,path in enumerate(paths):
        if need-added<=0: newpaths.append(path); continue
        g.set_route(n,[p for p in g.routes[n] if p is not path])   # lift this chain only
        bt,bv=g.blocked(n,hard=True)
        cur=list(path); offset=0   # offset grows as bumps are inserted
        for (i,j,l,d) in runs(path):
            if need-added<=0: break
            if j-i<2*MARG+WIDTH+2: continue
            pos=i+MARG
            while pos+WIDTH+MARG<=j and need-added>0:
                _,y,x=path[pos]; placed=False
                for side in (1,-1):
                    for a in range(AMP,AMIN-1,-1):
                        cells=bump_cells(l,y,x,d,a,WIDTH,side)
                        if any(cy<0 or cx<0 or cy>=g.ny or cx>=g.nx or bt[cl][cy,cx] for cl,cy,cx in cells): continue
                        k=pos+offset
                        cur=cur[:k+1]+cells+cur[k+1+WIDTH:]
                        offset+=len(cells)-WIDTH; added+=2*a*G; placed=True
                        for cl,cy,cx in cells:
                            bt[cl][max(0,cy-LEGGAP):cy+LEGGAP+1,max(0,cx-LEGGAP):cx+LEGGAP+1]=True
                        break
                    if placed: break
                pos+=WIDTH+LEGGAP+1 if placed else 1
        newpaths.append(cur); g.set_route(n,[p for p in paths[pi+1:]]+newpaths)
    g.set_route(n,newpaths)
    return added
ok=True
for name,minmm in want.items():
    n=nid0.get(name)
    if n is None or not g.routes.get(n): print(f'{name}: not routable here (not in scope or no routes)'); ok=False; continue
    L0=length_mm(n)
    print(f'{name}: {L0:.1f} mm, minimum {minmm:.0f}',flush=True)
    if L0>=minmm: continue
    if DETOUR and L0<minmm*DETOUR:
        d=detour(n,minmm/(1+BUMPSHARE)); print(f'{name}: detour through a waypoint +{d:.1f} mm',flush=True)
    if length_mm(n)<minmm: bumps(n,minmm)
    L1=length_mm(n); print(f'{name}: {L0:.1f} -> {L1:.1f} mm (+{L1-L0:.1f})',flush=True)
    if L1<minmm: print(f'{name}: minimum {minmm:.0f} mm NOT reached'); ok=False
g.write_out(dst)
sys.exit(0 if ok else 1)

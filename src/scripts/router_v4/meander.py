"""meander.py in out NET:min_mm[,NET:min_mm..] [NETS=@scope] : minimum route length for delay nets (e.g. CLK_E:420).
Each named net's routed track is measured; when it is shorter than the minimum, trombone bumps are added on its
straight runs wherever the free space allows (amplitude up to AMP mm, bump width WIDTH mm, legs LEGGAP mm apart,
clearance to every other copper and the board edge checked on the grid) until the minimum is reached. The net must be
in the re-routable scope (copper added after BASE, or NETS=@file). Prints the length before and after; exit 1 when the
minimum cannot be reached. env: AMP=5 WIDTH=1 LEGGAP=0.625 MARGIN=1 (mm kept free at both ends of a run)"""
import sys, os, time
import numpy as np
TOOLS=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,TOOLS)
from gridcore import *
src,dst=sys.argv[1:3]; spec=sys.argv[3]; BASE=E('BASE'); NETS=E('NETS')
AMP=int(round(float(E('AMP','5'))/G)); WIDTH=int(round(float(E('WIDTH','1'))/G)); LEGGAP=int(round(float(E('LEGGAP','0.625'))/G)); MARG=int(round(float(E('MARGIN','1'))/G))
AMIN=max(LEGGAP,int(round(1.0/G)))
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
ok=True
for name,minmm in want.items():
    n=nid0.get(name)
    if n is None or not g.routes.get(n): print(f'{name}: not routable here (not in scope or no routes)'); ok=False; continue
    L0=length_mm(n); need=minmm-L0; added=0.0
    print(f'{name}: {L0:.1f} mm, minimum {minmm:.0f}',flush=True)
    if need<=0: continue
    paths=list(g.routes[n]); newpaths=[]
    for pi,path in enumerate(paths):
        if need-added<=0: newpaths.append(path); continue
        others=[p for p in paths if p is not path]+newpaths[:0]
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
                        # own clearance to the run itself is implicit (legs leave the run); legs must clear previously placed bumps: LEGGAP handled by spacing
                        k=pos+offset
                        cur=cur[:k+1]+cells+cur[k+1+WIDTH:]
                        offset+=len(cells)-WIDTH; added+=2*a*G; placed=True
                        # mark bump cells + clearance as blocked for the next bumps
                        for cl,cy,cx in cells:
                            bt[cl][max(0,cy-LEGGAP):cy+LEGGAP+1,max(0,cx-LEGGAP):cx+LEGGAP+1]=True
                        break
                    if placed: break
                pos+=WIDTH+LEGGAP+(1 if placed else 0)
        newpaths.append(cur); g.set_route(n,[p for p in paths[pi+1:]]+newpaths)
    g.set_route(n,newpaths)
    L1=length_mm(n); print(f'{name}: {L0:.1f} -> {L1:.1f} mm (+{L1-L0:.1f})',flush=True)
    if L1<minmm: print(f'{name}: minimum {minmm:.0f} mm NOT reached'); ok=False
g.write_out(dst)
sys.exit(0 if ok else 1)

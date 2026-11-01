"""tidy.py in out BASE=base.kicad_pcb [NETS=a,b] : post-route clean-up of the copper added after BASE (v3/v4 grid output).
Every chain of a net (a run between two junctions, pads or fixed copper) is removed and re-routed alone with all other
copper fixed; the result is kept only when it is cheaper (fewer vias, fewer bends, less wrong-way track, shorter).
A chain whose ends are still connected without it is deleted. Repeats until nothing improves.
env: VIA=200 (via cost in cells, higher than the router's to trade length for vias)  BEND=4  AGAINST=3  RING=8
     WIN=25 (mm around the chain)  PASSES=4  MINGAIN=4"""
import sys, os, time
import numpy as np
TOOLS=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,TOOLS)
os.environ.setdefault('VIA','200'); os.environ.setdefault('BEND','4')
from gridcore import *
src,dst=sys.argv[1:3]; BASE=E('BASE'); NETS=E('NETS'); WIN=float(E('WIN','25')); PASSES=int(E('PASSES','4')); MINGAIN=float(E('MINGAIN','4'))
t0=time.time()
def netlist(spec):
    if spec and spec.startswith('@'): return [l.strip() for l in open(spec[1:],encoding='utf-8') if l.strip()]
    return spec.split(',') if spec else []
b0,n0,_f,_p,_e=load(src); nid0={v:k for k,v in n0.items()}
g=Grid(src,BASE,scope={nid0[x] for x in netlist(NETS) if x in nid0} if NETS else None)
nets=g.nets
from scipy.ndimage import binary_dilation
from gridcore import _disk
DK_T=_disk(W/2/G); DK_V=_disk(VD/2/G)
def comp_masks(n,path):
    """components of the net without this chain, and which of them the chain's copper touches.
    returns (src, goal, drop): drop when the chain touches at most one component (redundant or dangling);
    (None,None,False) when it touches more than two (left alone)."""
    la,lb=g.components(n,skip=path)
    ys=[p[1] for p in path]; xs=[p[2] for p in path]
    j0=max(0,min(ys)-5); j1=min(g.ny,max(ys)+6); i0=max(0,min(xs)-5); i1=min(g.nx,max(xs)+6)
    cells=[np.zeros((j1-j0,i1-i0),bool) for _ in LAY]; vc=np.zeros((j1-j0,i1-i0),bool)
    for i,(l,iy,ix) in enumerate(path):
        cells[l][iy-j0,ix-i0]=True
        if i and path[i-1][0]!=l: vc[iy-j0,ix-i0]=True
    vd=binary_dilation(vc,DK_V) if vc.any() else None
    touched=set()
    for l,lab in enumerate((la,lb)):
        m=binary_dilation(cells[l],DK_T) if cells[l].any() else np.zeros_like(vc)
        if vd is not None: m|=vd
        touched|=set(np.unique(lab[j0:j1,i0:i1][m]).tolist())
    touched.discard(0)
    if len(touched)<=1: return None,None,True
    if len(touched)>2: return None,None,False
    ca,cb=sorted(touched)
    src={'F.Cu':la==ca,'B.Cu':lb==ca}; goal={'F.Cu':la==cb,'B.Cu':lb==cb}
    return src,goal,False
def tidy_net(n):
    gain=0.0; changed=0; dropped=0
    paths=list(g.routes.get(n,[]))
    order=sorted(range(len(paths)),key=lambda i:-(g.path_vias(paths[i])*g.VIA_COST+len(paths[i])))
    for i in order:
        path=g.routes[n][i] if i<len(g.routes[n]) else None
        if path is None or path is not paths[i]: continue
        oc=g.path_cost(path)
        srcm,goalm,drop=comp_masks(n,path)
        if drop:
            new=[p for p in g.routes[n] if p is not path]; g.set_route(n,new); gain+=oc; dropped+=1; continue
        if srcm is None: continue
        g.apply_stamps(g.stamps[n],-1)   # own copper not blocked while routing
        bt,bv=g.blocked(n,hard=True)
        ring=g.own_ring(n)
        ct=[1.0+g.RING*ring[l] for l in range(2)]; cvia=np.full((g.ny,g.nx),g.VIA_COST,np.float32)
        pm={'F.Cu':np.zeros((g.ny,g.nx),bool),'B.Cu':np.zeros((g.ny,g.nx),bool)}
        for l,iy,ix in path: pm[LAY[l]][iy,ix]=True
        win=g.window([pm],WIN)
        newp,ne=g.astar(srcm,goalm,bt,bv,ct,cvia,win)
        g.apply_stamps(g.stamps[n],1)
        if newp and len(newp)>=2 and g.path_cost(newp)<oc-MINGAIN:
            new=[p for p in g.routes[n] if p is not path]+[newp]; g.set_route(n,new); gain+=oc-g.path_cost(newp); changed+=1
    return gain,changed,dropped
tot_before={n:(sum(g.path_vias(p) for p in g.routes[n]),sum(len(p) for p in g.routes[n])) for n in g.scope}
for ps in range(PASSES):
    t1=time.time(); tg=0; tc=0; td=0
    for n in sorted(g.scope,key=lambda n:-sum(g.path_vias(p) for p in g.routes[n])):
        if not g.routes.get(n): continue
        gain,changed,dropped=tidy_net(n); tg+=gain; tc+=changed; td+=dropped
        # re-decompose into chains so junctions created by the new path are honoured next pass
        if changed or dropped:
            cells=set()
            # rebuild chains from the routes' cells via the tail machinery: write cells as pseudo segments
            adj={}
            segs=[]; vias=[]
            for p in g.routes[n]:
                for a,b in zip(p,p[1:]):
                    if a[0]!=b[0]: vias.append((g.mm(a[1],a[2]),VD,-1))
                    else: segs.append((LAY[a[0]],g.mm(a[1],a[2]),g.mm(b[1],b[2]),W,-1))
            g.tailseg[n]=segs; g.tailvia[n]=vias
            newpaths=g.paths_from_tail(n)
            if newpaths is not None: g.set_route(n,newpaths)
    print(f'pass {ps}: {tc} chains improved, {td} dropped, cost gain {tg:.0f}, {time.time()-t1:.0f} s',flush=True)
    if tc==0 and td==0: break
vb=sum(v for v,_ in tot_before.values()); va=sum(sum(g.path_vias(p) for p in g.routes[n]) for n in g.scope)
cb=sum(c for _,c in tot_before.values()); ca=sum(sum(len(p) for p in g.routes[n]) for n in g.scope)
print(f'vias {vb} -> {va}, cells {cb} -> {ca}, {time.time()-t0:.0f} s')
g.write_out(dst)

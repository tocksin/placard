"""tidy.py in out BASE=base.kicad_pcb [NETS=a,b] : post-route clean-up of the copper added after BASE (v3/v4 grid output).
Every chain of a net (a run between two junctions, pads or fixed copper) is removed and re-routed alone with all other
copper fixed; the result is kept only when it is cheaper (fewer vias, fewer bends, less wrong-way track, shorter).
A chain whose ends are still connected without it is deleted. Repeats until nothing improves.
env: VIA=200 (via cost in cells, higher than the router's to trade length for vias)  BEND=4  AGAINST=3  RING=8
     WIN=25 (mm around the chain)  PASSES=4  MINGAIN=4
     PAIR=1: after the single-chain passes, every chain with a via is re-routed together with one neighbouring chain
     of another net (the neighbour is lifted first, the chain re-routed, then the neighbour); kept when the pair is cheaper.
     NEIGH=3 neighbours tried per chain.
     NETPASS=1: whole-net polish before the chain passes: every net is lifted entirely and re-routed from scratch
     against everything else (largest component first, nearest other component each step, hard A*); kept when the
     whole net is cheaper. Finds the shorter tree that chain-by-chain moves cannot reach. NETPASSES=2 rounds."""
import sys, os, time
import numpy as np
TOOLS=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,TOOLS)
os.environ.setdefault('VIA','200'); os.environ.setdefault('BEND','4')
from gridcore import *
src,dst=sys.argv[1:3]; BASE=E('BASE'); NETS=E('NETS'); WIN=float(E('WIN','25')); PASSES=int(E('PASSES','4')); MINGAIN=float(E('MINGAIN','4')); PAIR=int(E('PAIR','1')); NEIGH=int(E('NEIGH','3')); NETPASS=int(E('NETPASS','1')); NETPASSES=int(E('NETPASSES','2'))
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
        m=binary_dilation(cells[l],np.ones((3,3),bool)) if cells[l].any() else np.zeros_like(vc)   # 8-neighbours touch
        if vd is not None: m|=vd
        touched|=set(np.unique(lab[j0:j1,i0:i1][m]).tolist())
    touched.discard(0)
    if len(touched)<=1: return None,None,True
    if len(touched)>2: return None,None,False
    ca,cb=sorted(touched); cF,cB=g.last_copper   # route between real copper cells, not the dilated labels
    src={'F.Cu':(la==ca)&cF,'B.Cu':(lb==ca)&cB}; goal={'F.Cu':(la==cb)&cF,'B.Cu':(lb==cb)&cB}
    return src,goal,False
def reroute_chain(n,path):
    """route the chain's job alone (own copper free, everything else blocked). returns (newpath or None, drop)"""
    srcm,goalm,drop=comp_masks(n,path)
    if drop or srcm is None: return None,drop
    g.apply_stamps(g.stamps[n],-1)
    bt,bv=g.blocked(n,hard=True)
    ring=g.own_ring(n)
    ct=[1.0+g.RING*ring[l] for l in range(2)]; cvia=np.full((g.ny,g.nx),g.VIA_COST,np.float32)
    pm={'F.Cu':np.zeros((g.ny,g.nx),bool),'B.Cu':np.zeros((g.ny,g.nx),bool)}
    for l,iy,ix in path: pm[LAY[l]][iy,ix]=True
    win=g.window([pm],WIN)
    newp,ne=g.astar(srcm,goalm,bt,bv,ct,cvia,win)
    g.apply_stamps(g.stamps[n],1)
    return (newp if newp and len(newp)>=2 else None),False
def rechain(n):
    """re-decompose the net's routes into chains (junctions made by new paths are honoured)"""
    segs=[]; vias=[]
    for p in g.routes[n]:
        for a,b in zip(p,p[1:]):
            if a[0]!=b[0]: vias.append((g.mm(a[1],a[2]),VD,-1))
            else: segs.append((LAY[a[0]],g.mm(a[1],a[2]),g.mm(b[1],b[2]),W,-1))
    g.tailseg[n]=segs; g.tailvia[n]=vias
    newpaths=g.paths_from_tail(n)
    if newpaths is not None: g.set_route(n,newpaths)
def chain_bbox(path,pad):
    ys=[p[1] for p in path]; xs=[p[2] for p in path]
    return max(0,min(ys)-pad),min(g.ny,max(ys)+pad+1),max(0,min(xs)-pad),min(g.nx,max(xs)+pad+1)
def neighbours(n,path):
    """chains of other scope nets whose stamps cover cells next to this chain, nearest (most covered cells) first"""
    j0,j1,i0,i1=chain_bbox(path,6); score={}
    cells=[np.zeros((j1-j0,i1-i0),bool) for _ in LAY]
    for l,iy,ix in path: cells[l][iy-j0,ix-i0]=True
    for m in g.scope:
        if m==n: continue
        for q in g.routes.get(m,[]):
            qy=[p[1] for p in q]; qx=[p[2] for p in q]
            if max(qy)<j0 or min(qy)>=j1 or max(qx)<i0 or min(qx)>=i1: continue
            c=0
            for l,iy,ix in q:
                if j0<=iy<j1 and i0<=ix<i1 and cells[l][max(0,iy-j0-4):iy-j0+5,max(0,ix-i0-4):ix-i0+5].any(): c+=1
            if c: score[(m,id(q))]=(c,m,q)
    return [(m,q) for c,m,q in sorted(score.values(),key=lambda t:-t[0])[:NEIGH]]
def pair_net(n):
    gain=0.0; changed=0
    paths=sorted(g.routes.get(n,[]),key=lambda p:-g.path_vias(p))
    for path in paths:
        if path not in g.routes[n] or g.path_vias(path)==0: continue
        oc=g.path_cost(path)
        for m,q in neighbours(n,path):
            if q not in g.routes.get(m,[]): continue
            oq=g.path_cost(q)
            keep_n=list(g.routes[n]); keep_m=list(g.routes[m])
            g.set_route(m,[p for p in keep_m if p is not q])          # lift the neighbour
            newp,drop=reroute_chain(n,path)
            if newp is None: g.set_route(m,keep_m); continue
            g.set_route(n,[p for p in keep_n if p is not path]+[newp])
            newq,dropq=reroute_chain(m,q)
            if newq is None and not dropq: g.set_route(n,keep_n); g.set_route(m,keep_m); continue
            nc=g.path_cost(newp)+(0 if dropq else g.path_cost(newq))
            if nc<oc+oq-MINGAIN:
                if not dropq: g.set_route(m,g.routes[m]+[newq])
                gain+=oc+oq-nc; changed+=1; break
            g.set_route(n,keep_n); g.set_route(m,keep_m)
    return gain,changed
def polish_net(n):
    """lift the whole net and re-route it from scratch with everything else fixed; keep when cheaper"""
    paths=list(g.routes.get(n,[]))
    if not paths: return 0.0,0
    oc=sum(g.path_cost(p) for p in paths)
    pm={'F.Cu':np.zeros((g.ny,g.nx),bool),'B.Cu':np.zeros((g.ny,g.nx),bool)}
    for p in paths:
        for l,iy,ix in p: pm[LAY[l]][iy,ix]=True
    win=g.window([pm],WIN)
    g.set_route(n,[]); new=[]
    for _ in range(200):
        la,lb=g.components(n); cF,cB=g.last_copper
        labs=np.unique(np.concatenate([la[la>0],lb[lb>0]]))
        if len(labs)<=1: break
        cnt={int(k):int(((la==k)&cF).sum()+((lb==k)&cB).sum()) for k in labs}
        s=max(cnt,key=cnt.get)
        srcm={'F.Cu':(la==s)&cF,'B.Cu':(lb==s)&cB}; goalm={'F.Cu':(la>0)&(la!=s)&cF,'B.Cu':(lb>0)&(lb!=s)&cB}
        bt,bv=g.blocked(n,hard=True); ring=g.own_ring(n)
        ct=[1.0+g.RING*ring[l] for l in range(2)]; cvia=np.full((g.ny,g.nx),g.VIA_COST,np.float32)
        newp,ne=g.astar(srcm,goalm,bt,bv,ct,cvia,win)
        if not newp or len(newp)<2: g.set_route(n,paths); return 0.0,0
        new.append(newp); g.set_route(n,new)
    la,lb=g.components(n)
    if len(np.unique(np.concatenate([la[la>0],lb[lb>0]])))>1: g.set_route(n,paths); return 0.0,0
    nc=sum(g.path_cost(p) for p in new)
    if nc<oc-MINGAIN: rechain(n); return oc-nc,1
    g.set_route(n,paths); return 0.0,0
def tidy_net(n):
    gain=0.0; changed=0; dropped=0
    paths=list(g.routes.get(n,[]))
    order=sorted(range(len(paths)),key=lambda i:-(g.path_vias(paths[i])*g.VIA_COST+len(paths[i])))
    for i in order:
        path=g.routes[n][i] if i<len(g.routes[n]) else None
        if path is None or path is not paths[i]: continue
        oc=g.path_cost(path)
        newp,drop=reroute_chain(n,path)
        if drop:
            new=[p for p in g.routes[n] if p is not path]; g.set_route(n,new); gain+=oc; dropped+=1; continue
        if newp and g.path_cost(newp)<oc-MINGAIN:
            new=[p for p in g.routes[n] if p is not path]+[newp]; g.set_route(n,new); gain+=oc-g.path_cost(newp); changed+=1
    return gain,changed,dropped
tot_before={n:(sum(g.path_vias(p) for p in g.routes[n]),sum(len(p) for p in g.routes[n])) for n in g.scope}
if NETPASS:
    for ps in range(NETPASSES):
        t1=time.time(); tg=0; tc=0
        for n in sorted(g.scope,key=lambda n:-sum(g.path_cost(p) for p in g.routes[n])):
            if not g.routes.get(n): continue
            gain,changed=polish_net(n); tg+=gain; tc+=changed
        print(f'net pass {ps}: {tc} nets improved, cost gain {tg:.0f}, {time.time()-t1:.0f} s',flush=True)
        if tc==0: break
for ps in range(PASSES):
    t1=time.time(); tg=0; tc=0; td=0
    for n in sorted(g.scope,key=lambda n:-sum(g.path_vias(p) for p in g.routes[n])):
        if not g.routes.get(n): continue
        gain,changed,dropped=tidy_net(n); tg+=gain; tc+=changed; td+=dropped
        if changed or dropped: rechain(n)
    print(f'pass {ps}: {tc} chains improved, {td} dropped, cost gain {tg:.0f}, {time.time()-t1:.0f} s',flush=True)
    if tc==0 and td==0: break
if PAIR:
    for ps in range(PASSES):
        t1=time.time(); tg=0; tc=0
        for n in sorted(g.scope,key=lambda n:-sum(g.path_vias(p) for p in g.routes[n])):
            if not g.routes.get(n): continue
            gain,changed=pair_net(n); tg+=gain; tc+=changed
            if changed: rechain(n)
        print(f'pair pass {ps}: {tc} chain pairs improved, cost gain {tg:.0f}, {time.time()-t1:.0f} s',flush=True)
        if tc==0: break
        for n in g.scope:   # single-chain clean-up after the pair moves
            if g.routes.get(n):
                gain,changed,dropped=tidy_net(n)
                if changed or dropped: rechain(n)
vb=sum(v for v,_ in tot_before.values()); va=sum(sum(g.path_vias(p) for p in g.routes[n]) for n in g.scope)
cb=sum(c for _,c in tot_before.values()); ca=sum(sum(len(p) for p in g.routes[n]) for n in g.scope)
print(f'vias {vb} -> {va}, cells {cb} -> {ca}, {time.time()-t0:.0f} s')
g.write_out(dst)

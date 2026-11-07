"""tidy.py in out BASE=base.kicad_pcb [NETS=a,b] : post-route clean-up of the copper added after BASE (v3/v4 grid output).
Every chain of a net (a run between two junctions, pads or fixed copper) is removed and re-routed alone with all other
copper fixed; the result is kept only when it is cheaper (fewer vias, fewer bends, less wrong-way track, shorter).
A chain whose ends are still connected without it is deleted. Repeats until nothing improves.
env: VIA=200 (via cost in cells, higher than the router's to trade length for vias)  BEND=4  AGAINST=3  RING=8
     WIN=25 (mm around the chain)  PASSES=4  MINGAIN=4
     PAIR=1: after the single-chain passes, every chain with a via is re-routed together with one neighbouring chain
     of another net (the neighbour is lifted first, the chain re-routed, then the neighbour); kept when the pair is cheaper.
     NEIGH=3 neighbours tried per chain.
     NEIGHMM=1.0: a chain counts as a neighbour when its cells lie within this distance (mm) of the chain.
     SHOVE=8 (cells; default 0 = off, slow): after the pair passes, every chain with a via tries to shove a neighbouring chain's straight
     run sideways by up to SHOVE cells (legs added at both ends) and re-route itself; kept when the pair is cheaper.
     NETPASS=1: whole-net polish before the chain passes: every net is lifted entirely and re-routed from scratch
     against everything else (largest component first, nearest other component each step, hard A*); kept when the
     whole net is cheaper. Finds the shorter tree that chain-by-chain moves cannot reach. NETPASSES=2 rounds.
     BUDGET=budgets.json (budgets.py): no move is kept that puts a budgeted net further over its track-length budgets
     (summed mm over budget may not grow by more than 0.1 mm).
     WORKERS=N (default min(cpus,8), capped by free memory at ~40 B per grid cell per worker; 1 = the sequential pass):
     worker processes attach to the main grid's read-only arrays (shared memory) and keep only their own occupancy and
     routes. The main process hands out the nets of a pass one at a time in the sequential order (skipping up to LOOK=16
     nets ahead past one whose window overlaps a net in flight), validates every returned move on its own grid (the new
     copper must be free, and the move must not build on a net it had not yet seen updated), and streams each accepted
     move to all workers at once; a rejected move is retried later in the pass (RETRY=2). Moves therefore follow the
     sequential pass closely (a few per cent rejected), the result differs only in the order of equal-cost choices.
     HCOARSE=4: the A* goal-distance heuristic is a distance transform on 4x4-cell blocks (1 = per cell, 16x slower).
     BUDGET forces WORKERS=1."""
import sys, math, os, time
import numpy as np
TOOLS=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,TOOLS)
os.environ.setdefault('VIA','200'); os.environ.setdefault('BEND','4')
from gridcore import *
src,dst=sys.argv[1:3]; BASE=E('BASE'); NETS=E('NETS'); WIN=float(E('WIN','25')); PASSES=int(E('PASSES','4')); MINGAIN=float(E('MINGAIN','4')); PAIR=int(E('PAIR','1')); NEIGH=int(E('NEIGH','3')); SHOVE=int(E('SHOVE','0')); NEIGHMM=float(E('NEIGHMM','1.0')); NETPASS=int(E('NETPASS','1')); NETPASSES=int(E('NETPASSES','2')); WORKERS=int(E('WORKERS',str(min(os.cpu_count() or 1,8))))
t0=time.time()
def netlist(spec):
    if spec and spec.startswith('@'): return [l.strip() for l in open(spec[1:],encoding='utf-8') if l.strip()]
    return spec.split(',') if spec else []
BUD=E('BUDGET'); BG=None; EXC={}; g=None; ACTIVE=None
if BUD and WORKERS>1: WORKERS=1
def setup(quiet=False):
    """load the grid (main process and every worker)"""
    global g,nets,BG,EXC,ACTIVE
    b0,n0,_f,_p,_e=load(src); nid0={v:k for k,v in n0.items()}
    g=Grid(src,BASE,scope={nid0[x] for x in netlist(NETS) if x in nid0} if NETS else None,quiet=quiet)
    nets=g.nets; ACTIVE=g.scope
    if BUD:
        import lenbudget
        BG=lenbudget.Budgets(g,BUD,float(E('BUDGETSLACK','0'))); EXC={n:BG.excess(n)[0] for n in BG.nets()}
        if not quiet: print(f'length budgets: {len(EXC)} nets, {sum(1 for v in EXC.values() if v>0)} over budget by {sum(EXC.values()):.0f} mm',flush=True)
def bud_ok(*ns):
    """True when none of the nets went further over its length budgets (and records the new excess)"""
    if not BG: return True
    new={}
    for n in ns:
        if n in EXC:
            e=BG.excess(n)[0]
            if e>EXC[n]+0.1: return False
            new[n]=e
    EXC.update(new); return True
from scipy.ndimage import binary_dilation
from gridcore import _disk, stamp_disks
DK_T=_disk(W/2/G); DK_V=_disk(VD/2/G)
def comp_masks(n,path,win):
    """components of the net without this chain, and which of them the chain's copper touches.
    returns (src, goal, drop): drop when the chain touches at most one component (redundant or dangling);
    (None,None,False) when it touches more than two (left alone)."""
    la,lb=g.components(n,skip=path)
    ys=[p[1] for p in path]; xs=[p[2] for p in path]
    R=max(5,int(math.ceil(VD/2/G))+1)   # bbox margin must hold the via disk (fine grid)
    j0=max(0,min(ys)-R); j1=min(g.ny,max(ys)+R+1); i0=max(0,min(xs)-R); i1=min(g.nx,max(xs)+R+1)
    cells=[np.zeros((j1-j0,i1-i0),bool) for _ in LAY]; vc=np.zeros((j1-j0,i1-i0),bool)
    for i,(l,iy,ix) in enumerate(path):
        cells[l][iy-j0,ix-i0]=True
        if i and path[i-1][0]!=l: vc[iy-j0,ix-i0]=True
    vd=stamp_disks(vc,DK_V) if vc.any() else None
    touched=set()
    for l,lab in enumerate((la,lb)):
        m=binary_dilation(cells[l],np.ones((3,3),bool)) if cells[l].any() else np.zeros_like(vc)   # 8-neighbours touch
        if vd is not None: m|=vd
        touched|=set(np.unique(lab[j0:j1,i0:i1][m]).tolist())
    touched.discard(0)
    if len(touched)<=1: return None,None,True
    if len(touched)>2: return None,None,False
    ca,cb=sorted(touched); cF,cB=g.last_copper   # route between real copper cells, not the dilated labels
    W=(slice(win[2],win[3]),slice(win[0],win[1])); la=la[W]; lb=lb[W]; cF=cF[W]; cB=cB[W]
    src={'F.Cu':(la==ca)&cF,'B.Cu':(lb==ca)&cB}; goal={'F.Cu':(la==cb)&cF,'B.Cu':(lb==cb)&cB}
    return src,goal,False
def search_window(cells,pad_mm):
    ys=[c[1] for c in cells]; xs=[c[2] for c in cells]; pad=int(pad_mm/G)
    return (max(0,min(xs)-pad),min(g.nx,max(xs)+pad+1),max(0,min(ys)-pad),min(g.ny,max(ys)+pad+1))
def reroute_chain(n,path):
    """route the chain's job alone (own copper free, everything else blocked). returns (newpath or None, drop)
    everything is computed on the search window only (the chain's bbox + WIN mm)"""
    win=search_window(path,WIN)
    srcm,goalm,drop=comp_masks(n,path,win)
    if drop or srcm is None: return None,drop
    g.apply_stamps(g.stamps[n],-1)
    bt,bv=g.blocked(n,hard=True,win=win)
    ring=g.own_ring(n,win)
    ct=[1.0+g.RING*ring[l] for l in range(2)]
    newp,ne=g.astar(srcm,goalm,bt,bv,ct,None,win)
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
    R=max(4,int(round(NEIGHMM/G))); j0,j1,i0,i1=chain_bbox(path,R+2); score={}
    cells=[np.zeros((j1-j0,i1-i0),bool) for _ in LAY]
    for l,iy,ix in path: cells[l][iy-j0,ix-i0]=True
    for m in g.scope:
        if m==n: continue
        for q in g.routes.get(m,[]):
            qy=[p[1] for p in q]; qx=[p[2] for p in q]
            if max(qy)<j0 or min(qy)>=j1 or max(qx)<i0 or min(qx)>=i1: continue
            c=0
            for l,iy,ix in q:
                if j0<=iy<j1 and i0<=ix<i1 and cells[l][max(0,iy-j0-R):iy-j0+R+1,max(0,ix-i0-R):ix-i0+R+1].any(): c+=1
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
                if bud_ok(n,m): gain+=oc+oq-nc; changed+=1; break
            g.set_route(n,keep_n); g.set_route(m,keep_m)
    return gain,changed
def polish_net(n):
    """lift the whole net and re-route it from scratch with everything else fixed; keep when cheaper"""
    paths=list(g.routes.get(n,[]))
    if not paths: return 0.0,0
    oc=sum(g.path_cost(p) for p in paths)
    win=search_window([c for p in paths for c in p],WIN); W=(slice(win[2],win[3]),slice(win[0],win[1]))
    g.set_route(n,[]); new=[]
    for _ in range(200):
        la,lb=g.components(n); cF,cB=g.last_copper
        la=la[W]; lb=lb[W]; cF=cF[W]; cB=cB[W]
        ca=np.bincount(la[cF]); cbn=np.bincount(lb[cB]); m=max(len(ca),len(cbn)); cnt=np.zeros(m,np.int64); cnt[:len(ca)]+=ca; cnt[:len(cbn)]+=cbn; cnt[0]=0
        if (cnt>0).sum()<=1: break
        s=int(cnt.argmax())
        srcm={'F.Cu':(la==s)&cF,'B.Cu':(lb==s)&cB}; goalm={'F.Cu':(la>0)&(la!=s)&cF,'B.Cu':(lb>0)&(lb!=s)&cB}
        bt,bv=g.blocked(n,hard=True,win=win); ring=g.own_ring(n,win)
        ct=[1.0+g.RING*ring[l] for l in range(2)]
        newp,ne=g.astar(srcm,goalm,bt,bv,ct,None,win)
        if not newp or len(newp)<2: g.set_route(n,paths); return 0.0,0
        new.append(newp); g.set_route(n,new)
    la,lb=g.components(n); la=la[W]; lb=lb[W]
    if len(np.unique(np.concatenate([la[la>0],lb[lb>0]])))>1: g.set_route(n,paths); return 0.0,0
    nc=sum(g.path_cost(p) for p in new)
    if nc<oc-MINGAIN and bud_ok(n): rechain(n); return oc-nc,1
    g.set_route(n,paths); return 0.0,0
def runs(path):
    out=[]; i=0
    while i<len(path)-1:
        l,y,x=path[i]; l2,y2,x2=path[i+1]
        if l!=l2: i+=1; continue
        d=(y2-y,x2-x); j=i+1
        while j<len(path)-1 and path[j+1][0]==l and (path[j+1][1]-path[j][1],path[j+1][2]-path[j][2])==d: j+=1
        out.append((i,j,l,d)); i=j
    return out
def shifted(path,i,j,l,d,s):
    """path with the straight run i..j moved s cells sideways (perpendicular legs at both ends); None if it leaves the grid"""
    py,px=(-d[1],d[0]); sy,sx=py*s,px*s; sg=1 if s>0 else -1
    a=path[i]; b=path[j]
    leg1=[(l,a[1]+py*k*sg,a[2]+px*k*sg) for k in range(1,abs(s)+1)]
    run=[(l,p[1]+sy,p[2]+sx) for p in path[i+1:j]]
    leg2=[(l,b[1]+py*k*sg,b[2]+px*k*sg) for k in range(abs(s)-1,-1,-1)]
    new=path[:i+1]+leg1+run+leg2+path[j:]
    if any(c[1]<0 or c[2]<0 or c[1]>=g.ny or c[2]>=g.nx for c in new): return None
    return new
def shove_net(n):
    gain=0.0; changed=0
    paths=sorted(g.routes.get(n,[]),key=lambda p:-g.path_vias(p))
    for path in paths:
        if path not in g.routes[n] or g.path_vias(path)==0: continue
        oc=g.path_cost(path); j0,j1,i0,i1=chain_bbox(path,int(2/G)); done=False
        for m,q in neighbours(n,path):
            if q not in g.routes.get(m,[]): continue
            oq=g.path_cost(q); keep_n=list(g.routes[n]); keep_m=list(g.routes[m])
            g.set_route(n,[p for p in keep_n if p is not path]); g.set_route(m,[p for p in keep_m if p is not q])
            bt,bv=g.blocked(m,hard=True)
            for (i,j,l,d) in runs(q):
                if j-i<int(1/G): continue
                ys=[q[k][1] for k in range(i,j+1)]; xs=[q[k][2] for k in range(i,j+1)]
                if max(ys)<j0 or min(ys)>=j1 or max(xs)<i0 or min(xs)>=i1: continue
                for s in [v for k in range(1,SHOVE+1) for v in (k,-k)]:
                    nq=shifted(q,i,j,l,d,s)
                    if nq is None or any(bt[c[0]][c[1],c[2]] for c in nq[i+1:i+abs(s)+1+(j-i-1)+abs(s)]): continue
                    g.set_route(m,[p for p in keep_m if p is not q]+[nq])
                    newp,drop=reroute_chain(n,path)
                    if newp is not None and not drop:
                        nc=g.path_cost(newp)+g.path_cost(nq)
                        if nc<oc+oq-MINGAIN and g.path_vias(newp)<g.path_vias(path):
                            g.set_route(n,[p for p in keep_n if p is not path]+[newp])
                            if bud_ok(n,m): gain+=oc+oq-nc; changed+=1; done=True; break
                            g.set_route(n,[p for p in keep_n if p is not path])
                    g.set_route(m,[p for p in keep_m if p is not q])
                if done: break
            if done: rechain(m); break
            g.set_route(n,keep_n); g.set_route(m,keep_m)
        if not done: g.set_route(n,[p for p in g.routes[n]] if g.routes.get(n) else [])
    return gain,changed
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
            old=list(g.routes[n]); new=[p for p in old if p is not path]; g.set_route(n,new)
            if bud_ok(n): gain+=oc; dropped+=1
            else: g.set_route(n,old)
            continue
        if newp and g.path_cost(newp)<oc-MINGAIN:
            old=list(g.routes[n]); new=[p for p in old if p is not path]+[newp]; g.set_route(n,new)
            if bud_ok(n): gain+=oc-g.path_cost(newp); changed+=1
            else: g.set_route(n,old)
    return gain,changed,dropped
def stage_order(stage):
    """the sequential order of a stage over the ACTIVE nets: costliest / most vias first"""
    if stage=='net': return sorted(ACTIVE,key=lambda n:-sum(g.path_cost(p) for p in g.routes.get(n,[])))
    if stage=='cleanup': return list(ACTIVE)
    return sorted(ACTIVE,key=lambda n:-sum(g.path_vias(p) for p in g.routes.get(n,[])))
def net_step(stage,n):
    """one net of a stage on this process' grid: (gain, changed, dropped)"""
    if not g.routes.get(n): return 0.0,0,0
    if stage=='net':
        gain,changed=polish_net(n); return gain,changed,0
    if stage in ('chain','cleanup'):
        gain,changed,dropped=tidy_net(n)
        if changed or dropped: rechain(n)
        return gain,changed,dropped
    gain,changed=(pair_net if stage=='pair' else shove_net)(n)
    if changed: rechain(n)
    return gain,changed,0
def stage_pass(stage):
    """one sequential pass of a stage over the ACTIVE nets: (gain, changed, dropped)"""
    tg=0.0; tc=0; td=0
    for n in stage_order(stage):
        a,b,c=net_step(stage,n); tg+=a; tc+=b; td+=c
    return tg,tc,td
def worker_main(state,qin,qout,wid):
    """a worker: attaches to the main process' shared read-only grid arrays, keeps its own routes and occupancy; the main
    process hands it one net at a time and streams every accepted move of the other workers to it in between"""
    global g,nets,ACTIVE
    g=Grid.attach(state); nets=g.nets; ACTIVE=g.scope; ver={}
    while True:
        msg=qin.get()
        if msg is None: break
        if msg[0]=='update':
            for n,routes in msg[1].items(): g.set_route(n,routes)
            ver.update(msg[2])
        else:
            stage,n=msg[1],msg[2]; snap={m:list(g.routes.get(m,[])) for m in g.scope}
            tg,tc,td=net_step(stage,n)
            touched={m:g.routes.get(m,[]) for m in g.scope if g.routes.get(m,[])!=snap[m]}
            qout.put((wid,n,tg,tc,td,touched,{m:ver.get(m,0) for m in touched}))
def free_cells(n,paths,old):
    """True when every cell of the paths that is not already in the old paths is free of all copper but net n's fixed copper
    (own routes lifted by the caller; cells the old routes used stay valid even where today's rules would block them)"""
    cells=[c for p in paths for c in p]
    if not cells: return True
    oc=set(c for p in old for c in p); ov=set((q[1],q[2]) for p in old for k,q in enumerate(p) if k and p[k-1][0]!=q[0])
    ys=[c[1] for c in cells]; xs=[c[2] for c in cells]; y0,y1,x0,x1=min(ys),max(ys)+1,min(xs),max(xs)+1; sl=(slice(y0,y1),slice(x0,x1))
    bt=[(g.mul_t[L][sl]|((g.own_t[L][sl]!=0)&(g.own_t[L][sl]!=n))|g.edge_t[sl]|(g.occ_t[L][sl]>0)) for L in LAY]
    bv=g.mul_v[sl]|((g.own_v[sl]!=0)&(g.own_v[sl]!=n))|g.edge_v[sl]|(g.occ_v[sl]>0)
    for p in paths:
        for i,(l,iy,ix) in enumerate(p):
            if (l,iy,ix) not in oc and bt[l][iy-y0,ix-x0]: return False
            if i and p[i-1][0]!=l and (iy,ix) not in ov and bv[iy-y0,ix-x0]: return False
    return True
RETRY=int(E('RETRY','2')); LOOK=int(E('LOOK','16'))
class Pool:
    """worker processes, each with its own grid, fed one net at a time in the sequential order (skipping ahead past nets whose
    windows overlap a net in flight); every move is validated on the main grid against the state the workers were told
    about (per-net versions) and streamed to all workers, so a worker rarely builds on stale copper; a rejected move is
    retried later in the pass on the fresh state"""
    def __init__(self,k):
        import multiprocessing as mp
        ctx=mp.get_context('spawn'); self.w=[]; state=g.share(); self.qout=ctx.Queue()
        for i in range(k):
            qi=ctx.Queue(); p=ctx.Process(target=worker_main,args=(state,qi,self.qout,i),daemon=True); p.start(); self.w.append((p,qi))
        self.k=k; self.ver={}
    def box(self,n):
        pad=int(WIN/G); cells=[c for p in g.routes.get(n,[]) for c in p]
        if not cells: return None
        ys=[c[1] for c in cells]; xs=[c[2] for c in cells]
        return min(ys)-pad,max(ys)+pad,min(xs)-pad,max(xs)+pad
    def run(self,stage):
        """returns (accepted gain, accepted nets, dropped chains, rejected moves)"""
        import collections
        pending=collections.deque(stage_order(stage)); tries={}; inflight={}; idle=list(range(self.k)); boxes={}
        tg=0.0; td=0; acc=0; conf=0; self.dup=0; twait=0.0
        def apart(a,b): return a is None or b is None or a[1]<b[2] or b[1]<a[2] or a[3]<b[0] or b[3]<a[0]
        def dispatch(wid):
            pick=0
            for i,n in enumerate(pending):
                if i>=LOOK: break
                bx=self.box(n)
                if all(apart(bx,boxes[m]) for m in inflight.values()): pick=i; break
            pending.rotate(-pick); n=pending.popleft(); pending.rotate(pick)
            boxes[n]=self.box(n); inflight[wid]=n; self.w[wid][1].put(('do',stage,n))
        while pending or inflight:
            while idle and pending: dispatch(idle.pop())
            t1=time.time(); wid,n,wg,wc,wd,touched,vseen=self.qout.get(); twait+=time.time()-t1
            inflight.pop(wid); boxes.pop(n,None); idle.append(wid)
            if not touched: continue
            olds={m:g.routes.get(m,[]) for m in touched}
            if any(self.ver.get(m,0)!=vseen.get(m,0) for m in touched): ok=False; self.dup+=1   # built on a move it had not seen yet
            else:
                for m in touched: g.set_route(m,[])
                for m in touched: g.set_route(m,touched[m])
                ok=True
                for m in touched:
                    g.set_route(m,[]); ok=free_cells(m,touched[m],olds[m]); g.set_route(m,touched[m])
                    if not ok: break
            if ok:
                for m in touched: rechain(m); self.ver[m]=self.ver.get(m,0)+1
                upd=('update',{m:g.routes[m] for m in touched},{m:self.ver[m] for m in touched})
                for p,qi in self.w: qi.put(upd)
                tg+=wg; td+=wd; acc+=len(touched)
            else:
                for m in touched: g.set_route(m,olds[m])
                self.w[wid][1].put(('update',olds,{m:self.ver.get(m,0) for m in touched}))
                conf+=1; tries[n]=tries.get(n,0)+1
                if tries[n]<RETRY: pending.append(n)
        if E('TIMING'): print(f'  main waited {twait:.0f} s',flush=True)
        return tg,acc,td,conf
    def close(self):
        for p,qi in self.w: qi.put(None)
        for p,qi in self.w: p.join()
        g.unshare()
def avail_bytes():
    try:
        if os.name=='nt':
            import ctypes
            class MS(ctypes.Structure): _fields_=[('dwLength',ctypes.c_ulong),('dwMemoryLoad',ctypes.c_ulong)]+[(k,ctypes.c_ulonglong) for k in ('tp','ap','tpf','apf','tv','av','aev')]
            m=MS(); m.dwLength=ctypes.sizeof(MS); ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(m)); return int(m.ap)
        for l in open('/proc/meminfo'):
            if l.startswith('MemAvailable'): return int(l.split()[1])*1024
    except Exception: pass
    return None
def main():
    global WORKERS
    setup()
    av=avail_bytes()
    if WORKERS>1 and av:
        cap=max(1,int(0.8*av/(40*g.nx*g.ny+3e8)))   # a worker holds its occupancy + search temporaries, ~40 bytes per cell; the rest is shared
        if cap<WORKERS: print(f'WORKERS {WORKERS} -> {cap} (available memory {av/1e9:.1f} GB)',flush=True); WORKERS=cap
    pool=Pool(WORKERS) if WORKERS>1 else None
    if pool: print(f'{WORKERS} workers',flush=True)
    def run(stage):
        if pool:
            tg,tc,td,conf=pool.run(stage); run.conf=conf; return tg,tc,td,f' ({conf} moves rejected, {pool.dup} built on a move not yet seen)' if conf else ''
        tg,tc,td=stage_pass(stage); run.conf=0; return tg,tc,td,''
    run.conf=0
    def more(ps,tc,td=0):
        """keep going while something improved, or while conflicts remain to be retried (up to twice the passes)"""
        return (tc or td) or (run.conf and ps<2*PASSES-1)
    tot_before={n:(sum(g.path_vias(p) for p in g.routes[n]),sum(len(p) for p in g.routes[n])) for n in g.scope}
    if NETPASS:
        for ps in range(2*NETPASSES):
            t1=time.time(); tg,tc,td,x=run('net')
            print(f'net pass {ps}: {tc} nets improved, cost gain {tg:.0f}, {time.time()-t1:.0f} s{x}',flush=True)
            if not (tc or (run.conf and ps<2*NETPASSES-1)) or (ps>=NETPASSES-1 and not run.conf): break
    for ps in range(2*PASSES):
        t1=time.time(); tg,tc,td,x=run('chain')
        print(f'pass {ps}: {tc} chains improved, {td} dropped, cost gain {tg:.0f}, {time.time()-t1:.0f} s{x}',flush=True)
        if not more(ps,tc,td) or (ps>=PASSES-1 and not run.conf): break
    if PAIR:
        for ps in range(2*PASSES):
            t1=time.time(); tg,tc,td,x=run('pair')
            print(f'pair pass {ps}: {tc} chain pairs improved, cost gain {tg:.0f}, {time.time()-t1:.0f} s{x}',flush=True)
            if not more(ps,tc) or (ps>=PASSES-1 and not run.conf): break
            run('cleanup')   # single-chain clean-up after the pair moves
    if SHOVE:
        for ps in range(2*PASSES):
            t1=time.time(); tg,tc,td,x=run('shove')
            print(f'shove pass {ps}: {tc} chains improved, cost gain {tg:.0f}, {time.time()-t1:.0f} s{x}',flush=True)
            if not more(ps,tc) or (ps>=PASSES-1 and not run.conf): break
            run('cleanup')
    if pool: pool.close()
    vb=sum(v for v,_ in tot_before.values()); va=sum(sum(g.path_vias(p) for p in g.routes[n]) for n in g.scope)
    cb=sum(c for _,c in tot_before.values()); ca=sum(sum(len(p) for p in g.routes[n]) for n in g.scope)
    print(f'vias {vb} -> {va}, cells {cb} -> {ca}, {time.time()-t0:.0f} s')
    if BG: print(f'length budgets after tidy: {sum(1 for v in EXC.values() if v>0)} nets over budget by {sum(EXC.values()):.0f} mm')
    g.write_out(dst)
if __name__=='__main__': main()

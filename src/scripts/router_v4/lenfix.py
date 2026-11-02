"""lenfix.py in out BUDGET=budgets.json [BASE=base | NETS=@file] : repair pass for track-length budgets (budgets.py).
Every scope net with a pair over its budget is lifted and grown again pin by pin, tightest budget first (ratio budget /
straight distance): each new pin is joined to the tree by an A* whose start cells carry their copper distance from the
pin it is budgeted against (gridcore astar2), so the search minimises the driver-to-load length, and tree cells that cannot
meet the budget (distance + straight remainder > budget) are not offered as starts. Pins without a budget join afterwards,
nearest first. Kept when the net's excess (mm over budget, summed over its pairs) drops and nothing is left open.
LENRIP=1: a net that still breaks a budget is grown again ignoring the other scope nets' routes; the nets its new copper
crosses are lifted, the net is grown for real, and each lifted net is grown again (budget-aware when it has budgets). Kept
when everything connects and the summed excess of the net and the lifted nets drops.
env: LVIA=40 (via cost in cells while growing budgeted pins)  LAGAINST=1.5  LBEND=1  WIN=30 (mm)  LPASSES=2  LENRIP=1  RIPMAX=6
     LENSCALE=1.02 (grid length factor, see lenbudget.py)  BUDGETSLACK=0 (mm added to every budget)"""
import sys, os, time, math
import numpy as np
TOOLS=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,TOOLS)
from gridcore import *
import gridcore, lenbudget
LVIA=float(E('LVIA','40')); LAGAINST=float(E('LAGAINST','1.5')); LBEND=float(E('LBEND','1')); LWIN=float(E('WIN','30'))
RIPMAX=int(E('RIPMAX','6'))
def man_mm(B,a,b):
    p=B.padinfo[a]; q=B.padinfo[b]; return abs(p['x']-q['x'])+abs(p['y']-q['y'])
def _astar_init(g,srcm,goalm,bt,bv,ct,cvia,win,sinit,against,bend):
    """gridcore.Grid.astar with start costs (cells) per source cell"""
    import ctypes
    from scipy.ndimage import distance_transform_edt
    wx0,wx1,wy0,wy1=win; nx,ny=g.nx,g.ny
    gm=np.stack([goalm[L] for L in LAY]); sm=np.stack([srcm[L] for L in LAY])
    H=np.full((ny,nx),1e9,np.float32); sub=~gm.any(0)[wy0:wy1,wx0:wx1]
    H[wy0:wy1,wx0:wx1]=distance_transform_edt(sub) if sub.any() else 0
    a=lambda x,t: np.ascontiguousarray(x.astype(t))
    btc=a(np.stack(bt),np.uint8); bvc=a(bv,np.uint8); ctc=a(np.stack(ct),np.float32); cvc=a(cvia,np.float32)
    smc=a(sm,np.uint8); gmc=a(gm,np.uint8); si=a(sinit,np.float32)
    maxlen=400000; out=np.zeros(3*maxlen,np.int32); ne=ctypes.c_int64(0)
    f=gridcore.lib.astar2; f.restype=ctypes.c_int
    k=f(int(nx),int(ny),int(wx0),int(wx1),int(wy0),int(wy1),c_u8(btc),c_u8(bvc),c_f32(ctc),c_f32(cvc),c_f32(H),c_u8(smc),c_u8(gmc),
        ctypes.c_float(against),ctypes.c_float(bend),c_u8(g.field),out.ctypes.data_as(ctypes.POINTER(ctypes.c_int32)),int(maxlen),ctypes.byref(ne),int(g.DIAG),c_f32(si))
    if k==0: return None
    p=out[:3*k].reshape(k,3)[::-1]
    return [(int(l),int(iy),int(ix)) for l,iy,ix in p]
class Fixer:
    def __init__(self,g,B,quiet=False):
        self.g=g; self.B=B; self.quiet=quiet
    def pad_label(self,la,lb,name):
        pj,pi,m,lay=self.B.pad_cells(name); labs=(la,lb); s=set()
        for l in lay:
            blk=labs[l][pj:pj+m.shape[0],pi:pi+m.shape[1]]
            s|=set(np.unique(blk[m[:blk.shape[0],:blk.shape[1]]]).tolist())
        s.discard(0); return min(s) if s else 0
    def blocked_for(self,n,hard):
        g=self.g; g.apply_stamps(g.stamps.get(n,[]),-1)
        bt,bv=g.blocked(n,hard=hard); ring=g.own_ring(n)
        g.apply_stamps(g.stamps.get(n,[]),1)
        return bt,bv,ring
    def grow(self,n,hard=True,budgeted=True,winmm=None):
        """lift net n and grow it again. returns True when every component got joined (routes set), else restores nothing
        (caller restores)."""
        g=self.g; B=self.B; G=gridcore.G
        allpads=[f"{p['ref']}-{p['num']}" for p in g.pads if p['net']==n]
        pm={'F.Cu':np.zeros((g.ny,g.nx),bool),'B.Cu':np.zeros((g.ny,g.nx),bool)}
        for nm in allpads:
            pj,pi,m,lay=B.pad_cells(nm)
            for L in LAY: pm[L][pj:pj+m.shape[0],pi:pi+m.shape[1]]|=m
        for p in g.routes.get(n,[]):
            for l,iy,ix in p: pm[LAY[l]][iy,ix]=True
        win=g.window([pm],winmm or LWIN)
        g.set_route(n,[]); new=[]
        pairs=[(a,b,cap) for a,b,cap in (B.pairs.get(n,[]) if budgeted else []) if a in B.padinfo and b in B.padinfo]
        ratio=lambda t: t[2]/max(man_mm(B,t[0],t[1]),1.0)
        pairs.sort(key=ratio)
        for _ in range(400):
            la,lb=g.components(n); cF,cB=g.last_copper
            labs=np.unique(np.concatenate([la[la>0],lb[lb>0]]))
            if len(labs)<=1: return self.geo_connected(n)
            # tree = the component holding the tightest pair's first pin (stable as it grows)
            step=None
            if pairs:
                root=self.pad_label(la,lb,pairs[0][0]); intree=lambda nm: self.pad_label(la,lb,nm)==root
                for a,b,cap in pairs:
                    ia,ib=intree(a),intree(b)
                    if ia!=ib: step=(a,b,cap) if ia else (b,a,cap); break
            if step is not None:
                q,p,cap=step; root=self.pad_label(la,lb,q); tgt=self.pad_label(la,lb,p)
                srcm={'F.Cu':(la==root)&cF,'B.Cu':(lb==root)&cB}; goalm={'F.Cu':(la==tgt)&cF,'B.Cu':(lb==tgt)&cB}
                _,maps=B.lengths(n,[(q,p,cap)],dist_maps=True)
                d=maps.get(q)
                if d is None: return False
                pp=B.padinfo[p]
                XX=g.ox+np.arange(g.nx)*G; YY=g.oy+np.arange(g.ny)*G
                rem=np.abs(XX[None,:]-pp['x'])+np.abs(YY[:,None]-pp['y'])
                ok=[np.isfinite(d[l])&((d[l]+rem)*lenbudget.SCALE<=cap) for l in range(2)]
                for l,L in enumerate(LAY):
                    s2=srcm[L]&ok[l]
                    if s2.any(): srcm[L]=s2
                sinit=np.where(np.isfinite(d),d/G,0).astype(np.float32)
                bt,bv,ring=self.blocked_for(n,hard)
                ct=[1.0+g.RING*ring[l] for l in range(2)]; cvia=np.full((g.ny,g.nx),LVIA,np.float32)
                newp=_astar_init(g,srcm,goalm,bt,bv,ct,cvia,win,sinit,LAGAINST,LBEND)
                if newp is None:   # all starts allowed, plain costs
                    srcm={'F.Cu':(la==root)&cF,'B.Cu':(lb==root)&cB}
                    newp=_astar_init(g,srcm,goalm,bt,bv,ct,cvia,win,sinit,LAGAINST,LBEND)
            else:
                cnt={int(k):int(((la==k)&cF).sum()+((lb==k)&cB).sum()) for k in labs}
                s=max(cnt,key=cnt.get)
                srcm={'F.Cu':(la==s)&cF,'B.Cu':(lb==s)&cB}; goalm={'F.Cu':(la>0)&(la!=s)&cF,'B.Cu':(lb>0)&(lb!=s)&cB}
                bt,bv,ring=self.blocked_for(n,hard)
                ct=[1.0+g.RING*ring[l] for l in range(2)]; cvia=np.full((g.ny,g.nx),g.VIA_COST,np.float32)
                newp,_=g.astar(srcm,goalm,bt,bv,ct,cvia,win)
            if not newp or len(newp)<2: return False
            new.append(newp); g.set_route(n,new)
        return False
    def geo_connected(self,n):
        """exact check on the copper shapes (as conn.py / KiCad see it): the grid labels count copper cells one diagonal step
        apart as joined, so a via 0.07 mm short of a pad passed as connected (bench 2026-11-02)"""
        g=self.g; shapes=[]
        for it in g.items:
            if it is not None and it[0]==n: shapes.append((it[1],it[2]))
        for path in g.routes.get(n,[]): shapes+=g.path_geoms(path)
        par=list(range(len(shapes)))
        def f(i):
            while par[i]!=i: par[i]=par[par[i]]; i=par[i]
            return i
        from shapely.strtree import STRtree
        tree=STRtree([s for _,s in shapes])
        for i,(li,si) in enumerate(shapes):
            for j in tree.query(si):
                j=int(j)
                if j>i and li&shapes[j][0] and si.intersects(shapes[j][1]): par[f(i)]=f(j)
        padidx=[i for i,it in enumerate([x for x in g.items if x is not None and x[0]==n]) if it[3][0]=='pad']
        return len({f(i) for i in padidx})<=1
    def crossed(self,n):
        """scope nets whose route stamps overlap net n's route cells"""
        g=self.g; hit={}
        cells=[(l,iy,ix) for p in g.routes.get(n,[]) for (l,iy,ix) in p]
        if not cells: return []
        mt=[np.zeros((g.ny,g.nx),bool) for _ in LAY]
        for l,iy,ix in cells: mt[l][iy,ix]=True
        for m in g.scope:
            if m==n: continue
            c=0
            for kind,L,j0,i0,mm in g.stamps.get(m,[]):
                if kind!='t' or mm.size==0: continue
                c+=int((mt[LAY.index(L)][j0:j0+mm.shape[0],i0:i0+mm.shape[1]]&mm).sum())
            if c: hit[m]=c
        return sorted(hit,key=lambda m:-hit[m])
    def fix_net(self,n,rip=True):
        g=self.g; B=self.B
        old=list(g.routes.get(n,[])); ex0,bad0,op0=B.excess(n); pre=''
        if bad0==0 and op0==0: return 'ok'
        ok=self.grow(n,hard=True)
        if ok:
            ex1,bad1,op1=B.excess(n)
            if op1==0 and ex1<ex0-0.5:
                if ex1<=0 or not rip: return f'fixed {ex0:.0f}->{ex1:.0f} mm'
                pre=f'fixed {ex0:.0f}->{ex1:.0f} mm, '; old=list(g.routes[n]); ex0,bad0=ex1,bad1
            else: g.set_route(n,old)
        else: g.set_route(n,old)
        r=self._rip(n,ex0) if rip else 'kept'
        return pre+r if pre and not r.startswith('fixed') else r
    def _rip(self,n,ex0):
        g=self.g; B=self.B
        # rip-up: grow ignoring the other scope routes, lift what the new copper crosses
        keep={n:list(g.routes[n])}
        if not self.grow(n,hard=False): g.set_route(n,keep[n]); return 'kept'
        ex_s,_,op_s=B.excess(n)
        if op_s or ex_s>=ex0-0.5: g.set_route(n,keep[n]); return f'kept (best possible {ex_s:.0f} mm over)'
        vict=self.crossed(n)[:RIPMAX]; g.set_route(n,keep[n])
        if not vict: return 'kept'
        vex={m:B.excess(m)[0] if m in B.pairs else 0.0 for m in vict}
        for m in vict: keep[m]=list(g.routes[m]); g.set_route(m,[])
        def undo():
            for m,r in keep.items(): g.set_route(m,[])
            for m,r in keep.items(): g.set_route(m,r)
        if not self.grow(n,hard=True): undo(); return 'kept (rip failed)'
        ex1,_,op1=B.excess(n)
        if op1 or ex1>=ex0-0.5: undo(); return 'kept (rip no gain)'
        for m in vict:
            if not self.grow(m,hard=True,budgeted=m in B.pairs) and not self.grow(m,hard=True,budgeted=m in B.pairs,winmm=3*LWIN):
                undo(); return f'kept (victim {g.nets[m]} failed)'
        after=ex1+sum(B.excess(m)[0] for m in vict if m in B.pairs); before=ex0+sum(vex.values())
        if after>=before-0.5: undo(); return f'kept (moved nets got longer: {before:.0f}->{after:.0f} mm in all)'
        return f'fixed by rip-up {ex0:.0f}->{ex1:.0f} mm ({len(vict)} nets moved, all budgeted nets {before:.0f}->{after:.0f} mm)'
    def run(self,passes=2,rip=True):
        g=self.g; B=self.B; t0=time.time()
        for ps in range(passes):
            nets=sorted(B.nets(),key=lambda n:-B.excess(n)[0]); done=0; bad=0
            for n in nets:
                ex,b,o=B.excess(n)
                if not b and not o: continue
                bad+=1; r=self.fix_net(n,rip)
                if r.startswith('fixed'): done+=1
                if not self.quiet: print(f'  {g.nets[n]}: {ex:.0f} mm over in {b} pairs -> {r}',flush=True)
            if not self.quiet: print(f'length pass {ps}: {done}/{bad} nets improved, {time.time()-t0:.0f} s',flush=True)
            if done==0: break
def rechain_all(g,nets):
    """re-decompose routes into chains (tidy.rechain logic) so later tools see junction-split chains"""
    for n in nets:
        segs=[]; vias=[]
        for p in g.routes.get(n,[]):
            for a,b in zip(p,p[1:]):
                if a[0]!=b[0]: vias.append((g.mm(a[1],a[2]),VD,-1))
                else: segs.append((LAY[a[0]],g.mm(a[1],a[2]),g.mm(b[1],b[2]),W,-1))
        g.tailseg[n]=segs; g.tailvia[n]=vias
        np_=g.paths_from_tail(n)
        if np_ is not None: g.set_route(n,np_)
if __name__=='__main__':
    src,dst=sys.argv[1:3]; BASE=E('BASE'); NETS=E('NETS'); BUD=E('BUDGET')
    if not BUD: raise SystemExit('BUDGET=budgets.json needed (budgets.py)')
    def netlist(spec):
        if spec and spec.startswith('@'): return [l.strip() for l in open(spec[1:],encoding='utf-8') if l.strip()]
        return spec.split(',') if spec else []
    b0,n0,_f,_p,_e=load(src); nid0={v:k for k,v in n0.items()}
    g=Grid(src,BASE,scope={nid0[x] for x in netlist(NETS) if x in nid0} if NETS else None)
    B=lenbudget.Budgets(g,BUD,float(E('BUDGETSLACK','0')))
    tot,rows=B.report(); print(f'before: {tot[1]} pairs over budget by {tot[0]:.0f} mm, {tot[2]} open (budgeted nets in scope: {len(B.nets())})')
    for r in rows[:10]: print(f'  {r[1]} {r[2]}->{r[3]}: {r[4]:.1f} > {r[5]:.1f} mm')
    F=Fixer(g,B); F.run(int(E('LPASSES','2')),E('LENRIP','1')=='1')
    rechain_all(g,g.scope)
    tot,rows=B.report(); print(f'after: {tot[1]} pairs over budget by {tot[0]:.0f} mm, {tot[2]} open')
    for r in rows[:10]: print(f'  {r[1]} {r[2]}->{r[3]}: {r[4]:.1f} > {r[5]:.1f} mm')
    g.write_out(dst)

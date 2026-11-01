"""mroute4.py in out : negotiated-congestion router v4. Nets are routed in parallel batches (CPU: OpenMP threads,
GPU: one CUDA block per net) against the occupancy of all other nets, PathFinder style; then conflicted nets are
re-routed with other routes blocked; what is still open is written out unrouted (finish with mroute3.py / tidy.py).
env: BACKEND=auto|gpu|cpu  THREADS=cpu threads  BATCH=4 (nets per launch; larger batches converge worse even with SEQFIX)  ITERS=30  STALL=6  WIN=40 (mm)  VIA=120
     AGAINST=3  RING=8  PRES0=1 PRESF=1.5 PRESMAX=30  HARDROUNDS=6  NETS=a,b  GPUMEM=1.5 (GB per launch)  MAXSWEEPS=2000000  DELTA=1.5 (GPU near/far bucket width)
     BASE=<file> (scope = nets whose copper was added after BASE: that copper is stripped and re-routed)
     CHECKGPU=N compare CPU and GPU path costs for the first N nets and exit (backend self-test)
     SEQFIX=1 a batch-mate routed through an earlier batch-mate's new route is re-routed alone (large batches converge)
     CHAINRIP=1 rip-up removes only the crossed chains of a neighbour, not its whole route (shove-like)
     PROT=a,b nets never ripped (default: the clock/stall/write/sync nets below)  CRIT=a,b timing-critical nets: routed first,
     CRITVIA=2 (via cost x) CRITPRES=0.5 (they yield less to congestion so they stay short)  (default = PROT list)"""
import sys, os, time, ctypes, math
import numpy as np
TOOLS=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,TOOLS)
from gridcore import *
from scipy.ndimage import binary_dilation, label
E=os.environ.get
src,dst=sys.argv[1:3]
BACKEND=E('BACKEND','auto'); THREADS=int(E('THREADS','0')); BATCH=int(E('BATCH','4')); ITERS=int(E('ITERS','30')); STALL=int(E('STALL','6'))
WIN=float(E('WIN','40')); PRES=float(E('PRES0','1.0')); PRESF=float(E('PRESF','1.5')); PRESMAX=float(E('PRESMAX','30')); HARDROUNDS=int(E('HARDROUNDS','6'))
BUSGAIN=float(E('BUSGAIN','1.0')); GPUMEM=float(E('GPUMEM','1.5'))*1e9; MAXSWEEPS=int(E('MAXSWEEPS','2000000')); DELTA=float(E('DELTA','1.5')); NETS=E('NETS'); BASE=E('BASE')
T0=time.time()
def disk(r):
    k=int(math.ceil(r)); y,x=np.mgrid[-k:k+1,-k:k+1]; return (x*x+y*y)<=r*r+1e-9
D_T=disk(4.44); D_TV=disk(6.44); D_V=disk(8.44); PADC=9
def fast_stamps(self,path):
    """occupancy stamps from cells (same semantics as the shapely version): tracks 0.555 mm, vias 0.805/1.055 mm"""
    ys=[p[1] for p in path]; xs=[p[2] for p in path]
    j0=max(0,min(ys)-PADC); j1=min(self.ny,max(ys)+PADC+1); i0=max(0,min(xs)-PADC); i1=min(self.nx,max(xs)+PADC+1)
    tr=[np.zeros((j1-j0,i1-i0),bool) for _ in LAY]; vi=np.zeros((j1-j0,i1-i0),bool)
    for i,(l,iy,ix) in enumerate(path):
        tr[l][iy-j0,ix-i0]=True
        if i and path[i-1][0]!=l: vi[iy-j0,ix-i0]=True
    hasv=vi.any(); st=[]
    vt=binary_dilation(vi,D_TV) if hasv else None
    for l,L in enumerate(LAY):
        m=binary_dilation(tr[l],D_T) if tr[l].any() else np.zeros_like(vi)
        if hasv: m|=vt
        st.append(('t',L,j0,i0,m))
    anyt=tr[0]|tr[1]; mv=binary_dilation(anyt,D_TV)
    if hasv: mv|=binary_dilation(vi,D_V)
    st.append(('v',None,j0,i0,mv))
    return st
Grid.path_stamps=fast_stamps
g=Grid(src,BASE,scope=None if BASE else set())
nets=g.nets; nid=g.nid; nx,ny=g.nx,g.ny; N=nx*ny
# strip the scope's tail copper: it is re-routed from scratch
for n in list(g.scope): g.set_route(n,[])
# nets to route: every net with more than one group of fixed copper
todo=[]; groups0={}
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
    remap=np.zeros(len(par),np.int16)
    for k,i in enumerate(ids): remap[i]=k+1
    return remap[la],remap[lb],len(ids)
want=None if not NETS else {nid[x] for x in ([l.strip() for l in open(NETS[1:],encoding='utf-8') if l.strip()] if NETS.startswith('@') else NETS.split(',')) if x in nid}
cands=[n for n in nets if n and not nets[n].startswith('unconnected-') and nets[n] not in ('GND','+5V') and (want is None or n in want)]
if g.scope: cands=[n for n in cands if n in g.scope or want is not None]
for n in cands:
    la,lb,k=fixed_groups(n)
    if k>1:
        todo.append(n); ys,xs=np.nonzero((la>0)|(lb>0)); groups0[n]=(la.astype(np.int16),lb.astype(np.int16),k,(xs.min(),xs.max(),ys.min(),ys.max()))
print('open nets',len(todo),[nets[n] for n in todo],round(time.time()-T0),'s',flush=True)
CRITDEF='CLK,CLK_E,STALL_OUT,STALL_IN,RUN,~{WE},PIXEL_ENABLE,~{HSYNC},~{VSYNC}'
CRITN={nid[x] for x in E('CRIT',E('PROT',CRITDEF)).split(',') if x in nid}; CRITVIA=float(E('CRITVIA','2')); CRITPRES=float(E('CRITPRES','0.5'))
todo.sort(key=lambda n:(0 if n in CRITN else 1,(groups0[n][3][1]-groups0[n][3][0])+(groups0[n][3][3]-groups0[n][3][2])))
if CRITN&set(todo): print('critical nets first:',[nets[n] for n in todo if n in CRITN],flush=True)
g.scope=set(todo)
import re as _re
def busname(name):
    b=_re.sub(r'\d+$','',name); return b if b!=name else None
busof={}; busid={}
if BUSGAIN<1.0:
    members={}
    for n in todo:
        b=busname(nets[n])
        if b: members.setdefault(b,[]).append(n)
    for b,ns in members.items():
        if len(ns)>=3:
            busid[b]=len(busid)+1
            for n in ns: busof[n]=busid[b]
    print('buses',{b:len(ns) for b,ns in members.items() if b in busid},flush=True)
busmap=None
D_BAND=disk(7.0)
def update_busmap():
    """band next to routed bus members: within 7 cells of a sibling's path cells on the same layer, outside its clearance ring"""
    global busmap
    if not busof: return
    bm=np.zeros((2,ny,nx),np.int16)
    for n,bid in busof.items():
        for path in g.routes.get(n,[]):
            ys=[p[1] for p in path]; xs=[p[2] for p in path]
            j0=max(0,min(ys)-8); j1=min(ny,max(ys)+9); i0=max(0,min(xs)-8); i1=min(nx,max(xs)+9)
            for l in range(2):
                cells=np.zeros((j1-j0,i1-i0),bool)
                for pl,iy,ix in path:
                    if pl==l: cells[iy-j0,ix-i0]=True
                if not cells.any(): continue
                band=binary_dilation(cells,D_BAND)&~binary_dilation(cells,D_T)
                sub=bm[l,j0:j1,i0:i1]; sub[band]=bid
    busmap=np.ascontiguousarray(bm)
# ---- backends
class NetJob(ctypes.Structure):
    _fields_=[('n',ctypes.c_int),('wx0',ctypes.c_int),('wy0',ctypes.c_int),('ww',ctypes.c_int),('wh',ctypes.c_int),('ngroups',ctypes.c_int),
              ('off',ctypes.c_longlong),('qoff',ctypes.c_longlong),('poff',ctypes.c_longlong),('pcap',ctypes.c_int),
              ('pres',ctypes.c_float),('viacost',ctypes.c_float),('against',ctypes.c_float),('ring',ctypes.c_float),('soft',ctypes.c_float),('bend',ctypes.c_float),
              ('hard',ctypes.c_int),('maxsweeps',ctypes.c_int),('busid',ctypes.c_int),('busgain',ctypes.c_float),('delta',ctypes.c_float)]
P=ctypes.POINTER
class Maps(ctypes.Structure):
    _fields_=[('nx',ctypes.c_int),('ny',ctypes.c_int),('own_t',P(ctypes.c_int32)),('mul_t',P(ctypes.c_uint8)),('cop',P(ctypes.c_int32)),
              ('own_v',P(ctypes.c_int32)),('mul_v',P(ctypes.c_uint8)),('edge_t',P(ctypes.c_uint8)),('edge_v',P(ctypes.c_uint8)),('field',P(ctypes.c_uint8)),
              ('hist',P(ctypes.c_float)),('hist_v',P(ctypes.c_float)),('occ_t',P(ctypes.c_int16)),('occ_v',P(ctypes.c_int16)),
              ('soft_t',P(ctypes.c_uint8)),('soft_v',P(ctypes.c_uint8)),('bus',P(ctypes.c_int16))]
own_t=np.ascontiguousarray(np.stack([g.own_t[L] for L in LAY])); mul_t=np.ascontiguousarray(np.stack([g.mul_t[L] for L in LAY]).astype(np.uint8))
cop=np.ascontiguousarray(np.stack([g.cop[L] for L in LAY])); own_v=np.ascontiguousarray(g.own_v); mul_v=np.ascontiguousarray(g.mul_v.astype(np.uint8))
edge_t=np.ascontiguousarray(g.edge_t.astype(np.uint8)); edge_v=np.ascontiguousarray(g.edge_v.astype(np.uint8)); field=np.ascontiguousarray(g.field)
def cur_maps():
    hist=np.ascontiguousarray(np.stack([g.hist[L] for L in LAY]).astype(np.float32)); hist_v=np.ascontiguousarray(g.hist_v.astype(np.float32))
    occ_t=np.ascontiguousarray(np.stack([g.occ_t[L] for L in LAY]).astype(np.int16)); occ_v=np.ascontiguousarray(g.occ_v.astype(np.int16))
    return hist,hist_v,occ_t,occ_v
class CPU:
    name='cpu'
    def __init__(self):
        so=(os.path.join(TOOLS,'win','pfcpu.dll') if os.name=='nt' else os.path.join(TOOLS,'pfcpu.so'))
        if os.name!='nt' and (not os.path.exists(so) or os.path.getmtime(so)<max(os.path.getmtime(os.path.join(TOOLS,'pfcpu.c')),os.path.getmtime(os.path.join(TOOLS,'pfcommon.h')))):
            os.system(f'gcc -O3 -fopenmp -shared -fPIC -o {so} '+os.path.join(TOOLS,'pfcpu.c'))
        self.lib=ctypes.CDLL(so)
    def run(self,jobs,gid,state,ownocc,ownv,pcap_total,soft=None):
        hist,hist_v,occ_t,occ_v=cur_maps(); keep=(hist,hist_v,occ_t,occ_v)
        st_=soft[0].ctypes.data_as(P(ctypes.c_uint8)) if soft else None; sv_=soft[1].ctypes.data_as(P(ctypes.c_uint8)) if soft else None
        m=Maps(nx,ny,own_t.ctypes.data_as(P(ctypes.c_int32)),mul_t.ctypes.data_as(P(ctypes.c_uint8)),cop.ctypes.data_as(P(ctypes.c_int32)),
               own_v.ctypes.data_as(P(ctypes.c_int32)),mul_v.ctypes.data_as(P(ctypes.c_uint8)),edge_t.ctypes.data_as(P(ctypes.c_uint8)),edge_v.ctypes.data_as(P(ctypes.c_uint8)),
               field.ctypes.data_as(P(ctypes.c_uint8)),hist.ctypes.data_as(P(ctypes.c_float)),hist_v.ctypes.data_as(P(ctypes.c_float)),
               occ_t.ctypes.data_as(P(ctypes.c_int16)),occ_v.ctypes.data_as(P(ctypes.c_int16)),st_,sv_,busmap.ctypes.data_as(P(ctypes.c_int16)) if busmap is not None else None)
        J=(NetJob*len(jobs))(*jobs); path=np.zeros(pcap_total,np.int32); plen=np.zeros(len(jobs),np.int32); status=np.zeros(len(jobs),np.int32)
        self.lib.route_nets_cpu(ctypes.byref(m),J,len(jobs),gid.ctypes.data_as(P(ctypes.c_int16)),state.ctypes.data_as(P(ctypes.c_uint8)),
                                ownocc.ctypes.data_as(P(ctypes.c_int16)),ownv.ctypes.data_as(P(ctypes.c_int16)),path.ctypes.data_as(P(ctypes.c_int32)),plen.ctypes.data_as(P(ctypes.c_int32)),status.ctypes.data_as(P(ctypes.c_int32)),THREADS)
        return path,plen,status
class GPU:
    name='gpu'
    def __init__(self):
        import cupy as cp; self.cp=cp
        src=open(os.path.join(TOOLS,'pfgpu.cu')).read()
        self.mod=cp.RawModule(code=src,options=('-I'+TOOLS,'--std=c++11'),name_expressions=None)
        self.kern=self.mod.get_function('route_nets')
        self.d=dict(own_t=cp.asarray(own_t),mul_t=cp.asarray(mul_t),cop=cp.asarray(cop),own_v=cp.asarray(own_v),mul_v=cp.asarray(mul_v),
                    edge_t=cp.asarray(edge_t),edge_v=cp.asarray(edge_v),field=cp.asarray(field))
        self.dev=cp.cuda.Device(); print('GPU:',cp.cuda.runtime.getDeviceProperties(self.dev.id)['name'].decode(),flush=True)
    def run(self,jobs,gid,state,ownocc,ownv,pcap_total,soft=None):
        cp=self.cp; hist,hist_v,occ_t,occ_v=cur_maps()
        def ptr(a): return a.data.ptr
        dbus=cp.asarray(busmap) if busmap is not None else None
        dst_=cp.asarray(soft[0]) if soft else None; dsv_=cp.asarray(soft[1]) if soft else None
        st_=ctypes.cast(ptr(dst_),P(ctypes.c_uint8)) if soft else None; sv_=ctypes.cast(ptr(dsv_),P(ctypes.c_uint8)) if soft else None
        d=self.d; dh=cp.asarray(hist); dhv=cp.asarray(hist_v); do=cp.asarray(occ_t); dov=cp.asarray(occ_v)
        maps=Maps(nx,ny,ctypes.cast(ptr(d['own_t']),P(ctypes.c_int32)),ctypes.cast(ptr(d['mul_t']),P(ctypes.c_uint8)),ctypes.cast(ptr(d['cop']),P(ctypes.c_int32)),
                  ctypes.cast(ptr(d['own_v']),P(ctypes.c_int32)),ctypes.cast(ptr(d['mul_v']),P(ctypes.c_uint8)),ctypes.cast(ptr(d['edge_t']),P(ctypes.c_uint8)),
                  ctypes.cast(ptr(d['edge_v']),P(ctypes.c_uint8)),ctypes.cast(ptr(d['field']),P(ctypes.c_uint8)),ctypes.cast(ptr(dh),P(ctypes.c_float)),
                  ctypes.cast(ptr(dhv),P(ctypes.c_float)),ctypes.cast(ptr(do),P(ctypes.c_int16)),ctypes.cast(ptr(dov),P(ctypes.c_int16)),st_,sv_,ctypes.cast(ptr(dbus),P(ctypes.c_int16)) if busmap is not None else None)
        W2tot=sum(2*j.ww*j.wh for j in jobs)
        dp=cp.zeros(W2tot,cp.uint64); dgid=cp.asarray(gid); dstate=cp.asarray(state); dinq=cp.zeros(W2tot,cp.int32); downocc=cp.asarray(ownocc); downv=cp.asarray(ownv)
        q0=cp.zeros(W2tot,cp.int32); q1=cp.zeros(W2tot,cp.int32); dpath=cp.zeros(pcap_total,cp.int32)
        dplen=cp.zeros(len(jobs),cp.int32); dstatus=cp.zeros(len(jobs),cp.int32); qn=cp.zeros(2*len(jobs),cp.int32)
        J=(NetJob*len(jobs))(*jobs); dJ=cp.asarray(np.frombuffer(bytes(J),np.uint8))
        class Work(ctypes.Structure):
            _fields_=[('dp',ctypes.c_void_p),('gid',ctypes.c_void_p),('state',ctypes.c_void_p),('inq',ctypes.c_void_p),('ownocc',ctypes.c_void_p),('ownv',ctypes.c_void_p),('q0',ctypes.c_void_p),('q1',ctypes.c_void_p),
                      ('path',ctypes.c_void_p),('plen',ctypes.c_void_p),('status',ctypes.c_void_p)]
        work=Work(ptr(dp),ptr(dgid),ptr(dstate),ptr(dinq),ptr(downocc),ptr(downv),ptr(q0),ptr(q1),ptr(dpath),ptr(dplen),ptr(dstatus))
        def byval(st): return np.frombuffer(bytes(st),np.dtype((np.void,ctypes.sizeof(st))))[0]
        self.kern((len(jobs),),(1024,),(byval(maps),dJ,byval(work),qn))
        cp.cuda.Stream.null.synchronize()
        return cp.asnumpy(dpath),cp.asnumpy(dplen),cp.asnumpy(dstatus)
def make_backend():
    if BACKEND in ('auto','gpu'):
        try:
            import cupy as cp
            if cp.cuda.runtime.getDeviceCount()>0: return GPU()
        except Exception as ex:
            if BACKEND=='gpu': raise
            print('no GPU backend:',str(ex).split('\n')[0],flush=True)
    return CPU()
be=make_backend(); print('backend',be.name,flush=True)
# ---- routing one batch of nets
SOFTC=float(E('SOFTC','40')); CHAINRIP=E('CHAINRIP','1')=='1'; RIPFIXED=E('RIPFIXED','1')=='1'; RIPMAX=int(E('RIPMAX','4')); RIPROUNDS=int(E('RIPROUNDS','400'))
def net_groups(n):
    """groups of the net's fixed copper plus its kept routes (chain-level rip-up leaves partial routes in place)"""
    if not g.routes.get(n): return groups0[n]
    la,lb=g.components(n); ids=sorted(set(np.unique(la[la>0]).tolist())|set(np.unique(lb[lb>0]).tolist()))
    remap=np.zeros(int(max(la.max(),lb.max()))+1,np.int16)
    for k,i in enumerate(ids): remap[i]=k+1
    la=remap[la]; lb=remap[lb]; ys,xs=np.nonzero((la>0)|(lb>0))
    return la.astype(np.int16),lb.astype(np.int16),len(ids),(xs.min(),xs.max(),ys.min(),ys.max())
def route_batch(batch,hard,win_mm,soft=None,partial=False):
    """route the nets of batch in parallel; their own stamps are removed first. returns ({n: paths or None}, status)
    partial: kept routes count as groups (only the missing links are routed; the result is appended by the caller)"""
    jobs=[]; gids=[]; states=[]; owns=[]; ownvs=[]; off=0; poff=0
    for n in batch:
        la,lb,k,(x0,x1,y0,y1)=net_groups(n) if partial else groups0[n]; pad=int(win_mm/G)
        wx0=max(0,x0-pad); wx1=min(nx,x1+pad+1); wy0=max(0,y0-pad); wy1=min(ny,y1+pad+1); ww=wx1-wx0; wh=wy1-wy0; W2=2*ww*wh
        gw=np.ascontiguousarray(np.stack([la[wy0:wy1,wx0:wx1],lb[wy0:wy1,wx0:wx1]]).reshape(-1)).astype(np.int16)
        st=np.zeros(W2,np.uint8); smallest=min(range(1,k+1),key=lambda i:(gw==i).sum()); st[gw==smallest]=1
        oc=np.zeros((2,wh,ww),np.int16); ov=np.zeros((wh,ww),np.int16)
        for kind,L,j0,i0,mm in g.stamps.get(n,[]):   # the net's own previous route: not an obstacle to itself
            a0=max(j0,wy0); a1=min(j0+mm.shape[0],wy1); b0=max(i0,wx0); b1=min(i0+mm.shape[1],wx1)
            if a1<=a0 or b1<=b0: continue
            sub=mm[a0-j0:a1-j0,b0-i0:b1-i0]
            if kind=='t': oc[LAY.index(L),a0-wy0:a1-wy0,b0-wx0:b1-wx0]+=sub
            else: ov[a0-wy0:a1-wy0,b0-wx0:b1-wx0]+=sub
        owns.append(oc.reshape(-1)); ownvs.append(ov.reshape(-1))
        pcap=3*min(W2,300000)+8*k
        crit=n in CRITN
        jobs.append(NetJob(n,wx0,wy0,ww,wh,k,off,off,poff,pcap,PRES*(CRITPRES if crit else 1.0),g.VIA_COST*(CRITVIA if crit else 1.0),g.AGAINST,g.RING,SOFTC if soft else 0.0,g.BEND,int(hard),MAXSWEEPS,busof.get(n,0),BUSGAIN,DELTA))
        gids.append(gw); states.append(st); off+=W2; poff+=pcap
    gid=np.concatenate(gids); state=np.concatenate(states); ownocc=np.ascontiguousarray(np.concatenate(owns)); ownv=np.ascontiguousarray(np.concatenate(ownvs))
    path,plen,status=be.run(jobs,gid,state,ownocc,ownv,poff,soft)
    out={}
    for i,(n,j) in enumerate(zip(batch,jobs)):
        if status[i]!=0: out[n]=None; continue
        arr=path[j.poff:j.poff+plen[i]]; paths=[]; cur=[]
        k=0
        while k<len(arr):
            if arr[k]==-1:
                if len(cur)>=2: paths.append(cur[::-1])
                cur=[]; k+=1
            else: cur.append((int(arr[k]),int(arr[k+1]),int(arr[k+2]))); k+=3
        out[n]=paths
    return out,status
def batches(seq,size):
    for i in range(0,len(seq),size): yield seq[i:i+size]
def batch_size():
    if be.name=='gpu' or E('BATCH'): return BATCH
    return max(1,THREADS or os.cpu_count())
def overlaps(n,count_hist=True):
    c=0; g.apply_stamps(g.stamps.get(n,[]),-1)
    for path in g.routes.get(n,[]):
        for i,(l,iy,ix) in enumerate(path):
            if g.cop[LAY[l]][iy,ix]==n: continue
            if g.occ_t[LAY[l]][iy,ix]>0:
                c+=1
                if count_hist: g.hist[LAY[l]][iy,ix]+=1
            if i and path[i-1][0]!=l and g.occ_v[iy,ix]>0:
                c+=1
                if count_hist: g.hist_v[iy,ix]+=1
    g.apply_stamps(g.stamps.get(n,[]),1)
    return c
SEQFIX=E('SEQFIX','1')=='1'
def route_all(nets_list,hard,win_mm,bsize=None):
    """route in batches; with SEQFIX a batch-mate whose new route runs through an earlier batch-mate's new route is
    re-routed alone afterwards, so a large batch converges like a sequential pass"""
    fails=set()
    for b in batches(nets_list,bsize or batch_size()):
        out,status=route_batch(b,hard,win_mm)
        retry=[n for n in b if out[n] is None and win_mm<1e8]
        if retry: out.update(route_batch(retry,hard,1e9)[0])
        for n in b:
            if out[n] is None: fails.add(n); g.set_route(n,[])
            else: g.set_route(n,out[n])
        if SEQFIX and len(b)>1:
            acc_t=np.zeros((2,ny,nx),bool); acc_v=np.zeros((ny,nx),bool)
            def hits(n):
                for path in g.routes.get(n,[]):
                    for i,(l,iy,ix) in enumerate(path):
                        if acc_t[l,iy,ix] or (i and path[i-1][0]!=l and acc_v[iy,ix]): return True
                return False
            def commit(n):
                for k,L,j0,i0,mm in g.stamps.get(n,[]):
                    if k=='t': acc_t[LAY.index(L),j0:j0+mm.shape[0],i0:i0+mm.shape[1]]|=mm
                    else: acc_v[j0:j0+mm.shape[0],i0:i0+mm.shape[1]]|=mm
            redo=[]
            for n in b:
                if out[n] is None: continue
                if hits(n): redo.append(n)
                else: commit(n)
            for n in redo:
                o2,_=route_batch([n],hard,win_mm)
                if o2[n] is None and win_mm<1e8: o2,_=route_batch([n],hard,1e9)
                if o2[n]: g.set_route(n,o2[n])
                commit(n)
    return fails
def crossed_new(n,paths):
    """new routes of other nets whose footprint the paths of n run through: {net: [chains crossed]}"""
    cells={L:set() for L in LAY}; vcells=set()
    for path in paths:
        for i,(l,iy,ix) in enumerate(path):
            if g.occ_t[LAY[l]][iy,ix]>0: cells[LAY[l]].add((iy,ix))
            if i and path[i-1][0]!=l and g.occ_v[iy,ix]>0: vcells.add((iy,ix))
    def hits(st):
        for k,L,j0,i0,mm in st:
            cs=cells[L] if k=='t' else vcells
            if any(j0<=iy<j0+mm.shape[0] and i0<=ix<i0+mm.shape[1] and mm[iy-j0,ix-i0] for iy,ix in cs): return True
        return False
    out={}
    for m in todo:
        if m==n or not g.routes.get(m) or not hits(g.stamps.get(m,[])): continue
        ch=[q for q in g.routes[m] if hits(g.path_stamps(q))] if CHAINRIP else list(g.routes[m])
        if ch: out[m]=ch
    return out
PROTN=set(E('PROT',CRITDEF).split(','))
NORIP=[x for x in (nid.get('GND'),nid.get('+5V'))+tuple(nid[p] for p in PROTN if p in nid) if x]
def rip_masks(n):
    """fixed copper of rippable nets (not n, not protected, not pads/zones)"""
    rip_t=np.stack([(g.own_t[L]>0)&(g.own_t[L]!=n)&~g.mul_t[L]&~g.pad_t[L]&~np.isin(g.own_t[L],NORIP) for L in LAY])
    rip_v=(g.own_v>0)&(g.own_v!=n)&~g.mul_v&~g.pad_v&~np.isin(g.own_v,NORIP)
    return rip_t,rip_v
def rip_fixed(n,paths,rip_t,rip_v):
    """remove the fixed copper pieces the paths of n cross; those nets become routable. returns the nets that now have open groups"""
    crossed={}
    for path in paths:
        for i,(l,iy,ix) in enumerate(path):
            if rip_t[l,iy,ix]:
                mm=int(g.own_t[LAY[l]][iy,ix]); crossed.setdefault(mm,set()).add((LAY[l],*g.mm(iy,ix),'t'))
            if i and path[i-1][0]!=l and rip_v[iy,ix]:
                mm=int(g.own_v[iy,ix]); crossed.setdefault(mm,set()).add((None,*g.mm(iy,ix),'v'))
    ripped=set()
    from shapely.geometry import Point as _P
    for mm,cells in crossed.items():
        if mm<=0 or mm in NORIP: continue
        hit=set()
        for idx,it in enumerate(g.items):
            if it is None or it[0]!=mm or it[3][0]!='seg' and it[3][0]!='via': continue
            gt=it[2].buffer(CLR+W/2+g.M,8); gv=it[2].buffer(CLR+VD/2+g.M,8)
            for L,x,y,kind in cells:
                if (kind=='t' and L in it[1] and gt.contains(_P(x,y))) or (kind=='v' and gv.contains(_P(x,y))): hit.add(idx); break
        for idx in hit: g.drop_item(idx)
        for comp in g.fixed_groups_geo(mm):
            if not any(k[0]=='pad' for _,_,_,k in comp):
                for idx,_,_,_ in comp: g.drop_item(idx)
        g.reraster(mm)
        la,lb,k=fixed_groups(mm)
        if k>1:
            ys,xs=np.nonzero((la>0)|(lb>0)); groups0[mm]=(la.astype(np.int16),lb.astype(np.int16),k,(xs.min(),xs.max(),ys.min(),ys.max()))
            if mm not in todo: todo.append(mm); g.scope.add(mm)
            ripped.add(mm)
        print('  rip:',nets[n],'crosses fixed',nets[mm],'-> removed',len(hit),'pieces; groups',k,flush=True)
    return ripped
def ripretry(queue):
    """rip-up and retry: each queued net is routed with other routes blocked; one that cannot be placed cuts through
    the cheapest neighbors (cost SOFTC per cell), which are cleared and queued again; a net ripped RIPMAX times is locked."""
    ripcount={}; rounds=0; t0=time.time()
    for n in queue: g.set_route(n,[])
    print('rip-retry: start with',len(queue),'nets to place',('chain-level rip' if CHAINRIP else 'whole-net rip'),flush=True)
    while queue and rounds<RIPROUNDS:
        n=queue.pop(0); rounds+=1
        if g.routes.get(n) and net_groups(n)[2]<=1: continue   # still connected after a chain-level rip
        out,_=route_batch([n],True,WIN,partial=True)
        if out[n] is None: out,_=route_batch([n],True,1e9,partial=True)
        if out[n]: g.set_route(n,g.routes.get(n,[])+out[n]); continue
        locked=[m for m in todo if m!=n and g.routes.get(m) and ripcount.get(m,0)>=RIPMAX]
        lock_t=np.zeros((2,ny,nx),bool); lock_v=np.zeros((ny,nx),bool)
        for m in locked:
            for k,L,j0,i0,mm in g.stamps.get(m,[]):
                if k=='t': lock_t[LAY.index(L),j0:j0+mm.shape[0],i0:i0+mm.shape[1]]|=mm
                else: lock_v[j0:j0+mm.shape[0],i0:i0+mm.shape[1]]|=mm
        free_t=np.stack([(g.own_t[L]==0)|(g.own_t[L]==n) for L in LAY])&~np.stack([g.mul_t[L] for L in LAY]); free_v=((g.own_v==0)|(g.own_v==n))&~g.mul_v
        rip_t,rip_v=rip_masks(n) if RIPFIXED else (np.zeros((2,ny,nx),bool),np.zeros((ny,nx),bool))
        soft_t=np.ascontiguousarray(((np.stack([g.occ_t[L]>0 for L in LAY])&~lock_t&free_t)|rip_t).astype(np.uint8)); soft_v=np.ascontiguousarray((((g.occ_v>0)&~lock_v&free_v)|rip_v).astype(np.uint8))
        out,_=route_batch([n],True,1e9,soft=(soft_t,soft_v),partial=True)
        if not out[n] and locked:   # last resort: locked nets may be ripped too
            soft_t=np.ascontiguousarray(((np.stack([g.occ_t[L]>0 for L in LAY])&free_t)|rip_t).astype(np.uint8)); soft_v=np.ascontiguousarray((((g.occ_v>0)&free_v)|rip_v).astype(np.uint8))
            out,_=route_batch([n],True,1e9,soft=(soft_t,soft_v),partial=True)
            if out[n]: print('  rip-retry: unlocked for',nets[n],flush=True)
        if not out[n]:
            print('  rip-retry: no path at all for',nets[n],flush=True); g.set_route(n,[]); continue
        cn=crossed_new(n,out[n])
        for m,chains in cn.items():
            g.set_route(m,[q for q in g.routes[m] if not any(q is c for c in chains)]); ripcount[m]=ripcount.get(m,0)+1
            if m not in queue: queue.append(m)
        rf=rip_fixed(n,out[n],rip_t,rip_v) if RIPFIXED else set()
        for m in rf:
            if m not in queue: queue.append(m)
        g.set_route(n,g.routes.get(n,[])+out[n])
        print('  rip-retry',rounds,nets[n],'rips',{nets[m]:len(c) for m,c in cn.items()},'fixed',[nets[m] for m in rf],'queue',len(queue),flush=True)
    left=[n for n in todo if not g.routes.get(n) or net_groups(n)[2]>1]
    for n in left: g.set_route(n,[])
    print('rip-retry done after',rounds,'rounds; unrouted',[nets[n] for n in left],round(time.time()-t0),'s',flush=True)
    return left
if E('CHECKGPU'):
    # backend check: route the same nets on the CPU and the GPU and compare path costs (empty board, then congested)
    be_c=CPU(); be_g=GPU(); sel=todo[:int(E('CHECKGPU'))]
    def costs(b,ns):
        global be
        be=b; out,st=route_batch(ns,False,WIN)
        return {n:(round(sum(g.path_cost(p) for p in out[n]),1) if out[n] else ('FAIL',int(st[i]))) for i,n in enumerate(ns)}
    for phase in ('empty','congested'):
        rc=costs(be_c,sel); rg=costs(be_g,sel); bad=0
        for n in sel:
            if rc[n]!=rg[n]: bad+=1
            print(f'  {phase} {nets[n]:30s} cpu {rc[n]} gpu {rg[n]}' + ('' if rc[n]==rg[n] else '  <-- differs'),flush=True)
        print(phase,'nets',len(sel),'differing',bad,flush=True)
        if phase=='empty':
            be=be_c; PRES=4.0; fails=route_all(todo,False,WIN)   # now every net has a route: occupancy and pres costs apply
            for n in todo: overlaps(n)
    sys.exit(0)
fails=set(); conflicted=set(todo); best=None; noimp=0; it=0; tot=0
while it<ITERS and todo:
    t0=time.time()
    work=todo if (it==0 or it%4==0) else [n for n in todo if n in conflicted]
    update_busmap()
    fails=route_all(work,False,WIN)
    ov={n:overlaps(n) for n in todo}; tot=sum(ov.values()); conflicted={n for n,c in ov.items() if c}|fails
    print(f'iter {it} overlap cells {tot} conflicted {len(conflicted)} fails {[nets[n] for n in fails]} {time.time()-t0:.0f} s (total {time.time()-T0:.0f} s)',flush=True)
    key=(len(conflicted),tot)
    if best is None or key<best[0]: best=(key,{n:list(p) for n,p in g.routes.items()},set(fails)); noimp=0
    else: noimp+=1
    if tot==0 and not fails: break
    if noimp>=STALL: break
    it+=1; PRES=min(PRES*PRESF,PRESMAX)
if best and (len(conflicted),tot)>best[0]:
    print('restoring best iteration: conflicted',best[0][0],'overlap',best[0][1],flush=True)
    for n in todo: g.set_route(n,best[1].get(n,[]))
    fails=best[2]
conflicted={n for n in todo if overlaps(n,False)}|fails
# hard rounds: conflicted nets re-routed one at a time with everything else blocked
PRES=0.0
for r in range(HARDROUNDS):
    if not conflicted: break
    t0=time.time(); work=sorted(conflicted,key=lambda n:-overlaps(n,False))
    for n in work: g.set_route(n,[])
    fails=route_all(work,True,WIN,bsize=1)
    conflicted={n for n in todo if overlaps(n,False)}|fails
    print(f'hard round {r}: conflicted {len(conflicted)} fails {len(fails)} {time.time()-t0:.0f} s',flush=True)
    if not (conflicted-fails): break
left=[]
if conflicted:
    left=ripretry(sorted(conflicted,key=lambda n:-overlaps(n,False)))
for n in left: g.set_route(n,[])
# improvement passes: each net re-routed alone with everything else blocked, kept when cheaper
IMPROVE=int(E('IMPROVE','2'))
if IMPROVE and not left:
    PRES=0.0
    for ip in range(IMPROVE):
        t0=time.time(); gain=0.0; nimp=0
        for n in sorted(todo,key=lambda n:-sum(g.path_cost(p) for p in g.routes.get(n,[]))):
            old=g.routes.get(n,[]); oc=sum(g.path_cost(p) for p in old)
            out,_=route_batch([n],True,WIN)
            if out[n] and sum(g.path_cost(p) for p in out[n])<oc-1e-6:
                gain+=oc-sum(g.path_cost(p) for p in out[n]); nimp+=1; g.set_route(n,out[n])
        print(f'improve pass {ip}: nets improved {nimp}, cost gain {gain:.0f}, {time.time()-t0:.0f} s',flush=True)
        if nimp==0: break
print('UNROUTED',len(left),[nets[n] for n in left],'total',round(time.time()-T0),'s',flush=True)
vias=sum(g.path_vias(p) for n in todo for p in g.routes.get(n,[])); cells=sum(len(p) for n in todo for p in g.routes.get(n,[]))
print('routed vias',vias,'cells',cells,flush=True)
g.write_out(dst)
open(dst+'.nets','w',encoding='utf-8').write('\n'.join(nets[n] for n in todo)+'\n')

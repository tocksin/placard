"""mroute3.py in out : grid router for the main board, v3 (C A* core, own-net joining, negotiated congestion, improvement passes).
F.Cu horizontal / B.Cu vertical preferred, 90-degree moves only. All existing copper is fixed; open nets are joined group by group.
env: DIAG=1 (45-degree moves)  NETS=a,b (only these nets)  ITERS=30  WIN=40 (mm around the net; full board on failure)  VIA=120 (via cost in cells)
     AGAINST=3 (wrong-way cost)  BEND=2  RING=8 (extra cost inside the net's own clearance ring: join, don't shadow)
     MARGIN=0.005  IMPROVE=2 (re-route-alone passes)  PRES0=1 PRESF=1.5  LAZY=1
     BASE=<file> PROT=a,b : soft mode (copper added after BASE for non-protected nets is soft, CROSSES printed)
     DROPCONFLICT=1 : drop routes still in conflict at the end"""
import sys, math, uuid, time, os, ctypes
import numpy as np
TOOLS=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,TOOLS)
from board import *
from shapely.geometry import LineString, Point, Polygon
from scipy.ndimage import distance_transform_edt
E=os.environ.get
G=0.125; W=0.3; CLR=0.25; VD=0.8; VDR=0.4; EDGE=__import__("rules").EDGE; M=float(E('MARGIN','0.005'))
VIA_COST=float(E('VIA','120')); AGAINST=float(E('AGAINST','3')); BEND=float(E('BEND','2')); RING=float(E('RING','8'))
DIAG=int(E('DIAG','0')); ITERS=int(E('ITERS','30')); WIN=float(E('WIN','40')); IMPROVE=int(E('IMPROVE','2')); LAZY=E('LAZY','1')=='1'
PRES=float(E('PRES0','1.0')); PRESF=float(E('PRESF','1.5')); PRESMAX=float(E('PRESMAX','30')); FULLEVERY=int(E('FULLEVERY','4'))
LAY=['F.Cu','B.Cu']
lib=ctypes.CDLL((os.path.join(TOOLS,'win','astar.dll') if os.name=='nt' else os.path.join(TOOLS,'astar.so')))
lib.astar.restype=ctypes.c_int
src,dst=sys.argv[1:3]
b,nets,fps,pads,edges=load(src); nid={v:k for k,v in nets.items()}
bp=Polygon(outline(edges)); x0,y0,x1,y1=bp.bounds
ox=math.floor(x0)-1; oy=math.floor(y0)-1
nx=int((x1-ox)/G)+16; ny=int((y1-oy)/G)+16
print('grid',nx,ny,flush=True)
def raster(geom):
    a,bb,c,d=geom.bounds
    i0=max(0,int((a-ox)/G)-1); i1=min(nx,int((c-ox)/G)+2); j0=max(0,int((bb-oy)/G)-1); j1=min(ny,int((d-oy)/G)+2)
    if i1<=i0 or j1<=j0: return j0,i0,np.zeros((0,0),bool)
    import shapely
    xs=ox+np.arange(i0,i1)*G; ys=oy+np.arange(j0,j1)*G
    gx,gy=np.meshgrid(xs,ys); shapely.prepare(geom)
    return j0,i0,shapely.contains_xy(geom,gx,gy)
SOFT=E('BASE'); PROTN=set(E('PROT','').split(','))
nseg_old=nvia_old=None
if SOFT:
    _bt=open(SOFT).read(); _cut=len(_bt.rstrip())-2
    _tail=parse('(kicad_pcb '+open(src).read()[_cut:])
    nseg_old=len(find(b,'segment'))-len(find(_tail,'segment')); nvia_old=len(find(b,'via'))-len(find(_tail,'via'))
softitems=[]; items=[]
for p in pads:
    if p['kind']=='np_thru_hole': continue
    lay=set(LAY) if '*.Cu' in p['layers'] else {l for l in p['layers'] if l in LAY}
    items.append((p['net'] or -1,lay,pad_poly(p),('pad',None)))
for si,s in enumerate(find(b,'segment')):
    L=one(s,'layer')[1]
    if L not in LAY: continue
    a=tuple(map(float,one(s,'start')[1:3])); e=tuple(map(float,one(s,'end')[1:3])); w=float(one(s,'width')[1])
    it=(int(one(s,'net')[1]),{L},LineString([a,e]).buffer(w/2,8),('seg',si))
    (softitems if (SOFT and si>=nseg_old and nets[it[0]] not in PROTN) else items).append(it)
for vi,v in enumerate(find(b,'via')):
    x,y=map(float,one(v,'at')[1:3]); it=(int(one(v,'net')[1]),set(LAY),Point(x,y).buffer(float(one(v,'size')[1])/2,16),('via',vi))
    (softitems if (SOFT and vi>=nvia_old and nets[it[0]] not in PROTN) else items).append(it)
tdz=[]
for z in find(b,'zone'):
    L=one(z,'layer')
    if not L or L[1] not in LAY: continue
    pts=[tuple(map(float,q[1:3])) for q in find(one(one(z,'polygon'),'pts'),'xy')]
    if len(pts)>=3: tdz.append((int(one(z,'net')[1]),{L[1]},Polygon(pts).buffer(0),('zone',None)))
print('items',len(items),'soft',len(softitems),flush=True)
own_t={L:np.zeros((ny,nx),np.int32) for L in LAY}; mul_t={L:np.zeros((ny,nx),bool) for L in LAY}
own_v=np.zeros((ny,nx),np.int32); mul_v=np.zeros((ny,nx),bool)
cop={L:np.zeros((ny,nx),np.int32) for L in LAY}
def stamp(own,mul,j0,i0,m,n):
    if m.size==0: return
    sl=(slice(j0,j0+m.shape[0]),slice(i0,i0+m.shape[1])); o=own[sl]; mu=mul[sl]
    mu|=m&(o!=0)&(o!=n); o[m&(o==0)]=n
pad_t={L:np.zeros((ny,nx),bool) for L in LAY}; pad_v=np.zeros((ny,nx),bool)
infl={}   # item index -> (inflated track geom, inflated via geom)
def add_item(n,lay,g,key,idx=None):
    gt=g.buffer(CLR+W/2+M,8); gv=g.buffer(CLR+VD/2+M,8)
    if idx is not None: infl[idx]=(gt,gv)
    jt=raster(gt); jv=raster(gv); jc=raster(g)
    for L in lay:
        stamp(own_t[L],mul_t[L],*jt,n)
        if key[0] in ('pad','zone'):
            j0,i0,m=jt
            if m.size: pad_t[L][j0:j0+m.shape[0],i0:i0+m.shape[1]]|=m
            j0,i0,m=jv
            if m.size: pad_v[j0:j0+m.shape[0],i0:i0+m.shape[1]]|=m
        j0,i0,m=jc
        if m.size:
            sl=(slice(j0,j0+m.shape[0]),slice(i0,i0+m.shape[1])); c=cop[L][sl]; c[m]=n
    stamp(own_v,mul_v,*jv,n)
t=time.time()
for idx,it in enumerate(items): add_item(*it,idx=idx)
for it in tdz: add_item(*it)
print('rasterised',round(time.time()-t,1),'s',flush=True)
j0,i0,m=raster(bp.buffer(-(EDGE+W/2+M),join_style=2)); edge_t=np.ones((ny,nx),bool); edge_t[j0:j0+m.shape[0],i0:i0+m.shape[1]]&=~m
j0,i0,m=raster(bp.buffer(-(EDGE+VD/2+M),join_style=2)); edge_v=np.ones((ny,nx),bool); edge_v[j0:j0+m.shape[0],i0:i0+m.shape[1]]&=~m
for _g in __import__('rules').hole_edge_keepouts(pads,bp,CLR):   # nothing between a mounting hole and the board edge
    for _r,_arr in ((W/2+M,edge_t),(VD/2+M,edge_v)):
        _gg=_g.buffer(_r,join_style=2).intersection(bp)
        if _gg.is_empty: continue
        j0,i0,m=raster(_gg); _arr[j0:j0+m.shape[0],i0:i0+m.shape[1]]|=m
for p in pads:
    if p['kind']=='np_thru_hole':
        for r,arr in ((p['drill']/2+0.25+W/2+M,edge_t),(p['drill']/2+0.25+VD/2+M,edge_v)):
            j0,i0,m=raster(Point(p['x'],p['y']).buffer(r,16)); arr[j0:j0+m.shape[0],i0:i0+m.shape[1]]|=m
FX0,FX1,FY0,FY1=233.6,268.4,125.6,133.6   # J8 pad field: vertical moves only, no vias
XX=ox+np.arange(nx)*G; YY=oy+np.arange(ny)*G
field=np.zeros((ny,nx),np.uint8); field[np.ix_((YY>FY0)&(YY<FY1),(XX>FX0)&(XX<FX1))]=1
edge_v|=field.astype(bool)
def groups(n,with_keys=False):
    its=[(lay,g,k,i) for i,it in enumerate(items) if it is not None and it[0]==n for (nn,lay,g,k) in [it]]
    par=list(range(len(its)))
    def f(i):
        while par[i]!=i: par[i]=par[par[i]]; i=par[i]
        return i
    for i in range(len(its)):
        for j in range(i+1,len(its)):
            if its[i][0]&its[j][0] and its[i][1].intersects(its[j][1]): par[f(i)]=f(j)
    gr={}
    for i in range(len(its)): gr.setdefault(f(i),[]).append(its[i] if with_keys else its[i][:2])
    return list(gr.values())
def gmask(group):
    out={L:np.zeros((ny,nx),bool) for L in LAY}
    for lay,g in group:
        j0,i0,m=raster(g)
        for L in lay:
            if m.size: out[L][j0:j0+m.shape[0],i0:i0+m.shape[1]]|=m
    return out
# occupancy of new routes (track-inflation count per cell) and history
occ_t={L:np.zeros((ny,nx),np.int16) for L in LAY}; occ_v=np.zeros((ny,nx),np.int16)
hist={L:np.zeros((ny,nx),np.float32) for L in LAY}; hist_v=np.zeros((ny,nx),np.float32)
softmask={L:np.zeros((ny,nx),np.int32) for L in LAY}
for n,lay,g,_k in softitems:
    jt=raster(g.buffer(CLR+W/2+M,8)); jv=raster(g.buffer(CLR+VD/2+M,8))
    for L in lay:
        j0,i0,m=jt
        if m.size: sl=(slice(j0,j0+m.shape[0]),slice(i0,i0+m.shape[1])); occ_t[L][sl]+=m; sm_=softmask[L][sl]; sm_[m]=n
    j0,i0,m=jv
    if m.size: occ_v[j0:j0+m.shape[0],i0:i0+m.shape[1]]+=m
routes={}; stamps={}
def path_geoms(path):
    pts=[(LAY[l],ox+ix*G,oy+iy*G) for l,iy,ix in path]; g=[]
    for k in range(1,len(pts)):
        if pts[k][0]!=pts[k-1][0]: g.append((set(LAY),Point(pts[k][1],pts[k][2]).buffer(VD/2,16)))
    runs=[]; cur=[pts[0]]
    for p in pts[1:]:
        if p[0]==cur[-1][0]: cur.append(p)
        else: runs.append(cur); cur=[p]
    runs.append(cur)
    for rr in runs:
        if len(rr)>=2: g.append(({rr[0][0]},LineString([(x,y) for _,x,y in rr]).buffer(W/2,8)))
    return g
def path_stamps(path):
    st=[]
    for lay,g in path_geoms(path):
        jt=raster(g.buffer(CLR+W/2+M,8)); jv=raster(g.buffer(CLR+VD/2+M,8))
        for L in lay: st.append(('t',L,*jt))
        st.append(('v',None,*jv))
    return st
def apply_stamps(st,sign):
    for kind,L,j0,i0,m in st:
        sl=(slice(j0,j0+m.shape[0]),slice(i0,i0+m.shape[1]))
        if kind=='t': occ_t[L][sl]+=sign*m
        else: occ_v[sl]+=sign*m
def path_cost(path):
    c=0.0
    for i in range(1,len(path)):
        l,iy,ix=path[i]; pl,py,px=path[i-1]
        if l!=pl: c+=VIA_COST
        else:
            dx=ix-px; dy=iy-py
            if dx and dy: c+=1.41421356*(1+AGAINST)/2
            else: c+=(1.0 if (dx and l==0) or (not dx and l==1) else AGAINST)
            if i>1 and path[i-2][0]==l and (py-path[i-2][1],px-path[i-2][2])!=(iy-py,ix-px): c+=BEND
    return c
def c_u8(a): return a.ctypes.data_as(ctypes.POINTER(ctypes.c_uint8))
def c_f32(a): return a.ctypes.data_as(ctypes.POINTER(ctypes.c_float))
def astar(srcm,goalm,bt,bv,ct,cvia,win):
    wx0,wx1,wy0,wy1=win
    gm=np.stack([goalm[L] for L in LAY]); sm=np.stack([srcm[L] for L in LAY])
    H=np.full((ny,nx),1e9,np.float32)
    sub=~gm.any(0)[wy0:wy1,wx0:wx1]
    H[wy0:wy1,wx0:wx1]=distance_transform_edt(sub) if sub.any() else 0
    btc=np.ascontiguousarray(np.stack(bt).astype(np.uint8)); bvc=np.ascontiguousarray(bv.astype(np.uint8))
    ctc=np.ascontiguousarray(np.stack(ct).astype(np.float32)); cvc=np.ascontiguousarray(cvia.astype(np.float32))
    smc=np.ascontiguousarray(sm.astype(np.uint8)); gmc=np.ascontiguousarray(gm.astype(np.uint8))
    maxlen=400000; out=np.zeros(3*maxlen,np.int32); ne=ctypes.c_int64(0)
    n=lib.astar(int(nx),int(ny),int(wx0),int(wx1),int(wy0),int(wy1),c_u8(btc),c_u8(bvc),c_f32(ctc),c_f32(cvc),c_f32(H),c_u8(smc),c_u8(gmc),
                ctypes.c_float(AGAINST),ctypes.c_float(BEND),c_u8(field),out.ctypes.data_as(ctypes.POINTER(ctypes.c_int32)),int(maxlen),ctypes.byref(ne),int(DIAG))
    if n==0: return None,ne.value
    p=out[:3*n].reshape(n,3)[::-1]
    return [(int(l),int(iy),int(ix)) for l,iy,ix in p],ne.value
def window(masks,pad_mm):
    ys,xs=np.nonzero(np.logical_or.reduce([m[L] for m in masks for L in LAY]))
    pad=int(pad_mm/G)
    return max(0,xs.min()-pad),min(nx,xs.max()+pad+1),max(0,ys.min()-pad),min(ny,ys.max()+pad+1)
SOFTC=float(E('SOFTC','40'))
def route_net(n,hard=False,rip=None,lock=None):
    """join all groups of net n; hard=True: cells occupied by other new routes are blocked (improvement mode);
    rip=(rip_t list, rip_v): fixed copper of rippable nets costs SOFTC per cell instead of blocking"""
    bt=[(mul_t[L]|((own_t[L]!=0)&(own_t[L]!=n))|edge_t) for L in LAY]
    bv=mul_v|((own_v!=0)&(own_v!=n))|edge_v
    if hard:
        bt=[bt[l]|(occ_t[L]>0) for l,L in enumerate(LAY)]; bv=bv|(occ_v>0)
    if rip:
        bt=[bt[l]&~rip[0][l] for l in range(2)]; bv=bv&~rip[1]
    if lock:
        bt=[bt[l]|lock[0][l] for l in range(2)]; bv=bv|lock[1]
    ring=[((own_t[L]==n)&(cop[L]!=n)).astype(np.float32) for L in LAY]   # own clearance ring: join, don't shadow
    gr=[gmask(g) for g in groups0[n]]
    paths=[]
    while len(gr)>1:
        gr.sort(key=lambda m:m['F.Cu'].sum()+m['B.Cu'].sum())
        a=gr[0]; rest={L:np.logical_or.reduce([g[L] for g in gr[1:]]) for L in LAY}
        for L in LAY: rest[L]&=~a[L]
        ct=[1.0+hist[L]+PRES*occ_t[L]+RING*ring[l] for l,L in enumerate(LAY)]
        cvia=VIA_COST*(1.0+hist_v+PRES*occ_v)
        if rip:
            ct=[ct[l]+SOFTC*rip[0][l] for l in range(2)]; cvia=cvia+VIA_COST*SOFTC*rip[1]
        path=None
        for pad_mm in (WIN,1e9):
            path,ne=astar(a,rest,bt,bv,ct,cvia,window([a,rest],pad_mm))
            if path or pad_mm>=1e9: break
        if path is None or len(path)<2: return None
        paths.append(path)
        l,iy,ix=path[-1]
        pm={L:np.zeros((ny,nx),bool) for L in LAY}
        for (pl,py,px) in path: pm[LAY[pl]][py,px]=True
        hit=[k for k in range(1,len(gr)) if gr[k][LAY[l]][iy,ix]]
        k=hit[0]
        merged={L:a[L]|gr[k][L]|pm[L] for L in LAY}
        for i in range(1,len(path)):
            if path[i][0]!=path[i-1][0]: merged['F.Cu'][path[i][1],path[i][2]]=merged['B.Cu'][path[i][1],path[i][2]]=True
        gr=[merged]+[g for j,g in enumerate(gr) if j not in (0,k)]
        for kind,L,j0,i0,m in path_stamps(path):   # the new path's own ring
            if kind=='t':
                sl=(slice(j0,j0+m.shape[0]),slice(i0,i0+m.shape[1])); r=ring[LAY.index(L)][sl]; r[m&~pm[L][sl]]=1.0
    return paths
def overlaps(n):
    c=0; apply_stamps(stamps.get(n,[]),-1)
    for path in routes.get(n,[]):
        for i,(l,iy,ix) in enumerate(path):
            if cop[LAY[l]][iy,ix]==n: continue   # on own fixed copper (pad/track): not a conflict
            if occ_t[LAY[l]][iy,ix]>0: c+=1; hist[LAY[l]][iy,ix]+=1
            if i and path[i-1][0]!=l and occ_v[iy,ix]>0: c+=1; hist_v[iy,ix]+=1
    apply_stamps(stamps.get(n,[]),1)
    return c
todo=[]; groups0={}
NETS=E('NETS')
for n,name in nets.items():
    if not n or name.startswith('unconnected-') or name in('GND','+5V'): continue
    if NETS and name not in NETS.split(','): continue
    gr=groups(n)
    if len(gr)>1: todo.append(n); groups0[n]=gr
def span(n):
    ys,xs=np.nonzero(np.logical_or.reduce([gmask(g)[L] for g in groups0[n] for L in LAY]))
    return (xs.max()-xs.min())+(ys.max()-ys.min())
todo.sort(key=span)   # short nets first
print('open nets',len(todo),[nets[n] for n in todo],flush=True)
def set_route(n,p):
    apply_stamps(stamps.get(n,[]),-1)
    routes[n]=p or []; stamps[n]=[s for path in routes[n] for s in path_stamps(path)]
    apply_stamps(stamps[n],1)
def write_out(outpath,fails):
    added_s=[]; added_v=[]
    for n in todo:
        for path in routes.get(n,[]):
            pts=[(LAY[l],ox+ix*G,oy+iy*G) for l,iy,ix in path]
            for k in range(1,len(pts)):
                if pts[k][0]!=pts[k-1][0]: added_v.append((n,pts[k][1],pts[k][2]))
            runs=[]; cur=[pts[0]]
            for p in pts[1:]:
                if p[0]==cur[-1][0]: cur.append(p)
                else: runs.append(cur); cur=[p]
            runs.append(cur)
            for rr in runs:
                if len(rr)<2: continue
                c=[(x,y) for _,x,y in rr]; cc=[c[0]]
                for i in range(1,len(c)-1):
                    if (round(c[i][0]-c[i-1][0],4),round(c[i][1]-c[i-1][1],4))!=(round(c[i+1][0]-c[i][0],4),round(c[i+1][1]-c[i][1],4)): cc.append(c[i])
                cc.append(c[-1])
                for a1,a2 in zip(cc,cc[1:]): added_s.append((n,rr[0][0],a1,a2))
    txt=open(src).read(); out=[]
    if removed_s or removed_v:
        import re
        for kind,rem in (('segment',removed_s),('via',removed_v)):
            ms=list(re.finditer(r'\n\t\('+kind+r'\n(?:.*\n)*?\t\)',txt))
            for i in sorted(rem,reverse=True):
                m=ms[i]; txt=txt[:m.start()]+txt[m.end():]
    for n,L,a,e in added_s:
        out.append(f'\t(segment\n\t\t(start {a[0]:.4f} {a[1]:.4f})\n\t\t(end {e[0]:.4f} {e[1]:.4f})\n\t\t(width {W})\n\t\t(layer "{L}")\n\t\t(net {n})\n\t\t(uuid "{uuid.uuid4()}")\n\t)')
    for n,x,y in added_v:
        out.append(f'\t(via\n\t\t(at {x:.4f} {y:.4f})\n\t\t(size {VD})\n\t\t(drill {VDR})\n\t\t(layers "F.Cu" "B.Cu")\n\t\t(net {n})\n\t\t(uuid "{uuid.uuid4()}")\n\t)')
    i=txt.rstrip().rfind(')')
    open(outpath,"w").write(txt[:i].rstrip('\n')+'\n'+'\n'.join(out)+'\n)\n')
    print('FAILS',[nets[n] for n in fails],'segments',len(added_s),'vias',len(added_v),flush=True)
removed_s=set(); removed_v=set()
NORIP={nid.get('GND'),nid.get('+5V')}|{nid[x] for x in PROTN if x in nid}
RIPS=int(E('RIPS','4')); STALL=int(E('STALL','6')); RIPMAX=int(E('RIPMAX','3')); RIPROUNDS=int(E('RIPROUNDS','400'))
def reraster(r):
    for L in LAY:
        own_t[L][own_t[L]==r]=0; cop[L][cop[L]==r]=0
    own_v[own_v==r]=0
    for idx,it in enumerate(items):
        if it is not None and it[0]==r: add_item(*it,idx=idx)
def drop_item(idx):
    n,lay,g,key=items[idx]; items[idx]=None
    if key[0]=='seg': removed_s.add(key[1])
    elif key[0]=='via': removed_v.add(key[1])
def rip_masks(n):
    """fixed copper of rippable nets (not n, not protected, not pads)"""
    rip_t=[]
    for L in LAY:
        o=own_t[L]; r=(o>0)&(o!=n)&~mul_t[L]&~pad_t[L]
        for m in NORIP:
            if m: r&=(o!=m)
        rip_t.append(r)
    r=(own_v>0)&(own_v!=n)&~mul_v&~pad_v
    for m in NORIP:
        if m: r&=(own_v!=m)
    return rip_t,r
def rip_fixed(n,paths,rip_t,rip_v):
    """remove the fixed copper pieces that the paths of n cross; their nets become routable. returns ripped nets"""
    crossed={}
    for path in paths:
        for i,(l,iy,ix) in enumerate(path):
            if rip_t[l][iy,ix]:
                m=int(own_t[LAY[l]][iy,ix]); crossed.setdefault(m,set()).add((LAY[l],ox+ix*G,oy+iy*G,'t'))
            if i and path[i-1][0]!=l and rip_v[iy,ix]:
                m=int(own_v[iy,ix]); crossed.setdefault(m,set()).add((None,ox+ix*G,oy+iy*G,'v'))
    ripped=set()
    for m,cells in crossed.items():
        if m<=0: continue
        hit=set()
        for idx,it in enumerate(items):
            if it is None or it[0]!=m or it[3][0]=='pad': continue
            gt,gv=infl[idx]
            for L,x,y,kind in cells:
                if (kind=='t' and L in it[1] and gt.contains(Point(x,y))) or (kind=='v' and gv.contains(Point(x,y))): hit.add(idx); break
        for idx in hit: drop_item(idx)
        for comp in groups(m,with_keys=True):
            if not any(k[0]=='pad' for _,_,k,_ in comp):
                for _,_,_,idx in comp: drop_item(idx)
        reraster(m)
        gr=groups(m)
        if len(gr)>1:
            groups0[m]=gr
            if m not in todo: todo.append(m)
            ripped.add(m)
        print('  rip:',nets[n],'crosses fixed',nets[m],'-> removed',len(hit),'pieces; groups',len(gr),flush=True)
    return ripped
def crossed_new(n,paths):
    """new routes of other nets whose footprint the paths of n run through"""
    cells={L:set() for L in LAY}; vcells=set()
    for path in paths:
        for i,(l,iy,ix) in enumerate(path):
            if occ_t[LAY[l]][iy,ix]>0: cells[LAY[l]].add((iy,ix))
            if i and path[i-1][0]!=l and occ_v[iy,ix]>0: vcells.add((iy,ix))
    out=set()
    for m in todo:
        if m==n or not routes.get(m): continue
        for k,L,j0,i0,mm in stamps.get(m,[]):
            cs=cells[L] if k=='t' else vcells
            if any(j0<=iy<j0+mm.shape[0] and i0<=ix<i0+mm.shape[1] and mm[iy-j0,ix-i0] for iy,ix in cs): out.add(m); break
    return out
def ripretry():
    """rip-up and retry: conflicted nets are cleared, then each is routed without overlaps; a net that cannot be routed
    cuts through the cheapest neighbors (new routes or rippable fixed copper), which are cleared and queued again.
    A net ripped RIPMAX times is locked and never ripped again."""
    global PRES
    PRES=0.0; ripcount={}
    queue=sorted([n for n in todo if overlaps(n)>0 or not routes.get(n)],key=lambda n:-overlaps(n))
    for n in queue: set_route(n,[])
    print('rip-retry: start with',len(queue),'nets to place',flush=True)
    rounds=0
    while queue and rounds<RIPROUNDS:
        n=queue.pop(0); rounds+=1
        apply_stamps(stamps.get(n,[]),-1); stamps[n]=[]
        p=route_net(n,hard=True)
        if p: set_route(n,p); continue
        locked=[m for m in todo if m!=n and routes.get(m) and ripcount.get(m,0)>=RIPMAX]
        lock_t=[np.zeros((ny,nx),bool) for L in LAY]; lock_v=np.zeros((ny,nx),bool)
        for m in locked:
            for k,L,j0,i0,mm in stamps.get(m,[]):
                if k=='t': lock_t[LAY.index(L)][j0:j0+mm.shape[0],i0:i0+mm.shape[1]]|=mm
                else: lock_v[j0:j0+mm.shape[0],i0:i0+mm.shape[1]]|=mm
        rip_t,rip_v=rip_masks(n)
        soft_t=[(rip_t[l]|(occ_t[L]>0))&~lock_t[l] for l,L in enumerate(LAY)]; soft_v=(rip_v|(occ_v>0))&~lock_v
        p=route_net(n,hard=False,rip=(soft_t,soft_v),lock=(lock_t,lock_v))
        if not p:
            print('  rip-retry: no path at all for',nets[n],flush=True); set_route(n,[]); continue
        cn=crossed_new(n,p)
        for m in cn:
            set_route(m,[]); ripcount[m]=ripcount.get(m,0)+1
            if m not in queue: queue.append(m)
        rf=rip_fixed(n,p,rip_t,rip_v)
        for m in rf:
            if m not in queue: queue.append(m)
        set_route(n,p)
        print('  rip-retry',rounds,nets[n],'rips',[nets[m] for m in cn],'fixed',[nets[m] for m in rf],'queue',len(queue),flush=True)
    left=[n for n in todo if not routes.get(n)]
    print('rip-retry done after',rounds,'rounds; unrouted',[nets[n] for n in left],flush=True)
    return left
fails=set(); conflicted=set(todo); best=None; noimp=0; it=0
while it<ITERS:
    t0=time.time(); fails=set()
    for n in todo:
        if LAZY and it and (it%FULLEVERY) and n not in conflicted: continue
        apply_stamps(stamps.get(n,[]),-1); stamps[n]=[]
        p=route_net(n)
        if p is None: fails.add(n)
        set_route(n,p)
    ov={n:overlaps(n) for n in todo}; tot=sum(ov.values()); conflicted={n for n,c in ov.items() if c}|fails
    print('iter',it,'overlap cells',tot,'conflicted',len(conflicted),'fails',[nets[n] for n in fails],round(time.time()-t0),'s',flush=True)
    if best is None or (len(fails),tot)<best[0]: best=((len(fails),tot),{n:list(p) for n,p in routes.items()},set(fails)); noimp=0
    else: noimp+=1
    if tot==0 and not fails: break
    if noimp>=STALL: break
    it+=1; PRES=min(PRES*PRESF,PRESMAX)
if (len(fails),tot)>best[0]:
    print('restoring best iteration',best[0])
    for n in todo: set_route(n,best[1].get(n,[]))
    fails=best[2]
if tot>0 or fails:
    left=ripretry(); fails=set(left); tot=0
# improvement passes: re-route each net alone with everything else fixed, keep the cheaper result
if IMPROVE and not fails and tot==0:
    PRES=0.0
    for ip in range(IMPROVE):
        t0=time.time(); gain=0; nimp=0
        for n in sorted(todo,key=lambda n:-sum(path_cost(p) for p in routes[n])):
            old=routes[n]; oc=sum(path_cost(p) for p in old)
            apply_stamps(stamps.get(n,[]),-1); stamps[n]=[]
            p=route_net(n,hard=True)
            if p and sum(path_cost(q) for q in p)<oc-1e-6:
                gain+=oc-sum(path_cost(q) for q in p); nimp+=1; set_route(n,p)
            else: set_route(n,old)
        print('improve pass',ip,'nets improved',nimp,'cost gain',round(gain),round(time.time()-t0),'s',flush=True)
        if nimp==0: break
if SOFT:
    crossed=set()
    for n in todo:
        for path in routes.get(n,[]):
            for l,iy,ix in path:
                m=softmask[LAY[l]][iy,ix]
                if m and m!=n: crossed.add(nets[m])
    print('CROSSES',','.join(sorted(crossed)))
if E('DROPCONFLICT') and (tot>0 or fails):
    for n in conflicted|fails: set_route(n,[])
    print('dropped routes of',[nets[n] for n in conflicted|fails])
write_out(dst,fails)

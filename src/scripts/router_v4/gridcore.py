"""gridcore.py : shared grid machinery for the v4 router tools (rasterised board, C A* core, routes as cell paths,
stamps for occupancy, chain decomposition of existing copper, output writer). Built from mroute3.py (2026-10-31).
env: VIA (cells, default 120)  AGAINST (3)  BEND (2)  RING (8)  MARGIN (0.005)  DIAG (0)"""
import sys, math, uuid, time, os, ctypes, re, collections
import numpy as np
TOOLS=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,TOOLS)
from board import *
import rules
from shapely.geometry import LineString, Point, Polygon
from scipy.ndimage import distance_transform_edt, label
E=os.environ.get
G=0.125; W=0.3; CLR=0.25; VD=0.8; VDR=0.4; LAY=['F.Cu','B.Cu']
lib=ctypes.CDLL((os.path.join(TOOLS,'win','astar.dll') if os.name=='nt' else os.path.join(TOOLS,'astar.so'))); lib.astar.restype=ctypes.c_int
def c_u8(a): return a.ctypes.data_as(ctypes.POINTER(ctypes.c_uint8))
def c_f32(a): return a.ctypes.data_as(ctypes.POINTER(ctypes.c_float))

def _disk(r):
    k=int(math.ceil(r)); y,x=np.mgrid[-k:k+1,-k:k+1]; return (x*x+y*y)<=r*r+1e-9
class Grid:
    def __init__(self,src,base=None,scope=None,quiet=False):
        self.src=src; self.M=float(E('MARGIN','0.005')); M=self.M
        self.VIA_COST=float(E('VIA','120')); self.AGAINST=float(E('AGAINST','3')); self.BEND=float(E('BEND','2')); self.RING=float(E('RING','8'))
        self.DIAG=int(E('DIAG','0')); self.EDGE=rules.EDGE
        b,nets,fps,pads,edges=load(src); self.b=b; self.nets=nets; self.pads=pads; self.nid={v:k for k,v in nets.items()}
        bp=Polygon(outline(edges)); self.bp=bp; x0,y0,x1,y1=bp.bounds
        self.ox=math.floor(x0)-1; self.oy=math.floor(y0)-1
        self.nx=int((x1-self.ox)/G)+16; self.ny=int((y1-self.oy)/G)+16; nx,ny=self.nx,self.ny
        if not quiet: print('grid',nx,ny,flush=True)
        self.txt=open(src).read()
        # tail = copper added after base (same prefix)
        self.cut=None; nseg_old=nvia_old=10**9
        if not base and scope: nseg_old=nvia_old=0   # no base: all copper of the scope nets is re-routable
        if base:
            bt=open(base).read(); self.cut=len(bt.rstrip())-2
            tail=parse('(kicad_pcb '+self.txt[self.cut:])
            nseg_old=len(find(b,'segment'))-len(find(tail,'segment')); nvia_old=len(find(b,'via'))-len(find(tail,'via'))
        self.nseg_old=nseg_old; self.nvia_old=nvia_old
        segs=find(b,'segment'); vias=find(b,'via')
        tailnets={int(one(s,'net')[1]) for s in segs[nseg_old:]}|{int(one(v,'net')[1]) for v in vias[nvia_old:]}
        self.scope=set(scope) if scope is not None else tailnets
        if base and not self.txt.startswith(open(base).read()[:self.cut]): raise SystemExit('BASE is not a prefix of the input (fixed copper was changed): use NETS=@file instead')
        self.items=[]; self.tailseg=collections.defaultdict(list); self.tailvia=collections.defaultdict(list)
        for p in pads:
            if p['kind']=='np_thru_hole': continue
            lay=set(LAY) if '*.Cu' in p['layers'] else {l for l in p['layers'] if l in LAY}
            self.items.append((p['net'] or -1,lay,pad_poly(p),('pad',None)))
        for si,s in enumerate(segs):
            L=one(s,'layer')[1]
            if L not in LAY: continue
            a=tuple(map(float,one(s,'start')[1:3])); e=tuple(map(float,one(s,'end')[1:3])); w=float(one(s,'width')[1]); n=int(one(s,'net')[1])
            if si>=nseg_old and n in self.scope: self.tailseg[n].append((L,a,e,w,si))
            else: self.items.append((n,{L},LineString([a,e]).buffer(w/2,8),('seg',si)))
        for vi,v in enumerate(vias):
            x,y=map(float,one(v,'at')[1:3]); n=int(one(v,'net')[1]); d=float(one(v,'size')[1])
            if vi>=nvia_old and n in self.scope: self.tailvia[n].append(((x,y),d,vi))
            else: self.items.append((n,set(LAY),Point(x,y).buffer(d/2,16),('via',vi)))
        # off-grid tail copper (hand-routed, diagonal) stays fixed; only on-grid, axis-aligned copper becomes re-routable chains
        for n in list(self.tailseg)+list(self.tailvia):
            keep=[]
            for L,a,e,w,si in self.tailseg.get(n,[]):
                ca=self.cell(*a); ce=self.cell(*e)
                if ca is None or ce is None or (ca[0]!=ce[0] and ca[1]!=ce[1]) or abs(w-W)>1e-6: self.items.append((n,{L},LineString([a,e]).buffer(w/2,8),('seg',si)))
                else: keep.append((L,a,e,w,si))
            self.tailseg[n]=keep; keepv=[]
            for (x,y),d,vi in self.tailvia.get(n,[]):
                if self.cell(x,y) is None or abs(d-VD)>1e-6: self.items.append((n,set(LAY),Point(x,y).buffer(d/2,16),('via',vi)))
                else: keepv.append(((x,y),d,vi))
            self.tailvia[n]=keepv
        self.tail_idx={n:([si for *_,si in self.tailseg[n]],[vi for *_,vi in self.tailvia[n]]) for n in set(self.tailseg)|set(self.tailvia)}
        self.tdz=[]
        for z in find(b,'zone'):
            L=one(z,'layer')
            if not L or L[1] not in LAY: continue
            pts=[tuple(map(float,q[1:3])) for q in find(one(one(z,'polygon'),'pts'),'xy')]
            if len(pts)>=3: self.tdz.append((int(one(z,'net')[1]),{L[1]},Polygon(pts).buffer(0),('zone',None)))
        Z=lambda t=np.int32: np.zeros((ny,nx),t)
        self.own_t={L:Z() for L in LAY}; self.mul_t={L:Z(bool) for L in LAY}; self.own_v=Z(); self.mul_v=Z(bool)
        self.cop={L:Z() for L in LAY}; self.pad_t={L:Z(bool) for L in LAY}; self.pad_v=Z(bool); self.thru=Z(bool)
        t=time.time()
        for it in self.items: self.add_item(*it)
        for it in self.tdz: self.add_item(*it)
        if not quiet: print('rasterised',len(self.items),'items',round(time.time()-t,1),'s',flush=True)
        j0,i0,m=self.raster(bp.buffer(-(self.EDGE+W/2+M),join_style=2)); self.edge_t=np.ones((ny,nx),bool); self.edge_t[j0:j0+m.shape[0],i0:i0+m.shape[1]]&=~m
        j0,i0,m=self.raster(bp.buffer(-(self.EDGE+VD/2+M),join_style=2)); self.edge_v=np.ones((ny,nx),bool); self.edge_v[j0:j0+m.shape[0],i0:i0+m.shape[1]]&=~m
        for g in rules.hole_edge_keepouts(pads,bp,CLR):
            for r,arr in ((W/2+M,self.edge_t),(VD/2+M,self.edge_v)):
                gg=g.buffer(r,join_style=2).intersection(bp)
                if gg.is_empty: continue
                j0,i0,m=self.raster(gg); arr[j0:j0+m.shape[0],i0:i0+m.shape[1]]|=m
        for p in pads:
            if p['kind']=='np_thru_hole':
                for r,arr in ((p['drill']/2+rules.HOLECLR+W/2+M,self.edge_t),(p['drill']/2+rules.HOLECLR+VD/2+M,self.edge_v)):
                    j0,i0,m=self.raster(Point(p['x'],p['y']).buffer(r,16)); arr[j0:j0+m.shape[0],i0:i0+m.shape[1]]|=m
            elif p['kind']=='thru_hole' and nets.get(p['net']) in rules.PLANE_NETS and rules.THERMCLR>0:
                # inner-plane thermal spokes of a GND/+5V pad must not be cut by vias of other nets (DRC starved_thermal)
                j0,i0,m=self.raster(Point(p['x'],p['y']).buffer(rules.THERMCLR,16)); self.edge_v[j0:j0+m.shape[0],i0:i0+m.shape[1]]|=m
        FX0,FX1,FY0,FY1=233.6,268.4,125.6,133.6   # J8 pad field: vertical moves only, no vias
        XX=self.ox+np.arange(nx)*G; YY=self.oy+np.arange(ny)*G
        self.field=np.zeros((ny,nx),np.uint8); self.field[np.ix_((YY>FY0)&(YY<FY1),(XX>FX0)&(XX<FX1))]=1
        self.edge_v|=self.field.astype(bool)
        self.occ_t={L:Z(np.int16) for L in LAY}; self.occ_v=Z(np.int16)
        self.hist={L:Z(np.float32) for L in LAY}; self.hist_v=Z(np.float32)
        self.routes={}; self.stamps={}; self.PRES=0.0
        self.removed_s=set(); self.removed_v=set()
        # existing tail copper of scope nets -> cell paths (chains)
        self.unsnapped=set()
        for n in self.scope:
            paths=self.paths_from_tail(n)
            if paths is None: self.unsnapped.add(n); paths=[]
            self.set_route(n,paths)
        if self.unsnapped and not quiet: print('nets with off-grid tail copper (kept fixed):',[nets[n] for n in self.unsnapped])
        for n in self.unsnapped:   # keep it as fixed copper
            for L,a,e,w,si in self.tailseg[n]: self.add_item(n,{L},LineString([a,e]).buffer(w/2,8),('seg',si))
            for (x,y),d,vi in self.tailvia[n]: self.add_item(n,set(LAY),Point(x,y).buffer(d/2,16),('via',vi))
            self.tailseg[n]=[]; self.tailvia[n]=[]
    # ---- rasterisation
    def raster(self,geom):
        a,bb,c,d=geom.bounds; nx,ny,ox,oy=self.nx,self.ny,self.ox,self.oy
        i0=max(0,int((a-ox)/G)-1); i1=min(nx,int((c-ox)/G)+2); j0=max(0,int((bb-oy)/G)-1); j1=min(ny,int((d-oy)/G)+2)
        if i1<=i0 or j1<=j0: return j0,i0,np.zeros((0,0),bool)
        import shapely
        xs=ox+np.arange(i0,i1)*G; ys=oy+np.arange(j0,j1)*G
        gx,gy=np.meshgrid(xs,ys); shapely.prepare(geom)
        return j0,i0,shapely.contains_xy(geom,gx,gy)
    @staticmethod
    def stamp(own,mul,j0,i0,m,n):
        if m.size==0: return
        sl=(slice(j0,j0+m.shape[0]),slice(i0,i0+m.shape[1])); o=own[sl]; mu=mul[sl]
        mu|=m&(o!=0)&(o!=n); o[m&(o==0)]=n
    def add_item(self,n,lay,g,key):
        M=self.M; gt=g.buffer(CLR+W/2+M,8); gv=g.buffer(CLR+VD/2+M,8)
        jt=self.raster(gt); jv=self.raster(gv); jc=self.raster(g)
        for L in lay:
            self.stamp(self.own_t[L],self.mul_t[L],*jt,n)
            if key[0] in ('pad','zone'):
                j0,i0,m=jt
                if m.size: self.pad_t[L][j0:j0+m.shape[0],i0:i0+m.shape[1]]|=m
                j0,i0,m=jv
                if m.size: self.pad_v[j0:j0+m.shape[0],i0:i0+m.shape[1]]|=m
            j0,i0,m=jc
            if m.size and key[0]!='zone':   # teardrop zones are obstacles, never a connection
                sl=(slice(j0,j0+m.shape[0]),slice(i0,i0+m.shape[1])); c=self.cop[L][sl]; c[m]=n
        if len(lay)==2 and key[0] in ('pad','via'):
            j0,i0,m=jc
            if m.size: self.thru[j0:j0+m.shape[0],i0:i0+m.shape[1]]|=m
        self.stamp(self.own_v,self.mul_v,*jv,n)
    def drop_item(self,idx):
        n,lay,g,key=self.items[idx]; self.items[idx]=None
        if key[0]=='seg': self.removed_s.add(key[1])
        elif key[0]=='via':
            self.removed_v.add(key[1])
            # the via no longer joins the layers: clear its thru cells, re-add the other through items there
            j0,i0,m=self.raster(g)
            if m.size:
                self.thru[j0:j0+m.shape[0],i0:i0+m.shape[1]]&=~m
                for it in self.items:
                    if it is not None and len(it[1])==2 and it[3][0] in ('pad','via') and it[2].intersects(g):
                        k0,l0,mm=self.raster(it[2])
                        if mm.size: self.thru[k0:k0+mm.shape[0],l0:l0+mm.shape[1]]|=mm
    def reraster(self,r):
        """re-rasterise net r's fixed copper after items were dropped (mul stays conservative)"""
        for L in LAY:
            self.own_t[L][self.own_t[L]==r]=0; self.cop[L][self.cop[L]==r]=0
        self.own_v[self.own_v==r]=0
        for it in self.items:
            if it is not None and it[0]==r: self.add_item(*it)
    def fixed_groups_geo(self,n):
        """connected groups of net n's fixed items (geometric), with item indices"""
        its=[(i,it[1],it[2],it[3]) for i,it in enumerate(self.items) if it is not None and it[0]==n]
        par=list(range(len(its)))
        def f(i):
            while par[i]!=i: par[i]=par[par[i]]; i=par[i]
            return i
        for i in range(len(its)):
            for j in range(i+1,len(its)):
                if its[i][1]&its[j][1] and its[i][2].intersects(its[j][2]): par[f(i)]=f(j)
        gr={}
        for i in range(len(its)): gr.setdefault(f(i),[]).append(its[i])
        return list(gr.values())
    # ---- cell <-> mm
    def cell(self,x,y):
        ix=(x-self.ox)/G; iy=(y-self.oy)/G
        if abs(ix-round(ix))>1e-3 or abs(iy-round(iy))>1e-3: return None
        return int(round(iy)),int(round(ix))
    def mm(self,iy,ix): return self.ox+ix*G,self.oy+iy*G
    # ---- paths
    def path_geoms(self,path):
        pts=[(LAY[l],*self.mm(iy,ix)) for l,iy,ix in path]; g=[]
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
    def path_stamps(self,path):
        st=[]; M=self.M
        for lay,g in self.path_geoms(path):
            jt=self.raster(g.buffer(CLR+W/2+M,8)); jv=self.raster(g.buffer(CLR+VD/2+M,8))
            for L in lay: st.append(('t',L,*jt))
            st.append(('v',None,*jv))
        return st
    def apply_stamps(self,st,sign):
        for kind,L,j0,i0,m in st:
            sl=(slice(j0,j0+m.shape[0]),slice(i0,i0+m.shape[1]))
            if kind=='t': self.occ_t[L][sl]+=sign*m
            else: self.occ_v[sl]+=sign*m
    def set_route(self,n,paths):
        self.apply_stamps(self.stamps.get(n,[]),-1)
        self.routes[n]=paths or []; self.stamps[n]=[s for path in self.routes[n] for s in self.path_stamps(path)]
        self.apply_stamps(self.stamps[n],1)
    def path_cost(self,path):
        c=0.0; A=self.AGAINST
        for i in range(1,len(path)):
            l,iy,ix=path[i]; pl,py,px=path[i-1]
            if l!=pl: c+=self.VIA_COST
            else:
                dx=ix-px; dy=iy-py
                if dx and dy: c+=1.41421356*(1+A)/2
                else: c+=(1.0 if (dx and l==0) or (not dx and l==1) else A)
                if i>1 and path[i-2][0]==l and (py-path[i-2][1],px-path[i-2][2])!=(iy-py,ix-px): c+=self.BEND
        return c
    def path_vias(self,path): return sum(1 for i in range(1,len(path)) if path[i][0]!=path[i-1][0])
    # ---- existing copper -> chains
    def paths_from_tail(self,n):
        """cell paths (chains between junctions / fixed own copper) of the net's tail copper; None if off grid"""
        adj=collections.defaultdict(set)
        for L,a,e,w,si in self.tailseg[n]:
            ca=self.cell(*a); ce=self.cell(*e)
            if ca is None or ce is None: return None
            l=LAY.index(L); (y0,x0),(y1,x1)=ca,ce
            if y0!=y1 and x0!=x1: return None
            if (y0,x0)==(y1,x1): continue
            steps=max(abs(y1-y0),abs(x1-x0)); dy=(y1-y0)//steps; dx=(x1-x0)//steps
            prev=(l,y0,x0)
            for k in range(1,steps+1):
                cur=(l,y0+dy*k,x0+dx*k); adj[prev].add(cur); adj[cur].add(prev); prev=cur
        for (x,y),d,vi in self.tailvia[n]:
            c=self.cell(x,y)
            if c is None: return None
            a=(0,*c); bb=(1,*c); adj[a].add(bb); adj[bb].add(a)
        if not adj: return []
        def terminal(node):
            l,iy,ix=node; return self.cop[LAY[l]][iy,ix]==n
        junction={v for v in adj if len(adj[v])!=2 or terminal(v)}
        paths=[]; used=set()
        def walk(start,nxt):
            path=[start,nxt]; prev=start; cur=nxt
            while cur not in junction:
                nb=[u for u in adj[cur] if u!=prev]
                if not nb: break
                prev,cur=cur,nb[0]; path.append(cur)
                if len(path)>500000: break
            return path
        for v in junction:
            for u in adj[v]:
                key=frozenset((v,u))
                if key in used: continue
                p=walk(v,u)
                for a,bb in zip(p,p[1:]): used.add(frozenset((a,bb)))
                paths.append(p)
        # pure cycles with no junction: floating copper, dropped
        return paths
    # ---- components of a net's copper (fixed + routes), per cell
    def components(self,n,skip=None):
        """label map per layer of the net's copper; skip = path whose cells are left out. returns (labels F, labels B, nlabels)"""
        masks=[(self.cop[L]==n) for L in LAY]; thru=self.thru.copy()
        cells=[np.zeros((self.ny,self.nx),bool) for _ in LAY]; vc=np.zeros((self.ny,self.nx),bool)
        for path in self.routes.get(n,[]):
            if path is skip: continue
            for i,(l,iy,ix) in enumerate(path):
                cells[l][iy,ix]=True
                if i and path[i-1][0]!=l: vc[iy,ix]=True
        from scipy.ndimage import binary_dilation
        if vc.any(): vd=binary_dilation(vc,_disk(VD/2/G)); thru|=vd
        for l in range(2):   # track cells undilated (8-connectivity joins only touching copper), via pads as disks
            masks[l]|=cells[l]
            if vc.any(): masks[l]|=vd
        self.last_copper=[m.copy() for m in masks]
        labs=[label(m,np.ones((3,3),bool))[0] for m in masks]; n0=labs[0].max(); labs[1]=np.where(labs[1]>0,labs[1]+n0,0)
        par=list(range(int(labs[1].max())+1))
        def f(i):
            while par[i]!=i: par[i]=par[par[i]]; i=par[i]
            return i
        both=thru&(labs[0]>0)&(labs[1]>0)
        for a,bb in zip(labs[0][both],labs[1][both]):
            ra,rb=f(int(a)),f(int(bb))
            if ra!=rb: par[rb]=ra
        lut=np.array([f(i) for i in range(len(par))],np.int32)
        return lut[labs[0]],lut[labs[1]]
    # ---- A*
    def astar(self,srcm,goalm,bt,bv,ct,cvia,win):
        wx0,wx1,wy0,wy1=win; nx,ny=self.nx,self.ny
        gm=np.stack([goalm[L] for L in LAY]); sm=np.stack([srcm[L] for L in LAY])
        H=np.full((ny,nx),1e9,np.float32)
        sub=~gm.any(0)[wy0:wy1,wx0:wx1]
        H[wy0:wy1,wx0:wx1]=distance_transform_edt(sub) if sub.any() else 0
        btc=np.ascontiguousarray(np.stack(bt).astype(np.uint8)); bvc=np.ascontiguousarray(bv.astype(np.uint8))
        ctc=np.ascontiguousarray(np.stack(ct).astype(np.float32)); cvc=np.ascontiguousarray(cvia.astype(np.float32))
        smc=np.ascontiguousarray(sm.astype(np.uint8)); gmc=np.ascontiguousarray(gm.astype(np.uint8))
        maxlen=400000; out=np.zeros(3*maxlen,np.int32); ne=ctypes.c_int64(0)
        k=lib.astar(int(nx),int(ny),int(wx0),int(wx1),int(wy0),int(wy1),c_u8(btc),c_u8(bvc),c_f32(ctc),c_f32(cvc),c_f32(H),c_u8(smc),c_u8(gmc),
                    ctypes.c_float(self.AGAINST),ctypes.c_float(self.BEND),c_u8(self.field),out.ctypes.data_as(ctypes.POINTER(ctypes.c_int32)),int(maxlen),ctypes.byref(ne),int(self.DIAG))
        if k==0: return None,ne.value
        p=out[:3*k].reshape(k,3)[::-1]
        return [(int(l),int(iy),int(ix)) for l,iy,ix in p],ne.value
    def window(self,masks,pad_mm):
        ys,xs=np.nonzero(np.logical_or.reduce([m[L] for m in masks for L in LAY]))
        pad=int(pad_mm/G)
        return max(0,xs.min()-pad),min(self.nx,xs.max()+pad+1),max(0,ys.min()-pad),min(self.ny,ys.max()+pad+1)
    def blocked(self,n,hard=True):
        bt=[(self.mul_t[L]|((self.own_t[L]!=0)&(self.own_t[L]!=n))|self.edge_t) for L in LAY]
        bv=self.mul_v|((self.own_v!=0)&(self.own_v!=n))|self.edge_v
        if hard: bt=[bt[l]|(self.occ_t[L]>0) for l,L in enumerate(LAY)]; bv=bv|(self.occ_v>0)
        return bt,bv
    def own_ring(self,n):
        """cells inside the net's own clearance ring but not on its copper (fixed + current routes)"""
        ring=[((self.own_t[L]==n)&(self.cop[L]!=n)) for L in LAY]
        for kind,L,j0,i0,m in self.stamps.get(n,[]):
            if kind=='t': ring[LAY.index(L)][j0:j0+m.shape[0],i0:i0+m.shape[1]]|=m
        for path in self.routes.get(n,[]):
            for l,iy,ix in path: ring[l][iy,ix]=False
        return [r.astype(np.float32) for r in ring]
    # ---- output
    def write_out(self,outpath,extra_nets=()):
        """input text minus removed fixed copper and minus the scope's old tail copper, plus all routes of scope nets"""
        added_s=[]; added_v=[]
        for n in list(self.scope)+list(extra_nets):
            for path in self.routes.get(n,[]):
                pts=[(LAY[l],*self.mm(iy,ix)) for l,iy,ix in path]
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
        added_v=sorted(set(added_v))
        txt=self.txt; rem_s=set(self.removed_s); rem_v=set(self.removed_v)
        if self.cut is not None and not rem_s and not rem_v:
            # base split: keep the tail blocks of nets outside the scope verbatim
            head=txt[:self.cut].rstrip('\n'); tail=txt[self.cut:]
            blocks=re.findall(r'\n\t\((?:segment|via)\n(?:.*\n)*?\t\)',tail)
            keep=[bl for bl in blocks if int(re.search(r'\(net (\d+)\)',bl).group(1)) not in self.scope or int(re.search(r'\(net (\d+)\)',bl).group(1)) in self.unsnapped]
            out=[bl.strip('\n') for bl in keep]
        else:
            for n in self.scope:
                if n in self.unsnapped: continue
                ss,vv=self.tail_idx.get(n,([],[]))
                rem_s.update(si for si in ss if si>=0); rem_v.update(vi for vi in vv if vi>=0)
            for kind,rem in (('segment',rem_s),('via',rem_v)):
                ms=list(re.finditer(r'\n\t\('+kind+r'\n(?:.*\n)*?\t\)',txt))
                for i in sorted(rem,reverse=True):
                    mm=ms[i]; txt=txt[:mm.start()]+txt[mm.end():]
            i=txt.rstrip().rfind(')'); head=txt[:i].rstrip('\n'); out=[]
        for n,L,a,e in added_s:
            out.append(f'\t(segment\n\t\t(start {a[0]:.4f} {a[1]:.4f})\n\t\t(end {e[0]:.4f} {e[1]:.4f})\n\t\t(width {W})\n\t\t(layer "{L}")\n\t\t(net {n})\n\t\t(uuid "{uuid.uuid4()}")\n\t)')
        for n,x,y in added_v:
            out.append(f'\t(via\n\t\t(at {x:.4f} {y:.4f})\n\t\t(size {VD})\n\t\t(drill {VDR})\n\t\t(layers "F.Cu" "B.Cu")\n\t\t(net {n})\n\t\t(uuid "{uuid.uuid4()}")\n\t)')
        open(outpath,'w').write(head+'\n'+'\n'.join(out)+'\n)\n')
        print('wrote',outpath,'segments',len(added_s),'vias',len(added_v),flush=True)

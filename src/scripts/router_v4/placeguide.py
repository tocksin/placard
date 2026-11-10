"""placeguide.py board.kicad_pcb MODE [args] : component placement guidance from the pads only (no routing, tracks ignored).

It scores a placement with what makes the router v4 work hard on this board (2 signal layers, F.Cu horizontal, B.Cu vertical,
inner planes GND / +5V, through-hole parts), and searches moves, rotations and swaps that lower the score.
The board file is never written to; MODE optimize writes a moved COPY with the signal tracks removed (a router bench).

Model (all from pads; GND / +5V go to the planes and are left out):
  - topology  : every net becomes its rectilinear minimum spanning tree (MST) of pads; each MST edge is one connection.
  - length    : sum of the Manhattan lengths of the MST edges (mm).
  - bends     : a connection whose pads differ by more than ALIGN in both x and y needs an L, and with layer discipline an L
                means one via; an aligned connection can be one straight track on its own layer with no via.
  - crossings : two connections of different nets that run the same way (both mostly horizontal, or both vertical) and swap
                order along their common span must cross on the same layer: one of them has to jog (vias). Counted in three
                classes: both aligned (a2), one aligned (a1), neither (a0). Bus pin-order inversions are the big source.
  - congestion: the board is binned at BIN mm. Capacity of a bin per direction = parallel tracks (TRACK + CLR pitch) that pass
                straight through it on its preferred layer, plus WW x the other layer, after pads (dilated by CLR + TRACK/2),
                NPTH holes, the 1 mm outline band and the mounting-hole bands are rasterised at RES mm. Demand = RUDY spread of
                each connection over its bounding box, split by direction. Overflow = demand above capacity (tracks).
  - vias      : expected vias = KB*bends + K2*a2 + K1*a1 + K0*a0 + KC*congestion exposure; the K values come from `fit`
                (least squares of the per-net via counts of a routed board against the per-net features).
  cost = length + VIAMM * expected vias + OVW * overflow * BIN   (VIAMM 15 mm = the router's via cost; all in mm)
  - budgets   : BUDGET=budgets.json (budgets.py) adds BUDW mm per mm that a pair's straight distance x DETOUR is over its budget.

Modes:
  report [OUT=dir]           metrics, problem lists (worst bus-order pairs, hottest bins, nets with most bends, budget pairs
                             that cannot be met), congestion heatmap PNG, JSON.
  fit [routed.kicad_pcb ..]  calibrate K values against the routed board(s) (default: the board itself); writes
                             placeguide_fit.json (read by the other modes through FIT=, default next to this script).
  sweep REF [OUT=dir]        cost of REF (with its decoupling caps) over every legal position in RAD mm at STEP mm and the
                             four rotations: heatmap PNG + best positions.
  moves [OUT=dir]            best single move / rotation of every movable part, ranked by gain.
  swaps [OUT=dir]            ranked position swaps of movable parts with the same footprint.
  optimize OUT=dir           greedy: apply the best legal move or swap, repeat (ROUNDS, MINGAIN), write the move list and
                             OUT/placed.kicad_pcb (copy, signal tracks removed).
  scratch OUT=dir            place every chip and passive from the netlist (only SCRATCHFIXED parts stay), then optimize.
  rules OUT=dir              Justin's rules: single-destination passives at their connector, chips outside-in on rows with
                             bus partners side by side, decap at pin 1 (CENTREW, CHALO, PHALO, ROWPITCH, ROUNDS, REFINEROTS).
  pinswap OUT=dir            pin swaps only (pinswap.py table: register / buffer bit pairs, SRAM address / data, ATF22V10C pins
                             within product-term limits): OUT/pinswaps.md + OUT/pinswapped.kicad_pcb (PSMIN, PSPASSES;
                             PSFIX=net,net: pins on these nets stay; mroute4.py PINSWAP=1 runs this mode before routing).
Env (scratch: SCRATCHFIXED regex of parts that keep their place, HALO=0.5 spacing in legalisation, GPITERS=25, ANCHORW,
     ICROTS=90,270 restricts parts with 8+ pads to those absolute rotations, in every mode)
     BIN=5 RES=0.1 TRACK=0.3 CLR=0.25 ALIGN=1.0 WW=0.25 VIAMM=15 OVW=2 MARGIN=1.0 (courtyard to outline) GAP=0 (courtyard gap)
     FIXED=regex of parts never moved (default connectors, holes, switches, relay, clock, jumpers, test points, net ties)
     FREE=refs,.. (movable despite FIXED)  ONLY=refs,.. (only these move)  DECAPR=12 (cap on GND/+5V joins the nearest IC)
     SNAP=0.635 (a rotated part's origin stays on this grid)  RAD=10 STEP=1.27 ROTS=0,90,180,270 KEEP=24 (candidates per part passed from the quick screen to the full model)  TOP=25  ROUNDS=30  MINGAIN=5  BUDGET=  DETOUR=1.15  BUDW=20
"""
import os, sys, re, math, json, collections, time, itertools
import numpy as np
TOOLS=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,TOOLS)
from sexpr import parse, find, one
from board import rot, outline
E=os.environ.get
BIN=float(E('BIN','5.0')); RES=float(E('RES','0.1')); TRACK=float(E('TRACK','0.3')); CLR=float(E('CLR','0.25'))
ALIGN=float(E('ALIGN','1.0')); WW=float(E('WW','0.25')); VIAMM=float(E('VIAMM','15')); OVW=float(E('OVW','2'))
MARGIN=float(E('MARGIN','1.0')); GAP=float(E('GAP','0')); DECAPR=float(E('DECAPR','12'))
EDGEBAND=float(E('EDGE','1.0')); STRIPS=int(E('STRIPS','5')); HALO=float(E('HALO','0.5'))
SNAP=float(E('SNAP','0.635')); PITCH=TRACK+CLR; GROW=CLR+TRACK/2
ICROTS={int(float(a))%360 for a in E('ICROTS','').split(',') if a}   # allowed absolute rotations of parts with 8+ pads (empty = any)
FIXED_RE=re.compile(E('FIXED',r'^(J|H|SW|K|X|JP|TP|NT|G|LOGO|REF)\d*$'))
FREE=set(x for x in E('FREE','').split(',') if x); ONLY=set(x for x in E('ONLY','').split(',') if x)
PLANES=set(E('PLANES','GND,+5V').split(','))
FITFILE=E('FIT',os.path.join(TOOLS,'placeguide_fit.json'))
DEFAULT_K={'KB':0.55,'K2':1.0,'K1':0.05,'K0':0.05,'KC':0.1,'KX':0.1}

def lin(v): return [float(t) for t in v]

# ------------------------------------------------------------------ board model
class Part:
    pass

def _gpts(g):
    pts=[]
    for k in ('start','end','mid','center'):
        o=one(g,k)
        if o: pts.append(tuple(lin(o[1:3])))
    if g[0]=='fp_circle':
        c=one(g,'center'); e=one(g,'end')
        if c and e:
            cx,cy=lin(c[1:3]); r=math.dist((cx,cy),lin(e[1:3])); pts+= [(cx-r,cy-r),(cx+r,cy+r)]
    pl=one(g,'pts')
    if pl: pts+=[tuple(lin(xy[1:3])) for xy in find(pl,'xy')]
    return pts

def bbox(pts):
    xs=[p[0] for p in pts]; ys=[p[1] for p in pts]; return (min(xs),min(ys),max(xs),max(ys))

class Board:
    def __init__(self,path):
        self.path=path; s=open(path,encoding='utf-8').read(); b=parse(s); self.tree=b
        self.netname={int(n[1]):n[2] for n in find(b,'net')}
        self.parts=[]; self.npth=[]
        for fp in find(b,'footprint'):
            P=Part(); P.lib=fp[1]
            P.ref=([p[2] for p in find(fp,'property') if p[1]=='Reference']+[t[2] for t in find(fp,'fp_text') if t[1]=='reference'])[0]
            at=one(fp,'at'); P.x,P.y=float(at[1]),float(at[2]); P.a=float(at[3]) if len(at)>3 else 0.0
            P.layer=one(fp,'layer')[1]
            P.pads=[]
            for p in find(fp,'pad'):
                pa=one(p,'at'); lx,ly=float(pa[1]),float(pa[2]); pang=float(pa[3]) if len(pa)>3 else 0.0
                sz=one(p,'size'); n=one(p,'net'); dr=one(p,'drill')
                drill=float([v for v in dr[1:] if not isinstance(v,list) and v!='oval'][0]) if dr else 0.0
                lay=one(p,'layers')[1:]
                P.pads.append(dict(num=p[1],kind=p[2],shape=p[3],lx=lx,ly=ly,rang=pang-P.a,w=float(sz[1]),h=float(sz[2]),
                    net=int(n[1]) if n else 0,drill=drill,olx=lx,oly=ly,
                    tht=p[2]=='thru_hole', smd_layer=('F' if 'F.Cu' in lay else 'B')))
            crt=[]; eco=[]
            for g in fp:
                if not (isinstance(g,list) and g and g[0] in ('fp_line','fp_rect','fp_poly','fp_circle','fp_arc')): continue
                L=one(g,'layer')
                if not L: continue
                if L[1] in ('F.CrtYd','B.CrtYd'): crt+=_gpts(g)
                elif L[1]=='Eco1.User': eco.append(bbox(_gpts(g)))
            if not crt:
                crt=[(p['lx']-p['w']/2-0.25,p['ly']-p['h']/2-0.25) for p in P.pads]+[(p['lx']+p['w']/2+0.25,p['ly']+p['h']/2+0.25) for p in P.pads]
            P.crt=bbox(crt) if crt else (-0.5,-0.5,0.5,0.5)
            P.eco=eco
            self.parts.append(P)
        self.byref={P.ref:i for i,P in enumerate(self.parts)}
        edges=[]
        for g in find(b,'gr_line')+find(b,'gr_arc')+find(b,'gr_rect'):
            if one(g,'layer')[1]!='Edge.Cuts': continue
            if g[0]=='gr_rect':
                x0,y0=lin(one(g,'start')[1:3]); x1,y1=lin(one(g,'end')[1:3])
                edges+= [[(x0,y0),(x1,y0)],[(x1,y0),(x1,y1)],[(x1,y1),(x0,y1)],[(x0,y1),(x0,y0)]]; continue
            edges.append([tuple(lin(one(g,k)[1:3])) for k in ('start','mid','end') if one(g,k)])
        self.outline=outline(edges)
        ox=[p[0] for p in self.outline]; oy=[p[1] for p in self.outline]
        self.bx0,self.by0,self.bx1,self.by1=min(ox),min(oy),max(ox),max(oy)
        # nets: (part, pad) lists, planes and single-pad nets out
        nl=collections.defaultdict(list)
        for i,P in enumerate(self.parts):
            for j,p in enumerate(P.pads):
                if p['kind']=='np_thru_hole' or not p['net']: continue
                nm=self.netname.get(p['net'],'')
                if nm in PLANES or nm.startswith('unconnected-'): continue
                nl[p['net']].append((i,j))
        self.nets={n:v for n,v in nl.items() if len(v)>=2}
        self.partnets=collections.defaultdict(set)
        for n,v in self.nets.items():
            for i,j in v: self.partnets[i].add(n)
        self._groups()

    def _groups(self):
        """movable groups: each movable part, with decoupling caps (2 pads on GND and +5V) riding along with the nearest IC"""
        pl={n for n,m in self.netname.items() if m in PLANES}
        def mov(P):
            if ONLY: return P.ref in ONLY
            return P.ref in FREE or not FIXED_RE.match(P.ref)
        ics=[i for i,P in enumerate(self.parts) if P.ref.startswith('U') and mov(P)]
        self.leader={}; self.members=collections.defaultdict(list)
        for i,P in enumerate(self.parts):
            if not mov(P): continue
            nets={p['net'] for p in P.pads}
            if P.ref.startswith('C') and len(P.pads)==2 and nets<=pl and len(nets)==2 and ics:
                k=min(ics,key=lambda u:math.dist((self.parts[u].x,self.parts[u].y),(P.x,P.y)))
                if math.dist((self.parts[k].x,self.parts[k].y),(P.x,P.y))<=DECAPR:
                    self.leader[i]=k; continue
        for i,P in enumerate(self.parts):
            if mov(P) and i not in self.leader: self.members[i]=[i]+[c for c,k in self.leader.items() if k==i]
        self.movable=sorted(self.members)

# ------------------------------------------------------------------ geometry of a state
def rbox(b,a):
    """local box b rotated by a (multiples of 90 exact; others: box of the rotated corners)"""
    pts=[rot(x,y,a) for x in (b[0],b[2]) for y in (b[1],b[3])]
    return bbox(pts)

class State:
    """positions/angles of every part; pad coordinates cached"""
    def __init__(self,B):
        self.B=B; self.x=np.array([P.x for P in B.parts]); self.y=np.array([P.y for P in B.parts]); self.a=np.array([P.a for P in B.parts])
        self.padxy=[None]*len(B.parts)
        for i in range(len(B.parts)): self._pads(i)
    def copy(self):
        s=State.__new__(State); s.B=self.B; s.x=self.x.copy(); s.y=self.y.copy(); s.a=self.a.copy(); s.padxy=list(self.padxy); return s
    def _pads(self,i):
        P=self.B.parts[i]; a=self.a[i]
        self.padxy[i]=[(self.x[i]+rot(p['lx'],p['ly'],a)[0],self.y[i]+rot(p['lx'],p['ly'],a)[1]) for p in P.pads]
    def pad(self,i,j): return self.padxy[i][j]
    def boxes(self,i):
        """absolute courtyard box and eco boxes of part i"""
        P=self.B.parts[i]; a=self.a[i]; x,y=self.x[i],self.y[i]
        c=rbox(P.crt,a); c=(c[0]+x,c[1]+y,c[2]+x,c[3]+y)
        es=[]
        for e in P.eco:
            r=rbox(e,a); es.append((r[0]+x,r[1]+y,r[2]+x,r[3]+y))
        return c,es
    def apply(self,g,dx,dy,da):
        """rotate group g (leader and its decoupling caps) by da about the centre of the leader's courtyard, then move it by
        dx,dy; returns undo info. A 180-degree turn keeps the part where it is (a DIP footprint's origin is pin 1, not the centre)"""
        B=self.B; mem=B.members[g]; c=self.boxes(g)[0]; cx,cy=(c[0]+c[2])/2,(c[1]+c[3])/2
        old=[(i,self.x[i],self.y[i],self.a[i],self.padxy[i]) for i in mem]
        for i in mem:
            ox,oy=self.x[i]-cx,self.y[i]-cy
            if da:
                # KiCad: rotating by +da (CCW on screen) maps local offsets with rot(.,.,da)
                ox,oy=rot(ox,oy,da)
            self.x[i]=cx+dx+ox; self.y[i]=cy+dy+oy; self.a[i]=(self.a[i]+da)%360
            if self.a[i]>180: self.a[i]-=360
        if da and SNAP>0:
            # keep the leader's origin on its SNAP grid (pins stay on the 0.635 mm grid of the board)
            sx=round((self.x[g]-old[0][1])/SNAP)*SNAP-(self.x[g]-old[0][1]); sy=round((self.y[g]-old[0][2])/SNAP)*SNAP-(self.y[g]-old[0][2])
            for i in mem: self.x[i]+=sx; self.y[i]+=sy
        for i in mem: self._pads(i)
        return old
    def centre(self,g):
        c=self.boxes(g)[0]; return (c[0]+c[2])/2,(c[1]+c[3])/2
    def undo(self,old):
        for i,x,y,a,pp in old: self.x[i]=x; self.y[i]=y; self.a[i]=a; self.padxy[i]=pp

def ovl(a,b,g=0.0): return a[0]<b[2]+g and b[0]<a[2]+g and a[1]<b[3]+g and b[1]<a[3]+g

class Legal:
    """courtyard overlap, puller (Eco1) boxes against courtyards, outline margin"""
    def __init__(self,B,S):
        from matplotlib.path import Path
        self.B=B; self.path=Path(B.outline)
        self.base={}
        for i in range(len(B.parts)):
            if B.parts[i].ref.startswith('LOGO') or B.parts[i].lib.endswith('Logo'): continue
            self.base[i]=S.boxes(i)
        self.allowed=set()   # overlaps already present in the input placement are tolerated (decap tucked in a socket, etc.)
        for i in self.base:
            for k in self.base:
                if k<=i: continue
                if self._clash(self.base[i],self.base[k]): self.allowed.add((i,k))
    def _clash(self,A,Bx):
        ca,ea=A; cb,eb=Bx
        if ovl(ca,cb,GAP): return True
        return any(ovl(e,cb) for e in ea) or any(ovl(e,ca) for e in eb)
    def inside(self,c):
        x0,y0,x1,y1=c; m=MARGIN
        pts=[(x0-m,y0-m),(x1+m,y0-m),(x1+m,y1+m),(x0-m,y1+m),((x0+x1)/2,y0-m),((x0+x1)/2,y1+m),(x0-m,(y0+y1)/2),(x1+m,(y0+y1)/2)]
        return bool(self.path.contains_points(pts).all())
    def _arrays(self):
        ks=sorted(self.base); self._k=np.array(ks)
        self._C=np.array([self.base[k][0] for k in ks])
        ec=[(k,e) for k in ks for e in self.base[k][1]]
        self._ek=np.array([k for k,e in ec]); self._E=np.array([e for k,e in ec]) if ec else np.zeros((0,4))
    def _hits(self,bx,arr,g=0.0):
        if len(arr)==0: return np.zeros(0,bool)
        return (bx[0]<arr[:,2]+g)&(arr[:,0]<bx[2]+g)&(bx[1]<arr[:,3]+g)&(arr[:,1]<bx[3]+g)
    def ok(self,S,changed):
        if not hasattr(self,'_C'): self._arrays()
        cur={i:S.boxes(i) for i in changed if i in self.base}
        if ICROTS:
            for i in cur:
                if len(self.B.parts[i].pads)>=8 and int(round(S.a[i]))%360 not in ICROTS: return False
        for i,(c,es) in cur.items():
            if not self.inside(c): return False
            bad=set(self._k[self._hits(c,self._C,GAP)])|set(self._ek[self._hits(c,self._E)])
            for e in es: bad|=set(self._k[self._hits(e,self._C)])
            for k in bad:
                if k in cur: continue
                if (min(i,k),max(i,k)) not in self.allowed: return False
        ks=list(cur)
        for x in range(len(ks)):
            for y in range(x+1,len(ks)):
                a,b=ks[x],ks[y]
                if self._clash(cur[a],cur[b]) and (min(a,b),max(a,b)) not in self.allowed: return False
        return True
    def commit(self,S,changed):
        for i in changed:
            if i in self.base: self.base[i]=S.boxes(i)
        self._arrays()

# ------------------------------------------------------------------ net topology
def mst_edges(pts):
    n=len(pts)
    if n<2: return []
    P=np.array(pts); inT=np.zeros(n,bool); inT[0]=True
    d=np.abs(P[:,0]-P[0,0])+np.abs(P[:,1]-P[0,1]); par=np.zeros(n,int); out=[]
    d[0]=np.inf
    for _ in range(n-1):
        dd=np.where(inT,np.inf,d); j=int(np.argmin(dd)); out.append((P[par[j],0],P[par[j],1],P[j,0],P[j,1])); inT[j]=True
        nd=np.abs(P[:,0]-P[j,0])+np.abs(P[:,1]-P[j,1]); upd=(nd<d)&~inT; d=np.where(upd,nd,d); par=np.where(upd,j,par)
    return out

def edge_arrays(edges):
    if not edges: return np.zeros((0,4))
    return np.array(edges,float)

def classify(e):
    """e: (n,4) array -> dx, dy, horiz (bool), aligned (bool)"""
    dx=np.abs(e[:,2]-e[:,0]); dy=np.abs(e[:,3]-e[:,1]); return dx,dy,dx>=dy,np.minimum(dx,dy)<=ALIGN

def _cross_one_dir(A,Bv,eps=0.05):
    """A (n,4), Bv (m,4) edges both mostly horizontal: n x m bool, True where they swap y order over their common x span"""
    if len(A)==0 or len(Bv)==0: return np.zeros((len(A),len(Bv)),bool)
    def norm(e):
        sw=e[:,0]>e[:,2]; x0=np.where(sw,e[:,2],e[:,0]); y0=np.where(sw,e[:,3],e[:,1]); x1=np.where(sw,e[:,0],e[:,2]); y1=np.where(sw,e[:,1],e[:,3])
        return x0,y0,x1,y1
    ax0,ay0,ax1,ay1=norm(A); bx0,by0,bx1,by1=norm(Bv)
    lo=np.maximum(ax0[:,None],bx0[None,:]); hi=np.minimum(ax1[:,None],bx1[None,:])
    span=hi-lo
    def yat(x0,y0,x1,y1,x):
        d=np.where(x1-x0>1e-9,x1-x0,1.0)
        t=np.clip((x-x0)/d,0,1); return y0+t*(y1-y0)
    ya_lo=yat(ax0[:,None],ay0[:,None],ax1[:,None],ay1[:,None],lo); yb_lo=yat(bx0[None,:],by0[None,:],bx1[None,:],by1[None,:],lo)
    ya_hi=yat(ax0[:,None],ay0[:,None],ax1[:,None],ay1[:,None],hi); yb_hi=yat(bx0[None,:],by0[None,:],bx1[None,:],by1[None,:],hi)
    d0=ya_lo-yb_lo; d1=ya_hi-yb_hi
    return (span>eps)&(((d0>eps)&(d1<-eps))|((d0<-eps)&(d1>eps)))

def crossings(A,An,Bv,Bn,same=False):
    """same-direction crossings between edge sets A and B of different nets: counts (a2, a1, a0) and per-A-edge / per-B-edge counts"""
    out=np.zeros(3); pa=np.zeros((len(A),3)); pb=np.zeros((len(Bv),3))
    if len(A)==0 or len(Bv)==0: return out,pa,pb
    _,_,ha,aa=classify(A); _,_,hb,ab=classify(Bv)
    for hor in (True,False):
        ia=np.where(ha==hor)[0]; ib=np.where(hb==hor)[0]
        if len(ia)==0 or len(ib)==0: continue
        a=A[ia]; b=Bv[ib]
        if not hor: a=a[:,[1,0,3,2]]; b=b[:,[1,0,3,2]]
        X=_cross_one_dir(a,b)
        X&=(An[ia][:,None]!=Bn[ib][None,:])
        if same: X&=(ia[:,None]<ib[None,:])
        cls=2-(aa[ia][:,None].astype(int)+ab[ib][None,:].astype(int))   # 0=a2 1=a1 2=a0
        for c in range(3):
            M=X&(cls==c); out[c]+=M.sum(); pa[ia,c]+=M.sum(1); pb[ib,c]+=M.sum(0)
    return out,pa,pb

def proper_crossings(e,en,f=None,fn=None):
    """per edge of e: number of other-net edges (of f, default e) whose straight lines cross it properly, any direction
    (the PR #282 measure)"""
    if f is None: f,fn=e,en
    if len(e)==0 or len(f)==0: return np.zeros(len(e))
    ax=e[:,0:1]; ay=e[:,1:2]; bx=e[:,2:3]; by=e[:,3:4]; cx=f[:,0][None]; cy=f[:,1][None]; dx=f[:,2][None]; dy=f[:,3][None]
    def o(px_,py_,qx,qy,rx,ry): return (qx-px_)*(ry-py_)-(qy-py_)*(rx-px_)
    a=o(ax,ay,bx,by,cx,cy); b2=o(ax,ay,bx,by,dx,dy); c=o(cx,cy,dx,dy,ax,ay); d=o(cx,cy,dx,dy,bx,by)
    X=(a*b2<0)&(c*d<0)&(en[:,None]!=fn[None,:]); return X.sum(1)

# ------------------------------------------------------------------ congestion grid
class Grid:
    def __init__(self,B,S):
        self.B=B; self.x0=B.bx0; self.y0=B.by0
        self.nx=int(math.ceil((B.bx1-B.bx0)/BIN)); self.ny=int(math.ceil((B.by1-B.by0)/BIN))
        self.sub=int(round(BIN/RES)); self.W=self.nx*self.sub; self.H=self.ny*self.sub
        self._static()
        self.capH=np.zeros((self.ny,self.nx)); self.capV=np.zeros((self.ny,self.nx))
        self.blkF=self.static.copy(); self.blkB=self.static.copy()
        self._raster_pads(S,None)
        self._cap_all()
    def _static(self):
        from matplotlib.path import Path
        from shapely.geometry import Polygon
        import rules
        xs=self.x0+(np.arange(self.W)+0.5)*RES; ys=self.y0+(np.arange(self.H)+0.5)*RES
        self.xs=xs; self.ys=ys
        poly=Polygon(self.B.outline).buffer(-(EDGEBAND+TRACK/2),join_style=2)
        path=Path(np.array(poly.exterior.coords))
        XX,YY=np.meshgrid(xs,ys)
        inside=path.contains_points(np.c_[XX.ravel(),YY.ravel()]).reshape(self.H,self.W)
        st=~inside
        pads=[]
        for i,P in enumerate(self.B.parts):
            for p in P.pads: pads.append(dict(ref=P.ref,x=0,y=0,w=p['w'],h=p['h'],drill=p['drill']))
        # mounting-hole bands (rules.py): need pad coordinates
        S=State(self.B); pl=[]
        for i,P in enumerate(self.B.parts):
            for j,p in enumerate(P.pads):
                x,y=S.pad(i,j); pl.append(dict(ref=P.ref,x=x,y=y,w=p['w'],h=p['h'],drill=p['drill']))
        for r in rules.hole_edge_keepouts(pl,poly,0.0):
            x0,y0,x1,y1=r.bounds; c0,r0=self._cell(x0-GROW,y0-GROW); c1,r1=self._cell(x1+GROW,y1+GROW)
            st[max(0,r0):r1+1,max(0,c0):c1+1]=True
        self.static=st
    def _cell(self,x,y): return int((x-self.x0)/RES),int((y-self.y0)/RES)
    def _mask_pad(self,blk,x,y,w,h,ang,shape,grow):
        a=ang%180
        if abs(a-90)<1e-3: w,h=h,w
        elif abs(a)>1e-3 and abs(a-180)>1e-3: w=h=max(w,h)
        hw=w/2+grow; hh=h/2+grow
        c0,r0=self._cell(x-hw,y-hh); c1,r1=self._cell(x+hw,y+hh)
        c0=max(c0,0); r0=max(r0,0); c1=min(c1,self.W-1); r1=min(r1,self.H-1)
        if c1<c0 or r1<r0: return
        X=self.xs[c0:c1+1][None,:]-x; Y=self.ys[r0:r1+1][:,None]-y
        if shape in ('circle','oval'):
            rr=min(w,h)/2; qx=np.maximum(np.abs(X)-(w/2-rr),0); qy=np.maximum(np.abs(Y)-(h/2-rr),0)
            m=qx*qx+qy*qy<=(rr+grow)**2
        else:
            m=(np.abs(X)<=hw)&(np.abs(Y)<=hh)
        blk[r0:r1+1,c0:c1+1]|=m
    def _raster_pads(self,S,region):
        """region: (r0,r1,c0,c1) cell range to rebuild, or None = all"""
        if region is None:
            r0,r1,c0,c1=0,self.H-1,0,self.W-1
        else: r0,r1,c0,c1=region
        self.blkF[r0:r1+1,c0:c1+1]=self.static[r0:r1+1,c0:c1+1]; self.blkB[r0:r1+1,c0:c1+1]=self.static[r0:r1+1,c0:c1+1]
        X0=self.x0+c0*RES-5; X1=self.x0+(c1+1)*RES+5; Y0=self.y0+r0*RES-5; Y1=self.y0+(r1+1)*RES+5
        subF=self.blkF[r0:r1+1,c0:c1+1]; subB=self.blkB[r0:r1+1,c0:c1+1]
        save=(self.xs,self.ys,self.W,self.H,self.x0,self.y0)
        # rasterise into the sub-window by shifting the origin
        self.xs=save[0][c0:c1+1]; self.ys=save[1][r0:r1+1]; self.W=c1-c0+1; self.H=r1-r0+1; self.x0=save[4]+c0*RES; self.y0=save[5]+r0*RES
        try:
            for i,P in enumerate(self.B.parts):
                for j,p in enumerate(P.pads):
                    x,y=S.padxy[i][j]
                    if x<X0 or x>X1 or y<Y0 or y>Y1: continue
                    ang=p['rang']+S.a[i]
                    if p['kind']=='np_thru_hole':
                        d=max(p['drill'],p['w']); g=0.3+TRACK/2
                        self._mask_pad(subF,x,y,d,d,0,'circle',g); self._mask_pad(subB,x,y,d,d,0,'circle',g); continue
                    if p['tht'] or p['smd_layer']=='F': self._mask_pad(subF,x,y,p['w'],p['h'],ang,p['shape'],GROW)
                    if p['tht'] or p['smd_layer']=='B': self._mask_pad(subB,x,y,p['w'],p['h'],ang,p['shape'],GROW)
        finally:
            self.xs,self.ys,self.W,self.H,self.x0,self.y0=save
    @staticmethod
    def _tracks(freevec):
        """number of parallel tracks at PITCH that fit in the runs of True of a 1-D vector of RES cells"""
        v=np.concatenate([[False],freevec,[False]]).astype(np.int8); d=np.diff(v)
        st=np.where(d==1)[0]; en=np.where(d==-1)[0]; run=(en-st)
        return float(np.sum(np.floor((run-1)*RES/PITCH)+1)) if len(run) else 0.0
    def _cap_bin(self,r,c):
        """tracks per direction: the bin is cut into STRIPS slices across the direction of travel, the free tracks of each slice
        are counted and averaged (a connector pad row blocks its own slice, not the whole bin)"""
        s=self.sub; F=self.blkF[r*s:(r+1)*s,c*s:(c+1)*s]; Bb=self.blkB[r*s:(r+1)*s,c*s:(c+1)*s]
        k=STRIPS; cut=np.linspace(0,s,k+1).astype(int)
        hF=np.mean([self._tracks(~F[:,cut[i]:cut[i+1]].any(1)) for i in range(k)]); hB=np.mean([self._tracks(~Bb[:,cut[i]:cut[i+1]].any(1)) for i in range(k)])
        vB=np.mean([self._tracks(~Bb[cut[i]:cut[i+1],:].any(0)) for i in range(k)]); vF=np.mean([self._tracks(~F[cut[i]:cut[i+1],:].any(0)) for i in range(k)])
        self.capH[r,c]=hF+WW*hB; self.capV[r,c]=vB+WW*vF
    def _cap_all(self):
        for r in range(self.ny):
            for c in range(self.nx): self._cap_bin(r,c)
    def update(self,S,boxes):
        """re-rasterise the bins under boxes (absolute mm) after a move"""
        bins=set()
        for (x0,y0,x1,y1) in boxes:
            c0=max(0,int((x0-GROW-self.x0)//BIN)); c1=min(self.nx-1,int((x1+GROW-self.x0)//BIN))
            r0=max(0,int((y0-GROW-self.y0)//BIN)); r1=min(self.ny-1,int((y1+GROW-self.y0)//BIN))
            for r in range(r0,r1+1):
                for c in range(c0,c1+1): bins.add((r,c))
        if not bins: return bins
        rs=[b[0] for b in bins]; cs=[b[1] for b in bins]; s=self.sub
        self._raster_pads(S,(min(rs)*s,(max(rs)+1)*s-1,min(cs)*s,(max(cs)+1)*s-1))
        for r,c in bins: self._cap_bin(r,c)
        return bins
    def demand(self,e):
        """RUDY demand of edges e (n,4): (DH, DV) arrays (ny, nx) in tracks"""
        DH=np.zeros((self.ny,self.nx)); DV=np.zeros((self.ny,self.nx))
        if len(e)==0: return DH,DV
        bx=self.x0+np.arange(self.nx+1)*BIN; by=self.y0+np.arange(self.ny+1)*BIN
        for x0,y0,x1,y1 in e:
            if x0>x1: x0,x1=x1,x0
            if y0>y1: y0,y1=y1,y0
            w=x1-x0; h=y1-y0
            if w<PITCH: xc=(x0+x1)/2; x0,x1=xc-PITCH/2,xc+PITCH/2
            if h<PITCH: yc=(y0+y1)/2; y0,y1=yc-PITCH/2,yc+PITCH/2
            ox=np.clip(np.minimum(bx[1:],x1)-np.maximum(bx[:-1],x0),0,None); oy=np.clip(np.minimum(by[1:],y1)-np.maximum(by[:-1],y0),0,None)
            if w>=PITCH: DH+=np.outer(oy/(y1-y0),ox/BIN)
            if h>=PITCH: DV+=np.outer(oy/BIN,ox/(x1-x0))
        return DH,DV

# ------------------------------------------------------------------ the evaluator
class Model:
    def __init__(self,path,K=None,budget=None):
        t=time.time()
        self.B=Board(path); self.S=State(self.B); self.L=Legal(self.B,self.S)
        self.G=Grid(self.B,self.S)
        self.K=dict(DEFAULT_K)
        if K is None and os.path.exists(FITFILE): K=json.load(open(FITFILE)).get('K')
        if K: self.K.update(K)
        self.budget=self._budget(budget or E('BUDGET',''))
        self.netlist=sorted(self.B.nets)
        self.netedges={}
        for n in self.netlist: self.netedges[n]=self._edges(self.S,n)
        self._rebuild()
        self.t_load=time.time()-t
    def _budget(self,f):
        if not f: return []
        J=json.load(open(f)); out=[]; nid={v:k for k,v in self.B.netname.items()}
        for net,d in J.get('max',{}).items():
            if net not in nid: continue
            for a,dd in d.items():
                for b,mm in dd.items():
                    ra,pa=a.rsplit('-',1); rb,pb=b.rsplit('-',1)
                    if ra not in self.B.byref or rb not in self.B.byref: continue
                    ia=self.B.byref[ra]; ib=self.B.byref[rb]
                    ja=[j for j,p in enumerate(self.B.parts[ia].pads) if p['num']==pa]; jb=[j for j,p in enumerate(self.B.parts[ib].pads) if p['num']==pb]
                    if ja and jb: out.append((nid[net],ia,ja[0],ib,jb[0],float(mm),f'{net} {a}->{b}'))
        return out
    def _edges(self,S,n):
        pts=[S.pad(i,j) for i,j in self.B.nets[n]]
        return edge_arrays(mst_edges(pts))
    def _rebuild(self):
        es=[self.netedges[n] for n in self.netlist]
        self.E=np.concatenate(es) if es else np.zeros((0,4))
        self.En=np.concatenate([np.full(len(self.netedges[n]),n) for n in self.netlist])
        self.DH,self.DV=self.G.demand(self.E)
    # --- terms
    def terms(self,detail=False):
        e=self.E; dx,dy,h,al=classify(e)
        wl=float((dx+dy).sum()); bends=int((~al).sum())
        x,pa,pb=crossings(e,self.En,e,self.En,same=True)
        ovH=np.maximum(self.DH-self.G.capH,0); ovV=np.maximum(self.DV-self.G.capV,0); ov=float(ovH.sum()+ovV.sum())
        uH=self.DH/np.maximum(self.G.capH,0.5); uV=self.DV/np.maximum(self.G.capV,0.5)
        cong=self._cong_exposure(e,uH,uV)
        bud=self._budget_excess(self.S)
        xall=float(proper_crossings(e,self.En).sum())/2
        T=dict(length=wl,bends=bends,a2=float(x[0]),a1=float(x[1]),a0=float(x[2]),xall=xall,overflow=ov,cong=float(cong.sum()),budget=bud)
        if detail: T.update(_pa=pa+pb,_cong=cong,_uH=uH,_uV=uV)
        return T
    def _cong_exposure(self,e,uH,uV):
        """per edge: sum over its bbox bins of its own demand x max(0, utilisation - 0.7)"""
        out=np.zeros(len(e)); G=self.G
        bx=G.x0+np.arange(G.nx+1)*BIN; by=G.y0+np.arange(G.ny+1)*BIN
        pH=np.maximum(uH-0.7,0); pV=np.maximum(uV-0.7,0)
        for k,(x0,y0,x1,y1) in enumerate(e):
            if x0>x1: x0,x1=x1,x0
            if y0>y1: y0,y1=y1,y0
            w=x1-x0; h=y1-y0
            if w<PITCH: xc=(x0+x1)/2; x0,x1=xc-PITCH/2,xc+PITCH/2
            if h<PITCH: yc=(y0+y1)/2; y0,y1=yc-PITCH/2,yc+PITCH/2
            ox=np.clip(np.minimum(bx[1:],x1)-np.maximum(bx[:-1],x0),0,None); oy=np.clip(np.minimum(by[1:],y1)-np.maximum(by[:-1],y0),0,None)
            s=0.0
            if w>=PITCH: s+=float((np.outer(oy/(y1-y0),ox/BIN)*pH).sum())
            if h>=PITCH: s+=float((np.outer(oy/BIN,ox/(x1-x0))*pV).sum())
            out[k]=s
        return out
    def _budget_excess(self,S):
        DET=float(E('DETOUR','1.15')); s=0.0
        for n,ia,ja,ib,jb,mm,_ in self.budget:
            (x0,y0),(x1,y1)=S.pad(ia,ja),S.pad(ib,jb); s+=max(0.0,(abs(x1-x0)+abs(y1-y0))*DET-mm)
        return s
    def vias(self,T):
        K=self.K; return K['KB']*T['bends']+K['K2']*T['a2']+K['K1']*T['a1']+K['K0']*T['a0']+K['KC']*T['cong']+2*K['KX']*T['xall']
    def cost(self,T):
        return T['length']+VIAMM*self.vias(T)+OVW*T['overflow']*BIN+float(E('BUDW','20'))*T['budget']
    # --- incremental evaluation of a group move
    def try_move(self,g,dx,dy,da,check=True,full=False):
        """cost delta of moving group g; None when illegal. full=True also re-rasterises capacity (else demand-only screen)"""
        S=self.S; mem=self.B.members[g]
        old=S.apply(g,dx,dy,da)
        try:
            if check and not self.L.ok(S,mem): return None
            return self._delta(mem,old,full)
        finally:
            S.undo(old)
            if full: self._restore_cap()
    def quick(self,g,dx,dy,da):
        """cheap screen: legality, then MST length + bends of the affected nets only (no crossings, no congestion)"""
        S=self.S; mem=self.B.members[g]; old=S.apply(g,dx,dy,da)
        try:
            if not self.L.ok(S,mem): return None
            d=0.0; KB=self.K['KB']
            for n in self._affected(mem):
                e0=self.netedges[n]; e1=self._edges(S,n)
                for e,sg in ((e1,1),(e0,-1)):
                    if len(e)==0: continue
                    ddx=np.abs(e[:,2]-e[:,0]); ddy=np.abs(e[:,3]-e[:,1])
                    d+=sg*((ddx+ddy).sum()+VIAMM*KB*(np.minimum(ddx,ddy)>ALIGN).sum())
            return float(d)
        finally: S.undo(old)
    def _affected(self,mem):
        nets=set()
        for i in mem: nets|=self.B.partnets[i]
        return sorted(nets)
    def _delta(self,mem,old,full,nets=None):
        nets=self._affected(mem) if nets is None else nets; B=self.B
        if not nets and not full: return 0.0
        mask=np.isin(self.En,nets)
        Eo=self.E[mask]; Eno=self.En[mask]; Er=self.E[~mask]; Enr=self.En[~mask]
        new=[self._edges(self.S,n) for n in nets]
        En=np.concatenate(new) if new else np.zeros((0,4)); Enn=np.concatenate([np.full(len(a),n) for a,n in zip(new,nets)]) if new else np.zeros(0)
        K=self.K
        def local(EA,EAn):
            dx,dy,h,al=classify(EA); wl=(dx+dy).sum(); bends=(~al).sum()
            x1,_,_=crossings(EA,EAn,Er,Enr); x2,_,_=crossings(EA,EAn,EA,EAn,same=True)
            x=x1+x2
            xa=proper_crossings(EA,EAn,Er,Enr).sum()+proper_crossings(EA,EAn).sum()/2
            return wl+VIAMM*(K['KB']*bends+K['K2']*x[0]+K['K1']*x[1]+K['K0']*x[2]+2*K['KX']*xa)
        d=local(En,Enn)-local(Eo,Eno)
        # congestion: demand change and (full) capacity change
        DHo,DVo=self.G.demand(Eo); DHn,DVn=self.G.demand(En)
        capH,capV=self.G.capH,self.G.capV
        if full:
            self._save_cap()
            boxes=[]
            for i,x,y,a,pp in old:
                pts=pp+self.S.padxy[i]
                if pts: boxes.append(bbox(pts))
            self.G.update(self.S,boxes); capH,capV=self.G.capH,self.G.capV
            ov0=np.maximum(self.DH-self._capH0,0).sum()+np.maximum(self.DV-self._capV0,0).sum()
        else:
            ov0=np.maximum(self.DH-capH,0).sum()+np.maximum(self.DV-capV,0).sum()
        DH=self.DH-DHo+DHn; DV=self.DV-DVo+DVn
        ov1=np.maximum(DH-capH,0).sum()+np.maximum(DV-capV,0).sum()
        d+=OVW*(ov1-ov0)*BIN
        if self.budget:
            b1=self._budget_excess(self.S)
            d+=float(E('BUDW','20'))*(b1-self._bud0)
        return float(d)
    def _save_cap(self):
        self._capH0=self.G.capH.copy(); self._capV0=self.G.capV.copy(); self._blk=(self.G.blkF.copy(),self.G.blkB.copy())
    def _restore_cap(self):
        if hasattr(self,'_capH0'):
            self.G.capH=self._capH0; self.G.capV=self._capV0; self.G.blkF,self.G.blkB=self._blk; del self._capH0
    def commit(self,g,dx,dy,da):
        S=self.S; mem=self.B.members[g]; old=S.apply(g,dx,dy,da)
        boxes=[bbox(pp+S.padxy[i]) for i,x,y,a,pp in old if pp]
        self.G.update(S,boxes); self.L.commit(S,mem)
        for n in self._affected(mem): self.netedges[n]=self._edges(S,n)
        self._rebuild(); self._bud0=self._budget_excess(S)
    def ready(self):
        self._bud0=self._budget_excess(self.S)

# ------------------------------------------------------------------ reports
def per_net_features(M):
    T=M.terms(detail=True); e=M.E; dx,dy,h,al=classify(e); out={}
    pa=T['_pa']; cg=T['_cong']; xall=proper_crossings(e,M.En)
    for n in M.netlist:
        m=M.En==n
        out[n]=dict(length=float((dx[m]+dy[m]).sum()),bends=int((~al[m]).sum()),a2=float(pa[m,0].sum()),a1=float(pa[m,1].sum()),
                    a0=float(pa[m,2].sum()),cong=float(cg[m].sum()),pins=len(M.B.nets[n]),xall=float(xall[m].sum()))
    return T,out

def routed_vias(path,B):
    """per-net via count of a routed board (by net name), and per-bin routed track density per direction"""
    b=parse(open(path,encoding='utf-8').read()); nn={int(n[1]):n[2] for n in find(b,'net')}
    v=collections.Counter(nn.get(int(one(x,'net')[1]),'') for x in find(b,'via'))
    segs=[]
    for s in find(b,'segment'):
        a=lin(one(s,'start')[1:3]); e=lin(one(s,'end')[1:3]); segs.append((nn.get(int(one(s,'net')[1]),''),one(s,'layer')[1],a,e))
    return v,segs,nn

def bus_pairs(M,minshared=3):
    """chip pairs sharing >= minshared nets: pin-order inversions across the gap"""
    B=M.B; S=M.S; out=[]
    pn=collections.defaultdict(dict)   # part -> net -> pad index
    for n,v in B.nets.items():
        for i,j in v: pn[i].setdefault(n,j)
    ics=[i for i in pn if len(B.parts[i].pads)>=8]; movg=set(B.movable)
    for ai in range(len(ics)):
        for bi in range(ai+1,len(ics)):
            a,b=ics[ai],ics[bi]; sh=sorted(set(pn[a])&set(pn[b]))
            if len(sh)<minshared or not ({a,b}&movg): continue
            pa=np.array([S.pad(a,pn[a][n]) for n in sh]); pb=np.array([S.pad(b,pn[b][n]) for n in sh])
            hor=abs(S.x[a]-S.x[b])>=abs(S.y[a]-S.y[b]); k=1 if hor else 0
            ua=pa[:,k]; ub=pb[:,k]; inv=0; tot=0
            for i in range(len(sh)):
                for j in range(i+1,len(sh)):
                    if abs(ua[i]-ua[j])<0.5 or abs(ub[i]-ub[j])<0.5: continue
                    tot+=1; inv+= (ua[i]-ua[j])*(ub[i]-ub[j])<0
            out.append(dict(a=B.parts[a].ref,b=B.parts[b].ref,shared=len(sh),pairs=int(tot),inversions=int(inv),
                            dir='horizontal' if hor else 'vertical',nets=[B.netname[n] for n in sh]))
    # identical rows (the four expansion slots are wired in parallel) are merged: J9/J10/J11/J12-U31
    m={}
    for d in out:
        k=(d['b'],d['shared'],d['pairs'],d['inversions'],d['dir']) ; k2=(d['a'],d['shared'],d['pairs'],d['inversions'],d['dir'])
        if k in m and m[k]['a']!=d['a']: m[k]['a']+='/'+d['a']; continue
        if k2 in m and m[k2]['b']!=d['b'] and m[k2]['a']==d['a']: m[k2]['b']+='/'+d['b']; continue
        m[k]=d
    out=list(m.values()); out.sort(key=lambda d:-d['inversions']); return out

def draw(M,path,title,extra=None,arrows=None):
    import matplotlib; matplotlib.use('Agg'); import matplotlib.pyplot as plt
    from matplotlib.patches import Rectangle
    G=M.G; uH=M.DH/np.maximum(G.capH,0.5); uV=M.DV/np.maximum(G.capV,0.5); u=np.maximum(uH,uV)
    fig,ax=plt.subplots(1,1,figsize=(16,12),dpi=110)
    ext=(G.x0,G.x0+G.nx*BIN,G.y0+G.ny*BIN,G.y0)
    im=ax.imshow(extra if extra is not None else u,extent=ext,cmap='inferno_r' if extra is None else 'viridis',vmin=0,vmax=(1.6 if extra is None else None),alpha=0.85,interpolation='nearest')
    cb=fig.colorbar(im,ax=ax,shrink=0.7); cb.set_label('demand / capacity (worst direction)' if extra is None else 'cost delta (mm)')
    ol=np.array(M.B.outline+[M.B.outline[0]]); ax.plot(ol[:,0],ol[:,1],'k-',lw=1.5)
    for i,P in enumerate(M.B.parts):
        c,es=M.S.boxes(i)
        ax.add_patch(Rectangle((c[0],c[1]),c[2]-c[0],c[3]-c[1],fill=False,ec='#1565c0',lw=0.8))
        if len(P.pads)>=8 or P.ref[0] in 'JUX': ax.text((c[0]+c[2])/2,(c[1]+c[3])/2,P.ref,ha='center',va='center',fontsize=7,color='#0d47a1',weight='bold')
    if arrows:
        for (x0,y0,x1,y1,lab) in arrows:
            ax.annotate('',xy=(x1,y1),xytext=(x0,y0),arrowprops=dict(arrowstyle='->',color='#00c853',lw=2))
            ax.plot([x0],[y0],'o',color='#00c853',ms=4)
    ax.set_xlim(G.x0-2,G.x0+G.nx*BIN+2); ax.set_ylim(G.y0+G.ny*BIN+2,G.y0-2); ax.set_aspect('equal'); ax.set_title(title,fontsize=14)
    fig.tight_layout(); fig.savefig(path); plt.close(fig)

def fmt_terms(M,T):
    return (f"length {T['length']/1000:.2f} m | bends {T['bends']} | crossings {T['xall']:.0f} (same-way a2 {T['a2']:.0f} a1 {T['a1']:.0f} a0 {T['a0']:.0f}) | "
            f"overflow {T['overflow']:.1f} tracks | cong {T['cong']:.1f} | budget {T['budget']:.0f} mm | expected vias {M.vias(T):.0f} | cost {M.cost(T):.0f}")

def mode_report(M,out):
    t=time.time(); T,pn=per_net_features(M); B=M.B
    lines=[f'# placement report: {os.path.basename(M.B.path)}','',fmt_terms(M,T),'',
           f'{len(B.parts)} parts, {len(B.movable)} movable groups, {len(B.nets)} routed nets (planes {",".join(sorted(PLANES))} left out), '
           f'{len(M.E)} connections; bins {BIN} mm ({M.G.nx}x{M.G.ny}); K {json.dumps({k:round(v,3) for k,v in M.K.items()})}','']
    bp=bus_pairs(M)
    lines+=['## Bus pin-order inversions (chip pairs sharing 3+ nets)','','| pair | shared | inversions / pairs | across |','|---|---|---|---|']
    for d in bp[:int(E('TOP','25'))]:
        if d['inversions']==0: break
        lines.append(f"| {d['a']}-{d['b']} | {d['shared']} | {d['inversions']} / {d['pairs']} | {d['dir']} |")
    G=M.G; uH=M.DH/np.maximum(G.capH,0.5); uV=M.DV/np.maximum(G.capV,0.5)
    hot=[]
    for r in range(G.ny):
        for c in range(G.nx):
            for d,u,D,C in (('H',uH[r,c],M.DH[r,c],G.capH[r,c]),('V',uV[r,c],M.DV[r,c],G.capV[r,c])):
                if D>0.5: hot.append((u,d,r,c,D,C))
    hot.sort(reverse=True)
    def near(r,c):
        x=G.x0+(c+0.5)*BIN; y=G.y0+(r+0.5)*BIN
        k=min(range(len(B.parts)),key=lambda i:math.dist((M.S.x[i],M.S.y[i]),(x,y))); return x,y,B.parts[k].ref
    lines+=['','## Hottest bins','','| bin centre (mm) | near | dir | demand | capacity | ratio |','|---|---|---|---|---|---|']
    for u,d,r,c,D,C in hot[:int(E('TOP','25'))]:
        x,y,ref=near(r,c); lines.append(f'| {x:.0f},{y:.0f} | {ref} | {d} | {D:.1f} | {C:.1f} | {u:.2f} |')
    lines+=['','## Nets with the most L bends (each is about one via)','','| net | pins | bends | crossings a2/a1/a0 | MST mm |','|---|---|---|---|---|']
    for n in sorted(pn,key=lambda n:-pn[n]['bends'])[:int(E('TOP','25'))]:
        f=pn[n]; lines.append(f"| {B.netname[n]} | {f['pins']} | {f['bends']} | {f['a2']:.0f}/{f['a1']:.0f}/{f['a0']:.0f} | {f['length']:.0f} |")
    if M.budget:
        DET=float(E('DETOUR','1.15')); bl=[]
        for n,ia,ja,ib,jb,mm,lab in M.budget:
            (x0,y0),(x1,y1)=M.S.pad(ia,ja),M.S.pad(ib,jb); man=abs(x1-x0)+abs(y1-y0)
            bl.append((mm-man*DET,lab,man,mm))
        bl.sort()
        lines+=['',f'## Tightest length budgets (straight distance x {DET} against the budget)','','| pair | straight mm | budget mm | room mm |','|---|---|---|---|']
        for room,lab,man,mm in bl[:15]: lines.append(f'| {lab} | {man:.0f} | {mm:.0f} | {room:+.0f} |')
    os.makedirs(out,exist_ok=True)
    draw(M,os.path.join(out,'congestion.png'),f'routability: demand / capacity per {BIN:g} mm bin (pads only)')
    open(os.path.join(out,'report.md'),'w').write('\n'.join(lines)+'\n')
    json.dump(dict(terms={k:float(v) for k,v in T.items() if not k.startswith('_')},expected_vias=M.vias(T),cost=M.cost(T),bus=bp[:40],
                   nets={B.netname[n]:f for n,f in pn.items()}),open(os.path.join(out,'report.json'),'w'),indent=1)
    print('\n'.join(lines[:6])); print(f'wrote {out}/report.md congestion.png report.json  ({time.time()-t:.1f} s)')

def mode_fit(M,routed,out):
    """least squares: per-net routed vias ~ KB*bends + K2*a2 + K1*a1 + K0*a0 + KC*cong (non-negative)"""
    from scipy.optimize import nnls
    rows=[]; y=[]; names=[]
    for path in routed:
        Mr=M if os.path.abspath(path)==os.path.abspath(M.B.path) else Model(path,K=DEFAULT_K)
        T,pn=per_net_features(Mr); v,segs,nn=routed_vias(path,Mr.B)
        for n,f in pn.items():
            nm=Mr.B.netname[n]
            rows.append([f['bends'],f['a2'],f['a1'],f['a0'],f['cong'],f['xall']]); y.append(v.get(nm,0)); names.append((os.path.basename(path),nm))
    A=np.array(rows,float); y=np.array(y,float); XALL=A[:,5]
    def r2of(X):
        kk=nnls(X,y)[0]; pp=X@kk; return float(1-((y-pp)**2).sum()/max(((y-y.mean())**2).sum(),1e-9)),float(np.corrcoef(pp,y)[0,1]),float(pp.sum())
    alt={'bends only':r2of(A[:,:1]),'bends + any-direction crossings (PR #282 model)':r2of(np.c_[A[:,0],XALL]),
         'bends + same-way crossings':r2of(A[:,:4]),'same-way crossings + congestion, no any-direction':r2of(A[:,:5]),'full':r2of(A)}
    k,res=nnls(A,y); pred=A@k
    r2=1-((y-pred)**2).sum()/max(((y-y.mean())**2).sum(),1e-9)
    kb=nnls(A[:,:1],y)[0]; pb=A[:,:1]@kb; r2b=1-((y-pb)**2).sum()/max(((y-y.mean())**2).sum(),1e-9)
    K=dict(zip(['KB','K2','K1','K0','KC','KX'],map(float,k)))
    rep=dict(K=K,r2=float(r2),r2_bends_only=float(r2b),kb_only=float(kb[0]),nets=len(y),vias_routed=float(y.sum()),vias_predicted=float(pred.sum()),
             boards=[os.path.basename(p) for p in routed],corr=float(np.corrcoef(pred,y)[0,1]),
             compare={k:dict(r2=v[0],r=v[1],vias=v[2]) for k,v in alt.items()})
    json.dump(rep,open(out,'w'),indent=1)
    print(json.dumps(rep,indent=1)); return rep,names,A,y,pred

# ------------------------------------------------------------------ search
def candidates(rad=None,step=None):
    rad=float(E('RAD','10')) if rad is None else rad; step=float(E('STEP','1.27')) if step is None else step
    n=int(round(rad/step)); rots=[float(r) for r in E('ROTS','0,90,180,270').split(',')]
    return [(i*step,j*step,r) for r in rots for i in range(-n,n+1) for j in range(-n,n+1)]

def best_move(M,g,cands,verify=5,keep=None):
    """three stages: every candidate on legality + MST length/bends (quick), the best KEEP on the full model with demand
    only, the best few of those with the capacity re-rasterised"""
    keep=int(E('KEEP','24')) if keep is None else keep
    q=[]
    for dx,dy,da in cands:
        if dx==0 and dy==0 and da==0: continue
        d=M.quick(g,dx,dy,da)
        if d is not None: q.append((d,dx,dy,da))
    q.sort(); sc=[]
    for _,dx,dy,da in q[:keep]:
        d=M.try_move(g,dx,dy,da,check=False)
        if d is not None: sc.append((d,dx,dy,da))
    sc.sort()
    best=None
    for d,dx,dy,da in sc[:verify]:
        f=M.try_move(g,dx,dy,da,check=False,full=True)
        if best is None or f<best[0]: best=(f,dx,dy,da)
    return best,sc

def swap_delta(M,g,h,commit=False):
    """exchange the places (courtyard centres) of groups g and h (same footprint); each keeps its own rotation and its
    decoupling caps"""
    S=M.S; (gx,gy),(hx,hy)=S.centre(g),S.centre(h); dx=hx-gx; dy=hy-gy; da=0.0
    if commit:
        M.commit(g,dx,dy,da); M.commit(h,-dx,-dy,-da); return None
    old1=S.apply(g,dx,dy,da); old2=S.apply(h,-dx,-dy,-da)
    try:
        mem=M.B.members[g]+M.B.members[h]
        # legality against everything else (ok() skips the moved parts' own old boxes, so the two swap into each other's room)
        if not M.L.ok(S,mem): return None
        return M._delta(mem,old1+old2,True)
    finally:
        S.undo(old2); S.undo(old1); M._restore_cap()

def mode_sweep(M,ref,out):
    B=M.B; i=B.byref[ref]; g=B.leader.get(i,i)
    if g not in B.members: raise SystemExit(f'{ref} is fixed (FIXED / ONLY / FREE)')
    rad=float(E('RAD','20')); step=float(E('STEP','1.27')); n=int(round(rad/step)); rots=[float(r) for r in E('ROTS','0,90,180,270').split(',')]
    grid=np.full((len(rots),2*n+1,2*n+1),np.nan); cx0,cy0=M.S.centre(g); a0=M.S.a[g]
    for ri,da in enumerate(rots):
        for a in range(-n,n+1):
            for b in range(-n,n+1):
                d=M.try_move(g,a*step,b*step,da) if (a or b or da) else 0.0
                if d is not None: grid[ri,b+n,a+n]=d
    import matplotlib; matplotlib.use('Agg'); import matplotlib.pyplot as plt
    fig,axs=plt.subplots(1,len(rots),figsize=(5*len(rots),5),dpi=110)
    vmin=np.nanmin(grid); vmax=np.nanpercentile(grid,90)
    for ri,ax in enumerate(np.atleast_1d(axs)):
        im=ax.imshow(grid[ri],extent=(cx0-rad-step/2,cx0+rad+step/2,cy0+rad+step/2,cy0-rad-step/2),cmap='RdYlGn_r',vmin=vmin,vmax=vmax)
        ax.plot([cx0],[cy0],'k+',ms=14); ax.set_title(f'{ref} at {(a0+rots[ri]+180)%360-180:g} deg'+(' (now)' if rots[ri]==0 else ''))
        k=np.unravel_index(np.nanargmin(grid[ri]),grid[ri].shape) if np.isfinite(grid[ri]).any() else None
        if k: ax.plot([cx0+(k[1]-n)*step],[cy0+(k[0]-n)*step],'bo',mfc='none',ms=12)
        ax.set_xlabel('courtyard centre x (mm)'); ax.set_ylabel('y (mm)')
    fig.colorbar(im,ax=axs,shrink=0.8,label='cost change in mm (lower is better; blank = illegal; + = now; o = best)')
    fig.suptitle(f'{ref}: placement cost over legal positions (step {step} mm, congestion capacity not re-rasterised)')
    os.makedirs(out,exist_ok=True); fig.savefig(os.path.join(out,f'sweep_{ref}.png')); plt.close(fig)
    flat=[(grid[ri,b,a],(a-n)*step,(b-n)*step,rots[ri]) for ri in range(len(rots)) for b in range(2*n+1) for a in range(2*n+1) if np.isfinite(grid[ri,b,a])]
    flat.sort()
    print(f'{ref} centre ({cx0:.2f},{cy0:.2f}) rot {a0:g}; best positions (screen, then full with capacity):')
    for d,dx,dy,da in flat[:8]:
        f=M.try_move(g,dx,dy,da,check=False,full=True)
        print(f'  centre to ({cx0+dx:.2f},{cy0+dy:.2f}) at {(a0+da+180)%360-180:g} deg: {d:+.0f} mm (full {f:+.0f})')
    print('wrote',os.path.join(out,f'sweep_{ref}.png'))

def breakdown(M,g,dx,dy,da):
    """term changes of one move (committed, measured, undone)"""
    T0=M.terms(); M.commit(g,dx,dy,da); T1=M.terms(); M.commit(g,-dx,-dy,0); M.commit(g,0,0,-da)
    return {k:T1[k]-T0[k] for k in ('length','bends','xall','overflow','budget')}|{'vias':M.vias(T1)-M.vias(T0)}

def mode_moves(M,out):
    t=time.time(); cands=candidates(); res=[]
    for g in M.B.movable:
        b,_=best_move(M,g,cands)
        if b and b[0]<0: res.append((b[0],g)+b[1:])
    res.sort(); B=M.B; lines=['# best single moves (each on its own, from the input placement; gain in mm, one via = %g mm)'%VIAMM,'',
        '| part | move dx,dy mm | rotate | to | gain mm | track mm | bends | crossings | overflow | exp. vias |','|---|---|---|---|---|---|---|---|---|---|']
    for d,g,dx,dy,da in res[:int(E('TOP','25'))]:
        bd=breakdown(M,g,dx,dy,da)
        lines.append(f'| {B.parts[g].ref} | {dx:+.2f},{dy:+.2f} | +{da:g} | ({M.S.x[g]+dx:.2f},{M.S.y[g]+dy:.2f}) | {-d:.0f} | {bd["length"]:+.0f} | {bd["bends"]:+d} | {bd["xall"]:+.0f} | {bd["overflow"]:+.1f} | {bd["vias"]:+.1f} |')
    os.makedirs(out,exist_ok=True); open(os.path.join(out,'moves.md'),'w').write('\n'.join(lines)+'\n'); print('\n'.join(lines)); print(f'{time.time()-t:.0f} s')
    return res

def mode_swaps(M,out):
    B=M.B; bylib=collections.defaultdict(list)
    for g in B.movable: bylib[B.parts[g].lib].append(g)
    res=[]
    for lib,gs in bylib.items():
        if len(B.parts[gs[0]].pads)<3: continue      # passives: a swap is just a move of each
        for a in range(len(gs)):
            for b in range(a+1,len(gs)):
                d=swap_delta(M,gs[a],gs[b])
                if d is not None and d<0: res.append((d,gs[a],gs[b]))
    res.sort(); lines=['# best swaps (same footprint; cost change in mm)','','| swap | gain mm |','|---|---|']
    for d,a,b in res[:int(E('TOP','25'))]: lines.append(f'| {B.parts[a].ref} <-> {B.parts[b].ref} | {-d:.0f} |')
    os.makedirs(out,exist_ok=True); open(os.path.join(out,'swaps.md'),'w').write('\n'.join(lines)+'\n'); print('\n'.join(lines)); return res

def write_copy(M,src,dst,strip=True):
    """copy of src with every footprint at its model position/angle (pad, text and property angles follow); signal tracks
    and vias removed (KEEP nets stay) so the copy is a router bench"""
    s=open(src,encoding='utf-8').read(); n=len(s)
    def block_end(j):
        depth=0; q=False; k=j
        while k<n:
            c=s[k]
            if q:
                if c=='\\': k+=1
                elif c=='"': q=False
            elif c=='"': q=True
            elif c=='(': depth+=1
            elif c==')':
                depth-=1
                if depth==0: return k+1
            k+=1
    out=[]; i=0; idx=0; keep=set(E('KEEP','GND,+5V').split(','))
    nets={int(a):b for a,b in re.findall(r'\(net (\d+) "((?:[^"\\]|\\.)*)"\)',s)}
    pat=re.compile(r'\n\t\((footprint|segment|arc|via)\b')
    while True:
        m=pat.search(s,i)
        if not m: out.append(s[i:]); break
        j=m.start()+2; e=block_end(j); blk=s[j:e]
        if m.group(1)=='footprint':
            k=idx; idx+=1
            P=M.B.parts[k]; x,y,a=M.S.x[k],M.S.y[k],M.S.a[k]; da=a-P.a
            if abs(x-P.x)>1e-6 or abs(y-P.y)>1e-6 or abs(da)>1e-6:
                fa=f' {a:g}' if abs(a)>1e-9 else ''
                blk=re.sub(r'^(\(footprint "[^"]*"(?:\s|\n)*(?:\([^()]*\)\s*)*?)\(at [-\d.]+ [-\d.]+(?: [-\d.]+)?\)',
                           lambda mm:mm.group(1)+f'(at {x:.4f} {y:.4f}{fa})',blk,count=1)
                if abs(da)>1e-6:
                    def fix(mm):
                        ang=(float(mm.group(3)) if mm.group(3) else 0.0)+da; ang=(ang+180)%360-180
                        return f'{mm.group(1)}(at {mm.group(2)} {ang:g})'
                    blk=re.sub(r'(\n\t\t\((?:pad|fp_text|property)\b[^\n]*?(?:\n[^\n]*?)??)\(at ([-\d.]+ [-\d.]+)(?: ([-\d.]+))?\)',fix,blk)
            pm=pin_netmap(P)
            if pm:
                def padnet(mm):
                    pb=mm.group(0); num=re.match(r'\(pad "([^"]*)"',pb).group(1)
                    if num not in pm: return pb
                    nid=pm[num]; nn=nets.get(nid,'')
                    pat_=r'\(net \d+ "(?:[^"\\]|\\.)*"\)'
                    if not nid: return re.sub(r'\n\t\t\t'+pat_,'',pb,count=1)
                    if re.search(pat_,pb): return re.sub(pat_,f'(net {nid} "{nn}")',pb,count=1)
                    return re.sub(r'(\(layers [^\n]*)',lambda q:q.group(1)+f'\n\t\t\t(net {nid} "{nn}")',pb,count=1)
                blk=re.sub(r'\(pad "[^"]*"[^\n]*(?:\n\t\t\t[^\n]*)*',padnet,blk)
            out.append(s[i:j]+blk); i=e; continue
        nm=re.search(r'\(net (\d+)\)',blk)
        if (not strip) or (nm and nets.get(int(nm.group(1)),'') in keep): out.append(s[i:e]); i=e
        else: out.append(s[i:m.start()]); i=e
    assert idx==len(M.B.parts),(idx,len(M.B.parts))
    open(dst,'w',encoding='utf-8').write(''.join(out))

def pin_netmap(P):
    """after pin swaps: {pad number: net id} for every pad whose net changed (the pad now at a pin's original spot carries its net)"""
    spot={(round(p['olx'],3),round(p['oly'],3)):p['num'] for p in P.pads}; out={}
    for p in P.pads:
        if (round(p['lx'],3),round(p['ly'],3))==(round(p['olx'],3),round(p['oly'],3)): continue
        num=spot.get((round(p['lx'],3),round(p['ly'],3)))
        if num is not None: out[num]=p['net']
    return out

def _pinswap(M,i,a,b):
    P=M.B.parts[i]
    for ja,jb in zip(a,b):
        pa,pb=P.pads[ja],P.pads[jb]
        pa['lx'],pb['lx']=pb['lx'],pa['lx']; pa['ly'],pb['ly']=pb['ly'],pa['ly']
    M.S._pads(i)

def pin_swap_pass(M,log=print):
    """greedy pin swaps from the swap table (pinswap.py): every allowed pair is scored, then taken best first, each one
    re-scored just before it is committed; repeats until no swap gains PSMIN mm-equivalent. Returns the swaps taken."""
    import pinswap
    B=M.B; T=pinswap.table(B); done=[]; PSMIN=float(E('PSMIN','1.0'))
    for g in T:  # a pin the PLD leaves unused but the board ties to a net is not free
        if g['info'] is None: continue
        for sl,(k,nd) in list(g['info'].items()):
            if k=='free' and B.parts[g['i']].pads[sl[0]]['net'] and not B.netname.get(B.parts[g['i']].pads[sl[0]]['net'],'').startswith('unconnected-'):
                g['info'][sl]=('fixed',0)
    fixn=set(x for x in E('PSFIX','').split(',') if x)   # nets whose pins never move (the router passes the nets that already have copper)
    if fixn:
        for g in T:
            g['slots']=[sl for sl in g['slots'] if not any(B.netname.get(B.parts[g['i']].pads[j]['net'],'') in fixn for j in sl)]
    def nets_of(i,a,b):
        return sorted({B.parts[i].pads[j]['net'] for j in a+b}&set(B.nets))
    def score(g,a,b):
        i=g['i']; ns=nets_of(i,a,b)
        if not ns: return 0.0
        _pinswap(M,i,a,b)
        try: return M._delta([i],None,False,nets=ns)
        finally: _pinswap(M,i,a,b)
    if not T: log('pin-swap table is EMPTY: no schematic sheets / .pld files found (pinswap.py SCHDIR, PLDDIR)')
    log(f'pin-swap table: {len(T)} groups, '+', '.join(f"{g['ref']} {g['kind']} ({len(g['slots'])})" for g in T))
    for it in range(int(E('PSPASSES','4'))):
        cand=[]
        for g in T:
            for a,b in itertools.combinations(g['slots'],2):
                if not pinswap.can_swap(g,a,b): continue
                d=score(g,a,b)
                if d<-PSMIN: cand.append((d,id(g),g,a,b))
        cand.sort(key=lambda c:c[0]); took=0
        for _,_,g,a,b in cand:
            d=score(g,a,b)
            if d>=-PSMIN or not pinswap.can_swap(g,a,b): continue
            i=g['i']; ns=nets_of(i,a,b); _pinswap(M,i,a,b)
            for n in ns: M.netedges[n]=M._edges(M.S,n)
            M._rebuild(); M._bud0=M._budget_excess(M.S)
            g['pins'][a],g['pins'][b]=g['pins'][b],g['pins'][a]  # the pads (and their signals) moved; the pin numbers they sit on swap
            P=B.parts[i]; nm=lambda j:B.netname.get(P.pads[j]['net'],'-') or '-'
            done.append(dict(ref=g['ref'],kind=g['kind'],a=g['pins'][a],b=g['pins'][b],
                             nets_a='/'.join(nm(j) for j in b),nets_b='/'.join(nm(j) for j in a),gain=-d))
            took+=1
        T0=M.terms(); log(f'pass {it+1}: {len(cand)} candidates, {took} swaps, cost {M.cost(T0):.0f} vias {M.vias(T0):.0f} length {T0["length"]/1000:.2f} m')
        if not took: break
    return done

def pin_changes_md(M):
    """final pin assignment changes per part (a chain of greedy swaps collapses to one table row per pin)"""
    B=M.B; L=['| part | pin | was | now |','|---|---|---|---|']; nparts=npins=0
    for P in B.parts:
        pm=pin_netmap(P)
        if not pm: continue
        orig={p['num']:p['net'] for p in P.pads}; rows=[(k,orig.get(k,0),v) for k,v in pm.items() if orig.get(k,0)!=v]
        if not rows: continue
        nparts+=1; npins+=len(rows)
        for k,o,v in sorted(rows,key=lambda r:int(r[0]) if r[0].isdigit() else 0):
            L.append(f"| {P.ref} | {k} | {B.netname.get(o,'-') or '-'} | {B.netname.get(v,'-') or '-'} |")
    return [f'{npins} pins change on {nparts} parts.','']+L

def mode_pinswap(M,out):
    """pin swaps only (no part moves) on the board as it is: suggestions table + a router bench copy with the pad nets swapped"""
    os.makedirs(out,exist_ok=True); T0=M.terms(); c0=M.cost(T0)
    print(f'start: cost {c0:.0f}, vias {M.vias(T0):.0f}, length {T0["length"]/1000:.2f} m')
    done=pin_swap_pass(M); T1=M.terms()
    L=['# Pin-swap suggestions','',f'Board `{M.B.path}`. Model cost {c0:.0f} -> {M.cost(T1):.0f}, expected vias {M.vias(T0):.0f} -> {M.vias(T1):.0f}, '
       f'MST length {T0["length"]/1000:.2f} -> {T1["length"]/1000:.2f} m ({len(done)} greedy steps).','',
       'Suggestions only: each change needs the schematic (and for a PLD its PIN lines) changed and rechecked.','']
    L+=pin_changes_md(M)
    open(os.path.join(out,'pinswaps.md'),'w').write('\n'.join(L)+'\n')
    write_copy(M,M.B.path,os.path.join(out,'pinswapped.kicad_pcb'))
    print('\n'.join(L)); print(f'wrote {out}/pinswaps.md pinswapped.kicad_pcb')

def mode_optimize(M,out):
    """greedy: best legal move or swap of all parts, commit, repeat. Each part's best move is cached and only re-searched when
    a committed change shares a net with it or lands within NEAR mm; a cached move is re-checked in full before it is taken."""
    t=time.time(); B=M.B; rounds=int(E('ROUNDS','30')); ming=float(E('MINGAIN','5')); cands=candidates(); near=float(E('NEAR','25'))
    T0=M.terms(); c0=M.cost(T0); log=[]; arrows=[]
    print('start',fmt_terms(M,T0),flush=True)
    tabu=collections.Counter(); cache={}; swapc=None
    bylib=collections.defaultdict(list)
    for g in B.movable: bylib[B.parts[g].lib].append(g)
    swapsets=[gs for gs in bylib.values() if len(B.parts[gs[0]].pads)>=3 and len(gs)>1]
    def nets_of(g):
        s_=set()
        for i in B.members[g]: s_|=B.partnets[i]
        return s_
    for r in range(rounds):
        for g in B.movable:
            if tabu[g]>=3: cache[g]=None; continue
            if g not in cache:
                b,_=best_move(M,g,cands,verify=3); cache[g]=b
        if E('SWAPS','1')=='1' and swapc is None:
            swapc=[]
            for gs in swapsets:
                for a in range(len(gs)):
                    for bb in range(a+1,len(gs)):
                        d=swap_delta(M,gs[a],gs[bb])
                        if d is not None and d<0: swapc.append((d,gs[a],gs[bb]))
        opts=[(b[0],'move',g)+tuple(b[1:]) for g,b in cache.items() if b]+[(d,'swap',a,bb) for d,a,bb in (swapc or [])]
        opts.sort(); best=None
        for o in opts[:10]:
            if o[0]>-ming: break
            if o[1]=='move':
                d=M.try_move(o[2],o[3],o[4],o[5],check=True,full=True)
                if d is not None and d<=-ming: best=(d,)+o[1:]; break
                cache.pop(o[2],None)
            else:
                d=swap_delta(M,o[2],o[3])
                if d is not None and d<=-ming: best=(d,)+o[1:]; break
        if best is None: break
        if best[1]=='move':
            d,_,g,dx,dy,da=best; x0,y0=M.S.x[g],M.S.y[g]; c0_=M.S.centre(g); M.commit(g,dx,dy,da); tabu[g]+=1; moved=[g]
            msg=f'{B.parts[g].ref}: move {dx:+.2f},{dy:+.2f} mm, rotate +{da:g} -> ({M.S.x[g]:.2f},{M.S.y[g]:.2f}) rot {M.S.a[g]:g}'
            arrows.append(c0_+M.S.centre(g)+(B.parts[g].ref,))
        else:
            d,_,g,h=best; xg,yg,xh,yh=M.S.x[g],M.S.y[g],M.S.x[h],M.S.y[h]; cg_=M.S.centre(g); ch_=M.S.centre(h); swap_delta(M,g,h,commit=True); tabu[g]+=1; tabu[h]+=1; moved=[g,h]
            msg=f'swap {B.parts[g].ref} <-> {B.parts[h].ref}'; arrows+=[cg_+M.S.centre(g)+(B.parts[g].ref,),ch_+M.S.centre(h)+(B.parts[h].ref,)]
        # invalidate cached searches the change can affect
        mn=set(); pts=[]
        for m_ in moved: mn|=nets_of(m_); pts.append((M.S.x[m_],M.S.y[m_]))
        if best[1]=='move': pts.append((x0,y0))
        else: pts+=[(xg,yg),(xh,yh)]
        for k in list(cache):
            if k in moved or (nets_of(k)&mn) or min(math.dist((M.S.x[k],M.S.y[k]),p_) for p_ in pts)<near: cache.pop(k)
        swapc=None if any(m_ in gs for gs in swapsets for m_ in moved) or best[1]=='swap' else swapc
        T=M.terms(); log.append((msg,-d,T)); print(f'round {r+1}: {msg}  gain {-d:.0f} mm | {fmt_terms(M,T)}  ({time.time()-t:.0f} s)',flush=True)
    T1=M.terms(); os.makedirs(out,exist_ok=True)
    lines=['# placement suggestions (greedy, pads only)','',f'before: {fmt_terms(M,T0)}',f'after:  {fmt_terms(M,T1)}','',
           '| step | change | gain mm | expected vias after | length after m |','|---|---|---|---|---|']
    for k,(msg,gn,T) in enumerate(log): lines.append(f'| {k+1} | {msg} | {gn:.0f} | {M.vias(T):.0f} | {T["length"]/1000:.2f} |')
    open(os.path.join(out,'suggestions.md'),'w').write('\n'.join(lines)+'\n')
    write_copy(M,B.path,os.path.join(out,'placed.kicad_pcb'))
    draw(M,os.path.join(out,'suggestions.png'),'suggested moves (green arrows) over the new congestion map',arrows=arrows)
    json.dump([dict(change=m,gain=g) for m,g,_ in log],open(os.path.join(out,'suggestions.json'),'w'),indent=1)
    print('\n'.join(lines)); print(f'wrote {out}/suggestions.md suggestions.png placed.kicad_pcb  ({time.time()-t:.0f} s)')


# ------------------------------------------------------------------ placement from scratch
SCRATCH_FIXED=re.compile(E('SCRATCHFIXED',r'^(J|H|SW|LOGO|G|REF)\d*$'))

def set_centre(S,i,cx,cy,a,snap=0.635):
    """put part i with rotation a so that its courtyard centre is at cx,cy (origin snapped to the grid)"""
    S.a[i]=a; S.x[i]=0.0; S.y[i]=0.0; S._pads(i); c=S.boxes(i)[0]; ox=(c[0]+c[2])/2; oy=(c[1]+c[3])/2
    S.x[i]=round((cx-ox)/snap)*snap; S.y[i]=round((cy-oy)/snap)*snap; S._pads(i)

def global_place(B,S,mov,iters=None):
    """quadratic placement (star model per net, fixed pads as anchors) with SimPL-style spreading: each iteration the
    solution is spread over the free board area by recursive bisection and pulled toward the spread positions by
    pseudo-nets of growing weight. Pins sit at the part centres (rotation is not known yet). Returns {part: (x, y)}."""
    import scipy.sparse as sp, scipy.sparse.linalg as sla
    iters=int(E('GPITERS','25')) if iters is None else iters
    movi={i:k for k,i in enumerate(mov)}; nm=len(mov)
    nets=[n for n in B.nets if any(i in movi for i,j in B.nets[n])]
    nv=nm+len(nets)                         # one star node per net
    area=np.zeros(nm); fixedxy={}
    for k,i in enumerate(mov):
        c,es=S.boxes(i); bx=bbox([(c[0],c[1]),(c[2],c[3])]+[(e[0],e[1]) for e in es]+[(e[2],e[3]) for e in es])
        area[k]=(bx[2]-bx[0]+2*HALO)*(bx[3]-bx[1]+2*HALO)
    # free area raster (1 mm): inside the outline margin and outside fixed parts
    from matplotlib.path import Path
    from shapely.geometry import Polygon
    poly=Polygon(B.outline).buffer(-MARGIN-1.0,join_style=2); path=Path(np.array(poly.exterior.coords))
    gx=np.arange(B.bx0+0.5,B.bx1,1.0); gy=np.arange(B.by0+0.5,B.by1,1.0); XX,YY=np.meshgrid(gx,gy)
    free=path.contains_points(np.c_[XX.ravel(),YY.ravel()]).reshape(XX.shape)
    for i,P in enumerate(B.parts):
        if i in movi: continue
        c,es=S.boxes(i)
        for b in [c]+es:
            free&=~((XX>=b[0]-HALO)&(XX<=b[2]+HALO)&(YY>=b[1]-HALO)&(YY<=b[3]+HALO))
    fx_,fy_=XX[free],YY[free]
    def spread(px,py):
        out=np.zeros((nm,2))
        def rec(idx,mask_idx,depth):
            if len(idx)==0: return
            xs=fx_[mask_idx]; ys=fy_[mask_idx]
            if len(idx)==1 or len(xs)<4:
                out[idx,0]=xs.mean() if len(xs) else px[idx].mean(); out[idx,1]=ys.mean() if len(ys) else py[idx].mean(); return
            horiz=(xs.max()-xs.min())>=(ys.max()-ys.min())
            cc=px if horiz else py; ff=xs if horiz else ys
            o=idx[np.argsort(cc[idx])]; ca=np.cumsum(area[o]); half=np.searchsorted(ca,ca[-1]/2)+1; half=min(max(half,1),len(o)-1)
            frac=ca[half-1]/ca[-1]
            fo=np.argsort(ff); cut=int(round(frac*len(fo)))
            rec(o[:half],mask_idx[fo[:cut]],depth+1); rec(o[half:],mask_idx[fo[cut:]],depth+1)
        rec(np.arange(nm),np.arange(len(fx_)),0); return out
    cx0=(B.bx0+B.bx1)/2; cy0=(B.by0+B.by1)/2
    anchors=None; pos=None
    for it in range(iters+1):
        rows=[];cols=[];vals=[]; bx_=np.zeros(nv); by_=np.zeros(nv)
        def add(a,b,w):
            rows.extend([a,b,a,b]); cols.extend([a,b,b,a]); vals.extend([w,w,-w,-w])
        for k,n in enumerate(nets):
            star=nm+k; pins=B.nets[n]; w=1.0*len(pins)/(len(pins)-1)
            for i,j in pins:
                if i in movi: add(movi[i],star,w)
                else:
                    x,y=S.pad(i,j); rows.append(star); cols.append(star); vals.append(w); bx_[star]+=w*x; by_[star]+=w*y
        for k in range(nm):          # weak pull to the board centre keeps the system regular
            rows.append(k); cols.append(k); vals.append(1e-4); bx_[k]+=1e-4*cx0; by_[k]+=1e-4*cy0
        if anchors is not None:
            wa=float(E('ANCHORW','0.02'))*(1.6**it)
            for k in range(nm):
                rows.append(k); cols.append(k); vals.append(wa); bx_[k]+=wa*anchors[k,0]; by_[k]+=wa*anchors[k,1]
        A=sp.csr_matrix((vals,(rows,cols)),shape=(nv,nv))
        px=sla.spsolve(A.tocsc(),bx_)[:nm]; py=sla.spsolve(A.tocsc(),by_)[:nm]
        anchors=spread(px,py); pos=(px,py)
    return {i:(anchors[k,0],anchors[k,1]) for k,i in enumerate(mov)},{i:(pos[0][k],pos[1][k]) for k,i in enumerate(mov)}

def legalize(B,S,mov,target,followers):
    """greedy legalisation: big parts first, each at the legal spot and rotation (0/90/180/270) near its target that costs
    least (MST length + bends of its nets with unplaced parts at their targets, plus displacement); then each plane-only
    part (decoupling caps, GND/+5V test points) beside the nearest IC that has none yet"""
    from matplotlib.path import Path
    path=Path(B.outline); placed=[]
    for i in range(len(B.parts)):
        if i not in mov and i not in followers: placed.append(S.boxes(i))
    def clash(cb):
        c,es=cb
        if not path.contains_points([(c[0]-MARGIN,c[1]-MARGIN),(c[2]+MARGIN,c[1]-MARGIN),(c[2]+MARGIN,c[3]+MARGIN),(c[0]-MARGIN,c[3]+MARGIN)]).all(): return True
        for (pc,pes) in placed:
            if ovl(c,pc,HALO): return True
            if any(ovl(e,pc) for e in es) or any(ovl(e,c) for e in pes): return True
        return False
    # unplaced parts sit at their targets for the wirelength estimate
    for i in mov: set_centre(S,i,target[i][0],target[i][1],0.0)
    for i in followers: set_centre(S,i,(B.bx0+B.bx1)/2,(B.by0+B.by1)/2,0.0)
    fol=set(followers)
    def wl(i):
        t=0.0
        for n in B.partnets[i]:
            pts=[S.pad(a,b) for a,b in B.nets[n] if a not in fol]
            for x0,y0,x1,y1 in mst_edges(pts):
                dx=abs(x1-x0); dy=abs(y1-y0); t+=dx+dy+(VIAMM*0.5 if min(dx,dy)>ALIGN else 0)
        return t
    order=sorted(mov,key=lambda i:-(lambda c:(c[2]-c[0])*(c[3]-c[1]))(S.boxes(i)[0]))
    step=1.27; done=[]
    for i in order:
        tx,ty=target[i]; best=None
        for a in (0.0,90.0,180.0,270.0):
            if len(B.parts[i].pads)<=2 and a>=180: continue
            if ICROTS and len(B.parts[i].pads)>=8 and int(a)%360 not in ICROTS: continue
            found=0
            for r in range(0,80):
                ring=[(dx,dy) for dx in range(-r,r+1) for dy in range(-r,r+1) if max(abs(dx),abs(dy))==r]
                for dx,dy in ring:
                    set_centre(S,i,tx+dx*step,ty+dy*step,a)
                    cb=S.boxes(i)
                    if clash(cb): continue
                    c=wl(i)+float(E('DISPW','2.0'))*math.hypot(dx*step,dy*step)
                    if best is None or c<best[0]: best=(c,S.x[i],S.y[i],a)
                    found+=1
                if found>=6: break
        if best is None: raise SystemExit(f'no legal spot for {B.parts[i].ref}')
        S.x[i],S.y[i],S.a[i]=best[1],best[2],best[3]; S._pads(i); placed.append(S.boxes(i)); done.append(i)
    # followers next to ICs
    ics=[i for i in mov if B.parts[i].ref.startswith('U') and len(B.parts[i].pads)>=8]
    used=collections.Counter()
    for f in sorted(followers,key=lambda i:B.parts[i].ref):
        cand=sorted(ics,key=lambda u:(used[u],0))
        best=None
        for u in cand[:max(1,len([x for x in ics if used[x]==used[cand[0]]]))]:
            c=S.boxes(u)[0]; ux,uy=(c[0]+c[2])/2,(c[1]+c[3])/2
            for r in range(0,30):
                ok=None
                for dx in range(-r,r+1):
                    for dy in range(-r,r+1):
                        if max(abs(dx),abs(dy))!=r: continue
                        for a in (0.0,90.0):
                            set_centre(S,f,ux+dx*step,uy+dy*step,a)
                            if not clash(S.boxes(f)):
                                d=math.hypot(dx,dy)
                                if ok is None or d<ok[0]: ok=(d,S.x[f],S.y[f],a)
                if ok: break
            if ok and (best is None or ok[0]<best[0]): best=ok+(u,)
        if best is None: raise SystemExit(f'no spot for {B.parts[f].ref}')
        S.x[f],S.y[f],S.a[f]=best[1],best[2],best[3]; S._pads(f); placed.append(S.boxes(f)); used[best[4]]+=1

def mode_scratch(M,out):
    """placement from scratch: only SCRATCHFIXED parts (connectors, slots, cartridge, holes, switches, logo) keep their
    place; every chip and passive is placed by global_place + legalize without looking at its present position, then
    the result is written and refined by the optimizer (ROUNDS) on a fresh model of the written copy"""
    global FIXED_RE
    FIXED_RE=SCRATCH_FIXED                      # the refinement may move everything the scratch placement placed
    t=time.time(); B=M.B; S=M.S
    mov=[]; fol=[]
    pl={n for n,m in B.netname.items() if m in PLANES}
    for i,P in enumerate(B.parts):
        if SCRATCH_FIXED.match(P.ref): continue
        if all((p['net'] in pl) or not p['net'] for p in P.pads): fol.append(i)
        else: mov.append(i)
    for i in mov+fol: set_centre(S,i,(B.bx0+B.bx1)/2,(B.by0+B.by1)/2,0.0)   # forget the present placement
    print(f'scratch: {len(mov)} parts placed from the netlist, {len(fol)} plane-only parts follow the ICs, {len(B.parts)-len(mov)-len(fol)} fixed',flush=True)
    target,raw=global_place(B,S,mov); print(f'global placement {time.time()-t:.0f} s',flush=True)
    legalize(B,S,mov,target,fol); print(f'legalised {time.time()-t:.0f} s',flush=True)
    os.makedirs(out,exist_ok=True); p0=os.path.join(out,'scratch_legal.kicad_pcb'); write_copy(M,B.path,p0)
    M2=Model(p0); M2.ready(); T=M2.terms(); print('legal:',fmt_terms(M2,T),flush=True)
    draw(M2,os.path.join(out,'scratch_legal.png'),'from-scratch placement after legalisation')
    if int(E('ROUNDS','30'))>0: mode_optimize(M2,out)
    print(f'scratch done {time.time()-t:.0f} s')

# ------------------------------------------------------------------ rule-based constructive placement (Justin's rules)
def mode_rules(M,out):
    """Constructive placement from the netlist with Justin's rules (2026-11-09):
    1. a part whose nets go to one place sits at that place: passives (<= 3 pads) are placed outward-in from the fixed parts,
       packed tightly in banks of one orientation at the connector pins they serve (VGA ladder at J7, audio at J6, ...); passives
       that only reach other passives of a bank follow that bank;
    2. then the chip most connected to what is already placed goes next (the colour decoder after the VGA resistors, the audio
       register after the audio resistors), at the row position that is cheapest for its nets to the placed parts;
    3. chips on the same bus attract each other through their shared nets, so bus chips land side by side;
    5. outside in (Justin): the edge is the tight place, so every candidate pays CENTREW mm per mm of distance from the nearest
       board edge; the middle stays free for the wiring;
    4. chips are DIPs in rows (ROWPITCH, rotation ICROTS, default 90/270 = horizontal) with the decoupling cap at the pin-1 end;
       passives that serve a chip are placed right after it, next to its pins.
    Only SCRATCHFIXED parts keep their place. Writes OUT/rules.kicad_pcb (copy, signal tracks stripped) and a PNG; ROUNDS>0 then
    refines with optimize (moves only within RAD)."""
    global FIXED_RE, ICROTS
    FIXED_RE=SCRATCH_FIXED
    if not ICROTS: ICROTS={90,270}
    t=time.time(); B=M.B; S=M.S
    ROWP=float(E('ROWPITCH','19.05')); PHALO=float(E('PHALO','0.3')); CHALO=float(E('CHALO','1.0')); CENTREW=float(E('CENTREW','1.0'))
    def edge_d(i):
        c=S.boxes(i)[0]; return min(c[0]-B.bx0,B.bx1-c[2],c[1]-B.by0,B.by1-c[3])   # outside-in: distance to the nearest board edge
    pl={n for n,m in B.netname.items() if m in PLANES}
    fixed=[i for i,P in enumerate(B.parts) if SCRATCH_FIXED.match(P.ref)]
    fol=[]; chips=[]; pas=[]
    for i,P in enumerate(B.parts):
        if i in fixed: continue
        if all((p['net'] in pl) or not p['net'] for p in P.pads): fol.append(i)
        elif len(P.pads)<=3: pas.append(i)
        else: chips.append(i)
    caps=[i for i in fol if B.parts[i].ref.startswith('C')]; tps=[i for i in fol if i not in caps]
    # connection weight between parts: each net adds 1/(parts-1)
    W=collections.defaultdict(collections.Counter)
    for n,v in B.nets.items():
        ps={i for i,j in v}
        if len(ps)<2: continue
        for a in ps:
            for b in ps:
                if a!=b: W[a][b]+=1.0/(len(ps)-1)
    from matplotlib.path import Path
    path=Path(B.outline); placed=set(fixed); boxes=[]
    for i in fixed: boxes.append(S.boxes(i))
    BX=[]
    def rebuild():
        nonlocal BX
        BX=np.array([b[0] for b in boxes]); 
    EB=[]
    def clash(cb,halo):
        c,es=cb
        if not path.contains_points([(c[0]-MARGIN,c[1]-MARGIN),(c[2]+MARGIN,c[1]-MARGIN),(c[2]+MARGIN,c[3]+MARGIN),(c[0]-MARGIN,c[3]+MARGIN)]).all(): return True
        A=np.array([b[0] for b in boxes])
        if ((c[0]<A[:,2]+halo)&(A[:,0]<c[2]+halo)&(c[1]<A[:,3]+halo)&(A[:,1]<c[3]+halo)).any(): return True
        for b in boxes:
            if any(ovl(e,b[0]) for e in es) or any(ovl(e,c) for e in b[1]): return True
        return False
    off=(B.bx0-1000,B.by0-1000)
    for i in chips+pas+fol: S.x[i],S.y[i]=off; S._pads(i)      # forget the present placement
    def netcost(i):
        """MST length + bends of part i's nets over the pads of placed parts (and i)"""
        tcost=0.0
        for n in B.partnets[i]:
            pts=[S.pad(a,b) for a,b in B.nets[n] if a in placed or a==i]
            for x0,y0,x1,y1 in mst_edges(pts):
                dx=abs(x1-x0); dy=abs(y1-y0); tcost+=dx+dy+(VIAMM*M.K['KB'] if min(dx,dy)>ALIGN else 0)
        return tcost
    def put(i,cx,cy,a): set_centre(S,i,cx,cy,a)
    def place_near(i,tx,ty,rots,halo,maxr=60,need=8,step=1.27):
        best=None; found=0
        for r in range(0,maxr):
            for dx in range(-r,r+1):
                for dy in range(-r,r+1):
                    if max(abs(dx),abs(dy))!=r: continue
                    for a in rots:
                        put(i,tx+dx*step,ty+dy*step,a)
                        if clash(S.boxes(i),halo): continue
                        c=netcost(i)+0.5*math.hypot(dx*step,dy*step)+CENTREW*edge_d(i); found+=1
                        if best is None or c<best[0]: best=(c,S.x[i],S.y[i],a)
            if found>=need: break
        if best is None:
            if halo>0 or maxr<200:  # board too full for the halo: retry tight and wider
                print(f'  {B.parts[i].ref}: no spot with halo {halo}, retrying tight'); return place_near(i,tx,ty,rots,0.0,200,1,step)
            raise SystemExit(f'no spot for {B.parts[i].ref}')
        S.x[i],S.y[i],S.a[i]=best[1],best[2],best[3]; S._pads(i); placed.add(i); boxes.append(S.boxes(i))
    def pin_target(i):
        """centroid of the placed pads part i connects to"""
        pts=[S.pad(a,b) for n in B.partnets[i] for a,b in B.nets[n] if a in placed and a!=i]
        return (np.mean([p[0] for p in pts]),np.mean([p[1] for p in pts])) if pts else None
    log=[]
    def place_passives(level_from):
        """passives reachable from the given placed parts through passives only, nearest first (banks)"""
        todo=[i for i in pas if i not in placed and any(k in level_from for k in W[i])]
        while todo:
            todo.sort(key=lambda i:-sum(w for k,w in W[i].items() if k in placed))
            i=todo.pop(0)
            if i in placed: continue
            tg=pin_target(i)
            if tg is None: continue
            # bank orientation: the orientation of the passives already placed at the same home, else best of 0/90
            home=max((k for k in W[i] if k in placed),key=lambda k:W[i][k])
            mates=[k for k in pas if k in placed and home in W[k]]
            rots=[S.a[mates[0]]%360] if mates else [0.0,90.0]
            place_near(i,tg[0],tg[1],rots,PHALO,need=4); log.append(f'{B.parts[i].ref} at {B.parts[home].ref}')
            todo+= [k for k in pas if k not in placed and i in W[k] and k not in todo]
    place_passives(set(fixed))
    rows=np.arange(B.by0+MARGIN+8,B.by1-MARGIN-5,ROWP)
    capq=list(caps)
    while True:
        rest=[i for i in chips if i not in placed]
        if not rest: break
        att=lambda i:sum(w for k,w in W[i].items() if k in placed)
        i=max(rest,key=lambda i:(att(i),len(B.parts[i].pads)))
        P=B.parts[i]; dip='DIP' in P.lib
        tg=pin_target(i) or ((B.bx0+B.bx1)/2,(B.by0+B.by1)/2)
        if dip:
            best=None
            for ry in rows:
                if abs(ry-tg[1])>80: continue
                for xx in np.arange(B.bx0+MARGIN+2,B.bx1-MARGIN-2,2.54):
                    if abs(xx-tg[0])>110: continue
                    for a in sorted(ICROTS):
                        put(i,xx,ry,float(a))
                        c,_=S.boxes(i)
                        # room for the decap left of the chip (vertical cap, 1 mm gap)
                        if clash(((c[0]-5.0,c[1],c[2],c[3]),S.boxes(i)[1]),CHALO): continue
                        cc=netcost(i)+CENTREW*edge_d(i)
                        if best is None or cc<best[0]: best=(cc,S.x[i],S.y[i],float(a))
            if best is None: place_near(i,tg[0],tg[1],[float(a) for a in ICROTS],CHALO)
            else: S.x[i],S.y[i],S.a[i]=best[1],best[2],best[3]; S._pads(i); placed.add(i); boxes.append(S.boxes(i))
            if capq:
                k=capq.pop(0); c,_=S.boxes(i); put(k,c[0]-2.0,(c[1]+c[3])/2,90.0)
                if clash(S.boxes(k),0.0): place_near(k,c[0]-2.0,(c[1]+c[3])/2,[90.0,0.0],0.0,need=1)
                else: placed.add(k); boxes.append(S.boxes(k))
        else:
            place_near(i,tg[0],tg[1],[0.0,90.0,180.0,270.0],CHALO)
        log.append(f'{P.ref} ({att(i):.1f} links to placed)')
        place_passives({i})
    for i in [k for k in pas if k not in placed]:
        tg=pin_target(i) or ((B.bx0+B.bx1)/2,(B.by0+B.by1)/2); place_near(i,tg[0],tg[1],[0.0,90.0],PHALO,need=4)
    for k in capq+tps:
        place_near(k,(B.bx0+B.bx1)/2,(B.by0+B.by1)/2,[90.0,0.0],0.3,maxr=120,need=1)
    print(f'rules placement {time.time()-t:.0f} s; order: '+', '.join(l for l in log if l.startswith('U') or l.startswith('X') or l.startswith('K')),flush=True)
    os.makedirs(out,exist_ok=True); p0=os.path.join(out,'rules.kicad_pcb'); write_copy(M,B.path,p0)
    M2=Model(p0); M2.ready(); T=M2.terms(); print('rules:',fmt_terms(M2,T),flush=True)
    draw(M2,os.path.join(out,'rules.png'),'rule-based placement (from scratch)')
    if int(E('ROUNDS','0'))>0:
        # clean-up: any rotation is allowed now (Justin: turning a chip at the end of a bus can make sense), taken only when it pays
        ICROTS={int(float(a))%360 for a in E('REFINEROTS','0,90,180,270').split(',') if a}
        mode_optimize(M2,out)

def main():
    a=[x for x in sys.argv[1:] if '=' not in x]
    for x in sys.argv[1:]:
        if '=' in x: k,v=x.split('=',1); os.environ[k]=v
    if len(a)<2: print(__doc__); sys.exit(1)
    path,mode=a[0],a[1]; out=E('OUT','placeguide_out')
    if mode=='fit':
        M=Model(path,K=DEFAULT_K); M.ready(); mode_fit(M,a[2:] or [path],E('FITOUT',FITFILE)); return
    M=Model(path); M.ready()
    print(f'loaded {path}: {len(M.B.parts)} parts, {len(M.B.movable)} movable, {len(M.B.nets)} nets, {len(M.E)} connections ({M.t_load:.1f} s)')
    if mode=='report': mode_report(M,out)
    elif mode=='sweep': mode_sweep(M,a[2],out)
    elif mode=='moves': mode_moves(M,out)
    elif mode=='swaps': mode_swaps(M,out)
    elif mode=='optimize': mode_optimize(M,out)
    elif mode=='scratch': mode_scratch(M,out)
    elif mode=='rules': mode_rules(M,out)
    elif mode=='pinswap': mode_pinswap(M,out)
    else: print(__doc__); sys.exit(1)

if __name__=='__main__': main()

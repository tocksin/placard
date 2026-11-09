"""placeguide.py board.kicad_pcb [out_prefix] : placement guidance for routability. Never routes and never edits the board.
Estimates how hard the placement is to route from the pads and nets alone, explains where and why, and suggests component
moves (translation + rotation) that should make routing easier. Ignores existing copper for the estimate; when the board
has copper it is used to calibrate the model (how well the estimate predicts the copper and vias the router really made).
What the model treats as routing difficulty (GND/+5V are inner planes and do not count as wiring):
  - wirelength: rectilinear minimum spanning tree per net, critical nets weighted (WL).
  - congestion: RUDY (Spindler and Johannes, DATE 2007), each tree edge spreads its wire uniformly over its bounding box,
    per TILE mm tile; capacity is the two routing layers at the track pitch, minus pads and their clearance (UTIL of it usable).
  - via pressure: tree edges that need both axes (a bend, usually a layer change on a horizontal/vertical two-layer board) and
    crossings with other nets' edges; fitted against the real per-net via counts when the board has copper.
Moves: every free component is tried at positions within RADIUS mm on a STEP mm grid and in 4 rotations; a fast half-perimeter
filter keeps the best KEEP legal candidates, the full model scores those, and the best moves are applied in turn (in memory) for
ROUNDS rounds, so later suggestions build on the earlier ones. Legal = courtyard inside the board edge, clear of other courtyards
(same side, or either part through-hole), the edge keep-outs and the J8 pad field.
Held in place: locked footprints, references matching FIX (connectors, mounting holes, switches, relays, crystals by default)
and parts whose only nets are planes (decoupling capacitors: placement is electrical, not routing).
env: TILE=4  UTIL=0.6  CAPFLOOR=0.25  COEF=a,b,c (via model coefficients instead of fitting them to this board's copper)  STEP=2.54  RADIUS=12.7  KEEP=12  ROUNDS=4  MAXMOVES=25  MINGAIN=2 (mm-equivalent)  VIAMM=25 (mm of track worth one via)
     OVW=30 (mm-equivalent per unit of squared overflow)  CRIT=3 (weight of critical nets)  FIX=<regex>  ALLOW=<refs, comma list, only these move>
Outputs: report on stdout, <prefix>.svg (congestion map and arrows), <prefix>_moves.csv. Predictions are model estimates, not routed results."""
import sys, os, math, re, csv, time
import numpy as np
TOOLS=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,TOOLS)
from board import load, outline, rot
from sexpr import find, one
import rules
from shapely.geometry import Polygon, box
from shapely.prepared import prep
E=os.environ.get
src=sys.argv[1]; prefix=sys.argv[2] if len(sys.argv)>2 else os.path.splitext(os.path.basename(src))[0]+'_place'
T=float(E('TILE','4')); CAPFLOOR=float(E('CAPFLOOR','0.25')); UTIL=float(E('UTIL','0.6')); STEP=float(E('STEP','2.54')); RADIUS=float(E('RADIUS','12.7')); KEEP=int(E('KEEP','12'))
ROUNDS=int(E('ROUNDS','4')); MAXMOVES=int(E('MAXMOVES','25')); MINGAIN=float(E('MINGAIN','2')); VIAMM=float(E('VIAMM','25')); OVW=float(E('OVW','30')); CRITW=float(E('CRIT','3'))
FIX=re.compile(E('FIX',r'^(J|JP|H|SW|K|Y|LS|BT|TP|FID|MH|NT)\d')); ALLOW=set(filter(None,E('ALLOW','').split(',')))
PITCH=0.55; CLR=0.25; AXIS=1.0
CRIT={'STALL_IN','STALL_OUT','~{HSYNC}','~{VSYNC}','~{WE}','PIXEL_ENABLE','CLK','RUN'}
t0=time.time()
b,nets,fps,pads,edges=load(src)
bp=Polygon(outline(edges)); inner=prep(bp.buffer(-rules.EDGE)); bx0,by0,bx1,by1=bp.bounds
OX=math.floor(bx0)-T; OY=math.floor(by0)-T; NX=int((bx1-OX)/T)+2; NY=int((by1-OY)/T)+2
FX0,FX1,FY0,FY1=233.6,268.4,125.6,133.6   # J8 pad field (as gridcore)
keepouts=rules.hole_edge_keepouts(pads,bp,CLR)+[box(FX0,FY0,FX1,FY1)]
# ---- components
fpnode={}
for fp in find(b,'footprint'):
    ref=([p[2] for p in find(fp,'property') if p[1]=='Reference']+[t[2] for t in find(fp,'fp_text') if t[1]=='reference'])[0]
    fpnode[ref]=fp
def courtyard(fp):
    pts=[]
    for kind in ('fp_line','fp_rect','fp_arc','fp_circle','fp_poly'):
        for g in find(fp,kind):
            L=one(g,'layer')
            if not L or not str(L[1]).endswith('CrtYd'): continue
            for k in ('start','mid','end','center'):
                q=one(g,k)
                if q: pts.append((float(q[1]),float(q[2])))
            if kind=='fp_poly':
                pts+=[(float(q[1]),float(q[2])) for q in find(one(g,'pts'),'xy')]
            if kind=='fp_circle':
                c=one(g,'center'); e=one(g,'end'); r=math.hypot(float(e[1])-float(c[1]),float(e[2])-float(c[2]))
                pts+=[(float(c[1])+r,float(c[2])+r),(float(c[1])-r,float(c[2])-r)]
    return pts
idx={}; C=[]
for ref,x,y,a,lib in fps:
    fp=fpnode[ref]; locked=any(s=='locked' for s in fp[:4] if isinstance(s,str)) or (one(fp,'locked') is not None and one(fp,'locked')[1]=='yes')
    side='B' if one(fp,'layer')[1]=='B.Cu' else 'F'
    idx[ref]=len(C); C.append(dict(ref=ref,x=x,y=y,a=a,lib=lib,locked=locked,side=side,pads=[],crt=courtyard(fp),x0=x,y0=y))
P=[]
for p in pads:
    c=C[idx[p['ref']]]; p['ci']=idx[p['ref']]; p['i']=len(P); c['pads'].append(len(P)); P.append(p)
px=np.array([p['x'] for p in P]); py=np.array([p['y'] for p in P])
pw=np.array([max(abs(p['w']*math.cos(math.radians(p['ang'])))+abs(p['h']*math.sin(math.radians(p['ang']))),0.1) for p in P])+2*CLR
ph=np.array([max(abs(p['h']*math.cos(math.radians(p['ang'])))+abs(p['w']*math.sin(math.radians(p['ang']))),0.1) for p in P])+2*CLR
THRU=np.array([p['kind'] in ('thru_hole','np_thru_hole') for p in P]);
for c in C:
    c['tht']=bool(c['pads'] and THRU[c['pads']].any())
    if c['crt']:
        q=[rot(u,v,c['a']) for u,v in c['crt']]; c['ofs']=q
    else:
        s=[(px[i]-c['x'],py[i]-c['y']) for i in c['pads']] or [(0,0)]
        xs=[u for u,v in s]; ys=[v for u,v in s]; g=0.75; c['ofs']=[(min(xs)-g,min(ys)-g),(max(xs)+g,max(ys)+g)]
def aabb(ofs,cx,cy):
    xs=[cx+u for u,v in ofs]; ys=[cy+v for u,v in ofs]; return min(xs),min(ys),max(xs),max(ys)
for c in C: c['box']=aabb(c['ofs'],c['x'],c['y'])
CX0=np.array([c['box'][0] for c in C]); CY0=np.array([c['box'][1] for c in C]); CX1=np.array([c['box'][2] for c in C]); CY1=np.array([c['box'][3] for c in C])
CSIDE=np.array([c['side']=='F' for c in C]); CTHT=np.array([c['tht'] for c in C])
# ---- nets
netpads={}
for p in P:
    if p['net'] and p['netname'] not in rules.PLANE_NETS and not p['netname'].startswith('unconnected'): netpads.setdefault(p['net'],[]).append(p['i'])
netpads={n:np.array(v) for n,v in netpads.items() if len(v)>=2}
netw={n:(CRITW if nets[n] in CRIT else 1.0) for n in netpads}
def plane_only(c): return all(P[i]['netname'] in rules.PLANE_NETS or not P[i]['net'] for i in c['pads'])
for c in C:
    c['free']=not (c['locked'] or FIX.match(c['ref']) or plane_only(c) or not c['pads'])
    if ALLOW: c['free']=c['free'] and c['ref'] in ALLOW
    c['nets']=sorted({P[i]['net'] for i in c['pads'] if P[i]['net'] in netpads})
def mst(n):
    """rectilinear MST of the net's pads (Prim); returns edge array (x0,y0,x1,y1), one row per edge"""
    ii=netpads[n]; x=px[ii]; y=py[ii]; m=len(ii)
    d=np.abs(x-x[0])+np.abs(y-y[0]); par=np.zeros(m,int); inn=np.zeros(m,bool); inn[0]=True; out=np.zeros((m-1,4))
    for k in range(m-1):
        dd=d.copy(); dd[inn]=np.inf; j=int(dd.argmin()); out[k]=(x[par[j]],y[par[j]],x[j],y[j]); inn[j]=True
        nd=np.abs(x-x[j])+np.abs(y-y[j]); upd=nd<d; d[upd]=nd[upd]; par[upd]=j
    return out
def frac(a0,a1,org,n):
    """tile range overlapped by [a0,a1] and the overlap length in each tile"""
    i0=max(0,int(math.floor((a0-org)/T))); i1=min(n,int(math.ceil((a1-org)/T)))
    if i1<=i0: return 0,0,None
    lo=org+np.arange(i0,i1)*T
    return i0,i1,np.clip(np.minimum(a1,lo+T)-np.maximum(a0,lo),0,None)
def rudy(D,E_,sign):
    for x0,y0,x1,y1 in E_:
        dx=abs(x1-x0); dy=abs(y1-y0); L=dx+dy
        if L<=0: continue
        bw=max(dx,T); bh=max(dy,T); cx=(x0+x1)/2; cy=(y0+y1)/2
        a,a2,fx=frac(cx-bw/2,cx+bw/2,OX,NX); b_,b2,fy=frac(cy-bh/2,cy+bh/2,OY,NY)
        if fx is None or fy is None: continue
        D[b_:b2,a:a2]+=sign*(L/(bw*bh))*np.outer(fy,fx)
def blockage(B,idxs,dx,dy,sign,rotate=None):
    for i in idxs:
        x=px[i]+dx; y=py[i]+dy; w=pw[i]; h=ph[i]
        a,a2,fx=frac(x-w/2,x+w/2,OX,NX); b_,b2,fy=frac(y-h/2,y+h/2,OY,NY)
        if fx is None or fy is None: continue
        B[b_:b2,a:a2]+=sign*(2 if THRU[i] else 1)*np.outer(fy,fx)
# outside-board area per tile (fixed, both layers)
Bfix=np.zeros((NY,NX));
for j in range(NY):
    for i in range(NX):
        if not bp.contains(box(OX+i*T,OY+j*T,OX+(i+1)*T,OY+(j+1)*T)):
            Bfix[j,i]=2*T*T*(1-bp.intersection(box(OX+i*T,OY+j*T,OX+(i+1)*T,OY+(j+1)*T)).area/(T*T))
NOMCAP=2*T*T/PITCH*UTIL
def cap(B): return np.maximum((2*T*T-Bfix-B)/PITCH*UTIL,CAPFLOOR*NOMCAP)   # a tile full of pads still passes some wiring (between and around pins)
def overflow(D,B): return float((np.clip(D/cap(B)-1,0,None)**2).sum())
# ---- via model
def nonaxis(e): return int(((np.abs(e[:,2]-e[:,0])>AXIS)&(np.abs(e[:,3]-e[:,1])>AXIS)).sum())
def crossings(A,Bx):
    """number of pairs (edge of A, edge of Bx) whose straight lines cross properly"""
    if len(A)==0 or len(Bx)==0: return 0
    ax=A[:,0:1]; ay=A[:,1:2]; bx=A[:,2:3]; by=A[:,3:4]; cx=Bx[:,0][None]; cy=Bx[:,1][None]; dx=Bx[:,2][None]; dy=Bx[:,3][None]
    def o(px_,py_,qx,qy,rx,ry): return (qx-px_)*(ry-py_)-(qy-py_)*(rx-px_)
    a=o(ax,ay,bx,by,cx,cy); b2=o(ax,ay,bx,by,dx,dy); c=o(cx,cy,dx,dy,ax,ay); d=o(cx,cy,dx,dy,bx,by)
    return int(((a*b2<0)&(c*d<0)).sum())
state={n:mst(n) for n in netpads}
wl_of=lambda e: float(np.abs(e[:,2]-e[:,0]).sum()+np.abs(e[:,3]-e[:,1]).sum())
def all_edges(skip=()):
    arr=[state[n] for n in netpads if n not in skip]
    return np.vstack(arr) if arr else np.zeros((0,4))
D=np.zeros((NY,NX)); B=np.zeros((NY,NX))
for n,e in state.items(): rudy(D,e,1)
blockage(B,range(len(P)),0,0,1)
# ---- calibration against existing copper
A_NON=0.45; A_CROSS=0.10; INTER=0.0
segs=find(b,'segment'); vias=find(b,'via'); calib=None
rt_nets={n for n in netpads}
if segs:
    actual=np.zeros((NY,NX))
    nvia={n:0 for n in netpads}
    for s in segs:
        if int(one(s,'net')[1]) not in rt_nets: continue
        x0,y0=map(float,one(s,'start')[1:3]); x1,y1=map(float,one(s,'end')[1:3]); L=math.hypot(x1-x0,y1-y0)
        for k in range(max(1,int(L/T)+1)):
            t=(k+.5)/max(1,int(L/T)+1); i=int((x0+(x1-x0)*t-OX)/T); j=int((y0+(y1-y0)*t-OY)/T)
            if 0<=i<NX and 0<=j<NY: actual[j,i]+=L/max(1,int(L/T)+1)
    for v in vias:
        n=int(one(v,'net')[1])
        if n in nvia: nvia[n]+=1
    mask=Bfix<T*T
    r_tile=float(np.corrcoef(D[mask],actual[mask])[0,1])
    X=[];y=[];names=[]
    for n in netpads:
        e=state[n]; X.append([nonaxis(e),crossings(e,all_edges(skip=(n,))),1.0]); y.append(nvia[n]); names.append(n)
    X=np.array(X,float); y=np.array(y,float); FIXED=E('COEF'); coef=np.array([float(v) for v in FIXED.split(',')]) if FIXED else np.linalg.lstsq(X,y,rcond=None)[0]; pred=X@coef
    r_via=float(np.corrcoef(pred,y)[0,1])
    calib=dict(r_tile=r_tile,r_via=r_via,coef=coef.tolist(),total=int(y.sum()),pred=float(pred.sum()),fixed=bool(FIXED))
    if coef[0]>0 and coef[1]>0: A_NON,A_CROSS,INTER=float(coef[0]),float(coef[1]),float(coef[2])
def cross_total():
    arrs=[state[n] for n in netpads]; t=0
    E_=np.vstack(arrs); t=crossings(E_,E_)//2   # includes same-net pairs (tree edges rarely cross)
    return t
def summary():
    wl=sum(netw[n]*wl_of(state[n]) for n in netpads); rawwl=sum(wl_of(state[n]) for n in netpads)
    na=sum(nonaxis(state[n]) for n in netpads); cr=cross_total(); ov=overflow(D,B)
    return dict(wl=wl,rawwl=rawwl,nonaxis=na,cross=cr,over=ov,vias=A_NON*na+A_CROSS*cr*2+INTER*len(netpads),cost=wl+VIAMM*(A_NON*na+A_CROSS*cr*2)+OVW*ov)
# ---- moves
GRID=np.arange(-int(RADIUS/STEP),int(RADIUS/STEP)+1)*STEP
def legal(i,bx):
    x0,y0,x1,y1=bx
    hit=(CX0<x1)&(CX1>x0)&(CY0<y1)&(CY1>y0); hit[i]=False
    c=C[i]; conf=(CSIDE==(c['side']=='F'))|CTHT|c['tht']
    if (hit&conf).any(): return False
    g=box(x0,y0,x1,y1)
    return inner.contains(g) and not any(k.intersects(g) for k in keepouts)
def pad_offsets(c,da):
    if da==0: return None
    r=[rot(px[i]-c['x'],py[i]-c['y'],da) for i in c['pads']]
    return np.array([c['x']+u for u,v in r])-px[c['pads']],np.array([c['y']+v for u,v in r])-py[c['pads']]
def rot_ofs(ofs,da):
    return [rot(u,v,da) for u,v in ofs] if da else ofs
def candidates(i):
    """legal candidates by half-perimeter wirelength: list of (hp_delta,dx,dy,da)"""
    c=C[i]; own=c['pads']; ownset=set(own); cand=[]
    data=[]
    for n in c['nets']:
        ii=netpads[n]; mine=np.array([k for k,v in enumerate(ii) if v in ownset],int); oth=np.array([k for k,v in enumerate(ii) if v not in ownset],int)
        if len(oth): ox0,ox1,oy0,oy1=px[ii[oth]].min(),px[ii[oth]].max(),py[ii[oth]].min(),py[ii[oth]].max()
        else: ox0=ox1=oy0=oy1=None
        data.append((n,ii[mine],ox0,ox1,oy0,oy1))
    def hp(dx,dy,oo):
        tot=np.zeros(np.shape(dx))
        pos={int(k):v for v,k in enumerate(own)}
        for n,mine,ox0,ox1,oy0,oy1 in data:
            mx=px[mine]+(oo[0][[pos[int(k)] for k in mine]] if oo else 0); my=py[mine]+(oo[1][[pos[int(k)] for k in mine]] if oo else 0)
            if ox0 is None: continue
            x0=np.minimum(ox0,mx.min()+dx); x1=np.maximum(ox1,mx.max()+dx); y0=np.minimum(oy0,my.min()+dy); y1=np.maximum(oy1,my.max()+dy)
            tot+=netw[n]*((x1-x0)+(y1-y0))
        return tot
    base=float(hp(np.zeros(1),np.zeros(1),None)[0])
    DX,DY=np.meshgrid(GRID,GRID)
    for da in (0,90,180,270):
        oo=pad_offsets(c,da); h=hp(DX,DY,oo)-base
        for k in np.argsort(h,axis=None):
            j=int(k); dx=float(DX.flat[j]); dy=float(DY.flat[j])
            if da==0 and dx==0 and dy==0: continue
            cand.append((float(h.flat[j]),dx,dy,da))
    cand.sort(); out=[]
    ro={}
    for h,dx,dy,da in cand[:400]:
        if da not in ro: ro[da]=rot_ofs(c['ofs'],da)
        if legal(i,aabb(ro[da],c['x']+dx,c['y']+dy)): out.append((h,dx,dy,da))
        if len(out)>=KEEP: break
    return out
def evaluate(i,dx,dy,da):
    """full model on a candidate; returns (gain, dWL, dNonAxis, dCross, dOver) and leaves the state unchanged"""
    c=C[i]; own=np.array(c['pads']); oo=pad_offsets(c,da)
    ax=dx+(oo[0] if oo else 0); ay=dy+(oo[1] if oo else 0)
    affected=c['nets']; old={n:state[n] for n in affected}
    rest=all_edges(skip=affected)
    wl0=sum(netw[n]*wl_of(old[n]) for n in affected); na0=sum(nonaxis(old[n]) for n in affected); cr0=sum(crossings(old[n],rest) for n in affected)
    D2=D.copy(); B2=B.copy(); blockage(B2,own,0,0,-1)
    px[own]+=ax; py[own]+=ay
    try:
        blockage(B2,own,0,0,1)
        new={n:mst(n) for n in affected}
        wl1=sum(netw[n]*wl_of(new[n]) for n in affected); na1=sum(nonaxis(new[n]) for n in affected); cr1=sum(crossings(new[n],rest) for n in affected)
    finally:
        px[own]-=ax; py[own]-=ay
    for n in affected: rudy(D2,old[n],-1); rudy(D2,new[n],1)
    ov0=overflow(D,B); ov1=overflow(D2,B2)
    gain=(wl0-wl1)+VIAMM*(A_NON*(na0-na1)+2*A_CROSS*(cr0-cr1))+OVW*(ov0-ov1)   # a crossing counts for both nets in the per-net fit
    return gain,wl0-wl1,na0-na1,cr0-cr1,ov0-ov1
def apply(i,dx,dy,da):
    c=C[i]; own=np.array(c['pads']); oo=pad_offsets(c,da)
    ax=dx+(oo[0] if oo else 0); ay=dy+(oo[1] if oo else 0)
    blockage(B,own,0,0,-1)
    for n in c['nets']: rudy(D,state[n],-1)
    px[own]+=ax; py[own]+=ay
    blockage(B,own,0,0,1)
    for n in c['nets']:
        state[n]=mst(n); rudy(D,state[n],1)
    c['x']+=dx; c['y']+=dy; c['a']=(c['a']+da)%360; c['ofs']=rot_ofs(c['ofs'],da); c['box']=aabb(c['ofs'],c['x'],c['y'])
    CX0[i],CY0[i],CX1[i],CY1[i]=c['box']
# ---- report
s0=summary(); print(f'{src}: {len(C)} components ({sum(c["free"] for c in C)} free to move), {len(netpads)} signal nets, {len(P)} pads; {NX}x{NY} tiles of {T} mm')
print('\nWHAT THE MODEL READS (placement only, existing copper ignored)')
print(f'  wirelength (MST): {s0["rawwl"]/1000:.2f} m; edges needing both axes: {s0["nonaxis"]}; edge crossings: {s0["cross"]}; overflow: {s0["over"]:.1f}; tiles over capacity: {int((D/cap(B)>1).sum())}')
if calib:
    print('\nCALIBRATION AGAINST THE COPPER ON THIS BOARD')
    print(f'  congestion estimate vs real copper per tile: r = {calib["r_tile"]:.2f}')
    print(f'  via model vs real vias per net: r = {calib["r_via"]:.2f} ({"coefficients given, not fitted here" if calib["fixed"] else "fitted on this board"}; real signal-net vias {calib["total"]}, model {calib["pred"]:.0f}); vias per net = {calib["coef"][0]:.2f}*two-axis edges + {calib["coef"][1]:.3f}*crossings + {calib["coef"][2]:.2f}')
else: print('\n(no copper on this board: default via weights used)')
def tileref(i,j): return f'({OX+(i+.5)*T:.0f},{OY+(j+.5)*T:.0f})'
R=D/cap(B); oo=np.argsort(-R,axis=None)[:8]
print('\nHOTTEST TILES (demand / capacity)')
for k in oo:
    j,i=np.unravel_index(int(k),R.shape); print(f'  {tileref(i,j)} mm: {R[j,i]:.2f}')
cscore=[]
for i,c in enumerate(C):
    if not c['pads']: continue
    v=[]
    for k in c['pads']:
        ii=int((px[k]-OX)/T); jj=int((py[k]-OY)/T)
        if 0<=ii<NX and 0<=jj<NY: v.append(R[jj,ii])
    if v: cscore.append((max(v),np.mean(v),c['ref'],len(c['pads']),c['free']))
print('\nCOMPONENTS IN THE MOST CONGESTED AREAS (peak, mean demand/capacity at their pads)')
for pk,mn,ref,np_,fr in sorted(cscore,reverse=True)[:10]:
    print(f'  {ref:6s} {np_:3d} pads  peak {pk:.2f} mean {mn:.2f}{"" if fr else "  (held)"}')
init={c['ref']:(c['x'],c['y'],c['a']) for c in C}
moves=[]; tt=time.time()
for rnd in range(ROUNDS):
    best=[]
    for i,c in enumerate(C):
        if not c['free'] or not c['nets']: continue
        b_=None
        for h,dx,dy,da in candidates(i):
            r=evaluate(i,dx,dy,da)
            if b_ is None or r[0]>b_[0][0]: b_=(r,dx,dy,da)
        if b_ and b_[0][0]>MINGAIN: best.append((b_[0][0],i,b_))
    best.sort(key=lambda t:-t[0]); applied=0
    for g,i,(r,dx,dy,da) in best:
        if len(moves)>=MAXMOVES: break
        c=C[i]; ro=rot_ofs(c['ofs'],da)
        if not legal(i,aabb(ro,c['x']+dx,c['y']+dy)): continue
        rr=evaluate(i,dx,dy,da)
        if rr[0]<=MINGAIN: continue
        apply(i,dx,dy,da); moves.append(dict(rnd=rnd,ref=c['ref'],dx=dx,dy=dy,da=da,gain=rr[0],dwl=rr[1],dna=rr[2],dcr=rr[3],dov=rr[4])); applied+=1
    print(f'round {rnd}: {len(best)} parts with a gain, {applied} moves applied, {time.time()-tt:.0f} s',flush=True)
    if not applied or len(moves)>=MAXMOVES: break
s1=summary()
print('\nSUGGESTED MOVES (in order; each builds on the ones before it; last four columns are savings, positive = better)')
print(f'  {"#":>2} {"ref":6s} {"from x,y,rot":>20s}  {"to x,y,rot":>20s}  {"gain":>6s}  {"track":>7s}  {"2-axis":>6s}  {"cross":>5s}  {"overflow":>8s}')
pos=dict(init); rows=[]
for k,m in enumerate(moves):
    f=pos[m['ref']]; t_=(f[0]+m['dx'],f[1]+m['dy'],(f[2]+m['da'])%360); pos[m['ref']]=t_
    print(f'  {k+1:2d} {m["ref"]:6s} {f[0]:8.2f},{f[1]:7.2f},{f[2]:3.0f}  {t_[0]:8.2f},{t_[1]:7.2f},{t_[2]:3.0f}  {m["gain"]:6.0f}  {m["dwl"]:+7.1f}  {m["dna"]:+6d}  {m["dcr"]:+5d}  {m["dov"]:+8.2f}')
    rows.append(dict(order=k+1,ref=m['ref'],fromX=f[0],fromY=f[1],fromRot=f[2],toX=t_[0],toY=t_[1],toRot=t_[2],gain=round(m['gain'],1),trackSavedMm=round(m['dwl'],1),twoAxisEdgesSaved=m['dna'],crossingsSaved=m['dcr'],overflowSaved=round(m['dov'],2)))
print('\nPREDICTED BOARD AFTER ALL MOVES (model estimate, not a routed result)')
for k,lab,fmt in (('rawwl','wirelength mm','{:.0f}'),('nonaxis','two-axis edges','{:d}'),('cross','crossings','{:d}'),('over','overflow','{:.1f}')):
    print(f'  {lab:16s} {fmt.format(s0[k])} -> {fmt.format(s1[k])}')
print(f'  via estimate     {s0["vias"]:.0f} -> {s1["vias"]:.0f}  (signal nets)')
print(f'  {time.time()-t0:.0f} s')
with open(prefix+'_moves.csv','w',newline='',encoding='utf-8') as f:
    w=csv.DictWriter(f,fieldnames=['order','ref','fromX','fromY','fromRot','toX','toY','toRot','gain','trackSavedMm','twoAxisEdgesSaved','crossingsSaved','overflowSaved']); w.writeheader(); w.writerows(rows)
# ---- map: congestion of the original placement is not kept, so the map shows the state after the moves plus arrows from the old positions
S=8; R=D/cap(B); out=[f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {NX*S} {NY*S}" width="{NX*S}" height="{NY*S}"><rect width="100%" height="100%" fill="white"/>']
for j in range(NY):
    for i in range(NX):
        if Bfix[j,i]>=2*T*T*.99: continue
        v=min(1.0,float(R[j,i])/1.5); r_=255; g_=int(255-200*v); b__=int(255-235*v) if v>.3 else int(255-120*v)
        out.append(f'<rect x="{i*S}" y="{j*S}" width="{S}" height="{S}" fill="rgb({r_},{g_},{b__})"/>')
sx=lambda x:(x-OX)/T*S; sy=lambda y:(y-OY)/T*S
for c in C:
    x0,y0,x1,y1=c['box']; col='#1a5' if c['free'] else '#888'
    out.append(f'<rect x="{sx(x0):.1f}" y="{sy(y0):.1f}" width="{(x1-x0)/T*S:.1f}" height="{(y1-y0)/T*S:.1f}" fill="none" stroke="{col}" stroke-width="0.6"/>')
for ref,t_ in pos.items():
    f=init[ref]
    if f[:2]!=t_[:2] or f[2]!=t_[2]:
        out.append(f'<line x1="{sx(f[0]):.1f}" y1="{sy(f[1]):.1f}" x2="{sx(t_[0]):.1f}" y2="{sy(t_[1]):.1f}" stroke="#03c" stroke-width="1.2"/><circle cx="{sx(t_[0]):.1f}" cy="{sy(t_[1]):.1f}" r="2" fill="#03c"/><text x="{sx(t_[0])+3:.1f}" y="{sy(t_[1])-3:.1f}" font-size="9" fill="#024">{ref}</text>')
out.append('</svg>')
open(prefix+'.svg','w',encoding='utf-8').write('\n'.join(out))
print(f'wrote {prefix}_moves.csv and {prefix}.svg')

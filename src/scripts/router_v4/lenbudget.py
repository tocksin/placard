"""lenbudget.py : track-length budgets on the router grid (used by lenfix.py, tidy.py, mroute4.py with BUDGET=file).
Budgets come from budgets.py (JSON, "max": {net: {from_pad: {to_pad: mm}}}). The length of a pair is the shortest path
along the net's copper on the grid (track cells 8-connected, G or G*sqrt2 per step, free inside the net's pads, vias and
through-hole pads join the layers at no length), the same measure as the timing tool (tracklen.py) up to the grid step."""
import json, math, os
import numpy as np
from scipy.sparse import coo_matrix
from scipy.sparse.csgraph import dijkstra
from scipy.ndimage import binary_dilation
import gridcore
from gridcore import LAY, VD, _disk
from board import pad_poly
SCALE=float(os.environ.get('LENSCALE','1.02'))   # grid lengths run 1-3 % short of tracklen.py (free pad interiors, via disks)
class Budgets:
    def __init__(self,g,path,slack_mm=0.0):
        self.g=g; J=json.load(open(path,encoding='utf-8')); self.src=path
        self.pairs={}   # net id -> list of (from_pad, to_pad, max_mm)
        for net,fr in J.get('max',{}).items():
            n=g.nid.get(net)
            if n is None: continue
            for a,tos in fr.items():
                for b,mm in tos.items(): self.pairs.setdefault(n,[]).append((a,b,float(mm)+slack_mm))
        self.padinfo={f"{p['ref']}-{p['num']}":p for p in g.pads}; self._pc={}
    def nets(self): return [n for n in self.pairs if n in self.g.scope]
    def pad_cells(self,name):
        if name in self._pc: return self._pc[name]
        p=self.padinfo[name]; g=self.g; j0,i0,m=g.raster(pad_poly(p))
        lay=[l for l,L in enumerate(LAY) if '*.Cu' in p['layers'] or L in p['layers']]
        if m.size==0:   # tiny pad: its centre cell
            iy=int(round((p['y']-g.oy)/gridcore.G)); ix=int(round((p['x']-g.ox)/gridcore.G)); j0,i0,m=iy,ix,np.ones((1,1),bool)
        self._pc[name]=(j0,i0,m,lay); return self._pc[name]
    def copper(self,n):
        """per-layer copper masks of net n (fixed copper + routes, via disks) and the layer-joining cells"""
        g=self.g; g.components(n); masks=[m.copy() for m in g.last_copper]
        vc=np.zeros((g.ny,g.nx),bool)
        for path in g.routes.get(n,[]):
            for i,(l,iy,ix) in enumerate(path):
                if i and path[i-1][0]!=l: vc[iy,ix]=True
        thru=g.thru.copy()
        if vc.any(): thru|=binary_dilation(vc,_disk(VD/2/gridcore.G))
        return masks,thru
    def lengths(self,n,pairs=None,dist_maps=False):
        """{(a,b): mm or None}; with dist_maps also {a: (dist array [2,ny,nx] in mm, inf off copper)}"""
        g=self.g; G=gridcore.G; pairs=self.pairs.get(n,[]) if pairs is None else pairs
        if not pairs: return ({},{}) if dist_maps else {}
        masks,thru=self.copper(n)
        ys,xs=np.nonzero(masks[0]|masks[1])
        if len(ys)==0: return ({(a,b):None for a,b,_ in pairs},{}) if dist_maps else {(a,b):None for a,b,_ in pairs}
        j0,j1,i0,i1=ys.min(),ys.max()+1,xs.min(),xs.max()+1; h,w=j1-j0,i1-i0
        sub=[m[j0:j1,i0:i1] for m in masks]; th=thru[j0:j1,i0:i1]
        padm=np.zeros((2,h,w),bool)
        names={x for a,b,_ in pairs for x in (a,b)}|{f"{p['ref']}-{p['num']}" for p in g.pads if p['net']==n}
        for nm in names:
            if nm not in self.padinfo: continue
            pj,pi,m,lay=self.pad_cells(nm)
            if m.size==0: continue
            a0=max(pj,j0); a1=min(pj+m.shape[0],j1); b0=max(pi,i0); b1=min(pi+m.shape[1],i1)
            if a1<=a0 or b1<=b0: continue
            for l in lay: padm[l,a0-j0:a1-j0,b0-i0:b1-i0]|=m[a0-pj:a1-pj,b0-pi:b1-pi]
        idx=-np.ones((2,h,w),np.int64); cnt=0
        for l in range(2):
            k=int(sub[l].sum()); idx[l][sub[l]]=np.arange(cnt,cnt+k); cnt+=k
        R=[];C=[];W=[]
        for l in range(2):
            m=sub[l]; P=padm[l]
            for dy,dx,wt in ((0,1,G),(1,0,G),(1,1,G*math.sqrt(2)),(1,-1,G*math.sqrt(2))):
                ya=slice(0,h-dy); yb=slice(dy,h)
                xa=slice(max(0,-dx),w-max(0,dx)); xb=slice(max(0,dx),w-max(0,-dx) if dx<0 else w)
                if dx<0: xa=slice(1,w); xb=slice(0,w-1)
                both=m[ya,xa]&m[yb,xb]
                if not both.any(): continue
                u=idx[l][ya,xa][both]; v=idx[l][yb,xb][both]
                free=(P[ya,xa]&P[yb,xb])[both]
                R.append(u); C.append(v); W.append(np.where(free,1e-6,wt))
        jn=th&sub[0]&sub[1]
        if jn.any(): R.append(idx[0][jn]); C.append(idx[1][jn]); W.append(np.full(int(jn.sum()),1e-6))
        R=np.concatenate(R) if R else np.zeros(0,np.int64); C=np.concatenate(C) if C else np.zeros(0,np.int64); W=np.concatenate(W) if W else np.zeros(0)
        A=coo_matrix((W,(R,C)),shape=(cnt,cnt)).tocsr()
        def pad_nodes(nm):
            if nm not in self.padinfo: return np.zeros(0,np.int64)
            pj,pi,m,lay=self.pad_cells(nm); out=[]
            for l in lay:
                a0=max(pj,j0); a1=min(pj+m.shape[0],j1); b0=max(pi,i0); b1=min(pi+m.shape[1],i1)
                if a1<=a0 or b1<=b0: continue
                sel=m[a0-pj:a1-pj,b0-pi:b1-pi]&sub[l][a0-j0:a1-j0,b0-i0:b1-i0]
                out.append(idx[l][a0-j0:a1-j0,b0-i0:b1-i0][sel])
            return np.concatenate(out) if out else np.zeros(0,np.int64)
        res={}; maps={}
        for a in sorted({a for a,_,_ in pairs}):
            sn=pad_nodes(a)
            if len(sn)==0:
                for x,b,_ in pairs:
                    if x==a: res[(a,b)]=None
                continue
            d=dijkstra(A,directed=False,indices=sn,min_only=True)
            for x,b,_ in pairs:
                if x!=a: continue
                tn=pad_nodes(b); v=float(d[tn].min()) if len(tn) else math.inf
                res[(a,b)]=None if not math.isfinite(v) else v*SCALE
            if dist_maps:
                full=np.full((2,g.ny,g.nx),np.inf,np.float32)
                for l in range(2):
                    blk=np.full((h,w),np.inf,np.float32); blk[sub[l]]=d[idx[l][sub[l]]]; full[l,j0:j1,i0:i1]=blk
                maps[a]=full
        return (res,maps) if dist_maps else res
    def excess(self,n,lens=None):
        """(sum of mm over budget, number of pairs over budget, number not connected)"""
        lens=self.lengths(n) if lens is None else lens; ex=0.0; bad=0; opn=0
        for a,b,cap in self.pairs.get(n,[]):
            v=lens.get((a,b))
            if v is None: opn+=1
            elif v>cap+1e-6: ex+=v-cap; bad+=1
        return ex,bad,opn
    def report(self,nets=None,limit=20):
        rows=[]; tot=[0.0,0,0]
        for n in (nets if nets is not None else self.nets()):
            lens=self.lengths(n); ex,bad,opn=self.excess(n,lens); tot[0]+=ex; tot[1]+=bad; tot[2]+=opn
            for a,b,cap in self.pairs.get(n,[]):
                v=lens.get((a,b))
                if v is not None and v>cap+1e-6: rows.append((v-cap,self.g.nets[n],a,b,v,cap))
        rows.sort(reverse=True)
        return tot,rows[:limit]

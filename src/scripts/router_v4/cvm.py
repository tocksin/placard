"""cvm.py in out [NETS=@file] : constrained via minimisation on a finished v4 board (geometry fixed, layers reassigned).
A run of track between two vias of the same chain (an interior run) is moved to the other layer cell for cell, which
removes both vias and keeps the track length. Single flips first (legal when the run's cells are free on the other layer);
then pair flips: a run whose flip is blocked only by the copper of one other net is flipped together with an interior run
of that net (both nets lose two vias each, 4 in all, when both new runs are legal). Repeats until nothing changes.
Classic two-layer CVM (Joy and Ciesielski 1992; Chang and Cong) as a greedy local search on the v4 grid.
A flip (or pair) is kept only when it lowers the tidy's path cost (VIA, AGAINST, BEND as in tidy.py) by MINGAIN=4, so wrong-way
track is traded for vias at the same rate as the ladder rung whose VIA is given.
env: GRID (as the router)  VIA (cost in cells, use the last rung's)  AGAINST=3 (use the ladder's 2)  PASSES=4  PAIRWIN=2 (mm around a run where blocking nets are looked for)"""
import sys, os, time
import numpy as np
TOOLS=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,TOOLS)
from gridcore import *
src,dst=sys.argv[1:3]; NETS=E('NETS'); PASSES=int(E('PASSES','4')); PAIRWIN=float(E('PAIRWIN','2')); MINGAIN=float(E('MINGAIN','4'))
t0=time.time()
def netlist(spec):
    if spec and spec.startswith('@'): return [l.strip() for l in open(spec[1:],encoding='utf-8') if l.strip()]
    return spec.split(',') if spec else []
b0,n0,_f,_p,_e=load(src); nid0={v:k for k,v in n0.items()}
g=Grid(src,None,scope={nid0[x] for x in netlist(NETS) if x in nid0} if NETS else None)
PAD=int(PAIRWIN/G)+2
import collections; ST=collections.Counter()

def interior_runs(path):
    """(s,e) index ranges of same-layer runs bounded by a via (layer change at the same cell) at both ends"""
    out=[]; s=0
    for k in range(1,len(path)+1):
        if k==len(path) or path[k][0]!=path[k-1][0]:
            if s>0 and k<len(path) and path[s-1][1:]==path[s][1:] and path[k][1:]==path[k-1][1:]: out.append((s,k-1))
            s=k
    return out
def flipped(path,s,e):
    return path[:s-1]+[(1-l,iy,ix) for l,iy,ix in path[s:e+1]]+path[e+2:]
def cells_of(path,s,e): return [(1-l,iy,ix) for l,iy,ix in path[s:e+1]]
def win_of(cells,pad):
    ys=[c[1] for c in cells]; xs=[c[2] for c in cells]
    return (max(0,min(xs)-pad),min(g.nx,max(xs)+pad+1),max(0,min(ys)-pad),min(g.ny,max(ys)+pad+1))
def free(n,cells):
    """True when every (layer,iy,ix) track cell is free for net n (net n's own routes must already be lifted)"""
    w=win_of(cells,1); bt,_=g.blocked(n,True,w); x0,x1,y0,y1=w
    if any(g.field[iy,ix] for l,iy,ix in cells if l==0): return False
    return not any(bt[l][iy-y0,ix-x0] for l,iy,ix in cells)
def nvias(n): return sum(g.path_vias(p) for p in g.routes[n])
def gain(path,s,e): return g.path_cost(path)-g.path_cost(flipped(path,s,e))
def try_single(n,ci,s,e):
    old=list(g.routes[n]); path=old[ci]; cells=cells_of(path,s,e)
    if gain(path,s,e)<MINGAIN: ST['single: no cost gain']+=1; return False
    g.set_route(n,[]); ok=free(n,cells); ST['single: '+('flipped' if ok else 'blocked')]+=1
    g.set_route(n,old[:ci]+[flipped(path,s,e)]+old[ci+1:] if ok else old); return ok
def blockers(n,cells):
    """other scope nets whose route stamps cover any of the cells on its layer (net n lifted)"""
    w=win_of(cells,0); x0,x1,y0,y1=w; out=set()
    for m in g.scope:
        if m==n: continue
        for kind,L,j0,i0,msk in g.stamps.get(m,[]):
            if kind!='t' or j0>y1 or i0>x1 or j0+msk.shape[0]<y0 or i0+msk.shape[1]<x0: continue
            l=LAY.index(L)
            for cl,iy,ix in cells:
                if cl==l and j0<=iy<j0+msk.shape[0] and i0<=ix<i0+msk.shape[1] and msk[iy-j0,ix-i0]: out.add(m); break
            if m in out: break
    return out
def try_pair(n,ci,s,e):
    oldn=list(g.routes[n]); path=oldn[ci]; cells=cells_of(path,s,e)
    g.set_route(n,[]); bl=blockers(n,cells)
    ST[f'pair: {min(len(bl),3)} blocking nets']+=1
    if len(bl)!=1: g.set_route(n,oldn); return False
    m=bl.pop(); oldm=list(g.routes[m]); gn=gain(path,s,e); w=win_of(cells,PAD); x0,x1,y0,y1=w
    g.set_route(m,[])
    if not free(n,cells): ST['pair: fixed copper blocks too']+=1; g.set_route(m,oldm); g.set_route(n,oldn); return False   # fixed copper blocks it too
    newn=oldn[:ci]+[flipped(path,s,e)]+oldn[ci+1:]
    g.set_route(n,newn)
    for cj,pm in enumerate(oldm):
        for s2,e2 in interior_runs(pm):
            c2=cells_of(pm,s2,e2)
            if not any(x0<=ix<x1 and y0<=iy<y1 for _,iy,ix in c2) or gn+gain(pm,s2,e2)<MINGAIN: continue
            if free(m,c2):
                g.set_route(m,oldm[:cj]+[flipped(pm,s2,e2)]+oldm[cj+1:])
                g.set_route(n,[]); ok=free(n,cells)   # the rest of m's copper must still leave n's new run free
                g.set_route(n,newn)
                if ok: return True
                g.set_route(m,[])
    ST['pair: no legal partner run']+=1
    g.set_route(n,[]); g.set_route(m,oldm); g.set_route(n,oldn); return False
v0=sum(nvias(n) for n in g.scope); c0=sum(sum(len(p) for p in g.routes[n]) for n in g.scope)
print(f'interior runs (via at both ends): {sum(len(interior_runs(p)) for n in g.scope for p in g.routes[n])}')
print(f'start: {v0} vias, {c0} cells, {len(g.scope)} nets, {time.time()-t0:.0f} s',flush=True)
for mode in ('single','pair'):
    for ps in range(PASSES):
        t1=time.time(); k=0
        for n in sorted(g.scope):
            ci=0
            while ci<len(g.routes[n]):
                done=False
                for s,e in interior_runs(g.routes[n][ci]):
                    if (try_single if mode=='single' else try_pair)(n,ci,s,e): k+=1; done=True; break
                if not done: ci+=1
        print(f'{mode} pass {ps}: {k} flips, vias {sum(nvias(n) for n in g.scope)}, {time.time()-t1:.0f} s',flush=True)
        print('  ',dict(ST),flush=True); ST.clear()
        if not k: break
v1=sum(nvias(n) for n in g.scope); c1=sum(sum(len(p) for p in g.routes[n]) for n in g.scope)
print(f'vias {v0} -> {v1}, cells {c0} -> {c1}, {time.time()-t0:.0f} s')
g.write_out(dst)

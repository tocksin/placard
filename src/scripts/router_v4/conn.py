"""conn.py pcb [nets,..] : connectivity of every net (ignores teardrop zones; In1 GND / In2 +5V planes join all through-hole pads and vias of their net)"""
import os, sys,math,collections; TOOLS=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,TOOLS)
from board import *
from shapely.geometry import LineString, Point
from shapely.strtree import STRtree
def conn(pcb):
    b,nets,fps,pads,edges=load(pcb)
    ALL={'F.Cu','In1.Cu','In2.Cu','B.Cu'}
    items=[]
    for p in pads:
        if p['kind']=='np_thru_hole' or not p['net']: continue
        lay=ALL if '*.Cu' in p['layers'] else {l for l in p['layers'] if l.endswith('.Cu')}
        items.append((p['net'],lay,pad_poly(p),p['ref']+'-'+p['num']))
    for s in find(b,'segment'):
        a=tuple(map(float,one(s,'start')[1:3])); e=tuple(map(float,one(s,'end')[1:3])); w=float(one(s,'width')[1])
        items.append((int(one(s,'net')[1]),{one(s,'layer')[1]},LineString([a,e]).buffer(w/2,8),'seg'))
    for v in find(b,'via'):
        x,y=map(float,one(v,'at')[1:3]); d=float(one(v,'size')[1])
        items.append((int(one(v,'net')[1]),ALL,Point(x,y).buffer(d/2,8),'via'))
    par=list(range(len(items)))
    def f(i):
        while par[i]!=i: par[i]=par[par[i]]; i=par[i]
        return i
    tree=STRtree([i[2] for i in items])
    for i,(n,l,g,k) in enumerate(items):
        for j in tree.query(g):
            if j<=i: continue
            n2,l2,g2,k2=items[j]
            if n==n2 and l&l2 and g.intersects(g2): par[f(i)]=f(j)
    nid={v:k for k,v in nets.items()}
    for pn in ('GND','+5V'):
        r=None
        for i,(n,l,g,k) in enumerate(items):
            if n==nid.get(pn) and len(l)==4:
                if r is None: r=i
                else: par[f(i)]=f(r)
    groups=collections.defaultdict(lambda: collections.defaultdict(list))
    for i,(n,l,g,k) in enumerate(items):
        if nets[n].startswith('unconnected-'): continue
        groups[n][f(i)].append(k)
    out={}
    for n,gs in groups.items():
        if len(gs)>1: out[nets[n]]=[sorted(k for k in v if k not in('seg','via')) for v in gs.values()]
    return out
if __name__=='__main__':
    r=conn(sys.argv[1])
    for n,gs in sorted(r.items()): print(n,len(gs)-1,'open:',gs)

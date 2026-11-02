"""tracklen.py : copper path length from one pad to other pads of the same net, on the real track geometry of a .kicad_pcb
(shortest path along the net's segments; vias join the layers at no length). From the routed-timing tool meas.py
(2026-11-02, track-end touch tolerance 0.3 mm). Used by budgets.py (current lengths) and score.py (budget report).
measure(pcb_path_or_loaded, keys) -> {(net, from_pad, to_pad): mm or None (not connected)}"""
import math, heapq, os, sys
TOOLS=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,TOOLS)
from board import load, pad_poly
from sexpr import find, one
from shapely.geometry import LineString, Point
from shapely.strtree import STRtree
class Board:
    def __init__(self,pcb):
        self.b,self.nets,self.fps,self.pads,self.edges=load(pcb) if isinstance(pcb,str) else pcb
        self.nid={v:k for k,v in self.nets.items()}; self.SEG={}; self.VIA={}; self._g={}
        for s in find(self.b,'segment'):
            n=int(one(s,'net')[1]); self.SEG.setdefault(n,[]).append([one(s,'layer')[1],tuple(map(float,one(s,'start')[1:3])),tuple(map(float,one(s,'end')[1:3]))])
        for v in find(self.b,'via'):
            n=int(one(v,'net')[1]); self.VIA.setdefault(n,[]).append(tuple(map(float,one(v,'at')[1:3])))
        self.padxy={f"{p['ref']}-{p['num']}":(p['x'],p['y']) for p in self.pads}
    def graph(self,n):
        if n in self._g: return self._g[n]
        segs=self.SEG.get(n,[]); vias=self.VIA.get(n,[]); npads=[p for p in self.pads if p['net']==n]
        ends=[(L,p) for L,a,e in segs for p in (a,e)]+[(None,v) for v in vias]
        o=[]
        for L,a,e in segs:
            g=LineString([a,e]); cuts=[]
            for L2,p in ends:
                if (L2 is None or L2==L) and g.distance(Point(p))<0.3 and math.dist(p,a)>0.16 and math.dist(p,e)>0.16: cuts.append(g.project(Point(p)))
            pts=[a]+[g.interpolate(t).coords[0] for t in sorted(cuts)]+[e]
            for p,q in zip(pts,pts[1:]): o.append((L,p,q))
        def key(L,p): return (L,round(p[0],2),round(p[1],2))
        adj={}
        def add(u,v,w): adj.setdefault(u,[]).append((v,w)); adj.setdefault(v,[]).append((u,w))
        for L,p,q in o: add(key(L,p),key(L,q),math.dist(p,q))
        nodes=list(adj)
        if nodes:
            tree=STRtree([Point(k[1],k[2]) for k in nodes])
            for i,k in enumerate(nodes):
                for j in tree.query(Point(k[1],k[2]).buffer(0.16)):
                    if j>i and nodes[j][0]==k[0]: add(k,nodes[j],math.dist(k[1:],nodes[j][1:]))
        for v in vias:
            ks=[k for k in nodes if math.dist(k[1:],v)<0.56]
            for i in range(len(ks)):
                for j in range(i+1,len(ks)): add(ks[i],ks[j],0)
        padnode={}
        for p in npads:
            g=pad_poly(p,0.02); pk=('pad',p['ref'],p['num']); padnode[f"{p['ref']}-{p['num']}"]=pk; adj.setdefault(pk,[])
            for k in nodes:
                if ('*.Cu' in p['layers'] or k[0] in p['layers']) and g.contains(Point(k[1],k[2])): add(pk,k,0)
        self._g[n]=(adj,padnode); return self._g[n]
    def dist_from(self,n,pad):
        adj,padnode=self.graph(n)
        if pad not in padnode: return {}
        src=padnode[pad]; dist={src:0}; pq=[(0,src)]
        while pq:
            d,u=heapq.heappop(pq)
            if d>dist[u]: continue
            for v,w in adj.get(u,[]):
                if d+w<dist.get(v,1e9): dist[v]=d+w; heapq.heappush(pq,(d+w,v))
        return {k:dist.get(v) for k,v in padnode.items()}
def measure(pcb,keys):
    B=pcb if isinstance(pcb,Board) else Board(pcb); out={}; cache={}
    for net,a,b in keys:
        n=B.nid.get(net)
        if n is None: out[(net,a,b)]=None; continue
        if (n,a) not in cache: cache[(n,a)]=B.dist_from(n,a)
        out[(net,a,b)]=cache[(n,a)].get(b)
    return out

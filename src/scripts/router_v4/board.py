import os, math, sys
TOOLS=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,TOOLS)
from sexpr import parse, find, one
def rot(x,y,a):
    r=math.radians(a); return (x*math.cos(r)+y*math.sin(r), -x*math.sin(r)+y*math.cos(r))
def load(path):
    b=parse(open(path).read())
    nets={int(n[1]):n[2] for n in find(b,'net')}
    pads=[]; fps=[]
    for fp in find(b,'footprint'):
        ref=([p[2] for p in find(fp,'property') if p[1]=='Reference']+[t[2] for t in find(fp,'fp_text') if t[1]=='reference'])[0]
        at=one(fp,'at'); x0,y0=float(at[1]),float(at[2]); a=float(at[3]) if len(at)>3 else 0
        fps.append((ref,x0,y0,a,fp[1]))
        for p in find(fp,'pad'):
            pa=one(p,'at'); px,py=float(pa[1]),float(pa[2]); pang=float(pa[3]) if len(pa)>3 else 0
            dx,dy=rot(px,py,a)
            sz=one(p,'size'); w,h=float(sz[1]),float(sz[2])
            n=one(p,'net'); dr=one(p,'drill')
            pads.append(dict(ref=ref,num=p[1],kind=p[2],shape=p[3],x=x0+dx,y=y0+dy,ang=pang,w=w,h=h,
                layers=one(p,'layers')[1:],net=int(n[1]) if n else 0,netname=n[2] if n else '',
                drill=float([v for v in dr[1:] if not isinstance(v,list) and v!='oval'][0]) if dr else 0))
    edges=[]
    for g in find(b,'gr_line')+find(b,'gr_arc'):
        if one(g,'layer')[1]!='Edge.Cuts': continue
        pts=[tuple(map(float,one(g,k)[1:3])) for k in ('start','mid','end') if one(g,k)]
        edges.append(pts)
    return b,nets,fps,pads,edges
def arcpts(p0,pm,p1,n=12):
    (x1,y1),(x2,y2),(x3,y3)=p0,pm,p1
    d=2*(x1*(y2-y3)+x2*(y3-y1)+x3*(y1-y2))
    ux=((x1*x1+y1*y1)*(y2-y3)+(x2*x2+y2*y2)*(y3-y1)+(x3*x3+y3*y3)*(y1-y2))/d
    uy=((x1*x1+y1*y1)*(x3-x2)+(x2*x2+y2*y2)*(x1-x3)+(x3*x3+y3*y3)*(x2-x1))/d
    r=math.hypot(x1-ux,y1-uy)
    a0=math.atan2(y1-uy,x1-ux); am=math.atan2(y2-uy,x2-ux); a1=math.atan2(y3-uy,x3-ux)
    def norm(a): return (a-a0)%(2*math.pi)
    s=norm(a1); 
    if norm(am)>s: s=s-2*math.pi
    return [(ux+r*math.cos(a0+s*i/n),uy+r*math.sin(a0+s*i/n)) for i in range(n+1)]
def outline(edges):
    segs=[]
    for e in edges:
        segs.append(arcpts(*e) if len(e)==3 else e)
    poly=list(segs.pop(0))
    while segs:
        for i,s in enumerate(segs):
            if math.dist(s[0],poly[-1])<1e-3: poly+=s[1:]; segs.pop(i); break
            if math.dist(s[-1],poly[-1])<1e-3: poly+=s[::-1][1:]; segs.pop(i); break
        else: raise Exception('open outline')
    return poly[:-1]
def pad_poly(p, grow=0.0):
    from shapely.geometry import Point, box
    from shapely import affinity
    if p['shape']=='circle' or (p['shape']=='oval' and abs(p['w']-p['h'])<1e-6):
        return Point(p['x'],p['y']).buffer(p['w']/2+grow,32)
    if p['shape']=='oval':
        l=abs(p['w']-p['h'])/2; r=min(p['w'],p['h'])/2
        from shapely.geometry import LineString
        g=LineString([(-l,0),(l,0)] if p['w']>p['h'] else [(0,-l),(0,l)]).buffer(r+grow,32)
    else:
        g=box(-p['w']/2,-p['h']/2,p['w']/2,p['h']/2)
        if grow: g=g.buffer(grow,join_style=2)
    g=affinity.rotate(g,-p['ang'],origin=(0,0))
    return affinity.translate(g,p['x'],p['y'])

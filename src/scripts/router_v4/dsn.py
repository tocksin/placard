import sys, math
import os; sys.path.insert(0,os.path.dirname(os.path.abspath(__file__)))
from board import *
from shapely.geometry import Polygon, box, Point
U=1000.0
def c(v): return round(v*U)
def q(s): return '"'+s.replace('"','')+'"'
def write(pcb, out, power={'GND':0.6,'+5V':0.6}, width=0.3, clr=0.25, edge=None, hole_keep={'H1':3.0}, tab_y=None, via=(0.8,0.4), skip=(), planes=None, in2sig=False, pinsel=None, wtype='route', dirs=None, against=5.0, viacost=50, wsel=None):
    vn=f'Via[0-1]_{c(via[0])}:{c(via[1])}_um'
    b,nets,fps,pads,edges=load(pcb)
    o=outline(edges); bp=Polygon(o)
    yJ=([f for f in fps if f[0]=='J1']+[(0,0,0)])[0][2]
    if tab_y is not None: tab_y=yJ-5.175
    L=[]; A=L.append
    A('(pcb board (parser (string_quote ")(space_in_quoted_tokens on)(host_cad "KiCad")(host_version "9"))')
    A(' (resolution um 10)(unit um)')
    if planes:
        A(f' (structure (layer F.Cu (type signal)(property (index 0)))(layer In1.Cu (type power)(property (index 1)))(layer In2.Cu (type {"signal" if in2sig else "power"})(property (index 2)))(layer B.Cu (type signal)(property (index 3)))')
    else:
        A(' (structure (layer F.Cu (type signal)(property (index 0)))(layer B.Cu (type signal)(property (index 1)))')
    A('  (boundary (path pcb 0 '+' '.join(f'{c(x)} {c(-y)}' for x,y in o+[o[0]])+'))')
    # edge keepout ring (not across the finger tab)
    from rules import EDGE, hole_edge_keepouts
    if edge is None: edge=EDGE
    ring=bp.difference(bp.buffer(-edge,join_style=2))
    if tab_y is not None:
        minx,miny,maxx,maxy=bp.bounds
        ring=ring.difference(box(minx-1,tab_y,maxx+1,maxy+1))
    minx,miny,maxx,maxy=bp.bounds; mx=(minx+maxx)/2
    geoms=[]
    for half in (box(minx-1,miny-1,mx,maxy+1),box(mx,miny-1,maxx+1,maxy+1)):
        g=ring.intersection(half); geoms+=list(getattr(g,'geoms',[g]))
    assert all(len(g.interiors)==0 for g in geoms)
    if tab_y is not None:
        minx,miny,maxx,maxy=bp.bounds
        t=bp.intersection(box(minx-1,yJ+2.175,maxx+1,maxy+1)); geoms+=list(getattr(t,'geoms',[t]))
    if hole_keep=='np':
        for p in pads:
            if p['kind']=='np_thru_hole': geoms.append(Point(p['x'],p['y']).buffer(p['drill']/2+0.3,16))
        hole_keep={}
    geoms+=[g.intersection(bp) for g in hole_edge_keepouts(pads,bp,clr)]   # nothing between a mounting hole and the board edge
    for ref,r in hole_keep.items():
        p=[p for p in pads if p['ref']==ref][0]; geoms.append(Point(p['x'],p['y']).buffer(r,16))
    for g in geoms:
        if g.area<1e-4: continue
        g=g.simplify(0.01)
        polys=[g] 
        for lay in (('F.Cu','In2.Cu','B.Cu') if in2sig else ('F.Cu','B.Cu')):
            A(f'  (keepout "" (polygon {lay} 0 '+' '.join(f'{c(x)} {c(-y)}' for x,y in g.exterior.coords)+'))')
    if planes:
        pl=bp.buffer(-0.5,join_style=2)
        for n,lay in planes.items():
            A(f'  (plane {q(n)} (polygon {lay} 0 '+' '.join(f'{c(x)} {c(-y)}' for x,y in pl.exterior.coords)+'))')
    A(f'  (via {q(vn)})')
    if dirs:
        A('  (snap_angle ninety_degree)')
        A(f'  (autoroute_settings (fanout off)(autoroute on)(postroute on)(vias on)(via_costs {viacost})(plane_via_costs 5)(start_ripup_costs 100)(start_pass_no 1)')
        for LY,d in dirs.items():
            A(f'   (layer_rule {LY} (active on)(preferred_direction {d})(preferred_direction_trace_costs 1.0)(against_preferred_direction_trace_costs {against}))')
        A('  )')
    A(f'  (rule (width {c(width)})(clearance {c(clr)})(clearance {c(clr)} (type default_smd))(clearance {c(clr)} (type smd_smd)))')
    A(' )')
    stacks={}
    seen={}
    for p in pads:
        if p['kind']=='np_thru_hole': continue
        base=p['num'] or 'X'
        k=(p['ref'],base); seen[k]=seen.get(k,0)+1
        p['pid']=base if seen[k]==1 else f'{base}_{seen[k]}'
    def stack(p):
        lay=(['F.Cu','In1.Cu','In2.Cu','B.Cu'] if planes else ['F.Cu','B.Cu']) if '*.Cu' in p['layers'] else [l for l in p['layers'] if l.endswith('.Cu')]
        w,h=p['w'],p['h']
        if round(p['ang'])%180==90: w,h=h,w
        if p['shape'] in('circle','oval') and abs(w-h)<1e-6:
            name=f"Round[{'A' if len(lay)>=2 else lay[0][0]}]Pad_{c(w)}_um"
            body=' '.join(f'(shape (circle {l} {c(w)} 0 0))' for l in lay)
        elif p['shape']=='oval':
            name=f"Oval[{'A' if len(lay)>=2 else lay[0][0]}]Pad_{c(w)}x{c(h)}_um"
            r=min(w,h); l2=abs(w-h)/2
            seg=(f'{-c(l2)} 0 {c(l2)} 0' if w>h else f'0 {-c(l2)} 0 {c(l2)}')
            body=' '.join(f'(shape (path {l} {c(r)} {seg}))' for l in lay)
        else:
            name=f"Rect[{'A' if len(lay)>=2 else lay[0][0]}]Pad_{c(w)}x{c(h)}_um"
            body=' '.join(f'(shape (rect {l} {-c(w/2)} {-c(h/2)} {c(w/2)} {c(h/2)}))' for l in lay)
        stacks[name]=body; return name
    A(' (placement')
    imgs=[]
    for ref,x0,y0,a,name in fps:
        pins=[]
        for p in pads:
            if p['ref']!=ref or p['kind']=='np_thru_hole': continue
            pins.append((stack(p),p['pid'],p['x']-x0,-(p['y']-y0)))
        imgs.append((ref,pins))
        A(f'  (component {q("IMG_"+ref)} (place {q(ref)} {c(x0)} {c(-y0)} front 0))')
    A(' )')
    A(' (library')
    for ref,pins in imgs:
        A(f'  (image {q("IMG_"+ref)}')
        for st,num,x,y in pins: A(f'   (pin {q(st)} {num} {c(x)} {c(y)})')
        A('  )')
    for n,bd in stacks.items(): A(f'  (padstack {q(n)} {bd} (attach off))')
    A(f'  (padstack {q(vn)} '+' '.join(f'(shape (circle {l} {c(via[0])} 0 0))' for l in (['F.Cu','In1.Cu','In2.Cu','B.Cu'] if planes else ['F.Cu','B.Cu']))+f'(attach off))')
    A(' )')
    A(' (network')
    bynet={}
    for p in pads:
        if p['kind']!='np_thru_hole' and p['net'] and not p['netname'].startswith('unconnected-'): bynet.setdefault(p['netname'],[]).append(f"{p['ref']}-{p['pid']}")
    if pinsel:
        for k,v in pinsel.items(): bynet[k]=v
    routed=[n for n,pl in bynet.items() if len(pl)>1 and n not in skip]
    for n in routed: A(f'  (net {q(n)} (pins '+' '.join(bynet[n])+'))')
    sig=[n for n in routed if n not in power]
    A('  (class "kicad_default" '+' '.join(q(n) for n in sig)+f' (circuit (use_via {q(vn)}))(rule (width {c(width)})(clearance {c(clr)})))')
    for n,w in power.items():
        if n in routed: A(f'  (class {q("pwr_"+n)} {q(n)} (circuit (use_via {q(vn)}))(rule (width {c(w)})(clearance {c(clr)})))')
    A(' )')
    A(' (wiring')
    for sg in find(b,'segment'):
        a=one(sg,'start'); e=one(sg,'end'); n=nets[int(one(sg,'net')[1])]
        wt=wsel(n,(float(a[1]),float(a[2]),float(e[1]),float(e[2]))) if wsel else wtype
        nc=f'(net {q(n)})' if n in routed else ''   # copper of a net without pins: unassigned wire, Freerouting pops a dialog otherwise
        A(f'  (wire (path {one(sg,"layer")[1]} {c(float(one(sg,"width")[1]))} {c(float(a[1]))} {c(-float(a[2]))} {c(float(e[1]))} {c(-float(e[2]))}){nc}(type {wt}))')
    for v in find(b,'via'):
        at=one(v,'at'); n=nets[int(one(v,'net')[1])]
        wt=wsel(n,(float(at[1]),float(at[2]),float(at[1]),float(at[2]))) if wsel else wtype
        nc=f'(net {q(n)})' if n in routed else ''
        A(f'  (via {q(vn)} {c(float(at[1]))} {c(-float(at[2]))} {nc}(type {wt}))')
    A(' )')
    A(')')
    open(out,'w').write('\n'.join(L)+'\n')
    return routed
if __name__=='__main__':
    a=sys.argv
    import os
    WT='protect' if os.environ.get('PROTECT') else 'route'
    if a[3]=='dirs':
        r=write(a[1],a[2],tab_y=137.0,power={'GND':0.5,'+5V':0.5},planes={'GND':'In1.Cu','+5V':'In2.Cu'},
                dirs={'F.Cu':'vertical','B.Cu':'horizontal'},against=float(a[4]),viacost=int(a[5])); print(len(r)); sys.exit()
    if a[3]=='stubs':
        r=write(a[1],a[2],tab_y=137.0,power={'GND':0.5,'+5V':0.5},planes={'GND':'In1.Cu','+5V':'In2.Cu'},wtype='protect'); print(len(r)); sys.exit()
    if a[3]=='pass2':
        r=write(a[1],a[2],tab_y=137.0,power={'GND':0.5,'+5V':0.5},planes={'GND':'In1.Cu'},in2sig=True,
                pinsel={'+5V':['J1-A2','J1-B2','U1-24']},wtype='protect'); print(len(r)); sys.exit()
    w,cl,vd,vh,pw=map(float,a[3:8])
    r=write(a[1],a[2],tab_y=137.0,width=w,clr=cl,via=(vd,vh),power={'GND':pw,'+5V':pw}, skip=a[8].split(',') if len(a)>8 and a[8] else (), planes={'GND':'In1.Cu','+5V':'In2.Cu'} if len(a)>9 else None, wtype=WT)
    print(len(r),'nets')

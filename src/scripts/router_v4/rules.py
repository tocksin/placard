# Board rules shared by the routers and the DSN writer.
# Justin (2026-10-28): 1 mm clearance to the board outline, and nothing may pass between a
# mounting hole and the board edge (no routing "around the outside" of the mounting holes).
import os, re
from shapely.geometry import box
EDGE=float(os.environ.get('EDGE','1.0'))      # copper to board-outline clearance (mm)
HOLECLR=float(os.environ.get('HOLECLR','0.32'))  # copper to unplated hole edge (board rule 0.30 + margin)
PLANE_NETS={'GND','+5V'}                      # inner-plane nets with thermal-relief pads
THERMCLR=float(os.environ.get('THERMCLR','2.0'))  # no via centre within this distance of a plane-net through-hole pad (keeps the zone spokes)
HOLE_RE=re.compile(r'^H\d+$')                 # mounting-hole reference designators
NEAR=12.0                                     # a hole within this distance of an edge is "at" that edge

def hole_edge_keepouts(pads, bp, extra=0.0):
    """Rectangles between each mounting hole (pad extent + extra) and every nearby board edge."""
    minx,miny,maxx,maxy=bp.bounds; out=[]
    refs=sorted({p['ref'] for p in pads if HOLE_RE.match(p['ref'])})
    for ref in refs:
        ps=[p for p in pads if p['ref']==ref]
        big=max(ps,key=lambda p:(p.get('drill') or 0))
        cx,cy=big['x'],big['y']
        R=max(((p['x']-cx)**2+(p['y']-cy)**2)**0.5+max(p.get('w') or 0,p.get('h') or 0,p.get('drill') or 0)/2 for p in ps)+extra
        if cx-minx<NEAR: out.append(box(minx-1,cy-R,cx,cy+R))
        if maxx-cx<NEAR: out.append(box(cx,cy-R,maxx+1,cy+R))
        if cy-miny<NEAR: out.append(box(cx-R,miny-1,cx+R,cy))
        if maxy-cy<NEAR: out.append(box(cx-R,cy,cx+R,maxy+1))
    return out

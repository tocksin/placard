"""powerstubs.py in.kicad_pcb out.kicad_pcb : plane vias for surface-mount pads.

The grid router leaves GND and +5V to the inner planes, which only through-hole pads reach.  This gives every
surface-mount pad on a plane net (edge-connector fingers, SMD chip power pins) a short stub and a through via:
  * a chip pad: along the pad's long axis toward the middle of its footprint, the via just past the pad's end;
  * an edge-connector finger (EDGE=J1,...): straight in from the board edge, the via just past the finger's
    end; fingers of the two sides at the same place and net share one via.
A via is pushed further along its stub (STEP mm at a time), and the stub moved sideways inside its pad (SIDE),
until the via and the stub keep ECLR from the board outline and CLR from pads and vias of other nets: a finger
beside the edge of the connector tab or its key notch gets its via up in the card body.  Run it before
mroute4.py: the router keeps plane-net copper and routes round it.
env: PLANES=GND,+5V  EDGE=J1  W=0.5 (stub width)  WEDGE=0.3 (finger stub width)  VD=0.8 VDR=0.4 (via)
     GAP=0.65 (pad end to via centre)  CLR=0.25  ECLR=0.5 (outline)  STEP=0.25  SIDE=0,0.15,-0.15
"""
import sys, os, re, math, uuid
TOOLS = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, TOOLS)
import board
E = os.environ.get
PLANES = E('PLANES', 'GND,+5V').split(','); EDGE = E('EDGE', 'J1').split(',')
W = float(E('W', '0.5')); VD = float(E('VD', '0.8')); VDR = float(E('VDR', '0.4')); GAP = float(E('GAP', '0.65'))
CLR = float(E('CLR', '0.25')); STEP = float(E('STEP', '0.25')); ECLR = float(E('ECLR', '0.5'))
WEDGE = float(E('WEDGE', '0.3')); SIDE = [float(v) for v in E('SIDE', '0,0.15,-0.15').split(',')]; TOL = 0.02

def path_of(p, end, dx, dy, off, d):
    """pad centre -> along the pad and d past its end (the via); with a sideways offset the stub starts beside
    the centre instead (still inside the pad), since a piece from the centre would itself be too near the edge"""
    sx, sy = p['x'] + (-dy) * off, p['y'] + dx * off
    return [(sx, sy), (end[0] + (-dy) * off + dx * d, end[1] + dx * off + dy * d)]

def main():
    from shapely.geometry import LineString, Point
    from shapely.ops import unary_union
    src, dst = sys.argv[1:3]
    b, nets, fps, pads, edges = board.load(src)
    org = {f[0]: (f[1], f[2], f[3]) for f in fps}
    ys = [p[1] for e in edges for p in e]; ymid = (min(ys) + max(ys)) / 2
    rim = unary_union([LineString(board.arcpts(*e, n=64) if len(e) == 3 else e) for e in edges])
    poly = {id(p): board.pad_poly(p) for p in pads}
    vias = []; segs = []; done = {}
    todo = [p for p in pads if p['kind'] in ('smd', 'connect') and p['netname'] in PLANES]
    todo.sort(key=lambda p: (p['ref'] not in EDGE, p['x'], p['y']))

    def fits(p, path, wid):
        """the via at the end of path and the stub outside its own pad keep clear of the outline, other nets"""
        vx, vy = path[-1]; v = Point(vx, vy)
        if v.distance(rim) < VD / 2 + ECLR + TOL: return False
        stub = LineString(path).buffer(wid / 2).difference(poly[id(p)])
        if not stub.is_empty and stub.distance(rim) < ECLR + TOL: return False
        if any(n != p['net'] and math.hypot(vx - x, vy - y) < VD + CLR + TOL for x, y, n in vias): return False
        for q in pads:
            if q['net'] == p['net'] or not (set(q['layers']) & {'F.Cu', 'B.Cu', '*.Cu'}): continue
            if abs(q['x'] - vx) > 6 or abs(q['y'] - vy) > 6: continue
            if v.distance(poly[id(q)]) < VD / 2 + CLR + TOL: return False
            if q['layers'][0] in ('*.Cu', p['layers'][0]) and not stub.is_empty \
                    and stub.distance(poly[id(q)]) < CLR + TOL: return False
        return True

    for p in todo:
        ox, oy, oa = org[p['ref']]
        w, h = (p['w'], p['h']) if abs(p['ang'] % 180) < 1 else (p['h'], p['w'])     # size along board x, y
        edge = p['ref'] in EDGE
        if edge:
            dx, dy = 0.0, (-1.0 if p['y'] > ymid else 1.0); half = h / 2
        elif h >= w:
            dx, dy = 0.0, (1.0 if oy > p['y'] else -1.0); half = h / 2
        else:
            dx, dy = (1.0 if ox > p['x'] else -1.0), 0.0; half = w / 2
        wid = min(W, WEDGE) if edge else min(W, min(w, h))
        layer = [l for l in p['layers'] if l.endswith('.Cu')][0]
        key = (p['ref'], round(p['x'], 3), p['net']) if edge else (p['ref'], round(p['x'], 3), round(p['y'], 3), p['net'])
        end = (p['x'] + dx * half, p['y'] + dy * half)          # the pad's inner end (fingers of both sides: the same)
        if key in done:                      # the finger on the other side: join the same via
            off, d = done[key]
        else:
            found = None; d = GAP
            while found is None and d < 12:
                for off in SIDE:
                    if abs(off) > max(0.0, min(w, h) / 2 - wid / 2) + 1e-9: continue
                    if fits(p, path_of(p, end, dx, dy, off, d), wid): found = (off, d); break
                else: d += STEP
            if found is None: raise SystemExit('powerstubs: no room for a via at %s pad %s' % (p['ref'], p.get('num')))
            off, d = done[key] = found
            vx, vy = path_of(p, end, dx, dy, off, d)[-1]; vias.append((vx, vy, p['net']))
        pts = path_of(p, end, dx, dy, off, d)
        for a_, b_ in zip(pts, pts[1:]):
            if math.hypot(a_[0] - b_[0], a_[1] - b_[1]) > 1e-6: segs.append((a_[0], a_[1], b_[0], b_[1], layer, p['net'], wid))
    out = []
    for x0, y0, x1, y1, layer, n, wid in segs:      # the block layout the router tools read and write
        out.append('\t(segment\n\t\t(start %.4f %.4f)\n\t\t(end %.4f %.4f)\n\t\t(width %g)\n\t\t(layer "%s")\n\t\t(net %d)\n'
                   '\t\t(uuid "%s")\n\t)\n' % (x0, y0, x1, y1, wid, layer, n, uuid.uuid4()))
    for x, y, n in vias:
        out.append('\t(via\n\t\t(at %.4f %.4f)\n\t\t(size %g)\n\t\t(drill %g)\n\t\t(layers "F.Cu" "B.Cu")\n\t\t(net %d)\n'
                   '\t\t(uuid "%s")\n\t)\n' % (x, y, VD, VDR, n, uuid.uuid4()))
    s = open(src, encoding='utf-8').read().rstrip()
    assert s.endswith(')')
    open(dst, 'w', encoding='utf-8', newline='\n').write(s[:-1] + ''.join(out) + ')\n')
    print('powerstubs: %d stubs, %d vias -> %s' % (len(segs), len(vias), dst))

if __name__ == '__main__': main()

#!/usr/bin/env python3
"""
gen_bringup_boards.py - a board picture for each step of docs/hardware/BRINGUP.md

For every "### Step N" (and the expansion slots section) this draws the
main board from kicad/placard.kicad_pcb, seen from the component side as
in the layout, with

    orange   the parts that step's "Parts for this step" table fits
    red      the chips that step takes out (step 13: the RAM)
    gray     what earlier steps fitted
    outline  what comes later

The parts are read from the Ref column of each step's table in
BRINGUP.md ("U7-U10 sockets", "R14, R17", ...), so the pictures follow the
guide: rerun this after the tables or the layout change.  Straps, test
leads and cartridge parts aren't on the main board and are skipped; the
cartridge gets its own picture (kicad/cartridge_32k) at the step that
builds it.  A Ref the board doesn't have is reported and the run fails.

    python3 gen_bringup_boards.py            all pictures
    python3 gen_bringup_boards.py --check    only check the Refs

Images go to docs/hardware/bringup_boards/.  KiCad isn't needed: the
board file is read as text and never written.

Date: 2026-11-11
"""

import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
DOC = os.path.join(ROOT, 'docs', 'hardware', 'BRINGUP.md')
BOARD = os.path.join(ROOT, 'kicad', 'placard.kicad_pcb')
CART = os.path.join(ROOT, 'kicad', 'cartridge_32k', 'cartridge_32k.kicad_pcb')
OUT = os.path.join(ROOT, 'docs', 'hardware', 'bringup_boards')

# chips a step takes out again (they go back in with the step that lists them)
REMOVED = {13: ['U31', 'U32']}
NOT_PARTS = ('H', 'LOGO', 'NT')          # mounting holes, logo, net ties: nothing to fit

TOKEN = re.compile(r'\(|\)|"(?:\\.|[^"\\])*"|[^\s()]+')


def parse(text):
    stack = [[]]
    for m in TOKEN.finditer(text):
        t = m.group()
        if t == '(':
            node = []
            stack[-1].append(node)
            stack.append(node)
        elif t == ')':
            stack.pop()
        elif t[0] == '"':
            stack[-1].append(t[1:-1])
        else:
            stack[-1].append(t)
    return stack[0][0]


def kids(node, key):
    return [x for x in node if isinstance(x, list) and x and x[0] == key]


def layer_of(node):
    k = kids(node, 'layer')
    return k[0][1] if k else ''


def xy(node, key):
    k = kids(node, key)[0]
    return float(k[1]), float(k[2])


class Part:
    def __init__(self, ref, x, y, rot):
        self.ref, self.x, self.y, self.rot = ref, x, y, rot
        self.pts = []                    # courtyard points, board mm
        self.circle = None               # (cx, cy, r) for a round courtyard

    def place(self, px, py):
        a = math.radians(self.rot)
        return (self.x + px * math.cos(a) + py * math.sin(a),
                self.y - px * math.sin(a) + py * math.cos(a))

    def box(self):
        if self.circle and not self.pts:
            cx, cy, r = self.circle
            return cx - r, cy - r, cx + r, cy + r
        xs = [p[0] for p in self.pts]
        ys = [p[1] for p in self.pts]
        return min(xs), min(ys), max(xs), max(ys)


def read_board(path):
    """the footprints (courtyard outline) and the board edge"""
    b = parse(open(path).read())
    parts = {}
    for f in kids(b, 'footprint'):
        ref = [p[2] for p in kids(f, 'property') if p[1] == 'Reference'][0]
        at = kids(f, 'at')[0]
        p = Part(ref, float(at[1]), float(at[2]), float(at[3]) if len(at) > 3 else 0.0)
        for layer in ('F.CrtYd', 'B.CrtYd', 'F.Fab'):
            for g in f:
                if not isinstance(g, list) or layer_of(g) != layer:
                    continue
                if g[0] in ('fp_line', 'fp_rect'):
                    (x1, y1), (x2, y2) = xy(g, 'start'), xy(g, 'end')
                    corners = [(x1, y1), (x2, y2)] if g[0] == 'fp_line' else \
                        [(x1, y1), (x2, y1), (x2, y2), (x1, y2)]
                    p.pts += [p.place(*c) for c in corners]
                elif g[0] == 'fp_poly':
                    for q in kids(kids(g, 'pts')[0], 'xy'):
                        p.pts.append(p.place(float(q[1]), float(q[2])))
                elif g[0] == 'fp_circle':
                    (cx, cy), (ex, ey) = xy(g, 'center'), xy(g, 'end')
                    gx, gy = p.place(cx, cy)
                    p.circle = (gx, gy, math.hypot(ex - cx, ey - cy))
            if p.pts or p.circle:
                break
        if p.pts or p.circle:
            parts[ref] = p
    edge = []
    for g in b:
        if not isinstance(g, list) or layer_of(g) != 'Edge.Cuts':
            continue
        if g[0] == 'gr_line':
            edge.append(('line', xy(g, 'start'), xy(g, 'end')))
        elif g[0] == 'gr_rect':
            (x1, y1), (x2, y2) = xy(g, 'start'), xy(g, 'end')
            c = [(x1, y1), (x2, y1), (x2, y2), (x1, y2)]
            edge += [('line', c[k], c[(k + 1) % 4]) for k in range(4)]
        elif g[0] == 'gr_arc':
            edge.append(('arc', xy(g, 'start'), xy(g, 'mid'), xy(g, 'end')))
    return parts, edge


REF = re.compile(r'\b([A-Z]+)(\d+)(?:\s*-\s*([A-Z]+)?(\d+))?')


def cell_refs(cell):
    """the main-board reference designators a Ref cell names"""
    cell = cell.strip()
    if cell.startswith('cartridge') or cell.startswith('('):
        return []
    out = []
    for m in REF.finditer(cell):
        pre, lo, pre2, hi = m.group(1), int(m.group(2)), m.group(3), m.group(4)
        if pre == 'S':                    # a temporary strap, not a board part
            continue
        hi = int(hi) if hi and (pre2 in (None, pre)) else lo
        out += ['%s%d' % (pre, n) for n in range(lo, hi + 1)]
    return out


def read_steps():
    """[(key, title, [refs])] from the parts tables of BRINGUP.md; key is the
    step number or 'expansion'"""
    steps = []
    cur = None
    in_table = False
    for line in open(DOC).read().split('\n'):
        m = re.match(r'### Step (\d+): (.*)', line)
        if m:
            cur = [int(m.group(1)), m.group(2), []]
            steps.append(cur)
            in_table = False
            continue
        if line.startswith('## Expansion slots'):
            cur = ['expansion', 'expansion slots', []]
            steps.append(cur)
            in_table = False
            continue
        if line.startswith('## ') or line.startswith('### '):
            cur = None
            continue
        if cur is None:
            continue
        if line.startswith('| Ref |'):
            in_table = True
            continue
        if in_table:
            if not line.startswith('|'):
                in_table = False
                continue
            if set(line) <= set('|- '):
                continue
            for r in cell_refs(line.split('|')[1]):
                if r not in cur[2]:
                    cur[2].append(r)
    return steps


def arc_points(s, m, e, n=24):
    """points along the arc through start, mid, end"""
    (x1, y1), (x2, y2), (x3, y3) = s, m, e
    d = 2 * (x1 * (y2 - y3) + x2 * (y3 - y1) + x3 * (y1 - y2))
    if abs(d) < 1e-9:
        return [s, e]
    ux = ((x1 * x1 + y1 * y1) * (y2 - y3) + (x2 * x2 + y2 * y2) * (y3 - y1) + (x3 * x3 + y3 * y3) * (y1 - y2)) / d
    uy = ((x1 * x1 + y1 * y1) * (x3 - x2) + (x2 * x2 + y2 * y2) * (x1 - x3) + (x3 * x3 + y3 * y3) * (x2 - x1)) / d
    r = math.hypot(x1 - ux, y1 - uy)
    a1, a2, a3 = (math.atan2(p[1] - uy, p[0] - ux) for p in (s, m, e))
    tau = 2 * math.pi
    sweep = (a3 - a1) % tau
    if (a2 - a1) % tau > sweep:
        sweep -= tau
    return [(ux + r * math.cos(a1 + sweep * k / n), uy + r * math.sin(a1 + sweep * k / n))
            for k in range(n + 1)]


STYLE = {
    'now':   dict(fc='#ff9d1c', ec='#8a3d00', lw=1.6, z=4),
    'out':   dict(fc='#ff6b6b', ec='#8a0000', lw=1.6, z=4),
    'done':  dict(fc='#b9bec6', ec='#6c727c', lw=0.6, z=2),
    'later': dict(fc='#ffffff', ec='#c3c7ce', lw=0.6, z=1),
}


def draw(parts, edge, state, title, path, scale=1.0, legend=True):
    """state: ref -> 'now' | 'out' | 'done' (anything else is 'later')"""
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    from matplotlib.patches import Rectangle, Circle, Patch

    xs, ys = [], []
    for e in edge:
        for p in e[1:]:
            xs.append(p[0])
            ys.append(p[1])
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    for p in parts.values():                 # connectors overhang the edge
        b = p.box()
        x0, y0, x1, y1 = min(x0, b[0]), min(y0, b[1]), max(x1, b[2]), max(y1, b[3])
    w, h = x1 - x0, y1 - y0
    k = 0.055 * scale                        # inches per mm
    fig = plt.figure(figsize=(w * k + 0.3, h * k + 0.9))
    ax = fig.add_axes([0.01, 0.01, 0.98, 1 - 0.75 / (h * k + 0.9)])
    ax.set_xlim(x0 - 2, x1 + 2)
    ax.set_ylim(y1 + 2, y0 - 2)
    ax.set_aspect('equal')
    ax.axis('off')
    for e in edge:
        pts = [e[1], e[2]] if e[0] == 'line' else arc_points(*e[1:])
        ax.plot([p[0] for p in pts], [p[1] for p in pts], color='#1f5e2e', lw=1.8, zorder=5,
                solid_capstyle='round')
    fs = 6.5 * scale
    for ref, p in sorted(parts.items()):
        if ref.startswith(NOT_PARTS):
            if p.circle:
                ax.add_patch(Circle(p.circle[:2], p.circle[2] * 0.55, fc='none', ec='#c3c7ce',
                                    lw=0.6, zorder=1))
            continue
        st = STYLE[state.get(ref, 'later')]
        bx0, by0, bx1, by1 = p.box()
        if p.circle and not p.pts:
            ax.add_patch(Circle(p.circle[:2], p.circle[2], fc=st['fc'], ec=st['ec'], lw=st['lw'],
                                zorder=st['z']))
        else:
            ax.add_patch(Rectangle((bx0, by0), bx1 - bx0, by1 - by0, fc=st['fc'], ec=st['ec'],
                                   lw=st['lw'], zorder=st['z']))
        s = state.get(ref, 'later')
        bw, bh = bx1 - bx0, by1 - by0
        big = max(bw, bh) >= 9
        if s in ('now', 'out') or big:
            col = '#000000' if s in ('now', 'out') else ('#4a4f57' if s == 'done' else '#a6abb3')
            rot = 90 if bh > bw * 1.3 else 0
            size = fs if (max(bw, bh) >= 5.5 or s not in ('now', 'out')) else fs * 0.8
            ax.text((bx0 + bx1) / 2, (by0 + by1) / 2, ref, ha='center', va='center', rotation=rot,
                    fontsize=size, color=col, zorder=6,
                    fontweight='bold' if s in ('now', 'out') else 'normal', clip_on=False)
    fig.text(0.012, 1 - 0.30 / (h * k + 0.9), title, fontsize=12 * min(1.0, scale * 1.0) + 1,
             fontweight='bold', va='center')
    if legend:
        hs = [Patch(fc=STYLE['now']['fc'], ec=STYLE['now']['ec'], label='fit in this step')]
        if 'out' in state.values():
            hs.append(Patch(fc=STYLE['out']['fc'], ec=STYLE['out']['ec'], label='take out'))
        if 'done' in state.values():
            hs.append(Patch(fc=STYLE['done']['fc'], ec=STYLE['done']['ec'], label='already fitted'))
        hs.append(Patch(fc=STYLE['later']['fc'], ec=STYLE['later']['ec'], label='later'))
        fig.legend(handles=hs, loc='upper right', ncol=len(hs), frameon=False, fontsize=9,
                   bbox_to_anchor=(0.995, 1 - 0.08 / (h * k + 0.9)), handlelength=1.4,
                   columnspacing=1.2)
    fig.savefig(path, dpi=110)
    plt.close(fig)
    print('wrote', os.path.relpath(path, ROOT))


def main(argv):
    steps = read_steps()
    parts, edge = read_board(BOARD)
    bad = False
    listed = set()
    for key, title, refs in steps:
        miss = [r for r in refs if r not in parts]
        if miss:
            bad = True
            print('step %s: not on the board: %s' % (key, ', '.join(miss)))
        listed |= set(refs)
    never = sorted(r for r in parts if r not in listed and not r.startswith(NOT_PARTS))
    if never:
        print('on the board but in no step: %s' % ', '.join(never))
    if bad:
        return 1
    if '--check' in argv:
        return 0
    os.makedirs(OUT, exist_ok=True)
    done = set()
    for key, title, refs in steps:
        out = REMOVED.get(key, [])
        state = {r: 'done' for r in done}
        state.update({r: 'out' for r in out})
        state.update({r: 'now' for r in refs})
        if key == 'expansion':
            draw(parts, edge, state, 'Expansion slots (optional)', os.path.join(OUT, 'expansion_board.png'))
        else:
            draw(parts, edge, state, 'Step %d: %s' % (key, title),
                 os.path.join(OUT, 'step%02d_board.png' % key))
        done |= set(refs)
        done -= set(out)
    cparts, cedge = read_board(CART)
    # J1 is the card edge itself, nothing to fit
    draw(cparts, cedge, {r: 'now' for r in cparts if r != 'J1'}, '32K cartridge',
         os.path.join(OUT, 'cartridge_32k_board.png'), scale=1.6, legend=False)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

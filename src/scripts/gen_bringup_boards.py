#!/usr/bin/env python3
"""
gen_bringup_boards.py - a board picture for each step of docs/hardware/BRINGUP.md

For every "### Step N" (and the expansion slots section) this draws the
main board from kicad/placard.kicad_pcb, seen from the component side as
in the layout, with

    orange   the parts that step's "Parts for this step" table fits
    blue     a socket that step fits and leaves empty (its chip comes in a
             later step); it stays pale blue until the chip goes in
    red      the chips that step takes out (step 13: the RAM)
    gray     what earlier steps fitted
    outline  what comes later
    green    the temporary straps, drawn from pin to pin, from the step
             that puts them in until the step that takes them out

A step with straps also gets a close-up of the sockets that hold them
(stepNN_straps.png): every pin numbered, each strap between its two pins
and the test lead clip points.  The straps come from the "- **Sn**, in
Un (...): ... pin a ... to pin b ... Out at step m." lines of the guide.

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
        self.pads = {}                   # pad number -> (x, y), board mm
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
        for pad in kids(f, 'pad'):
            px, py = xy(pad, 'at')
            p.pads.setdefault(pad[1], p.place(px, py))
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
            cur = [int(m.group(1)), m.group(2), [], set()]
            steps.append(cur)
            in_table = False
            continue
        if line.startswith('## Expansion slots'):
            cur = ['expansion', 'expansion slots', [], set()]
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
            cell = line.split('|')[1]
            for r in cell_refs(cell):
                if r not in cur[2]:
                    cur[2].append(r)
                if 'socket' not in cell:
                    cur[3].add(r)            # the part itself, not only its socket
    # a socket whose chip isn't in the same step's table is fitted empty
    return [(key, title, refs, [r for r in refs if r[0] == 'U' and r not in full])
            for key, title, refs, full in steps]


STRAP = re.compile(r'- \*\*(S\d+)\*\*, in (U\d+)[^:]*:(.*?)pin (\d+).*?to pin (\d+).*?Out at step (\d+)', re.S)
LEAD = re.compile(r"\*\*(Ground|Power) lead:\*\* clip it to strap (S\d+)'s lead at (U\d+)'s pin (\d+)")


def read_straps():
    """[dict(name, ref, a, b, kind, first, out)] and the test lead clip
    points [(step, 'Ground'|'Power', ref, pin)] from the guide's text"""
    text = open(DOC).read()
    straps, leads = [], []
    for sec in re.split(r'\n(?=### Step \d+:)', text):
        m = re.match(r'### Step (\d+):', sec)
        if not m:
            continue
        step = int(m.group(1))
        sec = re.split(r'\n## ', sec)[0]
        for name, ref, how, a, b, out in STRAP.findall(sec):
            straps.append(dict(name=name, ref=ref, a=a, b=b, first=step, out=int(out),
                               kind='wire link' if 'wire' in how else '10k'))
        for which, name, ref, pin in LEAD.findall(sec):
            leads.append((step, which, ref, pin))
    return straps, leads


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
    'socket': dict(fc='#4aa3ff', ec='#0b3d91', lw=1.6, z=4),
    'empty': dict(fc='#d5e8ff', ec='#5b86c4', lw=0.8, z=2),
    'done':  dict(fc='#b9bec6', ec='#6c727c', lw=0.6, z=2),
    'later': dict(fc='#ffffff', ec='#c3c7ce', lw=0.6, z=1),
}


STRAP_COL = '#0a8f3c'


def draw(parts, edge, state, title, path, scale=1.0, legend=True, straps=()):
    """state: ref -> 'now' | 'socket' | 'empty' | 'out' | 'done' (anything
    else is 'later'); straps: the ones in place during this step"""
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
        hot = s in ('now', 'out', 'socket')
        if hot or big:
            col = '#000000' if hot else ('#4a4f57' if s in ('done', 'empty') else '#a6abb3')
            rot = 90 if bh > bw * 1.3 else 0
            size = fs if (max(bw, bh) >= 5.5 or not hot) else fs * 0.8
            has_strap = any(t['ref'] == ref for t in straps)
            ax.text((bx0 + bx1) / 2, (by0 + by1) / 2 + (0 if rot or not has_strap else 0),
                    ref + (' socket' if s == 'socket' else ''), ha='center', va='center',
                    rotation=rot, fontsize=size, color=col, zorder=6,
                    fontweight='bold' if hot else 'normal', clip_on=False)
    for t in straps:
        p = parts[t['ref']]
        (ax1, ay1), (ax2, ay2) = p.pads[t['a']], p.pads[t['b']]
        ax.plot([ax1, ax2], [ay1, ay2], color=STRAP_COL, lw=2.2, zorder=7, solid_capstyle='round')
        ax.plot([ax1, ax2], [ay1, ay2], 'o', color=STRAP_COL, ms=4.5, zorder=7)
    for ref in sorted(set(t['ref'] for t in straps)):
        # one label per socket, outside it, on the side nearer its straps
        mine = [t for t in straps if t['ref'] == ref]
        p = parts[ref]
        bx0, by0, bx1, by1 = p.box()
        ys = [p.pads[t[k]][1] for t in mine for k in ('a', 'b')]
        above = sum(ys) / len(ys) <= (by0 + by1) / 2
        gap = 1.6 + 1.5 * len(mine)
        ax.text((bx0 + bx1) / 2, (by0 - gap) if above else (by1 + gap),
                '\n'.join('%s %s: pin %s to %s' % (t['name'], t['kind'], t['a'], t['b'])
                          for t in mine),
                ha='center', va='center', fontsize=fs, color=STRAP_COL, fontweight='bold',
                zorder=8, bbox=dict(fc='white', ec=STRAP_COL, lw=0.6, pad=1.5))
    fig.text(0.012, 1 - 0.30 / (h * k + 0.9), title, fontsize=12 * min(1.0, scale * 1.0) + 1,
             fontweight='bold', va='center')
    if legend:
        hs = [Patch(fc=STYLE['now']['fc'], ec=STYLE['now']['ec'], label='fit in this step')]
        if 'socket' in state.values():
            hs.append(Patch(fc=STYLE['socket']['fc'], ec=STYLE['socket']['ec'],
                            label='fit the socket only'))
        if 'out' in state.values():
            hs.append(Patch(fc=STYLE['out']['fc'], ec=STYLE['out']['ec'], label='take out'))
        if 'empty' in state.values():
            hs.append(Patch(fc=STYLE['empty']['fc'], ec=STYLE['empty']['ec'], label='empty socket'))
        if straps:
            from matplotlib.lines import Line2D
            hs.append(Line2D([0], [0], color=STRAP_COL, lw=2.2, marker='o', ms=4, label='strap'))
        if 'done' in state.values():
            hs.append(Patch(fc=STYLE['done']['fc'], ec=STYLE['done']['ec'], label='already fitted'))
        hs.append(Patch(fc=STYLE['later']['fc'], ec=STYLE['later']['ec'], label='later'))
        fig.legend(handles=hs, loc='upper right', ncol=len(hs), frameon=False, fontsize=9,
                   bbox_to_anchor=(0.995, 1 - 0.08 / (h * k + 0.9)), handlelength=1.4,
                   columnspacing=1.2)
    fig.savefig(path, dpi=110)
    plt.close(fig)
    print('wrote', os.path.relpath(path, ROOT))


def closeup(parts, straps, leads, step, path):
    """the sockets that get straps in this step, enlarged, in the same
    orientation as the board picture: every pin numbered, the straps and
    the test lead clip points"""
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    from matplotlib.patches import Rectangle, Circle

    refs = []
    for t in straps:
        if t['ref'] not in refs:
            refs.append(t['ref'])
    refs.sort(key=lambda r: parts[r].box()[0])
    k = 0.2                                   # inches per mm
    boxes = [parts[r].box() for r in refs]
    widths = [b[2] - b[0] + (22 if b[3] - b[1] > b[2] - b[0] else 8) for b in boxes]
    height = max(b[3] - b[1] for b in boxes) + 20
    fig = plt.figure(figsize=(sum(widths) * k, height * k + 0.5))
    left = 0.0
    for r, b, w in zip(refs, boxes, widths):
        p = parts[r]
        ax = fig.add_axes([left / sum(widths), 0, w / sum(widths), height * k / (height * k + 0.5)])
        left += w
        cx, cy = (b[0] + b[2]) / 2, (b[1] + b[3]) / 2
        ax.set_xlim(cx - w / 2, cx + w / 2)
        ax.set_ylim(cy + height / 2, cy - height / 2)
        ax.set_aspect('equal')
        ax.axis('off')
        ax.add_patch(Rectangle((b[0], b[1]), b[2] - b[0], b[3] - b[1], fc=STYLE['empty']['fc'],
                               ec=STYLE['empty']['ec'], lw=1.2))
        if (b[3] - b[1]) > (b[2] - b[0]):
            ax.text(cx, b[3] + 3, "%s socket" % r, ha='center', va='center', fontsize=11,
                    color='#3b5f93')
        else:
            ax.text(cx, b[3] + 6.5, "%s socket" % r, ha='center', va='center', fontsize=11,
                    color='#3b5f93')
        used = {}
        for t in straps:
            if t['ref'] == r:
                used[t['a']] = used[t['b']] = t
        for num, (x, y) in p.pads.items():
            hot = num in used
            if num == '1':
                ax.add_patch(Rectangle((x - 0.8, y - 0.8), 1.6, 1.6, fc=STRAP_COL if hot else 'white',
                                       ec='#333333', lw=1, zorder=3))
            else:
                ax.add_patch(Circle((x, y), 0.8, fc=STRAP_COL if hot else 'white', ec='#333333',
                                    lw=1, zorder=3))
            # the number goes on the outside of the pin row
            vert = (b[3] - b[1]) > (b[2] - b[0])
            if vert:
                dx, dy = (-2.6 if x < cx else 2.6), 0
            else:
                dx, dy = 0, (-2.6 if y < cy else 2.6)
            ax.text(x + dx, y + dy, num, ha='center', va='center', fontsize=9,
                    fontweight='bold' if hot else 'normal', color='#000000' if hot else '#555555')
        for t in straps:
            if t['ref'] != r:
                continue
            (x1, y1), (x2, y2) = p.pads[t['a']], p.pads[t['b']]
            ax.plot([x1, x2], [y1, y2], color=STRAP_COL, lw=4, zorder=4, solid_capstyle='round')
            mx, my = (x1 + x2) / 2, (y1 + y2) / 2
            ax.text(mx, my, '%s\n%s' % (t['name'], t['kind']), ha='center', va='center', fontsize=9,
                    fontweight='bold', color=STRAP_COL, zorder=5,
                    bbox=dict(fc='white', ec=STRAP_COL, lw=1, pad=2))
        for _, which, ref, pin in leads:
            if ref != r:
                continue
            x, y = p.pads[pin]
            vert = (b[3] - b[1]) > (b[2] - b[0])
            if vert:
                tx, ty, ha = (x - 9 if x < cx else x + 9), y, ('right' if x < cx else 'left')
            else:
                tx, ty, ha = x, (y - 6.5 if y < cy else y + 6.5), 'center'
            ax.annotate('%s lead\nclips here' % which.lower(), xy=(x, y), xytext=(tx, ty), ha=ha,
                        va='center', fontsize=9, color='#b00020', fontweight='bold', zorder=6,
                        arrowprops=dict(arrowstyle='->', color='#b00020', lw=1.2))
    fig.text(0.01, 1 - 0.25 / (height * k + 0.5),
             'Step %d straps (same way up as the board picture; pin 1 is the square pad)' % step,
             fontsize=11, fontweight='bold', va='center')
    fig.savefig(path, dpi=110)
    plt.close(fig)
    print('wrote', os.path.relpath(path, ROOT))


def main(argv):
    steps = read_steps()
    parts, edge = read_board(BOARD)
    bad = False
    listed = set()
    for key, title, refs, _ in steps:
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
    straps, leads = read_straps()
    for t in straps:
        p = parts.get(t['ref'])
        if p is None or t['a'] not in p.pads or t['b'] not in p.pads:
            print('strap %s: no such pins on %s' % (t['name'], t['ref']))
            return 1
    os.makedirs(OUT, exist_ok=True)
    done, empty = set(), set()
    for key, title, refs, sockets in steps:
        out = REMOVED.get(key, [])
        state = {r: 'done' for r in done}
        state.update({r: 'empty' for r in empty})
        state.update({r: 'out' for r in out})
        state.update({r: 'now' for r in refs})
        state.update({r: 'socket' for r in sockets})
        if key == 'expansion':
            draw(parts, edge, state, 'Expansion slots (optional)', os.path.join(OUT, 'expansion_board.png'))
        else:
            here = [t for t in straps if t['first'] <= key < t['out']]
            draw(parts, edge, state, 'Step %d: %s' % (key, title),
                 os.path.join(OUT, 'step%02d_board.png' % key), straps=here)
            new = [t for t in straps if t['first'] == key]
            if new:
                closeup(parts, new, [l for l in leads if l[0] == key], key,
                        os.path.join(OUT, 'step%02d_straps.png' % key))
        done |= set(refs) - set(sockets)
        empty = (empty | set(sockets)) - (set(refs) - set(sockets))
        done -= set(out)
    cparts, cedge = read_board(CART)
    # J1 is the card edge itself, nothing to fit
    draw(cparts, cedge, {r: 'now' for r in cparts if r != 'J1'}, '32K cartridge',
         os.path.join(OUT, 'cartridge_32k_board.png'), scale=1.6, legend=False)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

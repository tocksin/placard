#!/usr/bin/env python3
"""
gen_revb_mod.py - the pictures of docs/hardware/REVB_MOD.md

The hand modification that makes a rev A main board work like rev B (the
160-read lines, docs/video/HIRES.md): five lifted PLD pins and five wires.
Draws, from kicad/placard.kicad_pcb (read as text, never written):

    revb_mod_board.png    the whole board, the chips and the wire runs
    revb_mod_video.png    U35, U13 and U15 enlarged: every pin numbered,
                          the lifted pins and the four wires there
    revb_mod_acsel.png    U17 and U27 enlarged: the /AC_SEL wire

The lifts and wires are the tables LIFT and WIRES below; the guide's
tables say the same and --check compares them with the two netlists'
difference written down in NETS (rev A pin -> rev B net).

    python3 gen_revb_mod.py            the pictures
    python3 gen_revb_mod.py --check    only check the tables

Date: 2026-11-17
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen_bringup_boards as B  # noqa: E402

OUT = os.path.join(B.ROOT, 'docs', 'hardware', 'revb_mod')

# pins bent out so they miss the socket: (chip, pin): what the pin is on rev B
LIFT = {
    ('U15', '4'): '/P0',
    ('U15', '21'): 'T2',
    ('U13', '6'): 'T2',
    ('U35', '16'): 'T2',
    ('U35', '21'): 'LC7',
}
# wires: name, color, list of ends (chip, pin, 'pin' = on the lifted or seated chip pin,
# 'hole' = into the socket contact the lifted pin left empty: the board's trace)
WIRES = [
    ('1  T2', '#d81b60', [('U15', '21', 'pin'), ('U13', '6', 'pin')]),
    ('2  T2', '#d81b60', [('U13', '6', 'pin'), ('U35', '16', 'pin')]),
    ('3  /P0', '#1565c0', [('U15', '21', 'hole'), ('U15', '4', 'pin')]),
    ('4  LC7', '#2e7d32', [('U13', '6', 'hole'), ('U35', '21', 'pin')]),
    ('5  /AC_SEL', '#6a1b9a', [('U17', '22', 'pin'), ('U27', '19', 'pin')]),
]
# what the netlists say: the rev A board's trace at a pin, and the rev B net there
NETS = {
    ('U15', '4'): ('V4', '/P0'), ('U15', '21'): ('/P0', 'T2'), ('U13', '6'): ('LC7', 'T2'),
    ('U35', '16'): ('I1', 'T2'), ('U35', '21'): ('/AC_SEL', 'LC7'), ('U17', '22'): (None, '/AC_SEL'),
    ('U27', '19'): ('/AC_SEL', '/AC_SEL'),
}
CHIPS = {'U13': 'H counter', 'U15': 'Sync', 'U35': 'Audio slot', 'U17': 'IR', 'U27': 'AC driver'}


def check():
    """every wire end carries its wire's net: a lifted or untraced pin takes the rev B net,
    a hole gives the rev A trace; every pin whose net changes is lifted, unless rev A has no trace"""
    bad = 0
    for name, _c, ends in WIRES:
        net = name.split()[1]
        for ref, pin, how in ends:
            old, new = NETS[(ref, pin)]
            if how == 'hole':
                ok = old == net and (ref, pin) in LIFT
            else:
                ok = new == net and ((ref, pin) in LIFT or old in (None, net))
            if not ok:
                print('wire %s: %s pin %s (%s) does not fit' % (name, ref, pin, how))
                bad += 1
    for (ref, pin), (old, new) in NETS.items():
        if old not in (None, new) and (ref, pin) not in LIFT:
            print('%s pin %s changes net and is not lifted' % (ref, pin))
            bad += 1
        if old != new and not any((ref, pin, 'pin') in ends for _n, _c, ends in WIRES):
            print('%s pin %s gets no wire' % (ref, pin))
            bad += 1
    for key, net in LIFT.items():
        if NETS[key][1] != net:
            print('lift table: %s pin %s' % key)
            bad += 1
    print('mod tables: %d problems' % bad)
    return bad


def setup():
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    return plt


def board(parts, edge, path):
    plt = setup()
    from matplotlib.patches import Rectangle, Circle
    xs = [p[0] for e in edge for p in e[1:]]
    ys = [p[1] for e in edge for p in e[1:]]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    for p in parts.values():
        b = p.box()
        x0, y0, x1, y1 = min(x0, b[0]), min(y0, b[1]), max(x1, b[2]), max(y1, b[3])
    k = 0.055
    w, h = x1 - x0, y1 - y0
    fig = plt.figure(figsize=(w * k + 0.3, h * k + 0.9))
    ax = fig.add_axes([0.01, 0.01, 0.98, 1 - 0.75 / (h * k + 0.9)])
    ax.set_xlim(x0 - 2, x1 + 2)
    ax.set_ylim(y1 + 2, y0 - 2)
    ax.set_aspect('equal')
    ax.axis('off')
    for e in edge:
        pts = [e[1], e[2]] if e[0] == 'line' else B.arc_points(*e[1:])
        ax.plot([p[0] for p in pts], [p[1] for p in pts], color='#1f5e2e', lw=1.8, zorder=5)
    for ref, p in sorted(parts.items()):
        if ref.startswith(B.NOT_PARTS):
            continue
        st = B.STYLE['now' if ref in CHIPS else 'socket' if ref == 'U16' else 'done']
        bx0, by0, bx1, by1 = p.box()
        if p.circle and not p.pts:
            ax.add_patch(Circle(p.circle[:2], p.circle[2], fc=st['fc'], ec=st['ec'], lw=st['lw'], zorder=st['z']))
        else:
            ax.add_patch(Rectangle((bx0, by0), bx1 - bx0, by1 - by0, fc=st['fc'], ec=st['ec'], lw=st['lw'],
                                   zorder=st['z']))
        bw, bh = bx1 - bx0, by1 - by0
        if ref in CHIPS or max(bw, bh) >= 9:
            ax.text((bx0 + bx1) / 2, (by0 + by1) / 2, ref + (': reprogram only' if ref == 'U16' else ''), ha='center', va='center',
                    rotation=90 if bh > bw * 1.3 else 0, fontsize=6.5,
                    color='#000000' if ref in CHIPS else '#4a4f57',
                    fontweight='bold' if ref in CHIPS else 'normal', zorder=6)
    for name, col, ends in WIRES:
        (ax1, ay1), (ax2, ay2) = [parts[r].pads[n] for r, n, _h in ends]
        ax.plot([ax1, ax2], [ay1, ay2], color=col, lw=2.2, zorder=7, solid_capstyle='round')
        ax.plot([ax1, ax2], [ay1, ay2], 'o', color=col, ms=4, zorder=7)
    # the names: one box for the four short wires at the video PLDs, one on the long wire
    ax.text(306, 112, 'wires 1-4: T2, T2, /P0, LC7\n(see the close-up)', ha='center', va='center', fontsize=8,
            fontweight='bold', color='#333333', zorder=8, bbox=dict(fc='white', ec='#333333', lw=0.6, pad=2))
    (ax1, ay1), (ax2, ay2) = [parts[r].pads[n] for r, n, _h in WIRES[4][2]]
    ax.text((ax1 + ax2) / 2, (ay1 + ay2) / 2, 'wire 5: /AC_SEL', ha='center', va='center', fontsize=8,
            fontweight='bold', color=WIRES[4][1], zorder=8, bbox=dict(fc='white', ec=WIRES[4][1], lw=0.6, pad=2))
    fig.text(0.012, 1 - 0.30 / (h * k + 0.9), 'Rev A board made rev B: the five wires (component side).  '
             'Reprogram U13, U15, U16, U17, U35.', fontsize=13, fontweight='bold', va='center')
    fig.savefig(path, dpi=110)
    plt.close(fig)
    print('wrote', os.path.relpath(path, B.ROOT))


def closeup(parts, refs, wires, title, path, k=0.2, margin=(9, 12, 9, 9), others=True):
    """the chips refs enlarged, the same way up as the board: every pin numbered, the lifted
    pins ringed, the wires; other parts inside the view in gray (others)"""
    plt = setup()
    from matplotlib.patches import Rectangle, Circle
    boxes = [parts[r].box() for r in refs]
    x0 = min(b[0] for b in boxes) - margin[0]
    y0 = min(b[1] for b in boxes) - margin[1]
    x1 = max(b[2] for b in boxes) + margin[2]
    y1 = max(b[3] for b in boxes) + margin[3]
    w, h = x1 - x0, y1 - y0
    fig = plt.figure(figsize=(w * k, h * k + 0.5))
    ax = fig.add_axes([0, 0, 1, h * k / (h * k + 0.5)])
    ax.set_xlim(x0, x1)
    ax.set_ylim(y1, y0)
    ax.set_aspect('equal')
    ax.axis('off')
    for ref, p in sorted(parts.items()):
        if ref in refs or ref.startswith(B.NOT_PARTS) or not others:
            continue
        b = p.box()
        if b[2] < x0 or b[0] > x1 or b[3] < y0 or b[1] > y1:
            continue
        ax.add_patch(Rectangle((b[0], b[1]), b[2] - b[0], b[3] - b[1], fc='#eef0f3', ec='#c3c7ce', lw=0.8,
                               zorder=1, clip_on=True))
        cx, cy = (b[0] + b[2]) / 2, (b[1] + b[3]) / 2
        if x0 + 2 < cx < x1 - 2 and y0 + 2 < cy < y1 - 2 and max(b[2] - b[0], b[3] - b[1]) >= 5:
            ax.text(cx, cy, ref, ha='center', va='center', fontsize=8, color='#9aa0a8', zorder=2,
                    rotation=90 if (b[3] - b[1]) > (b[2] - b[0]) * 1.3 else 0)
    ends = {}                                # (ref, pin) -> [(how, color)]
    for _n, col, es in wires:
        for r, n, how in es:
            ends.setdefault((r, n), []).append((how, col))
    for r in refs:
        p = parts[r]
        b = p.box()
        cx, cy = (b[0] + b[2]) / 2, (b[1] + b[3]) / 2
        vert = (b[3] - b[1]) > (b[2] - b[0])
        ax.add_patch(Rectangle((b[0], b[1]), b[2] - b[0], b[3] - b[1], fc='#fff3df', ec='#8a3d00', lw=1.4,
                               zorder=2))
        label = '%s\n%s PLD' % (r, CHIPS[r]) if r != 'U27' else 'U27\nAC source driver'
        if vert:
            ax.text(cx, b[3] + 5.5, label, ha='center', va='center', fontsize=11, fontweight='bold')
        else:
            ax.text(cx, b[3] + 6, label, ha='center', va='center', fontsize=11, fontweight='bold')
        for num, (x, y) in p.pads.items():
            lifted = (r, num) in LIFT
            used = (r, num) in ends
            if num == '1':
                ax.add_patch(Rectangle((x - 0.8, y - 0.8), 1.6, 1.6, fc='white', ec='#333333', lw=1, zorder=3))
            else:
                ax.add_patch(Circle((x, y), 0.8, fc='white', ec='#333333', lw=1, zorder=3))
            if lifted:
                ax.add_patch(Circle((x, y), 1.45, fc='none', ec='#c62828', lw=2.2, zorder=6))
            if vert:
                dx, dy = (-2.9 if x < cx else 2.9), 0
            else:
                dx, dy = 0, (-2.9 if y < cy else 2.9)
            ax.text(x + dx, y + dy, num, ha='center', va='center', fontsize=9,
                    fontweight='bold' if (lifted or used) else 'normal',
                    color='#c62828' if lifted else ('#000000' if used else '#666666'), zorder=7)
    for name, col, es in wires:
        pts = []
        for r, n, how in es:
            x, y = parts[r].pads[n]
            # a pin that has a wire on the lifted pin and one in its hole: draw them apart
            both = len(set(h for h, _c in ends[(r, n)])) > 1
            pts.append((x, y + (0.55 if how == 'hole' else -0.55) * (1 if both else 0)))
        ax.plot([q[0] for q in pts], [q[1] for q in pts], color=col, lw=3.2, zorder=5, solid_capstyle='round')
        for (x, y), (_r, _n, how) in zip(pts, es):
            ax.plot([x], [y], marker='s' if how == 'hole' else 'o', color=col, ms=7, zorder=5)
        mx, my = (pts[0][0] + pts[1][0]) / 2, (pts[0][1] + pts[1][1]) / 2
        ax.text(mx, my, name, ha='center', va='center', fontsize=9, fontweight='bold', color=col, zorder=8,
                bbox=dict(fc='white', ec=col, lw=1, pad=2))
    fig.text(0.01, 1 - 0.25 / (h * k + 0.5), title, fontsize=11, fontweight='bold', va='center')
    fig.text(0.99, 0.012, 'red ring: pin bent out of the socket    round end: soldered to the chip pin    '
             'square end: pushed into the empty socket contact', fontsize=8.5, ha='right', va='bottom',
             color='#333333')
    fig.savefig(path, dpi=110)
    plt.close(fig)
    print('wrote', os.path.relpath(path, B.ROOT))


def main(argv):
    if check():
        return 1
    if '--check' in argv:
        return 0
    parts, edge = B.read_board(B.BOARD)
    os.makedirs(OUT, exist_ok=True)
    board(parts, edge, os.path.join(OUT, 'revb_mod_board.png'))
    closeup(parts, ['U35', 'U13', 'U15'], WIRES[:4],
            'Wires 1-4 at the video PLDs (component side, same way up as the board; pin 1 is the square pad)',
            os.path.join(OUT, 'revb_mod_video.png'), margin=(10, 5, 10, 13), others=False)
    closeup(parts, ['U27', 'U17'], WIRES[4:],
            'Wire 5, /AC_SEL: U17 pin 22 to U27 pin 19 (component side; pin 1 is the square pad)',
            os.path.join(OUT, 'revb_mod_acsel.png'), k=0.12, margin=(8, 9, 8, 13))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

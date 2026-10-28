#!/usr/bin/env python3
"""
gen_wire3d.py - generate wire3d.masm, an Elite-style 3D demo and benchmark
for the Placard CPU: wireframes with hidden lines removed, and filled faces
painted back to front (a library program for the SD card, WIRE3D.PLC)

    python3 gen_wire3d.py                       wire3d.masm, wire3d.asm, ../../sdcard/WIRE3D.PLC,
                                                wire3d_rom.asm/.hex (build\\wire3d.bat: a ROM build for testing)
    python3 gen_wire3d.py --ships 8 -o w8.masm  another ship count (see ship_set)
    python3 test_wire3d_sim.py                  runs it in placard_sim: checks every frame
                                                against the Python model in this file,
                                                times each part, writes the GIF

WHAT IT DRAWS
    Convex "ships" (stations, freighters, darts, rocks) tumbling and flying
    in front of a fixed camera.  The demo switches between two modes every
    10 seconds, or when a key is pressed:
    - wireframe: white lines on black, an edge drawn when one of its two
      faces looks at the camera (Elite);
    - filled: each face that looks at the camera filled with one of five
      shades (blue, blue/gold, gold, gold/white, white: the 2 bpp palette
      and two dither patterns) by the angle to a light above and to the
      left, ships painted far to near so nearer ones hide farther ones.
    The picture is 320 x 240, 2 bpp, 2x line repeat (square pixels); the
    top 16 screen rows are a 1 bpp text band (title, mode, frames per
    second).  Esc goes back to the DOS (menu_poll).

HOW (the BBC Micro Elite way, adapted to the Placard)
    - Orientation: three angles a ship that turn a little every frame; the
      3x3 matrix comes from a sine table with 14 multiplies (1.0 = 63).
    - Multiply: quarter squares, a*b = q(a+b) - q(a-b), one 256-byte table
      for each scale.  A product is 8 instructions, 32 clocks.
    - Transform: the models' vertices come in chains of mirror images (the
      previous vertex with one coordinate negated), so a rotated vertex is
      often the previous one minus twice one column's products: 3
      subtractions instead of 9 multiplies.
    - Projection: screen x = 160 + X * K / Z with logarithms: a 512-entry
      table of 256 * log2(n) (+ 4096, so log(0) is far below everything)
      and 8 antilog pages, one per octave.  A divide is a 16-bit subtract
      and two look-ups.
    - Faces (as Elite does): the camera's position in the ship's own
      coordinates, c = -M^T o / 126, is worked out once per ship (9 log
      multiplies); a face looks at the camera when n . c > n . p, its
      normal n (scaled to length 100) times c against a constant.  The
      products n_i * c_i come from a small table made once per ship for
      the normal components the model has, so a face costs three 16-bit
      look-ups, two adds and a compare.
    - Lines: a record per line (entry address, start byte, row, error,
      slope, end) is computed once; drawing runs the record through
      unrolled loops (x-major left to right, down or up; y-major top to
      bottom, right or left; one copy per pixel of the byte) that XOR the
      pixel.  Erasing is running the same records again the next frame,
      ship by ship, just before that ship's new lines are drawn.
    - Filled faces: an edge's x is a 16-bit value (x * 64 + 32) stepped
      by a slope from the log tables, so its high byte is the byte column
      and its top 2 low bits the pixel.  A face is filled row by row
      between its left chain of edges and its right one (from its top
      vertex, the faces seen are clockwise on the screen); a row is a
      masked first byte, an unrolled run of whole bytes (6 clocks a byte,
      entered at its first byte and left through a branch patched in after
      its last) and a masked last byte.  Shared edges are stepped the same
      way from the same top vertex, so faces meet without gaps.
    - Erasing filled ships: each ship keeps its outline of the last frame
      (left and right x of every row: an edge between a face seen and one
      not seen moves the side of the row its face is on, an edge between
      two faces seen moves both); before anything is drawn, every ship blanks only
      the part of its old outline that its new outline does not cover,
      then the ships are painted far to near.  A pixel inside a ship is
      never blanked, so there is little flicker without a second buffer.
    - Clipping: a vertex that projects off the picture (or is too close)
      is marked invalid; its edges are not drawn, and in filled mode the
      whole ship is left out that frame.

MEMORY (a library program, docs/DOS.md: RAM x0100-x3FFF)
    x0100-x1EFF, x2000-x22FF  code (asm_expand.py packs the chunks)
    x2300-x3DFF               tables and ship models (TABLES below)
    x3E00-x3FFF               face product table (made per ship)
    x4000-x4FFF               wireframe: line records, two buffers (frame
                              parity), 8 field pages each, up to 255 lines;
                              filled: the new outline, pixel masks, face
                              shades, the shade products, the unrolled row
                              filler (made when filled mode starts)
    x5400-x59FF               projected vertices (SX low, SX high, SY,
                              valid), faces seen, ship state
    x5C00                     transform scratch
    even video pages          filled: each ship's outline of the last frame
                              (2x rows only show the odd pages; the text
                              band's bytes x20-x2F of each page are kept)
    zero page x10-x9F
    It runs with map FF (every section RAM, so the video RAM can be read
    for the XOR) and switches to map 07 only to call the library.

Date: 10/28/2026
"""

import argparse
import math
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

# ---------------------------------------------------------------------------
# constants
# ---------------------------------------------------------------------------
K = 96                      # focal length in pixels
LK = round(256 * math.log2(K))
LOG_OFS = 4096              # added to every log except log(0)
CX = 160                    # screen centre
CY = 124                    # logical line (0-239) of the centre
Y_TOP, Y_BOT = 8, 238       # picture lines (screen rows 16-477)
ZMIN = 48                   # nearest Z (half units)
MODE_PIC = 0x05             # 2 bpp, 2x
MODE_HUD = 0x40             # 1 bpp, 1x, blue tint
HUD_ROWS = 16
NLEN = 100                  # face normals are scaled to this length
LIGHT = (-24, 36, -44)      # direction to the light in camera space (63 = 1)
LG252 = round(256 * math.log2(252)) + 2 * LOG_OFS   # c = -M^T o / 252 (half of c)
LG100 = round(256 * math.log2(100)) + 2 * LOG_OFS   # shade = n . L' / 100
SHADE_T = (6, 20, 34, 48)   # the five shades: n . L' (63 = 1) below 6, 20, 34, 48, above
SHADES = [(1, 1), (1, 2), (2, 2), (2, 3), (3, 3)]  # pixel pairs: blue, blue/gold, gold, gold/white, white
MODE_SECS = 10              # seconds between the mode switches

# table pages
P_QV, P_QM, P_SIN, P_ROW = 0x23, 0x24, 0x25, 0x26
P_LGL, P_LGH = 0x27, 0x29   # two pages each (n < 256, n >= 256)
P_CPG = 0x2B                # two pages; ENT tables in the second one
P_ANT = 0x2D                # 8 pages
P_MV = 0x35                 # model vertices: VX x00, VY x40, VZ x80, MIR xC0
P_MF = 0x36                 # faces: FS (first vertex in FVL) x00, FN (vertices) x40, FIX x80, FIY xC0
P_MF2 = 0x37                # FIZ x00, D1L x40, D1H x80
P_ME = 0x38                 # edges: EV1 x00, EV2 x80
P_ME2 = 0x39                # EF1 x00, EF2 x80
P_ME3 = 0x3A                # EDIR x00 (1: face 1 goes v1 -> v2)
P_FVL = 0x3B                # face vertex lists
P_TE = 0x3C                 # product table entries: TA (axis) x00, TUL x40, TUH x80 (log of u), TKP xC0
P_TE2 = 0x3D                # TKN x00 (the negative's index, 255: none)
P_SC = 0x3E                 # ship constants, 16 each: rates x00-x3F, model MV x40, NV x50, MF x60,
                            # NF x70, ME x80, NE x90, TB xA0, NT xB0, vertex base xC0, face base xD0,
                            # the ship's path code xE0 (low), xF0 (high)
P_SC2 = 0x3F                # initial angles x00, x10, x20; the strings
P_MISC = 0x2C               # in the CPG page: XLO (x16 low byte of pixel phase) x40,
                            # LMK4 x44, RMK4 x48 (the masks of pixels from / before a phase)
ENTL = 0x80                 # in page P_CPG + 1
ENTH = 0xA0
XLO, LMK4, RMK4 = 0x40, 0x44, 0x48
# runtime pages
P_REC = (0x40, 0x48)        # wireframe: record buffers 0 and 1, 8 field pages each
P_NLH, P_NLL, P_NRH, P_NRL = 0x40, 0x41, 0x42, 0x43   # filled: the new outline
P_LMK, P_RMK = 0x44, 0x45   # filled: byte masks of the pixels from / before x (by x16 low)
P_FC0, P_FC1 = 0x46, 0x47   # filled: each face's color byte, even and odd lines
P_FILL = 0x4F               # filled: the unrolled row filler
P_SXL, P_SXH, P_SY, P_VAL, P_FV, P_SHIP = 0x54, 0x55, 0x56, 0x57, 0x58, 0x59
P_FCV = 0x5C                # a face's projected vertices: x low x00, x high x10, y x20
# the product tables live in even video pages (2x rows show only the odd
# ones; offsets x20-x2F are the text band, so the indexes start at KB)
P_TL, P_TH, P_B = 0xE0, 0xE2, 0xE4
KB = 0x30                   # index of the 0 entry; the others follow
# ship page: s * 8 + (a1, a2, a3, t, old records start, end, old outline top, bottom),
# then per ship OZ low/high (sort keys), the draw order, drawn
SH_OZL, SH_OZH, SH_ORD, SH_DRAWN = 0x80, 0x90, 0xA0, 0xB0
MAX_SHIPS = 16
FILL_STUB = 240             # the filler's return stub
OP_LDY, OP_STYX, OP_BRA, OP_LDYM, OP_JMPM = 0x10, 0x1E, 0xFC, 0x11, 0xE1
EMPTY_L = 0x78              # an empty outline row: left x16 high byte (right: 0)

MASK = [0x03, 0x0C, 0x30, 0xC0]
VARIANTS = ['xd', 'xu', 'td', 'tu', 'yr', 'yl']   # entry table order, 4 phases each


def fp_page(s, k):
    """ship s's outline page k (0 left high, 1 left low, 2 right high, 3 right low)"""
    return 0x60 + 8 * s + 2 * k


def ri_of(l):
    """the index of line l in an outline page (skips x20-x2F, the text band)"""
    return (l + 0x30) & 0xFF


# ---------------------------------------------------------------------------
# tables
# ---------------------------------------------------------------------------
def s8(v):
    return v - 256 if v >= 128 else v


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v >= 0x8000 else v


def tables():
    t = {}
    t['QV'] = [round(s8(n) ** 2 / 126) & 0xFF for n in range(256)]
    t['QM'] = [round(s8(n) ** 2 / 252) & 0xFF for n in range(256)]
    t['SIN'] = [round(63 * math.sin(2 * math.pi * i / 256)) & 0xFF for i in range(256)]
    t['ROW'] = [row_off(l) for l in range(256)]
    lg = [0] + [round(256 * math.log2(n)) + LOG_OFS for n in range(1, 512)]
    t['LG'] = lg
    t['ANT'] = [[min(255, round(2 ** (k + f / 256))) for f in range(256)] for k in range(8)]
    t['CPG'] = [(0x61 + 2 * (sx >> 2)) if sx < 320 else 0 for sx in range(512)]
    return t


def row_off(l):
    """low byte of logical line l's address in its byte column (2x rows)"""
    v = 32 + 2 * l
    return ((v & 0xFE) | ((v >> 8) & 1)) & 0xFF if l < 240 else 0


TAB = tables()


def antilog(s):
    """r for a 16-bit S as the program does it: None if r >= 256"""
    hi = (s >> 8) & 0xFF
    if hi >= 128:
        return 0
    if hi >= 8:
        return None
    return TAB['ANT'][hi][s & 0xFF]


def antilog16(s):
    """a 16-bit result: 2^(S/256), 1 for -1 <= S/256 < 0, 0 below"""
    s &= 0xFFFF
    hi, lo = s >> 8, s & 0xFF
    if hi >= 128:
        return 1 if hi == 0xFF else 0
    if hi < 8:
        return TAB['ANT'][hi][lo]
    assert hi <= 14, hi
    return (TAB['ANT'][7][lo] << (hi - 7)) & 0xFFFF


def lg(n):
    return TAB['LG'][n]


def qmul(q, a, b):
    return (q[(a + b) & 0xFF] - q[(a - b) & 0xFF]) & 0xFF


# ---------------------------------------------------------------------------
# models: convex hulls of integer points (|v| <= 60), faces as polygons
# ---------------------------------------------------------------------------
def sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def hull(pts):
    """(faces as vertex lists ordered so (b-a) x (c-a) points out, their
    outward normals, edges as (v1, v2, f1, f2, 1 if f1 goes v1 -> v2))"""
    n = len(pts)
    planes = {}
    for i in range(n):
        for j in range(i + 1, n):
            for k in range(j + 1, n):
                nv = cross(sub(pts[j], pts[i]), sub(pts[k], pts[i]))
                if nv == (0, 0, 0):
                    continue
                ds = [dot(nv, sub(p, pts[i])) for p in pts]
                if all(d <= 0 for d in ds):
                    pass
                elif all(d >= 0 for d in ds):
                    nv = (-nv[0], -nv[1], -nv[2])
                else:
                    continue
                g = math.gcd(math.gcd(abs(nv[0]), abs(nv[1])), abs(nv[2]))
                key = (nv[0] // g, nv[1] // g, nv[2] // g, dot(nv, pts[i]) // g)
                planes[key] = nv
    faces, normals = [], []
    for key, nv in planes.items():
        on = [i for i in range(n) if dot(key[:3], pts[i]) == key[3]]
        cx = [sum(pts[i][c] for i in on) / len(on) for c in range(3)]
        # an in-plane basis
        u = sub(pts[on[0]], cx)
        w = cross(nv, u)
        ang = lambda i: math.atan2(dot(sub(pts[i], cx), w), dot(sub(pts[i], cx), u))
        poly = sorted(on, key=ang)
        a, b, c = (pts[poly[0]], pts[poly[1]], pts[poly[2]])
        if dot(cross(sub(b, a), sub(c, a)), nv) < 0:
            poly.reverse()
        faces.append(poly)
        normals.append(nv)
    edges = {}
    for fi, poly in enumerate(faces):
        for k in range(len(poly)):
            a, b = poly[k], poly[(k + 1) % len(poly)]
            edges.setdefault((min(a, b), max(a, b)), []).append((fi, a < b))
    elist = []
    for (a, b), fs in sorted(edges.items()):
        assert len(fs) == 2 and fs[0][1] != fs[1][1], (a, b, fs)
        elist.append((a, b, fs[0][0], fs[1][0], 1 if fs[0][1] else 0))
    return faces, normals, elist


def mirror_order(pts):
    """the vertices in chains of mirror images: (order, mir), mir[k] = 0 for
    a vertex worked out in full, 1 + axis for the previous one with that
    coordinate negated"""
    n = len(pts)
    used = [False] * n
    order, mir = [], []

    def mirror(p, q):
        for a in range(3):
            if p[a] != 0 and q[a] == -p[a] and all(q[b] == p[b] for b in range(3) if b != a):
                return a + 1
        return 0
    for start in range(n):
        if used[start]:
            continue
        cur = start
        used[cur] = True
        order.append(cur)
        mir.append(0)
        while True:
            nxt = None
            for j in range(n):
                if not used[j] and mirror(pts[cur], pts[j]):
                    nxt = j
                    break
            if nxt is None:
                break
            mir.append(mirror(pts[cur], pts[nxt]))
            cur = nxt
            used[cur] = True
            order.append(cur)
    return order, mir


def model_points():
    m = {}
    a = 42
    m['station'] = [(sx * a, sy * a, 0) for sx in (-1, 1) for sy in (-1, 1)] + \
                   [(sx * a, 0, sz * a) for sx in (-1, 1) for sz in (-1, 1)] + \
                   [(0, sy * a, sz * a) for sy in (-1, 1) for sz in (-1, 1)]
    m['freighter'] = [(0, 6, 56), (-18, 12, 30), (18, 12, 30), (-52, 0, -8), (52, 0, -8),
                      (-34, 12, -34), (34, 12, -34), (-34, -10, -34), (34, -10, -34),
                      (-14, -10, 30), (14, -10, 30)]
    m['dart'] = [(0, 0, 58), (-40, -6, -30), (40, -6, -30), (0, 16, -26), (0, -10, -30),
                 (-12, 4, -40), (12, 4, -40)]
    p = (1 + math.sqrt(5)) / 2
    s = 58 / math.sqrt(1 + p * p)
    m['rock'] = [tuple(round(v) for v in q) for q in
                 [(0, sy * s, sz * s * p) for sy in (-1, 1) for sz in (-1, 1)] +
                 [(sx * s, sy * s * p, 0) for sx in (-1, 1) for sy in (-1, 1)] +
                 [(sx * s * p, 0, sz * s) for sx in (-1, 1) for sz in (-1, 1)]]
    for name, pts in m.items():
        for q in pts:
            assert dot(q, q) <= 60 * 60, (name, q)
    return m


def models():
    out = {}
    for name, pts0 in model_points().items():
        order, mir = mirror_order(pts0)
        pts = [pts0[i] for i in order]
        faces, normals, edges = hull(pts)
        ns = []
        for nv in normals:
            ln = math.sqrt(dot(nv, nv))
            ns.append(tuple(round(NLEN * c / ln) for c in nv))
        # the product table: index KB is 0, then each |n_a| (and its negative)
        tent, kmap, k = [], {}, KB + 1
        for a in range(3):
            for u in sorted({abs(n[a]) for n in ns} - {0}):
                kp = k
                k += 1
                kn = None
                if any(n[a] == -u for n in ns):
                    kn = k
                    k += 1
                tent.append((a, u, kp, kn))
                kmap[(a, u)] = kp
                kmap[(a, -u)] = kn
        assert k < 255
        fidx = [tuple(kmap[(a, n[a])] if n[a] else KB for a in range(3)) for n in ns]
        d1 = []
        for f, n in zip(faces, ns):
            c = [sum(pts[i][a] for i in f) / len(f) for a in range(3)]
            d1.append(round(dot(n, c) / 128) + 1)
        out[name] = {'v': pts, 'mir': mir, 'f': faces, 'n': ns, 'e': edges,
                     'tent': tent, 'fidx': fidx, 'd1': d1}
    return out


MODELS = models()

# ship sets: (model, angles, angle rates, path rate, X, Y, Z) with
# X/Y/Z = (centre, k, phase): centre + (sin(t + phase) << k), or k None: centre
SHIPS = [('station', (0, 20, 0), (1, 0, 2), 0, (-150, None, 0), (140, None, 0), (380, None, 0)),
         ('freighter', (64, 0, 20), (1, 0, 0), 1, (0, 1, 0), (-80, None, 0), (300, 0, 64)),
         ('dart', (64, 0, 236), (2, 0, 0), 2, (130, 0, 0), (40, None, 0), (270, 0, 64)),
         ('dart', (192, 10, 0), (255, 1, 3), 255, (-130, 0, 0), (-40, None, 0), (250, 0, 64)),
         ('rock', (10, 40, 70), (1, 2, 1), 1, (170, None, 0), (150, None, 0), (390, None, 0)),
         ('rock', (0, 0, 0), (2, 1, 2), 2, (40, None, 0), (190, None, 0), (390, None, 0)),
         ('dart', (50, 0, 0), (1, 2, 3), 1, (-200, None, 0), (-150, None, 0), (380, None, 0)),
         ('freighter', (0, 0, 30), (1, 1, 1), 1, (190, None, 0), (-160, None, 0), (390, None, 0)),
         ('rock', (30, 0, 90), (1, 1, 2), 1, (0, None, 0), (-210, None, 0), (380, None, 0)),
         ('dart', (90, 9, 9), (2, 1, 1), 1, (-260, None, 0), (60, None, 0), (390, None, 0)),
         ('rock', (70, 3, 30), (2, 2, 1), 1, (270, None, 0), (20, None, 0), (390, None, 0)),
         ('dart', (40, 9, 9), (1, 3, 1), 1, (-60, None, 0), (20, None, 0), (390, None, 0))]
DEMO_SHIPS = 6


def ship_set(n):
    assert 1 <= n <= len(SHIPS), n
    return SHIPS[:n]


# ---------------------------------------------------------------------------
# the Python model of everything the program computes (integer-exact)
# ---------------------------------------------------------------------------
def sinpos(t, c, k, ph):
    if k is None:
        return c
    s = s8(TAB['SIN'][(t + ph) & 0xFF])
    return (c + (s << k)) & 0xFFFF


def edge_dda(xt, yt, xb, yb):
    """an edge's (x16 at its top line, slope): x16 = x * 64 + 32, stepped by
    the slope each line down (16 bits)"""
    dy = yb - yt
    dx = xb - xt
    if dy == 1:
        slope = 0
    else:
        r = antilog16(lg(abs(dx)) - lg(dy) + 1536)
        slope = (-r) & 0xFFFF if dx < 0 else r
    return (xt * 64 + 32) & 0xFFFF, slope


def span_px(xl, xr):
    """the pixels [a, b) the span routine fills for x16 values xl, xr"""
    a = s16(xl)
    a = 0 if a < 0 else a >> 6
    b = s16(xr)
    if b < 0 or a >= 320:
        return 0, 0
    b = min(320, b >> 6)
    return a, max(a, b)


def face_spans(pts):
    """the rows (line, x16 left, x16 right) the fill makes for a face whose
    projected vertices are pts (clockwise on the screen), as the program does"""
    k = len(pts)
    ys = [p[1] for p in pts]
    ytop, ybot = min(ys), max(ys)
    jt = ys.index(ytop)
    st = {}

    def advance(c, step):
        j = st[c][0]
        for _ in range(k):
            nj = (j + step) % k
            if ys[nj] > ys[j]:
                x16, sl = edge_dda(pts[j][0], ys[j], pts[nj][0], ys[nj])
                st[c] = [nj, x16, sl, ys[nj]]
                return True
            j = nj
            st[c][0] = j
        return False
    st['L'] = [jt, 0, 0, ytop]
    st['R'] = [jt, 0, 0, ytop]
    out = []
    y = ytop
    while y != ybot:
        if y == st['L'][3] and not advance('L', -1):
            break
        if y == st['R'][3] and not advance('R', 1):
            break
        n = min(st['L'][3], st['R'][3]) - y
        if n <= 0:
            break
        for _ in range(n):
            out.append((y, st['L'][1], st['R'][1]))
            st['L'][1] = (st['L'][1] + st['L'][2]) & 0xFFFF
            st['R'][1] = (st['R'][1] + st['R'][2]) & 0xFFFF
            y += 1
    return out


class Model:
    """the program's state after each frame, computed the same way"""

    def __init__(self, ships):
        self.ships = ships
        self.state = [[s[1][0], s[1][1], s[1][2], 0] for s in ships]

    def matrix(self, a1, a2, a3):
        S = lambda a: s8(TAB['SIN'][a & 0xFF]) & 0xFF
        C = lambda a: s8(TAB['SIN'][(a + 64) & 0xFF]) & 0xFF
        q = TAB['QM']
        s1, c1, s2, c2, s3, c3 = S(a1), C(a1), S(a2), C(a2), S(a3), C(a3)
        p, qq = qmul(q, s2, s1), qmul(q, s2, c1)
        m = [0] * 9
        m[0] = (qmul(q, c3, c1) - qmul(q, s3, p)) & 0xFF
        m[1] = (-qmul(q, s3, c2)) & 0xFF
        m[2] = (qmul(q, c3, s1) + qmul(q, s3, qq)) & 0xFF
        m[3] = (qmul(q, s3, c1) + qmul(q, c3, p)) & 0xFF
        m[4] = qmul(q, c3, c2)
        m[5] = (qmul(q, s3, s1) - qmul(q, c3, qq)) & 0xFF
        m[6] = (-qmul(q, c2, s1)) & 0xFF
        m[7] = s2
        m[8] = qmul(q, c2, c1)
        return m

    def project(self, M, ox, oy, oz, v):
        q = TAB['QV']
        vx, vy, vz = (c & 0xFF for c in v)
        dotr = lambda r: (qmul(q, M[3 * r], vx) + qmul(q, M[3 * r + 1], vy) +
                          qmul(q, M[3 * r + 2], vz)) & 0xFF
        xr, yr, zr = dotr(0), dotr(1), dotr(2)
        Z = (oz + s8(zr)) & 0xFFFF
        if Z >> 8 >= 2 or Z < ZMIN:
            return None
        D = (LK - lg(Z)) & 0xFFFF

        def r_of(Wl):
            W = (Wl + 0) & 0xFFFF
            neg = W >= 0x8000
            Mg = (-W) & 0xFFFF if neg else W
            if Mg >> 8 >= 2:
                return None, neg
            r = antilog((lg(Mg) + D) & 0xFFFF)
            return r, neg
        r, neg = r_of(ox + s8(xr))
        if r is None:
            return None
        if neg:
            sx = 160 - r
            if sx < 0:
                return None
        else:
            if r > 159:
                return None
            sx = 160 + r
        r, neg = r_of(oy + s8(yr))
        if r is None:
            return None
        if neg:
            if r > Y_BOT - CY:
                return None
            sy = CY + r
        else:
            if r > CY - Y_TOP:
                return None
            sy = CY - r
        return sx, sy

    @staticmethod
    def camera(M, o):
        """c / 2: the camera in the ship's coordinates (model units / 2)"""
        cp = []
        for a in range(3):
            acc = 0
            for i in range(3):
                m = s8(M[3 * i + a])
                assert abs(o[i]) <= 511, o
                r = antilog((lg(abs(m)) + lg(abs(o[i])) - LG252) & 0xFFFF)
                assert r is not None
                neg = not ((m < 0) ^ (o[i] < 0))
                acc += -r if neg else r
            cp.append(acc)
        return cp

    @staticmethod
    def products(mdl, cv, lgsub):
        """the table of n_a * cv_a (8 bits, as 2^((log n_a + log |cv_a| - lgsub) / 256))
        for the model's normal components"""
        t = {KB: 0}
        for a, u, kp, kn in mdl['tent']:
            c = cv[a]
            r = antilog((lg(u) + lg(abs(c)) - lgsub) & 0xFFFF)
            assert r is not None, (u, c)
            v = -r if c < 0 else r
            t[kp] = v
            if kn is not None:
                t[kn] = -v
        return t

    def faces(self, mdl, cp):
        t = self.products(mdl, cp, 2 * LOG_OFS + 1536)
        vis = []
        for (ix, iy, iz), d1 in zip(mdl['fidx'], mdl['d1']):
            vis.append(t[ix] + t[iy] + t[iz] - d1 >= 0)
        return vis

    def shades(self, M, mdl, vis):
        q = TAB['QM']
        lp = []
        for j in range(3):
            acc = 0
            for i in range(3):
                acc += qmul(q, M[3 * i + j], LIGHT[i] & 0xFF)
            lp.append(s8(acc & 0xFF))
        t = self.products(mdl, lp, LG100)
        lev = []
        for (ix, iy, iz), v in zip(mdl['fidx'], vis):
            b = s8((t[ix] + t[iy] + t[iz]) & 0xFF)
            lev.append(sum(1 for th in SHADE_T if b >= th) if b >= 0 else 0)
        return lev

    def frame(self):
        """advance one frame: a dict per ship (pv, vis, lines, drawn, lev, oz)"""
        out = []
        for si, sh in enumerate(self.ships):
            name, _, rates, prate, PX, PY, PZ = sh
            st = self.state[si]
            for k in range(3):
                st[k] = (st[k] + rates[k]) & 0xFF
            st[3] = (st[3] + prate) & 0xFF
            t = st[3]
            ox, oy, oz = (s16(sinpos(t, *P)) for P in (PX, PY, PZ))
            M = self.matrix(*st[:3])
            mdl = MODELS[name]
            pv = [self.project(M, ox, oy, oz, v) for v in mdl['v']]
            vis = self.faces(mdl, self.camera(M, (ox, oy, oz)))
            lines = []
            for v1, v2, f1, f2, _ in mdl['e']:
                if (vis[f1] or vis[f2]) and pv[v1] and pv[v2]:
                    lines.append(pv[v1] + pv[v2])
            out.append({'pv': pv, 'vis': vis, 'lines': lines, 'drawn': None not in pv,
                        'lev': self.shades(M, mdl, vis), 'oz': oz, 'name': name})
        return out


def line_pixels(x0, y0, x1, y1):
    """the pixels the line code draws for a line, as (x, line) in order"""
    dx, dy = x1 - x0, y1 - y0
    adx, ady = abs(dx), abs(dy)

    def slope(num, den):
        if num == den:
            return 255, 255
        s = (lg(num) - lg(den) + 2048) & 0xFFFF
        hi = s >> 8
        if hi >= 128:
            return 0, 128
        if hi >= 8:
            return 255, 128
        return TAB['ANT'][hi][s & 0xFF], 128
    px = []
    if adx >= ady:
        frac, err = slope(ady, adx)
        if dx < 0:
            x0, y0, x1, y1 = x1, y1, x0, y0
        step = 1 if y1 > y0 else -1
        y = y0
        for x in range(x0, x1 + 1):
            px.append((x, y))
            err += frac
            if err >= 256:
                err -= 256
                y += step
    else:
        frac, err = slope(adx, ady)
        if dy < 0:
            x0, y0, x1, y1 = x1, y1, x0, y0
        step = 1 if x1 > x0 else -1
        x = x0
        for y in range(y0, y1 + 1):
            px.append((x, y))
            err += frac
            if err >= 256:
                err -= 256
                x += step
    return px


def screen_of(ships):
    """the wireframe picture: lit (x, line) -> 3 of the XOR of all the lines"""
    lit = set()
    for d in ships:
        for ln in d['lines']:
            for p in line_pixels(*ln):
                lit ^= {p}
    return {p: 3 for p in lit}


def shade_bytes(lev):
    a, b = SHADES[lev]
    return a | b << 2 | a << 4 | b << 6, b | a << 2 | b << 4 | a << 6


def draw_order(ships):
    return sorted(range(len(ships)), key=lambda s: (-ships[s]['oz'], s))


def screen_fill(ships):
    """the filled picture: (x, line) -> pixel value (0 left out), painted far to near"""
    pic = {}
    for s in draw_order(ships):
        d = ships[s]
        if not d['drawn']:
            continue
        mdl = MODELS[d['name']]
        for f, poly in enumerate(mdl['f']):
            if not d['vis'][f]:
                continue
            ce, co = shade_bytes(d['lev'][f])
            for l, xl, xr in face_spans([d['pv'][i] for i in poly]):
                cb = co if l & 1 else ce
                a, b = span_px(xl, xr)
                for x in range(a, b):
                    pic[(x, l)] = (cb >> (2 * (x & 3))) & 3
    return {p: v for p, v in pic.items() if v}


def ship_extent(d):
    """the outline the program keeps for a ship drawn: rows ntop to nbot, each
    the least x16 of the left edges of the faces seen that cross the row and
    the greatest of the right edges (a face seen but inverted on the screen,
    which fills nothing, may give an end that is not filled)"""
    mdl = MODELS[d['name']]
    pv, vis = d['pv'], d['vis']
    ys = [p[1] for p in pv]
    ntop, nbot = min(ys), max(ys)
    rows = {l: (EMPTY_L << 8, 0) for l in range(ntop, nbot)}
    for v1, v2, f1, f2, ed in mdl['e']:
        if not (vis[f1] or vis[f2]) or ys[v1] == ys[v2]:
            continue
        if vis[f1] and vis[f2]:
            side = 3                    # between two faces seen: either end of a row
            a, b = (v1, v2) if ys[v1] < ys[v2] else (v2, v1)
        else:                           # on the outline: down the face seen is its right side
            a, b = (v1, v2) if ed ^ vis[f1] ^ 1 else (v2, v1)
            side, a, b = (2, a, b) if ys[b] > ys[a] else (1, b, a)
        x16, sl = edge_dda(pv[a][0], ys[a], pv[b][0], ys[b])
        for l in range(ys[a], ys[b]):
            L, R = rows[l]
            v = s16(x16)
            rows[l] = (min(L, v) if side & 1 else L, max(R, v) if side & 2 else R)
            x16 = (x16 + sl) & 0xFFFF
    return ntop, nbot, rows


class FillScreen:
    """the filled picture as the program leaves it: each ship blanks what its
    outline of the last frame has and this frame's does not, then the faces
    are painted far to near (the same as screen_fill but where a face that
    looks at the camera is inverted on the screen, a pixel or so)"""

    def __init__(self, n):
        self.pic = {}
        self.old = [(0, 0, {}) for _ in range(n)]

    def span(self, l, xl, xr, cb):
        a, b = span_px(xl & 0xFFFF, xr & 0xFFFF)
        for x in range(a, b):
            v = (cb >> (2 * (x & 3))) & 3
            if v:
                self.pic[(x, l)] = v
            else:
                self.pic.pop((x, l), None)

    def frame(self, ships):
        for s, d in enumerate(ships):
            ntop, nbot, new = ship_extent(d) if d['drawn'] else (0, 0, {})
            otop, obot, old = self.old[s]
            for y0, y1 in ((otop, min(obot, ntop)), (max(otop, nbot), obot)):
                for l in range(y0, y1):
                    self.span(l, old[l][0], old[l][1], 0)
            for l in range(max(otop, ntop), min(obot, nbot)):
                oL, oR = old[l]
                nL, nR = new[l]
                xr = nL if nL < oR else oR
                if oL < xr:
                    self.span(l, oL, xr, 0)
                xl = nR if nR > oL else oL
                if xl < oR:
                    self.span(l, xl, oR, 0)
            self.old[s] = (ntop, nbot, new)
        for s in draw_order(ships):
            d = ships[s]
            if not d['drawn']:
                continue
            mdl = MODELS[d['name']]
            for f, poly in enumerate(mdl['f']):
                if not d['vis'][f]:
                    continue
                ce, co = shade_bytes(d['lev'][f])
                for l, xl, xr in face_spans([d['pv'][i] for i in poly]):
                    self.span(l, xl, xr, co if l & 1 else ce)
        return dict(self.pic)


# ---------------------------------------------------------------------------
# assembly
# ---------------------------------------------------------------------------
class Gen:
    def __init__(self):
        self.out = []
        self.n = 0

    def lab(self, base):
        self.n += 1
        return '%s_%d' % (base, self.n)

    def chunk(self, comment=''):
        self.out.append('')
        self.out.append('.chunk' + ('                          ; ' + comment if comment else ''))

    def fixed(self, addr, comment=''):
        self.out.append('')
        self.out.append('.fixed 0x%04X' % addr + ('                    ; ' + comment if comment else ''))

    def __call__(self, text):
        for ln in text.strip('\n').split('\n'):
            s = ln.rstrip()
            if not s:
                continue
            if s.startswith((' ', ';', '#', '.')) or s.endswith(':'):
                self.out.append(s)
            else:
                self.out.append('    ' + s)

    def tick(self):
        """count a video frame when the line read went down (frame_poll inline)"""
        n = self.lab('tk')
        self('''
    ld   0x50, y               ; tick: line read (V9:V2)
    ld   [y,x], ac
    ld   ac, [w_t]
    sub  [LINE_LAST], ac
    ld   [w_t], ac
    ld   ac, [LINE_LAST]
    bcc  %s
    ld   [FRAME_LO], ac
    inc
    ld   ac, [FRAME_LO]
    bcc  %s
    ld   [FRAME_HI], ac
    inc
    ld   ac, [FRAME_HI]
%s:''' % (n, n, n))

    def mul(self, a, b):
        """AC = q(a + b) - q(a - b), Y = the table page"""
        self('''
    ld   [%s], ac
    add  [%s], x
    ld   [y,x], ac
    ld   ac, [w_t]
    ld   [%s], ac
    sub  [%s], x
    ld   [w_t], ac
    sub  [y,x], ac''' % (a, b, a, b))

    def call2(self, name, link):
        """call name, which returns through the zero-page pair link (lo, hi)"""
        back = self.lab('rt')
        self('''
    ld   %(l)s_l, x
    ld   %(b)s & 0xFF, [x]
    ld   %(l)s_h, x
    ld   %(b)s >> 8, [x]
    ld   %(n)s >> 8, y
    jmp  %(n)s
%(b)s:''' % {'l': link, 'b': back, 'n': name})

    def ret2(self, link):
        self('''
    ld   [%s_h], y
    jmp  [%s_l]''' % (link, link))

    def neg16(self, lo, hi):
        n = self.lab('ng')
        self('''
    ld   [%(lo)s], ac
    xor  255, ac
    add  1, ac
    ld   ac, [%(lo)s]
    ld   [%(hi)s], ac
    xor  255, ac
    bcc  %(n)s
    inc
%(n)s:
    ld   ac, [%(hi)s]''' % {'lo': lo, 'hi': hi, 'n': n})

    def add16(self, dl_, dh_, sl_, sh_):
        """(dh:dl) += (sh:sl)"""
        n = self.lab('a6')
        self('''
    ld   [%(dl)s], ac
    add  [%(sl)s], ac
    ld   ac, [%(dl)s]
    ld   [%(dh)s], ac
    bcc  %(n)s
    inc
%(n)s:
    add  [%(sh)s], ac
    ld   ac, [%(dh)s]''' % {'dl': dl_, 'dh': dh_, 'sl': sl_, 'sh': sh_, 'n': n})

    def antilog16(self, sl_, sh_, rl, rh, tmp):
        """(rh:rl) = antilog16 of (sh:sl), as the Python antilog16"""
        neg, big, done, zero, sh_l, s0, s1 = (self.lab('al') for _ in range(7))
        self('''
    ld   [%(sh)s], ac
    blt  %(neg)s
    sub  8, ac
    bcc  %(big)s
    ld   [%(sh)s], ac
    add  0x%(ant)02X, y
    ld   [%(sl)s], x
    ld   [y,x], ac
    ld   ac, [%(rl)s]
    ld   0, ac
    ld   ac, [%(rh)s]
    bra  %(done)s
%(neg)s:
    xor  255, ac
    bne  %(zero)s
    ld   1, ac
    ld   ac, [%(rl)s]
    ld   0, ac
    ld   ac, [%(rh)s]
    bra  %(done)s
%(zero)s:
    ld   0, ac
    ld   ac, [%(rl)s]
    ld   ac, [%(rh)s]
    bra  %(done)s
%(big)s:
    ld   ac, [%(tmp)s]
    ld   0x%(ant7)02X, y
    ld   [%(sl)s], x
    ld   [y,x], ac
    ld   ac, [%(rl)s]
    ld   0, ac
    ld   ac, [%(rh)s]
%(shl)s:
    ld   [%(rl)s], ac
    shl
    ld   ac, [%(rl)s]
    ld   [%(rh)s], ac
    bcc  %(s0)s
    shl
    or   1, ac
    bra  %(s1)s
%(s0)s:
    shl
%(s1)s:
    ld   ac, [%(rh)s]
    ld   [%(tmp)s], ac
    sub  1, ac
    ld   ac, [%(tmp)s]
    bcc  %(shl)s
%(done)s:''' % {'sl': sl_, 'sh': sh_, 'rl': rl, 'rh': rh, 'tmp': tmp, 'ant': P_ANT,
                'ant7': P_ANT + 7, 'neg': neg, 'big': big, 'done': done, 'zero': zero,
                'shl': sh_l, 's0': s0, 's1': s1})


# zero page (x20-x9F): the common part ZP from x20, then three groups on
# top of each other from where it ends: ZP_XF (matrix to faces, every ship),
# ZP_WIRE (line records and drawing) and ZP_FILL (outline, erase, fill), as
# they are never needed at the same time.  ZP_LOW goes to R0-T7 (x10-x1F,
# the library's scratch: values that never live across a library call),
# the transform's part and the filled part on top of each other.
ZP = ['mode', 'msec', 'nrec', 'nst', 'par', 'lps', 'fps', 'secf', 'lastf',
      'shs', 'shs8', 'nfac', 'a1', 'a2', 'a3', 'tt',
      'vb', 'fb', 'vi', 'vo', 'vn', 'nvs', 'allv', 'fi', 'fo', 'fn', 'ti', 'tn', 'ei', 'en',
      'oxl', 'oxh', 'oyl', 'oyh', 'ozl', 'ozh', 'pl', 'phh', 'fr_l', 'fr_h', 'lk_sc_l', 'lk_sc_h',
      'w_t', 'w_t2', 'w_t3', 'w_t4', 'w_acc', 'w_r', 'w_a', 'w_b', 'w_c', 'w_s', 'sl', 'sh']
ZP_XF = ['m0', 'm1', 'm2', 'm3', 'm4', 'm5', 'm6', 'm7', 'm8',
         's1', 'c1', 's2', 'c2', 's3', 'c3', 'w_p', 'w_q',
         'zl', 'zh', 'dl', 'dh', 'ml', 'mh', 'bxl', 'bxh',
         'lgc0', 'lgc1', 'lgc2', 'lgh0', 'lgh1', 'lgh2', 'sgc0', 'sgc1', 'sgc2',
         'lgl0', 'lgl1', 'lgl2', 'lgk0', 'lgk1', 'lgk2', 'sgl0', 'sgl1', 'sgl2', 'w_kp', 'w_kn',
         'w_ci', 'w_osg']
ZP_WIRE = ['wbl', 'wbh', 'ev1', 'ev2', 'x0l', 'x0h', 'y0', 'x1l', 'x1h', 'y1',
           'dxl', 'dxh', 'adxl', 'adxh', 'ady', 'sgx', 'sgy', 'by', 'exl', 'exh', 'ey',
           'dirf', 'ph', 'ehi', 'err', 'frac', 'pg', 'off', 'endv', 'ntail', 'jlo',
           'rk', 'rend', 'rlo', 'rhi']
ZP_FILL = ['xLl', 'xLh', 'xRl', 'xRh', 'lc', 'lp', 'rc', 'rp', 'roff', 'cb', 'cbx', 'c0',
           'w_nm', 'w_cm', 'w_e', 'w_pp', 'w_slow',
           'lk_sp_l', 'lk_sp_h', 'lk_av_l', 'lk_av_h', 'lk_es_l', 'lk_es_h', 'lk_ef_l', 'lk_ef_h',
           'uxl', 'uxh', 'uy', 'wxl', 'wxh', 'wy', 'e16l', 'e16h', 'esl', 'esh',
           'w_dy', 'w_dxl', 'w_dxh', 'w_sg',
           'slLl', 'slLh', 'slRl', 'slRh', 'yeL', 'yeR', 'jL', 'jR', 'fk', 'fs0',
           'ytop', 'ybot', 'ycur', 'w_n', 'w_g', 'w_vc', 'w_cj', 'w_dir', 'w_nj',
           'cb0', 'cb1', 'ffi', 'w_nf', 'ntop', 'nbot', 'otop', 'obot', 'w_ye', 'w_ri',
           'fpLH', 'fpLL', 'fpRH', 'fpRL', 'sj']
ZP_LOW = ['vx', 'vy', 'vz', 'xr', 'yr', 'zr',
          'p00', 'p01', 'p02', 'p10', 'p11', 'p12', 'p20', 'p21', 'p22']
ZP_LOW_FILL = ['oLh', 'oLl', 'oRh', 'oRl', 'nLh', 'nLl', 'nRh', 'nRl',
               'eva', 'evb', 'w_side', 'w_vt', 'w_vbm', 'ozsl', 'ozsh', 'sk']
ZP_SPACE = list(range(0x20, 0xA0))


def zp_map():
    m = {}
    for i, n in enumerate(ZP):
        m[n] = ZP_SPACE[i]
    for part in (ZP_XF, ZP_WIRE, ZP_FILL):
        for i, n in enumerate(part):
            assert len(ZP) + i < len(ZP_SPACE), ('zero page full', n)
            assert n not in m, n
            m[n] = ZP_SPACE[len(ZP) + i]
    for part in (ZP_LOW, ZP_LOW_FILL):
        for i, n in enumerate(part):
            assert i < 16 and n not in m, n
            m[n] = 0x10 + i
    return m


ZPM = zp_map()


def zp_lines():
    return ['%-8s = 0x%02X' % (n, a) for n, a in ZPM.items()]


def gen_matrix(g):
    g.chunk('matrix: m0-m8 from a1, a2, a3 (1.0 = 63)')
    g('matrix:')
    g('    ld   0x%02X, y' % P_SIN)
    for a, s, c in (('a1', 's1', 'c1'), ('a2', 's2', 'c2'), ('a3', 's3', 'c3')):
        g('''
    ld   [%s], ac
    ld   ac, x
    ld   [y,x], ac
    ld   ac, [%s]
    ld   [%s], ac
    add  64, x
    ld   [y,x], ac
    ld   ac, [%s]''' % (a, s, a, c))
    g('    ld   0x%02X, y' % P_QM)
    g.mul('s2', 's1')
    g('    ld   ac, [w_p]')
    g.mul('s2', 'c1')
    g('    ld   ac, [w_q]')
    g('    GOTO matrix_b')
    g.chunk()
    g('matrix_b:')
    g('    ld   0x%02X, y' % P_QM)
    # m0 = c3c1 - s3p
    g.mul('c3', 'c1')
    g('    ld   ac, [w_acc]')
    g.mul('s3', 'w_p')
    g('''
    ld   ac, [w_t]
    ld   [w_acc], ac
    sub  [w_t], ac
    ld   ac, [m0]''')
    g.mul('s3', 'c2')
    g('''
    xor  255, ac
    add  1, ac
    ld   ac, [m1]''')
    g.mul('c3', 's1')
    g('    ld   ac, [w_acc]')
    g.mul('s3', 'w_q')
    g('''
    add  [w_acc], ac
    ld   ac, [m2]
    GOTO matrix_c''')
    g.chunk()
    g('matrix_c:')
    g('    ld   0x%02X, y' % P_QM)
    g.mul('s3', 'c1')
    g('    ld   ac, [w_acc]')
    g.mul('c3', 'w_p')
    g('''
    add  [w_acc], ac
    ld   ac, [m3]''')
    g.mul('c3', 'c2')
    g('    ld   ac, [m4]')
    g.mul('s3', 's1')
    g('    ld   ac, [w_acc]')
    g.mul('c3', 'w_q')
    g('''
    ld   ac, [w_t]
    ld   [w_acc], ac
    sub  [w_t], ac
    ld   ac, [m5]
    GOTO matrix_d''')
    g.chunk()
    g('matrix_d:')
    g('    ld   0x%02X, y' % P_QM)
    g.mul('c2', 's1')
    g('''
    xor  255, ac
    add  1, ac
    ld   ac, [m6]
    ld   [s2], ac
    ld   ac, [m7]''')
    g.mul('c2', 'c1')
    g('''
    ld   ac, [m8]
    RET''')


def gen_row(g, r):
    """row r of the rotated vertex (Y = QV): p_r0..p_r2 and their sum"""
    row = ('xr', 'yr', 'zr')[r]
    for a, v in enumerate(('vx', 'vy', 'vz')):
        g('''
    ld   [m%(m)d], ac
    add  [%(v)s], x
    ld   [y,x], ac
    ld   ac, [w_t]
    ld   [m%(m)d], ac
    sub  [%(v)s], x
    ld   [w_t], ac
    sub  [y,x], ac
    ld   ac, [p%(r)d%(a)d]''' % {'m': 3 * r + a, 'v': v, 'r': r, 'a': a})
    g('''
    ld   [p%(r)d0], ac
    add  [p%(r)d1], ac
    add  [p%(r)d2], ac
    ld   ac, [%(row)s]''' % {'r': r, 'row': row})


def gen_add_pos(g, lo, hi, dl_, dh_):
    """(dh_:dl_) = (hi:lo) + AC sign-extended"""
    n, p, q = g.lab('ap'), g.lab('ap'), g.lab('ap')
    g('''
    blt  %(n)s
    add  [%(lo)s], ac
    ld   ac, [%(dl)s]
    ld   [%(hi)s], ac
    bcc  %(p)s
    inc
%(p)s:
    ld   ac, [%(dh)s]
    bra  %(q)s
%(n)s:
    add  [%(lo)s], ac
    ld   ac, [%(dl)s]
    ld   [%(hi)s], ac
    bcs  %(p)s_b
    dec
%(p)s_b:
    ld   ac, [%(dh)s]
%(q)s:''' % {'n': n, 'p': p, 'q': q, 'lo': lo, 'hi': hi, 'dl': dl_, 'dh': dh_})


def gen_proj(g, bad):
    """w_r = antilog(L'(mh:ml) + D), or to bad when it is 256 or more"""
    z, d, c = g.lab('pz'), g.lab('pd'), g.lab('pc')
    g('''
    ld   [mh], ac
    add  0x%(lgh)02X, y
    ld   [ml], x
    ld   [y,x], ac
    ld   ac, [w_t]
    ld   [mh], ac
    add  0x%(lgl)02X, y
    ld   [y,x], ac
    add  [dl], ac
    ld   ac, [sl]
    ld   [w_t], ac
    bcc  %(c)s
    inc
%(c)s:
    add  [dh], ac
    blt  %(z)s
    ld   ac, [w_t]
    sub  8, ac
    bcc  %(bad)s
    ld   [w_t], ac
    add  0x%(ant)02X, y
    ld   [sl], x
    ld   [y,x], ac
    bra  %(d)s
%(z)s:
    ld   0, ac
%(d)s:
    ld   ac, [w_r]''' % {'lgh': P_LGH, 'lgl': P_LGL, 'ant': P_ANT, 'z': z, 'd': d, 'c': c,
                         'bad': bad})


def gen_neg_m(g):
    n = g.lab('nm')
    g('''
    ld   [ml], ac
    xor  255, ac
    add  1, ac
    ld   ac, [ml]
    ld   [mh], ac
    xor  255, ac
    bcc  %s
    inc
%s:
    ld   ac, [mh]''' % (n, n))


def gen_xform(g):
    g.chunk('xform: project vn model vertices from vi to the arrays at vo (allv = 0: one off)')
    g('''
xform:
xf_loop:
    ld   0x%(mv)02X, y
    ld   [vi], ac
    add  0xC0, x
    ld   [y,x], ac
    bne  xf_m
    ld   [vi], x
    ld   [y,x], ac
    ld   ac, [vx]
    ld   [vi], ac
    add  0x40, x
    ld   [y,x], ac
    ld   ac, [vy]
    ld   [vi], ac
    add  0x80, x
    ld   [y,x], ac
    ld   ac, [vz]
    ld   0x%(qv)02X, y''' % {'mv': P_MV, 'qv': P_QV})
    gen_row(g, 2)
    g('''
    GOTO xf_b
xf_m:
    GOTO xf_mir''')
    g.chunk()
    g('xf_b:')
    g('    ld   0x%02X, y' % P_QV)
    gen_row(g, 0)
    gen_row(g, 1)
    g('    GOTO xf_z')
    g.chunk('a mirror image of the previous vertex (AC = 1 + axis): row -= 2 p, p = -p')
    g('''
xf_mir:
    sub  1, ac
    beq  xm_0
    sub  1, ac
    beq  xm_1''')
    for a, lab in ((2, None), (0, 'xm_0'), (1, 'xm_1')):
        if lab:
            g(lab + ':')
        for r, row in enumerate(('xr', 'yr', 'zr')):
            g('''
    ld   [p%(r)d%(a)d], ac
    shl
    ld   ac, [w_t]
    ld   [%(row)s], ac
    sub  [w_t], ac
    ld   ac, [%(row)s]
    ld   [p%(r)d%(a)d], ac
    xor  255, ac
    add  1, ac
    ld   ac, [p%(r)d%(a)d]''' % {'r': r, 'a': a, 'row': row})
        g('    GOTO xf_z')
    g.chunk()
    g('xf_z:')
    g('    ld   [zr], ac')
    gen_add_pos(g, 'ozl', 'ozh', 'zl', 'zh')
    g('''
    sub  2, ac
    bcc  xz_bad
    ld   [zh], ac
    bne  xz_ok
    ld   [zl], ac
    sub  %d, ac
    bcs  xz_bad
xz_ok:
    ld   [zh], ac
    add  0x%02X, y
    ld   [zl], x
    ld   [y,x], ac
    ld   ac, [w_t2]
    ld   [zh], ac
    add  0x%02X, y
    ld   [y,x], ac
    ld   ac, [w_t]
    ld   %d, ac
    sub  [w_t], ac
    ld   ac, [dl]
    ld   %d, ac
    bcc  xz_1
    dec
xz_1:
    sub  [w_t2], ac
    ld   ac, [dh]
    ld   [xr], ac
    GOTO xf_x
xz_bad:
    GOTO xf_bad''' % (ZMIN, P_LGH, P_LGL, LK & 0xFF, LK >> 8))
    # X
    g.chunk()
    g('xf_x:')
    gen_add_pos(g, 'oxl', 'oxh', 'ml', 'mh')
    g('''
    blt  xx_neg
    sub  2, ac
    bcc  xx_bad''')
    gen_proj(g, 'xx_bad')
    g('''
    sub  160, ac
    bcc  xx_bad
    ld   [w_r], ac
    add  160, ac
    ld   ac, [bxl]
    ld   0, ac
    bcc  xx_1
    ld   1, ac
xx_1:
    ld   ac, [bxh]
    GOTO xf_y
xx_neg:
    GOTO xf_xn
xx_bad:
    GOTO xf_bad''')
    g.chunk()
    g('xf_xn:')
    gen_neg_m(g)
    g('''
    sub  2, ac
    bcc  xn_bad''')
    gen_proj(g, 'xn_bad')
    g('''
    ld   160, ac
    sub  [w_r], ac
    bcs  xn_bad
    ld   ac, [bxl]
    ld   0, ac
    ld   ac, [bxh]
    GOTO xf_y
xn_bad:
    GOTO xf_bad''')
    # Y
    g.chunk()
    g('xf_y:')
    g('    ld   [yr], ac')
    gen_add_pos(g, 'oyl', 'oyh', 'ml', 'mh')
    g('''
    blt  xy_neg
    GOTO xf_yp
xy_neg:
    GOTO xf_yn''')
    g.chunk()
    g('xf_yp:')
    g('''
    sub  2, ac
    bcc  yp_bad''')
    gen_proj(g, 'yp_bad')
    g('''
    sub  %d, ac
    bcc  yp_bad
    ld   %d, ac
    sub  [w_r], ac
    GOTO xf_st
yp_bad:
    GOTO xf_bad''' % (CY - Y_TOP + 1, CY))
    g.chunk()
    g('xf_yn:')
    gen_neg_m(g)
    g('''
    sub  2, ac
    bcc  yn_bad''')
    gen_proj(g, 'yn_bad')
    g('''
    sub  %d, ac
    bcc  yn_bad
    ld   [w_r], ac
    add  %d, ac
    GOTO xf_st
yn_bad:
    GOTO xf_bad''' % (Y_BOT - CY + 1, CY))
    g.chunk('store the projected vertex (AC = sy), next vertex')
    g('''
xf_st:
    ld   [vo], x
    ld   0x%02X, y
    ld   ac, [y,x]
    ld   0x%02X, y
    ld   [bxl], ac
    ld   ac, [y,x]
    ld   0x%02X, y
    ld   [bxh], ac
    ld   ac, [y,x]
    ld   0x%02X, y
    ld   1, [y,x]
    bra  xf_next
xf_bad:
    ld   [vo], x
    ld   0x%02X, y
    ld   0, [y,x]
    ld   0, ac
    ld   ac, [allv]
xf_next:
    ld   [vi], ac
    inc
    ld   ac, [vi]
    ld   [vo], ac
    inc
    ld   ac, [vo]
    ld   [vn], ac
    dec
    ld   ac, [vn]
    beq  xf_done
    GOTO xf_loop
xf_done:
    RET''' % (P_SY, P_SXL, P_SXH, P_VAL, P_VAL))


def gen_camera(g):
    """c / 2 = -M^T o / 252 by logs: the camera in the ship's coordinates;
    then lgc_a/lgh_a = log |c_a|, sgc_a its sign"""
    g.chunk('camera: |o| and its signs, then the nine terms')
    g('camera:')
    for i, (lo, hi, sg) in enumerate((('oxl', 'oxh', 'w_a'), ('oyl', 'oyh', 'w_b'),
                                       ('ozl', 'ozh', 'w_c'))):
        n, p = g.lab('cm'), g.lab('cm')
        g('''
    ld   0, ac
    ld   ac, [%(sg)s]
    ld   [%(hi)s], ac
    blt  %(n)s
    bra  %(p)s
%(n)s:''' % {'sg': sg, 'hi': hi, 'n': n, 'p': p})
        g.neg16(lo, hi)
        g('''
    ld   1, ac
    ld   ac, [%(sg)s]
%(p)s:''' % {'sg': sg, 'p': p})
    g('''
    ld   0, ac
    ld   ac, [lgc0]
    ld   ac, [lgc1]
    ld   ac, [lgc2]
    ld   ac, [lgh0]
    ld   ac, [lgh1]
    ld   ac, [lgh2]
    ld   ac, [w_ci]
    ld   ac, [w_q]
    GOTO cm_i''')
    # o_i: its log and sign, then the terms -m_ia o_i / 252 for a = 0, 1, 2
    g.chunk('cm_i: the log of |o_i| (w_ci = i), then its three terms')
    g('''
cm_i:
    ld   [w_ci], ac
    shl
    ld   ac, [w_p]
    add  oxl, x
    ld   [x], ac
    ld   ac, [w_t]
    ld   [w_p], ac
    add  oxh, x
    ld   [x], ac
    ld   ac, [w_t2]
    add  0x%(lgl)02X, y
    ld   [w_t], x
    ld   [y,x], ac
    ld   ac, [w_t3]
    ld   [w_t2], ac
    add  0x%(lgh)02X, y
    ld   [y,x], ac
    ld   ac, [w_t4]
    ld   [w_ci], ac
    add  w_a, x
    ld   [x], ac
    ld   ac, [w_osg]
    ld   0, ac
    ld   ac, [w_kp]
cm_a:
    ld   [w_q], ac
    add  m0, x
    ld   [x], ac
    blt  cm_n
    ld   ac, x
    ld   0, ac
    bra  cm_s
cm_n:
    xor  255, ac
    add  1, ac
    ld   ac, x
    ld   1, ac
cm_s:
    xor  [w_osg], ac
    ld   ac, [w_s]
    ld   0x%(lgl)02X, y
    ld   [y,x], ac
    add  [w_t3], ac
    ld   ac, [w_t]
    ld   0x%(lgh)02X, y
    ld   [y,x], ac
    bcc  cm_1
    inc
cm_1:
    add  [w_t4], ac
    ld   ac, [w_t2]
    ld   [w_t], ac
    sub  %(l252)d, ac
    ld   ac, [w_t]
    ld   [w_t2], ac
    bcc  cm_2
    dec
cm_2:
    sub  %(h252)d, ac
    blt  cm_z
    add  0x%(ant)02X, y
    ld   [w_t], x
    ld   [y,x], ac
    ld   ac, [w_r]
    GOTO cm_acc
cm_z:
    GOTO cm_nx''' % {'lgl': P_LGL, 'lgh': P_LGH, 'l252': LG252 & 0xFF, 'h252': LG252 >> 8,
                     'ant': P_ANT})
    # the term is -(m o): add r when the signs differ (w_s = 1), else subtract
    g.chunk('cm_acc: lgc_a/lgh_a += or -= w_r, then the next term')
    g('''
cm_acc:
    ld   [w_kp], ac
    add  lgc0, x
    ld   [w_s], ac
    bne  cm_ad
    ld   [x], ac
    sub  [w_r], ac
    ld   ac, [x]
    ld   0, ac
    bcc  cm_3
    ld   1, ac
cm_3:
    ld   ac, [w_t]
    ld   [w_kp], ac
    add  lgh0, x
    ld   [x], ac
    sub  [w_t], ac
    ld   ac, [x]
    bra  cm_nx
cm_ad:
    ld   [x], ac
    add  [w_r], ac
    ld   ac, [x]
    ld   0, ac
    bcc  cm_4
    ld   1, ac
cm_4:
    ld   ac, [w_t]
    ld   [w_kp], ac
    add  lgh0, x
    ld   [x], ac
    add  [w_t], ac
    ld   ac, [x]
cm_nx:
    ld   [w_q], ac
    add  1, ac
    ld   ac, [w_q]
    ld   [w_kp], ac
    add  1, ac
    ld   ac, [w_kp]
    xor  3, ac
    beq  cm_ni
    GOTO cm_a
cm_ni:
    ld   [w_ci], ac
    add  1, ac
    ld   ac, [w_ci]
    xor  3, ac
    beq  cm_e
    GOTO cm_i
cm_e:
    GOTO camera_e''')
    # c_a (in lgc_a/lgh_a as a 16-bit value) -> its log and sign
    g.chunk()
    g('camera_e:')
    for a in range(3):
        n, p = g.lab('cl'), g.lab('cl')
        g('''
    ld   0, ac
    ld   ac, [sgc%(a)d]
    ld   [lgh%(a)d], ac
    blt  %(n)s
    bra  %(p)s
%(n)s:''' % {'a': a, 'n': n, 'p': p})
        g.neg16('lgc%d' % a, 'lgh%d' % a)
        g('''
    ld   1, ac
    ld   ac, [sgc%(a)d]
%(p)s:
    ld   [lgh%(a)d], ac
    add  0x%(lgl)02X, y
    ld   [lgc%(a)d], x
    ld   [y,x], ac
    ld   ac, [lgc%(a)d]
    ld   [lgh%(a)d], ac
    add  0x%(lgh)02X, y
    ld   [y,x], ac
    ld   ac, [lgh%(a)d]''' % {'a': a, 'p': p, 'lgl': P_LGL, 'lgh': P_LGH})
    g('    RET')


def gen_tents(g):
    """the per-ship product tables: T (u * c_a / 64, kept as 16 bits for the
    sums, faces) and in filled mode B (8 bits, shades), for the entries ti..
    (tn of them)"""
    g.chunk('tents: T[kp] = u * c_a / 64, T[kn] = -T[kp] (and B in filled mode)')
    g('''
tents:
te_loop:
    ld   0x%(te)02X, y
    ld   [ti], x
    ld   [y,x], ac
    ld   ac, [w_a]
    ld   [ti], ac
    add  0x40, x
    ld   [y,x], ac
    ld   ac, [w_t]
    ld   [ti], ac
    add  0x80, x
    ld   [y,x], ac
    ld   ac, [w_t2]
    ld   [ti], ac
    add  0xC0, x
    ld   [y,x], ac
    ld   ac, [w_kp]
    ld   0x%(te2)02X, y
    ld   [ti], x
    ld   [y,x], ac
    ld   ac, [w_kn]
    ld   [w_a], ac
    add  lgh0, x
    ld   [x], ac
    ld   ac, [w_t3]
    ld   [w_a], ac
    add  lgc0, x
    ld   [x], ac
    add  [w_t], ac
    ld   ac, [sl]
    ld   [w_t2], ac
    bcc  te_1
    inc
te_1:
    add  [w_t3], ac
    sub  0x%(sub)02X, ac
    blt  te_z
    add  0x%(ant)02X, y
    ld   [sl], x
    ld   [y,x], ac
    bra  te_r
te_z:
    ld   0, ac
te_r:
    ld   ac, [ml]
    xor  255, ac
    add  1, ac
    ld   ac, [dl]
    ld   0, ac
    ld   ac, [mh]
    ld   [ml], ac
    beq  te_h0
    ld   255, ac
te_h0:
    ld   ac, [dh]
    ld   [w_a], ac
    add  sgc0, x
    ld   [x], ac
    beq  te_p
    ld   [ml], ac
    ld   ac, [w_t3]
    ld   [dl], ac
    ld   ac, [ml]
    ld   [w_t3], ac
    ld   ac, [dl]
    ld   [mh], ac
    ld   ac, [w_t3]
    ld   [dh], ac
    ld   ac, [mh]
    ld   [w_t3], ac
    ld   ac, [dh]
te_p:
    ld   0x%(tl)02X, y
    ld   [w_kp], x
    ld   [ml], ac
    ld   ac, [y,x]
    ld   [w_kn], x
    ld   [dl], ac
    ld   ac, [y,x]
    ld   0x%(th)02X, y
    ld   [dh], ac
    ld   ac, [y,x]
    ld   [w_kp], x
    ld   [mh], ac
    ld   ac, [y,x]
    GOTO te_b''' % {'te': P_TE, 'te2': P_TE2, 'sub': (2 * LOG_OFS + 1536) >> 8, 'ant': P_ANT,
                     'tl': P_TL, 'th': P_TH})
    g.chunk()
    g('''
te_b:
    ld   [mode], ac
    beq  te_next
    ld   [w_a], ac
    add  lgk0, x
    ld   [x], ac
    ld   ac, [w_t3]
    ld   [w_a], ac
    add  lgl0, x
    ld   [x], ac
    add  [w_t], ac
    ld   ac, [sl]
    ld   [w_t2], ac
    bcc  te_3
    inc
te_3:
    add  [w_t3], ac
    ld   ac, [sh]
    ld   [sl], ac
    sub  %(l100)d, ac
    ld   ac, [sl]
    ld   [sh], ac
    bcc  te_4
    dec
te_4:
    sub  %(h100)d, ac
    blt  te_bz
    add  0x%(ant)02X, y
    ld   [sl], x
    ld   [y,x], ac
    bra  te_bs
te_bz:
    ld   0, ac
te_bs:
    ld   ac, [w_r]
    ld   [w_a], ac
    add  sgl0, x
    ld   [x], ac
    beq  te_bp
    ld   [w_r], ac
    xor  255, ac
    add  1, ac
    ld   ac, [w_r]
te_bp:
    ld   0x%(b)02X, y
    ld   [w_kp], x
    ld   [w_r], ac
    ld   ac, [y,x]
    ld   [w_kn], x
    xor  255, ac
    add  1, ac
    ld   ac, [y,x]
te_next:
    ld   [ti], ac
    inc
    ld   ac, [ti]
    ld   [tn], ac
    dec
    ld   ac, [tn]
    beq  te_done
    GOTO te_loop
te_done:
    RET''' % {'tl': P_TL, 'l100': LG100 & 0xFF, 'h100': LG100 >> 8, 'ant': P_ANT, 'b': P_B})


def gen_faces(g):
    g.chunk('faces: FV[fo..] = 1 where face fi.. (fn of them) looks at the camera: S = sum T > D')
    g('''
faces:
fc_loop:
    ld   0x%(mf)02X, y
    ld   [fi], ac
    add  0x80, x
    ld   [y,x], ac
    ld   ac, [w_a]
    ld   [fi], ac
    add  0xC0, x
    ld   [y,x], ac
    ld   ac, [w_b]
    ld   0x%(mf2)02X, y
    ld   [fi], x
    ld   [y,x], ac
    ld   ac, [w_c]
    ld   [fi], ac
    add  0x40, x
    ld   [y,x], ac
    ld   ac, [dl]
    ld   [fi], ac
    add  0x80, x
    ld   [y,x], ac
    ld   ac, [dh]
    ld   0x%(tl)02X, y
    ld   [w_a], x
    ld   [y,x], ac
    ld   [w_b], x
    add  [y,x], ac
    ld   ac, [sl]
    ld   0, ac
    bcc  fc_1
    ld   1, ac
fc_1:
    ld   ac, [sh]
    ld   [w_c], x
    ld   [sl], ac
    add  [y,x], ac
    ld   ac, [sl]
    bcc  fc_2
    ld   [sh], ac
    inc
    ld   ac, [sh]
fc_2:
    ld   0x%(th)02X, y
    ld   [sh], ac
    ld   [w_a], x
    add  [y,x], ac
    ld   [w_b], x
    add  [y,x], ac
    ld   [w_c], x
    add  [y,x], ac
    ld   ac, [sh]
    ld   [sl], ac
    sub  [dl], ac
    ld   [sh], ac
    bcc  fc_3
    dec
fc_3:
    sub  [dh], ac
    blt  fc_inv
    ld   0x%(fv)02X, y
    ld   [fo], x
    ld   1, [y,x]
    ld   [mode], ac
    beq  fc_next
    GOTO fc_shade
fc_inv:
    ld   0x%(fv)02X, y
    ld   [fo], x
    ld   0, [y,x]
fc_next:
    ld   [fi], ac
    inc
    ld   ac, [fi]
    ld   [fo], ac
    inc
    ld   ac, [fo]
    ld   [fn], ac
    dec
    ld   ac, [fn]
    beq  fc_done
    GOTO fc_loop
fc_done:
    RET''' % {'mf': P_MF, 'mf2': P_MF2, 'tl': P_TL, 'th': P_TH, 'fv': P_FV})
    # the shade of a face seen (filled mode): b = B[ix] + B[iy] + B[iz]
    g.chunk('fc_shade: the colour bytes of a face seen')
    g('''
fc_shade:
    ld   0x%(b)02X, y
    ld   [w_a], x
    ld   [y,x], ac
    ld   [w_b], x
    add  [y,x], ac
    ld   [w_c], x
    add  [y,x], ac
    blt  fs_0''' % {'b': P_B})
    for k, th in enumerate(SHADE_T):
        prev = SHADE_T[k - 1] if k else 0
        g('''
    sub  %d, ac
    bcs  fs_%d''' % (th - prev, k))
    g('    bra  fs_%d' % len(SHADE_T))
    for k in range(len(SHADES)):
        ce, co = shade_bytes(k)
        g('''
fs_%d:
    ld   0x%02X, ac
    ld   ac, [w_t]
    ld   0x%02X, ac
    bra  fs_st''' % (k, ce, co))
    g('''
fs_st:
    ld   ac, [w_t2]
    ld   0x%(c0)02X, y
    ld   [fo], x
    ld   [w_t], ac
    ld   ac, [y,x]
    ld   0x%(c1)02X, y
    ld   [w_t2], ac
    ld   ac, [y,x]
    GOTO fc_next''' % {'c0': P_FC0, 'c1': P_FC1})


def gen_lights(g):
    """the light in the ship's coordinates, L' = M^T L / 63: its logs and signs"""
    g.chunk('lights: lgl_j/lgk_j = log |L\'_j|, sgl_j its sign')
    g('lights:')
    for j in range(3):
        if j == 2:
            g('    GOTO lights_b')
            g.chunk()
            g('lights_b:')
        g('    ld   0x%02X, y' % P_QM)
        for i in range(3):
            L = LIGHT[i] & 0xFF
            g('''
    ld   [m%(m)d], ac
    add  %(L)d, x
    ld   [y,x], ac
    ld   ac, [w_t]
    ld   [m%(m)d], ac
    sub  %(L)d, x
    ld   [w_t], ac
    sub  [y,x], ac''' % {'m': 3 * i + j, 'L': L})
            if i == 0:
                g('    ld   ac, [w_acc]')
            else:
                g('    add  [w_acc], ac')
                if i == 1:
                    g('    ld   ac, [w_acc]')
        n, p = g.lab('lt'), g.lab('lt')
        g('''
    ld   ac, [w_acc]
    ld   0, ac
    ld   ac, [sgl%(j)d]
    ld   [w_acc], ac
    blt  %(n)s
    bra  %(p)s
%(n)s:
    xor  255, ac
    add  1, ac
    ld   ac, [w_acc]
    ld   1, ac
    ld   ac, [sgl%(j)d]
    ld   [w_acc], ac
%(p)s:
    ld   ac, x
    ld   0x%(lgl)02X, y
    ld   [y,x], ac
    ld   ac, [lgl%(j)d]
    ld   0x%(lgh)02X, y
    ld   [y,x], ac
    ld   ac, [lgk%(j)d]''' % {'j': j, 'n': n, 'p': p, 'lgl': P_LGL, 'lgh': P_LGH})
    g('    RET')


def gen_edges(g):
    g.chunk('edges: a line record for each edge ei.. (en of them) with a face shown')
    g('''
edges:
ed_loop:
    ld   [nrec], ac
    xor  255, ac
    beq  ed_skip
    ld   0x%(e2)02X, y
    ld   [ei], x
    ld   [y,x], ac
    add  [fb], x
    ld   0x%(fv)02X, y
    ld   [y,x], ac
    ld   ac, [w_t]
    ld   0x%(e2)02X, y
    ld   [ei], ac
    add  0x80, x
    ld   [y,x], ac
    add  [fb], x
    ld   0x%(fv)02X, y
    ld   [y,x], ac
    or   [w_t], ac
    beq  ed_skip
    ld   0x%(e1)02X, y
    ld   [ei], x
    ld   [y,x], ac
    add  [vb], ac
    ld   ac, [ev1]
    ld   [ei], ac
    add  0x80, x
    ld   [y,x], ac
    add  [vb], ac
    ld   ac, [ev2]
    ld   0x%(val)02X, y
    ld   [ev1], x
    ld   [y,x], ac
    ld   [ev2], x
    and  [y,x], ac
    beq  ed_skip
    GOTO ed_get
ed_skip:
    GOTO ed_next''' % {'e1': P_ME, 'e2': P_ME2, 'fv': P_FV, 'val': P_VAL})
    g.chunk()
    g('''
ed_get:
    ld   0x%(sxl)02X, y
    ld   [ev1], x
    ld   [y,x], ac
    ld   ac, [x0l]
    ld   [ev2], x
    ld   [y,x], ac
    ld   ac, [x1l]
    ld   0x%(sxh)02X, y
    ld   [y,x], ac
    ld   ac, [x1h]
    ld   [ev1], x
    ld   [y,x], ac
    ld   ac, [x0h]
    ld   0x%(sy)02X, y
    ld   [y,x], ac
    ld   ac, [y0]
    ld   [ev2], x
    ld   [y,x], ac
    ld   ac, [y1]
    GOTO ls
ed_next:
    ld   [ei], ac
    inc
    ld   ac, [ei]
    ld   [en], ac
    dec
    ld   ac, [en]
    beq  ed_done
    GOTO ed_loop
ed_done:
    RET''' % {'sxl': P_SXL, 'sxh': P_SXH, 'sy': P_SY})
def gen_slope(g, num, denl, denh):
    a, b, z, f, s, e = (g.lab('sl') for _ in range(6))
    g('''
    ld   [%(dh)s], ac
    bne  %(a)s
    ld   [%(dl)s], ac
    xor  [%(n)s], ac
    bne  %(a)s
    ld   255, ac
    ld   ac, [frac]
    ld   ac, [err]
    bra  %(e)s
%(a)s:
    ld   0x%(lgh)02X, y
    ld   [%(n)s], x
    ld   [y,x], ac
    ld   ac, [w_t2]
    ld   0x%(lgl)02X, y
    ld   [y,x], ac
    ld   ac, [w_t]
    ld   [%(dh)s], ac
    add  0x%(lgh)02X, y
    ld   [%(dl)s], x
    ld   [y,x], ac
    ld   ac, [w_t3]
    ld   [%(dh)s], ac
    add  0x%(lgl)02X, y
    ld   [y,x], ac
    ld   ac, [w_t4]
    ld   [w_t], ac
    sub  [w_t4], ac
    ld   ac, [sl]
    ld   [w_t2], ac
    bcc  %(b)s
    dec
%(b)s:
    sub  [w_t3], ac
    add  8, ac
    blt  %(z)s
    ld   ac, [w_t2]
    sub  8, ac
    bcc  %(f)s
    ld   [w_t2], ac
    add  0x%(ant)02X, y
    ld   [sl], x
    ld   [y,x], ac
    bra  %(s)s
%(z)s:
    ld   0, ac
    bra  %(s)s
%(f)s:
    ld   255, ac
%(s)s:
    ld   ac, [frac]
    ld   128, ac
    ld   ac, [err]
%(e)s:''' % {'n': num, 'dl': denl, 'dh': denh, 'a': a, 'b': b, 'z': z, 'f': f, 's': s,
             'e': e, 'lgh': P_LGH, 'lgl': P_LGL, 'ant': P_ANT})


def gen_setup(g):
    g.chunk('ls: the line (x0, y0)-(x1, y1) into record nrec')
    g('''
ls:
    ld   [x1l], ac
    sub  [x0l], ac
    ld   ac, [dxl]
    ld   [x1h], ac
    bcc  ls_1
    dec
ls_1:
    sub  [x0h], ac
    ld   ac, [dxh]
    blt  ls_xn
    ld   ac, [adxh]
    ld   [dxl], ac
    ld   ac, [adxl]
    ld   0, ac
    ld   ac, [sgx]
    bra  ls_2
ls_xn:
    ld   [dxl], ac
    xor  255, ac
    add  1, ac
    ld   ac, [adxl]
    ld   [dxh], ac
    xor  255, ac
    bcc  ls_3
    inc
ls_3:
    ld   ac, [adxh]
    ld   1, ac
    ld   ac, [sgx]
ls_2:
    ld   [y1], ac
    sub  [y0], ac
    bcc  ls_4
    xor  255, ac
    add  1, ac
    ld   ac, [ady]
    ld   1, ac
    ld   ac, [sgy]
    bra  ls_5
ls_4:
    ld   ac, [ady]
    ld   0, ac
    ld   ac, [sgy]
ls_5:
    ld   [adxh], ac
    bne  ls_x
    ld   [adxl], ac
    sub  [ady], ac
    bcc  ls_x
    GOTO ls_y
ls_x:
    GOTO ls_xm''')
    # x-major
    g.chunk('x-major: slope, then left end first')
    g('ls_xm:')
    gen_slope(g, 'ady', 'adxl', 'adxh')
    g('''
    ld   [sgx], ac
    bne  lx_sw
    ld   [x0l], ac
    ld   ac, [wbl]
    ld   [x0h], ac
    ld   ac, [wbh]
    ld   [y0], ac
    ld   ac, [by]
    ld   [x1l], ac
    ld   ac, [exl]
    ld   [x1h], ac
    ld   ac, [exh]
    ld   [sgy], ac
    xor  1, ac
    ld   ac, [dirf]
    GOTO lx_c
lx_sw:
    ld   [x1l], ac
    ld   ac, [wbl]
    ld   [x1h], ac
    ld   ac, [wbh]
    ld   [y1], ac
    ld   ac, [by]
    ld   [x0l], ac
    ld   ac, [exl]
    ld   [x0h], ac
    ld   ac, [exh]
    ld   [sgy], ac
    ld   ac, [dirf]
    GOTO lx_c''')
    g.chunk()
    g('''
lx_c:
    ld   [wbh], ac
    add  0x%(cpg)02X, y
    ld   [wbl], x
    ld   [y,x], ac
    ld   ac, [pg]
    ld   [wbl], ac
    and  3, ac
    ld   ac, [ph]
    ld   0x%(row)02X, y
    ld   [by], x
    ld   [y,x], ac
    ld   ac, [off]
    ld   [exh], ac
    add  0x%(cpg)02X, y
    ld   [exl], x
    ld   [y,x], ac
    ld   ac, [endv]
    xor  [pg], ac
    bne  lx_far
    ld   [exl], ac
    and  3, ac
    sub  [ph], ac
    inc
    ld   ac, [ntail]
    ld   [dirf], ac
    bne  lx_td
    ld   12, ac
    bra  lx_e
lx_td:
    ld   8, ac
    bra  lx_e
lx_far:
    ld   [exl], ac
    and  3, ac
    inc
    ld   ac, [ntail]
    ld   [dirf], ac
    bne  lx_xd
    ld   4, ac
    bra  lx_e
lx_xd:
    ld   0, ac
lx_e:
    GOTO ls_ent''' % {'cpg': P_CPG, 'row': P_ROW})
    # y-major
    g.chunk('y-major: slope, then top end first')
    g('ls_y:')
    gen_slope(g, 'adxl', 'ady', 'adxh')     # adxh = 0 here: denominator high = 0
    g('''
    ld   [sgy], ac
    bne  ly_sw
    ld   [x0l], ac
    ld   ac, [wbl]
    ld   [x0h], ac
    ld   ac, [wbh]
    ld   [y0], ac
    ld   ac, [by]
    ld   [y1], ac
    ld   ac, [ey]
    ld   [sgx], ac
    xor  1, ac
    ld   ac, [dirf]
    GOTO ly_c
ly_sw:
    ld   [x1l], ac
    ld   ac, [wbl]
    ld   [x1h], ac
    ld   ac, [wbh]
    ld   [y1], ac
    ld   ac, [by]
    ld   [y0], ac
    ld   ac, [ey]
    ld   [sgx], ac
    ld   ac, [dirf]
    GOTO ly_c''')
    g.chunk()
    g('''
ly_c:
    ld   [wbh], ac
    add  0x%(cpg)02X, y
    ld   [wbl], x
    ld   [y,x], ac
    ld   ac, [pg]
    ld   [wbl], ac
    and  3, ac
    ld   ac, [ph]
    ld   0x%(row)02X, y
    ld   [by], x
    ld   [y,x], ac
    ld   ac, [off]
    ld   [ey], ac
    add  1, x
    ld   [y,x], ac
    ld   ac, [endv]
    ld   [dirf], ac
    bne  ly_r
    ld   20, ac
    bra  ly_e
ly_r:
    ld   16, ac
ly_e:
    GOTO ls_ent''' % {'cpg': P_CPG, 'row': P_ROW})
    g.chunk('ls_ent: AC = variant * 4; entry address, then write the record')
    g('''
ls_ent:
    add  [ph], ac
    ld   ac, [w_t]
    add  0x%(entl)02X, x
    ld   0x%(ent)02X, y
    ld   [y,x], ac
    ld   ac, [jlo]
    ld   [w_t], ac
    add  0x%(enth)02X, x
    ld   [y,x], ac
    ld   ac, [ehi]
    ld   [nrec], x
    ld   [par], ac
    bne  wr_1''' % {'entl': ENTL, 'enth': ENTH, 'ent': P_CPG + 1})
    for b, lab in ((0, 'wr_0'), (1, 'wr_1')):
        g('%s:' % lab)
        for f, v in enumerate(['jlo', 'ehi', 'pg', 'off', 'err', 'frac', 'endv', 'ntail']):
            g('''
    ld   0x%02X, y
    ld   [%s], ac
    ld   ac, [y,x]''' % (P_REC[b] + f, v))
        if b == 0:
            g('    bra  wr_d')
    g('''
wr_d:
    ld   [nrec], ac
    inc
    ld   ac, [nrec]
    GOTO ed_next''')


def gen_lines(g):
    """the unrolled line loops; every exit is ld [rhi], y / jmp [rlo]"""
    for v in ('xd', 'xu'):
        down = v == 'xd'
        tail = 't' + v[1]
        g.chunk('%s: x-major, left to right, %s' % (v, 'down' if down else 'up'))
        for p in range(4):
            g('ex_%s%d:\n    ld   [pg], y\n    bra  %s%d' % (v, p, v, p))
        for p in range(4):
            g('''
%(v)s%(p)d:
px_%(v)s%(p)d:
    ld   [y,x], ac
    xor  0x%(m)02X, ac
    ld   ac, [y,x]
    ld   [err], ac
    add  [frac], ac
    ld   ac, [err]
    bcc  %(v)s%(p)dn
    ld   [off], ac
    %(op)s  2, ac
    bcs  %(v)s%(p)dw
%(v)s%(p)ds:
    ld   ac, [off]
    ld   ac, x
%(v)s%(p)dn:''' % {'v': v, 'p': p, 'm': MASK[p], 'op': 'add' if down else 'sub'})
        g('''
    ld   [pg], ac
    add  2, ac
    ld   ac, [pg]
    ld   ac, y
    xor  [endv], ac
    bne  %(v)s0
    GOTO ex_%(t)s0''' % {'v': v, 't': tail})
        for p in range(4):
            g('%s%dw:\n    ld   0x%02X, ac\n    bra  %s%ds' % (v, p, 1 if down else 0xFE, v, p))
    for v in ('td', 'tu'):
        down = v == 'td'
        g.chunk('%s: the last byte of an x-major line, ntail pixels' % v)
        for p in range(4):
            g('ex_%s%d:\n    ld   [pg], y\n    bra  %s%d' % (v, p, v, p))
        for p in range(4):
            g('''
%(v)s%(p)d:
px_%(v)s%(p)d:
    ld   [y,x], ac
    xor  0x%(m)02X, ac
    ld   ac, [y,x]''' % {'v': v, 'p': p, 'm': MASK[p]})
            if p == 3:
                break
            g('''
    ld   [ntail], ac
    dec
    ld   ac, [ntail]
    beq  %(v)s_z
    ld   [err], ac
    add  [frac], ac
    ld   ac, [err]
    bcc  %(v)s%(q)d
    ld   [off], ac
    %(op)s  2, ac
    bcs  %(v)s%(p)dw
%(v)s%(p)ds:
    ld   ac, [off]
    ld   ac, x''' % {'v': v, 'p': p, 'q': p + 1, 'op': 'add' if down else 'sub'})
        g('''
%s_z:
    ld   [rhi], y
    jmp  [rlo]''' % v)
        for p in range(3):
            g('%s%dw:\n    ld   0x%02X, ac\n    bra  %s%ds' % (v, p, 1 if down else 0xFE, v, p))
    for v in ('yr', 'yl'):
        right = v == 'yr'
        if v == 'yl':
            g.out += ['', '.region 0x0100, 0x1F00']
        order = [0, 1, 2, 3] if right else [3, 2, 1, 0]
        g.chunk('%s: y-major, top to bottom, x to the %s' % (v, 'right' if right else 'left'))
        for p in range(4):
            g('ex_%s%d:\n    ld   [pg], y\n    bra  %s%d' % (v, p, v, p))
        for k, p in enumerate(order):
            g('''
%(v)s%(p)d:
px_%(v)s%(p)d:
    ld   [y,x], ac
    xor  0x%(m)02X, ac
    ld   ac, [y,x]
    ld   [off], ac
    add  2, ac
    bcs  %(v)s%(p)dw
%(v)s%(p)ds:
    ld   ac, [off]
    ld   ac, x
    xor  [endv], ac
    beq  %(v)s_z
    ld   [err], ac
    add  [frac], ac
    ld   ac, [err]
    bcc  %(v)s%(p)d''' % {'v': v, 'p': p, 'm': MASK[p]})
            if k == 3:
                g('''
    ld   [pg], ac
    %s  2, ac
    ld   ac, [pg]
    ld   ac, y
    bra  %s%d''' % ('add' if right else 'sub', v, order[0]))
        g('''
%s_z:
    ld   [rhi], y
    jmp  [rlo]''' % v)
        for p in range(4):
            g('%s%dw:\n    ld   1, ac\n    bra  %s%ds' % (v, p, v, p))


def gen_drawl(g):
    g.chunk('drawl: run records rk..rend-1 of buffer AC (0 or 1)')
    g('''
drawl:
    bne  dl_b1
    ld   dl0 & 0xFF, ac
    ld   ac, [rlo]
    ld   dl0 >> 8, ac
    ld   ac, [rhi]
    GOTO dl0
dl_b1:
    ld   dl1 & 0xFF, ac
    ld   ac, [rlo]
    ld   dl1 >> 8, ac
    ld   ac, [rhi]
    GOTO dl1''')
    for b in (0, 1):
        g.chunk()
        g('dl%d:' % b)
        g.tick()
        g('''
    ld   [rk], ac
    xor  [rend], ac
    beq  dl%(b)d_z
    ld   [rk], x''' % {'b': b})
        for f, v in ((4, 'err'), (5, 'frac'), (6, 'endv'), (7, 'ntail'), (2, 'pg'),
                     (0, 'jlo'), (3, 'off')):
            g('''
    ld   0x%02X, y
    ld   [y,x], ac
    ld   ac, [%s]''' % (P_REC[b] + f, v))
        g('''
    ld   0x%02X, y
    ld   [y,x], ac
    ld   ac, y
    ld   [off], x
    ld   [rk], ac
    inc
    ld   ac, [rk]
    jmp  [jlo]
dl%d_z:
    RET''' % (P_REC[b] + 1, b))


def gen_sinpos(g, P, lo, hi):
    c, k, ph = P
    if k is None:
        g('''
    ld   %d, ac
    ld   ac, [%s]
    ld   %d, ac
    ld   ac, [%s]''' % (c & 0xFF, lo, (c >> 8) & 0xFF, hi))
        return
    n, h, e = g.lab('sp'), g.lab('sp'), g.lab('sp')
    g('''
    ld   0x%(sin)02X, y
    ld   [tt], ac
    add  %(ph)d, x
    ld   [y,x], ac
    ld   ac, [pl]
    blt  %(n)s
    ld   0, ac
    bra  %(h)s
%(n)s:
    ld   255, ac
%(h)s:
    ld   ac, [phh]''' % {'sin': P_SIN, 'ph': ph & 0xFF, 'n': n, 'h': h})
    for _ in range(k):
        c1, d1 = g.lab('sh'), g.lab('sh')
        g('''
    ld   [pl], ac
    shl
    ld   ac, [pl]
    ld   [phh], ac
    bcs  %(c)s
    shl
    bra  %(d)s
%(c)s:
    shl
    or   1, ac
%(d)s:
    ld   ac, [phh]''' % {'c': c1, 'd': d1})
    g('''
    ld   [pl], ac
    add  %(cl)d, ac
    ld   ac, [%(lo)s]
    ld   [phh], ac
    bcc  %(e)s
    inc
%(e)s:
    add  %(ch)d, ac
    ld   ac, [%(hi)s]''' % {'cl': c & 0xFF, 'ch': (c >> 8) & 0xFF, 'lo': lo, 'hi': hi, 'e': e})




# ---------------------------------------------------------------------------
# filled faces
# ---------------------------------------------------------------------------
def rmw(g, col, mask):
    """byte column col of line roff: keep the pixels outside mask (in AC: the
    pixels kept), set those in it from cb"""
    g('''
    ld   ac, [w_nm]
    xor  255, ac
    and  [cb], ac
    ld   ac, [w_cm]
    ld   [%s], ac
    shl
    add  0x61, y
    ld   [roff], x
    ld   [y,x], ac
    and  [w_nm], ac
    or   [w_cm], ac
    ld   ac, [y,x]''' % col)


def gen_span(g):
    g.chunk('span_c: the pixels of line roff from x16 xL up to xR (not that one), '
            'clipped to the picture, in cb')
    g('''
span_c:
    ld   [xRh], ac
    blt  sc_out
    ld   [xLh], ac
    blt  sc_lz
    sub  80, ac
    bcc  sc_out
    ld   [xLh], ac
    ld   ac, [lc]
    ld   [xLl], ac
    ld   ac, [lp]
    bra  sc_r
sc_lz:
    ld   0, ac
    ld   ac, [lc]
    ld   ac, [lp]
sc_r:
    ld   [xRh], ac
    sub  80, ac
    bcs  sc_rok
    ld   80, ac
    ld   ac, [rc]
    ld   0, ac
    ld   ac, [rp]
    GOTO span_f
sc_rok:
    ld   [xRh], ac
    ld   ac, [rc]
    ld   [xRl], ac
    ld   ac, [rp]
    GOTO span_f
sc_out:
    ld   [lk_sp_h], y
    jmp  [lk_sp_l]''')
    g.chunk('span_f: the same from (lc:lp) up to (rc:rp), on the picture')
    g('''
span_f:
    ld   [rc], ac
    sub  [lc], ac
    beq  sp_one
    bcs  sp_out
    ld   0x%(lmk)02X, y
    ld   [lp], x
    ld   [y,x], ac
    xor  255, ac
    beq  sp_m0''' % {'lmk': P_LMK})
    rmw(g, 'lc', None)
    g('''
    ld   [lc], ac
    add  1, ac
    bra  sp_m1
sp_m0:
    ld   [lc], ac
sp_m1:
    ld   ac, [c0]
    ld   0x%(rmk)02X, y
    ld   [rp], x
    ld   [y,x], ac
    beq  sp_m2
    xor  255, ac''' % {'rmk': P_RMK})
    rmw(g, 'rc', None)
    g('''
sp_m2:
    ld   [rc], ac
    sub  [c0], ac
    beq  sp_out
    GOTO sp_run
sp_one:
    ld   0x%(lmk)02X, y
    ld   [lp], x
    ld   [y,x], ac
    ld   ac, [w_t]
    ld   0x%(rmk)02X, y
    ld   [rp], x
    ld   [y,x], ac
    and  [w_t], ac
    beq  sp_out
    xor  255, ac''' % {'lmk': P_LMK, 'rmk': P_RMK})
    rmw(g, 'lc', None)
    g('''
sp_out:
    ld   [lk_sp_h], y
    jmp  [lk_sp_l]''')
    g.chunk('sp_run: the unrolled filler from byte c0, a branch to its stub patched in at byte rc')
    g('''
sp_run:
    ld   [rc], ac
    xor  80, ac
    beq  sp_rn
    ld   [rc], ac
    shl
    add  [rc], ac
    ld   ac, [w_pp]
    ld   ac, x
    ld   0x%(fill)02X, y
    ld   0x%(bra)02X, [y,x]
    ld   [w_pp], ac
    add  1, x
    ld   %(stub)d, [y,x]
sp_rn:
    ld   [c0], ac
    shl
    add  [c0], ac
    ld   ac, [w_e]
    ld   [cb], ac
    ld   [roff], x
    ld   0x%(fill)02X, y
    jmp  [w_e]
sp_bk:
    ld   [rc], ac
    xor  80, ac
    beq  sp_bo
    ld   0x%(fill)02X, y
    ld   [w_pp], x
    ld   0x%(ldy)02X, [y,x]
    ld   [w_pp], ac
    add  1, x
    ld   [rc], ac
    shl
    add  0x61, ac
    ld   ac, [y,x]
sp_bo:
    ld   [lk_sp_h], y
    jmp  [lk_sp_l]''' % {'fill': P_FILL, 'bra': OP_BRA, 'stub': FILL_STUB, 'ldy': OP_LDY})


def gen_esetup(g):
    g.chunk('esetup: the edge from (ux, uy) down to (wx, wy): e16 = ux * 64 + 32, '
            'es = 64 dx / dy, w_dy = wy - uy')
    g('''
esetup:
    ld   [wy], ac
    sub  [uy], ac
    ld   ac, [w_dy]
    ld   [uxl], ac
    and  3, ac
    add  0x%(xlo)02X, x
    ld   0x%(misc)02X, y
    ld   [y,x], ac
    ld   ac, [e16l]
    ld   [uxl], ac
    shr  ac
    shr  ac
    ld   ac, [w_t]
    ld   [uxh], ac
    beq  es_1
    ld   [w_t], ac
    or   0x40, ac
    bra  es_2
es_1:
    ld   [w_t], ac
es_2:
    ld   ac, [e16h]
    ld   [w_dy], ac
    xor  1, ac
    bne  es_s
    ld   0, ac
    ld   ac, [esl]
    ld   ac, [esh]
    ld   [lk_es_h], y
    jmp  [lk_es_l]
es_s:
    ld   [wxl], ac
    sub  [uxl], ac
    ld   ac, [w_dxl]
    ld   [wxh], ac
    bcc  es_3
    dec
es_3:
    sub  [uxh], ac
    ld   ac, [w_dxh]
    ld   0, ac
    ld   ac, [w_sg]
    ld   [w_dxh], ac
    blt  es_n
    GOTO es_lg
es_n:''' % {'xlo': XLO, 'misc': P_MISC})
    g.neg16('w_dxl', 'w_dxh')
    g('''
    ld   1, ac
    ld   ac, [w_sg]
    GOTO es_lg''')
    g.chunk()
    g('''
es_lg:
    ld   [w_dxh], ac
    add  0x%(lgl)02X, y
    ld   [w_dxl], x
    ld   [y,x], ac
    ld   ac, [sl]
    ld   [w_dxh], ac
    add  0x%(lgh)02X, y
    ld   [y,x], ac
    ld   ac, [sh]
    ld   0x%(lgl)02X, y
    ld   [w_dy], x
    ld   [y,x], ac
    ld   ac, [w_t]
    ld   0x%(lgh)02X, y
    ld   [y,x], ac
    ld   ac, [w_t2]
    ld   [sl], ac
    sub  [w_t], ac
    ld   ac, [sl]
    ld   [sh], ac
    bcc  es_4
    dec
es_4:
    sub  [w_t2], ac
    add  6, ac
    ld   ac, [sh]''' % {'lgl': P_LGL, 'lgh': P_LGH})
    g.antilog16('sl', 'sh', 'esl', 'esh', 'w_t3')
    g('''
    ld   [w_sg], ac
    beq  es_5''')
    g.neg16('esl', 'esh')
    g('''
es_5:
    ld   [lk_es_h], y
    jmp  [lk_es_l]''')


def gen_adv(g):
    g.chunk('adv: from vertex w_cj of the face, step w_dir (0: back, 1: on) to the first '
            'edge going down; AC = 0 if there is none')
    g('''
adv:
    ld   [fk], ac
    ld   ac, [w_n]
av_lp:
    ld   [w_dir], ac
    bne  av_inc
    ld   [w_cj], ac
    bne  av_d1
    ld   [fk], ac
av_d1:
    sub  1, ac
    bra  av_s
av_inc:
    ld   [w_cj], ac
    add  1, ac
    ld   ac, [w_t]
    xor  [fk], ac
    beq  av_s
    ld   [w_t], ac
av_s:
    ld   ac, [w_nj]
    add  0x20, x
    ld   0x%(fcv)02X, y
    ld   [y,x], ac
    ld   ac, [w_t]
    ld   [w_cj], ac
    add  0x20, x
    ld   [y,x], ac
    sub  [w_t], ac
    bcs  av_got
    ld   [w_nj], ac
    ld   ac, [w_cj]
    ld   [w_n], ac
    sub  1, ac
    ld   ac, [w_n]
    bne  av_lp
    ld   [lk_av_h], y
    jmp  [lk_av_l]
av_got:
    ld   [w_cj], x
    ld   [y,x], ac
    ld   ac, [uxl]
    ld   [w_cj], ac
    add  0x10, x
    ld   [y,x], ac
    ld   ac, [uxh]
    ld   [w_cj], ac
    add  0x20, x
    ld   [y,x], ac
    ld   ac, [uy]
    ld   [w_nj], x
    ld   [y,x], ac
    ld   ac, [wxl]
    ld   [w_nj], ac
    add  0x10, x
    ld   [y,x], ac
    ld   ac, [wxh]
    ld   [w_nj], ac
    add  0x20, x
    ld   [y,x], ac
    ld   ac, [wy]
    ld   [w_nj], ac
    ld   ac, [w_cj]''' % {'fcv': P_FCV})
    g.call2('esetup', 'lk_es')
    g('''
    ld   1, ac
    ld   [lk_av_h], y
    jmp  [lk_av_l]''')


def gen_fill_face(g):
    g.chunk('fill_face: face ffi of the model (its vertices at vb) in cb0 / cb1, row by row')
    g('fill_face:')
    g.tick()
    g('''
    ld   0x%(mf)02X, y
    ld   [ffi], x
    ld   [y,x], ac
    ld   ac, [fs0]
    ld   [ffi], ac
    add  0x40, x
    ld   [y,x], ac
    ld   ac, [fk]
    ld   255, ac
    ld   ac, [ytop]
    ld   0, ac
    ld   ac, [ybot]
    ld   ac, [w_g]
    ld   ac, [w_slow]
ff_cp:
    ld   [w_g], ac
    add  [fs0], x
    ld   0x%(fvl)02X, y
    ld   [y,x], ac
    add  [vb], ac
    ld   ac, [w_vc]
    ld   ac, x
    ld   0x%(sxl)02X, y
    ld   [y,x], ac
    ld   ac, [w_t2]
    ld   [w_g], x
    ld   0x%(fcv)02X, y
    ld   ac, [y,x]
    ld   [w_vc], x
    ld   0x%(sxh)02X, y
    ld   [y,x], ac
    ld   ac, [w_t]
    bne  ff_h
    ld   [w_t2], ac
    sub  3, ac
    bcc  ff_x
    bra  ff_s
ff_h:
    ld   [w_t2], ac
    sub  61, ac
    bcs  ff_x
ff_s:
    ld   1, ac
    ld   ac, [w_slow]
ff_x:
    ld   [w_g], ac
    add  0x10, x
    ld   0x%(fcv)02X, y
    ld   [w_t], ac
    ld   ac, [y,x]
    ld   [w_vc], x
    ld   0x%(sy)02X, y
    ld   [y,x], ac
    ld   ac, [w_t]
    ld   [w_g], ac
    add  0x20, x
    ld   0x%(fcv)02X, y
    ld   [w_t], ac
    ld   ac, [y,x]
    sub  [ytop], ac
    bcc  ff_1
    ld   [w_t], ac
    ld   ac, [ytop]
    ld   [w_g], ac
    ld   ac, [jL]
ff_1:
    ld   [ybot], ac
    sub  [w_t], ac
    bcc  ff_2
    ld   [w_t], ac
    ld   ac, [ybot]
ff_2:
    ld   [w_g], ac
    add  1, ac
    ld   ac, [w_g]
    xor  [fk], ac
    bne  ff_cp
    GOTO ff_go''' % {'mf': P_MF, 'fvl': P_FVL, 'sxl': P_SXL, 'sxh': P_SXH, 'sy': P_SY,
                     'fcv': P_FCV})
    g.chunk()
    g('''
ff_go:
    ld   [ytop], ac
    ld   ac, [ycur]
    ld   ac, [yeL]
    ld   ac, [yeR]
    ld   [jL], ac
    ld   ac, [jR]
    ld   [cb0], ac
    xor  [cb1], ac
    ld   ac, [cbx]
    ld   [ytop], ac
    and  1, ac
    beq  ff_c0
    ld   [cb1], ac
    bra  ff_c1
ff_c0:
    ld   [cb0], ac
ff_c1:
    ld   ac, [cb]
ff_seg:
    ld   [ycur], ac
    xor  [ybot], ac
    beq  ff_done
    ld   [ycur], ac
    xor  [yeL], ac
    bne  ff_r
    ld   [jL], ac
    ld   ac, [w_cj]
    ld   0, ac
    ld   ac, [w_dir]''')
    g.call2('adv', 'lk_av')
    g('''
    beq  ff_done
    ld   [w_cj], ac
    ld   ac, [jL]
    ld   [wy], ac
    ld   ac, [yeL]
    ld   [e16l], ac
    ld   ac, [xLl]
    ld   ac, [lp]
    ld   [e16h], ac
    ld   ac, [xLh]
    ld   ac, [lc]
    ld   [esl], ac
    ld   ac, [slLl]
    ld   [esh], ac
    ld   ac, [slLh]
ff_r:
    ld   [ycur], ac
    xor  [yeR], ac
    bne  ff_m
    ld   [jR], ac
    ld   ac, [w_cj]
    ld   1, ac
    ld   ac, [w_dir]''')
    g.call2('adv', 'lk_av')
    g('''
    beq  ff_done
    GOTO ff_r2
ff_m:
    GOTO ff_m2
ff_done:
    RET''')
    g.chunk()
    g('''
ff_r2:
    ld   [w_cj], ac
    ld   ac, [jR]
    ld   [wy], ac
    ld   ac, [yeR]
    ld   [e16l], ac
    ld   ac, [xRl]
    ld   ac, [rp]
    ld   [e16h], ac
    ld   ac, [xRh]
    ld   ac, [rc]
    ld   [esl], ac
    ld   ac, [slRl]
    ld   [esh], ac
    ld   ac, [slRh]
ff_m2:
    ld   [yeL], ac
    sub  [yeR], ac
    bcs  ff_m1
    ld   [yeR], ac
    bra  ff_m3
ff_m1:
    ld   [yeL], ac
ff_m3:
    ld   ac, [w_ye]
    sub  [ycur], ac
    beq  ff_end
    bcs  ff_end
    ld   [w_slow], ac
    bne  ff_sl
    GOTO ff_rf
ff_sl:
    GOTO ff_rs
ff_end:
    RET''')
    for kind, fn, vl in (('f', 'span_f', ('lp', 'lc', 'rp', 'rc')),
                         ('s', 'span_c', ('xLl', 'xLh', 'xRl', 'xRh'))):
        g.chunk('ff_r%s: the rows down to the next vertex%s' % (
            kind, '' if kind == 'f' else ' (a face at the picture\'s edge: clipped)'))
        g('''
ff_r%s:
    ld   0x%02X, y
    ld   [ycur], x
    ld   [y,x], ac
    ld   ac, [roff]''' % (kind, P_ROW))
        g.call2(fn, 'lk_sp')
        g.add16(vl[0], vl[1], 'slLl', 'slLh')
        g.add16(vl[2], vl[3], 'slRl', 'slRh')
        g('''
    ld   [cb], ac
    xor  [cbx], ac
    ld   ac, [cb]
    ld   [ycur], ac
    add  1, ac
    ld   ac, [ycur]
    xor  [w_ye], ac
    bne  ff_r%s
    GOTO ff_seg''' % kind)


def gen_foot(g):
    g.chunk('foot: the new outline of the ship (rows ntop to nbot): the edges between '
            'a face seen and one not seen')
    g('''
foot:
    ld   255, ac
    ld   ac, [ntop]
    ld   0, ac
    ld   ac, [nbot]
    ld   [vb], ac
    ld   ac, [w_g]
    ld   [nvs], ac
    ld   ac, [w_n]
ft_v:
    ld   [w_g], x
    ld   0x%(sy)02X, y
    ld   [y,x], ac
    ld   ac, [w_t]
    sub  [ntop], ac
    bcc  ft_v1
    ld   [w_t], ac
    ld   ac, [ntop]
ft_v1:
    ld   [nbot], ac
    sub  [w_t], ac
    bcc  ft_v2
    ld   [w_t], ac
    ld   ac, [nbot]
ft_v2:
    ld   [w_g], ac
    add  1, ac
    ld   ac, [w_g]
    ld   [w_n], ac
    sub  1, ac
    ld   ac, [w_n]
    bne  ft_v
    ld   [ntop], ac
    add  0x30, ac
    ld   ac, [w_ri]
    ld   [nbot], ac
    sub  [ntop], ac
    beq  ft_i0
    ld   ac, [w_n]
ft_i:
    ld   [w_ri], x
    ld   0x%(nlh)02X, y
    ld   0x%(empty)02X, [y,x]
    ld   0x%(nll)02X, y
    ld   0, [y,x]
    ld   0x%(nrh)02X, y
    ld   0, [y,x]
    ld   0x%(nrl)02X, y
    ld   0, [y,x]
    ld   [w_ri], ac
    add  1, ac
    ld   ac, [w_ri]
    ld   [w_n], ac
    sub  1, ac
    ld   ac, [w_n]
    bne  ft_i
ft_i0:
    GOTO ft_el''' % {'sy': P_SY, 'nlh': P_NLH, 'nll': P_NLL, 'nrh': P_NRH, 'nrl': P_NRL,
                     'empty': EMPTY_L})
    g.chunk('ft_el: the next edge: is a face of it seen, which end is the top, which '
            'side of a face seen (an edge between two faces seen: both)')
    g('''
ft_el:
    ld   0x%(me2)02X, y
    ld   [ei], x
    ld   [y,x], ac
    add  [fb], x
    ld   0x%(fv)02X, y
    ld   [y,x], ac
    ld   ac, [w_t]
    ld   0x%(me2)02X, y
    ld   [ei], ac
    add  0x80, x
    ld   [y,x], ac
    add  [fb], x
    ld   0x%(fv)02X, y
    ld   [y,x], ac
    ld   ac, [w_t2]
    or   [w_t], ac
    beq  ft_nx1
    ld   0x%(me)02X, y
    ld   [ei], x
    ld   [y,x], ac
    add  [vb], ac
    ld   ac, [eva]
    ld   [ei], ac
    add  0x80, x
    ld   [y,x], ac
    add  [vb], ac
    ld   ac, [evb]
    ld   [w_t2], ac
    and  [w_t], ac
    bne  ft_in
    ld   0x%(me3)02X, y
    ld   [ei], x
    ld   [y,x], ac
    xor  [w_t], ac
    beq  ft_f
    ld   [eva], ac
    ld   ac, [w_t]
    ld   [evb], ac
    ld   ac, [eva]
    ld   [w_t], ac
    ld   ac, [evb]
ft_f:
    ld   0x%(sy)02X, y
    ld   [eva], x
    ld   [y,x], ac
    ld   ac, [w_t]
    ld   [evb], x
    ld   [y,x], ac
    sub  [w_t], ac
    beq  ft_nx1
    bcs  ft_lf
    ld   2, ac
    bra  ft_ab
ft_lf:
    ld   1, ac
    bra  ft_ba
ft_in:
    ld   0x%(sy)02X, y
    ld   [eva], x
    ld   [y,x], ac
    ld   ac, [w_t]
    ld   [evb], x
    ld   [y,x], ac
    sub  [w_t], ac
    beq  ft_nx1
    bcs  ft_i1
    ld   3, ac
    bra  ft_ab
ft_i1:
    ld   3, ac
ft_ba:
    ld   ac, [w_side]
    ld   [evb], ac
    ld   ac, [w_vt]
    ld   [eva], ac
    ld   ac, [w_vbm]
    GOTO ft_ed
ft_ab:
    ld   ac, [w_side]
    ld   [eva], ac
    ld   ac, [w_vt]
    ld   [evb], ac
    ld   ac, [w_vbm]
    GOTO ft_ed
ft_nx1:
    GOTO ft_nx''' % {'me2': P_ME2, 'me': P_ME, 'me3': P_ME3, 'fv': P_FV, 'sy': P_SY})
    g.chunk()
    g('''
ft_ed:
    ld   [w_vt], x
    ld   0x%(sxl)02X, y
    ld   [y,x], ac
    ld   ac, [uxl]
    ld   0x%(sxh)02X, y
    ld   [y,x], ac
    ld   ac, [uxh]
    ld   0x%(sy)02X, y
    ld   [y,x], ac
    ld   ac, [uy]
    ld   [w_vbm], x
    ld   [y,x], ac
    ld   ac, [wy]
    ld   0x%(sxh)02X, y
    ld   [y,x], ac
    ld   ac, [wxh]
    ld   0x%(sxl)02X, y
    ld   [y,x], ac
    ld   ac, [wxl]''' % {'sxl': P_SXL, 'sxh': P_SXH, 'sy': P_SY})
    g.call2('esetup', 'lk_es')
    g('''
    ld   [uy], ac
    add  0x30, ac
    ld   ac, [w_ri]
    ld   [w_dy], ac
    ld   ac, [w_n]
    ld   [w_side], ac
    sub  2, ac
    beq  ft_r2
    bcs  ft_r1
    GOTO ft_row3
ft_r1:
    GOTO ft_row1
ft_r2:
    GOTO ft_row2''')
    left = '''
    ld   [w_ri], x
    ld   0x%(nll)02X, y
    ld   [e16l], ac
    sub  [y,x], ac
    ld   0x%(nlh)02X, y
    ld   [e16h], ac
    bcc  fl_%(k)d
    dec
fl_%(k)d:
    sub  [y,x], ac
    blt  fls_%(k)d
    bra  fln_%(k)d
fls_%(k)d:
    ld   [e16h], ac
    ld   ac, [y,x]
    ld   0x%(nll)02X, y
    ld   [e16l], ac
    ld   ac, [y,x]
fln_%(k)d:'''
    right = '''
    ld   [w_ri], x
    ld   0x%(nrl)02X, y
    ld   [y,x], ac
    sub  [e16l], ac
    ld   0x%(nrh)02X, y
    ld   [y,x], ac
    bcc  fr_%(k)d
    dec
fr_%(k)d:
    sub  [e16h], ac
    blt  frs_%(k)d
    bra  frn_%(k)d
frs_%(k)d:
    ld   [e16h], ac
    ld   ac, [y,x]
    ld   0x%(nrl)02X, y
    ld   [e16l], ac
    ld   ac, [y,x]
frn_%(k)d:'''
    for k, what in ((1, 'left: the least'), (2, 'right: the greatest'), (3, 'both')):
        g.chunk('ft_row%d: the edge\'s x16 on each of its rows, %s x16 of a row' % (k, what))
        g('ft_row%d:' % k)
        d = {'k': k, 'nll': P_NLL, 'nlh': P_NLH, 'nrl': P_NRL, 'nrh': P_NRH}
        if k & 1:
            g(left % d)
        if k & 2:
            g(right % d)
        g.add16('e16l', 'e16h', 'esl', 'esh')
        g('''
    ld   [w_ri], ac
    add  1, ac
    ld   ac, [w_ri]
    ld   [w_n], ac
    sub  1, ac
    ld   ac, [w_n]
    bne  ft_row%d
    GOTO ft_nx''' % k)
    g.chunk()
    g('''
ft_nx:
    ld   [ei], ac
    add  1, ac
    ld   ac, [ei]
    ld   [en], ac
    sub  1, ac
    ld   ac, [en]
    beq  ft_done
    GOTO ft_el
ft_done:
    RET''')


def gen_erase(g):
    g.chunk('erase: blank the part of the ship\'s old outline that its new one does not '
            'cover, then keep the new one')
    g('''
erase:
    ld   0, ac
    ld   ac, [cb]
    ld   0x%(ship)02X, y
    ld   [shs8], ac
    add  6, x
    ld   [y,x], ac
    ld   ac, [otop]
    ld   [shs8], ac
    add  7, x
    ld   [y,x], ac
    ld   ac, [obot]
    ld   [shs8], ac
    add  0x60, ac
    ld   ac, [fpLH]
    add  2, ac
    ld   ac, [fpLL]
    add  2, ac
    ld   ac, [fpRH]
    add  2, ac
    ld   ac, [fpRL]
    ld   [otop], ac
    ld   ac, [ycur]
    ld   [obot], ac
    sub  [ntop], ac
    bcs  er_1
    ld   [ntop], ac
    bra  er_2
er_1:
    ld   [obot], ac
er_2:
    ld   ac, [w_ye]''' % {'ship': P_SHIP})
    g.call2('er_fl', 'lk_ef')
    g('''
    ld   [otop], ac
    sub  [nbot], ac
    bcs  er_3
    ld   [otop], ac
    bra  er_4
er_3:
    ld   [nbot], ac
er_4:
    ld   ac, [ycur]
    ld   [obot], ac
    ld   ac, [w_ye]''')
    g.call2('er_fl', 'lk_ef')
    g('    GOTO er_d')
    g.chunk('er_fl: blank the old outline\'s rows ycur up to w_ye')
    g('''
er_fl:
    ld   [ycur], ac
    sub  [w_ye], ac
    bcc  ef_done
    ld   [ycur], ac
    add  0x30, x
    ld   [fpLH], y
    ld   [y,x], ac
    ld   ac, [xLh]
    ld   [fpLL], y
    ld   [y,x], ac
    ld   ac, [xLl]
    ld   [fpRH], y
    ld   [y,x], ac
    ld   ac, [xRh]
    ld   [fpRL], y
    ld   [y,x], ac
    ld   ac, [xRl]
    ld   0x%02X, y
    ld   [ycur], x
    ld   [y,x], ac
    ld   ac, [roff]''' % P_ROW)
    g.call2('span_c', 'lk_sp')
    g('''
    ld   [ycur], ac
    add  1, ac
    ld   ac, [ycur]
    bra  er_fl
ef_done:
    ld   [lk_ef_h], y
    jmp  [lk_ef_l]''')
    g.chunk('er_d: the rows in both outlines: blank old left to new left, new right to old right')
    g('''
er_d:
    ld   [otop], ac
    sub  [ntop], ac
    bcs  ed_1
    ld   [otop], ac
    bra  ed_2
ed_1:
    ld   [ntop], ac
ed_2:
    ld   ac, [ycur]
    ld   [obot], ac
    sub  [nbot], ac
    bcs  ed_3
    ld   [nbot], ac
    bra  ed_4
ed_3:
    ld   [obot], ac
ed_4:
    ld   ac, [w_ye]
ed_lp:
    ld   [ycur], ac
    sub  [w_ye], ac
    bcc  ed_end
    GOTO ed_row
ed_end:
    GOTO er_cp''')
    g.chunk()
    g('''
ed_row:
    ld   0x%(row)02X, y
    ld   [ycur], x
    ld   [y,x], ac
    ld   ac, [roff]
    ld   [ycur], ac
    add  0x30, x
    ld   [fpLH], y
    ld   [y,x], ac
    ld   ac, [oLh]
    ld   [fpLL], y
    ld   [y,x], ac
    ld   ac, [oLl]
    ld   [fpRH], y
    ld   [y,x], ac
    ld   ac, [oRh]
    ld   [fpRL], y
    ld   [y,x], ac
    ld   ac, [oRl]
    ld   0x%(nlh)02X, y
    ld   [y,x], ac
    ld   ac, [nLh]
    ld   0x%(nll)02X, y
    ld   [y,x], ac
    ld   ac, [nLl]
    ld   0x%(nrh)02X, y
    ld   [y,x], ac
    ld   ac, [nRh]
    ld   0x%(nrl)02X, y
    ld   [y,x], ac
    ld   ac, [nRl]
    ld   [nLl], ac
    sub  [oRl], ac
    ld   [nLh], ac
    bcc  eo_1
    dec
eo_1:
    sub  [oRh], ac
    blt  eo_n
    ld   [oRl], ac
    ld   ac, [xRl]
    ld   [oRh], ac
    ld   ac, [xRh]
    bra  eo_2
eo_n:
    ld   [nLl], ac
    ld   ac, [xRl]
    ld   [nLh], ac
    ld   ac, [xRh]
eo_2:
    ld   [oLl], ac
    sub  [xRl], ac
    ld   [oLh], ac
    bcc  eo_3
    dec
eo_3:
    sub  [xRh], ac
    blt  eo_go
    GOTO ed_rt
eo_go:
    ld   [oLl], ac
    ld   ac, [xLl]
    ld   [oLh], ac
    ld   ac, [xLh]''' % {'nlh': P_NLH, 'nll': P_NLL, 'nrh': P_NRH, 'nrl': P_NRL, 'row': P_ROW})
    g.call2('span_c', 'lk_sp')
    g('    GOTO ed_rt')
    g.chunk()
    g('''
ed_rt:
    ld   [oLl], ac
    sub  [nRl], ac
    ld   [oLh], ac
    bcc  er_5
    dec
er_5:
    sub  [nRh], ac
    blt  er_nr
    ld   [oLl], ac
    ld   ac, [xLl]
    ld   [oLh], ac
    ld   ac, [xLh]
    bra  er_6
er_nr:
    ld   [nRl], ac
    ld   ac, [xLl]
    ld   [nRh], ac
    ld   ac, [xLh]
er_6:
    ld   [xLl], ac
    sub  [oRl], ac
    ld   [xLh], ac
    bcc  er_7
    dec
er_7:
    sub  [oRh], ac
    blt  er_go
    bra  er_nxt
er_go:
    ld   [oRl], ac
    ld   ac, [xRl]
    ld   [oRh], ac
    ld   ac, [xRh]''')
    g.call2('span_c', 'lk_sp')
    g('''
er_nxt:
    ld   [ycur], ac
    add  1, ac
    ld   ac, [ycur]
    GOTO ed_lp''')
    g.chunk('er_cp: keep the new outline as the old one')
    g('''
er_cp:
    ld   [ntop], ac
    add  0x30, ac
    ld   ac, [w_ri]
    ld   [nbot], ac
    sub  [ntop], ac
    beq  ec_z
    ld   ac, [w_n]
ec_lp:
    ld   [w_ri], x
    ld   0x%(nlh)02X, y
    ld   [y,x], ac
    ld   [fpLH], y
    ld   ac, [y,x]
    ld   0x%(nll)02X, y
    ld   [y,x], ac
    ld   [fpLL], y
    ld   ac, [y,x]
    ld   0x%(nrh)02X, y
    ld   [y,x], ac
    ld   [fpRH], y
    ld   ac, [y,x]
    ld   0x%(nrl)02X, y
    ld   [y,x], ac
    ld   [fpRL], y
    ld   ac, [y,x]
    ld   [w_ri], ac
    add  1, ac
    ld   ac, [w_ri]
    ld   [w_n], ac
    sub  1, ac
    ld   ac, [w_n]
    bne  ec_lp
ec_z:
    ld   0x%(ship)02X, y
    ld   [shs8], ac
    add  6, x
    ld   [ntop], ac
    ld   ac, [y,x]
    ld   [shs8], ac
    add  7, x
    ld   [nbot], ac
    ld   ac, [y,x]
    RET''' % {'nlh': P_NLH, 'nll': P_NLL, 'nrh': P_NRH, 'nrl': P_NRL, 'ship': P_SHIP})


def gen_fill_pass(g, nships):
    g.chunk('fill_pass: the ships in order of distance, far to near (an insertion sort)')
    g('''
fill_pass:
pm_s:
    ld   0x%(ship)02X, y
    ld   0, ac
    ld   ac, [sk]
so_ins:
    ld   [sk], ac
    add  0x%(ozl)02X, x
    ld   [y,x], ac
    ld   ac, [ozsl]
    ld   [sk], ac
    add  0x%(ozh)02X, x
    ld   [y,x], ac
    ld   ac, [ozsh]
    ld   [sk], ac
    ld   ac, [sj]
so_lp:
    ld   [sj], ac
    beq  so_pt
    add  0x%(ord1)02X, x
    ld   [y,x], ac
    ld   ac, [w_t]
    add  0x%(ozh)02X, x
    ld   [y,x], ac
    ld   ac, [w_t3]
    ld   [w_t], ac
    add  0x%(ozl)02X, x
    ld   [y,x], ac
    sub  [ozsl], ac
    ld   [w_t3], ac
    bcc  so_1
    dec
so_1:
    sub  [ozsh], ac
    blt  so_sh
    bra  so_pt
so_sh:
    ld   [sj], ac
    add  0x%(ord)02X, x
    ld   [w_t], ac
    ld   ac, [y,x]
    ld   [sj], ac
    sub  1, ac
    ld   ac, [sj]
    bra  so_lp
so_pt:
    ld   [sj], ac
    add  0x%(ord)02X, x
    ld   [sk], ac
    ld   ac, [y,x]
    ld   [sk], ac
    add  1, ac
    ld   ac, [sk]
    xor  %(n)d, ac
    bne  so_ins
    GOTO fill_paint''' % {'ship': P_SHIP, 'ozl': SH_OZL, 'ozh': SH_OZH, 'ord': SH_ORD,
                          'ord1': SH_ORD - 1, 'n': nships})
    g.chunk('fill_paint: every face seen of every ship drawn, in that order')
    g('''
fill_paint:
    ld   0, ac
    ld   ac, [sk]
fp_ship:
    ld   0x%(ship)02X, y
    ld   [sk], ac
    add  0x%(ord)02X, x
    ld   [y,x], ac
    ld   ac, [sj]
    add  0x%(drawn)02X, x
    ld   [y,x], ac
    beq  fp_nx
    ld   0x%(sc)02X, y
    ld   [sj], ac
    add  0xC0, x
    ld   [y,x], ac
    ld   ac, [vb]
    ld   [sj], ac
    add  0xD0, x
    ld   [y,x], ac
    ld   ac, [fb]
    ld   [sj], ac
    add  0x60, x
    ld   [y,x], ac
    ld   ac, [ffi]
    ld   [sj], ac
    add  0x70, x
    ld   [y,x], ac
    ld   ac, [w_nf]
fp_face:
    ld   0x%(fv)02X, y
    ld   [fb], x
    ld   [y,x], ac
    beq  fp_fn
    ld   0x%(fc0)02X, y
    ld   [y,x], ac
    ld   ac, [cb0]
    ld   0x%(fc1)02X, y
    ld   [y,x], ac
    ld   ac, [cb1]
    ld   [nfac], ac
    add  1, ac
    ld   ac, [nfac]
pm_p:
    CALL fill_face
fp_fn:
    ld   [fb], ac
    add  1, ac
    ld   ac, [fb]
    ld   [ffi], ac
    add  1, ac
    ld   ac, [ffi]
    ld   [w_nf], ac
    sub  1, ac
    ld   ac, [w_nf]
    bne  fp_face
fp_nx:
    ld   [sk], ac
    add  1, ac
    ld   ac, [sk]
    xor  %(n)d, ac
    bne  fp_ship
    GOTO frame_end''' % {'ship': P_SHIP, 'ord': SH_ORD, 'drawn': SH_DRAWN, 'sc': P_SC,
                         'fv': P_FV, 'fc0': P_FC0, 'fc1': P_FC1, 'n': nships})


def gen_fill_init(g):
    g.chunk('fill_init: the pixel mask pages and the unrolled row filler (when filled mode starts)')
    g('''
fill_init:
    ld   0, ac
    ld   ac, [w_g]
fi_m:
    ld   [w_g], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [w_t]
    add  0x%(lmk4)02X, x
    ld   0x%(misc)02X, y
    ld   [y,x], ac
    ld   ac, [w_t2]
    ld   [w_t], ac
    add  0x%(rmk4)02X, x
    ld   [y,x], ac
    ld   ac, [w_t3]
    ld   [w_g], x
    ld   0x%(lmk)02X, y
    ld   [w_t2], ac
    ld   ac, [y,x]
    ld   0x%(rmk)02X, y
    ld   [w_t3], ac
    ld   ac, [y,x]
    ld   [w_g], ac
    add  1, ac
    ld   ac, [w_g]
    bne  fi_m
    ld   0, ac
    ld   ac, [w_g]
    ld   0x61, ac
    ld   ac, [w_t]
    ld   0x%(fill)02X, y
fi_f:
    ld   [w_g], x
    ld   0x%(ldy)02X, [y,x]
    ld   [w_g], ac
    add  1, x
    ld   [w_t], ac
    ld   ac, [y,x]
    ld   [w_g], ac
    add  2, x
    ld   0x%(styx)02X, [y,x]
    ld   [w_g], ac
    add  3, ac
    ld   ac, [w_g]
    ld   [w_t], ac
    add  2, ac
    ld   ac, [w_t]
    ld   [w_g], ac
    xor  %(stub)d, ac
    bne  fi_f
    ld   %(stub)d, x
    ld   0x%(ldym)02X, [y,x]
    ld   %(stub1)d, x
    ld   fr_h, [y,x]
    ld   %(stub2)d, x
    ld   0x%(jmpm)02X, [y,x]
    ld   %(stub3)d, x
    ld   fr_l, [y,x]
    ld   sp_bk & 0xFF, ac
    ld   ac, [fr_l]
    ld   sp_bk >> 8, ac
    ld   ac, [fr_h]
    RET''' % {'lmk4': LMK4, 'rmk4': RMK4, 'misc': P_MISC, 'lmk': P_LMK, 'rmk': P_RMK,
              'fill': P_FILL, 'ldy': OP_LDY, 'styx': OP_STYX, 'stub': FILL_STUB,
              'stub1': FILL_STUB + 1, 'stub2': FILL_STUB + 2, 'stub3': FILL_STUB + 3,
              'ldym': OP_LDYM, 'jmpm': OP_JMPM})


# ---------------------------------------------------------------------------
# ships, frame, main
# ---------------------------------------------------------------------------
def model_bases():
    """per model: (first vertex, face, edge, product entry, face vertex list entry)"""
    b, v, f, e, t, fl = {}, 0, 0, 0, 0, 0
    for name, m in MODELS.items():
        b[name] = (v, f, e, t, fl)
        v += len(m['v'])
        f += len(m['f'])
        e += len(m['e'])
        t += len(m['tent'])
        fl += sum(len(p) for p in m['f'])
    assert v <= 64 and f <= 64 and e <= 128 and t <= 64 and fl <= 256, (v, f, e, t, fl)
    return b


MODEL_BASE = model_bases()


def gen_ships(g, ships):
    """ship_pre (every ship): angles, the ship's constants, then its own path code
    (ship_N), which goes on to ship_body"""
    n = len(ships)
    g.chunk('ship_pre: ship shs: turn it, its constants, then its path (ship_N)')
    g('ship_pre:')
    g.tick()
    g('''
    ld   0x%(sc)02X, y
    ld   [shs], x
    ld   [y,x], ac
    ld   ac, [w_t]
    ld   [shs], ac
    add  0x10, x
    ld   [y,x], ac
    ld   ac, [w_t2]
    ld   [shs], ac
    add  0x20, x
    ld   [y,x], ac
    ld   ac, [w_t3]
    ld   [shs], ac
    add  0x30, x
    ld   [y,x], ac
    ld   ac, [w_t4]
    ld   0x%(ship)02X, y''' % {'sc': P_SC, 'ship': P_SHIP})
    for k, (var, r) in enumerate((('a1', 'w_t'), ('a2', 'w_t2'), ('a3', 'w_t3'), ('tt', 'w_t4'))):
        if k == 0:
            g('    ld   [shs8], x')
        else:
            g('    ld   [shs8], ac\n    add  %d, x' % k)
        g('''
    ld   [y,x], ac
    add  [%s], ac
    ld   ac, [y,x]
    ld   ac, [%s]''' % (r, var))
    g('    GOTO ship_pre_b')
    g.chunk()
    g('ship_pre_b:')
    g('    ld   0x%02X, y' % P_SC)
    for off, names in ((0x40, ('vi',)), (0x50, ('vn', 'nvs')), (0x60, ('fi',)), (0x70, ('fn',)),
                       (0x80, ('ei',)), (0x90, ('en',)), (0xA0, ('ti',)), (0xB0, ('tn',)),
                       (0xC0, ('vo', 'vb')), (0xD0, ('fo', 'fb')), (0xE0, ('w_t',)),
                       (0xF0, ('w_t2',))):
        g('''
    ld   [shs], ac
    add  0x%02X, x
    ld   [y,x], ac''' % off)
        for nm in names:
            g('    ld   ac, [%s]' % nm)
    g('''
    ld   [w_t2], y
    jmp  [w_t]''')
    for s, sh in enumerate(ships):
        name, ang, rates, prate, PX, PY, PZ = sh
        g.chunk('ship %d: %s, its path' % (s, name))
        g('ship_%d:' % s)
        gen_sinpos(g, PX, 'oxl', 'oxh')
        gen_sinpos(g, PY, 'oyl', 'oyh')
        gen_sinpos(g, PZ, 'ozl', 'ozh')
        g('    GOTO ship_body')
    g.chunk('ship_body: transform, faces, then the lines or the outline')
    g('''
ship_body:
    ld   0x%(ship)02X, y
    ld   [shs], ac
    add  0x%(ozl)02X, x
    ld   [ozl], ac
    ld   ac, [y,x]
    ld   [shs], ac
    add  0x%(ozh)02X, x
    ld   [ozh], ac
    ld   ac, [y,x]
pm_m:
    CALL matrix
    ld   1, ac
    ld   ac, [allv]
pm_x:
    CALL xform
pm_c:
    CALL camera
    ld   [mode], ac
    beq  sb_1
    CALL lights
sb_1:
pm_t:
    CALL tents
pm_f:
    CALL faces
    ld   [mode], ac
    beq  sb_w
    GOTO ship_fill
sb_w:
    GOTO ship_wire''' % {'ship': P_SHIP, 'ozl': SH_OZL, 'ozh': SH_OZH})
    g.chunk('ship_wire: the line records, then the old lines erased and the new drawn')
    g('''
ship_wire:
    ld   [nrec], ac
    ld   ac, [nst]
pm_e:
    CALL edges
    ld   0x%(ship)02X, y
    ld   [shs8], ac
    add  4, x
    ld   [y,x], ac
    ld   ac, [rk]
    ld   [shs8], ac
    add  5, x
    ld   [y,x], ac
    ld   ac, [rend]
    ld   [par], ac
    xor  1, ac
pm_r:
    CALL drawl
    ld   [nst], ac
    ld   ac, [rk]
    ld   [nrec], ac
    ld   ac, [rend]
    ld   [par], ac
pm_d:
    CALL drawl
pm_o:
    ld   0x%(ship)02X, y
    ld   [shs8], ac
    add  4, x
    ld   [nst], ac
    ld   ac, [y,x]
    ld   [shs8], ac
    add  5, x
    ld   [nrec], ac
    ld   ac, [y,x]
    GOTO ship_next''' % {'ship': P_SHIP})
    g.chunk('ship_fill: the outline (if every vertex is on the picture), then the erase')
    g('''
ship_fill:
    ld   [allv], ac
    beq  sf_off
pm_fo:
    CALL foot
    ld   0x%(ship)02X, y
    ld   [shs], ac
    add  0x%(drawn)02X, x
    ld   1, [y,x]
    bra  sf_er
sf_off:
    ld   0x%(ship)02X, y
    ld   [shs], ac
    add  0x%(drawn)02X, x
    ld   0, [y,x]
    ld   0, ac
    ld   ac, [ntop]
    ld   ac, [nbot]
sf_er:
pm_er:
    CALL erase
    GOTO ship_next''' % {'ship': P_SHIP, 'drawn': SH_DRAWN})
    g.chunk('ship_next')
    g('''
ship_next:
pm_n:
    ld   [shs], ac
    add  1, ac
    ld   ac, [shs]
    xor  %(n)d, ac
    beq  sn_done
    ld   [shs8], ac
    add  8, ac
    ld   ac, [shs8]
    GOTO ship_pre
sn_done:
    ld   [mode], ac
    beq  sn_w
    GOTO fill_pass
sn_w:
    GOTO frame_end''' % {'n': n})


def data_page(g, page, values, comment, off=0):
    g.fixed((page << 8) + off, comment)
    assert off + len(values) <= 256, (comment, len(values))
    for i in range(0, len(values), 16):
        g('    #d8 ' + ', '.join('0x%02X' % (v & 0xFF) for v in values[i:i + 16]))


def gen_tables(g, ships):
    data_page(g, P_QV, TAB['QV'], 'QV: round(n * n / 126), n = -128..127 (matrix x vertex)')
    data_page(g, P_QM, TAB['QM'], 'QM: round(n * n / 252) (matrix x matrix)')
    data_page(g, P_SIN, TAB['SIN'], 'SIN: 63 sin(2 pi i / 256)')
    data_page(g, P_ROW, TAB['ROW'], 'ROW: address low byte of picture line l (2x rows)')
    data_page(g, P_LGL, [v & 0xFF for v in TAB['LG'][:256]], 'LG low: 256 log2(n) + 4096, n < 256')
    data_page(g, P_LGL + 1, [v & 0xFF for v in TAB['LG'][256:]], 'LG low, n = 256-511')
    data_page(g, P_LGH, [v >> 8 for v in TAB['LG'][:256]], 'LG high')
    data_page(g, P_LGH + 1, [v >> 8 for v in TAB['LG'][256:]], 'LG high, n = 256-511')
    data_page(g, P_CPG, TAB['CPG'][:256], 'CPG: video page of pixel x (byte column)')
    data_page(g, P_CPG + 1, TAB['CPG'][256:320], 'CPG, x = 256-319')
    g.fixed((P_MISC << 8) + XLO, 'XLO: x16 low byte of a pixel phase; LMK4, RMK4: masks')
    g('    #d8 ' + ', '.join('0x%02X' % v for v in
                             [32, 96, 160, 224, 0xFF, 0xFC, 0xF0, 0xC0, 0x00, 0x03, 0x0F, 0x3F]))
    g.fixed(((P_CPG + 1) << 8) + ENTL, 'ENT: line loop entries, low bytes then high')
    names = ['ex_%s%d' % (v, p) for v in VARIANTS for p in range(4)]
    g('    #d8 ' + ', '.join('%s & 0xFF' % n for n in names))
    g.fixed(((P_CPG + 1) << 8) + ENTH)
    g('    #d8 ' + ', '.join('%s >> 8' % n for n in names))
    for k in range(8):
        data_page(g, P_ANT + k, TAB['ANT'][k], 'ANT%d: 2^(%d + f/256)' % (k, k))
    cols = {k: [] for k in ('vx', 'vy', 'vz', 'mir', 'fs', 'fn', 'fix', 'fiy', 'fiz', 'd1l', 'd1h',
                            'ev1', 'ev2', 'ef1', 'ef2', 'edir', 'fvl', 'ta', 'tul', 'tuh', 'tkp',
                            'tkn')}
    for name, m in MODELS.items():
        cols['vx'] += [p[0] for p in m['v']]
        cols['vy'] += [p[1] for p in m['v']]
        cols['vz'] += [p[2] for p in m['v']]
        cols['mir'] += m['mir']
        for f, (ix, iy, iz), d1 in zip(m['f'], m['fidx'], m['d1']):
            cols['fs'].append(len(cols['fvl']))
            cols['fn'].append(len(f))
            cols['fvl'] += f
            cols['fix'].append(ix)
            cols['fiy'].append(iy)
            cols['fiz'].append(iz)
            cols['d1l'].append(d1 & 0xFF)
            cols['d1h'].append((d1 >> 8) & 0xFF)
        for v1, v2, f1, f2, d in m['e']:
            cols['ev1'].append(v1)
            cols['ev2'].append(v2)
            cols['ef1'].append(f1)
            cols['ef2'].append(f2)
            cols['edir'].append(d)
        for a, u, kp, kn in m['tent']:
            cols['ta'].append(a)
            cols['tul'].append(lg(u) & 0xFF)
            cols['tuh'].append(lg(u) >> 8)
            cols['tkp'].append(kp)
            cols['tkn'].append(255 if kn is None else kn)
    for page, items in ((P_MV, (('vx', 'model vertices: x'), ('vy', 'y'), ('vz', 'z'),
                                ('mir', 'mirror: 0 full, 1 + axis: the previous one, that negated'))),
                        (P_MF, (('fs', 'faces: first vertex in FVL'), ('fn', 'vertices'),
                                ('fix', 'product index of n x'), ('fiy', 'n y'))),
                        (P_MF2, (('fiz', 'n z'), ('d1l', 'D1 = n . centre / 2 + 1, low'),
                                 ('d1h', 'high'))),
                        (P_TE, (('ta', 'product entries: axis'), ('tul', 'log u low'),
                                ('tuh', 'high'), ('tkp', 'index of +u'))),
                        (P_TE2, (('tkn', 'index of -u (255: none)'),))):
        for q, (k, c) in enumerate(items):
            data_page(g, page, cols[k], c, q * 0x40)
    for page, items in ((P_ME, (('ev1', 'edges: vertex 1'), ('ev2', 'vertex 2'))),
                        (P_ME2, (('ef1', 'face 1'), ('ef2', 'face 2'))),
                        (P_ME3, (('edir', '1: face 1 goes vertex 1 -> 2'),))):
        for q, (k, c) in enumerate(items):
            data_page(g, page, cols[k], c, q * 0x80)
    data_page(g, P_FVL, cols['fvl'], 'face vertex lists (clockwise from outside)')
    # ship constants
    sc = [0] * 256
    vb = fb = 0
    for s, sh in enumerate(ships):
        name, ang, rates, prate, PX, PY, PZ = sh
        m = MODELS[name]
        mv, mf, me, mt, _ = MODEL_BASE[name]
        for k, v in enumerate(list(rates) + [prate, mv, len(m['v']), mf, len(m['f']), me,
                                             len(m['e']), mt, len(m['tent']), vb, fb]):
            sc[16 * k + s] = v & 0xFF
        vb += len(m['v'])
        fb += len(m['f'])
    assert vb <= 255 and fb <= 255
    data_page(g, P_SC, sc[:0xE0], 'ship constants (16 each): rates a1 a2 a3 t, MV NV MF NF ME NE '
              'TB NT, vertex base, face base')
    g.fixed((P_SC << 8) + 0xE0, 'the ships\' path code, low bytes then high')
    g('    #d8 ' + ', '.join('ship_%d & 0xFF' % s for s in range(len(ships))))
    g.fixed((P_SC << 8) + 0xF0)
    g('    #d8 ' + ', '.join('ship_%d >> 8' % s for s in range(len(ships))))
    init = [0] * 48
    for s, sh in enumerate(ships):
        for k in range(3):
            init[16 * k + s] = sh[1][k] & 0xFF
    data_page(g, P_SC2, init, 'initial angles a1, a2, a3 (16 each)')


def gen_main(g, ships, title, pace, secs, start):
    n = len(ships)
    g.fixed(0x0100, 'main')
    g('''
main:
    ld   STACK_TOP, ac
    ld   ac, [SP]
    ld   0x07, ac
    ld   ac, [MAP_SHADOW]''')
    g.call2('screen', 'lk_sc')
    g('''
    ld   0, ac
    ld   ac, [w_g]
mc_lp:
    ld   [w_g], ac
    shl
    shl
    shl
    ld   ac, [w_t]
    ld   0x%(sc2)02X, y
    ld   [w_g], x
    ld   [y,x], ac
    ld   ac, [a1]
    ld   [w_g], ac
    add  0x10, x
    ld   [y,x], ac
    ld   ac, [a2]
    ld   [w_g], ac
    add  0x20, x
    ld   [y,x], ac
    ld   ac, [a3]
    ld   0x%(ship)02X, y
    ld   [w_t], x
    ld   [a1], ac
    ld   ac, [y,x]
    ld   [w_t], ac
    add  1, x
    ld   [a2], ac
    ld   ac, [y,x]
    ld   [w_t], ac
    add  2, x
    ld   [a3], ac
    ld   ac, [y,x]''' % {'sc2': P_SC2, 'ship': P_SHIP})
    for k in range(3, 8):
        g('    ld   [w_t], ac\n    add  %d, x\n    ld   0, [y,x]' % k)
    g('''
    ld   [w_g], ac
    add  1, ac
    ld   ac, [w_g]
    xor  %(n)d, ac
    bne  mc_lp
    GOTO main_c''' % {'n': n})
    g.chunk()
    g('''
main_c:
    ld   %(start)d, ac
    ld   ac, [mode]
    ld   0, ac
    ld   ac, [msec]
    ld   ac, [par]
    ld   ac, [lps]
    ld   ac, [fps]
    ld   ac, [nrec]
    ld   ac, [nfac]
    ld   [FRAME_LO], ac
    ld   ac, [secf]
    ld   ac, [lastf]
    ld   [mode], ac
    beq  mc_i1
    CALL fill_init
mc_i1:
    ld   0xFF, ac
    ld   0x50, y
    ld   ac, [y,x]
    GOTO frame''' % {'start': start})
    g.chunk('screen: clear, the text band, the title (map 07)')
    g('''
screen:
    ld   0x%02X, ac
    CALL vid_clear
    ld   0x5A, y
    ld   0x20, ac
sc_m:
    ld   ac, x
    ld   0x%02X, [y,x]
    add  1, ac
    xor  0x%02X, ac
    beq  sc_d
    xor  0x%02X, ac
    bra  sc_m
sc_d:
    ld   0, ac''' % (MODE_PIC, MODE_HUD, 0x20 + HUD_ROWS, 0x20 + HUD_ROWS))
    g('''
    ld   ac, [CUR_COL]
    ld   ac, [CUR_ROW]
    ld   s_title & 0xFF, ac
    ld   ac, [R0]
    ld   s_title >> 8, ac
    ld   ac, [R1]
    CALL con_puts
    ld   [lk_sc_h], y
    jmp  [lk_sc_l]''')
    g.chunk('frame: every ship, then (filled) the paint pass, the frame count and the menu hook')
    g('''
frame:
    ld   0, ac
    ld   ac, [nrec]
    ld   ac, [nfac]
    ld   ac, [shs]
    ld   ac, [shs8]
    GOTO ship_pre''')
    g.chunk()
    g('''
frame_end:
    ld   [lps], ac
    inc
    ld   ac, [lps]
    ld   [FRAME_LO], ac
    sub  [secf], ac
    sub  60, ac
    bcs  fe_ns
    ld   [secf], ac
    add  60, ac
    ld   ac, [secf]
    ld   [lps], ac
    ld   ac, [fps]
    ld   0, ac
    ld   ac, [lps]
    ld   [msec], ac
    add  1, ac
    ld   ac, [msec]
    ld   0x07, ac
    ld   0x50, y
    ld   ac, [y,x]
    GOTO hud
fe_ns:
    ld   0x07, ac
    ld   0x50, y
    ld   ac, [y,x]
    GOTO fe_menu''')
    g.chunk('hud: the second text row')
    g('''
hud:
    ld   0, ac
    ld   ac, [CUR_COL]
    ld   1, ac
    ld   ac, [CUR_ROW]
    ld   s_fps & 0xFF, ac
    ld   ac, [R0]
    ld   s_fps >> 8, ac
    ld   ac, [R1]
    CALL con_puts
    ld   [fps], ac
    CALL con_dec8
    ld   [mode], ac
    bne  hu_f
    ld   s_wire & 0xFF, ac
    ld   ac, [R0]
    ld   s_wire >> 8, ac
    ld   ac, [R1]
    CALL con_puts
    ld   [nrec], ac
    bra  hu_n
hu_f:
    ld   s_fill & 0xFF, ac
    ld   ac, [R0]
    ld   s_fill >> 8, ac
    ld   ac, [R1]
    CALL con_puts
    ld   [nfac], ac
hu_n:
    CALL con_dec8
    ld   s_sp & 0xFF, ac
    ld   ac, [R0]
    ld   s_sp >> 8, ac
    ld   ac, [R1]
    CALL con_puts
    GOTO fe_menu''')
    g.chunk('fe_menu: wait for the frame cap, the menu hook, the mode switch (a key or time)')
    g('fe_menu:')
    if pace:
        g('fe_wait:')
        g.tick()
        g('''
    ld   [FRAME_LO], ac
    sub  [lastf], ac
    sub  %d, ac
    bcs  fe_wait
    ld   [FRAME_LO], ac
    ld   ac, [lastf]''' % pace)
    g('''
fe_mark:
    CALL kbd_scan
    CALL menu_poll
    CALL kbd_getc
    bne  fe_sw
    ld   [msec], ac
    sub  %d, ac
    bcc  fe_sw
fe_go:
    ld   0xFF, ac
    ld   0x50, y
    ld   ac, [y,x]
    ld   [par], ac
    xor  1, ac
    ld   ac, [par]
    GOTO frame
fe_sw:
    GOTO switch''' % secs)
    g.chunk('switch: the other mode: a clear screen, every ship\'s old lines or outline forgotten')
    g('''
switch:
    ld   [mode], ac
    xor  1, ac
    ld   ac, [mode]
    ld   0, ac
    ld   ac, [msec]
    ld   ac, [nrec]''')
    g.call2('screen', 'lk_sc')
    g('''
    ld   0x%(ship)02X, y
    ld   0, ac
    ld   ac, [w_g]
sw_lp:
    add  4, x
    ld   0, [y,x]
    ld   [w_g], ac
    add  5, x
    ld   0, [y,x]
    ld   [w_g], ac
    add  6, x
    ld   0, [y,x]
    ld   [w_g], ac
    add  7, x
    ld   0, [y,x]
    ld   [w_g], ac
    add  8, ac
    ld   ac, [w_g]
    xor  %(n8)d, ac
    beq  sw_d
    ld   [w_g], ac
    bra  sw_lp
sw_d:
    ld   [mode], ac
    beq  sw_w
    CALL fill_init
sw_w:
    GOTO fe_go''' % {'ship': P_SHIP, 'n8': 8 * n})
    g.fixed((P_SC2 << 8) + 0x30, 'strings')
    g('s_title:\n    #d "%s", 0x00' % title)
    g('s_fps:\n    #d "FPS ", 0x00')
    g('s_wire:\n    #d "   WIREFRAME   LINES ", 0x00')
    g('s_fill:\n    #d "   FILLED      FACES ", 0x00')
    g('s_sp:\n    #d "   ", 0x00')


def generate(ships, pace=2, secs=MODE_SECS, start=0):
    g = Gen()
    nverts = sum(len(MODELS[s[0]]['v']) for s in ships)
    nfaces = sum(len(MODELS[s[0]]['f']) for s in ships)
    assert len(ships) <= MAX_SHIPS
    title = 'PLACARD 3D  %d SHIPS  %d VERTICES  %d FACES   ANY KEY: MODE   ESC: DOS' % (
        len(ships), nverts, nfaces)
    head = ['; ' + '=' * 60,
            '; wire3d.masm - Elite-style 3D: wireframes and filled faces (made by',
            ';   gen_wire3d.py: change that and run it again; see its docstring)',
            '; Date: 10/28/2026',
            '; ' + '=' * 60, '',
            '#include "placard.asm"',
            '#include "placard_lib.asm"', '']
    head += zp_lines()
    head += ['', '.prefix w3', '.region 0x2000, 0x%04X' % (P_QV << 8)]
    g.out = head
    gen_lines(g)
    g.out += ['', '.region 0x0100, 0x1F00']
    gen_main(g, ships, title, pace, secs, start)
    gen_ships(g, ships)
    gen_matrix(g)
    gen_xform(g)
    gen_camera(g)
    gen_lights(g)
    gen_tents(g)
    gen_faces(g)
    gen_edges(g)
    gen_setup(g)
    gen_drawl(g)
    gen_span(g)
    gen_esetup(g)
    gen_adv(g)
    gen_fill_face(g)
    gen_foot(g)
    gen_erase(g)
    gen_fill_pass(g, len(ships))
    gen_fill_init(g)
    gen_tables(g, ships)
    return pack('\n'.join(g.out) + '\n')


def pack(text):
    """the chunks of each region largest first, so asm_expand's first fit
    leaves little room unused"""
    import asm_expand as ae
    _, chunks = ae.expand(text, 'wire3d.masm')
    size = {c.lineno: c.size for c in chunks}
    head, blocks, region, cur = [], [], None, None
    for n, ln in enumerate(text.splitlines(), 1):
        word = ln.split(';')[0].split(None, 1)[0] if ln.split(';')[0].strip() else ''
        if word == '.region':
            region = ln
            continue
        if word in ('.chunk', '.fixed'):
            cur = [region if word == '.chunk' else None, size[n], [ln]]
            blocks.append(cur)
            continue
        (head if cur is None else cur[2]).append(ln)
    out = list(head)
    regions = []
    for b in blocks:
        if b[0] is not None and b[0] not in regions:
            regions.append(b[0])
    for r in regions:
        out += ['', r]
        for b in sorted((b for b in blocks if b[0] == r), key=lambda b: -b[1]):
            out += b[2]
    for b in blocks:
        if b[0] is None:
            out += b[2]
    return '\n'.join(out) + '\n'


ROM_IMG = 0x8000             # the ROM build: RAM x0100-x3FFF kept at ROM x8000-xBEFF


def rom_wrapper(asm_path, out_path):
    """wire3d_rom.asm: a 64K development image (a ROM program at x6000) that
    copies the program into RAM x0100-x3FFF (not LIB_RAM, x1F00-x1FFF) and
    runs it, for build\\wire3d.bat; a temporary build for testing on the
    board without the SD card and the DOS"""
    import placard_sim as ps
    mem, syms, _ = ps.assemble(open(asm_path).read(), os.path.dirname(os.path.abspath(asm_path)))
    lib, _, _ = ps.assemble(open(os.path.join(HERE, 'rom_lib.asm')).read(), HERE)
    own = {a: v for a, v in mem.items()
           if 0x0100 <= a < 0x4000 and not (ps.lib_area(a) and lib.get(a) == v)}
    out = ['; ' + '=' * 60,
           '; wire3d_rom.asm - the 3D wireframe demo as a ROM program (made by',
           ';   gen_wire3d.py from wire3d.asm: change that and run it again)',
           ';',
           '; A temporary build for testing on the board: build\\wire3d.bat.  The stub at',
           '; x6000 copies RAM x0100-x3FFF (but x1F00-x1FFF, LIB_RAM) from its copy at',
           '; ROM x%04X-x%04X, sets map 07 as the DOS would, and jumps to the program.' % (
               ROM_IMG, ROM_IMG + 0x3EFF),
           '; Without the DOS there is no menu block, so Esc does nothing.',
           '; Date: 10/28/2026',
           '; ' + '=' * 60, '',
           '#include "placard.asm"',
           '#include "placard_lib.asm"', '',
           'cp_pg   = 0x20',
           'W_MAIN  = 0x%04X' % syms['main'],
           'W_FE_MARK = 0x%04X' % syms['fe_mark'], '',
           '#addr 0x6000',
           'main:',
           '    ld   STACK_TOP, ac',
           '    ld   ac, [SP]',
           '    ld   0x01, ac',
           '    ld   ac, [cp_pg]',
           'cp_loop:',
           '    xor  0x1F, ac',
           '    beq  cp_next                 ; leave LIB_RAM alone',
           '    ld   0, ac',
           '    ld   ac, [R0]',
           '    ld   ac, [R2]',
           '    ld   ac, [R4]                ; 256 bytes',
           '    ld   [cp_pg], ac',
           '    ld   ac, [R3]',
           '    add  0x%02X, ac' % ((ROM_IMG >> 8) - 1),
           '    ld   ac, [R1]',
           '    ld   LINK_LO, x',
           '    ld   cp_back, [x]',
           '    ld   LINK_HI, x',
           '    ld   cp_back >> 8, [x]',
           '    ld   memcpy >> 8, y',
           '    jmp  memcpy',
           'cp_back:',
           'cp_next:',
           '    ld   [cp_pg], ac',
           '    inc',
           '    ld   ac, [cp_pg]',
           '    xor  0x40, ac',
           '    beq  cp_done',
           '    xor  0x40, ac',
           '    bra  cp_loop',
           'cp_done:',
           '    ld   0x07, ac',
           '    ld   LINK_LO, x',
           '    ld   cp_go, [x]',
           '    ld   LINK_HI, x',
           '    ld   cp_go >> 8, [x]',
           '    ld   map_set >> 8, y',
           '    jmp  map_set',
           'cp_go:',
           '    ld   W_MAIN >> 8, y',
           '    jmp  W_MAIN', '',
           '; the program (wire3d.asm) as it is in RAM x0100-x3FFF',
           '#addr 0x%04X' % ROM_IMG]
    for a in range(0x0100, 0x4000, 16):
        out.append('    #d8 ' + ', '.join('0x%02X' % own.get(b, 0) for b in range(a, a + 16)))
    open(out_path, 'w', newline='\n').write('\n'.join(out) + '\n')


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--ships', type=int, default=DEMO_SHIPS)
    ap.add_argument('--pace', type=int, default=2,
                    help='video frames a frame at least (2 = 30 fps cap, 0 = as fast as it can)')
    ap.add_argument('--secs', type=int, default=MODE_SECS, help='seconds between the mode switches')
    ap.add_argument('--start', type=int, default=0, help='the first mode: 0 wireframe, 1 filled')
    ap.add_argument('-o', '--out', default=os.path.join(HERE, 'wire3d.masm'))
    ap.add_argument('--plc', default=None, help='the .PLC file (default ../../sdcard/WIRE3D.PLC '
                    'for the demo build, none otherwise; "none" for none)')
    a = ap.parse_args(argv)
    ships = ship_set(a.ships)
    open(a.out, 'w', newline='\n').write(generate(ships, a.pace, a.secs, a.start))
    subprocess.check_call([sys.executable, os.path.join(HERE, 'asm_expand.py'), a.out])
    asm = a.out[:-5] + '.asm'
    demo = (a.ships == DEMO_SHIPS and a.pace == 2 and a.secs == MODE_SECS and a.start == 0)
    plc = a.plc or (os.path.join(HERE, '..', '..', 'sdcard', 'WIRE3D.PLC') if demo else None)
    if plc and plc != 'none':
        subprocess.check_call([sys.executable, os.path.join(HERE, 'gen_plc.py'), asm, '-o', plc])
        rom = os.path.join(HERE, 'wire3d_rom.asm')
        rom_wrapper(asm, rom)
        subprocess.check_call([sys.executable, os.path.join(HERE, 'placard_sim.py'), rom])
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

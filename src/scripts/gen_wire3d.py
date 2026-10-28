#!/usr/bin/env python3
"""
gen_wire3d.py - generate wire3d.masm, an Elite-style 3D wireframe demo and
benchmark for the Placard CPU (a library program for the SD card, WIRE3D.PLC)

    python3 gen_wire3d.py                       wire3d.masm, wire3d.asm, ../../sdcard/WIRE3D.PLC,
                                                wire3d_rom.asm/.hex (build\\wire3d.bat: a ROM build for testing)
    python3 gen_wire3d.py --ships 8 -o w8.masm  a stress build: more ships (see SHIP_SETS)
    python3 test_wire3d_sim.py                  runs it in placard_sim: checks every frame
                                                against the Python model in this file,
                                                times each part, writes the GIF

WHAT IT DRAWS
    Up to 8 convex "ships" (a station, a freighter, two darts, a rock)
    tumbling and flying in front of a fixed camera, with hidden lines
    removed: an edge is drawn when one of its two faces looks at the camera.
    The picture is 320 x 240, 2 bpp, 2x line repeat (square pixels), white
    lines on black; the top 16 screen rows are a 1 bpp text band (title,
    frames per second, lines drawn).  Esc goes back to the DOS (menu_poll).

HOW (the BBC Micro Elite way, adapted to the Placard)
    - Orientation: each ship has three angles (yaw, pitch, roll) that turn
      a little every frame; the 3x3 matrix is made from a sine table with 14
      multiplies.  1.0 = 63.
    - Multiply: quarter squares, a*b = q(a+b) - q(a-b), one 256-byte table
      for each scale (QV: matrix x vertex, QM: matrix x matrix).  A product
      is 8 instructions, 32 clocks.  Vertices are |v| <= 60, so a + b fits
      a signed byte.  Rotated coordinates come out in half units (8 bits).
    - Projection: screen x = 160 + X * K / Z with logarithms: a 512-entry
      table of 256 * log2(n) (+ 4096, so log(0) is far below everything) and
      8 antilog pages, one per octave of the result.  A divide is a 16-bit
      subtract and two look-ups.
    - Hidden lines: a face is visible when its first three projected
      vertices turn the right way on the screen: dx1 * dy2 > dy1 * dx2,
      compared with the same log tables (signs apart, logs added).
    - Lines: a record per line (entry address, start byte, row, error,
      slope, end) is computed once; drawing runs the record through
      unrolled loops (x-major left to right, down or up; y-major top to
      bottom, right or left; one copy per pixel of the byte) that XOR the
      pixel: load, xor, store.  The slope is 256 * minor / major from the
      log tables (no divide).  Erasing is running the same records again
      the next frame, ship by ship, just before that ship's new lines are
      drawn (no screen clear, no double buffer, as in Elite).
    - Clipping: a vertex that projects off the picture (or is too close)
      is marked invalid and its edges are not drawn.

MEMORY (a library program, docs/DOS.md: RAM x0100-x3FFF)
    x0100-x1EFF, x2000-x22FF  code (asm_expand.py packs the chunks)
    x2300-x3FFF               tables and ship models (TABLES below)
    x4000-x47FF / x4800-x4FFF line records, two buffers (frame parity),
                              8 field pages each, up to 255 lines a frame
    x5400-x5800               projected vertices (SX low, SX high, SY,
                              valid) and visible faces
    x5900                     ship state (angles, path phase, old records)
    zero page x20-x7F
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

# table pages
P_QV, P_QM, P_SIN, P_ROW = 0x23, 0x24, 0x25, 0x26
P_LGL, P_LGH = 0x27, 0x29   # two pages each (n < 256, n >= 256)
P_CPG = 0x2B                # two pages; ENT tables in the second one
P_ANT = 0x2D                # 8 pages
P_MVX, P_MVY, P_MVZ = 0x35, 0x36, 0x37
P_MFA, P_MFB, P_MFC = 0x38, 0x39, 0x3A
P_MEV1, P_MEV2, P_MEF1, P_MEF2 = 0x3B, 0x3C, 0x3D, 0x3E
P_SPARE = 0x3F
ENTL = 0x80                 # in page P_CPG + 1
ENTH = 0xA0
# runtime pages
P_REC = (0x40, 0x48)        # record buffers 0 and 1: 8 field pages each
P_SXL, P_SXH, P_SY, P_VAL, P_FV, P_SHIP = 0x54, 0x55, 0x56, 0x57, 0x58, 0x59

MASK = [0x03, 0x0C, 0x30, 0xC0]
VARIANTS = ['xd', 'xu', 'td', 'tu', 'yr', 'yl']   # entry table order, 4 phases each


# ---------------------------------------------------------------------------
# tables
# ---------------------------------------------------------------------------
def s8(v):
    return v - 256 if v >= 128 else v


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
    """(faces as vertex lists ordered so (b-a) x (c-a) points out, edges as
    (v1, v2, f1, f2))"""
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
    faces = []
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
    edges = {}
    for fi, poly in enumerate(faces):
        for k in range(len(poly)):
            a, b = poly[k], poly[(k + 1) % len(poly)]
            edges.setdefault((min(a, b), max(a, b)), []).append(fi)
    elist = []
    for (a, b), fs in sorted(edges.items()):
        assert len(fs) == 2, (a, b, fs)
        elist.append((a, b, fs[0], fs[1]))
    return faces, elist


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
    for name, pts in model_points().items():
        faces, edges = hull(pts)
        out[name] = {'v': pts, 'f': faces, 'e': edges}
    return out


MODELS = models()

# ship sets: (model, angles, angle rates, path rate, X, Y, Z) with
# X/Y/Z = (centre, k, phase): centre + (sin(t + phase) << k), or k None: centre
SHIP_SETS = {
    4: [('station', (0, 20, 0), (1, 0, 2), 0, (-150, None, 0), (140, None, 0), (380, None, 0)),
        ('freighter', (64, 0, 20), (1, 0, 0), 1, (0, 1, 0), (-80, None, 0), (300, 0, 64)),
        ('dart', (64, 0, 236), (2, 0, 0), 2, (130, 0, 0), (40, None, 0), (270, 0, 64)),
        ('dart', (192, 10, 0), (255, 1, 3), 255, (-130, 0, 0), (-40, None, 0), (250, 0, 64))],
}


def ship_set(n):
    if n in SHIP_SETS:
        return SHIP_SETS[n]
    base = SHIP_SETS[4]
    extra = [('rock', (10, 40, 70), (1, 2, 1), 1, (170, None, 0), (150, None, 0), (390, None, 0)),
             ('rock', (0, 0, 0), (2, 1, 2), 2, (40, None, 0), (190, None, 0), (390, None, 0)),
             ('dart', (50, 0, 0), (1, 2, 3), 1, (-200, None, 0), (-150, None, 0), (380, None, 0)),
             ('freighter', (0, 0, 30), (1, 1, 1), 1, (190, None, 0), (-160, None, 0), (390, None, 0)),
             ('rock', (30, 0, 90), (1, 1, 2), 1, (0, None, 0), (-210, None, 0), (380, None, 0)),
             ('dart', (90, 9, 9), (2, 1, 1), 1, (-260, None, 0), (60, None, 0), (390, None, 0)),
             ('rock', (70, 3, 30), (2, 2, 1), 1, (270, None, 0), (20, None, 0), (390, None, 0)),
             ('dart', (40, 9, 9), (1, 3, 1), 1, (-60, None, 0), (20, None, 0), (390, None, 0))]
    return (base + extra)[:n]


# ---------------------------------------------------------------------------
# the Python model of everything the program computes (integer-exact)
# ---------------------------------------------------------------------------
def sinpos(t, c, k, ph):
    if k is None:
        return c
    s = s8(TAB['SIN'][(t + ph) & 0xFF])
    return (c + (s << k)) & 0xFFFF


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
    def facing(pa, pb, pc):
        d = lambda p, q: (q[0] - p[0], q[1] - p[1])
        dx1, dy1 = d(pa, pb)
        dx2, dy2 = d(pa, pc)
        L = lambda v: lg(abs(v))
        s1 = (dx1 < 0) ^ (dy2 < 0)
        s2 = (dy1 < 0) ^ (dx2 < 0)
        if s1 != s2:
            return not s1
        l1 = L(dx1) + L(dy2)
        l2 = L(dy1) + L(dx2)
        if l1 > l2:
            return not s1
        return s1               # smaller or equal: as the program does

    def frame(self):
        """advance one frame; returns the list of lines (x0, y0, x1, y1) per ship"""
        out = []
        self.debug = []
        for si, sh in enumerate(self.ships):
            name, _, rates, prate, PX, PY, PZ = sh
            st = self.state[si]
            for k in range(3):
                st[k] = (st[k] + rates[k]) & 0xFF
            st[3] = (st[3] + prate) & 0xFF
            t = st[3]
            ox, oy, oz = (sinpos(t, *P) for P in (PX, PY, PZ))
            ox, oy, oz = (s8w(v) for v in (ox, oy, oz))
            M = self.matrix(*st[:3])
            mdl = MODELS[name]
            pv = [self.project(M, ox, oy, oz, v) for v in mdl['v']]
            vis = []
            for f in mdl['f']:
                a, b, c = (pv[i] for i in f[:3])
                vis.append(True if None in (a, b, c) else self.facing(a, b, c))
            self.debug.append((pv, vis))
            lines = []
            for v1, v2, f1, f2 in mdl['e']:
                if (vis[f1] or vis[f2]) and pv[v1] and pv[v2]:
                    lines.append(pv[v1] + pv[v2])
            out.append(lines)
        return out


def s8w(v):
    v &= 0xFFFF
    return v - 0x10000 if v >= 0x8000 else v


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


def screen_of(lines_per_ship):
    """the picture (set of lit (x, line)) the XOR of all those lines makes"""
    lit = set()
    for lines in lines_per_ship:
        for ln in lines:
            for p in line_pixels(*ln):
                lit ^= {p}
    return lit


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


ZP = ['w_t', 'w_t2', 'w_t3', 'w_t4', 'w_acc',
      'm0', 'm1', 'm2', 'm3', 'm4', 'm5', 'm6', 'm7', 'm8',
      's1', 'c1', 's2', 'c2', 's3', 'c3', 'w_p', 'w_q',
      'a1', 'a2', 'a3', 'tt',
      'vx', 'vy', 'vz', 'ozl', 'ozh', 'oxl', 'oxh', 'oyl', 'oyh',
      'zl', 'zh', 'dl', 'dh', 'ml', 'mh', 'sl', 'w_r',
      'vi', 'vo', 'vn', 'vb', 'fi', 'fo', 'fn', 'fb', 'ei', 'en',
      'fa', 'fb_', 'fc', 'axl', 'axh', 'ay', 'gl', 'gh',
      'sg1', 'sg2', 'l1l', 'l1h', 'l2l', 'l2h',
      'ev1', 'ev2', 'x0l', 'x0h', 'y0', 'x1l', 'x1h', 'y1',
      'dxl', 'dxh', 'adxl', 'adxh', 'ady', 'sgx', 'sgy',
      'bxl', 'bxh', 'by', 'exl', 'exh', 'ey', 'dirf', 'ph', 'ehi',
      'err', 'frac', 'pg', 'off', 'endv', 'ntail', 'jlo', 'rk', 'rend', 'rlo', 'rhi',
      'nrec', 'nst', 'par', 'lps', 'fps', 'secf', 'lastf', 'pl', 'phh']


def zp_lines():
    assert 0x20 + len(ZP) <= 0x90, len(ZP)
    return ['%-6s = 0x%02X' % (n, 0x20 + i) for i, n in enumerate(ZP)]


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


def gen_dot(g, ma, mb, mc):
    """AC = row (ma, mb, mc) . (vx, vy, vz), Y = QV"""
    g('''
    ld   [%(a)s], ac
    add  [vx], x
    ld   [y,x], ac
    ld   ac, [w_acc]
    ld   [%(a)s], ac
    sub  [vx], x
    ld   [w_acc], ac
    sub  [y,x], ac
    ld   ac, [w_acc]
    ld   [%(b)s], ac
    add  [vy], x
    ld   [w_acc], ac
    add  [y,x], ac
    ld   ac, [w_acc]
    ld   [%(b)s], ac
    sub  [vy], x
    ld   [w_acc], ac
    sub  [y,x], ac
    ld   ac, [w_acc]
    ld   [%(c)s], ac
    add  [vz], x
    ld   [w_acc], ac
    add  [y,x], ac
    ld   ac, [w_acc]
    ld   [%(c)s], ac
    sub  [vz], x
    ld   [w_acc], ac
    sub  [y,x], ac''' % {'a': ma, 'b': mb, 'c': mc})


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
    g.chunk('xform: project vn model vertices from vi to the arrays at vo')
    g('''
xform:
xf_loop:
    ld   0x%02X, y
    ld   [vi], ac
    ld   ac, x
    ld   [y,x], ac
    ld   ac, [vx]
    ld   0x%02X, y
    ld   [y,x], ac
    ld   ac, [vy]
    ld   0x%02X, y
    ld   [y,x], ac
    ld   ac, [vz]
    ld   0x%02X, y''' % (P_MVX, P_MVY, P_MVZ, P_QV))
    gen_dot(g, 'm6', 'm7', 'm8')
    g('''
    GOTO xf_z''')
    g.chunk()
    g('xf_z:')
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
    ld   0x%02X, y''' % (ZMIN, P_LGH, P_LGL, LK & 0xFF, LK >> 8, P_QV))
    gen_dot(g, 'm0', 'm1', 'm2')
    g('''
    GOTO xf_x
xz_bad:
    GOTO xf_bad''')
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
    g('    ld   0x%02X, y' % P_QV)
    gen_dot(g, 'm3', 'm4', 'm5')
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


def gen_delta(g, idx, dlv, dhv):
    """(dh:dl) = SX[idx] - SX[a] and gl = SY[idx] - SY[a] as 16 bits (gh)"""
    a, b = g.lab('dd'), g.lab('dd')
    g('''
    ld   0x%(sxl)02X, y
    ld   [%(i)s], x
    ld   [y,x], ac
    sub  [axl], ac
    ld   ac, [%(dl)s]
    ld   0x%(sxh)02X, y
    ld   [y,x], ac
    bcc  %(a)s
    dec
%(a)s:
    sub  [axh], ac
    ld   ac, [%(dh)s]
    ld   0x%(sy)02X, y
    ld   [y,x], ac
    sub  [ay], ac
    ld   ac, [gl]
    ld   0, ac
    bcc  %(b)s
    ld   255, ac
%(b)s:
    ld   ac, [gh]''' % {'sxl': P_SXL, 'sxh': P_SXH, 'sy': P_SY, 'i': idx, 'dl': dlv,
                         'dh': dhv, 'a': a, 'b': b})


def gen_abslog(g, lo, hi, sg, ll, lh, add):
    """log of |hi:lo| into (lh:ll) (add: added to it), sign into sg"""
    n, p, c, q = g.lab('al'), g.lab('al'), g.lab('al'), g.lab('al')
    g('''
    ld   [%(hi)s], ac
    blt  %(n)s
    bra  %(p)s
%(n)s:
    ld   [%(lo)s], ac
    xor  255, ac
    add  1, ac
    ld   ac, [%(lo)s]
    ld   [%(hi)s], ac
    xor  255, ac
    bcc  %(c)s
    inc
%(c)s:
    ld   ac, [%(hi)s]
    ld   [%(sg)s], ac
    xor  1, ac
    ld   ac, [%(sg)s]
%(p)s:
    ld   [%(hi)s], ac
    add  0x%(lgh)02X, y
    ld   [%(lo)s], x
    ld   [y,x], ac
    ld   ac, [w_t]
    ld   [%(hi)s], ac
    add  0x%(lgl)02X, y
    ld   [y,x], ac''' % {'hi': hi, 'lo': lo, 'sg': sg, 'n': n, 'p': p, 'c': c,
                         'lgh': P_LGH, 'lgl': P_LGL})
    if add:
        g('''
    add  [%(ll)s], ac
    ld   ac, [%(ll)s]
    ld   [w_t], ac
    bcc  %(q)s
    inc
%(q)s:
    add  [%(lh)s], ac
    ld   ac, [%(lh)s]''' % {'ll': ll, 'lh': lh, 'q': q})
    else:
        g('''
    ld   ac, [%(ll)s]
    ld   [w_t], ac
    ld   ac, [%(lh)s]''' % {'ll': ll, 'lh': lh})


def gen_faces(g):
    g.chunk('faces: FV[fo..] = 1 where face fi.. (fn of them) looks at the camera')
    g('''
faces:
fc_loop:
    ld   0x%(mfa)02X, y
    ld   [fi], ac
    ld   ac, x
    ld   [y,x], ac
    add  [vb], ac
    ld   ac, [fa]
    ld   0x%(mfb)02X, y
    ld   [y,x], ac
    add  [vb], ac
    ld   ac, [fb_]
    ld   0x%(mfc)02X, y
    ld   [y,x], ac
    add  [vb], ac
    ld   ac, [fc]
    ld   0x%(val)02X, y
    ld   [fa], x
    ld   [y,x], ac
    ld   [fb_], x
    and  [y,x], ac
    ld   [fc], x
    and  [y,x], ac
    beq  fc_v
    ld   0x%(sxl)02X, y
    ld   [fa], x
    ld   [y,x], ac
    ld   ac, [axl]
    ld   0x%(sxh)02X, y
    ld   [y,x], ac
    ld   ac, [axh]
    ld   0x%(sy)02X, y
    ld   [y,x], ac
    ld   ac, [ay]
    ld   0, ac
    ld   ac, [sg1]
    ld   ac, [sg2]
    GOTO fc_b
fc_v:
    GOTO fc_vis''' % {'mfa': P_MFA, 'mfb': P_MFB, 'mfc': P_MFC, 'val': P_VAL,
                      'sxl': P_SXL, 'sxh': P_SXH, 'sy': P_SY})
    g.chunk()
    g('fc_b:')
    gen_delta(g, 'fb_', 'dxl', 'dxh')
    gen_abslog(g, 'dxl', 'dxh', 'sg1', 'l1l', 'l1h', False)
    g('    GOTO fc_c')
    g.chunk()
    g('fc_c:')
    gen_abslog(g, 'gl', 'gh', 'sg2', 'l2l', 'l2h', False)
    g('    GOTO fc_d')
    g.chunk()
    g('fc_d:')
    gen_delta(g, 'fc', 'dxl', 'dxh')
    gen_abslog(g, 'dxl', 'dxh', 'sg2', 'l2l', 'l2h', True)
    g('    GOTO fc_e')
    g.chunk()
    g('fc_e:')
    gen_abslog(g, 'gl', 'gh', 'sg1', 'l1l', 'l1h', True)
    g('''
    ld   [sg1], ac
    xor  [sg2], ac
    beq  fc_same
    ld   [sg1], ac
    beq  fc_v2
    bra  fc_i2
fc_same:
    ld   [l1l], ac
    sub  [l2l], ac
    ld   ac, [w_t]
    ld   [l1h], ac
    bcc  fc_e1
    dec
fc_e1:
    sub  [l2h], ac
    blt  fc_lt
    bne  fc_gt
    ld   [w_t], ac
    beq  fc_lt
fc_gt:
    ld   [sg1], ac
    beq  fc_v2
    bra  fc_i2
fc_lt:
    ld   [sg1], ac
    bne  fc_v2
fc_i2:
    GOTO fc_invis
fc_v2:
    GOTO fc_vis''')
    g.chunk()
    g('''
fc_vis:
    ld   0x%02X, y
    ld   [fo], x
    ld   1, [y,x]
    bra  fc_next
fc_invis:
    ld   0x%02X, y
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
    RET''' % (P_FV, P_FV))


def gen_edges(g):
    g.chunk('edges: a line record for each edge ei.. (en of them) with a face shown')
    g('''
edges:
ed_loop:
    ld   [nrec], ac
    xor  255, ac
    beq  ed_skip
    ld   0x%(f1)02X, y
    ld   [ei], ac
    ld   ac, x
    ld   [y,x], ac
    add  [fb], x
    ld   0x%(fv)02X, y
    ld   [y,x], ac
    ld   ac, [w_t]
    ld   0x%(f2)02X, y
    ld   [ei], x
    ld   [y,x], ac
    add  [fb], x
    ld   0x%(fv)02X, y
    ld   [y,x], ac
    or   [w_t], ac
    beq  ed_skip
    ld   0x%(v1)02X, y
    ld   [ei], x
    ld   [y,x], ac
    add  [vb], ac
    ld   ac, [ev1]
    ld   0x%(v2)02X, y
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
    GOTO ed_next''' % {'f1': P_MEF1, 'f2': P_MEF2, 'fv': P_FV, 'v1': P_MEV1, 'v2': P_MEV2,
                       'val': P_VAL})
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
    ld   ac, [bxl]
    ld   [x0h], ac
    ld   ac, [bxh]
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
    ld   ac, [bxl]
    ld   [x1h], ac
    ld   ac, [bxh]
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
    ld   [bxh], ac
    add  0x%(cpg)02X, y
    ld   [bxl], x
    ld   [y,x], ac
    ld   ac, [pg]
    ld   [bxl], ac
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
    ld   ac, [bxl]
    ld   [x0h], ac
    ld   ac, [bxh]
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
    ld   ac, [bxl]
    ld   [x1h], ac
    ld   ac, [bxh]
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
    ld   [bxh], ac
    add  0x%(cpg)02X, y
    ld   [bxl], x
    ld   [y,x], ac
    ld   ac, [pg]
    ld   [bxl], ac
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
        if v == 'tu':
            g.out += ['', '.region 0x0100, 0x1F00']
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
    g.out += ['', '.region 0x0100, 0x1F00']
    for v in ('yr', 'yl'):
        right = v == 'yr'
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


def gen_ships(g, ships):
    vb = fb = 0
    mv = {}
    for s, sh in enumerate(ships):
        name, ang, rates, prate, PX, PY, PZ = sh
        m = MODELS[name]
        base = MODEL_BASE[name]
        g.chunk('ship %d: %s' % (s, name))
        g('ship_%d:' % s)
        g.tick()
        g('    ld   0x%02X, y' % P_SHIP)
        for k, (var, r) in enumerate(zip(('a1', 'a2', 'a3', 'tt'), list(rates) + [prate])):
            g('''
    ld   %d, x
    ld   [y,x], ac
    add  %d, ac
    ld   ac, [y,x]
    ld   ac, [%s]''' % (s * 8 + k, r & 0xFF, var))
        g('    GOTO ship_%d_p' % s)
        g.chunk()
        g('ship_%d_p:' % s)
        gen_sinpos(g, PX, 'oxl', 'oxh')
        gen_sinpos(g, PY, 'oyl', 'oyh')
        gen_sinpos(g, PZ, 'ozl', 'ozh')
        g('    GOTO ship_%d_b' % s)
        g.chunk()
        g('''
ship_%(s)d_b:
    CALL matrix
    ld   %(mv)d, ac
    ld   ac, [vi]
    ld   %(nv)d, ac
    ld   ac, [vn]
    ld   %(vb)d, ac
    ld   ac, [vo]
pm_x%(s)d:
    CALL xform
    ld   %(mf)d, ac
    ld   ac, [fi]
    ld   %(nf)d, ac
    ld   ac, [fn]
    ld   %(fb)d, ac
    ld   ac, [fo]
    ld   %(vb)d, ac
    ld   ac, [vb]
pm_f%(s)d:
    CALL faces
    ld   %(me)d, ac
    ld   ac, [ei]
    ld   %(ne)d, ac
    ld   ac, [en]
    ld   %(fb)d, ac
    ld   ac, [fb]
    ld   [nrec], ac
    ld   ac, [nst]
pm_e%(s)d:
    CALL edges
    GOTO ship_%(s)d_c''' % {'s': s, 'mv': base[0], 'nv': len(m['v']), 'vb': vb,
                            'mf': base[1], 'nf': len(m['f']), 'fb': fb,
                            'me': base[2], 'ne': len(m['e'])})
        g.chunk()
        nxt = 'ship_%d' % (s + 1) if s + 1 < len(ships) else 'frame_end'
        g('''
ship_%(s)d_c:
    ld   0x%(sp)02X, y
    ld   %(o4)d, x
    ld   [y,x], ac
    ld   ac, [rk]
    ld   %(o5)d, x
    ld   [y,x], ac
    ld   ac, [rend]
    ld   [par], ac
    xor  1, ac
pm_r%(s)d:
    CALL drawl
    ld   [nst], ac
    ld   ac, [rk]
    ld   [nrec], ac
    ld   ac, [rend]
    ld   [par], ac
pm_d%(s)d:
    CALL drawl
pm_o%(s)d:
    ld   0x%(sp)02X, y
    ld   %(o4)d, x
    ld   [nst], ac
    ld   ac, [y,x]
    ld   %(o5)d, x
    ld   [nrec], ac
    ld   ac, [y,x]
    GOTO %(n)s''' % {'s': s, 'sp': P_SHIP, 'o4': s * 8 + 4, 'o5': s * 8 + 5, 'n': nxt})
        vb += len(m['v'])
        fb += len(m['f'])
    assert vb <= 255 and fb <= 255
    return vb, fb


def model_bases():
    b, v, f, e = {}, 0, 0, 0
    for name, m in MODELS.items():
        b[name] = (v, f, e)
        v += len(m['v'])
        f += len(m['f'])
        e += len(m['e'])
    assert v <= 256 and f <= 256 and e <= 256
    return b


MODEL_BASE = model_bases()


def data_page(g, page, values, comment):
    g.fixed(page << 8, comment)
    for i in range(0, len(values), 16):
        g('    #d8 ' + ', '.join('0x%02X' % (v & 0xFF) for v in values[i:i + 16]))


def gen_tables(g):
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
    g.fixed(((P_CPG + 1) << 8) + ENTL, 'ENT: line loop entries, low bytes then high')
    names = ['ex_%s%d' % (v, p) for v in VARIANTS for p in range(4)]
    g('    #d8 ' + ', '.join('%s & 0xFF' % n for n in names))
    g.fixed(((P_CPG + 1) << 8) + ENTH)
    g('    #d8 ' + ', '.join('%s >> 8' % n for n in names))
    for k in range(8):
        data_page(g, P_ANT + k, TAB['ANT'][k], 'ANT%d: 2^(%d + f/256)' % (k, k))
    vx, vy, vz, fa, fb, fc, e1, e2, f1, f2 = ([] for _ in range(10))
    for name, m in MODELS.items():
        vx += [p[0] for p in m['v']]
        vy += [p[1] for p in m['v']]
        vz += [p[2] for p in m['v']]
        fa += [f[0] for f in m['f']]
        fb += [f[1] for f in m['f']]
        fc += [f[2] for f in m['f']]
        e1 += [e[0] for e in m['e']]
        e2 += [e[1] for e in m['e']]
        f1 += [e[2] for e in m['e']]
        f2 += [e[3] for e in m['e']]
    for page, vals, c in ((P_MVX, vx, 'model vertices x'), (P_MVY, vy, 'y'), (P_MVZ, vz, 'z'),
                          (P_MFA, fa, 'faces: first three vertices (a)'), (P_MFB, fb, 'b'),
                          (P_MFC, fc, 'c'), (P_MEV1, e1, 'edges: vertex 1'),
                          (P_MEV2, e2, 'vertex 2'), (P_MEF1, f1, 'face 1'), (P_MEF2, f2, 'face 2')):
        data_page(g, page, vals, c)


def gen_main(g, ships, title, nverts, pace):
    g.fixed(0x0100, 'main')
    g('''
main:
    ld   STACK_TOP, ac
    ld   ac, [SP]
    ld   0x07, ac
    ld   ac, [MAP_SHADOW]
    ld   0x%02X, ac
    CALL vid_clear
    GOTO main_b''' % MODE_PIC)
    g.chunk()
    g('main_b:')
    g('    ld   0x5A, y')
    for r in range(HUD_ROWS):
        g('    ld   0x%02X, x\n    ld   0x%02X, [y,x]' % (0x20 + r, MODE_HUD))
    g('''
    ld   0, ac
    ld   ac, [CUR_COL]
    ld   ac, [CUR_ROW]
    ld   s_title & 0xFF, ac
    ld   ac, [R0]
    ld   s_title >> 8, ac
    ld   ac, [R1]
    CALL con_puts
    GOTO main_c''')
    for s, sh in enumerate(ships):
        g.chunk()
        g('main_c%s:' % ('' if s == 0 else str(s)))
        g('    ld   0x%02X, y' % P_SHIP)
        for k, v in enumerate(list(sh[1]) + [0, 0, 0]):
            g('    ld   %d, x\n    ld   %d, [y,x]' % (s * 8 + k, v & 0xFF))
        if s + 1 < len(ships):
            g('    GOTO main_c%d' % (s + 1))
    g('''
    ld   0, ac
    ld   ac, [par]
    ld   ac, [lps]
    ld   ac, [fps]
    ld   ac, [nrec]
    ld   [FRAME_LO], ac
    ld   ac, [secf]
    ld   ac, [lastf]
    ld   0xFF, ac
    ld   0x50, y
    ld   ac, [y,x]
    GOTO frame''')
    g.chunk('frame: every ship, then the frame count and the menu hook')
    g('''
frame:
    ld   0, ac
    ld   ac, [nrec]
    GOTO ship_0''')
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
    ld   s_lines & 0xFF, ac
    ld   ac, [R0]
    ld   s_lines >> 8, ac
    ld   ac, [R1]
    CALL con_puts
    ld   [nrec], ac
    CALL con_dec8
    ld   s_sp & 0xFF, ac
    ld   ac, [R0]
    ld   s_sp >> 8, ac
    ld   ac, [R1]
    CALL con_puts
    GOTO fe_menu''')
    g.chunk('fe_menu: wait for the frame cap, then the menu hook')
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
    CALL menu_poll
    ld   0xFF, ac
    ld   0x50, y
    ld   ac, [y,x]
    ld   [par], ac
    xor  1, ac
    ld   ac, [par]
    GOTO frame''')
    g.chunk('strings')
    g('s_title:\n    #d "%s", 0x00' % title)
    g('s_fps:\n    #d "FPS ", 0x00')
    g('s_lines:\n    #d "   LINES ", 0x00')
    g('s_sp:\n    #d "   ", 0x00')


def generate(ships, pace=0):
    g = Gen()
    nverts = sum(len(MODELS[s[0]]['v']) for s in ships)
    nedges = sum(len(MODELS[s[0]]['e']) for s in ships)
    title = 'PLACARD 3D  %d SHIPS  %d VERTICES  %d EDGES  (ESC: DOS)' % (len(ships), nverts, nedges)
    head = ['; ' + '=' * 60,
            '; wire3d.masm - Elite-style 3D wireframes (made by gen_wire3d.py: change',
            ';   that and run it again; see its docstring)',
            '; Date: 10/28/2026',
            '; ' + '=' * 60, '',
            '#include "placard.asm"',
            '#include "placard_lib.asm"', '']
    head += zp_lines()
    head += ['', '.prefix w3', '.region 0x2000, 0x%04X' % (P_QV << 8)]
    g.out = head
    gen_lines(g)
    g.out += ['', '.region 0x0100, 0x1F00']
    gen_main(g, ships, title, nverts, pace)
    gen_ships(g, ships)
    gen_matrix(g)
    gen_xform(g)
    gen_faces(g)
    gen_edges(g)
    gen_setup(g)
    gen_drawl(g)
    gen_tables(g)
    return '\n'.join(g.out) + '\n'


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
    ap.add_argument('--ships', type=int, default=4)
    ap.add_argument('--pace', type=int, default=2,
                    help='video frames a frame at least (2 = 30 fps cap, 0 = as fast as it can)')
    ap.add_argument('-o', '--out', default=os.path.join(HERE, 'wire3d.masm'))
    ap.add_argument('--plc', default=None, help='the .PLC file (default ../../sdcard/WIRE3D.PLC '
                    'for the 4-ship build, none otherwise; "none" for none)')
    a = ap.parse_args(argv)
    ships = ship_set(a.ships)
    open(a.out, 'w', newline='\n').write(generate(ships, a.pace))
    subprocess.check_call([sys.executable, os.path.join(HERE, 'asm_expand.py'), a.out])
    asm = a.out[:-5] + '.asm'
    plc = a.plc or (os.path.join(HERE, '..', '..', 'sdcard', 'WIRE3D.PLC') if a.ships == 4 else None)
    if plc and plc != 'none':
        subprocess.check_call([sys.executable, os.path.join(HERE, 'gen_plc.py'), asm, '-o', plc])
        rom = os.path.join(HERE, 'wire3d_rom.asm')
        rom_wrapper(asm, rom)
        subprocess.check_call([sys.executable, os.path.join(HERE, 'placard_sim.py'), rom])
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""
gen_raycast.py - generate raycast.asm, a first-person ray casting demo for the
Placard CPU (a ROM program that uses the standard library)

    python3 gen_raycast.py                  writes raycast.asm next to this script
    python3 gen_raycast.py --preview p.png  also draws the first view with the
                                            Python model (no CPU)
    python3 test_raycast_sim.py             runs it in placard_sim and checks
                                            every view against the model

SCREEN
    rows   0-31   1 bpp, 1x   four lines of 80 column text: title, frame
                              rate, controls, demo / player mode
    rows  32-479  8 bpp, 4x   the 3D view: 80 x 112 cells of 8 x 4 pixels,
                              256 colors (RGB 3-3-2)
    The 1x text rows use video offsets x020-x03F of each byte column and the
    4x view rows x180-x1FF (VIDEO.md, line repeat), so they never share a
    byte.  There is no page flip, so a view is drawn over the last one,
    column by column, while it is on the screen.

WHY IT IS FAST ON THIS MACHINE
    Video memory is column-major: the 112 cells of one view column are 112
    bytes of one 512-byte page pair (Y = x61 + 2 * column, X = the row's
    offset), so a wall slice is a run of stores with the X offsets as
    immediates.  The program has three unrolled store runs in ROM, one for
    the ceiling, one for the floor and one for the wall, and enters each at
    the right place for the wall height h (0-56 cells above and below the
    middle).  Every cell costs 6 clocks (ld n, x / ld c, [y,x]), so a whole
    column is 672 clocks, whatever the wall height.  The ceiling and floor
    colors are immediates in the code (fixed gradients); the wall color is
    in AC.

THE RAY CASTER (one ray per column, DDA on a 16 x 16 map)
    Player position 8.8 fixed point (high byte = map cell), angle 0-255
    (1.4 degrees a step).  Ray angles are 0-1023: ray c has angle
    4 * angle + COLANG[c], COLANG = atan(0.66 * camera x) (66 degree field
    of view).  For each ray:
      - DDX, DDY = |1 / cos|, |1 / sin| of the ray angle, 8.8, from 1 KB
        tables (clamped to x3FFF); the steps (+-1 cell) from the quadrant
      - the first crossing distances side = f * dd / 256, f = the distance
        to the next cell edge in 1/256 cell (255 - frac or frac), with two
        8 x 8 quarter-square multiplies (a * b = Q(a + b) - Q(|a - b|),
        Q(n) = n * n / 4, 2 KB of tables)
      - DDA: step along x when sideX < sideY, else along y, adding dd with
        the carry flag, until the map cell is a wall
      - distance = side - dd of the axis that hit (the distance along the
        ray), half height hr = 60.6 / distance from a 6 KB table
        (distance high byte 0-23 picks the page, low byte the entry), then
        the fish-eye correction h = hr + hr * KC[c] / 256 (KC = 1 / cos of
        the column's angle offset, minus 1), at most 56
      - wall color COLTAB[type * 32 + side * 16 + parity * 8 + h / 8]: a
        color for each wall type, darker for y sides, every other map cell
        a little darker (so blocks show), and darker with distance
    About 2,000 clocks a column with the drawing, so a whole view takes
    about 1.7 frames: around 30 views a second (the HUD shows the rate).

CONTROLS
    Arrow keys or SNES pad 1: Up / Down walk, Left / Right turn.  With no
    input for 10 s the demo walk (a fixed script) takes over again; it
    starts in the demo walk.  Movement is per frame (tick), so the speed
    doesn't depend on the view rate: 1/18 cell a tick, turning 2 steps
    (2.8 degrees) a tick.  Walls are kept 1/4 cell away; each axis is
    tried on its own, so the player slides along walls.

Date: 10/18/2026
"""

import argparse
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps  # noqa: E402

# ---------------------------------------------------------------------------
# layout
# ---------------------------------------------------------------------------
NCOL = 80               # view columns (one byte column each, 8 bpp)
NROW = 112              # view cells down (4x rows 32-479)
HALF = 56               # cells above (and below) the middle
TOP_ROW = 32            # first screen row of the view
MODE_VIEW = 0x0B        # 8 bpp, 4x
FOV_TAN = 0.66
HT_PAGES = 24           # distance high bytes with a height table page
DD_MAX = 0x3FFF
RADIUS = 64             # player keeps this far (1/256 cell) from walls
SPEED = 14              # 1/256 cell a tick
TURN = 2                # angle steps a tick
IDLE_TICKS = 600        # back to the demo walk after this many idle ticks

# table pages (ROM, program area x6000-xDFFF)
DDXL, DDXH, DDYL, DDYH = 0xA000, 0xA400, 0xA800, 0xAC00
HT = 0xB000                       # 24 pages
QL0, QL1, QH0, QH1 = 0xC800, 0xC900, 0xCA00, 0xCB00
MAP = 0xCC00
COLTAB = 0xCD00
PAR = 0xCE00
COLT = 0xCF00                     # CA_LO +0, CA_HI +x50, KC +xA0
E_CE, E_FE, E_WE, E_WP, E_WS = 0xD000, 0xD100, 0xD200, 0xD300, 0xD400
MVX, MVY = 0xD500, 0xD600
MISC = 0xD700                     # FPS digit tables, script, strings
CEIL, FLOOR, WALL = 0xD800, 0xD900, 0xDA00   # store runs (WALL: 2 pages)

MAP_ROWS = [
    "AAAAAAAAAAAAAAAA",
    "A..............A",
    "A.BB.B...CCC...A",
    "A.B..B.....C...A",
    "A.B..BB....C...A",
    "A..........C...A",
    "A...E...E......A",
    "A..............A",
    "A...E...E..DDDDA",
    "A..........D...A",
    "A.FFF......D.G.A",
    "A.F........D...A",
    "A.F...G.G......A",
    "A.......G...GG.A",
    "A..............A",
    "AAAAAAAAAAAAAAAA",
]

# wall colors by type (R, G, B 0-1)
WALL_RGB = {
    1: (0.80, 0.78, 0.72),   # A stone
    2: (0.95, 0.35, 0.20),   # B brick
    3: (0.30, 0.55, 1.00),   # C blue tile
    4: (0.35, 0.90, 0.30),   # D moss
    5: (1.00, 0.80, 0.15),   # E gold
    6: (0.75, 0.35, 0.95),   # F purple
    7: (0.25, 0.95, 0.95),   # G cyan
}

START = dict(pa=0, px=0x0780, py=0x0780)

# demo walk: (ticks, input bits), bit 0 forward, 1 back, 2 turn left, 3 right
SCRIPT = [
    (40, 0), (60, 1), (24, 8), (70, 1), (32, 4), (60, 1), (48, 8), (90, 1),
    (40, 4), (50, 1), (64, 8), (80, 1), (30, 9), (40, 1), (45, 4), (70, 1),
    (90, 8), (40, 0), (60, 1), (36, 5), (60, 1), (20, 4), (100, 1),
]


# ---------------------------------------------------------------------------
# tables
# ---------------------------------------------------------------------------
def rgb332(r, g, b):
    """0-1 floats -> G3 G2 G1 B2 B1 R3 R2 R1 byte (placard_sim.rgb8)"""
    ri = max(0, min(7, int(round(r * 7))))
    gi = max(0, min(7, int(round(g * 7))))
    bi = max(0, min(3, int(round(b * 3))))
    return (gi << 5) | (bi << 3) | ri


def tables():
    t = {}
    colang = []
    kc = []
    for c in range(NCOL):
        camx = (2 * c + 1) / NCOL - 1
        a = int(round(math.atan(camx * FOV_TAN) * 1024 / (2 * math.pi)))
        colang.append(a & 1023)
        off = a * 2 * math.pi / 1024
        kc.append(int(round(256 * (1 / math.cos(off) - 1))))
    t['colang'] = colang
    t['kc'] = kc
    ddx, ddy = [], []
    for a in range(1024):
        th = a * 2 * math.pi / 1024
        for lst, v in ((ddx, math.cos(th)), (ddy, math.sin(th))):
            lst.append(DD_MAX if abs(v) < 1e-9 else min(DD_MAX, int(round(256 / abs(v)))))
    t['ddx'], t['ddy'] = ddx, ddy
    k = 256 * NCOL * 8 / (2 * FOV_TAN) / 4 / 2     # half height in cells * 256 at 1 cell
    t['k'] = k
    t['ht'] = [min(255, int(round(k / max(d, 1)))) for d in range(HT_PAGES * 256)]
    t['q'] = [n * n // 4 for n in range(512)]
    m = []
    for row in MAP_ROWS:
        for ch in row:
            m.append(0 if ch == '.' else (ord(ch) - ord('A') + 1) << 5)
    t['map'] = m
    col = [0x01] * 256
    for typ, (r, g, b) in WALL_RGB.items():
        for side in (0, 1):
            for par in (0, 1):
                for sh in range(8):
                    bri = 0.22 + 0.78 * (sh + 1) / 8
                    if side:
                        bri *= 0.72
                    if par:
                        bri *= 0.86
                    v = rgb332(r * bri, g * bri, b * bri)
                    col[(typ << 5) | (side << 4) | (par << 3) | sh] = v or 0x01
    t['coltab'] = col
    t['par'] = [(((i ^ (i >> 4)) & 1) << 3) for i in range(256)]
    # ceiling and floor: 8 brightness levels each, dithered row by row
    # (error diffusion down the rows) so the bands blend
    def rgbi(r, g, b):
        return (g << 5) | (b << 3) | r
    ceil_l = [rgbi(*c) for c in ((0, 0, 0), (0, 0, 1), (0, 1, 1), (1, 1, 2), (1, 2, 2),
                                 (2, 2, 3), (2, 3, 3), (3, 4, 3))]
    floor_l = [rgbi(*c) for c in ((0, 0, 0), (1, 0, 0), (2, 1, 0), (3, 1, 0), (4, 2, 0),
                                  (5, 3, 0), (6, 3, 0), (7, 4, 1))]

    def ramp(levels, want):
        out, err = [], 0.0
        for w in want:
            v = w + err
            li = max(0, min(7, int(round(v))))
            err = v - li
            out.append(levels[li])
        return out
    t['ceil'] = ramp(ceil_l, [7 * (1 - g / (HALF - 1)) ** 1.3 for g in range(HALF)])
    t['floor'] = ramp(floor_l, [7 * (k / (HALF - 1)) ** 1.1 for k in range(HALF)])
    t['mvx'] = [int(round(SPEED * math.cos(p * 2 * math.pi / 256))) & 0xFF for p in range(256)]
    t['mvy'] = [int(round(SPEED * math.sin(p * 2 * math.pi / 256))) & 0xFF for p in range(256)]
    return t


T = tables()


def row_x(g):
    """X (offset low byte) of view cell row g in a byte column (page x61 + 2c)"""
    r = TOP_ROW + 4 * g
    off = ps.row_offset(r, MODE_VIEW)
    assert off >> 8 == 1
    for k in range(4):
        assert ps.row_offset(r + k, MODE_VIEW) == off
    return off & 0xFF


# ---------------------------------------------------------------------------
# the model (bit for bit what the program does)
# ---------------------------------------------------------------------------
def cast(pa, px, py, c):
    """-> (h, color) of view column c"""
    a = (pa * 4 + T['colang'][c]) & 1023
    q = a >> 8
    ddx, ddy = T['ddx'][a], T['ddy'][a]
    fx, fy = px & 255, py & 255
    fxq = (255 - fx) if q in (0, 3) else fx
    fyq = (255 - fy) if q in (0, 1) else fy
    sx = ((fxq * (ddx & 255)) >> 8) + fxq * (ddx >> 8)
    sy = ((fyq * (ddy & 255)) >> 8) + fyq * (ddy >> 8)
    stx = 1 if q in (0, 3) else -1
    sty = 16 if q in (0, 1) else -16
    mi = ((py >> 8) * 16 + (px >> 8)) & 255
    while True:
        if sx < sy:
            sx += ddx
            mi = (mi + stx) & 255
            side = 0
        else:
            sy += ddy
            mi = (mi + sty) & 255
            side = 1
        assert sx < 65536 and sy < 65536
        v = T['map'][mi]
        if v:
            break
    dist = (sx - ddx) if side == 0 else (sy - ddy)
    hr = T['ht'][dist] if (dist >> 8) < HT_PAGES else 1
    if hr >= HALF:
        h = HALF
    else:
        h = min(HALF, hr + ((hr * T['kc'][c]) >> 8))
    color = T['coltab'][v | (side << 4) | T['par'][mi] | (h >> 3)]
    return h, color


def view_bytes(pa, px, py):
    """{address: byte} of the whole view"""
    out = {}
    for c in range(NCOL):
        h, color = cast(pa, px, py, c)
        page = 0x6100 + c * 512
        for g in range(NROW):
            if g < HALF - h:
                v = T['ceil'][g]
            elif g >= HALF + h:
                v = T['floor'][g - HALF]
            else:
                v = color
            out[page + row_x(g)] = v
    return out


def wall_at(px, py):
    return T['map'][((py >> 8) * 16 + (px >> 8)) & 255] != 0


def sx8(v):
    return v - 256 if v & 0x80 else v


def tick(st, bits):
    """one frame of movement: st = dict(pa, px, py) changed in place;
    -> True if a move was blocked"""
    if bits & 4:
        st['pa'] = (st['pa'] - TURN) & 255
    if bits & 8:
        st['pa'] = (st['pa'] + TURN) & 255
    if not bits & 3:
        return False
    p = st['pa'] if bits & 1 else st['pa'] ^ 0x80
    dx, dy = sx8(T['mvx'][p]), sx8(T['mvy'][p])
    if dx:
        nx = (st['px'] + dx) & 0xFFFF
        probe = (nx + (RADIUS if dx > 0 else -RADIUS)) & 0xFFFF
        if not wall_at(probe, st['py']):
            st['px'] = nx
    if dy:
        ny = (st['py'] + dy) & 0xFFFF
        probe = (ny + (RADIUS if dy > 0 else -RADIUS)) & 0xFFFF
        if not wall_at(st['px'], probe):
            st['py'] = ny
    return False


class Script:
    """the demo walk, one step per tick"""

    def __init__(self):
        self.i = 0
        self.n = SCRIPT[0][0]

    def bits(self):
        b = SCRIPT[self.i][1]
        self.n -= 1
        if self.n == 0:
            self.i = (self.i + 1) % len(SCRIPT)
            self.n = SCRIPT[self.i][0]
        return b


def preview(path, st):
    from PIL import Image
    img = Image.new('RGB', (640, 480))
    px_ = img.load()
    for c in range(NCOL):
        h, color = cast(st['pa'], st['px'], st['py'], c)
        for g in range(NROW):
            if g < HALF - h:
                v = T['ceil'][g]
            elif g >= HALF + h:
                v = T['floor'][g - HALF]
            else:
                v = color
            rgb = ps.rgb8(v)
            for yy in range(4):
                for xx in range(8):
                    px_[c * 8 + xx, TOP_ROW + g * 4 + yy] = rgb
    img.save(path)


# ---------------------------------------------------------------------------
# assembly writer: keeps every group of lines inside one 256-byte page (the
# branches only change PC low), hopping to the next page when a group would
# not fit
# ---------------------------------------------------------------------------
class Asm:
    def __init__(self):
        self.out = []
        self.addr = 0
        self.hops = 0

    def raw(self, s=''):
        self.out.append(s)

    def org(self, a, comment=None):
        self.raw('')
        if comment:
            self.raw('; ' + comment)
        self.raw('#addr 0x%04X' % a)
        self.addr = a

    @staticmethod
    def size(lines):
        n = 0
        for ln in lines:
            _, text = ps.parse_line(ln)
            if text and not text.startswith('#') and not ps.CONST_RE.match(text):
                n += ps.instr_size(text)
        return n

    def g(self, lines, y_live=False):
        """place lines (one string with newlines, or a list) as one group"""
        if isinstance(lines, str):
            lines = [ln for ln in lines.split('\n')]
        lines = [ln for ln in lines if ln.strip() != '']
        n = self.size(lines)
        if n > 252:
            raise ValueError('group of %d bytes: %s' % (n, lines[0]))
        room = 256 - (self.addr & 0xFF)
        if n + 4 > room:
            if y_live or room < 4 or room <= 3 + 1:
                if room > 6 and not y_live:
                    pass
                for _ in range(room):
                    self.raw('    nop                         ; (to the next page)')
                self.addr += room
            else:
                self.hops += 1
                lb = 'hop_%d' % self.hops
                self.raw('    ld   %s >> 8, y' % lb)
                self.raw('    jmp  %s                  ; (to the next page)' % lb)
                self.addr = (self.addr & 0xFF00) + 0x100
                self.raw('#addr 0x%04X' % self.addr)
                self.raw('%s:' % lb)
        for ln in lines:
            s = ln.rstrip()
            if s.startswith(('    ', ';')) or s.endswith(':') or ':' in s.split(';')[0]:
                self.raw(s)
            else:
                self.raw('    ' + s.strip())
        self.addr += n

    def call(self, target, ret, comment=''):
        self.g('''
    ld   LINK_LO, x             ; CALL %s %s
    ld   %s, [x]
    ld   LINK_HI, x
    ld   %s >> 8, [x]
    ld   %s >> 8, y
    jmp  %s
%s:''' % (target, comment, ret, ret, target, target, ret))

    def jump(self, target):
        self.g('''
    ld   %s >> 8, y
    jmp  %s''' % (target, target))


def data_page(a, addr, values, comment):
    a.raw('')
    a.raw('#addr 0x%04X                     ; %s' % (addr, comment))
    for i in range(0, len(values), 16):
        a.raw('    #d8 ' + ', '.join('0x%02X' % (v & 0xFF) for v in values[i:i + 16]))


def mul(a, p, ma, mb, comment=''):
    """inline 8 x 8 multiply: mRH:mRL = [ma] * [mb] (quarter squares).
    One group; labels get the prefix p."""
    a.g('''
    ld   [{ma}], ac             ; {c}{ma} * {mb}: d = |a - b|
    sub  [{mb}], ac
    bcc  {p}_dp
    xor  255, ac
    add  1, ac
{p}_dp:
    ld   ac, x
    ld   QL0 >> 8, y            ; Q(d)
    ld   [y,x], ac
    ld   ac, [mDL]
    ld   QH0 >> 8, y
    ld   [y,x], ac
    ld   ac, [mDH]
    ld   [{ma}], ac             ; s = a + b, 9 bits (carry)
    add  [{mb}], ac
    ld   ac, x
    bcs  {p}_big
    ld   QL0 >> 8, y            ; Q(s) - Q(d)
    ld   [y,x], ac
    sub  [mDL], ac
    ld   ac, [mRL]
    ld   QH0 >> 8, y
    ld   [y,x], ac
    bcc  {p}_n0
    sub  1, ac
{p}_n0:
    sub  [mDH], ac
    ld   ac, [mRH]
    bra  {p}_end
{p}_big:
    ld   QL1 >> 8, y
    ld   [y,x], ac
    sub  [mDL], ac
    ld   ac, [mRL]
    ld   QH1 >> 8, y
    ld   [y,x], ac
    bcc  {p}_n1
    sub  1, ac
{p}_n1:
    sub  [mDH], ac
    ld   ac, [mRH]
{p}_end:'''.format(ma=ma, mb=mb, p=p, c=comment))


ZP = '''
; ---------------------------------------------------------------------------
; program variables (zero page x20-x8F)
; ---------------------------------------------------------------------------
pa         = 0x20       ; player angle 0-255
pxl        = 0x21       ; player x, 8.8 (pxh = map column)
pxh        = 0x22
pyl        = 0x23       ; player y, 8.8 (pyh = map row)
pyh        = 0x24
palo       = 0x25       ; 4 * pa, 10 bits
pahi       = 0x26
mi0        = 0x27       ; player's map cell (row * 16 + column)
col        = 0x28       ; view column 0-79
alo        = 0x29       ; ray angle 0-1023
ahi        = 0x2A
ddxl       = 0x2B       ; |1 / cos|, 8.8
ddxh       = 0x2C
ddyl       = 0x2D       ; |1 / sin|
ddyh       = 0x2E
sxl        = 0x2F       ; distance to the next x crossing
sxh        = 0x30
syl        = 0x31       ; distance to the next y crossing
syh        = 0x32
mi         = 0x33       ; map cell the ray is in
wv         = 0x34       ; map value of the wall hit, + x10 on a y side
dsl        = 0x35       ; distance along the ray to the wall
dsh        = 0x36
hr         = 0x37       ; half height before the fish-eye correction
hh         = 0x38       ; half height 0-56
tmp        = 0x39
mA         = 0x3A       ; multiply: mRH:mRL = mA * mB
mB         = 0x3B
mDL        = 0x3C
mDH        = 0x3D
mRL        = 0x3E
mRH        = 0x3F
colpage    = 0x40       ; video page of this column (x61 + 2 * col)
wcol       = 0x41       ; wall color (never 0)
e_ceil     = 0x42       ; store run entry points (low bytes)
e_floor    = 0x43
e_wall     = 0x44
w_pg       = 0x45       ;   wall run page of e_wall
w_stub     = 0x46       ;   and the low byte of that page's stub
last_frame = 0x47       ; FRAME_LO when the last view started
nticks     = 0x48       ; frames since then (ticks to move)
inp        = 0x49       ; input bits: 0 fwd, 1 back, 2 left, 3 right
demo       = 0x4A       ; 1 while the demo walk runs
sc_i       = 0x4B       ; demo walk step (byte offset into SCRIPT)
sc_n       = 0x4C       ;   ticks left in it
idle_lo    = 0x4D       ; ticks with no input
idle_hi    = 0x4E
tbits      = 0x4F       ; this tick's input
mvd        = 0x50       ; move: dx or dy
nlo        = 0x51       ;   new coordinate
nhi        = 0x52
prb        = 0x53       ;   probe cell
mvp        = 0x54       ;   move angle
views_lo   = 0x55       ; views drawn
views_hi   = 0x56
vticks     = 0x57       ; frames from the last view to this one
fxq        = 0x60       ; x60-x63: f for x by quadrant (255 - frac or frac)
fyq        = 0x64       ; x64-x67: f for y by quadrant
'''


def gen():
    a = Asm()
    a.raw('; raycast.asm - generated by gen_raycast.py, do not edit')
    a.raw(';')
    for ln in __doc__.strip().split('\n')[1:]:
        a.raw(('; ' + ln).rstrip())
    a.raw('')
    a.raw('#include "placard.asm"')
    a.raw('#include "placard_lib.asm"')
    a.raw(ZP)
    for name, v in (('DDXL', DDXL), ('DDXH', DDXH), ('DDYL', DDYL), ('DDYH', DDYH),
                    ('HT', HT), ('QL0', QL0), ('QL1', QL1), ('QH0', QH0), ('QH1', QH1),
                    ('MAP', MAP), ('COLTAB', COLTAB), ('PAR', PAR), ('COLT', COLT),
                    ('E_CE', E_CE), ('E_FE', E_FE), ('E_WE', E_WE), ('E_WP', E_WP),
                    ('E_WS', E_WS), ('MVX', MVX), ('MVY', MVY), ('MISC', MISC)):
        a.raw('%-10s = 0x%04X' % (name, v))
    a.raw('RADIUS     = %d' % RADIUS)

    # ------------------------------------------------------------- main
    a.org(0x6000, 'main: set up the screen and the player')
    a.raw('main:')
    a.g('''
    ld   STACK_TOP, ac          ; stack first
    ld   ac, [SP]''')
    a.call('port_init', 'm_1')
    a.call('con_clear', 'm_2', '(every row 1 bpp 1x, cursor 0, 0)')
    a.g('''
    ld   0x5A, y                ; rows 32-479 (x5A40-x5BFF): 8 bpp 4x
    ld   0x40, ac
m_mb1:
    ld   ac, x
    ld   MODE_VIEW, [y,x]
    inc
    bne  m_mb1''')
    a.g('''
    ld   0x5B, y
    clr  ac
m_mb2:
    ld   ac, x
    ld   MODE_VIEW, [y,x]
    inc
    bne  m_mb2''')
    a.raw('MODE_VIEW  = 0x%02X' % MODE_VIEW)
    for i, (lab, row) in enumerate((('s_title', 0), ('s_rate', 1), ('s_keys', 2))):
        a.g('''
    clr  ac
    ld   ac, [CUR_COL]
    ld   %d, ac
    ld   ac, [CUR_ROW]
    ld   %s, ac
    ld   ac, [R0]
    ld   %s >> 8, ac
    ld   ac, [R1]''' % (row, lab, lab))
        a.call('con_puts', 'm_s%d' % i)
    a.g('''
    ld   %d, ac                 ; the player
    ld   ac, [pa]
    ld   %d, ac
    ld   ac, [pxl]
    ld   %d, ac
    ld   ac, [pxh]
    ld   %d, ac
    ld   ac, [pyl]
    ld   %d, ac
    ld   ac, [pyh]
    ld   1, ac                  ; demo walk on, from its first step
    ld   ac, [demo]
    clr  ac
    ld   ac, [sc_i]
    ld   ac, [idle_lo]
    ld   ac, [idle_hi]
    ld   ac, [views_lo]
    ld   ac, [views_hi]
    ld   %d, ac
    ld   ac, [sc_n]''' % (START['pa'], START['px'] & 255, START['px'] >> 8,
                          START['py'] & 255, START['py'] >> 8, SCRIPT[0][0]))
    a.call('frame_poll', 'm_fp')
    a.g('''
    ld   [FRAME_LO], ac
    sub  1, ac                  ; the first view moves one tick
    ld   ac, [last_frame]''')
    a.jump('view_loop')

    # ------------------------------------------------------------- view loop
    a.org(0x6200, 'view_loop: input, movement, then the 80 columns')
    a.raw('view_loop:')
    a.call('frame_poll', 'v_fp')
    a.g('''
    ld   [FRAME_LO], ac         ; ticks = frames since the last view
    sub  [last_frame], ac
    beq  view_loop              ; (never: a view takes longer than a frame)
    ld   ac, [nticks]
    ld   ac, [vticks]
    ld   [FRAME_LO], ac
    ld   ac, [last_frame]''')
    a.call('pad_read', 'v_pad')
    a.call('kbd_scan', 'v_kbd')
    # input bits from pad 1 (R0: 4 up, 5 down, 6 left, 7 right) and the
    # arrow keys (KBD_NOW + 6 bit 5 up; + 7 bit 5 left, 6 down, 7 right, 0 = down)
    a.g('''
    clr  ac
    ld   ac, [inp]
    ld   [R0], ac               ; pad: up
    and  0x10, ac
    beq  v_i1
    ld   1, ac
    ld   ac, [inp]
v_i1:
    ld   [R0], ac               ; down
    and  0x20, ac
    beq  v_i2
    ld   [inp], ac
    or   2, ac
    ld   ac, [inp]
v_i2:
    ld   [R0], ac               ; left
    and  0x40, ac
    beq  v_i3
    ld   [inp], ac
    or   4, ac
    ld   ac, [inp]
v_i3:
    ld   [R0], ac               ; right
    and  0x80, ac
    beq  v_i4
    ld   [inp], ac
    or   8, ac
    ld   ac, [inp]
v_i4:''')
    a.g('''
    ld   [KBD_NOW + 6], ac      ; Up key
    and  0x20, ac
    bne  v_k1
    ld   [inp], ac
    or   1, ac
    ld   ac, [inp]
v_k1:
    ld   [KBD_NOW + 7], ac      ; Left
    and  0x20, ac
    bne  v_k2
    ld   [inp], ac
    or   4, ac
    ld   ac, [inp]
v_k2:
    ld   [KBD_NOW + 7], ac      ; Down
    and  0x40, ac
    bne  v_k3
    ld   [inp], ac
    or   2, ac
    ld   ac, [inp]
v_k3:
    ld   [KBD_NOW + 7], ac      ; Right
    and  0x80, ac
    bne  v_k4
    ld   [inp], ac
    or   8, ac
    ld   ac, [inp]
v_k4:''')
    a.g('''
    ld   [inp], ac              ; any input: the player drives, idle = 0
    beq  v_idle
    clr  ac
    ld   ac, [demo]
    ld   ac, [idle_lo]
    ld   ac, [idle_hi]
    bra  v_mode
v_idle:
    ld   [demo], ac             ; no input: count idle ticks, demo walk
    bne  v_mode                 ;   again after IDLE_TICKS
    ld   [idle_lo], ac
    add  [nticks], ac
    ld   ac, [idle_lo]
    ld   [idle_hi], ac
    bcc  v_id1
    add  1, ac
    ld   ac, [idle_hi]
v_id1:
    sub  IDLE_TICKS >> 8, ac
    bcs  v_mode
    bne  v_id2
    ld   [idle_lo], ac
    sub  IDLE_TICKS & 0xFF, ac
    bcs  v_mode
v_id2:
    ld   1, ac
    ld   ac, [demo]
v_mode:''')
    a.raw('IDLE_TICKS = %d' % IDLE_TICKS)
    a.jump('ticks')

    # ------------------------------------------------------------- ticks
    a.org(0x6400, 'ticks: move the player once per frame since the last view')
    a.raw('ticks:')
    a.g('''
    ld   [inp], ac              ; this tick's input: the player's, or the
    ld   ac, [tbits]            ; demo walk's next step
    ld   [demo], ac
    beq  t_turn
    ld   [sc_i], ac
    add  (SCRIPT & 0xFF) + 1, ac
    ld   ac, x
    ld   SCRIPT >> 8, y
    ld   [y,x], ac
    ld   ac, [tbits]
    ld   [sc_n], ac
    sub  1, ac
    ld   ac, [sc_n]
    bne  t_turn
    ld   [sc_i], ac             ; next step (2 bytes each, 00 ends the list)
    add  2, ac
    ld   ac, [sc_i]
    add  SCRIPT & 0xFF, ac
    ld   ac, x
    ld   [y,x], ac
    bne  t_sc1
    clr  ac
    ld   ac, [sc_i]
    ld   SCRIPT & 0xFF, x
    ld   [y,x], ac
t_sc1:
    ld   ac, [sc_n]
t_turn:
    ld   [tbits], ac            ; turn
    and  4, ac
    beq  t_t1
    ld   [pa], ac
    sub  TURN, ac
    ld   ac, [pa]
t_t1:
    ld   [tbits], ac
    and  8, ac
    beq  t_t2
    ld   [pa], ac
    add  TURN, ac
    ld   ac, [pa]
t_t2:
    ld   [tbits], ac            ; walk: forward at pa, back at pa + 128
    and  3, ac
    bne  t_walk
    ld   t_next >> 8, y
    jmp  t_next
t_walk:
    and  1, ac
    beq  t_back
    clr  ac
    bra  t_fw
t_back:
    ld   0x80, ac
t_fw:
    xor  [pa], ac
    ld   ac, [mvp]''')
    a.raw('TURN       = %d' % TURN)
    # x move
    for ax, (lo, hi, tbl, lbl) in enumerate((('pxl', 'pxh', 'MVX', 'tx'), ('pyl', 'pyh', 'MVY', 'ty'))):
        probe = ('''
    ld   [pyh], ac              ; probe cell = row * 16 + column
    shl
    shl
    shl
    shl
    or   [prb], ac''' if ax == 0 else '''
    ld   [prb], ac              ; probe cell = row * 16 + column
    shl
    shl
    shl
    shl
    or   [pxh], ac''')
        a.g('''
    ld   [mvp], x               ; d{ax}
    ld   {tbl} >> 8, y
    ld   [y,x], ac
    beq  {l}_done
    ld   ac, [mvd]
    blt  {l}_neg
    add  [{lo}], ac             ; new = pos + d (d > 0)
    ld   ac, [nlo]
    ld   [{hi}], ac
    bcc  {l}_p1
    add  1, ac
{l}_p1:
    ld   ac, [nhi]
    ld   [nlo], ac              ; probe = new + RADIUS
    add  RADIUS, ac
    ld   [nhi], ac
    bcc  {l}_p2
    add  1, ac
{l}_p2:
    ld   ac, [prb]
    bra  {l}_chk
{l}_neg:
    add  [{lo}], ac             ; new = pos + d (d < 0: the high byte - 1 + carry)
    ld   ac, [nlo]
    ld   [{hi}], ac
    bcs  {l}_n1
    sub  1, ac
{l}_n1:
    ld   ac, [nhi]
    ld   [nlo], ac              ; probe = new - RADIUS
    sub  RADIUS, ac
    ld   [nhi], ac
    bcc  {l}_n2
    sub  1, ac
{l}_n2:
    ld   ac, [prb]
{l}_chk:'''.format(ax='xy'[ax], tbl=tbl, l=lbl, lo=lo, hi=hi) + probe + '''
    ld   ac, x
    ld   MAP >> 8, y
    ld   [y,x], ac
    bne  {l}_done               ; a wall: stay
    ld   [nlo], ac
    ld   ac, [{lo}]
    ld   [nhi], ac
    ld   ac, [{hi}]
{l}_done:'''.format(l=lbl, lo=lo, hi=hi))
    a.g('''
t_next:
    ld   [nticks], ac
    sub  1, ac
    ld   ac, [nticks]
    beq  t_end
    ld   ticks >> 8, y
    jmp  ticks
t_end:''')
    # per view setup
    a.g('''
    ld   [pa], ac               ; palo:pahi = 4 * pa
    shl
    shl
    ld   ac, [palo]
    ld   [pa], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [pahi]
    ld   [pxl], ac              ; f for x: quadrants 0 and 3 step +1
    ld   ac, [fxq + 1]
    ld   ac, [fxq + 2]
    xor  255, ac
    ld   ac, [fxq + 0]
    ld   ac, [fxq + 3]
    ld   [pyl], ac              ; f for y: quadrants 0 and 1 step +16
    ld   ac, [fyq + 2]
    ld   ac, [fyq + 3]
    xor  255, ac
    ld   ac, [fyq + 0]
    ld   ac, [fyq + 1]
    ld   [pyh], ac              ; player's cell
    shl
    shl
    shl
    shl
    or   [pxh], ac
    ld   ac, [mi0]
    clr  ac
    ld   ac, [col]''')
    a.jump('col_top')

    # ------------------------------------------------------------- column
    a.org(0x6600, 'col_top: one ray (common part: angle, steps, first crossings)')
    a.raw('col_top:')
    a.g('''
    ld   [col], x               ; ray angle = 4 * pa + COLANG[col]
    ld   COLT >> 8, y
    ld   [y,x], ac
    ld   ac, [tmp]
    ld   [col], ac
    add  0x50, ac               ; COLANG high bytes at COLT + x50
    ld   ac, x
    ld   [y,x], ac
    ld   ac, [ahi]
    ld   [tmp], ac
    add  [palo], ac
    ld   ac, [alo]
    ld   [ahi], ac
    bcc  c_a1
    add  1, ac
c_a1:
    add  [pahi], ac
    and  3, ac
    ld   ac, [ahi]''')
    a.g('''
    ld   [alo], x               ; the four |1 / cos|, |1 / sin| bytes
    ld   [ahi], ac
    add  DDXL >> 8, y
    ld   [y,x], ac
    ld   ac, [ddxl]
    ld   [ahi], ac
    add  DDXH >> 8, y
    ld   [y,x], ac
    ld   ac, [ddxh]
    ld   [ahi], ac
    add  DDYL >> 8, y
    ld   [y,x], ac
    ld   ac, [ddyl]
    ld   [ahi], ac
    add  DDYH >> 8, y
    ld   [y,x], ac
    ld   ac, [ddyh]
    ld   [ahi], ac              ; mA = f for x in this quadrant
    add  fxq, x
    ld   [x], ac
    ld   ac, [mA]
    ld   [ddxl], ac
    ld   ac, [mB]''')
    mul(a, 'mx1', 'mA', 'mB', 'sideX = hi(f * ddxl) + f * ddxh: ')
    a.g('''
    ld   [mRH], ac
    ld   ac, [tmp]
    ld   [ddxh], ac
    ld   ac, [mB]''')
    mul(a, 'mx2', 'mA', 'mB')
    a.g('''
    ld   [mRL], ac
    add  [tmp], ac
    ld   ac, [sxl]
    ld   [mRH], ac
    bcc  c_x1
    add  1, ac
c_x1:
    ld   ac, [sxh]
    ld   [ahi], ac              ; mA = f for y
    add  fyq, x
    ld   [x], ac
    ld   ac, [mA]
    ld   [ddyl], ac
    ld   ac, [mB]''')
    mul(a, 'my1', 'mA', 'mB', 'sideY: ')
    a.g('''
    ld   [mRH], ac
    ld   ac, [tmp]
    ld   [ddyh], ac
    ld   ac, [mB]''')
    mul(a, 'my2', 'mA', 'mB')
    a.g('''
    ld   [mRL], ac
    add  [tmp], ac
    ld   ac, [syl]
    ld   [mRH], ac
    bcc  c_y1
    add  1, ac
c_y1:
    ld   ac, [syh]
    ld   [mi0], ac
    ld   ac, [mi]
    ld   [ahi], ac              ; DDA for this quadrant: page DDA0 + quadrant
    add  dda0 >> 8, y
    jmp  dda0''')

    # ------------------------------------------------------------- DDA x4
    for q in range(4):
        stx = 1 if q in (0, 3) else 255
        sty = 16 if q in (0, 1) else 240
        a.org(0x6C00 + q * 0x100, 'DDA, quadrant %d: x step %+d, y step %+d'
              % (q, 1 if stx == 1 else -1, 16 if sty == 16 else -16))
        if q == 0:
            a.raw('dda0:')
        a.g('''
d{q}_lp:
    ld   [sxh], ac              ; sideX < sideY ?
    sub  [syh], ac
    bne  d{q}_ne
    ld   [sxl], ac
    sub  [syl], ac
d{q}_ne:
    bcs  d{q}_x
    ld   [syl], ac              ; step y: sideY += ddy
    add  [ddyl], ac
    ld   ac, [syl]
    ld   [syh], ac
    bcc  d{q}_y1
    add  1, ac
d{q}_y1:
    add  [ddyh], ac
    ld   ac, [syh]
    ld   [mi], ac
    add  {sty}, ac
    ld   ac, [mi]
    ld   ac, x
    ld   MAP >> 8, y
    ld   [y,x], ac
    beq  d{q}_lp
    or   0x10, ac               ; a y side
    ld   ac, [wv]
    ld   [syl], ac              ; distance = sideY - ddy
    sub  [ddyl], ac
    ld   ac, [dsl]
    ld   [syh], ac
    bcc  d{q}_y2
    sub  1, ac
d{q}_y2:
    sub  [ddyh], ac
    ld   ac, [dsh]
    ld   hit >> 8, y
    jmp  hit
d{q}_x:
    ld   [sxl], ac              ; step x: sideX += ddx
    add  [ddxl], ac
    ld   ac, [sxl]
    ld   [sxh], ac
    bcc  d{q}_x1
    add  1, ac
d{q}_x1:
    add  [ddxh], ac
    ld   ac, [sxh]
    ld   [mi], ac
    add  {stx}, ac
    ld   ac, [mi]
    ld   ac, x
    ld   MAP >> 8, y
    ld   [y,x], ac
    beq  d{q}_lp
    ld   ac, [wv]
    ld   [sxl], ac              ; distance = sideX - ddx
    sub  [ddxl], ac
    ld   ac, [dsl]
    ld   [sxh], ac
    bcc  d{q}_x2
    sub  1, ac
d{q}_x2:
    sub  [ddxh], ac
    ld   ac, [dsh]
    ld   hit >> 8, y
    jmp  hit'''.format(q=q, stx=stx, sty=sty))

    # ------------------------------------------------------------- hit
    a.org(0x7000, 'hit: wall height, color and the store run entry points')
    a.raw('hit:')
    a.g('''
    ld   [dsh], ac              ; hr = HT[distance] (1 when 24 cells or more)
    sub  HT_PAGES, ac
    bcc  h_far
    ld   [dsh], ac
    add  HT >> 8, y
    ld   [dsl], x
    ld   [y,x], ac
    bra  h_got
h_far:
    ld   1, ac
h_got:
    ld   ac, [hr]
    sub  HALF, ac
    bcs  h_mul
    ld   HALF, ac
    ld   ac, [hh]
    ld   h_col >> 8, y
    jmp  h_col
h_mul:
    ld   [hr], ac               ; fish-eye: h = hr + hr * KC[col] / 256
    ld   ac, [mA]
    ld   [col], ac
    add  0xA0, ac
    ld   ac, x
    ld   COLT >> 8, y
    ld   [y,x], ac
    ld   ac, [mB]''')
    a.raw('HT_PAGES   = %d' % HT_PAGES)
    a.raw('HALF       = %d' % HALF)
    mul(a, 'mh', 'mA', 'mB')
    a.g('''
    ld   [mRH], ac
    add  [hr], ac
    ld   ac, [hh]
    sub  HALF + 1, ac
    bcs  h_col
    ld   HALF, ac
    ld   ac, [hh]
h_col:
    ld   [hh], ac               ; color = COLTAB[wv | PAR[mi] | h / 8]
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [tmp]
    ld   [mi], x
    ld   PAR >> 8, y
    ld   [y,x], ac
    or   [tmp], ac
    or   [wv], ac
    ld   ac, x
    ld   COLTAB >> 8, y
    ld   [y,x], ac
    ld   ac, [wcol]
    ld   [hh], x                ; store run entry points for h
    ld   E_CE >> 8, y
    ld   [y,x], ac
    ld   ac, [e_ceil]
    ld   E_FE >> 8, y
    ld   [y,x], ac
    ld   ac, [e_floor]
    ld   E_WE >> 8, y
    ld   [y,x], ac
    ld   ac, [e_wall]
    ld   E_WP >> 8, y
    ld   [y,x], ac
    ld   ac, [w_pg]
    ld   E_WS >> 8, y
    ld   [y,x], ac
    ld   ac, [w_stub]
    ld   [col], ac              ; video page x61 + 2 * col
    shl
    add  0x61, ac
    ld   ac, [colpage]
    ld   ceil_stub >> 8, y
    jmp  ceil_stub''')
    a.g('''
col_next:
    ld   [col], ac              ; next column
    add  1, ac
    ld   ac, [col]
    sub  NCOL, ac
    bne  c_more
    ld   view_done >> 8, y
    jmp  view_done
c_more:''')
    a.raw('NCOL       = %d' % NCOL)
    a.call('frame_poll', 'c_fp', '(keeps the frame count during the view)')
    a.jump('col_top')

    # ------------------------------------------------------------- view done
    a.org(0x7200, 'view_done: frame rate on the text rows')
    a.raw('view_done:')
    a.g('''
    ld   [views_lo], ac         ; views drawn
    add  1, ac
    ld   ac, [views_lo]
    bcc  vd_1
    ld   [views_hi], ac
    add  1, ac
    ld   ac, [views_hi]
vd_1:
    ld   RATE_COL, ac           ; "nn" views a second, from the frames since
    ld   ac, [CUR_COL]          ; the last view
    ld   1, ac
    ld   ac, [CUR_ROW]
    ld   [vticks], ac
    and  63, ac
    ld   ac, [tmp]
    ld   ac, x
    ld   FPS_T >> 8, y
    ld   [y,x], ac''')
    a.call('con_putc', 'vd_2')
    a.g('''
    ld   [tmp], ac
    add  FPS_O & 0xFF, ac
    ld   ac, x
    ld   FPS_O >> 8, y
    ld   [y,x], ac''')
    a.call('con_putc', 'vd_3')
    a.g('''
    ld   MODE_COL, ac           ; "DEMO WALK" or "YOU DRIVE"
    ld   ac, [CUR_COL]
    ld   1, ac
    ld   ac, [CUR_ROW]
    ld   s_demo, ac
    ld   ac, [R0]
    ld   [demo], ac
    bne  vd_4
    ld   s_you, ac
    ld   ac, [R0]
vd_4:
    ld   s_demo >> 8, ac
    ld   ac, [R1]''')
    a.call('con_puts', 'vd_5')
    a.jump('view_loop')

    # ------------------------------------------------------------- data
    t = T
    data_page(a, DDXL, [v & 255 for v in t['ddx']], 'DDXL: |1 / cos| low bytes (1024)')
    data_page(a, DDXH, [v >> 8 for v in t['ddx']], 'DDXH: high bytes')
    data_page(a, DDYL, [v & 255 for v in t['ddy']], 'DDYL: |1 / sin| low bytes')
    data_page(a, DDYH, [v >> 8 for v in t['ddy']], 'DDYH: high bytes')
    data_page(a, HT, t['ht'], 'HT: half height for distance (page = high byte)')
    data_page(a, QL0, [v & 255 for v in t['q']], 'QL0, QL1: n * n / 4 low bytes, n = 0-511')
    data_page(a, QH0, [v >> 8 for v in t['q']], 'QH0, QH1: high bytes')
    data_page(a, MAP, t['map'], 'MAP: 16 x 16, row * 16 + column, wall type * 32')
    data_page(a, COLTAB, t['coltab'], 'COLTAB: wall color by type, side, parity, shade')
    data_page(a, PAR, t['par'], 'PAR: 8 on every other map cell')
    data_page(a, COLT, [v & 255 for v in t['colang']] + [v >> 8 for v in t['colang']] + t['kc'],
              'COLANG low (+0), high (+x50), KC (+xA0) by column')
    ent_ce, ent_fe, ent_we, ent_wp, ent_ws = [], [], [], [], []
    ceil_e0 = CEIL + 6
    floor_e0 = FLOOR + 6
    wall_e0 = WALL + 6
    wall_end = wall_e0 + 6 * HALF
    wall_stub_b = wall_end + 4
    for h in range(HALF + 1):
        ent_ce.append((ceil_e0 + 4 * h) & 255)
        ent_fe.append((floor_e0 + 4 * h) & 255)
        e = wall_e0 + 6 * (HALF - h)
        ent_we.append(e & 255)
        ent_wp.append(e >> 8)
        ent_ws.append(WALL & 255 if e >> 8 == WALL >> 8 else wall_stub_b & 255)
        assert (e >> 8) in (WALL >> 8, wall_stub_b >> 8)
    data_page(a, E_CE, ent_ce, 'E_CE: ceiling run entry (low byte) for h')
    data_page(a, E_FE, ent_fe, 'E_FE: floor run entry for h')
    data_page(a, E_WE, ent_we, 'E_WE: wall run entry for h')
    data_page(a, E_WP, ent_wp, 'E_WP: its page')
    data_page(a, E_WS, ent_ws, 'E_WS: the low byte of that page\'s stub')
    data_page(a, MVX, t['mvx'], 'MVX: x step a tick at angle p (signed)')
    data_page(a, MVY, t['mvy'], 'MVY: y step')
    # MISC page: FPS_T (tens digit), FPS_O (ones digit) for 0-63 frames, the
    # demo walk script, strings
    a.raw('')
    a.raw('#addr 0x%04X                     ; FPS_T / FPS_O: 60 / frames as two digits' % MISC)
    a.raw('FPS_T      = 0x%04X' % MISC)
    a.raw('FPS_O      = 0x%04X' % (MISC + 64))
    tens, ones = [], []
    for n in range(64):
        f = 60 // n if n else 99
        tens.append(0x20 if f < 10 else 0x30 + f // 10)
        ones.append(0x30 + f % 10)
    for i in range(0, 64, 16):
        a.raw('    #d8 ' + ', '.join('0x%02X' % v for v in tens[i:i + 16]))
    for i in range(0, 64, 16):
        a.raw('    #d8 ' + ', '.join('0x%02X' % v for v in ones[i:i + 16]))
    a.raw('SCRIPT     = 0x%04X' % (MISC + 128))
    sc = []
    for n, b in SCRIPT:
        sc += [n, b]
    sc.append(0)
    assert len(sc) <= 64
    a.raw('    #d8 ' + ', '.join('0x%02X' % v for v in sc))
    a.raw('RATE_COL   = 0')
    a.raw('MODE_COL   = 67')

    # strings that don't fit the MISC page go after the code
    a.org(0x7400, 'text')
    a.raw('s_title: #d "PLACARD RAY CASTER                        ALL SOFTWARE: NO SPRITE OR 3D HARDWARE", 0x00')
    a.raw('s_rate:  #d "   VIEWS A SECOND    80 X 112 CELLS, 8 BPP, ONE RAY A COLUMN", 0x00')
    a.raw('s_demo:  #d "DEMO WALK   ", 0x00')
    a.raw('s_you:   #d "YOU DRIVE   ", 0x00')
    a.raw('s_keys:  #d "ARROW KEYS OR SNES PAD 1: UP/DOWN WALK, LEFT/RIGHT TURN.  10 S IDLE: DEMO WALK", 0x00')

    # ------------------------------------------------------------- store runs
    a.org(CEIL, 'ceiling run: enter at ceil_e0 + 4h, rows g = 55-h .. 0')
    a.raw('ceil_stub:')
    a.raw('    ld   [colpage], y')
    a.raw('    ld   [wcol], ac')
    a.raw('    bne  [e_ceil]')
    a.raw('ceil_e0:')
    for k in range(HALF):
        g = HALF - 1 - k
        a.raw('    ld   0x%02X, x\n    ld   0x%02X, [y,x]' % (row_x(g), T['ceil'][g]))
    a.raw('    ld   floor_stub >> 8, y')
    a.raw('    jmp  floor_stub')
    a.org(FLOOR, 'floor run: enter at floor_e0 + 4h, rows g = 56+h .. 111')
    a.raw('floor_stub:')
    a.raw('    ld   [colpage], y')
    a.raw('    ld   [wcol], ac')
    a.raw('    bne  [e_floor]')
    a.raw('floor_e0:')
    for k in range(HALF):
        g = HALF + k
        a.raw('    ld   0x%02X, x\n    ld   0x%02X, [y,x]' % (row_x(g), T['floor'][k]))
    a.raw('    ld   [w_pg], y')
    a.raw('    jmp  [w_stub]')
    a.org(WALL, 'wall run (2 pages): enter at wall_e0 + 6 * (56 - h), rows 56-h .. 55+h, color AC')
    a.raw('wall_stub_a:')
    a.raw('    ld   [colpage], y')
    a.raw('    ld   [wcol], ac')
    a.raw('    bne  [e_wall]')
    a.raw('wall_e0:')
    for p in range(HALF - 1, -1, -1):
        a.raw('    ld   0x%02X, x\n    ld   ac, [y,x]\n    ld   0x%02X, x\n    ld   ac, [y,x]'
              % (row_x(HALF - 1 - p), row_x(HALF + p)))
    a.raw('    ld   col_next >> 8, y')
    a.raw('    jmp  col_next')
    a.raw('wall_stub_b:')
    a.raw('    ld   [colpage], y')
    a.raw('    ld   [wcol], ac')
    a.raw('    bne  [e_wall]')
    return '\n'.join(a.out) + '\n', dict(ceil_e0=ceil_e0, floor_e0=floor_e0, wall_e0=wall_e0,
                                       wall_stub_b=wall_stub_b)


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('-o', default=os.path.join(HERE, 'raycast.asm'))
    ap.add_argument('--preview')
    args = ap.parse_args(argv)
    src, addrs = gen()
    open(args.o, 'w', newline='\n').write(src)
    mem, syms, _ = ps.assemble(src, HERE)
    for k, v in addrs.items():
        assert syms[k] == v, (k, hex(syms[k]), hex(v))
    print('wrote %s: %d bytes' % (args.o, len(mem)))
    if args.preview:
        preview(args.preview, dict(START))
        print('wrote', args.preview)


if __name__ == '__main__':
    main(sys.argv[1:])

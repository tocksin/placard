#!/usr/bin/env python3
"""
gen_raycast_tex.py - generate raycast_tex.asm, the textured version of the
ray casting demo (raycast.asm stays as it is).  A ROM program that uses the
standard library.

    python3 gen_raycast_tex.py                  writes raycast_tex.asm next to
                                                this script
    python3 gen_raycast_tex.py --preview p.png  also draws the first view with
                                                the Python model (no CPU)
    python3 gen_raycast_tex.py --textures t.png the seven textures, enlarged
    python3 test_raycast_tex_sim.py             runs it in placard_sim and
                                                checks every view against the
                                                model

SCREEN
    The same as raycast.asm: rows 0-31 are four lines of 1 bpp text, rows
    32-479 the 3D view, 80 x 112 cells of 8 x 4 pixels at 8 bpp (RGB 3-3-2)
    with 4x line repeat.

TEXTURES
    Seven 32 x 32 textures at 8 bpp, drawn by this script (no outside art):
    A stone blocks, B red brick, C wood planks, D riveted blue metal, E mossy
    stone, F a circuit board with a 22V10 on it, G a framed Mandelbrot
    picture.  The ROM holds texel (u, t) of texture k at x2000 + t * 256 +
    k * 32 + u (page = texel row t), so one X value (k * 32 + u) reaches a
    whole texture column by changing only Y.
    Each wall is shaded twice: y sides darker than x sides (as in
    Wolfenstein 3D), and darker with distance (4 levels).  The shading is
    a 256-byte table per level and side (8 pages).

ONE COLUMN
    1. The ray: the same DDA as raycast.asm (angle, |1 / cos|, |1 / sin|,
       first crossings with quarter-square multiplies, step to a wall).
    2. Height h = HT[distance] with the fish-eye correction, 1-255 (more
       than 56 means the wall is taller than the view and is clipped).
    3. Where the ray hit the wall: frac = the low byte of y + dist * sin
       (x sides) or x + dist * cos (y sides), two 8 x 8 multiplies;
       u = frac / 8, mirrored on the faces seen from the other side, so no
       texture is ever back to front.
    4. The texture column: 32 texels through the shading table into zero
       page x68-x87 (unrolled, 20 clocks a texel).
    5. The ceiling and floor runs (as in raycast.asm), then a compiled
       scaler: one unrolled routine per wall height that stores the right
       zero page texel into each of the wall's cells (6 clocks a cell, 3
       more when the texel changes).  Heights 1-SC_EXACT have their own
       scaler, taller walls up to 56 share one scaler between two heights,
       and clipped walls (h > 56) use a few levels; the ceiling and floor
       use the same height, so there is never a gap.

MEMORY
    The program uses the ROM x2000-x3FFF (textures) and x6000-xBFFF, so it
    does not fit in the menu ROM beside the text demo.  The tables raycast.asm
    builds in the RAM at x2000-x41FF move to RAM section 0 and 2 here
    (HT x0100-x18FF, DD lows x1900-x1DFF, DD highs x4200-x46FF), so the
    program runs with the standard map 05 (x2000-x3FFF reads ROM).
    Variables in the zero page x20-x5F, texture column x68-x87.

CONTROLS
    As raycast.asm: arrow keys or SNES pad 1, Up / Down walk, Left / Right
    turn; the demo walk runs at start and after 10 s with no input.

Date: 10/24/2026
"""

import argparse
import math
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps  # noqa: E402
import gen_raycast as rc  # noqa: E402
from gen_raycast import Asm, data_page, mul, rgb332, row_x  # noqa: E402

# ---------------------------------------------------------------------------
# layout
# ---------------------------------------------------------------------------
NCOL, NROW, HALF, TOP_ROW, MODE_VIEW = rc.NCOL, rc.NROW, rc.HALF, rc.TOP_ROW, rc.MODE_VIEW
HT_PAGES, DD_MAX = rc.HT_PAGES, rc.DD_MAX
RADIUS, SPEED, TURN, IDLE_TICKS = rc.RADIUS, rc.SPEED, rc.TURN, rc.IDLE_TICKS
TEXN, TEXW = 7, 32      # textures, 32 x 32 texels

# tables built in the RAM at start (map 05: sections 0 and 2 read RAM)
HT = 0x0100                       # 24 pages, x0100-x18FF
DDYL, DDXL = 0x1900, 0x1A00       # 5 low-byte pages x1900-x1DFF: H G H G H
DDYH, DDXH = 0x4200, 0x4300       # 5 high-byte pages x4200-x46FF
MAP_RUN = 0x05                    # the standard map: sections 0 and 2 RAM

TEXB = 0x2000                     # 32 pages: texel row t at TEXB + t * 256
HTB = 0x6080                      # hit tables, in the page of the entry jump

# data pages (ROM), in order from x6100
DATA = ['QL0', 'QL1', 'QH0', 'QH1', 'MAP', 'COLT', 'MVX', 'MVY', 'E_CE', 'E_FE',
        'SC_LO', 'SC_PG', 'LVL', 'MISC', 'GL', 'GH', 'HCL', 'HCH', 'SNT', 'CST',
        'TEXT', 'CEIL', 'FLOOR']
PAGE = {n: 0x6100 + 0x100 * i for i, n in enumerate(DATA)}
SHADE = 0x6100 + 0x100 * len(DATA)       # 8 pages: light levels 0-3, dark 0-3
CODE = SHADE + 0x800                     # code from here, then the scalers
SC_END = 0xC000

ZT = 0x68                                 # zero page texture column x68-x87

MAP_ROWS = rc.MAP_ROWS                    # A-G = textures 1-7
START = dict(rc.START)
SCRIPT = rc.SCRIPT

SHADE_F = (0.40, 0.60, 0.80, 1.00)        # brightness by distance level
SIDE_F = 0.68                             # y sides


def level(h):
    """distance shading level 0-3 of a wall h cells high (half height)"""
    return 0 if h < 7 else 1 if h < 14 else 2 if h < 28 else 3


# ---------------------------------------------------------------------------
# textures (drawn here; values are R, G, B 0-1)
# ---------------------------------------------------------------------------
def clamp01(v):
    return max(0.0, min(1.0, v))


def mix(a, b, f):
    return tuple(x + (y - x) * f for x, y in zip(a, b))


def scale(c, f):
    return tuple(clamp01(x * f) for x in c)


def tex_stone(rng, base=(0.72, 0.62, 0.48), moss=False):
    img = [[None] * 32 for _ in range(32)]
    shades = {}
    for t in range(32):
        row = t // 8
        off = (row % 2) * 8
        for u in range(32):
            bu = (u + off) % 32
            block = (row, (u + off) // 16 % 2)
            if block not in shades:
                shades[block] = 0.85 + 0.25 * rng.random()
            mortar = t % 8 == 7 or bu % 16 == 15
            if mortar:
                c = (0.28, 0.27, 0.26)
            else:
                c = scale(base, shades[block] * (0.94 + 0.10 * rng.random()))
                if t % 8 == 0 or bu % 16 == 0:
                    c = scale(c, 1.18)          # lit top and left edges
                if t % 8 == 6 or bu % 16 == 14:
                    c = scale(c, 0.78)
            img[t][u] = c
    if moss:
        for _ in range(9):
            cx, cy, r = rng.randrange(32), rng.randrange(32), 2 + rng.random() * 3.5
            for t in range(32):
                for u in range(32):
                    du = min(abs(u - cx), 32 - abs(u - cx))
                    d = math.hypot(du, t - cy)
                    if d < r and rng.random() < 0.85:
                        g = 0.45 + 0.4 * rng.random()
                        img[t][u] = mix(img[t][u], (0.20, g, 0.12), 0.8)
    return img


def tex_brick(rng):
    img = [[None] * 32 for _ in range(32)]
    shade = {}
    for t in range(32):
        row = t // 8
        off = (row % 2) * 8
        for u in range(32):
            bu = (u + off) % 32
            key = (row, (u + off) // 16 % 2)
            if key not in shade:
                shade[key] = 0.75 + 0.35 * rng.random()
            if t % 8 == 7 or bu % 16 == 15:
                c = (0.72, 0.70, 0.64)
            else:
                f = shade[key] * (0.85 + 0.25 * rng.random())
                c = scale((0.78, 0.24, 0.14), f)
                if t % 8 == 6:
                    c = scale(c, 0.7)
            img[t][u] = c
    return img


def tex_wood(rng):
    img = [[None] * 32 for _ in range(32)]
    for t in range(32):
        for u in range(32):
            plank = u // 8
            if u % 8 == 7:
                c = (0.22, 0.12, 0.05)
            else:
                ph = plank * 1.7
                grain = 0.5 + 0.5 * math.sin(t * 0.55 + ph + 1.6 * math.sin(u * 0.9 + ph))
                f = 0.70 + 0.30 * grain + 0.08 * rng.random()
                c = scale((0.72, 0.45, 0.22), f)
                if u % 8 == 0:
                    c = scale(c, 1.15)
            img[t][u] = c
        # a dark knot
    for (cu, ct) in ((3, 9), (19, 24), (27, 5)):
        for t in range(32):
            for u in range(32):
                if (u - cu) ** 2 + ((t - ct) * 0.6) ** 2 < 2.2:
                    img[t][u] = (0.35, 0.18, 0.07)
    return img


def tex_metal(rng):
    img = [[None] * 32 for _ in range(32)]
    for t in range(32):
        for u in range(32):
            f = 0.9 + 0.12 * rng.random()
            c = scale((0.35, 0.45, 0.75), f)
            pu, pt = u % 16, t % 16
            if pt == 0 or pu == 0:
                c = (0.70, 0.80, 1.00)              # bevel: lit
            elif pt == 15 or pu == 15:
                c = (0.10, 0.14, 0.30)              # bevel: shadow
            if pu in (3, 12) and pt in (3, 12):
                c = (0.92, 0.95, 1.00)              # rivet
            elif pu in (4, 13) and pt in (4, 13):
                c = (0.12, 0.15, 0.30)              # rivet shadow
            img[t][u] = c
    return img


def tex_circuit(rng):
    green = (0.10, 0.48, 0.16)
    img = [[scale(green, 0.9 + 0.15 * rng.random()) for _ in range(32)] for _ in range(32)]
    copper = (0.95, 0.75, 0.25)
    # traces
    for t in (3, 28):
        for u in range(32):
            img[t][u] = copper
    for u in (2, 29):
        for t in range(32):
            img[t][u] = copper
    for u in range(8, 24, 3):          # pins down to the edge traces
        for t in range(3, 9):
            img[t][u] = copper
        for t in range(22, 29):
            img[t][u] = copper
    for t, u in ((3, 2), (3, 29), (28, 2), (28, 29), (14, 2), (17, 29)):
        for dt in (-1, 0, 1):
            for du in (-1, 0, 1):
                img[(t + dt) % 32][(u + du) % 32] = (0.85, 0.85, 0.80)   # vias
    # the chip
    for t in range(10, 21):
        for u in range(6, 26):
            img[t][u] = (0.08, 0.08, 0.10)
    for u in range(8, 24, 3):
        img[9][u] = (0.80, 0.80, 0.82)
        img[21][u] = (0.80, 0.80, 0.82)
    img[12][8] = (0.75, 0.75, 0.75)    # pin 1 dot
    # "22V10" in a 3 x 5 font across the chip
    font = {'2': ['111', '001', '111', '100', '111'], 'V': ['101', '101', '101', '101', '010'],
            '1': ['010', '110', '010', '010', '111'], '0': ['111', '101', '101', '101', '111']}
    x = 7
    for ch in '22V10':
        for dy, line in enumerate(font[ch]):
            for dx, bit in enumerate(line):
                if bit == '1':
                    img[13 + dy][x + dx] = (0.85, 0.85, 0.85)
        x += 4
    return img


def tex_painting(rng):
    img = [[None] * 32 for _ in range(32)]
    for t in range(32):
        for u in range(32):
            d = min(t, u, 31 - t, 31 - u)
            if d == 0:
                c = (0.30, 0.18, 0.06)
            elif d < 3:
                c = (0.95, 0.75, 0.25) if d == 1 else (0.70, 0.50, 0.12)
            elif d == 3:
                c = (0.10, 0.06, 0.02)
            else:
                # the Mandelbrot set
                cr = -2.1 + (u - 4) * 2.7 / 24
                ci = -1.2 + (t - 4) * 2.4 / 24
                zr = zi = 0.0
                n = 0
                while n < 40 and zr * zr + zi * zi < 4:
                    zr, zi = zr * zr - zi * zi + cr, 2 * zr * zi + ci
                    n += 1
                if n == 40:
                    c = (0.02, 0.02, 0.10)
                else:
                    k = n / 40
                    c = (clamp01(0.2 + 3 * k), clamp01(0.1 + 1.5 * k), clamp01(0.55 - 0.5 * k))
            img[t][u] = c
    return img


def textures():
    """-> list of TEXN textures, each [t][u] = RGB 3-3-2 byte"""
    rng = random.Random(1979)
    srcs = [tex_stone(rng), tex_brick(rng), tex_wood(rng), tex_metal(rng),
            tex_stone(rng, base=(0.58, 0.58, 0.50), moss=True), tex_circuit(rng),
            tex_painting(rng)]
    return [[[rgb332(*c) for c in row] for row in img] for img in srcs]


def unrgb(c):
    return ((c & 7) / 7, (c >> 5) / 7, ((c >> 3) & 3) / 3)


def shade_table(f):
    out = []
    for c in range(256):
        r, g, b = unrgb(c)
        out.append(rgb332(r * f, g * f, b * f))
    return out


# ---------------------------------------------------------------------------
# tables
# ---------------------------------------------------------------------------
def tables():
    t = dict(rc.T)          # angles, DD, HT, Q, movement, ceiling and floor
    t['tex'] = textures()
    t['shade'] = [shade_table(SHADE_F[lv] * (SIDE_F if side else 1.0))
                  for side in (0, 1) for lv in range(4)]
    s = [min(255, int(round(256 * math.sin(i * 2 * math.pi / 1024)))) for i in range(256)]
    c = [min(255, int(round(256 * math.cos(i * 2 * math.pi / 1024)))) for i in range(256)]
    t['snt'], t['cst'] = s, c
    return t


T = tables()


def hit_tables():
    """HTB: by idx = (side << 4) | quadrant: the page of the |sin| or |cos|
    table (+0), the zero page address of the coordinate along the wall (+32),
    1 when the ray goes down that coordinate (+64), the u flip (+96)"""
    ss, pos, sg, fl = {}, {}, {}, {}
    for side in (0, 1):
        for q in range(4):
            i = (side << 4) | q
            if side == 0:           # x side: y + dist * sin
                ss[i] = PAGE['SNT'] >> 8 if q % 2 == 0 else PAGE['CST'] >> 8
                pos[i] = 'pyl'
                sg[i] = 1 if q in (2, 3) else 0
                fl[i] = 31 if q in (1, 2) else 0
            else:                   # y side: x + dist * cos
                ss[i] = PAGE['CST'] >> 8 if q % 2 == 0 else PAGE['SNT'] >> 8
                pos[i] = 'pxl'
                sg[i] = 1 if q in (1, 2) else 0
                fl[i] = 31 if q in (0, 1) else 0
    return ss, pos, sg, fl


HSS, HPOS, HSG, HFL = hit_tables()


# ---------------------------------------------------------------------------
# scaler heights: every height up to SC_EXACT, every other height up to 56,
# then a few clipped levels
# ---------------------------------------------------------------------------
CLIP_LEVELS = [64, 74, 88, 106, 130, 165, 210, 255]


def scaler_heights(exact):
    hs = list(range(1, exact + 1)) + list(range(exact + 2 - exact % 2, HALF + 1, 2))
    if HALF not in hs:
        hs.append(HALF)
    return hs + CLIP_LEVELS


def quantize(h, hs):
    """the scaler height used for wall height h (1-255): the largest <= h"""
    return max(x for x in hs if x <= max(1, h))


def texel_row(g, hq):
    return max(0, min(31, ((g - HALF + hq) * 16) // hq))


# ---------------------------------------------------------------------------
# the model (bit for bit what the program does)
# ---------------------------------------------------------------------------
def cast(pa, px, py, c):
    """-> dict(h, side, typ, q, alo, dist) of view column c (the DDA of
    raycast.asm, the height without the clamp to 56)"""
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
    h = min(255, hr + ((hr * T['kc'][c]) >> 8))
    return dict(h=h, side=side, typ=v >> 5, q=q, alo=a & 255, dist=dist)


def column(pa, px, py, c, hs):
    """-> the 112 bytes of view column c, top to bottom"""
    r = cast(pa, px, py, c)
    i = (r['side'] << 4) | r['q']
    s = (T['snt'] if HSS[i] == PAGE['SNT'] >> 8 else T['cst'])[r['alo']]
    dsh, dsl = r['dist'] >> 8, r['dist'] & 255
    p = (((dsh * s) & 255) + ((dsl * s) >> 8)) & 255
    pos = (px if HPOS[i] == 'pxl' else py) & 255
    frac = (pos - p if HSG[i] else pos + p) & 255
    u = (frac >> 3) ^ HFL[i]
    xb = (r['typ'] - 1) * 32 + u
    sh = T['shade'][r['side'] * 4 + level(r['h'])]
    zt = [sh[T['tex'][r['typ'] - 1][t][u]] for t in range(32)]
    hq = quantize(r['h'], hs)
    hv = min(hq, HALF)
    out = []
    for g in range(NROW):
        if g < HALF - hv:
            out.append(T['ceil'][g])
        elif g >= HALF + hv:
            out.append(T['floor'][g - HALF])
        else:
            out.append(zt[texel_row(g, hq)])
    assert 0 <= xb < 7 * 32
    return out


def view_bytes(pa, px, py, hs):
    """{address: byte} of the whole view"""
    out = {}
    for c in range(NCOL):
        col = column(pa, px, py, c, hs)
        page = 0x6100 + c * 512
        for g in range(NROW):
            out[page + row_x(g)] = col[g]
    return out


def wall_at(px, py):
    return T['map'][((py >> 8) * 16 + (px >> 8)) & 255] != 0


tick = rc.tick              # the same movement, map and demo walk
Script = rc.Script


def preview(path, st, hs):
    from PIL import Image
    img = Image.new('RGB', (640, 480))
    px_ = img.load()
    for c in range(NCOL):
        col = column(st['pa'], st['px'], st['py'], c, hs)
        for g in range(NROW):
            rgb = ps.rgb8(col[g])
            for yy in range(4):
                for xx in range(8):
                    px_[c * 8 + xx, TOP_ROW + g * 4 + yy] = rgb
    img.save(path)


def texture_sheet(path):
    from PIL import Image
    z = 8
    img = Image.new('RGB', (TEXN * (32 * z + 8) + 8, 2 * (32 * z + 8) + 8), (40, 40, 40))
    px_ = img.load()
    for k, tex in enumerate(T['tex']):
        for side in (0, 1):
            sh = T['shade'][side * 4 + 3]
            for t in range(32):
                for u in range(32):
                    rgb = ps.rgb8(sh[tex[t][u]])
                    for yy in range(z):
                        for xx in range(z):
                            px_[8 + k * (32 * z + 8) + u * z + xx,
                                8 + side * (32 * z + 8) + t * z + yy] = rgb
    img.save(path)


# ---------------------------------------------------------------------------
# the program
# ---------------------------------------------------------------------------
ZP = rc.ZP.replace('wcol       = 0x41       ; wall color (never 0)',
                   'wcol       = 0x41       ; always 1 (the store run stubs branch on it)')
ZP += '''widx       = 0x58       ; (side << 4) | quadrant: hit table index
hpos       = 0x59       ; low byte of the coordinate along the wall
xb         = 0x5A       ; texture column: k * 32 + u
shp        = 0x5B       ; shading table page
zt         = 0x%02X       ; x%02X-x%02X: the texture column, shaded
''' % (ZT, ZT, ZT + 31)


def scaler_chunks(hq):
    """the code of the scaler for height hq as (lines, size) chunks"""
    hv = min(hq, HALF)
    chunks = []
    last = None
    for g in range(HALF - hv, HALF + hv):
        t = texel_row(g, hq)
        lines, n = [], 0
        if t != last:
            lines.append('    ld   [zt + %d], ac' % t)
            n += 2
            last = t
        lines.append('    ld   0x%02X, x' % row_x(g))
        lines.append('    ld   ac, [y,x]')
        chunks.append((lines, n + 3))
    return chunks


def pack_scalers(hs, start):
    """-> (lines, {hq: address}, end address) of all the scalers from start"""
    out = []
    addr = start
    ents = {}
    hops = [0]

    def room():
        return 256 - (addr & 0xFF)

    def hop():
        nonlocal addr
        hops[0] += 1
        lb = 'sch_%d' % hops[0]
        out.append('    ld   %s >> 8, y' % lb)
        out.append('    jmp  %s' % lb)
        addr = (addr & 0xFF00) + 0x100
        out.append('#addr 0x%04X' % addr)
        out.append('%s:' % lb)
        out.append('    ld   [colpage], y')
        addr += 2

    for hq in hs:
        chunks = scaler_chunks(hq)
        if room() < 2 + chunks[0][1] + 4:
            addr = (addr & 0xFF00) + 0x100
        out.append('')
        out.append('#addr 0x%04X' % addr)
        out.append('sc_%d:                           ; scaler, height %d' % (hq, hq))
        ents[hq] = addr
        out.append('    ld   [colpage], y')
        addr += 2
        for lines, n in chunks:
            if room() < n + 4:
                hop()
            out += lines
            addr += n
        out.append('    ld   col_next >> 8, y')
        out.append('    jmp  col_next')
        addr += 4
    return out, ents, addr


def choose_heights(start):
    for exact in range(HALF, 0, -1):
        hs = scaler_heights(exact)
        lines, ents, end = pack_scalers(hs, start)
        if end <= SC_END:
            return exact, hs, lines, ents, end
    raise ValueError('the scalers do not fit')


def gen():
    a = Asm()
    a.raw('; raycast_tex.asm - generated by gen_raycast_tex.py, do not edit')
    a.raw(';')
    for ln in __doc__.strip().split('\n')[1:]:
        a.raw(('; ' + ln).rstrip())
    a.raw('')
    a.raw('#include "placard.asm"')
    a.raw('#include "placard_lib.asm"')
    a.raw(ZP)
    for name, v in (('DDXL', DDXL), ('DDXH', DDXH), ('DDYL', DDYL), ('DDYH', DDYH),
                    ('HT', HT), ('TEXB', TEXB), ('HTB', HTB), ('SHADE', SHADE)):
        a.raw('%-10s = 0x%04X' % (name, v))
    for name in DATA:
        a.raw('%-10s = 0x%04X' % (name, PAGE[name]))
    a.raw('RADIUS     = %d' % RADIUS)
    a.raw('MAP_RUN    = 0x%02X' % MAP_RUN)
    a.raw('MODE_VIEW  = 0x%02X' % MODE_VIEW)
    a.raw('HT_PAGES   = %d' % HT_PAGES)
    a.raw('HALF       = %d' % HALF)
    a.raw('NCOL       = %d' % NCOL)
    a.raw('TURN       = %d' % TURN)
    a.raw('IDLE_TICKS = %d' % IDLE_TICKS)
    a.raw('DD_MAX     = 0x%04X' % DD_MAX)

    def section(comment):
        """start a section on the next free page of the code area"""
        a.org((a.addr + 255) & 0xFF00, comment)

    # ------------------------------------------------------------- entry
    a.org(0x6000, 'the boot jumps here: on to main')
    a.raw('    ld   main >> 8, y')
    a.raw('    jmp  main')
    a.addr = CODE
    a.org(CODE, 'main: set up the screen and the player')
    a.raw('main:')
    a.g('''
    ld   STACK_TOP, ac          ; stack first
    ld   ac, [SP]
    ld   MAP_RUN, ac            ; the standard map (the boot set it already)
    ld   ac, [MAP_SHADOW]''')
    a.call('map_set', 'm_0')
    a.jump('build')
    a.raw('built:')
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
    ld   ac, [wcol]             ; (the store run stubs branch on it)
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
    section('view_loop: input, movement, then the 80 columns')
    a.raw('view_loop:')
    a.call('frame_poll', 'v_fp')
    a.call('menu_poll', 'v_mp', '(the program menu: Esc, time up)')
    a.g('''
    ld   [FRAME_LO], ac         ; ticks = frames since the last view
    sub  [last_frame], ac
    beq  view_loop              ; (wait for the next frame: 60 views a second at most)
    ld   ac, [nticks]
    ld   ac, [vticks]
    ld   [FRAME_LO], ac
    ld   ac, [last_frame]''')
    a.call('pad_read', 'v_pad')
    a.call('kbd_scan', 'v_kbd')
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
    a.jump('ticks')

    # ------------------------------------------------------------- ticks
    section('ticks: move the player once per frame since the last view')
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
    section('col_top: one ray (common part: angle, steps, first crossings)')
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
        section('DDA, quadrant %d: x step %+d, y step %+d'
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
    section('hit: wall height, where the ray hit the wall, the texture column')
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
    ld   ac, [mA]               ; fish-eye: h = hr + hr * KC[col] / 256
    ld   [col], ac              ;   (at most 255)
    add  0xA0, ac
    ld   ac, x
    ld   COLT >> 8, y
    ld   [y,x], ac
    ld   ac, [mB]''')
    mul(a, 'mh', 'mA', 'mB')
    a.g('''
    ld   [mRH], ac
    add  [hr], ac
    bcc  h_ok
    ld   255, ac
h_ok:
    ld   ac, [hh]
    ld   [wv], ac               ; widx = (side << 4) | quadrant
    and  0x10, ac
    or   [ahi], ac
    ld   ac, [widx]
    add  HTB_LO, ac             ; mB = |sin| (x side) or |cos| (y side)
    ld   ac, x
    ld   HTB >> 8, y
    ld   [y,x], ac
    ld   ac, y
    ld   [alo], x
    ld   [y,x], ac
    ld   ac, [mB]
    ld   [dsh], ac
    ld   ac, [mA]''')
    a.raw('HTB_LO     = 0x%02X' % (HTB & 0xFF))
    mul(a, 'mp1', 'mA', 'mB', 'P = lo(dsh * s) + hi(dsl * s): ')
    a.g('''
    ld   [mRL], ac
    ld   ac, [tmp]
    ld   [dsl], ac
    ld   ac, [mA]''')
    mul(a, 'mp2', 'mA', 'mB')
    a.g('''
    ld   [mRH], ac
    add  [tmp], ac
    ld   ac, [tmp]
    ld   [widx], ac             ; the coordinate along the wall (pyl or pxl)
    add  HTB_LO + 32, ac
    ld   ac, x
    ld   HTB >> 8, y
    ld   [y,x], ac
    ld   ac, x
    ld   [x], ac
    ld   ac, [hpos]
    ld   [widx], ac             ; + P or - P
    add  HTB_LO + 64, ac
    ld   ac, x
    ld   [y,x], ac
    bne  p_neg
    ld   [hpos], ac
    add  [tmp], ac
    bra  p_frac
p_neg:
    ld   [hpos], ac
    sub  [tmp], ac
p_frac:
    shr  ac                     ; u = frac / 8, mirrored on some faces
    shr  ac
    shr  ac
    ld   ac, [tmp]
    ld   [widx], ac
    add  HTB_LO + 96, ac
    ld   ac, x
    ld   [tmp], ac
    xor  [y,x], ac
    ld   ac, [tmp]
    ld   [wv], ac               ; xb = (type - 1) * 32 + u
    and  0xE0, ac
    sub  32, ac
    add  [tmp], ac
    ld   ac, [xb]''')
    a.g('''
    ld   [hh], x                ; shading page: LVL[h], + 4 on a y side
    ld   LVL >> 8, y
    ld   [y,x], ac
    ld   ac, [shp]
    ld   [wv], ac
    and  0x10, ac
    beq  p_lit
    ld   [shp], ac
    add  4, ac
    ld   ac, [shp]
p_lit:
    ld   E_CE >> 8, y           ; store run and scaler entry points for h
    ld   [y,x], ac
    ld   ac, [e_ceil]
    ld   E_FE >> 8, y
    ld   [y,x], ac
    ld   ac, [e_floor]
    ld   SC_LO >> 8, y
    ld   [y,x], ac
    ld   ac, [w_stub]
    ld   SC_PG >> 8, y
    ld   [y,x], ac
    ld   ac, [w_pg]
    ld   [col], ac              ; video page x61 + 2 * col
    shl
    add  0x61, ac
    ld   ac, [colpage]
    ld   [xb], x''')
    # the texture column: 32 texels through the shading table to zero page
    for t in range(32):
        a.g('''
    ld   (TEXB >> 8) + %d, y%s
    ld   [y,x], ac
    ld   ac, x
    ld   [shp], y
    ld   [y,x], ac
    ld   ac, [zt + %d]
    ld   [xb], x''' % (t, '      ; texel row 0 ... 31, shaded' if t == 0 else '', t))
    a.jump('ceil_stub')
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
    a.call('frame_poll', 'c_fp', '(keeps the frame count during the view)')
    a.jump('col_top')

    # ------------------------------------------------------------- view done
    section('view_done: frame rate on the text rows')
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

    # ------------------------------------------------------------- build
    section('build: the DD and HT tables in the RAM (once, at start)')
    a.raw('build:')
    a.g('''
    clr  ac                     ; DD: G into pages 1 and 3, H into 0, 2, 4
    ld   ac, [tmp]              ;   (lows at DDYL, highs at DDYH)
b_dd:
    ld   [tmp], x
    ld   GL >> 8, y
    ld   [y,x], ac
    ld   (DDYL >> 8) + 1, y
    ld   ac, [y,x]
    ld   (DDYL >> 8) + 3, y
    ld   ac, [y,x]
    ld   GH >> 8, y
    ld   [y,x], ac
    ld   (DDYH >> 8) + 1, y
    ld   ac, [y,x]
    ld   (DDYH >> 8) + 3, y
    ld   ac, [y,x]
    ld   DD_MAX & 0xFF, ac      ; H[0] = DD_MAX, H[l] = G[256 - l]
    ld   ac, [mA]
    ld   DD_MAX >> 8, ac
    ld   ac, [mB]
    ld   [tmp], ac
    beq  b_h
    xor  255, ac
    add  1, ac
    ld   ac, x
    ld   GL >> 8, y
    ld   [y,x], ac
    ld   ac, [mA]
    ld   GH >> 8, y
    ld   [y,x], ac
    ld   ac, [mB]
    ld   [tmp], x
b_h:
    ld   [mA], ac
    ld   (DDYL >> 8) + 0, y
    ld   ac, [y,x]
    ld   (DDYL >> 8) + 2, y
    ld   ac, [y,x]
    ld   (DDYL >> 8) + 4, y
    ld   ac, [y,x]
    ld   [mB], ac
    ld   (DDYH >> 8) + 0, y
    ld   ac, [y,x]
    ld   (DDYH >> 8) + 2, y
    ld   ac, [y,x]
    ld   (DDYH >> 8) + 4, y
    ld   ac, [y,x]
    ld   [tmp], ac
    add  1, ac
    ld   ac, [tmp]
    bne  b_dd''')
    a.g('''
    ld   HT >> 8, ac            ; HT: HCH:HCL[v] entries of value v, v = 255
    ld   ac, [mDL]              ;   down to 0, from HT on
    clr  ac                     ;   (mDL = page, mDH = offset, mB = v,
    ld   ac, [mDH]              ;   mRH:mRL = entries left)
    ld   255, ac
    ld   ac, [mB]
b_v:
    ld   [mB], x
    ld   HCL >> 8, y
    ld   [y,x], ac
    ld   ac, [mRL]
    ld   HCH >> 8, y
    ld   [y,x], ac
    ld   ac, [mRH]
b_n:
    ld   [mRL], ac
    or   [mRH], ac
    beq  b_nx
    ld   [mDL], y
    ld   [mDH], x
    ld   [mB], ac
    ld   ac, [y,x]
    ld   [mDH], ac
    add  1, ac
    ld   ac, [mDH]
    bcc  b_c
    ld   [mDL], ac
    add  1, ac
    ld   ac, [mDL]
b_c:
    ld   [mRL], ac
    sub  1, ac
    ld   ac, [mRL]
    bcc  b_n
    ld   [mRH], ac
    sub  1, ac
    ld   ac, [mRH]
    bra  b_n
b_nx:
    ld   [mB], ac
    sub  1, ac
    ld   ac, [mB]
    bcc  b_v''')
    a.jump('built')
    code_end = a.addr

    # ------------------------------------------------------------- scalers
    exact, hs, sc_lines, sc_ents, sc_end = choose_heights((code_end + 255) & 0xFF00)
    a.raw('')
    a.raw('; ---------------------------------------------------------------------------')
    a.raw('; compiled scalers: heights 1-%d, every other height to %d, clipped %s'
          % (exact, HALF, ', '.join(str(h) for h in CLIP_LEVELS)))
    a.raw('; ---------------------------------------------------------------------------')
    a.raw('SC_EXACT   = %d' % exact)
    for ln in sc_lines:
        a.raw(ln)

    # ------------------------------------------------------------- data
    t = T
    data_page(a, PAGE['GL'], [v & 255 for v in t['g']], 'GL: |1 / cos| low bytes, angles 0-255 (build_dd)')
    data_page(a, PAGE['GH'], [v >> 8 for v in t['g']], 'GH: high bytes')
    data_page(a, PAGE['HCL'], [v & 255 for v in t['ht_count']], 'HCL: how many HT entries have value v, low bytes')
    data_page(a, PAGE['HCH'], [v >> 8 for v in t['ht_count']], 'HCH: high bytes')
    data_page(a, PAGE['QL0'], [v & 255 for v in t['q'][:256]], 'QL0: n * n / 4 low bytes, n = 0-255')
    data_page(a, PAGE['QL1'], [v & 255 for v in t['q'][256:]], 'QL1: n = 256-511')
    data_page(a, PAGE['QH0'], [v >> 8 for v in t['q'][:256]], 'QH0: high bytes')
    data_page(a, PAGE['QH1'], [v >> 8 for v in t['q'][256:]], 'QH1')
    data_page(a, PAGE['MAP'], t['map'], 'MAP: 16 x 16, row * 16 + column, texture * 32')
    data_page(a, PAGE['COLT'], [v & 255 for v in t['colang']] + [v >> 8 for v in t['colang']] + t['kc'],
              'COLANG low (+0), high (+x50), KC (+xA0) by column')
    data_page(a, PAGE['MVX'], t['mvx'], 'MVX: x step a tick at angle p (signed)')
    data_page(a, PAGE['MVY'], t['mvy'], 'MVY: y step')
    data_page(a, PAGE['SNT'], t['snt'], 'SNT: |sin| * 256 (at most 255), angles 0-255')
    data_page(a, PAGE['CST'], t['cst'], 'CST: |cos|')
    hqs = [quantize(h, hs) for h in range(256)]
    hqs[0] = 1
    ceil_e0 = PAGE['CEIL'] + 6
    floor_e0 = PAGE['FLOOR'] + 6
    data_page(a, PAGE['E_CE'], [(ceil_e0 + 4 * min(q, HALF)) & 255 for q in hqs],
              'E_CE: ceiling run entry (low byte) for h')
    data_page(a, PAGE['E_FE'], [(floor_e0 + 4 * min(q, HALF)) & 255 for q in hqs],
              'E_FE: floor run entry for h')
    data_page(a, PAGE['SC_LO'], [sc_ents[q] & 255 for q in hqs], 'SC_LO: scaler for h, low byte')
    data_page(a, PAGE['SC_PG'], [sc_ents[q] >> 8 for q in hqs], 'SC_PG: its page')
    data_page(a, PAGE['LVL'], [(SHADE >> 8) + level(h) for h in range(256)],
              'LVL: shading page (light) for h')
    for p in range(8):
        data_page(a, SHADE + 0x100 * p, t['shade'][p],
                  'SHADE %d: %s side, distance level %d' % (p, 'y' if p >= 4 else 'x', p % 4))
    for row in range(32):
        vals = []
        for k in range(8):
            vals += t['tex'][k][row] if k < TEXN else [0] * 32
        data_page(a, TEXB + 0x100 * row, vals, 'texel row %d of textures A-G' % row)
    a.raw('')
    a.raw('#addr 0x%04X                     ; HTB: hit tables by (side << 4) | quadrant' % HTB)
    ss = [HSS.get(i, 0) for i in range(32)]
    pos = [HPOS.get(i, 'pxl') for i in range(32)]
    a.raw('    #d8 ' + ', '.join('0x%02X' % v for v in ss) + '     ; page of |sin| or |cos|')
    a.raw('    #d8 ' + ', '.join(pos) + '     ; coordinate along the wall')
    a.raw('    #d8 ' + ', '.join('%d' % HSG.get(i, 0) for i in range(32)) + '     ; 1: minus')
    a.raw('    #d8 ' + ', '.join('%d' % HFL.get(i, 0) for i in range(32)) + '     ; u flip')
    # MISC page: FPS digits, the demo walk script
    a.raw('')
    a.raw('#addr 0x%04X                     ; FPS_T / FPS_O: 60 / frames as two digits' % PAGE['MISC'])
    a.raw('FPS_T      = 0x%04X' % PAGE['MISC'])
    a.raw('FPS_O      = 0x%04X' % (PAGE['MISC'] + 64))
    tens, ones = [], []
    for n in range(64):
        f = 60 // n if n else 99
        tens.append(0x20 if f < 10 else 0x30 + f // 10)
        ones.append(0x30 + f % 10)
    for i in range(0, 64, 16):
        a.raw('    #d8 ' + ', '.join('0x%02X' % v for v in tens[i:i + 16]))
    for i in range(0, 64, 16):
        a.raw('    #d8 ' + ', '.join('0x%02X' % v for v in ones[i:i + 16]))
    a.raw('SCRIPT     = 0x%04X' % (PAGE['MISC'] + 128))
    sc = []
    for n, b in SCRIPT:
        sc += [n, b]
    sc.append(0)
    a.raw('    #d8 ' + ', '.join('0x%02X' % v for v in sc))
    a.raw('RATE_COL   = 0')
    a.raw('MODE_COL   = 67')

    a.raw('')
    a.raw('#addr 0x%04X                     ; text' % PAGE['TEXT'])
    a.raw('s_title: #d "PLACARD TEXTURED RAY CASTER           ALL SOFTWARE: NO SPRITE OR 3D HARDWARE", 0x00')
    a.raw('s_rate:  #d "   VIEWS A SECOND    80 X 112 CELLS, 8 BPP, 7 TEXTURES 32 X 32", 0x00')
    a.raw('s_demo:  #d "DEMO WALK   ", 0x00')
    a.raw('s_you:   #d "YOU DRIVE   ", 0x00')
    a.raw('s_keys:  #d "ARROW KEYS OR SNES PAD 1: UP/DOWN WALK, LEFT/RIGHT TURN.  10 S IDLE: DEMO WALK", 0x00')

    # ------------------------------------------------------------- store runs
    a.raw('')
    a.raw('#addr 0x%04X                     ; ceiling run: enter at ceil_e0 + 4h, rows g = 55-h .. 0'
          % PAGE['CEIL'])
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
    a.raw('')
    a.raw('#addr 0x%04X                     ; floor run: enter at floor_e0 + 4h, rows g = 56+h .. 111'
          % PAGE['FLOOR'])
    a.raw('floor_stub:')
    a.raw('    ld   [colpage], y')
    a.raw('    ld   [wcol], ac')
    a.raw('    bne  [e_floor]')
    a.raw('floor_e0:')
    for k in range(HALF):
        g = HALF + k
        a.raw('    ld   0x%02X, x\n    ld   0x%02X, [y,x]' % (row_x(g), T['floor'][k]))
    a.raw('    ld   [w_pg], y               ; the wall: the scaler for h')
    a.raw('    jmp  [w_stub]')
    info = dict(ceil_e0=ceil_e0, floor_e0=floor_e0, exact=exact, hs=hs,
                code_end=code_end, sc_end=sc_end)
    return '\n'.join(a.out) + '\n', info


def build(quiet=False):
    """-> (source, assembled program, symbols, info)"""
    src, info = gen()
    mem, syms, _ = ps.assemble(src, HERE)
    assert syms['ceil_e0'] == info['ceil_e0'] and syms['floor_e0'] == info['floor_e0']
    assert syms['main'] == CODE
    return src, mem, syms, info


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('-o', default=os.path.join(HERE, 'raycast_tex.asm'))
    ap.add_argument('--preview')
    ap.add_argument('--textures')
    args = ap.parse_args(argv)
    src, mem, syms, info = build()
    open(args.o, 'w', newline='\n').write(src)
    print('wrote %s: %d bytes; code x%04X-x%04X, scalers to x%04X; exact scaler heights 1-%d'
          % (args.o, len(mem), CODE, info['code_end'] - 1, info['sc_end'] - 1, info['exact']))
    if args.preview:
        preview(args.preview, dict(START), info['hs'])
        print('wrote', args.preview)
    if args.textures:
        texture_sheet(args.textures)
        print('wrote', args.textures)


if __name__ == '__main__':
    main(sys.argv[1:])

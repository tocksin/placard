#!/usr/bin/env python3
"""
gen_boing.py - generate boing.masm, the Amiga "Boing Ball" demo for the
Placard: a red and white checkered ball spinning and bouncing in front of a
purple grid, with its shadow on the wall (a library program for the SD
card, BOING.PLC, and a ROM build for testing on the board)

    python3 gen_boing.py            boing.masm, boing.asm, ../../sdcard/BOING.PLC,
                                    boing_rom.asm/.hex (build\\boing.bat)
    python3 test_boing_sim.py       runs it in placard_sim: checks every frame
                                    against the Python model in this file, checks
                                    that the drawing stays ahead of the beam,
                                    times it, writes the GIF

WHAT IT DRAWS
    The picture is 160 x 120, 4 bpp with 4x line repeat (square pixels of
    4 x 4 screen pixels); the top 16 screen rows are a 1 bpp text band (the
    title, frames per second).  The 4 bpp palette has the Amiga demo's
    colors: light gray wall, purple grid, red and white ball, dark gray
    shadow (dark blue where the shadow falls on a grid line).  The ball is
    48 pixels across, its axis tilted 17 degrees like the original; it
    bounces on the floor (a parabola, 64 frames a bounce), moves sideways a
    byte (2 pixels) every other frame, turns around at the walls, and spins
    the way it is going.  Esc goes back to the DOS (menu_poll).

HOW (no palette registers, sprites or scroll registers)
    - The Amiga spins its ball by cycling palette colors.  The Placard's
      colors are fixed in the color decoder, so the spin is 8 phases of the
      ball worked out here (45 degrees of turn, one checker pair, so 8
      phases repeat seamlessly), 920 bytes each, 4 pages a phase.  A row of
      a phase never crosses a page, so a row is read with one Y.
    - The background is kept twice in the video RAM: the picture in the
      4x rows' bytes (offsets x80-xFF of each odd page) and a clean copy
      in the bytes 4x rows leave free (offsets x00-x7F of the same page,
      the same row's byte at its offset AND x7F).
    - Every frame only the rows the ball and its shadow cover, now or last
      frame, are drawn again, top to bottom.  A row is built in 32 zero
      page bytes (RB) for 32 byte columns from two left of the ball: copy
      the clean background in (unrolled, 10 clocks a byte), darken the
      shadow's span through a table (DK, and DKL / DKH for a half byte at
      either end), copy the ball's bytes of this phase over it (the half
      bytes at its edge merged with what is under them), and write the 32
      bytes to the picture (unrolled, 11 clocks a byte).  Nothing else is
      erased: the 32 columns cover the ball's old place too, as it moves a
      byte at most.
    - The drawing starts as the frame wraps (the line read goes down, 36,000
      clocks before the first picture line) and keeps ahead of the beam
      (about 2,600 clocks a row against the beam's 3,200), so there is no
      tearing and no second buffer.

MEMORY (a library program, docs/DOS.md: RAM x0100-x3FFF)
    x0100-x0BFF               code (asm_expand.py packs the chunks)
    x0C00-                    tables, background rows, the 8 phases (TABLES)
    odd video pages x00-x7F   the clean background (4x rows show x80-xFF)
    zero page x20-x3F RB, x40-x5F the 32 columns' pages, x60- variables
    It runs with map FF while it draws (every section RAM, so the clean
    background can be read) and with map 07 for the library.

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
R = 24                      # ball radius in pixels (48 across, 24 bytes)
BW = 2 * R // 2             # ball width in bytes
TILT = 17                   # axis tilt in degrees
NPH = 8                     # spin phases (45 degrees: one red and one white segment)
SDX, SDY = 4, 2             # shadow offset: bytes right, rows down
TOP_ROW = 4                 # first picture row (rows 0-3 are the text band's 16 lines)
ROWS = 120
FLOOR = 100                 # horizon row: the floor below it
BY_TOP, BY_LOW = 8, 62      # ball top row: highest, lowest (bottom on row 109)
BOUNCE = 64                 # frames a bounce
BXMIN, BXMAX = 2, 50        # ball left byte column (32 columns from bx - 2 stay on the screen)
BX0, DIR0 = 20, 1
HSTEP = 2                   # frames a sideways byte
MODE_PIC = 0x0A             # 4 bpp, 4x
MODE_HUD = 0x40             # 1 bpp, 1x, blue tint
GRAY, PURPLE, RED, WHITE = 0xB, 0x2, 0x4, 0xA
DARK = {GRAY: 0x7, PURPLE: 0x1}
RBB, PGB = 0x20, 0x40       # zero page: row bytes, column pages
NCOL = 32                   # columns drawn a row (from bx - 2)

# pages
CODE_END = 0x0C00
P_MISC = 0x0C               # ROW4 x00-x77, BY x80-xBF, strings xC0-
P_SIL = 0x0D                # KL x00, KE x30, PART x60, RPG x90, ROFF xC0
P_BGD = 0x0E                # background row source: page x00-x77, offset x80-xF7
P_DK, P_DKL, P_DKH = 0x0F, 0x10, 0x11
P_BGR = 0x12                # background rows, 3 to a page
P_PH = 0x20                 # phases, 4 pages each (x2000-x3FFF)


def row4(r):
    """low byte of 4x picture row r's address (screen rows 4r-4r+3) in its
    odd page (VIDEO.md, line repeat)"""
    v = 32 + 4 * r
    return (0x80 | (v & 0x7C) | ((v >> 8) & 1) << 1 | ((v >> 7) & 1)) & 0xFF


# ---------------------------------------------------------------------------
# the picture (pixels: x 0-159, row 0-119; a byte is two pixels, the left
# one in the low nibble)
# ---------------------------------------------------------------------------
VY = 70                     # the floor's vanishing row


def background():
    bg = [[GRAY] * 160 for _ in range(ROWS)]
    for r in range(TOP_ROW, ROWS):
        for x in range(160):
            if r < FLOOR:
                if r % 16 == 11 or x % 16 == 8:
                    bg[r][x] = PURPLE
            else:                       # lines to the vanishing point, joined row to row
                for m in range(-8, 9):
                    x0 = 80 + 24 * m * (r - VY) / (119 - VY)
                    x1 = 80 + 24 * m * (r + 1 - VY) / (119 - VY)
                    if min(x0, x1) - 0.5 <= x + 0.5 <= max(x0, x1) + 0.5:
                        bg[r][x] = PURPLE
        if r in (FLOOR, 104, 109, 115):
            bg[r] = [PURPLE] * 160
    return bg


BG = background()


def in_disc(x, y):
    return (x + 0.5 - R) ** 2 + (y + 0.5 - R) ** 2 < R * R


def silhouette():
    """for each ball row: first and last byte, and whether the edge bytes are halves"""
    s = []
    for y in range(2 * R):
        xs = [x for x in range(2 * R) if in_disc(x, y)]
        jl, jr = xs[0] // 2, xs[-1] // 2
        s.append((jl, jr, xs[0] & 1))
    return s


SIL = silhouette()


def ball(ph):
    """ball pixels of phase ph: {(x, y): color} inside the disc"""
    t = math.radians(TILT)
    rot = ph * (360 / 16 * 2 / NPH)
    out = {}
    for y in range(2 * R):
        for x in range(2 * R):
            if not in_disc(x, y):
                continue
            nx = (x + 0.5 - R) / R
            ny = (y + 0.5 - R) / R
            nz = math.sqrt(max(0.0, 1 - nx * nx - ny * ny))
            ax = nx * math.cos(t) + ny * math.sin(t)       # tilt about the view axis
            ay = -nx * math.sin(t) + ny * math.cos(t)
            lon = math.degrees(math.atan2(ax, nz)) + rot
            lat = math.degrees(math.asin(max(-1.0, min(1.0, ay)))) + 90
            c = (int(math.floor(lon / 22.5)) + int(lat // 22.5)) & 1
            out[(x, y)] = RED if c else WHITE
    return out


BALLS = [ball(p) for p in range(NPH)]


def ball_rows(ph):
    """the bytes of each row of phase ph, from its first byte to its last
    (a half byte at an edge holds only the ball's nibble)"""
    b = BALLS[ph]
    rows = []
    for y, (jl, jr, part) in enumerate(SIL):
        bs = []
        for j in range(jl, jr + 1):
            v = 0
            for k in (0, 1):
                c = b.get((2 * j + k, y))
                if c is not None:
                    v |= c << (4 * k)
            bs.append(v)
        rows.append(bs)
    return rows


def row_layout():
    """page (0-3) and offset of each ball row in a phase's 4 pages"""
    lay, pg, off = [], 0, 0
    for jl, jr, _ in SIL:
        n = jr - jl + 1
        if off + n > 256:
            pg, off = pg + 1, 0
        lay.append((pg, off))
        off += n
    assert pg < 4
    return lay


LAYOUT = row_layout()


def bounce():
    return [BY_LOW - round((BY_LOW - BY_TOP) * (1 - (2 * t / BOUNCE - 1) ** 2))
            for t in range(BOUNCE)]


BY = bounce()


def screen(bx, top, ph):
    """the picture with the ball's left byte at bx, top row top, phase ph:
    {(x, row): color} for rows TOP_ROW-119"""
    pic = {}
    b = BALLS[ph]
    for r in range(TOP_ROW, ROWS):
        for x in range(160):
            c = BG[r][x]
            sx, sy = x - 2 * (bx + SDX), r - top - SDY
            if 0 <= sx < 2 * R and 0 <= sy < 2 * R and in_disc(sx, sy):
                c = DARK.get(c, 0)
            bxp, byp = x - 2 * bx, r - top
            if (bxp, byp) in b:
                c = b[(bxp, byp)]
            pic[(x, r)] = c
    return pic


class Motion:
    """the ball's state frame by frame, as the program moves it"""

    def __init__(self):
        self.bx, self.dir, self.t, self.hc, self.ph = BX0, DIR0, 0, 0, 0

    def state(self):
        return self.bx, BY[self.t], self.ph

    def step(self):
        self.t = (self.t + 1) % BOUNCE
        self.hc = (self.hc + 1) % HSTEP
        if self.hc == 0:
            self.bx += 1 if self.dir == 1 else -1
            if self.bx == BXMAX:
                self.dir = 255
            elif self.bx == BXMIN:
                self.dir = 1
        self.ph = (self.ph + (1 if self.dir == 1 else -1)) % NPH


# ---------------------------------------------------------------------------
# code
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

    def map(self, v):
        self('''
    ld   0x%02X, ac
    ld   0x50, y
    ld   ac, [y,x]''' % v)


ZP = ['xr', 'ny', 'oy', 'bx', 'dir', 'ph', 'php', 'tb', 'hc',
      'w_r', 'w_rend', 'w_i', 'w_k', 'w_kend', 'w_d', 'w_dend', 'w_del', 'w_v',
      'w_pg', 'w_sp', 'w_so', 'lastf', 'secf', 'lps', 'fps', 'w_t']
ZPM = {n: 0x60 + i for i, n in enumerate(ZP)}
assert max(ZPM.values()) < 0x90


def gen_main(g):
    g.fixed(0x0100, 'main: the screen, the background, the state')
    g('''
main:
    ld   STACK_TOP, ac
    ld   ac, [SP]
    ld   0x07, ac
    ld   ac, [MAP_SHADOW]
    ld   0x%(pic)02X, ac
    CALL vid_clear
    ld   0x5A, y
    ld   0x20, ac
mn_m:
    ld   ac, x
    ld   0x%(hud)02X, [y,x]
    add  1, ac
    xor  0x30, ac
    beq  mn_d
    xor  0x30, ac
    bra  mn_m
mn_d:
    ld   0, ac
    ld   ac, [CUR_COL]
    ld   ac, [CUR_ROW]
    ld   s_title & 0xFF, ac
    ld   ac, [R0]
    ld   s_title >> 8, ac
    ld   ac, [R1]
    CALL con_puts
    GOTO bgb''' % {'pic': MODE_PIC, 'hud': MODE_HUD})
    g.chunk('bgb: the background rows, into the picture and the clean copy')
    g('''
bgb:
    ld   %(top)d, ac
    ld   ac, [w_r]
bg_row:
    ld   0x%(misc)02X, y
    ld   [w_r], x
    ld   [y,x], ac
    ld   ac, [xr]
    ld   0x%(bgd)02X, y
    ld   [y,x], ac
    ld   ac, [w_sp]
    ld   [w_r], ac
    add  0x80, x
    ld   [y,x], ac
    ld   ac, [w_so]
    ld   0x61, ac
    ld   ac, [w_pg]
bg_col:
    ld   [w_sp], y
    ld   [w_so], x
    ld   [y,x], ac
    ld   ac, [w_v]
    ld   [w_pg], y
    ld   [xr], x
    ld   [w_v], ac
    ld   ac, [y,x]
    ld   [xr], ac
    and  0x7F, x
    ld   [w_v], ac
    ld   ac, [y,x]
    ld   [w_so], ac
    add  1, ac
    ld   ac, [w_so]
    ld   [w_pg], ac
    add  2, ac
    ld   ac, [w_pg]
    xor  0x01, ac
    bne  bg_col
    ld   [w_r], ac
    add  1, ac
    ld   ac, [w_r]
    xor  %(rows)d, ac
    bne  bg_row
    GOTO init''' % {'top': TOP_ROW, 'misc': P_MISC, 'bgd': P_BGD, 'rows': ROWS})
    g.chunk('init: the ball\'s state')
    g('''
init:
    ld   %(bx)d, ac
    ld   ac, [bx]
    ld   %(dir)d, ac
    ld   ac, [dir]
    ld   0, ac
    ld   ac, [tb]
    ld   ac, [hc]
    ld   ac, [ph]
    ld   ac, [lps]
    ld   ac, [fps]
    ld   0x%(php)02X, ac
    ld   ac, [php]
    ld   %(by0)d, ac
    ld   ac, [ny]
    ld   ac, [oy]
    ld   [FRAME_LO], ac
    ld   ac, [lastf]
    ld   ac, [secf]
    GOTO frame''' % {'bx': BX0, 'dir': DIR0, 'php': P_PH, 'by0': BY[0]})


def gen_frame(g):
    g.chunk('frame: wait for the wrap, the column pages, the rows to draw')
    g('''
frame:
fr_w:''')
    g.tick()
    g('''
    ld   [FRAME_LO], ac
    xor  [lastf], ac
    beq  fr_w
    ld   [FRAME_LO], ac
    ld   ac, [lastf]
fr_go:''')
    g.map(0xFF)
    g('''
    ld   [bx], ac
    shl
    add  0x%02X, ac             ; the page of column bx - 2''' % (0x61 - 4))
    for k in range(NCOL):
        g('    ld   ac, [0x%02X]' % (PGB + k))
        if k < NCOL - 1:
            g('    add  2, ac')
    g('''
    ld   [oy], ac
    sub  [ny], ac
    blt  fr_o
    ld   [ny], ac
    ld   ac, [w_r]
    ld   [oy], ac
    bra  fr_e
fr_o:
    ld   [oy], ac
    ld   ac, [w_r]
    ld   [ny], ac
fr_e:
    add  %d, ac
    ld   ac, [w_rend]
    GOTO row''' % (2 * R + SDY))


def gen_row(g):
    g.chunk('row: this row\'s byte offsets, then the clean background into RB')
    g('''
row:
    ld   0x%02X, y
    ld   [w_r], x
    ld   [y,x], ac
    ld   ac, [xr]
    and  0x7F, x''' % P_MISC)
    for k in range(NCOL):
        g('''
    ld   [0x%02X], y
    ld   [y,x], ac
    ld   ac, [0x%02X]''' % (PGB + k, RBB + k))
    g('    GOTO shad')

    g.chunk('shad: the shadow\'s span of this row darkened')
    g('''
shad:
    ld   [w_r], ac
    sub  [ny], ac
    sub  %(sdy)d, ac
    ld   ac, [w_i]
    blt  sh_no
    sub  %(n)d, ac
    blt  sh_go
sh_no:
    GOTO ball
sh_go:
    ld   0x%(sil)02X, y
    ld   [w_i], x
    ld   [y,x], ac
    add  %(sdx)d, ac
    ld   ac, [w_k]
    ld   [w_i], ac
    add  0x30, x
    ld   [y,x], ac
    add  %(sdx)d, ac
    ld   ac, [w_kend]
    ld   [w_i], ac
    add  0x60, x
    ld   [y,x], ac
    beq  sh_full
    ld   [w_k], x              ; left half byte: its right pixel
    ld   [x], ac
    ld   ac, x
    ld   0x%(dkh)02X, y
    ld   [y,x], ac
    ld   [w_k], x
    ld   ac, [x]
    ld   [w_kend], ac          ; right half byte: its left pixel
    sub  1, x
    ld   [x], ac
    ld   ac, x
    ld   0x%(dkl)02X, y
    ld   [y,x], ac
    ld   ac, [w_v]
    ld   [w_kend], ac
    sub  1, x
    ld   [w_v], ac
    ld   ac, [x]
    ld   [w_k], ac
    add  1, ac
    ld   ac, [w_k]
    ld   [w_kend], ac
    sub  1, ac
    ld   ac, [w_kend]
sh_full:
    ld   [w_k], ac
    xor  [w_kend], ac
    beq  sh_d
    ld   0x%(dk)02X, y
sh_lp:
    ld   [w_k], x
    ld   [x], ac
    ld   ac, x
    ld   [y,x], ac
    ld   [w_k], x
    ld   ac, [x]
    ld   [w_k], ac
    add  1, ac
    ld   ac, [w_k]
    xor  [w_kend], ac
    bne  sh_lp
sh_d:
    GOTO ball''' % {'sdy': SDY, 'n': 2 * R, 'sil': P_SIL, 'sdx': SDX, 'dk': P_DK,
                    'dkl': P_DKL, 'dkh': P_DKH})

    g.chunk('ball: this phase\'s bytes of the row over RB')
    g('''
ball:
    ld   [w_r], ac
    sub  [ny], ac
    ld   ac, [w_i]
    blt  bl_no
    sub  %(n)d, ac
    blt  bl_go
bl_no:
    GOTO wrow
bl_go:
    ld   0x%(sil)02X, y
    ld   [w_i], x
    ld   [y,x], ac
    ld   ac, [w_k]
    ld   [w_i], ac
    add  0x30, x
    ld   [y,x], ac
    ld   ac, [w_kend]
    ld   [w_i], ac
    add  0xC0, x
    ld   [y,x], ac
    ld   ac, [w_d]
    sub  [w_k], ac
    ld   ac, [w_del]           ; data index - RB address
    ld   [w_kend], ac
    add  [w_del], ac
    ld   ac, [w_dend]
    ld   [w_i], ac
    add  0x60, x
    ld   [y,x], ac
    ld   ac, [w_v]
    ld   [w_i], ac
    add  0x90, x
    ld   [y,x], ac
    add  [php], y              ; the row's page in this phase
    ld   [w_v], ac
    beq  bl_full
    ld   [w_d], x              ; left half byte: the ball's right pixel
    ld   [y,x], ac
    ld   ac, [w_v]
    ld   [w_k], x
    ld   [x], ac
    and  0x0F, ac
    or   [w_v], ac
    ld   ac, [x]
    ld   [w_dend], ac          ; right half byte: the ball's left pixel
    sub  1, x
    ld   [y,x], ac
    ld   ac, [w_v]
    ld   [w_kend], ac
    sub  1, x
    ld   [x], ac
    and  0xF0, ac
    or   [w_v], ac
    ld   ac, [x]
    ld   [w_d], ac
    add  1, ac
    ld   ac, [w_d]
    ld   [w_dend], ac
    sub  1, ac
    ld   ac, [w_dend]
bl_full:
    ld   [w_d], ac
    xor  [w_dend], ac
    beq  bl_d
bl_lp:
    ld   [w_d], x
    ld   [y,x], ac
    ld   ac, [w_v]
    ld   [w_d], ac
    sub  [w_del], x
    ld   [w_v], ac
    ld   ac, [x]
    ld   [w_d], ac
    add  1, ac
    ld   ac, [w_d]
    xor  [w_dend], ac
    bne  bl_lp
bl_d:
    GOTO wrow''' % {'n': 2 * R, 'sil': P_SIL})

    g.chunk('wrow: RB into the picture, the next row')
    g('''
wrow:
    ld   [xr], x''')
    for k in range(NCOL):
        g('''
    ld   [0x%02X], y
    ld   [0x%02X], ac
    ld   ac, [y,x]''' % (PGB + k, RBB + k))
    g('''
row_done:
    ld   [w_r], ac
    add  1, ac
    ld   ac, [w_r]
    xor  [w_rend], ac
    beq  wr_e
    GOTO row
wr_e:
    GOTO move''')


def gen_move(g):
    g.chunk('move: the next frame\'s place and phase')
    g('''
move:''')
    g.map(0x07)
    g('''
    ld   [ny], ac
    ld   ac, [oy]
    ld   [tb], ac
    add  1, ac
    and  %(bm)d, ac
    ld   ac, [tb]
    ld   0x%(misc)02X, y
    add  0x80, x
    ld   [y,x], ac
    ld   ac, [ny]
    ld   [hc], ac
    add  1, ac
    ld   ac, [hc]
    xor  %(hs)d, ac
    bne  mv_s
    ld   ac, [hc]
    ld   [bx], ac
    add  [dir], ac
    ld   ac, [bx]
    xor  %(bxmax)d, ac
    bne  mv_l
    ld   255, ac
    ld   ac, [dir]
    bra  mv_s
mv_l:
    xor  %(bxx)d, ac
    bne  mv_s
    ld   1, ac
    ld   ac, [dir]
mv_s:
    ld   [ph], ac
    add  [dir], ac
    and  %(pm)d, ac
    ld   ac, [ph]
    shl
    shl
    add  0x%(php)02X, ac
    ld   ac, [php]
    GOTO count''' % {'bm': BOUNCE - 1, 'misc': P_MISC, 'hs': HSTEP, 'bxmax': BXMAX,
                     'bxx': BXMAX ^ BXMIN, 'pm': NPH - 1, 'php': P_PH})

    g.chunk('count: frames a second on the second text row, keys, the menu hook')
    g('''
count:
    ld   [lps], ac
    add  1, ac
    ld   ac, [lps]
    ld   [FRAME_LO], ac
    sub  [secf], ac
    sub  60, ac
    bcs  ct_k
    ld   [secf], ac
    add  60, ac
    ld   ac, [secf]
    ld   [lps], ac
    ld   ac, [fps]
    ld   0, ac
    ld   ac, [lps]
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
    ld   s_sp & 0xFF, ac
    ld   ac, [R0]
    ld   s_sp >> 8, ac
    ld   ac, [R1]
    CALL con_puts
ct_k:
fe_mark:
    CALL kbd_scan
    CALL menu_poll
    GOTO frame''')


def data_page(g, addr, values, comment):
    g.fixed(addr, comment)
    for i in range(0, len(values), 16):
        g('    #d8 ' + ', '.join('0x%02X' % v for v in values[i:i + 16]))


def bg_row_bytes(r):
    return [BG[r][2 * c] | BG[r][2 * c + 1] << 4 for c in range(80)]


def tables():
    """{page: 256 bytes} of every table"""
    pages = {}
    misc = [0] * 256
    for r in range(ROWS):
        misc[r] = row4(r)
    for t in range(BOUNCE):
        misc[0x80 + t] = BY[t]
    pages[P_MISC] = misc[:0xC0]
    sil = [0] * 256
    for i, (jl, jr, part) in enumerate(SIL):
        sil[i] = RBB + 2 + jl
        sil[0x30 + i] = RBB + 2 + jr + 1
        sil[0x60 + i] = part
        sil[0x90 + i], sil[0xC0 + i] = LAYOUT[i]
    pages[P_SIL] = sil
    dk = [DARK.get(v & 15, 0) | DARK.get(v >> 4, 0) << 4 for v in range(256)]
    dkl = [DARK.get(v & 15, 0) | (v & 0xF0) for v in range(256)]
    dkh = [(v & 0x0F) | DARK.get(v >> 4, 0) << 4 for v in range(256)]
    pages[P_DK], pages[P_DKL], pages[P_DKH] = dk, dkl, dkh
    # background rows: one copy of each distinct row, 3 to a page
    srcs, where = [], {}
    bgd = [0] * 256
    for r in range(TOP_ROW, ROWS):
        b = tuple(bg_row_bytes(r))
        if b not in where:
            n = len(srcs)
            where[b] = (P_BGR + n // 3, 80 * (n % 3))
            srcs.append(b)
        bgd[r], bgd[0x80 + r] = where[b]
    pages[P_BGD] = bgd
    for n, b in enumerate(srcs):
        p = P_BGR + n // 3
        pages.setdefault(p, [0] * 240)
        pages[p][80 * (n % 3):80 * (n % 3) + 80] = list(b)
    assert P_BGR + (len(srcs) - 1) // 3 < 0x1F, 'background rows run into LIB_RAM'
    for p in range(NPH):
        rows = ball_rows(p)
        for k in range(4):
            pages[P_PH + 4 * p + k] = [0] * 256
        for i, bs in enumerate(rows):
            pg, off = LAYOUT[i]
            pages[P_PH + 4 * p + pg][off:off + len(bs)] = bs
    for p in pages:
        assert 0x0C <= p < 0x40 and p != 0x1F, hex(p)
    return pages


def generate():
    g = Gen()
    head = ['; ' + '=' * 60,
            '; boing.masm - the Amiga Boing Ball on the Placard (made by gen_boing.py:',
            ';   change that and run it again; see its docstring)',
            '; Date: 10/28/2026',
            '; ' + '=' * 60, '',
            '#include "placard.asm"',
            '#include "placard_lib.asm"', '']
    head += ['%-8s = 0x%02X' % (n, a) for n, a in ZPM.items()]
    head += ['', '.prefix bo', '.region 0x0100, 0x%04X' % CODE_END]
    g.out = head
    gen_main(g)
    gen_frame(g)
    gen_row(g)
    gen_move(g)
    pages = tables()
    for p in sorted(pages):
        v = pages[p]
        if p == P_MISC:
            data_page(g, p << 8, v, 'ROW4 (x00), the bounce (x80)')
            g('s_title:\n    #d "PLACARD BOING BALL    ESC: DOS", 0x00')
            g('s_fps:\n    #d "FPS ", 0x00')
            g('s_sp:\n    #d " ", 0x00')
        else:
            data_page(g, p << 8, v, 'table page x%02X' % p)
    return pack('\n'.join(g.out) + '\n')


def pack(text):
    """the chunks of each region largest first, so asm_expand's first fit
    leaves little room unused"""
    import asm_expand as ae
    _, chunks = ae.expand(text, 'boing.masm')
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
    """boing_rom.asm: a 64K development image (a ROM program at x6000) that
    copies the program into RAM x0100-x3FFF (not LIB_RAM, x1F00-x1FFF) and
    runs it, for build\\boing.bat; for testing on the board without the SD
    card and the DOS"""
    import placard_sim as ps
    mem, syms, _ = ps.assemble(open(asm_path).read(), os.path.dirname(os.path.abspath(asm_path)))
    lib, _, _ = ps.assemble(open(os.path.join(HERE, 'rom_lib.asm')).read(), HERE)
    own = {a: v for a, v in mem.items()
           if 0x0100 <= a < 0x4000 and not (ps.lib_area(a) and lib.get(a) == v)}
    out = ['; ' + '=' * 60,
           '; boing_rom.asm - the Boing Ball demo as a ROM program (made by',
           ';   gen_boing.py from boing.asm: change that and run it again)',
           ';',
           '; For testing on the board without the SD card: build\\boing.bat.  The stub at',
           '; x6000 copies RAM x0100-x3FFF (but x1F00-x1FFF, LIB_RAM) from its copy at',
           '; ROM x%04X-x%04X, sets map 07 as the DOS would, and jumps to the program.' % (
               ROM_IMG, ROM_IMG + 0x3EFF),
           '; Without the DOS there is no menu block, so Esc does nothing.',
           '; Date: 10/28/2026',
           '; ' + '=' * 60, '',
           '#include "placard.asm"',
           '#include "placard_lib.asm"', '',
           'cp_pg   = 0x20',
           'B_MAIN  = 0x%04X' % syms['main'],
           'B_FE_MARK = 0x%04X' % syms['fe_mark'], '',
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
           '    ld   B_MAIN >> 8, y',
           '    jmp  B_MAIN', '',
           '; the program (boing.asm) as it is in RAM x0100-x3FFF',
           '#addr 0x%04X' % ROM_IMG]
    for a in range(0x0100, 0x4000, 16):
        out.append('    #d8 ' + ', '.join('0x%02X' % own.get(b, 0) for b in range(a, a + 16)))
    open(out_path, 'w', newline='\n').write('\n'.join(out) + '\n')


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('-o', '--out', default=os.path.join(HERE, 'boing.masm'))
    ap.add_argument('--plc', default=os.path.join(HERE, '..', '..', 'sdcard', 'BOING.PLC'),
                    help='the .PLC file ("none" for none: no ROM build either)')
    a = ap.parse_args(argv)
    open(a.out, 'w', newline='\n').write(generate())
    subprocess.check_call([sys.executable, os.path.join(HERE, 'asm_expand.py'), a.out])
    asm = a.out[:-5] + '.asm'
    if a.plc != 'none':
        subprocess.check_call([sys.executable, os.path.join(HERE, 'gen_plc.py'), asm, '-o', a.plc])
        rom = os.path.join(HERE, 'boing_rom.asm')
        rom_wrapper(asm, rom)
        subprocess.check_call([sys.executable, os.path.join(HERE, 'placard_sim.py'), rom])
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

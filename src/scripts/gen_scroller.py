#!/usr/bin/env python3
"""
gen_scroller.py - generate scroller.asm, a side-scrolling platform game demo
for the Placard CPU (a ROM program that uses the standard library)

    python3 gen_scroller.py                 writes scroller.asm next to this script
    python3 gen_scroller.py --preview p.png also draws the first frame with the
                                            Python model (no CPU)
    python3 test_scroller_sim.py            runs it in placard_sim and checks
                                            every frame against the model

SCREEN
    rows   0-31   1 bpp, 1x   four lines of 80 column text: title, score,
                              controls, CPU load
    rows  32-479  4 bpp, 4x   the playfield: 160 x 112 pixels of 4 x 4,
                              16 colors, in four bands:
        cells   0-23   clouds over the sky       scrolls at 1/8 speed
        cells  24-47   mountains                 1/4
        cells  48-63   hills                     1/2
        cells  64-111  the level: 3 rows of      full speed
                       16 x 16 tiles
    The text rows use video offsets x020-x03F of each byte column and the
    playfield x180-x1FF (VIDEO.md, line repeat).

HOW IT DRAWS A FRAME (no scroll registers, no sprite hardware)
    Every frame the whole playfield is drawn again, 8,960 bytes, ahead of
    the video beam:
      1. Wait for the start of vertical blanking (frame_poll sees the line
         read wrap).
      2. Draw the bands top to bottom.  Each band is a repeating picture
         64 byte columns wide; each distinct byte column of it is a
         "strip", unrolled code in ROM that stores the column's bytes with
         immediates (ld X, x / ld value, [y,x]: 6 clocks a byte, because
         video memory is column-major).  Every row is drawn every frame,
         even rows that are the same in every column: a sprite can cover
         any row, and only the redraw takes it away.  The level band is drawn as three tile
         strips per column (tile id x 8 + byte in the tile).
         The beam takes 800 clocks a line; the drawing is a band ahead of
         it all the way down, so nothing tears.
      3. Draw the sprites on top with a blitter that runs from RAM: it maps
         the video RAM in (map xFD) so it can read the background, and
         each sprite frame is compiled code (one routine per frame, made by
         this script): a store for each solid byte, read / AND mask / OR /
         write for each byte that is half transparent, nothing for empty
         bytes.  The row offsets come from a table, so a sprite can be at
         any row; columns off the screen and rows off the playfield write
         to video RAM that isn't shown (page x60, offset x10).
    Then the sound driver, the pads and keyboard, and the game.  The text
    line 3 shows the CPU load: the share of the frame not spent waiting
    for the next one.

THE GAME
    Run right (or left), jump over water and onto bricks, collect coins,
    stomp the slimes (landing on them; touching one from the side costs a
    life).  The level is 128 tiles (1,024 bytes) long and wraps around; on
    each lap the coins and slimes come back.  All positions are 10-bit
    byte columns, so the wrap is free.  With no input for 10 s the demo
    player (runs right, jumps at water, walls and slimes) takes over; it
    starts in the demo.
    Controls: arrow keys or SNES pad 1 Left / Right, Up / Space / pad B
    or A to jump.

Date: 10/18/2026
"""

import argparse
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps  # noqa: E402
from gen_raycast import Asm, data_page, row_x  # noqa: E402

MODE_PF = 0x0A          # 4 bpp, 4x
NCOL = 80
NROW = 112
LEVEL_W = 128           # tiles
WRAP = LEVEL_W * 8      # byte columns (1024)
BANDS = [               # name, first cell, last cell + 1, shift (speed = 1 / 2^shift)
    ('C', 0, 24, 3),
    ('M', 24, 48, 2),
    ('H', 48, 64, 1),
]
BAND_W = 64             # repeating picture width (byte columns)
GROUND_G = 64           # first cell of the level band
SPRITE_TOP = 0          # sprites (coins at the top of a jump, the player) reach every row
GRAV = 0x38
JUMPV = 0x0480
MAXFALL = 0x0500
INV_FRAMES = 90
IDLE_TICKS = 600
MAX_SPR = 12
DROWN_G = 100           # player top cell: in the water

# palette (COLORS.md, 4 bpp): 0 black 1 blue 2 green 3 cyan 4 red 5 magenta
# 6 brown 7 khaki 8 dark gray 9 light blue a light green b light cyan
# c orange d pink e yellow f white

# ---------------------------------------------------------------------------
# pictures
# ---------------------------------------------------------------------------
TILES = {
    # 16 x 16, one hex digit a pixel
    'E': ["2222a22222222222", "222aaa2222222a22", "22aaaaa22222aaa2", "2222222222222222",
          "2222222222222222", "222222222a222222", "22222222aaa22222", "2222222aaaaa2222",
          "2222222222222222", "2a22222222222222", "aaa222222222222a", "2222222222222222",
          "2222222222222222", "222222a222222222", "22222aaa22222222", "2222222222222222"],   # hedge
    'W': ["bbbb1111bbbb1111", "11bbbb1111bbbb11"] + ["1111111111111111"] * 4
         + ["1111911111119111", "1111111111111111"] * 2 + ["1111111111111111"] * 6
         + ["0000000000000000"] * 2,                    # water
    'G': ["aaaaaaaaaaaaaaaa",
          "a2aa2aaa2aa2aaa2",
          "2222222222222222",
          "6662666266626662",
          "6666666666666666",
          "6c66666666c66666",
          "6666666c66666666",
          "6666666666666666",
          "6666c66666666c66",
          "6666666666666666",
          "66c6666666666666",
          "6666666666c66666",
          "6666666666666666",
          "666666c666666666",
          "6c66666666666666",
          "6666666666666666"],                           # grass on soil
    'D': ["6666666666666666", "6c66666666c66666", "6666666c66666666", "6666666666666666",
          "6666c66666666c66", "6666666666666666", "66c6666666666666", "6666666666c66666",
          "6666666666666666", "666666c666666666", "6c66666666666666", "6666666666666666",
          "6666666c66666666", "666c666666666c66", "6666666666666666", "66666c6666666666"],
    'B': ["7777777777777777",
          "cccccccc6ccccccc",
          "cccccccc6ccccccc",
          "cccccccc6ccccccc",
          "6666666666666666",
          "ccc6ccccccccc6cc",
          "ccc6ccccccccc6cc",
          "ccc6ccccccccc6cc",
          "6666666666666666",
          "cccccccc6ccccccc",
          "cccccccc6ccccccc",
          "cccccccc6ccccccc",
          "6666666666666666",
          "ccc6ccccccccc6cc",
          "ccc6ccccccccc6cc",
          "6666666666666666"],                           # bricks
    'S': ["ffffffffffffff7f",
          "f77777777777777 8".replace(' ', '')[:16],
          "f7777777777777788"[:16],
          "f7777777777777788"[:16],
          "f7777777777777788"[:16],
          "f7777777777777788"[:16],
          "f7777777777777788"[:16],
          "f7777777777777788"[:16],
          "f7777777777777788"[:16],
          "f7777777777777788"[:16],
          "f7777777777777788"[:16],
          "f7777777777777788"[:16],
          "f7777777777777788"[:16],
          "f7777777777777788"[:16],
          "7888888888888888",
          "8888888888888888"],                           # stone block
}
SOLID_TILES = set('GDBS')

SPRITES = {
    # robot, facing right
    'stand': ["......44........",
              "......88........",
              "..8888888888....",
              "..8bbbbbbbbb8...",
              "..8bbbbbbf0b8...",
              "..8bbbbbbf0b8...",
              "..8bbbbbbbbb8...",
              "...888888888....",
              "..89999999998...",
              ".8f9999ee99998..",
              ".8f99999999998..",
              ".889999999998...",
              "...888...888....",
              "...8f8...8f8....",
              "...888...888....",
              "..8888..8888...."],
    'run1': None, 'run2': None, 'run3': None, 'jump': None,
    'slime1': ["................",
               "................",
               "................",
               "................",
               "................",
               "......5555......",
               "....55555555....",
               "...5555555555...",
               "..55f0555f055d..",
               "..55005550055d..",
               ".5555555555555d.",
               ".55555555555555.",
               ".55d55555555d55.",
               "5555555555555555",
               "5555555555555555",
               ".55.55.55.55.55."],
    'slime2': ["................",
               "................",
               "................",
               "................",
               "................",
               "................",
               "................",
               "....55555555....",
               "..555555555555..",
               ".55f055555f0555.",
               ".55005555500555d",
               "5555555555555555",
               "55d55555555d5555",
               "5555555555555555",
               "5555555555555555",
               "55.55.55.55.55.5"],
    'coin1': ["..eeee..", ".eeeeee.", "eeeffee6", "eeefee66", "eeeeee66", "eeeee666", ".ee6666.", "..6666.."],
    'coin2': ["...ee...", "..eeee..", "..efe6..", "..efe6..", "..eee6..", "..ee66..", "..e666..", "...66..."],
    'coin3': ["...e6...", "...e6...", "...e6...", "...e6...", "...e6...", "...e6...", "...e6...", "...e6..."],
    'coin4': ["...66...", "..6ee6..", "..6efe..", "..6efe..", "..6eee..", "..66ee..", "..666e..", "...66..."],
}
_legs = {
    'run1': ["...888..888.....", "...8f8.8f8......", "..888..888......", "..8888.8888....."],
    'run2': ["....888888......", "....8f88f8......", "....888888......", "...8888888......"],
    'run3': ["..888....888....", ".8f8......8f8...", ".888.......888..", "8888.......8888."],
    'jump': ["..888....888....", "..8f8....8f8....", ".888......888...", ".888.......888.."],
}
for _k, _l in _legs.items():
    SPRITES[_k] = SPRITES['stand'][:12] + _l
SPRITES['jump'] = SPRITES['jump'][:9] + [".8f99999999998f8", "..f99999999998f.", "..89999999998..."] + SPRITES['jump'][12:]

PLAYER_FRAMES = ['stand', 'run1', 'run2', 'run3', 'jump']
FRAMES = ([('R_' + f, SPRITES[f]) for f in PLAYER_FRAMES]
          + [('L_' + f, [r[::-1] for r in SPRITES[f]]) for f in PLAYER_FRAMES]
          + [('slime1', SPRITES['slime1']), ('slime2', SPRITES['slime2'])]
          + [('coin%d' % i, SPRITES['coin%d' % i]) for i in range(1, 5)])
FRAME_ID = {n: i for i, (n, _) in enumerate(FRAMES)}

# level: 3 tile rows (cells 64-79, 80-95, 96-111), 128 tiles, wraps around.
# '.' = hedge in rows 0-1, water in row 2.  Coins: 'o' in the coin rows
# (cell 48 = top of hills, 68 = inside tile row 0, 84 = tile row 1).
# Slimes: 's' (standing on what is below).
SEGMENTS = [
    # row 0, row 1, row 2, coins at cell 48, 68, 84, slimes (16 tiles each)
    ("................", "................", "GGGGGGGGGGGGGGGG",
     "................", "................", "....oo..........", "................"),
    ("................", "......BBB.......", "GGG...GGGGGGGGGG",
     "................", "......ooo.......", "................", "............s..."),
    ("....SS..........", "...SSSS.........", "GGGGGGGGGGGGGGGG",
     "....oo..........", "................", "..........oo....", "..........s....."),
    ("................", "......BB........", "GGGG......GGGGGG",
     "................", "......oo........", "................", "................"),
    ("................", "....GGGGGGGG....", "GGGGDDDDDDDDGGGG",
     "................", ".....oo.........", "..oo............", ".......s........"),
    ("..BBBBB.........", "................", "GGGGGGGGGGGG..GG",
     "...ooo..........", "................", "................", "........s......."),
    ("......S.........", "....SSS.........", "GGGGGGGGG...GGGG",
     "......o.........", "................", "..oo............", "................"),
    ("................", "..........BBB...", "GGGGGGGGGGGGGGGG",
     "................", "..........ooo...", "..oo............", "....s..........."),
]
LEVEL = [''.join(sg[r] for sg in SEGMENTS) for r in range(3)]
COINS = {g: ''.join(sg[3 + k] for sg in SEGMENTS) for k, g in enumerate((48, 68, 84))}
SLIMES = ''.join(sg[6] for sg in SEGMENTS)

START_X = 16            # player start (byte column)


LEVEL = [LEVEL[0][:LEVEL_W].ljust(LEVEL_W, '.'), LEVEL[1][:LEVEL_W].ljust(LEVEL_W, '.'),
         LEVEL[2][:LEVEL_W].ljust(LEVEL_W, 'G')]
COINS = {g: r[:LEVEL_W].ljust(LEVEL_W, '.') for g, r in COINS.items()}
SLIMES = SLIMES[:LEVEL_W].ljust(LEVEL_W, '.')


def tile_rows():
    rows = []
    for r in range(3):
        row = []
        for t in range(LEVEL_W):
            ch = LEVEL[r][t]
            if ch == '.':
                ch = 'W' if r == 2 else 'E'
            row.append(ch)
        rows.append(row)
    return rows


TROWS = tile_rows()


def solid_at(x, g):
    """is cell g of world byte column x (any int) solid?"""
    if g < GROUND_G or g >= NROW:
        return False
    return TROWS[(g - GROUND_G) >> 4][(x >> 3) % LEVEL_W] in SOLID_TILES


def surface(t):
    """top cell of the first solid tile in tile column t, or None"""
    for r in range(3):
        if TROWS[r][t] in SOLID_TILES:
            return GROUND_G + 16 * r
    return None


def objects():
    coins = []
    for g, row in COINS.items():
        assert len(row) == LEVEL_W, g
        for t, ch in enumerate(row):
            if ch == 'o':
                coins.append((t * 8 + 2, g))
    slimes = []
    assert len(SLIMES) == LEVEL_W
    for t, ch in enumerate(SLIMES):
        if ch == 's':
            top = surface(t)
            assert top is not None, t
            # patrol while the tile under stays the same surface and nothing blocks
            lo = hi = t
            while lo > 0 and surface(lo - 1) == top and not solid_at((lo - 1) * 8, top - 1):
                lo -= 1
            while hi < LEVEL_W - 1 and surface(hi + 1) == top and not solid_at((hi + 1) * 8, top - 1):
                hi += 1
            slimes.append(dict(x=t * 8, g=top - 16, lo=lo * 8, hi=hi * 8 + 8 - 8))
    return coins, slimes


COINS_L, SLIMES_L = objects()


def pix_byte(left, right):
    return int(left, 16) | (int(right, 16) << 4)


def band_pictures():
    """{band: [byte column][cell] -> byte} for bands C, M, H (64 columns each)"""
    rnd = random.Random(7)
    W = BAND_W * 2      # pixels across
    pics = {}
    # clouds over a sky gradient
    rows = 24
    px = [[0] * W for _ in range(rows)]
    sky = [1] * 6 + [1, 9] * 3 + [9] * 6 + [9, 11] * 3 + [11] * 0
    sky = (sky + [11] * rows)[:rows]
    for g in range(rows):
        for x in range(W):
            # dither alternate pixels on the "1, 9" rows
            px[g][x] = sky[g]
    for g in range(rows):
        if g in (6, 8, 10):
            for x in range(W):
                px[g][x] = 1 if x % 2 else 9
        if g in (18, 20, 22):
            for x in range(W):
                px[g][x] = 9 if x % 2 else 11
    for cx, cy, cw in ((10, 6, 22), (54, 11, 30), (96, 4, 18), (118, 13, 14)):
        for g in range(rows):
            for x in range(W):
                dx = ((x - cx) % W)
                if dx > W // 2:
                    dx -= W
                # a cloud: three overlapping ellipses
                inside = False
                shade = False
                for ox, oy, rx, ry in ((0, 2, cw // 2, 3), (-cw // 5, 0, cw // 4, 3), (cw // 6, -1, cw // 4, 4)):
                    ex = (dx - ox) / rx
                    ey = (g - cy - oy) / ry
                    if ex * ex + ey * ey <= 1:
                        inside = True
                        if g - cy - oy > ry * 0.35:
                            shade = True
                if inside:
                    px[g][x] = 11 if shade else 15
    pics['C'] = px
    # mountains
    rows = 24
    px = [[11] * W for _ in range(rows)]
    peaks = [(14, 3), (40, 8), (62, 1), (90, 6), (112, 4)]
    for x in range(W):
        top = rows
        for pxp, py in peaks:
            d = abs(((x - pxp) + W // 2) % W - W // 2)
            top = min(top, py + d * 0.75)
        top = int(top)
        for g in range(rows):
            if g >= top:
                snow = g < top + 3 and top < 12
                px[g][x] = 15 if snow else (9 if (x + g) % 7 else 8)
    for g in range(rows - 2, rows):
        for x in range(W):
            px[g][x] = 9
    pics['M'] = px
    # hills
    rows = 16
    px = [[9] * W for _ in range(rows)]
    for x in range(W):
        import math
        top = 5 + 3.5 * math.sin(x * 2 * math.pi / W * 2) + 2 * math.sin(x * 2 * math.pi / W * 3 + 1)
        top = int(round(top))
        for g in range(rows):
            if g >= top:
                px[g][x] = 10 if g < top + 2 else 2
        # bushes
        if rnd.random() < 0.12:
            pass
    for g in range(rows - 2, rows):
        for x in range(W):
            px[g][x] = 2
    pics['H'] = px
    out = {}
    for b, px in pics.items():
        cols = []
        for c in range(BAND_W):
            cols.append([px[g][2 * c] | (px[g][2 * c + 1] << 4) for g in range(len(px))])
        out[b] = cols
    return out


BANDPIX = band_pictures()


def tile_bytes(ch):
    """[byte 0-7][row 0-15] -> byte"""
    art = TILES[ch]
    return [[pix_byte(art[r][2 * j], art[r][2 * j + 1]) for r in range(16)] for j in range(8)]


TILE_IDS = {}
for _r in range(3):
    for _ch in TROWS[_r]:
        TILE_IDS.setdefault((_r, _ch), None)
TILE_LIST = sorted(set(ch for r in TROWS for ch in r))      # one id per tile letter
TID = {ch: i for i, ch in enumerate(TILE_LIST)}
assert len(TILE_LIST) <= 8


# ---------------------------------------------------------------------------
# the model: what the playfield looks like
# ---------------------------------------------------------------------------
def band_static_rows():
    """{band: {g: value}} rows that are the same in every column, drawn once
    at the start; only rows above SPRITE_TOP, since a sprite drawn over a
    static row would stay there (the bands never redraw it)"""
    st = {}
    for name, g0, g1, _ in BANDS:
        cols = BANDPIX[name]
        st[name] = {}
        for k in range(min(g1, SPRITE_TOP) - g0):
            vals = set(cols[c][k] for c in range(BAND_W))
            if len(vals) == 1:
                st[name][g0 + k] = vals.pop()
    return st


STATIC = band_static_rows()


def background(scroll):
    """{address: byte} of the playfield for a scroll (byte columns)"""
    out = {}
    for c in range(NCOL):
        page = 0x6100 + c * 512
        for name, g0, g1, sh in BANDS:
            w = ((scroll >> sh) + c) % BAND_W
            for g in range(g0, g1):
                out[page + row_x(g)] = BANDPIX[name][w][g - g0]
        x = (scroll + c) % WRAP
        t, j = x >> 3, x & 7
        for r in range(3):
            tb = tile_bytes(TROWS[r][t])[j]
            for k in range(16):
                out[page + row_x(GROUND_G + 16 * r + k)] = tb[k]
    return out


def sprite_masks(art):
    """[(row, byte, mask, value)] of the non-empty bytes"""
    out = []
    for r, line in enumerate(art):
        for k in range(len(line) // 2):
            a, b = line[2 * k], line[2 * k + 1]
            m = (0x0F if a == '.' else 0) | (0xF0 if b == '.' else 0)
            v = (0 if a == '.' else int(a, 16)) | ((0 if b == '.' else int(b, 16)) << 4)
            if m != 0xFF:
                out.append((r, k, m, v))
    return out


def rowx_table():
    return [row_x(i - 32) if 0 <= i - 32 < NROW else 0x10 for i in range(256)]


def vpg_table():
    return [0x61 + 2 * (i - 8) if 0 <= i - 8 < NCOL else 0x60 for i in range(256)]


ROWX_T = rowx_table()
VPG_T = vpg_table()


def draw_sprites_model(mem, sprites):
    """sprites: [(frame id, SL_C, SL_G)] drawn in order onto mem (a bytearray)"""
    for fid, sc, sg in sprites:
        art = FRAMES[fid][1]
        for r, k, m, v in sprite_masks(art):
            pg = VPG_T[(sc + k) & 255]
            x = ROWX_T[(sg + r) & 255]
            a = pg << 8 | x
            mem[a] = v if m == 0 else (mem[a] & m) | v


# ---------------------------------------------------------------------------
# the RAM blitter (assembled on its own at x0100, copied from ROM at start)
# ---------------------------------------------------------------------------
ZP = '''
; ---------------------------------------------------------------------------
; program variables (zero page x20-x8F)
; ---------------------------------------------------------------------------
colpage    = 0x20       ; video page of the column being drawn (x61 + 2 * col)
rl         = 0x21       ; strip return address
rh         = 0x22
bw         = 0x23       ; band picture column
gt         = 0x24       ; level tile column 0-127
gj         = 0x25       ;   byte in the tile 0-7
tmp        = 0x26
tmp2       = 0x27
scl        = 0x28       ; scroll: world byte column at the left edge, 0-1023
sch        = 0x29
pxl        = 0x2A       ; player x (left byte column), 0-1023
pxh        = 0x2B
pyl        = 0x2C       ; player y: top cell (pyh) and 1/256 cell
pyh        = 0x2D
vyl        = 0x2E       ; vertical speed, cells / 256 a frame, signed
vyh        = 0x2F
onground   = 0x30
facing     = 0x31       ; 0 right, 5 left (frame offset)
anim       = 0x32
inp        = 0x33       ; input: 1 right, 2 left, 4 jump
demo       = 0x34
idle_lo    = 0x35
idle_hi    = 0x36
last_frame = 0x37
lives      = 0x38
score_lo   = 0x39
score_hi   = 0x3A
coins      = 0x3B
hud_dirty  = 0x3C
ta_lo      = 0x3D       ; tile_at: world byte column, cell
ta_hi      = 0x3E
ta_g       = 0x3F
chk_lo     = 0x40       ; where the player last stood
chk_hi     = 0x41
sl_n       = 0x42       ; sprites in the list
s_i        = 0x43
sc         = 0x44       ; this sprite: byte column + 8, top cell + 32
sy         = 0x45
srl        = 0x46       ; return address for the sprite routines
srh        = 0x47
vpg        = 0x48       ; x48-x4F: video page of each of the sprite's 8 columns
SL_LO      = 0x50       ; x50-x5B: sprite routine address, low
SL_HI      = 0x5C       ; x5C-x67: high
SL_C       = 0x68       ; x68-x73: byte column + 8 (0-87)
SL_G       = 0x74       ; x74-x7F: top cell + 32
it_lo      = 0x80       ; polls while waiting for the next frame
it_hi      = 0x81
o_i        = 0x82       ; object loop index
dlo        = 0x83
dhi        = 0x84
inv        = 0x85       ; frames of safety after a lost life
lag        = 0x86       ; frames missed (should stay 0)
moved      = 0x87
tmp3       = 0x88
hud_div    = 0x89
danger     = 0x8A       ; a slime ahead (for the demo player)
ll_lo      = 0x8B       ; lose_life's return address
ll_hi      = 0x8C
'''


def blitter():
    """-> (source, symbols, {addr: byte})"""
    a = Asm()
    a.raw('#include "placard.asm"')
    a.raw(ZP)
    a.raw('LINK_LO = 0x04')
    a.raw('LINK_HI = 0x05')
    a.raw('MAP_SHADOW = 0x07')
    a.raw('MAP_SPR = 0xFD')
    a.org(0x0100, 'ROWX: video offset (low byte) of top cell + 32, 0x10 off the playfield')
    a.raw('ROWX:')
    for i in range(0, 256, 16):
        a.raw('    #d8 ' + ', '.join('0x%02X' % v for v in ROWX_T[i:i + 16]))
    a.org(0x0200, 'VPG: video page of byte column + 8, x60 off the screen')
    a.raw('VPG:')
    for i in range(0, 256, 16):
        a.raw('    #d8 ' + ', '.join('0x%02X' % v for v in VPG_T[i:i + 16]))
    a.org(0x0300, 'draw_sprites: draw the SL_ list (CALL it; maps video RAM in)')
    a.raw('draw_sprites:')
    a.g('''
    ld   0x50, y                ; map: video RAM readable (all RAM but x2000-x3FFF)
    ld   MAP_SPR, [y,x]
    ld   ds_next & 0xFF, ac     ; every sprite routine returns to ds_next
    ld   ac, [srl]
    ld   ds_next >> 8, ac
    ld   ac, [srh]
    clr  ac
    ld   ac, [s_i]
ds_next:
    ld   [s_i], ac
    sub  [sl_n], ac
    bne  ds_one
    ld   0x50, y                ; done: the map back
    ld   [MAP_SHADOW], ac
    ld   ac, [y,x]
    ld   [LINK_HI], y           ; RETURN
    jmp  [LINK_LO]
ds_one:
    ld   [s_i], ac
    add  SL_C, x
    ld   [x], ac
    ld   ac, [sc]
    ld   [s_i], ac
    add  SL_G, x
    ld   [x], ac
    ld   ac, [sy]
    ld   VPG >> 8, y''')
    lines = []
    for k in range(8):
        lines.append('    ld   [sc], ac\n    add  %d, x\n    ld   [y,x], ac\n    ld   ac, [vpg + %d]' % (k, k))
    a.g('\n'.join(lines))
    a.g('''
    ld   [s_i], ac
    add  SL_HI, x
    ld   [x], ac
    ld   ac, [tmp]
    ld   [s_i], ac
    add  SL_LO, x
    ld   [x], ac
    ld   ac, [tmp2]
    ld   [s_i], ac
    add  1, ac
    ld   ac, [s_i]
    ld   [tmp], y
    ld   [tmp2], ac
    jmp  ac''')
    for name, art in FRAMES:
        a.raw('')
        a.raw('spr_%s:' % name)
        bytes_ = sprite_masks(art)
        for r in sorted(set(b[0] for b in bytes_)):
            lines = ['    ld   [sy], ac               ; row %d' % r,
                     '    add  %d, x' % r,
                     '    ld   ROWX >> 8, y',
                     '    ld   [y,x], ac',
                     '    ld   ac, x']
            for rr, k, m, v in bytes_:
                if rr != r:
                    continue
                lines.append('    ld   [vpg + %d], y' % k)
                if m == 0:
                    lines.append('    ld   0x%02X, [y,x]' % v)
                else:
                    lines.append('    ld   [y,x], ac\n    and  0x%02X, ac\n    or   0x%02X, ac\n    ld   ac, [y,x]'
                                 % (m, v))
            for ln in lines:
                a.raw(ln)
            a.addr += Asm.size(lines)
        a.raw('    ld   [srh], y')
        a.raw('    jmp  [srl]')
        a.addr += 4
    src = '\n'.join(a.out) + '\n'
    mem, syms, _ = ps.assemble(src, HERE)
    assert max(mem) < 0x2000, 'blitter too big: %04X' % max(mem)
    return src, syms, mem


BLIT_SRC, BLIT_SYMS, BLIT_MEM = blitter()


# ---------------------------------------------------------------------------
# ROM program
# ---------------------------------------------------------------------------
def gen():
    a = Asm()
    a.raw('; scroller.asm - generated by gen_scroller.py, do not edit')
    a.raw(';')
    for ln in __doc__.strip().split('\n')[1:]:
        a.raw(('; ' + ln).rstrip())
    a.raw('')
    a.raw('#include "placard.asm"')
    a.raw('#include "placard_lib.asm"')
    a.raw(ZP)
    for k in ('draw_sprites',):
        a.raw('%-10s = 0x%04X       ; in RAM (the blitter)' % (k, BLIT_SYMS[k]))
    consts = dict(MODE_PF=MODE_PF, GRAV=GRAV, JUMPV_LO=(-JUMPV) & 0xFF, JUMPV_HI=((-JUMPV) >> 8) & 0xFF,
                  MAXFALL_HI=MAXFALL >> 8, INV_FRAMES=INV_FRAMES, IDLE_TICKS=IDLE_TICKS,
                  N_COINS=len(COINS_L), N_SLIMES=len(SLIMES_L), MAX_SPR=MAX_SPR, GROUND_G=GROUND_G,
                  START_X=START_X, NROW=NROW)
    for k, v in consts.items():
        a.raw('%-10s = %d' % (k, v))

    # table pages
    pages = {}
    a.raw('ENEMY      = 0x5400       ; RAM: slime state (see the end of this file)')
    a.raw('COIN_GOT   = 0x5500       ; RAM: 1 when coin n is taken')

    def call(target, ret, comment=''):
        a.call(target, ret, comment)

    # ------------------------------------------------------------ main
    a.org(0x6000, 'main')
    a.raw('main:')
    a.g('''
    ld   STACK_TOP, ac
    ld   ac, [SP]''')
    call('port_init', 'm_1')
    call('con_clear', 'm_2')
    call('snd_init', 'm_3')
    a.g('''
    ld   0x5A, y                ; rows 32-479 (x5A40-x5BFF): 4 bpp 4x
    ld   0x40, ac
m_mb1:
    ld   ac, x
    ld   MODE_PF, [y,x]
    inc
    bne  m_mb1''')
    a.g('''
    ld   0x5B, y
    clr  ac
m_mb2:
    ld   ac, x
    ld   MODE_PF, [y,x]
    inc
    bne  m_mb2''')
    # copy the blitter to RAM: BLIT_ROM -> x0100, BLIT_PAGES pages
    a.g('''
    ld   BLIT_ROM & 0xFF, ac    ; copy the RAM blitter, a page at a time
    ld   ac, [R0]
    ld   BLIT_ROM >> 8, ac
    ld   ac, [R1]
    clr  ac
    ld   ac, [R2]
    ld   1, ac
    ld   ac, [R3]
    ld   BLIT_PAGES, ac
    ld   ac, [tmp3]''')
    a.g('''
m_cp:
    clr  ac
    ld   ac, [R4]''')
    call('memcpy', 'm_cp1')
    a.g('''
    ld   [tmp3], ac
    sub  1, ac
    ld   ac, [tmp3]
    beq  m_cp2
    ld   m_cp >> 8, y
    jmp  m_cp
m_cp2:''')
    # static rows
    a.g('''
    ld   m_st1 & 0xFF, ac       ; the rows that never change, every column
    ld   ac, [rl]
    ld   m_st1 >> 8, ac
    ld   ac, [rh]
    ld   0x61, ac
    ld   ac, [colpage]
    ld   strip_static >> 8, y
    jmp  strip_static
m_st1:
    ld   [colpage], ac
    add  2, ac
    ld   ac, [colpage]
    sub  1, ac                  ; past column 79 (xFF + 2 = x01)
    beq  m_st2
    ld   strip_static >> 8, y
    jmp  strip_static
m_st2:''')
    for i, (lab, row) in enumerate((('s_title', 0), ('s_score', 1), ('s_keys', 2), ('s_cpu', 3))):
        a.g('''
    clr  ac
    ld   ac, [CUR_COL]
    ld   %d, ac
    ld   ac, [CUR_ROW]
    ld   %s, ac
    ld   ac, [R0]
    ld   %s >> 8, ac
    ld   ac, [R1]''' % (row, lab, lab))
        call('con_puts', 'm_s%d' % i)
    a.g('''
    ld   0x20, ac               ; program variables x20-x8F = 0
m_z:
    ld   ac, x
    ld   0, [x]
    add  1, ac
    sub  0x90, ac
    beq  m_z1
    add  0x90, ac
    bra  m_z
m_z1:
    ld   1, ac
    ld   ac, [demo]
    ld   ac, [hud_div]
    ld   ac, [hud_dirty]
    ld   3, ac
    ld   ac, [lives]
    ld   START_X, ac
    ld   ac, [chk_lo]''')
    call('reset_objs', 'm_ro')
    call('respawn', 'm_rs')
    call('frame_poll', 'm_fp')
    a.g('''
    ld   [FRAME_LO], ac
    ld   ac, [last_frame]''')
    a.jump('frame')

    # ------------------------------------------------------------ frame
    a.sect('frame: wait for vertical blanking, then draw ahead of the beam')
    a.raw('frame:')
    a.g('''
    clr  ac
    ld   ac, [it_lo]
    ld   ac, [it_hi]
f_wait:''')
    call('frame_poll', 'f_w1')
    a.g('''
    ld   [it_lo], ac            ; count the polls (CPU load)
    add  1, ac
    ld   ac, [it_lo]
    bcc  f_w2
    ld   [it_hi], ac
    add  1, ac
    ld   ac, [it_hi]
f_w2:
    ld   [FRAME_LO], ac
    sub  [last_frame], ac
    bne  f_new
    ld   f_wait >> 8, y
    jmp  f_wait
f_new:
    sub  1, ac                  ; more than one frame: count the missed ones
    beq  f_nolag
    add  [lag], ac
    ld   ac, [lag]
f_nolag:
    ld   [FRAME_LO], ac
    ld   ac, [last_frame]
frame_go:''')
    # band loops
    for bi, (name, g0, g1, sh) in enumerate(BANDS):
        base = 64 * bi
        offs = {3: '''
    ld   [scl], ac              ; w = (scroll >> 3) & 63
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [tmp]
    ld   [sch], ac
    and  1, ac
    beq  b{n}_o
    ld   [tmp], ac
    or   0x20, ac
    ld   ac, [tmp]
b{n}_o:
    ld   [tmp], ac''', 2: '''
    ld   [scl], ac              ; w = (scroll >> 2) & 63
    shr  ac
    shr  ac''', 1: '''
    ld   [scl], ac              ; w = (scroll >> 1) & 63
    shr  ac'''}[sh]
        a.g((offs + '''
    and  63, ac
    add  {base}, ac             ; (this band's strips at BS_LO + {base})
    ld   ac, [bw]
    ld   b{n}_ret & 0xFF, ac
    ld   ac, [rl]
    ld   b{n}_ret >> 8, ac
    ld   ac, [rh]
    ld   0x61, ac
    ld   ac, [colpage]''').format(n=name, base=base))
        a.g('''
b{n}_lp:
    ld   [bw], x                ; strip for picture column bw
    ld   BS_LO >> 8, y
    ld   [y,x], ac
    ld   ac, [tmp]
    ld   BS_HI >> 8, y
    ld   [y,x], ac
    ld   ac, y
    ld   [tmp], ac
    jmp  ac
b{n}_ret:
    ld   [bw], ac
    add  1, ac
    and  63, ac
    or   {base}, ac
    ld   ac, [bw]
    ld   [colpage], ac
    add  2, ac
    ld   ac, [colpage]
    sub  1, ac
    bne  b{n}_lp'''.format(n=name, base=base))
        a.raw('band_%s_done:' % name)
    # ground band
    a.g('''
    ld   [scl], ac              ; level: tile column = (scroll >> 3) & 127,
    and  7, ac                  ; byte in the tile = scroll & 7
    ld   ac, [gj]
    ld   [scl], ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [tmp]
    ld   [sch], ac
    and  3, ac
    beq  g_o1
    shl
    shl
    shl
    shl
    shl
    or   [tmp], ac
    ld   ac, [tmp]
g_o1:
    ld   [tmp], ac
    ld   ac, [gt]
    ld   0x61, ac
    ld   ac, [colpage]''')
    for r in range(3):
        a.g('''
{lp}
    ld   g_r{r} & 0xFF, ac      ; tile row {r}
    ld   ac, [rl]
    ld   g_r{r} >> 8, ac
    ld   ac, [rh]
    ld   [gt], x
    ld   LV{r} >> 8, y
    ld   [y,x], ac              ; tile id * 8 + {rb}
    or   [gj], ac
    ld   ac, x
    ld   TS_LO >> 8, y
    ld   [y,x], ac
    ld   ac, [tmp]
    ld   TS_HI >> 8, y
    ld   [y,x], ac
    ld   ac, y
    ld   [tmp], ac
    jmp  ac
g_r{r}:'''.format(r=r, rb=64 * r, lp='g_lp:' if r == 0 else ''))
    a.g('''
    ld   [gj], ac               ; next byte column
    add  1, ac
    and  7, ac
    ld   ac, [gj]
    bne  g_n1
    ld   [gt], ac
    add  1, ac
    and  127, ac
    ld   ac, [gt]
g_n1:
    ld   [colpage], ac
    add  2, ac
    ld   ac, [colpage]
    sub  1, ac
    beq  g_done
    ld   g_lp >> 8, y
    jmp  g_lp
g_done:''')
    a.raw('drawn_bg:')
    call('draw_sprites', 'f_spr', '(RAM)')
    a.raw('drawn_all:')
    call('snd_update', 'f_snd')
    call('pad_read', 'f_pad')
    call('kbd_scan', 'f_kbd')
    # input: 1 right, 2 left, 4 jump
    a.g('''
    clr  ac
    ld   ac, [inp]
    ld   [R0], ac               ; pad: Right (bit 7), Left (6), Up (4), B (0)
    and  0x80, ac
    beq  i_1
    ld   1, ac
    ld   ac, [inp]
i_1:
    ld   [R0], ac
    and  0x40, ac
    beq  i_2
    ld   [inp], ac
    or   2, ac
    ld   ac, [inp]
i_2:
    ld   [R0], ac
    and  0x11, ac
    bne  i_3
    ld   [R1], ac               ; A (bit 8)
    and  0x01, ac
    beq  i_4
i_3:
    ld   [inp], ac
    or   4, ac
    ld   ac, [inp]
i_4:''')
    a.g('''
    ld   [KBD_NOW + 7], ac      ; Right key (column 7 row 7, 0 = down)
    and  0x80, ac
    bne  k_1
    ld   [inp], ac
    or   1, ac
    ld   ac, [inp]
k_1:
    ld   [KBD_NOW + 7], ac      ; Left (row 5)
    and  0x20, ac
    bne  k_2
    ld   [inp], ac
    or   2, ac
    ld   ac, [inp]
k_2:
    ld   [KBD_NOW + 6], ac      ; Up (column 6 row 5)
    and  0x20, ac
    beq  k_3
    ld   [KBD_NOW + 7], ac      ; Space (column 7 row 2)
    and  0x04, ac
    bne  k_4
k_3:
    ld   [inp], ac
    or   4, ac
    ld   ac, [inp]
k_4:''')
    a.g('''
    ld   [inp], ac              ; any input: the player plays
    beq  i_idle
    clr  ac
    ld   ac, [demo]
    ld   ac, [idle_lo]
    ld   ac, [idle_hi]
    bra  i_mode
i_idle:
    ld   [demo], ac
    bne  i_mode
    ld   [idle_lo], ac
    add  1, ac
    ld   ac, [idle_lo]
    bcc  i_id1
    ld   [idle_hi], ac
    add  1, ac
    ld   ac, [idle_hi]
i_id1:
    ld   [idle_hi], ac
    sub  IDLE_TICKS >> 8, ac
    bne  i_mode
    ld   [idle_lo], ac
    sub  IDLE_TICKS & 0xFF, ac
    bne  i_mode
    ld   1, ac
    ld   ac, [demo]
i_mode:''')
    call('game', 'f_game')
    call('hud', 'f_hud')
    a.jump('frame')

    # ------------------------------------------------------------ tile_at
    a.sect('tile_at: AC = 0 when cell ta_g of world byte column ta_hi:ta_lo is not solid')
    a.raw('tile_at:')
    a.g('''
    ld   [ta_g], ac
    sub  GROUND_G, ac
    bcs  ta_no                  ; above the level band
    ld   ac, [tmp3]
    sub  48, ac
    bcc  ta_no                  ; below it
    ld   [tmp3], ac             ; tile row = (g - 64) / 16 -> page LV0 + row
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    add  LV0 >> 8, ac
    ld   ac, [tmp3]
    ld   [ta_lo], ac            ; tile column = (x >> 3) & 127
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [dlo]
    ld   [ta_hi], ac
    and  3, ac
    shl
    shl
    shl
    shl
    shl
    or   [dlo], ac
    ld   ac, x
    ld   [tmp3], y
    ld   [y,x], ac
    ld   ac, x
    ld   SOLID >> 8, y
    ld   [y,x], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
ta_no:
    clr  ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]''')

    # ------------------------------------------------------------ objects reset / respawn
    a.g('''
reset_objs:
    clr  ac                     ; slimes from the ROM list (OBJ x00-x47)
    ld   ac, [tmp]
ro_1:
    ld   [tmp], x
    ld   OBJ >> 8, y
    ld   [y,x], ac
    ld   ENEMY >> 8, y
    ld   ac, [y,x]
    ld   [tmp], ac
    add  1, ac
    ld   ac, [tmp]
    sub  0x48, ac
    bne  ro_1
    clr  ac                     ; every coin back
    ld   ac, [tmp]
    ld   COIN_GOT >> 8, y
ro_2:
    ld   [tmp], x
    ld   0, [y,x]
    ld   [tmp], ac
    add  1, ac
    ld   ac, [tmp]
    sub  N_COINS, ac
    bne  ro_2
    ld   [LINK_HI], y
    jmp  [LINK_LO]''')
    a.g('''
respawn:
    ld   [chk_lo], ac           ; at the last place stood on, from the top
    ld   ac, [pxl]
    ld   [chk_hi], ac
    ld   ac, [pxh]
    clr  ac
    ld   ac, [pyh]
    ld   ac, [pyl]
    ld   ac, [vyl]
    ld   ac, [vyh]
    ld   ac, [onground]
    ld   ac, [facing]
    ld   INV_FRAMES, ac
    ld   ac, [inv]
    ld   [LINK_HI], y
    jmp  [LINK_LO]''')

    def screen_col(page_y, idx_lo, idx_hi, skip):
        """dlo = (x - scroll + 8) & 1023 for an object whose x low byte is at
        [Y, idx_lo + o_i] and high byte at [Y, idx_hi + o_i]; jump to skip
        when that is not 0-87 (off the screen).  The high byte is read first
        so that no indexed add sits between the subtract and its borrow."""
        return '''
    ld   {pg} >> 8, y
    ld   [o_i], ac
    add  {hi}, x
    ld   [y,x], ac
    ld   ac, [dhi]
    ld   [o_i], ac
    add  {lo}, x
    ld   [y,x], ac
    sub  [scl], ac
    ld   ac, [dlo]
    ld   [dhi], ac
    bcc  {s}_1
    sub  1, ac
{s}_1:
    sub  [sch], ac
    ld   ac, [dhi]
    ld   [dlo], ac
    add  8, ac
    ld   ac, [dlo]
    ld   [dhi], ac
    bcc  {s}_2
    add  1, ac
{s}_2:
    and  3, ac
    bne  {s}_off
    ld   [dlo], ac
    sub  88, ac
    bcs  {s}_on
{s}_off:
    ld   {skip} >> 8, y
    jmp  {skip}
{s}_on:'''.format(pg=page_y, lo=idx_lo, hi=idx_hi, s=skip + '_sc', skip=skip)

    # ------------------------------------------------------------ game
    a.sect('game: the demo player, then movement, objects, sprite list')
    a.raw('game:')
    a.g('''
    ld   [SP], x                ; PUSH_LINK
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, x
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, [SP]''')
    a.begin()
    a.g('''
    ld   [demo], ac
    bne  gm_demo
    ld   gm_play >> 8, y
    jmp  gm_play
gm_demo:
    ld   1, ac                  ; demo: run right; jump at water, walls, slimes
    ld   ac, [inp]
    ld   [onground], ac
    bne  gm_d0
    ld   gm_play >> 8, y
    jmp  gm_play
gm_d0:
    ld   [danger], ac           ; a slime ahead (seen last frame)
    bne  gm_djump
    ld   [pxl], ac              ; ground ahead? (byte 10, the cell below the feet)
    add  10, ac
    ld   ac, [ta_lo]
    ld   [pxh], ac
    bcc  gm_d1
    add  1, ac
gm_d1:
    ld   ac, [ta_hi]
    ld   [pyh], ac
    add  16, ac
    ld   ac, [ta_g]''')
    call('tile_at', 'gm_d2')
    a.g('''
    beq  gm_djump
    ld   [pyh], ac              ; a wall ahead? (byte 9, the middle row)
    add  8, ac
    ld   ac, [ta_g]
    ld   [ta_lo], ac
    sub  1, ac
    ld   ac, [ta_lo]''')
    call('tile_at', 'gm_d3')
    a.g('''
    beq  gm_play_j
gm_djump:
    ld   5, ac
    ld   ac, [inp]
gm_play_j:
    ld   gm_play >> 8, y
    jmp  gm_play''')
    a.end()

    a.sect('game: the player, sideways')
    a.raw('gm_play:')
    a.begin()
    a.g('''
    clr  ac
    ld   ac, [moved]
    ld   [inp], ac              ; right
    and  1, ac
    beq  gm_nr
    clr  ac
    ld   ac, [facing]
    ld   [pxl], ac              ; wall at byte 8, rows 1, 8, 15?
    add  8, ac
    ld   ac, [ta_lo]
    ld   [pxh], ac
    bcc  gm_r1
    add  1, ac
gm_r1:
    ld   ac, [ta_hi]
    ld   1, ac
    ld   ac, [moved]
    bra  gm_side
gm_nr:
    ld   [inp], ac              ; left
    and  2, ac
    bne  gm_l0
    ld   gm_vert >> 8, y
    jmp  gm_vert
gm_l0:
    ld   5, ac
    ld   ac, [facing]
    ld   [pxl], ac              ; wall at byte -1?
    sub  1, ac
    ld   ac, [ta_lo]
    ld   [pxh], ac
    bcc  gm_l1
    sub  1, ac
gm_l1:
    ld   ac, [ta_hi]
    ld   2, ac
    ld   ac, [moved]
gm_side:
    ld   [pyh], ac
    add  1, ac
    ld   ac, [ta_g]''')
    call('tile_at', 'gm_s1')
    a.g('''
    bne  gm_block
    ld   [pyh], ac
    add  8, ac
    ld   ac, [ta_g]''')
    call('tile_at', 'gm_s2')
    a.g('''
    bne  gm_block
    ld   [pyh], ac
    add  15, ac
    ld   ac, [ta_g]''')
    call('tile_at', 'gm_s3')
    a.g('''
    bne  gm_block
    ld   [moved], ac            ; free: move one byte column (wraps at 1024)
    sub  1, ac
    bne  gm_ml
    ld   [pxl], ac
    add  1, ac
    ld   ac, [pxl]
    bne  gm_vert_j
    ld   [pxh], ac
    add  1, ac
    and  3, ac
    ld   ac, [pxh]
    bne  gm_vert_j
    ld   LINK_LO, x             ; x = 0: a new lap, coins and slimes back
    ld   gm_vert & 0xFF, [x]
    ld   LINK_HI, x
    ld   gm_vert >> 8, [x]
    ld   reset_objs >> 8, y
    jmp  reset_objs
gm_ml:
    ld   [pxl], ac
    sub  1, ac
    ld   ac, [pxl]
    xor  0xFF, ac
    bne  gm_vert_j
    ld   [pxh], ac
    sub  1, ac
    and  3, ac
    ld   ac, [pxh]
    bra  gm_vert_j
gm_block:
    clr  ac
    ld   ac, [moved]
gm_vert_j:
    ld   gm_vert >> 8, y
    jmp  gm_vert''')
    a.end()

    a.sect('game: jumping and falling')
    a.raw('gm_vert:')
    a.begin()
    a.g('''
    ld   [inp], ac              ; jump from the ground
    and  4, ac
    beq  gm_g0
    ld   [onground], ac
    beq  gm_g0
    ld   JUMPV_LO, ac
    ld   ac, [vyl]
    ld   JUMPV_HI, ac
    ld   ac, [vyh]
    ld   72, ac''')
    call('snd_beep', 'gm_js')
    a.g('''
gm_g0:
    ld   [vyl], ac              ; gravity
    add  GRAV, ac
    ld   ac, [vyl]
    ld   [vyh], ac
    bcc  gm_g1
    add  1, ac
gm_g1:
    ld   ac, [vyh]
    blt  gm_g2                  ; going up
    sub  MAXFALL_HI, ac
    bcs  gm_g2
    ld   MAXFALL_HI, ac
    ld   ac, [vyh]
    clr  ac
    ld   ac, [vyl]
gm_g2:
    ld   [pyl], ac              ; y += vy
    add  [vyl], ac
    ld   ac, [pyl]
    ld   [vyh], ac
    blt  gm_up
    ld   [pyh], ac
    bcc  gm_g3
    add  1, ac
gm_g3:
    add  [vyh], ac
    ld   ac, [pyh]
    ld   gm_fall >> 8, y
    jmp  gm_fall
gm_up:
    ld   [pyh], ac              ; (vy < 0: high byte - 1 + carry)
    bcs  gm_g4
    sub  1, ac
gm_g4:
    add  [vyh], ac
    ld   ac, [pyh]
    blt  gm_top                 ; above the screen: stop there
    ld   gm_head >> 8, y
    jmp  gm_head
gm_top:
    clr  ac
    ld   ac, [pyh]
    ld   ac, [pyl]
    ld   ac, [vyl]
    ld   ac, [vyh]
    ld   gm_obj >> 8, y
    jmp  gm_obj''')
    a.end()
    a.begin()
    a.g('''
gm_head:
    ld   [pyh], ac              ; head in a solid tile?
    ld   ac, [ta_g]
    ld   [pxl], ac
    add  1, ac
    ld   ac, [ta_lo]
    ld   [pxh], ac
    bcc  gm_h1
    add  1, ac
gm_h1:
    ld   ac, [ta_hi]''')
    call('tile_at', 'gm_h2')
    a.g('''
    bne  gm_bump
    ld   [ta_lo], ac
    add  5, ac
    ld   ac, [ta_lo]''')
    call('tile_at', 'gm_h3')
    a.g('''
    beq  gm_h4
gm_bump:
    ld   [pyh], ac              ; below that tile
    sub  GROUND_G, ac
    and  0xF0, ac
    add  GROUND_G + 16, ac
    ld   ac, [pyh]
    clr  ac
    ld   ac, [pyl]
    ld   ac, [vyl]
    ld   ac, [vyh]
gm_h4:
    clr  ac
    ld   ac, [onground]
    ld   gm_obj >> 8, y
    jmp  gm_obj''')
    a.end()
    a.begin()
    a.g('''
gm_fall:
    ld   [pyh], ac              ; into the water: a life
    sub  DROWN_G, ac
    bcs  gm_f0
    ld   LINK_LO, x
    ld   gm_obj & 0xFF, [x]
    ld   LINK_HI, x
    ld   gm_obj >> 8, [x]
    ld   lose_life >> 8, y
    jmp  lose_life
gm_f0:
    ld   [pyh], ac              ; feet on a solid tile?
    add  16, ac
    ld   ac, [ta_g]
    ld   [pxl], ac
    add  1, ac
    ld   ac, [ta_lo]
    ld   [pxh], ac
    bcc  gm_f1
    add  1, ac
gm_f1:
    ld   ac, [ta_hi]''')
    a.raw('DROWN_G    = %d' % DROWN_G)
    call('tile_at', 'gm_f2')
    a.g('''
    bne  gm_land
    ld   [ta_lo], ac
    add  5, ac
    ld   ac, [ta_lo]''')
    call('tile_at', 'gm_f3')
    a.g('''
    bne  gm_land
    clr  ac
    ld   ac, [onground]
    ld   gm_obj >> 8, y
    jmp  gm_obj
gm_land:
    ld   [pyh], ac              ; stand on the tile: y = its top - 16
    add  16 - GROUND_G, ac
    and  0xF0, ac
    add  GROUND_G - 16, ac
    ld   ac, [pyh]
    clr  ac
    ld   ac, [pyl]
    ld   ac, [vyl]
    ld   ac, [vyh]
    ld   1, ac
    ld   ac, [onground]
    ld   [pxl], ac              ; checkpoint
    ld   ac, [chk_lo]
    ld   [pxh], ac
    ld   ac, [chk_hi]
    ld   gm_obj >> 8, y
    jmp  gm_obj''')
    a.end()

    a.sect('lose_life: a life (game over: a new game), noise, respawn; returns via LINK')
    a.g('''
lose_life:
    ld   [LINK_LO], ac          ; keep the return address over snd_noise
    ld   ac, [ll_lo]
    ld   [LINK_HI], ac
    ld   ac, [ll_hi]
    ld   1, ac
    ld   ac, [hud_dirty]
    ld   [lives], ac
    sub  1, ac
    ld   ac, [lives]
    bne  ll_1
    ld   3, ac                  ; game over: a new game
    ld   ac, [lives]
    clr  ac
    ld   ac, [score_lo]
    ld   ac, [score_hi]
    ld   ac, [coins]
ll_1:
    ld   8, ac                  ; noise: rumble, 30 frames, fading
    ld   ac, [R0]
    ld   30, ac
    ld   ac, [R2]
    ld   3, ac
    ld   ac, [R3]
    ld   90, ac''')
    call('snd_noise', 'll_2')
    a.g('''
    ld   [ll_lo], ac
    ld   ac, [LINK_LO]
    ld   [ll_hi], ac
    ld   ac, [LINK_HI]
    ld   respawn >> 8, y
    jmp  respawn''')

    # sprite list append: tmp = frame id, dlo = SL_C, tmp3 = SL_G
    a.g('''
sl_add:
    ld   [sl_n], ac
    sub  MAX_SPR, ac
    beq  sa_full
    ld   [sl_n], ac
    add  SL_C, x
    ld   [dlo], ac
    ld   ac, [x]
    ld   [sl_n], ac
    add  SL_G, x
    ld   [tmp3], ac
    ld   ac, [x]
    ld   [tmp], x
    ld   FR_LO >> 8, y
    ld   [y,x], ac
    ld   ac, [tmp2]
    ld   [sl_n], ac
    add  SL_LO, x
    ld   [tmp2], ac
    ld   ac, [x]
    ld   [tmp], x
    ld   FR_HI >> 8, y
    ld   [y,x], ac
    ld   ac, [tmp2]
    ld   [sl_n], ac
    add  SL_HI, x
    ld   [tmp2], ac
    ld   ac, [x]
    ld   [sl_n], ac
    add  1, ac
    ld   ac, [sl_n]
sa_full:
    ld   [LINK_HI], y
    jmp  [LINK_LO]''')

    # objects
    a.sect('game: camera, coins')
    a.raw('gm_obj:')
    a.g('''
    ld   [onground], ac         ; animation: count while running on the ground
    beq  go_a1
    ld   [moved], ac
    beq  go_a1
    ld   [anim], ac
    add  1, ac
    ld   ac, [anim]
go_a1:
    ld   [inv], ac
    beq  go_a2
    sub  1, ac
    ld   ac, [inv]
go_a2:
    ld   [pxl], ac              ; camera: scroll = px - 30 (the player at
    sub  30, ac                 ; screen byte column 30)
    ld   ac, [scl]
    ld   [pxh], ac
    bcc  go_a3
    sub  1, ac
go_a3:
    and  3, ac
    ld   ac, [sch]
    clr  ac
    ld   ac, [sl_n]
    ld   ac, [o_i]
    ld   ac, [danger]''')
    a.g('''
go_c:
    ld   [o_i], x               ; coin o_i: taken?
    ld   COIN_GOT >> 8, y
    ld   [y,x], ac
    beq  go_c0
    ld   go_cn >> 8, y
    jmp  go_cn
go_c0:''')
    a.g(screen_col('OBJ', 'COIN_XL', 'COIN_XH', 'go_cn'))
    a.g('''
    ld   OBJ >> 8, y            ; top cell + 32
    ld   [o_i], ac
    add  COIN_G, x
    ld   [y,x], ac
    add  32, ac
    ld   ac, [tmp3]
    ld   [dlo], ac              ; touching the player?  cx - px = dlo - 38,
    sub  35, ac                 ; in -3..6
    sub  10, ac
    bcc  go_cadd
    ld   [tmp3], ac             ; cg - pyh in -7..15: (cg + 32) - pyh - 25
    sub  [pyh], ac
    sub  25, ac
    sub  23, ac
    bcc  go_cadd
    ld   [o_i], x               ; taken: +10, a beep
    ld   COIN_GOT >> 8, y
    ld   1, [y,x]
    ld   [coins], ac
    add  1, ac
    ld   ac, [coins]
    ld   [score_lo], ac
    add  10, ac
    ld   ac, [score_lo]
    bcc  go_cs
    ld   [score_hi], ac
    add  1, ac
    ld   ac, [score_hi]
go_cs:
    ld   1, ac
    ld   ac, [hud_dirty]
    ld   LINK_LO, x
    ld   go_cn & 0xFF, [x]
    ld   LINK_HI, x
    ld   go_cn >> 8, [x]
    ld   88, ac
    ld   snd_beep >> 8, y
    jmp  snd_beep
go_cadd:
    ld   [FRAME_LO], ac         ; frame: coin1-4, a step every 8 frames
    shr  ac
    shr  ac
    shr  ac
    and  3, ac
    add  FID_COIN, ac
    ld   ac, [tmp]''')
    call('sl_add', 'go_ca1')
    a.g('''
go_cn:
    ld   [o_i], ac
    add  1, ac
    ld   ac, [o_i]
    sub  N_COINS, ac
    beq  go_cd
    ld   go_c >> 8, y
    jmp  go_c
go_cd:
    clr  ac
    ld   ac, [o_i]
    ld   go_e >> 8, y
    jmp  go_e''')

    a.sect('game: slimes')
    a.raw('go_e:')
    a.g('''
    ld   ENEMY >> 8, y          ; alive?
    ld   [o_i], ac
    add  0x40, x
    ld   [y,x], ac
    bne  go_e1
    ld   go_en >> 8, y
    jmp  go_en
go_e1:
    ld   [FRAME_LO], ac         ; move a byte every other frame
    and  1, ac
    beq  go_e5
    ld   [o_i], ac
    add  0x18, x
    ld   [y,x], ac              ; direction 0 right, 1 left
    bne  go_el
    ld   [o_i], x               ; right: x + 1
    ld   [y,x], ac
    add  1, ac
    ld   ac, [y,x]
    bne  go_e2
    ld   [o_i], ac
    add  8, x
    ld   [y,x], ac
    add  1, ac
    and  3, ac
    ld   ac, [y,x]
go_e2:
    ld   [o_i], ac              ; at the right end: turn
    add  0x30, x
    ld   [y,x], ac
    ld   ac, [tmp]
    ld   [o_i], x
    ld   [y,x], ac
    sub  [tmp], ac
    bne  go_e5
    ld   [o_i], ac
    add  0x18, x
    ld   1, [y,x]
    bra  go_e5
go_el:
    ld   [o_i], x               ; left: x - 1
    ld   [y,x], ac
    sub  1, ac
    ld   ac, [y,x]
    xor  0xFF, ac
    bne  go_e3
    ld   [o_i], ac
    add  8, x
    ld   [y,x], ac
    sub  1, ac
    and  3, ac
    ld   ac, [y,x]
go_e3:
    ld   [o_i], ac              ; at the left end: turn
    add  0x20, x
    ld   [y,x], ac
    ld   ac, [tmp]
    ld   [o_i], x
    ld   [y,x], ac
    sub  [tmp], ac
    bne  go_e5
    ld   [o_i], ac
    add  0x18, x
    ld   0, [y,x]
go_e5:''')
    a.begin()
    a.g(screen_col('ENEMY', '0', '8', 'go_en'))
    a.g('''
    ld   ENEMY >> 8, y          ; top cell + 32
    ld   [o_i], ac
    add  0x10, x
    ld   [y,x], ac
    add  32, ac
    ld   ac, [tmp3]
    sub  [pyh], ac              ; eg - pyh, in tmp2
    sub  32, ac
    ld   ac, [tmp2]
    ld   [dlo], ac              ; ahead of the player (4-24 bytes) at about
    sub  42, ac                 ; the same height: danger, for the demo
    sub  21, ac
    bcc  go_e6
    ld   [tmp2], ac
    add  15, ac
    sub  31, ac
    bcc  go_e6
    ld   1, ac
    ld   ac, [danger]
go_e6:
    ld   [inv], ac              ; touching the player?  ex - px in -6..6
    bne  go_eadd
    ld   [dlo], ac
    sub  32, ac
    sub  13, ac
    bcc  go_eadd
    ld   [tmp2], ac             ; eg - pyh in -14..14
    add  14, ac
    sub  29, ac
    bcc  go_eadd
    ld   go_hit >> 8, y
    jmp  go_hit''')
    a.g('''
go_eadd:
    ld   [FRAME_LO], ac         ; slime1 / slime2, 16 frames each
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    and  1, ac
    add  FID_SLIME, ac
    ld   ac, [tmp]''')
    call('sl_add', 'go_ea1')
    a.end()
    a.g('''
go_en:
    ld   [o_i], ac
    add  1, ac
    ld   ac, [o_i]
    sub  N_SLIMES, ac
    beq  go_pl_j
    ld   go_e >> 8, y
    jmp  go_e
go_pl_j:
    ld   go_pl >> 8, y
    jmp  go_pl''')

    a.sect('game: a slime touches the player; the player into the list')
    a.g('''
go_hit:
    ld   [vyh], ac              ; falling and feet in its top half: stomp
    blt  go_hurt
    ld   [tmp2], ac             ; eg - pyh >= 8
    sub  8, ac
    blt  go_hurt
    ld   ENEMY >> 8, y
    ld   [o_i], ac
    add  0x40, x
    ld   0, [y,x]
    ld   0xFD, ac               ; bounce up
    ld   ac, [vyh]
    clr  ac
    ld   ac, [vyl]
    ld   [score_lo], ac         ; +100
    add  100, ac
    ld   ac, [score_lo]
    bcc  go_h1
    ld   [score_hi], ac
    add  1, ac
    ld   ac, [score_hi]
go_h1:
    ld   1, ac
    ld   ac, [hud_dirty]
    ld   LINK_LO, x
    ld   go_en & 0xFF, [x]
    ld   LINK_HI, x
    ld   go_en >> 8, [x]
    ld   60, ac
    ld   snd_beep >> 8, y
    jmp  snd_beep
go_hurt:
    ld   LINK_LO, x
    ld   go_eadd & 0xFF, [x]
    ld   LINK_HI, x
    ld   go_eadd >> 8, [x]
    ld   lose_life >> 8, y
    jmp  lose_life''')
    a.begin()
    a.g('''
go_pl:
    ld   [inv], ac              ; the player last (blinks while safe)
    and  4, ac
    bne  go_done
    ld   38, ac                 ; byte column 30 + 8
    ld   ac, [dlo]
    ld   [pyh], ac
    add  32, ac
    ld   ac, [tmp3]
    ld   [onground], ac         ; frame: jump, run 1-3, stand
    bne  go_p1
    ld   4, ac
    bra  go_p3
go_p1:
    ld   [moved], ac
    beq  go_p3
    ld   [anim], ac             ; run: 1, 2, 3, 2 a step every 4 frames
    shr  ac
    shr  ac
    and  3, ac
    ld   ac, x
    ld   RUNSEQ >> 8, y
    ld   [y,x], ac
go_p3:
    add  [facing], ac
    ld   ac, [tmp]''')
    call('sl_add', 'go_p4')
    a.g('''
go_done:
    ld   lib_leave >> 8, y
    jmp  lib_leave''')
    a.end()

    # ------------------------------------------------------------ hud
    a.sect('hud: score line when it changed, CPU load every 16 frames')
    a.raw('hud:')
    a.g('''
    ld   [SP], x                ; PUSH_LINK
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, x
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, [SP]
    ld   [hud_dirty], ac
    bne  hu_s
    ld   hu_cpu >> 8, y
    jmp  hu_cpu
hu_s:
    clr  ac
    ld   ac, [hud_dirty]
    ld   6, ac                  ; score at column 6
    ld   ac, [CUR_COL]
    ld   1, ac
    ld   ac, [CUR_ROW]
    ld   [score_lo], ac
    ld   ac, [R0]
    ld   [score_hi], ac
    ld   ac, [R1]''')
    call('con_dec16', 'hu_1')
    a.g('''
    ld   s_sp >> 8, ac
    ld   ac, [R1]
    ld   s_sp, ac
    ld   ac, [R0]''')
    call('con_puts', 'hu_2')
    a.g('''
    ld   22, ac                 ; coins at column 22
    ld   ac, [CUR_COL]
    ld   [coins], ac''')
    call('con_dec8', 'hu_3')
    a.g('''
    ld   s_sp >> 8, ac
    ld   ac, [R1]
    ld   s_sp, ac
    ld   ac, [R0]''')
    call('con_puts', 'hu_4')
    a.g('''
    ld   37, ac                 ; lives at column 37
    ld   ac, [CUR_COL]
    ld   [lives], ac''')
    call('con_dec8', 'hu_5')
    a.g('''
    ld   56, ac                 ; demo / player at column 56
    ld   ac, [CUR_COL]
    ld   s_demo, ac
    ld   ac, [R0]
    ld   [demo], ac
    bne  hu_6
    ld   s_you, ac
    ld   ac, [R0]
hu_6:
    ld   s_demo >> 8, ac
    ld   ac, [R1]''')
    call('con_puts', 'hu_7')
    a.g('''
hu_cpu:
    ld   [hud_div], ac          ; CPU load every 16 frames:
    sub  1, ac                  ; busy % = 100 - polls / POLLS_PER_PCT
    ld   ac, [hud_div]
    beq  hu_c0
    ld   lib_leave >> 8, y
    jmp  lib_leave
hu_c0:
    ld   16, ac
    ld   ac, [hud_div]
    ld   100, ac
    ld   ac, [tmp3]
hu_c1:
    ld   [it_lo], ac            ; polls - POLLS_PER_PCT until it goes below 0
    sub  POLLS_PER_PCT, ac
    ld   ac, [it_lo]
    ld   [it_hi], ac
    bcc  hu_c2
    sub  1, ac
    ld   ac, [it_hi]
    blt  hu_c3
hu_c2:
    ld   [tmp3], ac
    sub  1, ac
    ld   ac, [tmp3]
    beq  hu_c3
    bra  hu_c1
hu_c3:
    ld   10, ac
    ld   ac, [CUR_COL]
    ld   3, ac
    ld   ac, [CUR_ROW]
    ld   [tmp3], ac''')
    call('con_dec8', 'hu_8')
    a.g('''
    ld   s_pct >> 8, ac
    ld   ac, [R1]
    ld   s_pct, ac
    ld   ac, [R0]''')
    call('con_puts', 'hu_9')
    a.jump('lib_leave')

    # ------------------------------------------------------------ text
    def txt(label, text):
        a.raw('%-8s #d "%s", 0x00' % (label + ':', text))
        a.addr += len(text) + 1

    a.sect('text', align=True)
    txt('s_demo', "DEMO PLAYER")
    txt('s_you', "YOU PLAY   ")
    txt('s_title', "PLACARD RUNNER   160 X 112, 16 COLORS, 4 PARALLAX LAYERS, ALL SPRITES IN SOFTWARE")
    txt('s_score', "SCORE 0          COINS 0        LIVES 3")
    txt('s_keys', "ARROWS OR SNES PAD: RUN LEFT/RIGHT, UP/SPACE/B JUMP.  STOMP THE SLIMES")
    txt('s_cpu', "CPU BUSY     (WHOLE SCREEN REDRAWN EVERY FRAME, AHEAD OF THE BEAM)")
    txt('s_sp', "  ")
    txt('s_pct', "% ")

    # ------------------------------------------------------------ strips
    a.sect('strips: unrolled column stores (enter with Y = strip page, return via rl/rh)', align=True)
    bs_addr = {}           # (band, w) -> address
    ts_addr = {}           # (row, tile, j) -> address
    cache = {}
    labels = {}

    def strip(rows_vals, label):
        key = tuple(rows_vals)
        if key in cache:
            return cache[key]
        lines = ['%s:' % label, '    ld   [colpage], y']
        for g, v in rows_vals:
            lines.append('    ld   0x%02X, x\n    ld   0x%02X, [y,x]' % (row_x(g), v))
        lines.append('    ld   [rh], y\n    jmp  [rl]')
        here = a.addr
        for ln in lines:
            a.raw(ln)
        a.addr += Asm.size(lines)
        cache[key] = here
        labels[label] = here
        return here

    st_rows = []
    for name, g0, g1, sh in BANDS:
        for g, v in sorted(STATIC[name].items()):
            st_rows.append((g, v))
    strip(st_rows, 'strip_static')
    n = 0
    for name, g0, g1, sh in BANDS:
        for w in range(BAND_W):
            rv = [(g, BANDPIX[name][w][g - g0]) for g in range(g0, g1) if g not in STATIC[name]]
            bs_addr[(name, w)] = strip(rv, 'bs_%d' % n)
            n += 1
    for r in range(3):
        for ch in sorted(set(TROWS[r])):
            tb = tile_bytes(ch)
            for j in range(8):
                rv = [(GROUND_G + 16 * r + k, tb[j][k]) for k in range(16)]
                ts_addr[(r, ch, j)] = strip(rv, 'ts_%d' % n)
                n += 1
    strips_end = a.addr

    # ------------------------------------------------------------ tables
    tb = (a.addr + 255) & 0xFF00
    for i, n in enumerate(['BS_LO', 'BS_HI', 'TS_LO', 'TS_HI', 'LV0', 'LV1', 'LV2', 'SOLID',
                           'FR_LO', 'FR_HI', 'OBJ', 'MISC']):
        pages[n] = tb + i * 0x100
        a.raw('%-10s = 0x%04X' % (n, pages[n]))
    a.addr = tb + 12 * 0x100

    def page(name, vals, comment):
        vals = list(vals) + [0] * (256 - len(vals))
        data_page(a, pages[name], vals, comment)
    bs_lo, bs_hi = [0] * 256, [0] * 256
    for bi, (name, g0, g1, sh) in enumerate(BANDS):
        for w in range(BAND_W):
            ad = bs_addr[(name, w)]
            bs_lo[64 * bi + w] = ad & 255
            bs_hi[64 * bi + w] = ad >> 8
    page('BS_LO', bs_lo, 'BS_LO: band strip addresses (band * 64 + column)')
    page('BS_HI', bs_hi, 'BS_HI')
    ts_lo, ts_hi = [0] * 256, [0] * 256
    for r in range(3):
        for ch in sorted(set(TROWS[r])):
            for j in range(8):
                ad = ts_addr[(r, ch, j)]
                i = 64 * r + 8 * TID[ch] + j
                ts_lo[i], ts_hi[i] = ad & 255, ad >> 8
    page('TS_LO', ts_lo, 'TS_LO: tile strips (row * 64 + tile * 8 + byte)')
    page('TS_HI', ts_hi, 'TS_HI')
    for r in range(3):
        page('LV%d' % r, [64 * r + 8 * TID[ch] for ch in TROWS[r]], 'LV%d: level tile row %d (row * 64 + tile * 8)' % (r, r))
    solid = [0] * 256
    for r in range(3):
        for ch in TILE_LIST:
            solid[64 * r + 8 * TID[ch]] = 1 if ch in SOLID_TILES else 0
    page('SOLID', solid, 'SOLID: 1 for a solid tile (index from LVn)')
    page('FR_LO', [BLIT_SYMS['spr_' + nm] & 255 for nm, _ in FRAMES], 'FR_LO: sprite routines (RAM)')
    page('FR_HI', [BLIT_SYMS['spr_' + nm] >> 8 for nm, _ in FRAMES], 'FR_HI')
    page('MISC', [1, 2, 3, 2], 'MISC: RUNSEQ, the run frames')
    a.raw('RUNSEQ     = MISC')
    a.raw('FID_COIN   = %d' % FRAME_ID['coin1'])
    a.raw('FID_SLIME  = %d' % FRAME_ID['slime1'])
    # OBJ page: slime init (x00-x7F, copied to ENEMY), coins (x80-)
    obj = [0] * 256
    for i, s in enumerate(SLIMES_L):
        obj[0x00 + i] = s['x'] & 255
        obj[0x08 + i] = s['x'] >> 8
        obj[0x10 + i] = s['g']
        obj[0x18 + i] = 0
        obj[0x20 + i] = s['lo'] & 255
        obj[0x28 + i] = s['lo'] >> 8
        obj[0x30 + i] = s['hi'] & 255
        obj[0x38 + i] = s['hi'] >> 8
        obj[0x40 + i] = 1
    assert len(SLIMES_L) <= 8 and len(COINS_L) <= 40
    for i, (x, g) in enumerate(COINS_L):
        obj[0x80 + i] = x & 255
        obj[0xA8 + i] = x >> 8
        obj[0xD0 + i] = g
    page('OBJ', obj, 'OBJ: slimes x00-x7F (x lo, hi, top cell, direction, bounds, alive),'
         ' coins x80 (x lo), xA8 (x hi), xD0 (top cell)')
    a.raw('COIN_XL    = 0x80')
    a.raw('COIN_XH    = 0xA8')
    a.raw('COIN_G     = 0xD0')
    # the RAM blitter as data
    top = max(BLIT_MEM) + 1
    npages = (top - 0x100 + 255) // 256
    blit_rom = a.addr
    a.raw('')
    a.raw('BLIT_ROM   = 0x%04X       ; the RAM blitter (x0100-x%04X), copied at start' % (blit_rom, top - 1))
    a.raw('BLIT_PAGES = %d' % npages)
    a.raw('#addr 0x%04X' % blit_rom)
    data = [BLIT_MEM.get(0x100 + i, 0) for i in range(npages * 256)]
    for i in range(0, len(data), 16):
        a.raw('    #d8 ' + ', '.join('0x%02X' % v for v in data[i:i + 16]))
    assert blit_rom + len(data) <= 0xE000, hex(blit_rom + len(data))
    a.raw('POLLS_PER_PCT = %d' % POLLS_PER_PCT)
    return '\n'.join(a.out) + '\n', dict(strips_end=strips_end, blit_end=blit_rom + len(data), labels=labels)


POLLS_PER_PCT = 51      # frame_poll loops in 1 % of a frame (4,200 clocks; measured)


def preview(path, scroll=0):
    mem = bytearray(65536)
    for a, v in background(scroll).items():
        mem[a] = v
    for g in range(NROW):
        mem[0x5A20 + 32 + 4 * g: 0x5A20 + 36 + 4 * g] = bytes([MODE_PF] * 4)
    sprites = [(FRAME_ID['R_run1'], 38, 32 + 80), (FRAME_ID['slime1'], 70, 32 + 80),
               (FRAME_ID['coin1'], 50, 32 + 70)]
    draw_sprites_model(mem, sprites)
    ps.render(mem, path)


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('-o', default=os.path.join(HERE, 'scroller.asm'))
    ap.add_argument('--preview')
    ap.add_argument('--scroll', type=int, default=0)
    args = ap.parse_args(argv)
    src, info = gen()
    open(args.o, 'w', newline='\n').write(src)
    mem, syms, _ = ps.assemble(src, HERE)
    for k, v in info['labels'].items():
        assert syms[k] == v, (k, hex(syms[k]), hex(v))
    for t in ('s_title', 's_score', 's_keys', 's_cpu'):
        pass
    print('wrote %s: %d bytes; strips end %04X, blitter %d bytes (x0100-x%04X)'
          % (args.o, len(mem), info['strips_end'], max(BLIT_MEM) - 0xFF, max(BLIT_MEM)))
    if args.preview:
        preview(args.preview, args.scroll)
        print('wrote', args.preview)


if __name__ == '__main__':
    main(sys.argv[1:])

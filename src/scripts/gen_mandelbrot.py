#!/usr/bin/env python3
"""
gen_mandelbrot.py - generate mandelbrot.asm, a Mandelbrot set demo / benchmark
for the Placard CPU that draws the set once in each of the four video modes.

    python3 gen_mandelbrot.py                   writes mandelbrot.asm and .hex next to this script
    python3 gen_mandelbrot.py --once --delay 0 -o m.asm
                                                a build for the simulator: no pauses,
                                                halts after the 8 bpp pass
    python3 placard_sim.py mandelbrot.asm --run --max-steps 2000000000 --png m.png

Then merge mandelbrot.hex into video_ram.mem with gen_video_ram.tcl (set
::ASM_FILE to mandelbrot.hex) to run it on the board.

SEQUENCE (repeats forever)
    1 bpp -> 2 bpp -> 4 bpp -> 8 bpp.  Each pass is timed, and when it
    finishes the time "SSS.SSS s" is shown in a black 1 bpp band across the
    middle of the screen (rows 232-247), then the program pauses about 5 s.
    The screen is cleared (and every mode byte set) before each pass.

    mode    points      screen pixels per point   colors
    1 bpp   632 x 480   1 x 1                     2   (iteration bands)
    2 bpp   316 x 240   2 x 2                     4
    4 bpp   158 x 120   4 x 4                     16
    8 bpp    79 x  60   8 x 8                     256 (hue wheel)
    All four show the same view:
        real axis       -2.0 .. +0.47
        imaginary axis  -0.94 .. +0.94
    Up to MAXIT iterations per point; points that never escape are black.

ARITHMETIC
    The CPU has no carry flag and no multiply, so the program uses:
      - fixed point with 8 fraction bits (1.0 = 256), in every mode; the
        coarser modes just step c by 2, 4 or 8 units per point
      - z = (x, y) kept as magnitude + sign; |x|, |y| < 2 means each
        magnitude is under 512
      - squares from a table:  x*x, y*y and (x+y)^2, then
            x' = x*x - y*y + cx
            y' = (x+y)^2 - x*x - y*y + cy     (= 2xy + cy)
      - values in "base 128": value = hi * 128 + lo, lo = 0..127, hi
        signed.  A carry or borrow out of lo shows up as bit 7, which is
        the N flag, so it can be tested with a branch.  The square table
        is indexed the same way: page = table + hi, X = lo.
    Escape when x*x + y*y >= 4, or when |x'| or |y'| >= 2.

TIMER (the same as gen_pi_spigot.py)
    The line read at 5000h (V9:V2 of the line counter, 124-255) is polled
    once per video byte written; a poll that sees the value go down adds
    one frame (16800 us at 25.000 MHz) to a 9 digit decimal count of
    microseconds at 0050-0058.  The timer starts at the top of a frame just
    after the screen clear, and stops when the last byte is written, adding
    128 us for each step of the line read since the top of that frame.
    Resolution 128 us.  The pause is a calibrated delay loop, not the timer.

RESULT (placard_sim.py, State PLD rev 12 / Branch PLD rev 09 timing, no
video stalls; every pass matches a Python model pixel for pixel outside the
time band, and the time shown matches the simulated time to 128 us)
    mode    timed clocks    shown on screen   on the board, with video
    1 bpp   2,035,644,487    81.425 s          about 89.6 s   stalls (1 clock
    2 bpp     510,448,188    20.418 s          about 22.5 s   in 8 during
    4 bpp     128,719,100     5.148 s          about  5.7 s   active video)
    8 bpp      32,697,831     1.307 s          about  1.4 s
    The four screens are reference/mandelbrot_sim.png (1, 2 / 4, 8 bpp).

MEMORY
    0000-0003   reset: jump to main
    0010-004F   variables (zero page)
    0050-0058   timer, decimal microseconds, least significant digit first
    0060-0068   one frame (16800) as decimal digits, 0070-0078 one step (128)
    0080-00E7   font: 0-9, ".", space, "s"
    0100-1EFF   code, one block per page
    1F00        color tables, 64 entries per mode, indexed by iterations left
    2000-27FF   square table low limbs  (k = 0..1023: page 20 + k/128, X = k%128)
    2800-2FFF   square table high limbs (page 28 + k/128)
    4A20-4BFF   mode bytes, one per row
    6000-FFFF   video RAM

Date: 10/16/2026
"""

import argparse
import colorsys
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from placard_sim import assemble, instr_size, to_hexstr   # noqa: E402

MAXIT = 32
F = 8                       # fraction bits
SQL_PG, SQH_PG = 0x20, 0x28
COL_PG = 0x1F
CODE_PG = 0x01

CLOCK_HZ = 25.17483e6
CPU_SHARE = 1 - 38400 / 420000      # video steals 1 clock in 8 during active video

ZP = {}
for _i, _n in enumerate([
        'axl', 'axh', 'sx', 'ayl', 'ayh', 'sy', 'xxl', 'xxh', 'yyl', 'yyh',
        'tl', 'th', 'dl', 'dh', 'nxl', 'nxh', 'nyl', 'nyh', 'sl', 'sh',
        'pl', 'ph', 'cxl', 'cxh', 'cyl', 'cyh', 'it', 'coff', 'ret', 'reth',
        'cxl0', 'cxh0', 'pix', 'col', 'cnt', 'rowx', 'rowy', 'vpage', 'bcnt',
        'mode', 'tmp', 'dl2', 'dl3', 'pret', 'preth',
        'cur', 'last', 'wrapped', 'doff', 'dc', 'ds', 'tret', 'treth',
        'dret', 'dreth', 'gret', 'greth', 'sx2', 'gx', 'gsx', 'cpg', 'crow',
        'dig']):
    ZP[_n] = 0x10 + _i


def z(n):
    return '[0x%02X]' % ZP[n]


# timer (as in gen_pi_spigot.py): 9 decimal digits of microseconds, least
# significant first, and the two addends: one frame (525 lines x 32 us =
# 16800 us at 25.000 MHz) and one step of the line read (4 lines = 128 us)
TU, FR, PT = 0x50, 0x60, 0x70
FRAME_US, STEP_US = 16800, 128
LINE0 = 124             # line read value at the top of the frame (V = 499)

# the time is shown in a 1 bpp band across the middle of the screen
BAND_ROW0, BAND_ROWS = 232, 16      # screen rows 232-247
TEXT_ROW = 236                      # glyph rows 236-243
TCOL = 36                           # "SSS.SSS s", columns 36-44 of 1-79

FONT_LO = 0x80                      # font in the top of zero page
FONT = {
    0: [0x70, 0x88, 0x98, 0xA8, 0xC8, 0x88, 0x70, 0x00],
    1: [0x20, 0x60, 0x20, 0x20, 0x20, 0x20, 0x70, 0x00],
    2: [0x70, 0x88, 0x08, 0x10, 0x20, 0x40, 0xF8, 0x00],
    3: [0xF8, 0x10, 0x20, 0x10, 0x08, 0x88, 0x70, 0x00],
    4: [0x10, 0x30, 0x50, 0x90, 0xF8, 0x10, 0x10, 0x00],
    5: [0xF8, 0x80, 0xF0, 0x08, 0x08, 0x88, 0x70, 0x00],
    6: [0x30, 0x40, 0x80, 0xF0, 0x88, 0x88, 0x70, 0x00],
    7: [0xF8, 0x08, 0x10, 0x20, 0x40, 0x40, 0x40, 0x00],
    8: [0x70, 0x88, 0x88, 0x70, 0x88, 0x88, 0x70, 0x00],
    9: [0x70, 0x88, 0x88, 0x78, 0x08, 0x10, 0x60, 0x00],
    10: [0x00, 0x00, 0x00, 0x00, 0x00, 0x60, 0x60, 0x00],    # .
    11: [0x00] * 8,                                            # space
    12: [0x00, 0x00, 0x78, 0x80, 0x70, 0x08, 0xF0, 0x00],    # s
}


# 4 bpp: 0-7 = R G B bits at full level, 8-15 = the same at half level
# plus 50% grey.  Indexed by iterations done before escape.
COLOR4 = [4, 12, 6, 14, 2, 10, 3, 11, 1, 9, 5, 13, 7, 15, 8, 4]
COLOR2 = [1, 2, 3]          # blue, gold, white


def color8(n):
    """hue wheel in the 8 bpp format G3G2G1 B3B2 R3R2R1"""
    r, gg, b = colorsys.hsv_to_rgb((n % 16) / 16.0, 1.0, 1.0)
    return (round(gg * 7) << 5) | (round(b * 3) << 3) | round(r * 7)


def color_for(mode, n):
    """color of a point that escaped after n iterations (n >= 1)"""
    if mode == 0:
        return n & 1
    if mode == 1:
        return COLOR2[(n - 1) % 3]
    if mode == 2:
        return COLOR4[(n - 1) % 16]
    return color8(n - 1)


class Gen:
    def __init__(self):
        self.blocks = []
        self.cur = None
        self.n = 0

    def block(self, name):
        self.cur = []
        self.blocks.append((name, self.cur))

    def e(self, s):
        self.cur.append('    ' + s)

    def label(self, s):
        self.cur.append(s + ':')

    def uniq(self, p):
        self.n += 1
        return '%s_%d' % (p, self.n)

    def st(self, v, name):
        self.e('ld   0x%02X, ac' % (v & 0xFF))
        self.e('ld   ac, %s' % z(name))

    def far(self, target):
        self.e('ld   %s >> 8, y' % target)
        self.e('jmp  %s' % target)

    def call(self, target, slot='ret'):
        r = self.uniq('ret')
        self.e('ld   %s, ac' % r)
        self.e('ld   ac, %s' % z(slot))
        self.e('ld   %s >> 8, ac' % r)
        self.e('ld   ac, %s' % z(slot + 'h'))
        self.far(target)
        self.label(r)

    # ---------------- base-128 arithmetic ----------------
    def add128(self, r, a, b):
        """r = a + b; leaves r hi in AC"""
        e = self.e
        nc, done = self.uniq('nc'), self.uniq('ad')
        e('ld   %s, ac' % z(a + 'l'))
        e('add  %s, ac' % z(b + 'l'))
        e('bge  %s' % nc)
        e('and  0x7F, ac')
        e('ld   ac, %s' % z(r + 'l'))
        e('ld   %s, ac' % z(a + 'h'))
        e('add  %s, ac' % z(b + 'h'))
        e('inc')
        e('bra  %s' % done)
        self.label(nc)
        e('ld   ac, %s' % z(r + 'l'))
        e('ld   %s, ac' % z(a + 'h'))
        e('add  %s, ac' % z(b + 'h'))
        self.label(done)
        e('ld   ac, %s' % z(r + 'h'))

    def sub128(self, r, a, b):
        """r = a - b; leaves r hi in AC"""
        e = self.e
        nb, done = self.uniq('nb'), self.uniq('sd')
        e('ld   %s, ac' % z(a + 'l'))
        e('sub  %s, ac' % z(b + 'l'))
        e('bge  %s' % nb)
        e('and  0x7F, ac')
        e('ld   ac, %s' % z(r + 'l'))
        e('ld   %s, ac' % z(a + 'h'))
        e('sub  %s, ac' % z(b + 'h'))
        e('dec')
        e('bra  %s' % done)
        self.label(nb)
        e('ld   ac, %s' % z(r + 'l'))
        e('ld   %s, ac' % z(a + 'h'))
        e('sub  %s, ac' % z(b + 'h'))
        self.label(done)
        e('ld   ac, %s' % z(r + 'h'))

    def square(self, r, k):
        """r = k*k / 256 from the table; k is a base-128 magnitude"""
        e = self.e
        e('ld   %s, x' % z(k + 'l'))
        e('ld   %s, ac' % z(k + 'h'))
        e('add  0x%02X, y' % SQL_PG)
        e('ld   [y,x], ac')
        e('ld   ac, %s' % z(r + 'l'))
        e('ld   %s, ac' % z(k + 'h'))
        e('add  0x%02X, y' % SQH_PG)
        e('ld   [y,x], ac')
        e('ld   ac, %s' % z(r + 'h'))

    def to_signmag(self, src, mag, sign, esc):
        """base-128 src -> magnitude (base 128) + sign; branch to esc if |src| >= 2"""
        e = self.e
        neg, nb, mh, done = [self.uniq(s) for s in ('neg', 'nb', 'mh', 'sm')]
        lim = 1 << (F + 1 - 7)          # |value| < 2.0 -> hi < lim
        e('ld   %s, ac' % z(src + 'h'))
        e('blt  %s' % neg)
        e('sub  %d, ac' % lim)
        e('bge  %s' % esc)
        e('ld   %s, ac' % z(src + 'l'))
        e('ld   ac, %s' % z(mag + 'l'))
        e('ld   %s, ac' % z(src + 'h'))
        e('ld   ac, %s' % z(mag + 'h'))
        e('clr  ac')
        e('ld   ac, %s' % z(sign))
        e('bra  %s' % done)
        self.label(neg)
        e('clr  ac                    ; magnitude = 0 - value')
        e('sub  %s, ac' % z(src + 'l'))
        e('bge  %s' % nb)
        e('and  0x7F, ac')
        e('ld   ac, %s' % z(mag + 'l'))
        e('clr  ac')
        e('sub  %s, ac' % z(src + 'h'))
        e('dec')
        e('bra  %s' % mh)
        self.label(nb)
        e('ld   ac, %s' % z(mag + 'l'))
        e('clr  ac')
        e('sub  %s, ac' % z(src + 'h'))
        self.label(mh)
        e('ld   ac, %s' % z(mag + 'h'))
        e('sub  %d, ac' % lim)
        e('bge  %s' % esc)
        e('ld   1, ac')
        e('ld   ac, %s' % z(sign))
        self.label(done)


def delay_counts(seconds):
    """three nested down-counters; the inner loop is nop / dec / bne = 9 clocks
    (dec is a SUB to AC, which takes the ALU wait clock)"""
    if seconds <= 0:
        return None
    clocks = seconds * CLOCK_HZ * CPU_SHARE
    inner = 256 * 9 + 16                # one middle pass
    middle = 256 * inner + 16           # one outer pass
    outer = max(1, min(256, round(clocks / middle)))
    return outer % 256


def build(once, delay, out_path=None):
    g = Gen()
    e, label = g.e, g.label

    # ------------------------------------------------------------ main
    g.block('main')
    label('main')
    for m in range(4):
        e('; ---- pass %d: %d bpp ----' % (m, 1 << m))
        g.st(m, 'mode')
        g.call('pass%d' % m)
        g.call('tshow')
        if m < 3 or not once:
            g.call('delay')
    if once:
        label('halt')
        e('bra  halt')
    else:
        g.far('main')

    # ------------------------------------------------------------ clear screen
    g.block('clear')
    label('clear')
    e('; video RAM 6000-FFFF = 0, then mode byte = [mode] for rows 4A20-4BFF')
    g.st(0x60, 'tmp')
    label('clr_pg')
    e('ld   %s, y' % z('tmp'))
    e('clr  x')
    label('clr_b')
    e('ld   0x00, [y,x]')
    e('ld   x, ac')
    e('inc')
    e('ld   ac, x')
    e('bne  clr_b')
    e('ld   %s, ac' % z('tmp'))
    e('inc')
    e('ld   ac, %s' % z('tmp'))
    e('bne  clr_pg')
    e('ld   0x4A, y')
    e('ld   0x20, x')
    label('mode0')
    e('ld   %s, ac' % z('mode'))
    e('ld   ac, [y,x]')
    e('ld   x, ac')
    e('inc')
    e('ld   ac, x')
    e('bne  mode0')
    e('ld   0x4B, y')
    label('mode1')
    e('ld   %s, ac' % z('mode'))
    e('ld   ac, [y,x]')
    e('ld   x, ac')
    e('inc')
    e('ld   ac, x')
    e('bne  mode1')
    e('ld   %s, y' % z('reth'))
    e('jmp  %s' % z('ret'))

    # ------------------------------------------------------------ delay
    g.block('delay')
    label('delay')
    cnt = delay_counts(delay)
    if cnt is not None:
        e('; about %g s at %.3f MHz, less the video stalls' % (delay, CLOCK_HZ / 1e6))
        g.st(cnt, 'dl3')
        label('dly3')
        g.st(0, 'dl2')
        label('dly2')
        e('clr  ac')
        label('dly1')
        e('nop')
        e('dec')
        e('bne  dly1')
        e('ld   %s, ac' % z('dl2'))
        e('dec')
        e('ld   ac, %s' % z('dl2'))
        e('bne  dly2')
        e('ld   %s, ac' % z('dl3'))
        e('dec')
        e('ld   ac, %s' % z('dl3'))
        e('bne  dly3')
    e('ld   %s, y' % z('reth'))
    e('jmp  %s' % z('ret'))

    # ------------------------------------------------------------ one pass per mode
    # The return address of a pass is kept in pret/preth while the kernel
    # uses ret/reth.
    for m in range(4):
        bpp = 1 << m
        ppb = 8 // bpp          # points per byte
        w = 8 // ppb            # screen pixels per point (and c step, 1/256 units)
        g.block('pass%d' % m)
        label('pass%d' % m)
        e('; %d bpp: %d points per byte, %d x %d pixels per point' % (bpp, ppb, w, w))
        e('ld   %s, ac' % z('ret'))
        e('ld   ac, %s' % z('pret'))
        e('ld   %s, ac' % z('reth'))
        e('ld   ac, %s' % z('preth'))
        g.call('clear')
        g.call('tstart')
        g.st(64 * m, 'coff')
        g.st(0x62, 'vpage')              # byte column 1 = 0x6220
        e('; cx = -2.0 = -512 = (hi -4, lo 0)')
        g.st(-4, 'cxh0')
        g.st(0, 'cxl0')
        g.st(79, 'bcnt')
        label('col%d' % m)
        e('ld   %s, ac' % z('vpage'))
        e('ld   ac, %s' % z('rowy'))
        g.st(0x20, 'rowx')
        e('; cy = -240/256 = (hi -2, lo 16)')
        g.st(-2, 'cyh')
        g.st(16, 'cyl')
        label('row%d' % m)
        e('ld   %s, ac' % z('cxl0'))
        e('ld   ac, %s' % z('cxl'))
        e('ld   %s, ac' % z('cxh0'))
        e('ld   ac, %s' % z('cxh'))
        g.st(0, 'pix')
        g.st(ppb, 'cnt')
        label('pt%d' % m)
        g.call('kernel')
        e('ld   ac, %s' % z('col'))
        if ppb > 1:
            e('ld   %s, ac' % z('pix'))
            for _ in range(bpp):
                e('shr  ac')
            e('or   %s, ac' % z('col'))
        e('ld   ac, %s' % z('pix'))
        if ppb > 1:
            e('; next point: cx lo is a multiple of 8 plus < 8, never carries')
            e('ld   %s, ac' % z('cxl'))
            e('add  %d, ac' % w)
            e('ld   ac, %s' % z('cxl'))
            e('ld   %s, ac' % z('cnt'))
            e('dec')
            e('ld   ac, %s' % z('cnt'))
            e('bne  pt%d' % m)
        e('; write the byte to %d screen row(s)' % w)
        if ppb > 1:
            e('ld   %s, ac' % z('pix'))
        e('ld   %s, x' % z('rowx'))
        e('ld   %s, y' % z('rowy'))
        for r in range(w):
            if r:
                e('ld   %s, ac' % z('pix'))
            e('ld   ac, [y,x]')
            e('ld   x, ac')
            e('inc')
            e('ld   ac, x')
        e('ld   ac, %s' % z('rowx'))
        e('bne  nw%d' % m)
        e('ld   %s, ac' % z('rowy'))
        e('inc')
        e('ld   ac, %s' % z('rowy'))
        label('nw%d' % m)
        e('; once per byte: check the line read for a new frame')
        g.call('poll', 'tret')
        e('; cy += %d/256' % w)
        e('ld   %s, ac' % z('cyl'))
        e('add  %d, ac' % w)
        e('bge  cyok%d' % m)
        e('and  0x7F, ac')
        e('ld   ac, %s' % z('cyl'))
        e('ld   %s, ac' % z('cyh'))
        e('inc')
        e('ld   ac, %s' % z('cyh'))
        e('bra  cyd%d' % m)
        label('cyok%d' % m)
        e('ld   ac, %s' % z('cyl'))
        label('cyd%d' % m)
        e('; column done after 480 rows: rowy = vpage + 2')
        e('ld   %s, ac' % z('rowy'))
        e('sub  %s, ac' % z('vpage'))
        e('sub  2, ac')
        e('beq  cdone%d' % m)
        g.far('row%d' % m)
        label('cdone%d' % m)
        e('; next byte column: cx0 += 8/256, video page += 2')
        e('ld   %s, ac' % z('cxl0'))
        e('add  8, ac')
        e('bge  cxok%d' % m)
        e('and  0x7F, ac')
        e('ld   ac, %s' % z('cxl0'))
        e('ld   %s, ac' % z('cxh0'))
        e('inc')
        e('ld   ac, %s' % z('cxh0'))
        e('bra  cxd%d' % m)
        label('cxok%d' % m)
        e('ld   ac, %s' % z('cxl0'))
        label('cxd%d' % m)
        e('ld   %s, ac' % z('vpage'))
        e('add  2, ac')
        e('ld   ac, %s' % z('vpage'))
        e('ld   %s, ac' % z('bcnt'))
        e('dec')
        e('ld   ac, %s' % z('bcnt'))
        e('beq  pdone%d' % m)
        g.far('col%d' % m)
        label('pdone%d' % m)
        e('ld   %s, y' % z('preth'))
        e('jmp  %s' % z('pret'))

    # ------------------------------------------------------------ timer
    # The same timer as gen_pi_spigot.py.  The line read at 5000h (V9:V2,
    # 124-255) is polled; a poll that sees it go down adds one frame to a
    # decimal count of microseconds.
    g.block('poll')
    label('poll')
    e('; read the line read (V9:V2, 124-255) and add one frame to the timer')
    e('; when it went down.  cur - last - 96 >= 0 means it wrapped, as long as')
    e('; polls are less than 95 steps (380 lines) apart.  Uses y and x.')
    e('ld   0x50, y')
    e('ld   [y,x], ac')
    e('ld   ac, %s' % z('cur'))
    e('sub  %s, ac' % z('last'))
    e('sub  96, ac')
    e('blt  pnw')
    g.st(1, 'wrapped')
    g.st(FR - TU, 'doff')
    g.call('dadd', 'dret')
    label('pnw')
    e('ld   %s, ac' % z('cur'))
    e('ld   ac, %s' % z('last'))
    e('ld   %s, y' % z('treth'))
    e('jmp  %s' % z('tret'))

    g.block('dadd')
    label('dadd')
    e('; timer digits at 0x%02X += addend digits at 0x%02X + [doff], decimal' % (TU, TU))
    e('clr  ac')
    e('ld   ac, %s' % z('dc'))
    e('ld   0x%02X, x' % TU)
    label('dl')
    e('ld   [x], ac')
    e('add  %s, ac' % z('dc'))
    e('ld   ac, %s' % z('ds'))
    e('ld   x, ac')
    e('add  %s, ac' % z('doff'))
    e('ld   ac, x')
    e('ld   [x], ac')
    e('add  %s, ac' % z('ds'))
    e('ld   ac, %s' % z('ds'))
    e('ld   x, ac')
    e('sub  %s, ac' % z('doff'))
    e('ld   ac, x')
    e('ld   %s, ac' % z('ds'))
    e('sub  10, ac')
    e('blt  dlt')
    e('ld   ac, [x]')
    e('ld   1, ac')
    e('bra  dn')
    label('dlt')
    e('ld   %s, ac' % z('ds'))
    e('ld   ac, [x]')
    e('clr  ac')
    label('dn')
    e('ld   ac, %s' % z('dc'))
    e('ld   x, ac')
    e('inc')
    e('ld   ac, x')
    e('sub  0x%02X, ac' % (TU + 9))
    e('bne  dl')
    e('ld   %s, y' % z('dreth'))
    e('jmp  %s' % z('dret'))

    g.block('tstart')
    label('tstart')
    e('; start the timer at the top of a frame: wait for the line read to wrap')
    g.call('poll', 'tret')
    label('sync')
    g.st(0, 'wrapped')
    g.call('poll', 'tret')
    e('ld   %s, ac' % z('wrapped'))
    e('beq  sync')
    g.call('tclear', 'tret')
    e('ld   %s, y' % z('reth'))
    e('jmp  %s' % z('ret'))

    g.block('tclear')
    label('tclear')
    e('; timer = 0, frame addend = %d us, step addend = %d us' % (FRAME_US, STEP_US))
    e('ld   0x%02X, x' % TU)
    label('tcl')
    e('ld   0x00, [x]')
    e('ld   x, ac')
    e('inc')
    e('ld   ac, x')
    e('sub  0x%02X, ac' % (PT + 9))
    e('bne  tcl')
    for base, v in ((FR, FRAME_US), (PT, STEP_US)):
        for k in range(9):
            dk = v // 10 ** k % 10
            if dk:
                e('ld   %d, ac' % dk)
                e('ld   ac, [0x%02X]' % (base + k))
    e('ld   %s, y' % z('treth'))
    e('jmp  %s' % z('tret'))

    # ------------------------------------------------------------ show the time
    g.block('tshow')
    label('tshow')
    e('; stop the timer: whole frames are counted, add the 128 us steps since')
    e('; the top of this frame')
    g.call('poll', 'tret')
    e('ld   %s, ac' % z('last'))
    e('sub  %d, ac' % LINE0)
    e('ld   ac, %s' % z('tmp'))
    g.st(PT - TU, 'doff')
    label('part')
    e('ld   %s, ac' % z('tmp'))
    e('beq  pdn')
    e('dec')
    e('ld   ac, %s' % z('tmp'))
    g.call('dadd', 'dret')
    e('bra  part')
    label('pdn')
    v0 = 0x20 + BAND_ROW0
    e('; a black 1 bpp band, screen rows %d-%d: mode bytes 0, pixels 0'
      % (BAND_ROW0, BAND_ROW0 + BAND_ROWS - 1))
    g.st(0x60 + (v0 >> 8), 'tmp')
    label('bnd')
    e('ld   %s, y' % z('tmp'))
    e('ld   0x%02X, x' % (v0 & 0xFF))
    label('bndr')
    e('ld   0x00, [y,x]')
    e('ld   x, ac')
    e('inc')
    e('ld   ac, x')
    e('sub  0x%02X, ac' % ((v0 & 0xFF) + BAND_ROWS))
    e('bne  bndr')
    e('ld   %s, ac' % z('tmp'))
    e('add  2, ac')
    e('ld   ac, %s' % z('tmp'))
    e('sub  0x%02X, ac' % ((0x60 + (v0 >> 8) + 160) & 0xFF))
    e('bne  bnd')
    e('ld   0x%02X, y' % (0x4A + (v0 >> 8)))
    e('ld   0x%02X, x' % (v0 & 0xFF))
    label('bndm')
    e('ld   0x00, [y,x]')
    e('ld   x, ac')
    e('inc')
    e('ld   ac, x')
    e('sub  0x%02X, ac' % ((v0 & 0xFF) + BAND_ROWS))
    e('bne  bndm')
    g.far('tshow2')

    g.block('tshow2')
    label('tshow2')
    vt = 0x20 + TEXT_ROW
    e('; "SSS.SSS s", leading zeros of the seconds as spaces')
    g.st(0x60 + 2 * TCOL + (vt >> 8), 'cpg')
    g.st(vt & 0xFF, 'crow')
    e('ld   [0x%02X], ac' % (TU + 8))
    e('bne  sh1')
    e('ld   11, ac')
    e('ld   ac, [0x%02X]' % (TU + 8))
    e('ld   [0x%02X], ac' % (TU + 7))
    e('bne  sh1')
    e('ld   11, ac')
    e('ld   ac, [0x%02X]' % (TU + 7))
    label('sh1')
    g.st(TU + 8, 'sx2')
    label('shlp')
    e('ld   %s, x' % z('sx2'))
    e('ld   [x], ac')
    e('ld   ac, %s' % z('dig'))
    g.call('gdraw', 'gret')
    e('ld   %s, ac' % z('sx2'))
    e('sub  0x%02X, ac' % (TU + 6))
    e('bne  shnd')
    g.st(10, 'dig')
    g.call('gdraw', 'gret')
    label('shnd')
    e('ld   %s, ac' % z('sx2'))
    e('dec')
    e('ld   ac, %s' % z('sx2'))
    e('sub  0x%02X, ac' % (TU + 2))
    e('bne  shlp')
    for c in (11, 12):
        g.st(c, 'dig')
        g.call('gdraw', 'gret')
    e('ld   %s, y' % z('reth'))
    e('jmp  %s' % z('ret'))

    g.block('gdraw')
    label('gdraw')
    e('; draw glyph [dig] at page [cpg], row byte [crow]; then cpg += 2')
    e('ld   %s, ac' % z('dig'))
    e('shl')
    e('shl')
    e('shl')
    e('add  0x%02X, ac' % FONT_LO)
    e('ld   ac, %s' % z('gx'))
    e('ld   %s, ac' % z('crow'))
    e('ld   ac, %s' % z('gsx'))
    for r in range(8):
        e('ld   %s, x' % z('gx'))
        e('ld   [x], ac')
        e('ld   ac, %s' % z('tmp'))
        e('ld   %s, x' % z('gsx'))
        e('ld   %s, y' % z('cpg'))
        e('ld   %s, ac' % z('tmp'))
        e('ld   ac, [y,x]')
        if r < 7:
            e('ld   %s, ac' % z('gx'))
            e('inc')
            e('ld   ac, %s' % z('gx'))
            e('ld   x, ac')
            e('inc')
            e('ld   ac, %s' % z('gsx'))
    e('ld   %s, ac' % z('cpg'))
    e('add  2, ac')
    e('ld   ac, %s' % z('cpg'))
    e('ld   %s, y' % z('greth'))
    e('jmp  %s' % z('gret'))

    # ------------------------------------------------------------ kernel
    g.block('kernel')
    label('kernel')
    e('; in: cx, cy, coff.  out: AC = color for this mode.  returns to [reth, ret]')
    e('clr  ac')
    for n in ('axl', 'axh', 'ayl', 'ayh', 'sx', 'sy'):
        e('ld   ac, %s' % z(n))
    g.st(MAXIT, 'it')
    label('iter')
    e('; x*x, y*y')
    g.square('xx', 'ax')
    g.square('yy', 'ay')
    e('; t = x*x + y*y, escape if t >= 4.0 (hi >= %d)' % (1 << (F - 5)))
    g.add128('t', 'xx', 'yy')
    e('sub  %d, ac' % (1 << (F - 5)))
    e('bge  escape')
    e('; x\' = x*x - y*y + cx')
    g.sub128('d', 'xx', 'yy')
    g.add128('nx', 'd', 'cx')
    g.far('kernel2')
    label('escape')
    e('; color from the iterations left (0 = never escaped)')
    e('ld   %s, ac' % z('it'))
    e('add  %s, ac' % z('coff'))
    e('ld   ac, x')
    e('ld   0x%02X, y' % COL_PG)
    e('ld   [y,x], ac')
    e('ld   %s, y' % z('reth'))
    e('jmp  %s' % z('ret'))

    g.block('kernel2')
    label('kernel2')
    e('; s = |x + y|')
    e('ld   %s, ac' % z('sx'))
    e('xor  %s, ac' % z('sy'))
    e('bne  sdiff')
    g.add128('s', 'ax', 'ay')
    e('bra  sdone')
    label('sdiff')
    g.sub128('s', 'ax', 'ay')
    e('bge  sdone')
    g.sub128('s', 'ay', 'ax')
    label('sdone')
    g.square('p', 's')
    e('; y\' = s*s - t + cy  (= 2xy + cy)')
    g.sub128('ny', 'p', 't')
    g.add128('ny', 'ny', 'cy')
    g.far('kernel3')

    g.block('kernel3')
    label('kernel3')
    e('; back to magnitude + sign, escape if |x\'| or |y\'| >= 2')
    g.to_signmag('nx', 'ax', 'sx', 'esc3')
    g.to_signmag('ny', 'ay', 'sy', 'esc3')
    e('ld   %s, ac' % z('it'))
    e('dec')
    e('ld   ac, %s' % z('it'))
    e('beq  esc3                 ; never escaped: it = 0 -> black')
    g.far('iter')
    label('esc3')
    g.far('escape')

    # ------------------------------------------------------------ output
    out = []
    o = out.append
    o('; mandelbrot.asm - generated by gen_mandelbrot.py, do not edit by hand')
    o('; Placard CPU: the Mandelbrot set drawn in 1, 2, 4 and 8 bpp in turn,')
    o('; %d iterations, 8 fraction bits.  See gen_mandelbrot.py for the method' % MAXIT)
    o('; and memory map.')
    o(';     %s' % ('one pass, no pauses (simulator build)' if once else
                    'repeats forever, about %g s pause after each mode' % delay))
    o(';')
    o(';     python3 placard_sim.py mandelbrot.asm --run --max-steps 2000000000 --png m.png')
    o(';')
    o('; Date: 10/16/2026')
    o('')
    o('#include "placard.asm"')
    o('')
    o('#addr 0x0000')
    o('reset:')
    o('    ld   main >> 8, y')
    o('    jmp  main')
    o('')
    o('#addr 0x%04X' % FONT_LO)
    o('font:      ; 0-9, ".", space, "s"; 8 bytes each, leftmost pixel in bit 0')
    for d in range(13):
        rev = [int('{:08b}'.format(b)[::-1], 2) for b in FONT[d]]
        o('    #d8 ' + ', '.join('0x%02X' % b for b in rev))
    pg = CODE_PG
    for name, lines in g.blocks:
        size = sum(instr_size(l.split(';')[0]) for l in lines if not l.endswith(':'))
        if size > 256:
            raise SystemExit('block %s is %d bytes, more than a page' % (name, size))
        o('')
        o('#addr 0x%04X' % (pg << 8))
        out.extend(lines)
        pg += 1
    if pg > COL_PG:
        raise SystemExit('code runs into the color tables')

    o('')
    o('#addr 0x%04X' % (COL_PG << 8))
    o('colors:    ; mode m at offset 64*m, index = iterations left, already')
    o('           ; shifted to the top of the byte for the pixel packing')
    for m in range(4):
        bpp = 1 << m
        tab = [0] + [color_for(m, MAXIT - it) << (8 - bpp) & 0xFF for it in range(1, MAXIT + 1)]
        tab += [0] * (64 - len(tab))
        for r in range(4):
            o('    #d8 ' + ', '.join('0x%02X' % v for v in tab[16 * r:16 * r + 16]))
    sq = [(k * k + (1 << (F - 1))) >> F for k in range(1024)]
    for pgbase, part in ((SQL_PG, 0), (SQH_PG, 1)):
        o('')
        o('; squares k*k/256, %s limbs, page 0x%02X + k/128, X = k%%128'
          % (('low', 'high')[part], pgbase))
        for kh in range(8):
            o('#addr 0x%04X' % ((pgbase + kh) << 8))
            for r in range(8):
                vals = [sq[128 * kh + 16 * r + c] for c in range(16)]
                vals = [(v & 0x7F) if part == 0 else (v >> 7) for v in vals]
                o('    #d8 ' + ', '.join('0x%02X' % v for v in vals))
    here = os.path.dirname(os.path.abspath(__file__))
    path = out_path or os.path.join(here, 'mandelbrot.asm')
    src = '\n'.join(out) + '\n'
    with open(path, 'w') as f:
        f.write(src)
    mem, _, _ = assemble(src, here)
    hexpath = os.path.splitext(path)[0] + '.hex'
    with open(hexpath, 'w') as f:
        f.write(to_hexstr(mem) + '\n')
    print('wrote', path, 'and', hexpath)


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--once', action='store_true',
                    help='draw the four modes once and halt (for the simulator)')
    ap.add_argument('--delay', type=float, default=5.0,
                    help='pause after each mode, seconds (0 = none)')
    ap.add_argument('-o', '--out', help='output .asm path (the .hex goes next to it); '
                    'default mandelbrot.asm next to this script')
    a = ap.parse_args()
    build(a.once, a.delay, a.out)

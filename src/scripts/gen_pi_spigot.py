#!/usr/bin/env python3
"""
gen_pi_spigot.py - generate pi_spigot.asm, a Rabinowitz & Wagon spigot
benchmark for the Placard CPU: exact decimal digits of pi using integer
arithmetic only, printed in the middle of the screen as they are produced,
timed with the video line read, and run again every 10 seconds.

    python3 gen_pi_spigot.py                 1000 digits -> pi_spigot.asm and .hex
    python3 gen_pi_spigot.py --digits 50     a quick test build
    python3 placard_sim.py pi_spigot.asm --run --max-steps 2000000000 --stop-at pause --png pi.png

Then put pi_spigot.hex into rom.mem with gen_rom.tcl (set
::ASM_FILE to pi_spigot.hex) to run it on the board.

ALGORITHM (Rabinowitz & Wagon 1995, with predigit / nines handling)
    LEN = 10 * N / 3 + 1 mixed-radix digits, all starting at 2
    repeat N times:
        q = 0
        for i = LEN down to 2:
            x    = 10 * a[i] + q * i
            a[i] = x mod (2i - 1)
            q    = x div (2i - 1)
        x = 10 * a[1] + q;  a[1] = x mod 10;  q = x div 10
        q is the next digit, held back while it might still get a carry
        (runs of 9s, and a 10 that carries into the held digit)
    For N = 1000: a[i] < 6667 (13 bits), x < 2^17, q <= 18.

ARITHMETIC
    Multi-byte values are plain bytes, least significant first, and the
    carry flag (Branch PLD rev 11) carries between them: after a byte's add
    or subtract, bcc skips the inc or dec of the next byte.
    - 10 * a[i] and q * i come from a product table T[m][v] = m * v
      (m = 0..18, v = 0..255, two bytes), applied to each byte of a[i]
      and i.  q * (i >> 8) is under 256, so it needs only the low table.
      init builds the table in the RAM at reset (see MEMORY).
    - x div (2i - 1) is a software restoring division: q <= 18 < 32, so
      five compare-and-subtract steps against D_k = (2i - 1) << k, k = 4..0,
      with q built up in the X register.  x < 2^17, D_3 < 2^16, so after
      the k = 3 step x fits in two bytes and the last three steps are
      16-bit.  The five D_k are counters that step down by 2 << k as i
      steps down, so no shifts are needed in the loop.
    - a[i] is two byte arrays (low byte, high byte) walked by pointer; the
      pointer's low byte is also the low byte of i.

SCREEN (1 bpp)
    Digits in the 8x8 font in a block centered on the screen: "3." and 50
    decimals on the first row, then rows of 50 decimals under the first
    decimal (52 columns from column 14; 20 rows for 1000 digits).  One blank
    row below the block, the run time "SSS.SSS s" is centered.  The screen
    is cleared and every mode byte (5A20-5BFF) set to 1 bpp first.

TIMER
    The line read at 5000h (V9:V2 of the line counter, 124-255, see
    README.md) is the time base.  There is no frame counter, so the program
    polls it: every 256 terms of the inner loop (about 100,000 clocks, a
    quarter of a frame), once per page while a[i] is filled, and in the
    10 second wait.  A poll that sees the value go down adds one frame,
    16800 us at 25.000 MHz (525 lines x 800 clocks), to a 9 digit decimal
    count of microseconds at 0050-0058, so the result never has to be
    divided to print it.
    - Start: after the screen is cleared, the program waits for the value
      to wrap (the top of a frame), clears the count and starts filling
      a[i].
    - Stop: after the last digit, one more poll, then 128 us for each step
      of the line read since the top of the frame.  Resolution 128 us.
    - Then the time is shown, the count is cleared and polled until it
      reaches 10 s, and the program starts again from the screen clear.

RESULT (placard_sim.py with State PLD rev 12 / Branch PLD rev 11 timing;
1000 digits, the same screen as the base-128 build before the carry flag
apart from the time)
    485,958,344 instructions, 1,699,635,170 clocks from reset to the stop
    (the polls add about 0.25 %).  The timer shows 67.949 s (25.000 MHz,
    no video stalls).  With the CPU stalled on every video byte fetch (1
    clock in 8 during active video, 9.1 % of all clocks) the board should
    show about 74 s.  Before the carry flag (base-128 limbs) it was
    2,261,702,856 clocks and 90.434 s, so the carry flag makes it 1.33x
    faster.  The screen is reference/pi_spigot_sim.png.

MEMORY
    0000-0003   reset: jump to init (builds the product table, then main)
    0010-0048   variables (zero page)
    0050-0058   timer, decimal microseconds, least significant digit first
    0060-0068   one frame (16800) as decimal digits, 0070-0078 one step (128)
    0080-00E7   font
    0100-08FF   code, blocks packed so none crosses a page
    0900-16FF   a[i] low bytes  (address 0900 + i)
    1700-24FF   a[i] high bytes (address 1700 + i)
    2500-37FF   product table low bytes,  page 25 + m, m = 0..18
    3800-4AFF   product table high bytes, page 38 + m
    5A20-5BFF   mode bytes, one per row (all 0, 1 bpp)
    5D00-5D0A   the program menu's block (menu_hook.py), when run from it
    6000-FFFF   video RAM
    The tables only go up to m = 18, the largest q for 1000 digits (build()
    checks it for the digit count asked for).  They are not part of the
    program: init builds them once at reset (row m = row m - 1 + v), so the
    program is only x0000-x08FF.

PROGRAM MENU
    In the menu ROM (docs/MENU.md) poll also calls hk_poll (menu_hook.py),
    which goes back to the menu when Esc is pressed or the time is up, and
    the end of the 10 s pause calls hk_done, which goes on to the next
    program when the menu is rotating.  Run by itself both just return.

Date: 10/20/2026
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from placard_sim import assemble, instr_size, to_hexstr   # noqa: E402
from menu_hook import hook_blocks, as_lines              # noqa: E402

ALO_PG, AHI_PG = 0x09, 0x17
TLO_PG, THI_PG = 0x25, 0x38
TMAX = 18               # largest multiplier m; build() checks q <= TMAX
FONT_PG, FONT_LO = 0x00, 0x80     # font in the top of zero page
CODE_PG = 0x01

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

ZP = {}
for _i, _n in enumerate(
        ['x0', 'x1', 'x2', 't0', 't1', 'q', 'al', 'ah', 'ih', 'px', 'py',
         'pre', 'nines', 'first', 'fill', 'dig', 'dotf', 'cpage', 'crow',
         'ccol', 'rhi', 'gx', 'sx', 'tmp', 'ret', 'reth', 'jl', 'jh',
         'cur', 'last', 'wrapped', 'doff', 'dc', 'ds', 'pret', 'preth',
         'dret', 'dreth', 'sx2', 'di', 'hret', 'hreth'] +
        ['d%d%d' % (k, l) for k in range(5) for l in range(3)]):
    ZP[_n] = 0x10 + _i


# timer: 9 decimal digits of microseconds, least significant first, and the
# two addends: one frame (525 lines x 32 us = 16800 us at 25.000 MHz) and one
# step of the line read (4 lines = 128 us)
TU, FR, PT = 0x50, 0x60, 0x70
FRAME_US, STEP_US = 16800, 128
LINE0 = 124             # line read value at the top of the frame (V = 499)

# screen layout, in 8x8 character cells (79 columns, 1-79, by 60 rows)
DCOL = 14               # "3." at column 14 (the block is 52 columns wide)
DWID = 50               # 50 decimals per row, rows after the first at DCOL + 2
TCOL = 36               # time "SSS.SSS s", one blank row below the digits
WAIT_TENS = 1           # wait until the timer's tens-of-seconds digit is 1


def cell(col, row):
    """(page, low byte) of the top byte of a character cell"""
    v = 0x20 + 8 * row
    return 0x60 + 2 * col + (v >> 8), v & 0xFF


def z(n):
    return '[0x%02X]' % ZP[n]


def limbs(v, n):
    return [(v >> (8 * j)) & 0xFF for j in range(n)]


class Gen:
    def __init__(self):
        self.blocks = []        # list of (name, lines)
        self.cur = None
        self.n = 0

    def block(self, name):
        self.cur = []
        self.blocks.append((name, self.cur))

    def e(self, s):
        if s.startswith('bge '):
            # no BGE since Branch PLD rev 11 (BCS/BCC took its code):
            # branch round the jump when bit 7 is set
            skip = self.uniq('ge')
            self.cur.append('    blt  ' + skip)
            self.cur.append('    bra  ' + s[4:].strip())
            self.cur.append(skip + ':')
            return
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


def max_q(ndig):
    """largest q of the inner loop (the table multiplier) for ndig digits"""
    ln = 10 * ndig // 3 + 1
    a = [2] * (ln + 1)
    mq = 0
    for _ in range(ndig):
        q = 0
        for i in range(ln, 1, -1):
            x = 10 * a[i] + q * i
            a[i], q = x % (2 * i - 1), x // (2 * i - 1)
            mq = max(mq, q)
        x = 10 * a[1] + q
        a[1] = x % 10
    return mq


def build(ndig):
    ln = 10 * ndig // 3 + 1
    if ALO_PG * 256 + ln >= AHI_PG * 256:
        raise SystemExit('too many digits for the array space')
    if TMAX * (ln >> 8) > 255:
        raise SystemExit('q * (i >> 8) does not fit a byte')
    if max(max_q(ndig), 10) > TMAX:
        raise SystemExit('q reaches %d, more than the product table (TMAX = %d)'
                         % (max_q(ndig), TMAX))
    g = Gen()
    e, label = g.e, g.label
    # digit rows, a blank row and the time row, centered on the 60 rows
    rows = (ndig - 1 + DWID - 1) // DWID
    drow = (60 - rows - 2) // 2
    trow = drow + rows + 1

    # ------------------------------------------------------------ setup
    g.block('init')
    label('init')
    e('; product tables T[m][v] = m * v (low bytes at page 0x%02X + m, high' % TLO_PG)
    e('; bytes at page 0x%02X + m), built once: row m = row m - 1 + v' % THI_PG)
    e('clr  ac')
    label('it0')
    e('ld   ac, x')
    e('ld   0x%02X, y' % TLO_PG)
    e('ld   0x00, [y,x]')
    e('ld   0x%02X, y' % THI_PG)
    e('ld   0x00, [y,x]')
    e('inc')
    e('bne  it0')
    g.st(TLO_PG, 'tmp')
    label('itm')
    g.st(0, 'gx')
    label('itv')
    e('ld   %s, ac' % z('gx'))
    e('ld   ac, x')
    e('ld   %s, y' % z('tmp'))
    e('ld   [y,x], ac')
    e('add  %s, ac' % z('gx'))
    e('ld   ac, %s' % z('t0'))
    e('clr  ac')
    e('bcc  itnc')
    e('ld   1, ac')
    label('itnc')
    e('ld   ac, %s' % z('t1'))
    e('ld   %s, ac' % z('tmp'))
    e('add  0x%02X, y' % (THI_PG - TLO_PG))
    e('ld   [y,x], ac')
    e('add  %s, ac' % z('t1'))
    e('ld   ac, %s' % z('t1'))
    e('ld   %s, ac' % z('tmp'))
    e('add  1, y')
    e('ld   %s, ac' % z('t0'))
    e('ld   ac, [y,x]')
    e('ld   %s, ac' % z('tmp'))
    e('add  0x%02X, y' % (THI_PG - TLO_PG + 1))
    e('ld   %s, ac' % z('t1'))
    e('ld   ac, [y,x]')
    e('ld   %s, ac' % z('gx'))
    e('inc')
    e('ld   ac, %s' % z('gx'))
    e('bne  itv')
    e('ld   %s, ac' % z('tmp'))
    e('inc')
    e('ld   ac, %s' % z('tmp'))
    e('sub  0x%02X, ac' % (TLO_PG + TMAX))
    e('bne  itm')
    g.far('main')

    g.block('main')
    e('; clear video RAM 6000-FFFF (pixels off)')
    g.st(0x60, 'tmp')
    label('clr_pg')
    e('ld   %s, y' % z('tmp'))
    e('clr  ac')
    label('clr_b')
    e('ld   ac, x')
    e('ld   0x00, [y,x]')
    e('inc')
    e('bne  clr_b')
    e('ld   %s, ac' % z('tmp'))
    e('inc')
    e('ld   ac, %s' % z('tmp'))
    e('bne  clr_pg')
    g.far('clr_m')

    g.block('clr_m')
    label('clr_m')
    e('; mode bytes 5A00-5BFF = 0 (1 bpp)')
    e('ld   0x5A, y')
    e('clr  ac')
    label('clr_m0')
    e('ld   ac, x')
    e('ld   0x00, [y,x]')
    e('inc')
    e('bne  clr_m0')
    e('ld   0x5B, y')
    label('clr_m1')
    e('ld   ac, x')
    e('ld   0x00, [y,x]')
    e('inc')
    e('bne  clr_m1')
    g.far('tsync')

    g.block('tsync')
    label('tsync')
    e('; start the timer at the top of a frame: wait for the line read to wrap')
    g.call('poll', 'pret')
    label('sync')
    g.st(0, 'wrapped')
    g.call('poll', 'pret')
    e('ld   %s, ac' % z('wrapped'))
    e('beq  sync')
    g.call('tclear', 'pret')
    e('; a[i] = 2: low limb pages = 2, high limb pages = 0')
    g.st(ALO_PG, 'tmp')
    label('fill_pg')
    g.call('poll', 'pret')
    e('ld   %s, y' % z('tmp'))
    e('clr  ac')
    label('fill_b')
    e('ld   ac, x')
    e('ld   0x02, [y,x]')
    e('inc')
    e('bne  fill_b')
    e('ld   %s, ac' % z('tmp'))
    e('add  0x%02X, y' % (AHI_PG - ALO_PG))
    e('clr  ac')
    label('fill_h')
    e('ld   ac, x')
    e('ld   0x00, [y,x]')
    e('inc')
    e('bne  fill_h')
    e('ld   %s, ac' % z('tmp'))
    e('inc')
    e('ld   ac, %s' % z('tmp'))
    e('sub  0x%02X, ac' % AHI_PG)
    e('bne  fill_pg')
    e('; output state')
    g.st(0, 'pre')
    g.st(0, 'nines')
    g.st(1, 'first')
    g.st(1, 'dotf')
    pg, lo = cell(DCOL, drow)
    g.st(pg, 'cpage')
    g.st(lo, 'crow')
    g.st(0, 'rhi')
    g.st(DWID + 2, 'ccol')
    jl, jh = limbs(ndig, 2)
    g.st(jl, 'jl')
    g.st(jh, 'jh')
    e('; ---- one digit per pass ----')
    label('outer')
    g.st(0, 'q')
    g.st(ln >> 8, 'ih')
    p = ALO_PG * 256 + ln
    g.st(p & 0xFF, 'px')
    g.st(p >> 8, 'py')
    for k in range(5):
        for l, v in enumerate(limbs((2 * ln - 1) << k, 3)):
            g.st(v, 'd%d%d' % (k, l))
    g.far('inner')

    # ------------------------------------------------------------ x = 10 a[i] + q i
    def ksub(k, nbytes):
        """if x >= D_k = (2i-1) << k: x -= D_k, q += 1 << k.
        nbytes = 2: x < 65536 and D_k < 65536"""
        a, z, skip = g.uniq('ka'), g.uniq('kz'), g.uniq('ks')
        e('; k = %d' % k)
        e('ld   %s, ac' % z_('x0'))
        e('sub  %s, ac' % z_('d%d0' % k))
        e('ld   ac, %s' % z_('t0'))
        e('ld   %s, ac' % z_('x1'))
        e('bcc  %s' % a)
        e('dec')
        e('bcs  %s' % (skip if nbytes == 2 else z))   # x1 was 0: borrow out
        label(a)
        e('sub  %s, ac' % z_('d%d1' % k))
        if nbytes == 2:
            e('bcs  %s' % skip)
        elif k == 3:
            # x < 16 (2i-1) and 8 (2i-1) < 65536: with no borrow here x2 is 0;
            # with a borrow, x >= D_3 only when x2 = 1 (then x2 becomes 0)
            ok = g.uniq('kc')
            e('bcc  %s' % ok)
            y3 = g.uniq('ky')
            label(y3)
            e('ld   ac, %s' % z_('t1'))
            e('ld   %s, ac' % z_('x2'))
            e('beq  %s' % skip)
            e('clr  ac')
            e('ld   ac, %s' % z_('x2'))
            e('ld   %s, ac' % z_('t1'))
            label(ok)
        else:
            # three bytes (k = 4)
            b = g.uniq('kb')
            e('ld   ac, %s' % z_('t1'))
            e('ld   %s, ac' % z_('x2'))
            e('bcc  %s' % b)
            e('dec')
            e('bcs  %s' % skip)
            label(b)
            e('sub  %s, ac' % z_('d%d2' % k))
            e('bcs  %s' % skip)
            e('ld   ac, %s' % z_('x2'))
            e('ld   %s, ac' % z_('t1'))
        e('ld   ac, %s' % z_('x1'))
        e('ld   %s, ac' % z_('t0'))
        e('ld   ac, %s' % z_('x0'))
        if k == 4:
            e('ld   0x10, ac')
        else:
            e('ld   %s, ac' % z_('q'))
            e('or   0x%02X, ac' % (1 << k))
        e('ld   ac, %s' % z_('q'))
        if k == 3:
            e('bra  %s' % skip)
            label(z)
            e('; x1 was 0 and borrowed: t1 = FF - D_31')
            e('ld   %s, ac' % z_('d%d1' % k))
            e('not')
            e('bra  %s' % y3)
        elif k == 4:
            e('bra  %s' % skip)
            label(z)
            e('; x1 was 0 and borrowed: t1 = FF - D_41, borrow into x2')
            e('ld   %s, ac' % z_('d%d1' % k))
            e('not')
            e('ld   ac, %s' % z_('t1'))
            e('ld   %s, ac' % z_('x2'))
            e('dec')
            e('bcs  %s' % skip)
            e('bra  %s' % b)
        label(skip)

    z_ = z
    g.block('inner')
    label('inner')
    e('; a[i] -> al, ah (X = px is also the low byte of i)')
    e('ld   %s, x' % z('px'))
    e('ld   %s, y' % z('py'))
    e('ld   [y,x], ac')
    e('ld   ac, %s' % z('al'))
    e('ld   %s, ac' % z('py'))
    e('add  0x%02X, y' % (AHI_PG - ALO_PG))
    e('ld   [y,x], ac')
    e('ld   ac, %s' % z('ah'))
    e('; q * i: x0 = T[q][il].lo, t0 = T[q][il].hi, x1 = T[q][ih].lo (q * ih < 256)')
    e('ld   %s, ac' % z('q'))
    e('add  0x%02X, y' % TLO_PG)
    e('ld   [y,x], ac')
    e('ld   ac, %s' % z('x0'))
    e('ld   %s, ac' % z('q'))
    e('add  0x%02X, y' % THI_PG)
    e('ld   [y,x], ac')
    e('ld   ac, %s' % z('t0'))
    e('ld   %s, ac' % z('q'))
    e('add  0x%02X, y' % TLO_PG)
    e('ld   %s, x' % z('ih'))
    e('ld   [y,x], ac')
    e('ld   ac, %s' % z('x1'))
    e('; + 10 * al: x0 += T[10][al].lo, t0 += T[10][al].hi + carry (< 256)')
    e('ld   %s, x' % z('al'))
    e('ld   0x%02X, y' % (TLO_PG + 10))
    e('ld   [y,x], ac')
    e('add  %s, ac' % z('x0'))
    e('ld   ac, %s' % z('x0'))
    e('ld   0x%02X, y' % (THI_PG + 10))
    e('ld   [y,x], ac')
    e('bcc  qi0')
    e('inc')
    label('qi0')
    e('add  %s, ac' % z('t0'))
    e('add  %s, ac' % z('x1'))
    e('ld   ac, %s' % z('x1'))
    e('; + 2560 * ah: x2 = T[10][ah].hi + carries, x1 += T[10][ah].lo')
    e('ld   %s, x' % z('ah'))
    e('ld   [y,x], ac')
    e('bcc  qi1')
    e('inc')
    label('qi1')
    e('ld   ac, %s' % z('x2'))
    e('ld   0x%02X, y' % (TLO_PG + 10))
    e('ld   [y,x], ac')
    e('add  %s, ac' % z('x1'))
    e('ld   ac, %s' % z('x1'))
    e('bcc  qi2')
    e('ld   %s, ac' % z('x2'))
    e('inc')
    e('ld   ac, %s' % z('x2'))
    label('qi2')
    e('; x div (2i - 1), q in zero page (X is not a source)')
    e('clr  ac')
    e('ld   ac, %s' % z('q'))
    ksub(4, 3)
    g.far('div2')

    g.block('div2')
    label('div2')
    ksub(3, 3)
    ksub(2, 2)
    ksub(1, 2)
    ksub(0, 2)
    g.far('div3')

    g.block('div3')
    label('div3')
    e('; a[i] = remainder (x2 = 0)')
    e('ld   %s, x' % z('px'))
    e('ld   %s, y' % z('py'))
    e('ld   %s, ac' % z('x0'))
    e('ld   ac, [y,x]')
    e('ld   %s, ac' % z('py'))
    e('add  0x%02X, y' % (AHI_PG - ALO_PG))
    e('ld   %s, ac' % z('x1'))
    e('ld   ac, [y,x]')
    e('; step the pointer (and i) and the five divisors down')
    e('ld   %s, ac' % z('px'))
    e('bne  pnz')
    e('ld   %s, ac' % z('py'))
    e('dec')
    e('ld   ac, %s' % z('py'))
    e('ld   %s, ac' % z('ih'))
    e('dec')
    e('ld   ac, %s' % z('ih'))
    e('; every 256 terms: check the line read for a new frame')
    g.call('poll', 'pret')
    e('clr  ac')
    label('pnz')
    e('dec')
    e('ld   ac, %s' % z('px'))
    for k in range(5):
        ok = g.uniq('dok')
        e('ld   %s, ac' % z('d%d0' % k))
        e('sub  0x%02X, ac' % (2 << k))
        e('ld   ac, %s' % z('d%d0' % k))
        e('bcc  %s' % ok)
        e('ld   %s, ac' % z('d%d1' % k))
        e('dec')
        e('ld   ac, %s' % z('d%d1' % k))
        if k == 4:
            e('bcc  %s' % ok)
            e('ld   %s, ac' % z('d%d2' % k))
            e('dec')
            e('ld   ac, %s' % z('d%d2' % k))
        label(ok)
    e('; loop while i > 1')
    e('ld   %s, ac' % z('ih'))
    e('bne  again')
    e('ld   %s, ac' % z('px'))
    e('sub  1, ac')
    e('beq  last')
    label('again')
    g.far('inner')
    label('last')
    g.far('last_i')

    # ------------------------------------------------------------ i = 1, digit out
    g.block('last_i')
    label('last_i')
    e('; x = 10 * a[1] + q, a[1] = x mod 10, q = x div 10 (x <= 110)')
    e('ld   0x%02X, y' % ALO_PG)
    e('ld   0x01, x')
    e('ld   [y,x], ac')
    e('shl')
    e('ld   ac, %s' % z('t0'))
    e('shl')
    e('shl')
    e('add  %s, ac' % z('t0'))
    e('add  %s, ac' % z('q'))
    e('ld   ac, %s' % z('x0'))
    e('clr  ac')
    e('ld   ac, %s' % z('q'))
    label('d10')
    e('ld   %s, ac' % z('x0'))
    e('sub  10, ac')
    e('blt  d10done')
    e('ld   ac, %s' % z('x0'))
    e('ld   %s, ac' % z('q'))
    e('inc')
    e('ld   ac, %s' % z('q'))
    e('bra  d10')
    label('d10done')
    e('ld   %s, ac' % z('x0'))
    e('ld   ac, [y,x]')
    e('; predigit handling')
    e('ld   %s, ac' % z('q'))
    e('sub  9, ac')
    e('bne  not9')
    e('ld   %s, ac' % z('nines'))
    e('inc')
    e('ld   ac, %s' % z('nines'))
    e('bra  next')
    label('not9')
    e('sub  1, ac')
    e('bne  normal')
    e('; q = 10: held digit + 1, then the held 9s become 0s')
    e('ld   %s, ac' % z('pre'))
    e('inc')
    e('ld   ac, %s' % z('dig'))
    g.call('emit')
    g.st(0, 'fill')
    g.st(0, 'pre')
    e('bra  flush')
    label('normal')
    e('ld   %s, ac' % z('first'))
    e('bne  nofirst')
    e('ld   %s, ac' % z('pre'))
    e('ld   ac, %s' % z('dig'))
    g.call('emit')
    label('nofirst')
    g.st(0, 'first')
    e('ld   %s, ac' % z('q'))
    e('ld   ac, %s' % z('pre'))
    g.st(9, 'fill')
    label('flush')
    e('ld   %s, ac' % z('nines'))
    e('beq  next')
    e('dec')
    e('ld   ac, %s' % z('nines'))
    e('ld   %s, ac' % z('fill'))
    e('ld   ac, %s' % z('dig'))
    g.call('emit')
    e('bra  flush')
    label('next')
    e('; digits left')
    e('ld   %s, ac' % z('jl'))
    e('dec')
    e('ld   ac, %s' % z('jl'))
    e('bcc  jok')
    e('ld   %s, ac' % z('jh'))
    e('dec')
    e('ld   ac, %s' % z('jh'))
    label('jok')
    e('ld   %s, ac' % z('jl'))
    e('or   %s, ac' % z('jh'))
    e('beq  finish')
    g.far('outer')
    label('finish')
    e('ld   %s, ac' % z('pre'))
    e('ld   ac, %s' % z('dig'))
    g.call('emit')
    g.far('stop')

    # ------------------------------------------------------------ emit a digit
    g.block('emit')
    label('emit')
    e('; draw glyph [dig] at the cursor, then a "." after the first digit')
    e('ld   %s, ac' % z('dig'))
    e('shl')
    e('shl')
    e('shl')
    e('or   0x%02X, ac' % FONT_LO)
    e('ld   ac, %s' % z('gx'))
    e('ld   %s, ac' % z('crow'))
    e('ld   ac, %s' % z('sx'))
    for r in range(8):
        e('ld   %s, ac' % z('gx'))
        e('add  %d, x' % r)
        e('ld   0x%02X, y' % FONT_PG)
        e('ld   [y,x], ac')
        e('ld   ac, %s' % z('tmp'))
        e('ld   %s, ac' % z('sx'))
        e('add  %d, x' % r)
        e('ld   %s, y' % z('cpage'))
        e('ld   %s, ac' % z('tmp'))
        e('ld   ac, [y,x]')
    e('; next character cell')
    e('ld   %s, ac' % z('cpage'))
    e('add  2, ac')
    e('ld   ac, %s' % z('cpage'))
    e('ld   %s, ac' % z('ccol'))
    e('dec')
    e('ld   ac, %s' % z('ccol'))
    e('bne  advd')
    g.st(DWID, 'ccol')
    e('ld   %s, ac' % z('crow'))
    e('add  8, ac')
    e('ld   ac, %s' % z('crow'))
    e('bne  nlw')
    g.st(1, 'rhi')
    label('nlw')
    e('ld   0x%02X, ac' % cell(DCOL + 2, 0)[0])
    e('add  %s, ac' % z('rhi'))
    e('ld   ac, %s' % z('cpage'))
    label('advd')
    e('ld   %s, ac' % z('dotf'))
    e('beq  eret')
    g.st(0, 'dotf')
    g.st(10, 'dig')
    e('bra  emit')
    label('eret')
    e('ld   %s, y' % z('reth'))
    e('jmp  %s' % z('ret'))

    # ------------------------------------------------------------ timer
    g.block('poll')
    label('poll')
    e('; read the line read (V9:V2, 124-255) and add one frame to the timer')
    e('; when it went down.  cur - last - 96 >= 0 means it wrapped, as long as')
    e('; polls are less than 95 steps (380 lines) apart.  Uses y and x.')
    e('; The menu hook first (Esc, time up: menu_hook.py).')
    g.call('hk_poll', 'hret')
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
    e('ld   %s, y' % z('preth'))
    e('jmp  %s' % z('pret'))

    g.block('dadd')
    label('dadd')
    e('; timer digits at 0x%02X += addend digits at 0x%02X + [doff], decimal' % (TU, TU))
    e('clr  ac')
    e('ld   ac, %s' % z('dc'))
    e('ld   ac, %s' % z('di'))
    label('dl')
    e('ld   %s, ac' % z('di'))
    e('add  0x%02X, x' % TU)
    e('ld   [x], ac')
    e('add  %s, ac' % z('dc'))
    e('ld   ac, %s' % z('ds'))
    e('ld   %s, ac' % z('di'))
    e('add  %s, ac' % z('doff'))
    e('add  0x%02X, x' % TU)
    e('ld   [x], ac')
    e('add  %s, ac' % z('ds'))
    e('ld   ac, %s' % z('ds'))
    e('ld   %s, ac' % z('di'))
    e('add  0x%02X, x' % TU)
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
    e('ld   %s, ac' % z('di'))
    e('inc')
    e('ld   ac, %s' % z('di'))
    e('sub  9, ac')
    e('bne  dl')
    e('ld   %s, y' % z('dreth'))
    e('jmp  %s' % z('dret'))

    g.block('tclear')
    label('tclear')
    e('; timer = 0, frame addend = %d us, step addend = %d us' % (FRAME_US, STEP_US))
    e('ld   0x%02X, ac' % (PT + 8 - TU))
    label('tcl')
    e('add  0x%02X, x' % TU)
    e('ld   0x00, [x]')
    e('sub  1, ac')
    e('bcc  tcl')
    for base, v in ((FR, FRAME_US), (PT, STEP_US)):
        for k in range(9):
            dk = v // 10 ** k % 10
            if dk:
                e('ld   %d, ac' % dk)
                e('ld   ac, [0x%02X]' % (base + k))
    e('ld   %s, y' % z('preth'))
    e('jmp  %s' % z('pret'))

    # ------------------------------------------------------------ stop and show
    g.block('stop')
    label('stop')
    e('; stop the timer: whole frames are counted, add the 128 us steps since')
    e('; the top of this frame')
    g.call('poll', 'pret')
    e('ld   %s, ac' % z('last'))
    e('sub  %d, ac' % LINE0)
    e('ld   ac, %s' % z('tmp'))
    g.st(PT - TU, 'doff')
    label('part')
    e('ld   %s, ac' % z('tmp'))
    e('beq  pdone')
    e('dec')
    e('ld   ac, %s' % z('tmp'))
    g.call('dadd', 'dret')
    e('bra  part')
    label('pdone')
    g.far('show')

    g.block('show')
    label('show')
    e('; "SSS.SSS s" centered below the digits, leading zeros as spaces')
    pg, lo = cell(TCOL, trow)
    g.st(pg, 'cpage')
    g.st(lo, 'crow')
    g.st(0, 'ccol')          # no line wrap
    g.st(0, 'dotf')
    e('; leading zeros of the seconds become spaces (the timer is cleared next)')
    e('ld   [0x%02X], ac' % (TU + 8))
    e('bne  sh1')
    e('ld   11, ac')
    e('ld   ac, [0x%02X]' % (TU + 8))
    e('ld   [0x%02X], ac' % (TU + 7))
    e('bne  sh1')
    e('ld   11, ac')
    e('ld   ac, [0x%02X]' % (TU + 7))
    label('sh1')
    e('; digits 8 down to 3, with "." after the ones digit')
    g.st(TU + 8, 'sx2')
    label('shlp')
    e('ld   %s, x' % z('sx2'))
    e('ld   [x], ac')
    e('ld   ac, %s' % z('dig'))
    g.call('emit')
    e('ld   %s, ac' % z('sx2'))
    e('sub  0x%02X, ac' % (TU + 6))
    e('bne  shnd')
    e('ld   10, ac')
    e('ld   ac, %s' % z('dig'))
    g.call('emit')
    label('shnd')
    e('ld   %s, ac' % z('sx2'))
    e('dec')
    e('ld   ac, %s' % z('sx2'))
    e('sub  0x%02X, ac' % (TU + 2))
    e('bne  shlp')
    for c in (11, 12):
        g.st(c, 'dig')
        g.call('emit')
    g.far('pause')

    g.block('pause')
    label('pause')
    e('; wait 10 s on the timer, then run the test again')
    g.call('tclear', 'pret')
    label('pw')
    g.call('poll', 'pret')
    e('ld   [0x%02X], ac' % (TU + 7))
    e('sub  %d, ac' % WAIT_TENS)
    e('bne  pw')
    label('shown')
    e('; done: the menu goes on to the next program now (when rotating)')
    g.call('hk_done', 'hret')
    g.far('main')

    for name, items in hook_blocks(ZP['hret'], ZP['hreth']):
        g.block(name)
        g.cur.extend(as_lines(items))

    # ------------------------------------------------------------ output
    out = []
    o = out.append
    o('; pi_spigot.asm - generated by gen_pi_spigot.py, do not edit by hand')
    o('; Placard CPU benchmark: Rabinowitz & Wagon spigot, %d digits of pi,' % ndig)
    o('; centered on the screen, timed with the line read, repeated every 10 s.')
    o('; See gen_pi_spigot.py for the method, timer and memory map.')
    o(';')
    o(';     python3 placard_sim.py pi_spigot.asm --run --max-steps 2000000000 --stop-at pause --png pi.png')
    o(';')
    o('; Date: 10/20/2026')
    o('')
    o('#include "placard.asm"')
    o('')
    o('#addr 0x0000')
    o('reset:')
    o('    ld   init >> 8, y')
    o('    jmp  init')
    # each block stays inside one page (branches are page relative); small
    # blocks share a page
    # first fit, largest first, in pages CODE_PG up to the a[i] arrays
    sized = []
    for name, lines in g.blocks:
        size = sum(instr_size(l.split(';')[0]) for l in lines if not l.endswith(':'))
        if size > 256:
            raise SystemExit('block %s is %d bytes, more than a page' % (name, size))
        sized.append((size, name, lines))
    o('')
    o('#addr 0x%04X' % ((FONT_PG << 8) + FONT_LO))
    o('font:      ; 0-9, ".", space and "s", 8 bytes each, leftmost pixel in bit 0')
    for d in range(len(FONT)):
        rev = [int('{:08b}'.format(b)[::-1], 2) for b in FONT[d]]
        o('    #d8 ' + ', '.join('0x%02X' % b for b in rev))
    used, placed = {}, []
    for size, name, lines in sorted(sized, key=lambda b: -b[0]):
        pg = next((p for p in range(CODE_PG, ALO_PG) if used.get(p, 0) + size <= 256), None)
        if pg is None:
            raise SystemExit('code does not fit below the a[i] arrays')
        placed.append(((pg << 8) + used.get(pg, 0), name, lines))
        used[pg] = used.get(pg, 0) + size
    for addr, name, lines in sorted(placed, key=lambda b: b[0]):
        o('')
        o('#addr 0x%04X' % addr)
        if name == 'main':
            o('main:')
        out.extend(lines)
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'pi_spigot.asm')
    with open(path, 'w') as f:
        f.write('\n'.join(out) + '\n')
    # write the hex too, so pi_spigot.hex always matches pi_spigot.asm
    mem, _, _ = assemble('\n'.join(out) + '\n', os.path.dirname(path))
    with open(path[:-4] + '.hex', 'w') as f:
        f.write(to_hexstr(mem) + '\n')
    print('wrote %s and pi_spigot.hex (%d digits, %d terms)' % (path, ndig, ln))


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--digits', type=int, default=1000)
    build(ap.parse_args().digits)

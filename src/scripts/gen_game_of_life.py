#!/usr/bin/env python3
"""
gen_game_of_life.py - generate game_of_life.asm, Conway's Game of Life on the
full 1 bpp screen (632 x 480 cells) for the Placard CPU.

    python3 gen_game_of_life.py                     writes game_of_life.asm
    python3 gen_game_of_life.py --once --gens 3     a build for the simulator:
                                                    3 generations, then halt
    python3 placard_sim.py game_of_life.asm --run --max-steps 100000000 --png g.png
    python3 gen_game_of_life.py --check 3           build, run in placard_sim and
                                                    compare with a Python model

Then put game_of_life.hex into rom.mem with gen_rom.tcl (set
::ASM_FILE to game_of_life.hex) to run it on the board, or use
build\\game_of_life.bat.

SEQUENCE (repeats forever)
    fill the screen with random bytes (about half the cells alive),
    run GENS generations (default 1000), pause about DELAY s (default 5),
    then start again with a new random screen.

THE BOARD
    Byte columns 1-79 by rows 0-479 are the cells, 632 x 480 cells, and
    byte column 0 is cleared and left black.  (Column 0 held the mode bytes
    until they moved to 5A20-5BFF; the board was not widened.)  The edges
    wrap (a torus).
    Pixel i of a byte is bit i, bit 0 on the left.

METHOD
    Bit-parallel: each byte is 8 cells and every step works on whole bytes.
    The screen is column-major, so the program walks one byte column at a
    time from row 0 to row 479; the rows above and below are the next and
    previous addresses.  For each row j of the column it reads the byte C,
    the byte W to its left and E to its right and forms
        L = C << 1 | W bit 7        (each cell's left neighbour)
        R = C >> 1 | E bit 0 << 7   (each cell's right neighbour)
        H = L + C + R   two bit planes a, b   (used as the row above / below)
        M = L + R       two bit planes m0, m1 (used as the middle row)
    and then for row j - 1, with T = H(j-2), B = H(j) and M = M(j-1):
        neighbours n = T + B + M, a 4-bit count per cell
        s0 = aT ^ aB ^ m0           (bit 0 of n)
        k  = bT + bB + m1 + carry   (n = s0 + 2k)
        new = (s0 | C) & (k == 1)   (n == 3, or n == 2 and alive)
    A row whose L, C and R are all zero takes a short path, and a new byte
    whose three rows are all empty is 0 without the arithmetic.
    New values go straight back into the column one row behind the reads.
    The old byte is also copied to a column buffer, which is what the next
    column reads as W.  Column 79 reads its E from a copy of the old
    column 1.  Rows 479 and 0 are read before row 0's step, so the column
    wraps too.

RANDOM NUMBERS
    Additive lagged Fibonacci generator x[n] = x[n-55] + x[n-24] (mod 256),
    the 55 bytes of state in zero page, seeded by this script.  The state
    carries on from one screen to the next, so every restart is different.

RESULT (placard_sim.py --check 1000, seed 1970: all 1000 generations match
the Python model cell for cell; generation 1 also checked with --hw-alu)
    random screen                     3,577,367 clocks     0.14 s
    1000 generations              6,452,703,368 clocks   256 s, 282 s with
                                                         video stalls
    per generation   10.3 M clocks (0.45 s) on the random screen, falling
                     to 5.8 M (0.25 s) by generation 1000 as it thins out;
                     6.45 M (0.28 s) on average, about 3.5 per second
    A row with nothing alive near it costs about 100 clocks per byte, a busy
    one about 270.  The screens are reference/game_of_life_sim.png.

MEMORY
    0000-0003   reset: jump to main
    0010-007F   variables (zero page)
    0080-00B6   random number state (zero page)
    0100-       code
    4000-45FF   column buffers: A 4000-41FF, B 4200-43FF, column 1 4400-45FF
                (laid out like a screen column, row j at page + 0x20 + j)
    5A20-5BFF   mode bytes, one per row (all 0, 1 bpp)
    6000-FFFF   video RAM

Date: 10/16/2026
"""

import argparse
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from placard_sim import instr_size, COND   # noqa: E402
from menu_hook import hook_blocks, as_lines   # noqa: E402

CLOCK_HZ = 25.17483e6
CPU_SHARE = 1 - 38400 / 420000      # video steals 1 clock in 8 during active video

COLS = 79                   # byte columns 1..79
ROWS = 480
BUF_A, BUF_B, BUF_K = 0x40, 0x42, 0x44
RING = 0x80                 # random state, 55 bytes
RING_END = RING + 55
LAG = 24

ZP = {}
_names = ['cp', 'wp', 'ep', 'ob', 'qp', 'px', 'cpb', 'wpb', 'obb', 'epb', 'ccnt',
          'L', 'R', 'T', 'SC', 'U', 'CC', 'RR', 'WW', 'NQ',
          'a0s', 'b0s', 'o0s', 'gl', 'gh', 'ri', 'rj', 'rv', 'fx', 'fy',
          'dl1', 'dl2', 'dl3', 'hret', 'hreth']
for _s in range(3):
    _names += ['a%d' % _s, 'b%d' % _s, 'm0%d' % _s, 'm1%d' % _s, 'c%d' % _s, 'o%d' % _s]
for _i, _n in enumerate(_names):
    ZP[_n] = 0x10 + _i
assert max(ZP.values()) < RING


def z(n):
    return '[0x%02X]' % ZP[n]


# ---------------------------------------------------------------------------
# Code is built from atoms: short runs of lines whose branches all stay
# inside the atom.  The layout keeps each atom's branches in one page and
# fills any gap it leaves with nops or a jump (y is never live between atoms).
# ---------------------------------------------------------------------------
class Gen:
    def __init__(self):
        self.atoms = []
        self.cur = None
        self.n = 0

    def atom(self):
        self.cur = []
        self.atoms.append(self.cur)

    def e(self, s):
        self.cur.append('    ' + s)

    def label(self, s):
        self.cur.append(s + ':')

    def uniq(self, p):
        self.n += 1
        return '%s_%d' % (p, self.n)

    def far(self, target):
        self.e('ld   %s >> 8, y' % target)
        self.e('jmp  %s' % target)

    def st(self, v, name):
        self.e('ld   0x%02X, ac' % (v & 0xFF))
        self.e('ld   ac, %s' % z(name))

    def call(self, target, slot):
        r = self.uniq('ret')
        self.e('ld   %s, ac' % r)
        self.e('ld   ac, %s' % z(slot))
        self.e('ld   %s >> 8, ac' % r)
        self.e('ld   ac, %s' % z(slot + 'h'))
        self.far(target)
        self.label(r)


def layout(atoms, start):
    """place the atoms from address start; returns the lines with fillers"""
    out = []
    addr = start
    nfill = 0
    for at in atoms:
        def fits(base):
            labels, a, brs = {}, base, []
            for ln in at:
                if ln.endswith(':'):
                    labels[ln[:-1]] = a
                    continue
                code = ln.split(';')[0].strip()
                if not code:
                    continue
                parts = code.split(None, 1)
                if parts[0] in COND and len(parts) > 1 and not parts[1].startswith('[') \
                        and parts[1].strip() not in ('ac', 'x'):
                    brs.append((a, parts[1].strip()))
                a += instr_size(code)
            for ba, t in brs:
                if t not in labels:
                    raise SystemExit('branch to %s leaves its atom' % t)
                if (ba + 2) >> 8 != labels[t] >> 8:
                    return None
            return a
        end = fits(addr)
        if end is None:
            nxt = (addr | 0xFF) + 1
            g = nxt - addr
            nfill += 1
            lab = 'fill_%d' % nfill
            if g == 1:
                out.append('    nop')
            elif g <= 3:
                out.extend(['    nop'] * (g - 2) + ['    bra  %s' % lab])
            else:
                out.extend(['    ld   %s >> 8, y' % lab, '    jmp  %s' % lab])
            out.append('#addr 0x%04X' % nxt)
            out.append(lab + ':')
            addr = nxt
            end = fits(addr)
            if end is None:
                raise SystemExit('atom does not fit in a page')
        out.extend(at)
        addr = end
    return out, addr


# ---------------------------------------------------------------------------
# program pieces
# ---------------------------------------------------------------------------
def read_row(g, s, name=None):
    """read row at X (pages cp, wp, ep), save C to ob, fill slot s"""
    e, label = g.e, g.label
    a, b, m0, m1, c, o = ['%s%d' % (v, s) for v in ('a', 'b', 'm0', 'm1', 'c', 'o')]
    w1, wd, e0, ed, done = [g.uniq(p) for p in ('w1', 'wd', 'e0', 'ed', 'rd')]
    cz, zw1, zk1, zk = [g.uniq(p) for p in ('cz', 'zw1', 'zk1', 'zk')]
    g.atom()
    if name:
        label(name)
    e('ld   %s, y' % z('cp'))
    e('ld   [y,x], ac            ; C')
    e('ld   ac, %s' % z(c))
    e('ld   %s, y' % z('ob'))
    e('ld   ac, [y,x]            ; old C for the next column')
    e('beq  %s' % cz)
    e('ld   %s, y' % z('wp'))
    e('ld   [y,x], ac            ; W')
    e('blt  %s' % w1)
    e('ld   %s, ac' % z(c))
    e('shl')
    e('bra  %s' % wd)
    label(w1)
    e('ld   %s, ac' % z(c))
    e('shl')
    e('or   1, ac')
    label(wd)
    e('ld   ac, %s' % z('L'))
    e('ld   %s, y' % z('ep'))
    e('ld   [y,x], ac            ; E')
    e('and  1, ac')
    e('beq  %s' % e0)
    e('ld   %s, ac' % z(c))
    e('shr  ac')
    e('or   0x80, ac')
    e('bra  %s' % ed)
    label(e0)
    e('ld   %s, ac' % z(c))
    e('shr  ac')
    label(ed)
    e('ld   ac, %s' % z('R'))
    e('and  %s, ac' % z('L'))
    e('ld   ac, %s                ; m1 = L & R' % z(m1))
    e('ld   %s, ac' % z('R'))
    e('xor  %s, ac' % z('L'))
    e('ld   ac, %s                ; m0 = L ^ R' % z(m0))
    e('xor  %s, ac' % z(c))
    e('ld   ac, %s                ; a = L ^ C ^ R' % z(a))
    e('ld   %s, ac' % z(m0))
    e('and  %s, ac' % z(c))
    e('or   %s, ac' % z(m1))
    e('ld   ac, %s                ; b = majority(L, C, R)' % z(b))
    e('or   %s, ac' % z(a))
    e('ld   ac, %s                ; o = L | C | R' % z(o))
    e('bra  %s' % done)
    label(cz)
    e('; C = 0: L = W bit 7, R = E bit 0 << 7, so m1 = b = 0, m0 = a = o = L | R')
    e('ld   ac, %s' % z(m1))
    e('ld   ac, %s' % z(b))
    e('ld   %s, y' % z('wp'))
    e('ld   [y,x], ac')
    e('ld   %s, y' % z('ep'))
    e('or   [y,x], ac')
    e('beq  %s                ; W, C and E all 0' % zk)
    e('ld   %s, y' % z('wp'))
    e('ld   [y,x], ac')
    e('blt  %s' % zw1)
    e('ld   %s, y' % z('ep'))
    e('ld   [y,x], ac')
    e('and  1, ac')
    e('beq  %s' % zk)
    e('ld   0x80, ac')
    e('bra  %s' % zk)
    label(zw1)
    e('ld   %s, y' % z('ep'))
    e('ld   [y,x], ac')
    e('and  1, ac')
    e('beq  %s' % zk1)
    e('ld   0x81, ac')
    e('bra  %s' % zk)
    label(zk1)
    e('ld   1, ac')
    label(zk)
    e('ld   ac, %s' % z(m0))
    e('ld   ac, %s' % z(a))
    e('ld   ac, %s' % z(o))
    label(done)
    e('nop')        # keeps the done label inside the atom


def new_byte(g, t, m, u, wpage):
    """AC = next state of the row whose rows above / at / below are slots
    t, m, u (u may be 's' = the saved row 0); write it at [wpage, px]"""
    e, label = g.e, g.label
    v = lambda n, s: '%s%s' % (n, s if s != 's' else 's')
    aT, bT, oT = 'a%d' % t, 'b%d' % t, 'o%d' % t
    if u == 's':
        aB, bB, oB = 'a0s', 'b0s', 'o0s'
    else:
        aB, bB, oB = 'a%d' % u, 'b%d' % u, 'o%d' % u
    m0, m1, c, oM = 'm0%d' % m, 'm1%d' % m, 'c%d' % m, 'o%d' % m
    zo = g.uniq('zo')
    g.atom()
    e('ld   %s, ac' % z(oT))
    e('or   %s, ac' % z(oM))
    e('or   %s, ac' % z(oB))
    e('beq  %s                ; nothing alive nearby: stays 0, no write' % zo)
    e('ld   %s, ac' % z(aT))
    e('xor  %s, ac' % z(aB))
    e('ld   ac, %s' % z('T'))
    e('xor  %s, ac' % z(m0))
    e('or   %s, ac' % z(c))
    e('ld   ac, %s                ; SC = s0 | C' % z('SC'))
    e('ld   %s, ac' % z(aT))
    e('and  %s, ac' % z(aB))
    e('ld   ac, %s' % z('U'))
    e('ld   %s, ac' % z('T'))
    e('and  %s, ac' % z(m0))
    e('or   %s, ac' % z('U'))
    e('ld   ac, %s                ; CC = carry out of bit 0' % z('CC'))
    e('xor  %s, ac' % z(m1))
    e('ld   ac, %s' % z('RR'))
    e('ld   %s, ac' % z('CC'))
    e('and  %s, ac' % z(m1))
    e('ld   ac, %s' % z('WW'))
    e('ld   %s, ac' % z(bT))
    e('and  %s, ac' % z(bB))
    e('or   %s, ac' % z('WW'))
    e('not')
    e('ld   ac, %s' % z('NQ'))
    e('ld   %s, ac' % z(bT))
    e('xor  %s, ac' % z(bB))
    e('xor  %s, ac' % z('RR'))
    e('and  %s, ac' % z('NQ'))
    e('and  %s, ac                ; k == 1 and (s0 | C)' % z('SC'))
    e('ld   %s, x' % z('px'))
    e('ld   %s, y' % z(wpage))
    e('ld   ac, [y,x]')
    label(zo)


def tail(g, exit_to=None, cont=None):
    """px += 1, X = px + 1; leave for exit_to when X wraps to 0.  Joins the
    atom of new_byte, whose zero path lands here."""
    e, label = g.e, g.label
    e('ld   %s, ac' % z('px'))
    e('inc')
    e('ld   ac, %s' % z('px'))
    e('inc')
    e('ld   ac, x')
    if exit_to:
        ok = g.uniq('ok')
        e('bne  %s' % ok)
        g.far(exit_to)
        label(ok)
        e('nop')
    if cont:
        g.atom()
        g.far(cont)


def delay_counts(seconds):
    """three nested down-counters; the inner loop is nop / dec / bne = 8 clocks"""
    if seconds <= 0:
        return None
    clocks = seconds * CLOCK_HZ * CPU_SHARE
    inner = 256 * 8 + 15
    middle = 256 * inner + 15
    outer = max(1, min(256, round(clocks / middle)))
    return outer % 256


def ring_seed(seed):
    rnd = random.Random(seed)
    r = [rnd.randrange(256) for _ in range(55)]
    r[0] |= 1
    return r


def build(gens, once, delay, seed):
    g = Gen()
    e, label, atom = g.e, g.label, g.atom

    # ------------------------------------------------------------ main
    atom()
    label('main')
    g.st(RING, 'ri')
    g.st(RING + 55 - LAG, 'rj')
    e('; mode byte 0 (1 bpp) for every row: 5A20-5BFF')
    e('ld   0x5A, y')
    e('ld   0x20, ac')
    label('md0')
    e('ld   ac, x')
    e('ld   0x00, [y,x]')
    e('inc')
    e('bne  md0')
    e('ld   0x5B, y')
    label('md1')
    e('ld   ac, x')
    e('ld   0x00, [y,x]')
    e('inc')
    e('bne  md1')
    e('; byte column 0 (6020-61FF) is not part of the board: clear it')
    e('ld   0x60, y')
    e('ld   0x20, ac')
    label('md2')
    e('ld   ac, x')
    e('ld   0x00, [y,x]')
    e('inc')
    e('bne  md2')
    e('ld   0x61, y')
    label('md3')
    e('ld   ac, x')
    e('ld   0x00, [y,x]')
    e('inc')
    e('bne  md3')

    # ------------------------------------------------------------ random screen
    atom()
    label('restart')
    e('; random bytes into 6200-FFFF (the gaps between columns are not shown)')
    g.st(0x62, 'fy')
    label('fl_pg')
    e('clr  ac')
    e('ld   ac, %s' % z('fx'))
    atom()
    label('fl_b')
    e('ld   %s, x' % z('ri'))
    e('ld   [x], ac')
    e('ld   %s, x' % z('rj'))
    e('add  [x], ac')
    e('ld   %s, x' % z('ri'))
    e('ld   ac, [x]              ; x[n] = x[n-55] + x[n-24]')
    e('ld   ac, %s' % z('rv'))
    e('ld   %s, ac' % z('ri'))
    e('inc')
    e('ld   ac, %s' % z('ri'))
    e('sub  0x%02X, ac' % RING_END)
    e('bne  fl_i')
    g.st(RING, 'ri')
    label('fl_i')
    e('ld   %s, ac' % z('rj'))
    e('inc')
    e('ld   ac, %s' % z('rj'))
    e('sub  0x%02X, ac' % RING_END)
    e('bne  fl_j')
    g.st(RING, 'rj')
    label('fl_j')
    e('ld   %s, ac' % z('rv'))
    e('ld   %s, x' % z('fx'))
    e('ld   %s, y' % z('fy'))
    e('ld   ac, [y,x]')
    e('ld   %s, ac' % z('fx'))
    e('inc')
    e('ld   ac, %s' % z('fx'))
    e('beq  fl_n')
    g.far('fl_b')
    label('fl_n')
    e('ld   %s, ac' % z('fy'))
    e('inc')
    e('ld   ac, %s' % z('fy'))
    e('beq  fl_d')
    g.far('fl_pg')
    label('fl_d')
    hi, lo = (gens - 1) // 256, gens - 256 * ((gens - 1) // 256)
    g.st(lo, 'gl')
    g.st(hi, 'gh')

    # ------------------------------------------------------------ one generation
    atom()
    label('gen')
    g.st(0x62, 'cpb')
    g.st(0xFE, 'wpb')          # column 1 reads W from the old column 79
    g.st(BUF_K, 'obb')         # and keeps its old bytes for column 79
    g.st(COLS, 'ccnt')
    atom()
    label('col')
    e('; the program menu\'s hook (Esc, time up: menu_hook.py), once a column')
    g.call('hk_poll', 'hret')
    e('; E page: next column, or the copy of column 1 for column 79')
    e('ld   %s, ac' % z('ccnt'))
    e('dec')
    e('beq  col_l')
    e('ld   %s, ac' % z('cpb'))
    e('add  2, ac')
    e('bra  col_e')
    label('col_l')
    e('ld   0x%02X, ac' % BUF_K)
    label('col_e')
    e('ld   ac, %s' % z('epb'))
    e('; pages + 1 for row 479')
    for v in ('cp', 'wp', 'ob', 'ep'):
        e('ld   %s, ac' % z(v + 'b' if v != 'ob' else 'obb'))
        e('inc')
        e('ld   ac, %s' % z(v))
    e('ld   0xFF, x')
    read_row(g, 2)
    atom()
    for v in ('cp', 'wp', 'ob', 'ep'):
        e('ld   %s, ac' % z(v + 'b' if v != 'ob' else 'obb'))
        e('ld   ac, %s' % z(v))
    e('ld   0x20, x')
    read_row(g, 0)
    atom()
    for v in ('a', 'b', 'o'):
        e('ld   %s, ac' % z(v + '0'))
        e('ld   ac, %s' % z(v + '0s'))
    g.st(0x20, 'px')
    e('ld   0x21, x')

    # ------------------------------------------------------------ the row loop
    # step r reads row r + 1 into slot (r + 1) % 3 and writes row r.
    # rows 0-222: step0..2 with the page vars at the first page.
    # step 222 (sub-step 0) wraps X: pages + 1, then step 223 writes its row
    # on the old page (qp).  Steps 224-478 run on the second page; step 478
    # (sub-step 1) wraps X again, and step 479 uses the saved row 0.
    for k in range(3):
        read_row(g, (k + 1) % 3, 'step%d' % k)
        new_byte(g, (k + 2) % 3, k, (k + 1) % 3, 'cp')
        if k == 0:
            tail(g, exit_to='half')
        elif k == 1:
            tail(g, exit_to='last')
        else:
            tail(g, cont='step0')

    atom()
    label('half')
    e('ld   %s, ac' % z('cp'))
    e('ld   ac, %s' % z('qp'))
    for v in ('cp', 'wp', 'ob', 'ep'):
        e('ld   %s, ac' % z(v))
        e('inc')
        e('ld   ac, %s' % z(v))
    e('; step 223')
    read_row(g, 2)
    new_byte(g, 0, 1, 2, 'qp')
    tail(g, cont='step2')

    atom()
    label('last')
    e('; step 479')
    new_byte(g, 1, 2, 's', 'cp')
    atom()
    e('; next column: its W is this column\'s buffer, buffers A / B alternate')
    e('ld   %s, ac' % z('obb'))
    e('ld   ac, %s' % z('wpb'))
    e('sub  0x%02X, ac' % BUF_A)
    e('beq  nc_b')
    e('ld   0x%02X, ac' % BUF_A)
    e('bra  nc_o')
    label('nc_b')
    e('ld   0x%02X, ac' % BUF_B)
    label('nc_o')
    e('ld   ac, %s' % z('obb'))
    e('ld   %s, ac' % z('cpb'))
    e('add  2, ac')
    e('ld   ac, %s' % z('cpb'))
    e('ld   %s, ac' % z('ccnt'))
    e('dec')
    e('ld   ac, %s' % z('ccnt'))
    e('beq  nc_d')
    g.far('col')
    label('nc_d')
    e('nop')

    atom()
    e('; generation count')
    e('ld   %s, ac' % z('gl'))
    e('dec')
    e('ld   ac, %s' % z('gl'))
    e('bne  gc_more')
    e('ld   %s, ac' % z('gh'))
    e('beq  gc_done')
    e('dec')
    e('ld   ac, %s' % z('gh'))
    label('gc_more')
    g.far('gen')
    label('gc_done')
    e('nop')

    atom()
    if once:
        label('halt')
        e('bra  halt')
    else:
        cnt = delay_counts(delay)
        if cnt is not None:
            e('; about %g s at %.3f MHz, less the video stalls' % (delay, CLOCK_HZ / 1e6))
            g.st(cnt, 'dl3')
            label('dly3')
            g.st(0, 'dl2')
            label('dly2')
            g.call('hk_poll', 'hret')
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
        e('; done: the menu goes on to the next program now (when rotating)')
        g.call('hk_done', 'hret')
        g.far('restart')

    for name, items in hook_blocks(ZP['hret'], ZP['hreth']):
        atom()
        g.cur.extend(as_lines(items))

    code, top = layout(g.atoms, 0x0100)
    if top > BUF_A << 8:
        raise SystemExit('code runs into the column buffers')

    # ------------------------------------------------------------ output
    out = []
    o = out.append
    o('; game_of_life.asm - generated by gen_game_of_life.py, do not edit by hand')
    o('; Placard CPU: Conway\'s Game of Life on the 632 x 480 1 bpp screen (a torus).')
    o('; Random screen, %d generations, %s.' % (
        gens, 'then halt (simulator build)' if once else
        'about %g s pause, then a new random screen' % delay))
    o('; See gen_game_of_life.py for the method and memory map.')
    o(';')
    o(';     python3 placard_sim.py game_of_life.asm --run --max-steps 100000000 --png g.png')
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
    o('#addr 0x%04X' % RING)
    o('ring:      ; random number state, x[n-55] .. x[n-1]')
    seedv = ring_seed(seed)
    for r in range(0, 55, 11):
        o('    #d8 ' + ', '.join('0x%02X' % v for v in seedv[r:r + 11]))
    o('')
    o('#addr 0x0100')
    out.extend(code)
    return out, seedv


# ---------------------------------------------------------------------------
# Python model
# ---------------------------------------------------------------------------
def model_start(seedv):
    """the random screen the program draws from the generator state seedv,
    as a 480 x 632 array of cells"""
    import numpy as np
    ring = list(seedv)
    ri, rj = 0, 55 - LAG
    vid = {}
    for a in range(0x6200, 0x10000):
        v = (ring[ri] + ring[rj]) & 0xFF
        ring[ri] = v
        ri = (ri + 1) % 55
        rj = (rj + 1) % 55
        vid[a] = v
    b = np.zeros((ROWS, COLS * 8), dtype=np.uint8)
    for c in range(1, COLS + 1):
        for r in range(ROWS):
            v = vid[0x6020 + 512 * c + r]
            for i in range(8):
                b[r, (c - 1) * 8 + i] = (v >> i) & 1
    return b


def model_step(b):
    """one Life generation on the torus"""
    import numpy as np
    n = sum(np.roll(np.roll(b, dy, 0), dx, 1)
            for dy in (-1, 0, 1) for dx in (-1, 0, 1) if dy or dx)
    return ((n == 3) | ((n == 2) & (b == 1))).astype(np.uint8)


def model_screens(seedv, gens_list):
    """{generation: cells} for each count in gens_list"""
    b = model_start(seedv)
    res, g = {}, 0
    for want in sorted(gens_list):
        while g < want:
            b = model_step(b)
            g += 1
        res[want] = b.copy()
    return res


def screen_cells(mem):
    import numpy as np
    b = np.zeros((ROWS, COLS * 8), dtype=np.uint8)
    for c in range(1, COLS + 1):
        base = 0x6020 + 512 * c
        for r in range(ROWS):
            v = mem[base + r]
            for i in range(8):
                b[r, (c - 1) * 8 + i] = (v >> i) & 1
    return b


def write_asm(lines):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'game_of_life.asm')
    with open(path, 'w') as f:
        f.write('\n'.join(lines) + '\n')
    return path


def check(gens, seed):
    """run the simulator for gens generations and compare with the model"""
    import placard_sim as ps
    lines, seedv = build(gens, True, 0, seed)
    mem, syms, _ = ps.assemble('\n'.join(lines))
    cpu = ps.Cpu(mem)
    # stop at the start of each generation to compare
    gen_pc = syms['gen']
    want = model_start(seedv)
    g = 0
    clocks0 = None
    per = []
    while True:
        here = cpu.step()
        if cpu.pc == gen_pc or (cpu.pc == here and ps.m_is_branch(cpu.mem[here])):
            if clocks0 is not None:
                per.append(cpu.clocks - clocks0)
            else:
                fill = cpu.clocks
            clocks0 = cpu.clocks
            got = screen_cells(cpu.mem)
            ok = (got == want).all()
            print('generation %4d  %s  live cells %6d  clocks %s'
                  % (g, 'match' if ok else 'MISMATCH (%d cells)' % (got != want).sum(),
                     int(got.sum()), per[-1] if per else fill), flush=True)
            if not ok or g == gens:
                break
            g += 1
            want = model_step(want)
    if per:
        t = sum(per)
        sec = lambda c: c / CLOCK_HZ
        print('RESULT  random screen %d clocks, %d generations %d clocks,'
              ' %.0f per generation' % (fill, len(per), t, t / len(per)))
        print('        %.3f s per generation at %.3f MHz, %.3f s with video stalls'
              % (sec(t / len(per)), CLOCK_HZ / 1e6, sec(t / len(per)) / CPU_SHARE))
    return per


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--gens', type=int, default=1000, help='generations per screen')
    ap.add_argument('--once', action='store_true',
                    help='one random screen, then halt (for the simulator)')
    ap.add_argument('--delay', type=float, default=5.0,
                    help='pause after the last generation, seconds (0 = none)')
    ap.add_argument('--seed', type=int, default=1970, help='random state seed')
    ap.add_argument('--check', type=int, metavar='N',
                    help='simulate N generations and compare with the Python model')
    a = ap.parse_args()
    if a.check:
        check(a.check, a.seed)
    else:
        lines, _ = build(a.gens, a.once, a.delay, a.seed)
        print('wrote', write_asm(lines))

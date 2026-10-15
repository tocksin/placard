#!/usr/bin/env python3
"""
gen_pi_spigot.py - generate pi_spigot.asm, a Rabinowitz & Wagon spigot
benchmark for the Placard CPU: exact decimal digits of pi using integer
arithmetic only, printed to the screen as they are produced.

    python3 gen_pi_spigot.py                 1000 digits -> pi_spigot.asm
    python3 gen_pi_spigot.py --digits 50     a quick test build
    python3 placard_sim.py pi_spigot.asm --run --max-steps 2000000000 --png pi.png

Then merge pi_spigot.hex into video_ram.mem with gen_video_ram.tcl (set
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
    The CPU has no carry flag, so multi-byte values are kept in "base 128":
    value = limb2 * 16384 + limb1 * 128 + limb0, limbs 0..127.  A carry or
    borrow out of a limb lands in bit 7, the N flag, and is tested with a
    branch.
    - 10 * a[i] and q * i come from a product table T[m][v] = m * v
      (m = 0..20, v = 0..127, two base-128 limbs), applied to each 7-bit
      limb of a[i] and i.  The table is ROM data built by this script.
    - x div (2i - 1) is a software restoring division: q <= 18 < 32, so
      five compare-and-subtract steps against (2i - 1) << k, k = 4..0.
      The five shifted divisors are counters that step down by 2 << k as
      i steps down, so no shifts are needed in the loop.
    - a[i] is two byte arrays (low limb, high limb) walked by pointer.

SCREEN (1 bpp)
    Digits in the 8x8 font, 79 per line, "3." first.  The screen is cleared
    and every mode byte set to 1 bpp first.

RESULT (placard_sim.py, 1000 digits, all match pi; 50 digits also checked
with --hw-alu)
    635,770,131 instructions, 2,123,927,763 clocks (about 637 per term)
        84.4 s at 25.175 MHz with no video
        92.9 s with the CPU stalled on every video byte fetch (1 clock in 8
               during active video, 9.1% of all clocks)
    The screen is reference/pi_spigot_sim.png.

MEMORY
    0000-0003   reset: jump to main
    0010-004F   variables (zero page)
    0100-07FF   code; font at 0700
    0800-15FF   a[i] low limbs  (address 0800 + i)
    1600-23FF   a[i] high limbs (address 1600 + i)
    2400-38FF   product table low limbs,  page 24 + m
    3900-4DFF   product table high limbs, page 39 + m
    6000-FFFF   video RAM

Date: 10/15/2026
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from placard_sim import instr_size   # noqa: E402

ALO_PG, AHI_PG = 0x08, 0x16
TLO_PG, THI_PG = 0x24, 0x39
TMAX = 20
FONT_PG = 0x07
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
}

ZP = {}
for _i, _n in enumerate(
        ['x0', 'x1', 'x2', 't0', 't1', 'q', 'al', 'ah', 'il', 'ih', 'px', 'py',
         'pre', 'nines', 'first', 'fill', 'dig', 'dotf', 'cpage', 'crow',
         'ccol', 'rhi', 'gx', 'sx', 'tmp', 'ret', 'reth', 'jl', 'jh'] +
        ['d%d%d' % (k, l) for k in range(5) for l in range(3)]):
    ZP[_n] = 0x10 + _i


def z(n):
    return '[0x%02X]' % ZP[n]


def limbs(v, n):
    return [(v >> (7 * j)) & 0x7F for j in range(n)]


class Gen:
    def __init__(self):
        self.blocks = []        # list of (name, lines)
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

    def call(self, target):
        r = self.uniq('ret')
        self.e('ld   %s, ac' % r)
        self.e('ld   ac, %s' % z('ret'))
        self.e('ld   %s >> 8, ac' % r)
        self.e('ld   ac, %s' % z('reth'))
        self.far(target)
        self.label(r)


def build(ndig):
    ln = 10 * ndig // 3 + 1
    if ALO_PG * 256 + ln >= AHI_PG * 256:
        raise SystemExit('too many digits for the array space')
    g = Gen()
    e, label = g.e, g.label

    # ------------------------------------------------------------ setup
    g.block('main')
    e('; clear video RAM 6000-FFFF (mode bytes 0 = 1 bpp, pixels off)')
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
    e('; a[i] = 2: low limb pages = 2, high limb pages = 0')
    g.st(ALO_PG, 'tmp')
    label('fill_pg')
    e('ld   %s, y' % z('tmp'))
    e('clr  x')
    label('fill_b')
    e('ld   0x02, [y,x]')
    e('ld   %s, ac' % z('tmp'))
    e('add  0x%02X, y' % (AHI_PG - ALO_PG))
    e('ld   0x00, [y,x]')
    e('ld   %s, y' % z('tmp'))
    e('ld   x, ac')
    e('inc')
    e('ld   ac, x')
    e('bne  fill_b')
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
    g.st(0x62, 'cpage')      # byte column 1, row 0 = 0x6220
    g.st(0x20, 'crow')
    g.st(0, 'rhi')
    g.st(79, 'ccol')
    jl, jh = limbs(ndig, 2)
    g.st(jl, 'jl')
    g.st(jh, 'jh')
    e('; ---- one digit per pass ----')
    label('outer')
    g.st(0, 'q')
    il, ih = limbs(ln, 2)
    g.st(il, 'il')
    g.st(ih, 'ih')
    p = ALO_PG * 256 + ln
    g.st(p & 0xFF, 'px')
    g.st(p >> 8, 'py')
    for k in range(5):
        for l, v in enumerate(limbs((2 * ln - 1) << k, 3)):
            g.st(v, 'd%d%d' % (k, l))
    g.far('inner')

    # ------------------------------------------------------------ x = 10 a[i] + q i
    def csub(k):
        """if x >= (2i-1) << k: x -= it, q += 1 << k"""
        n0, m0, n1, m1, skip = [g.uniq(s) for s in ('n0', 'm0', 'n1', 'm1', 'ns')]
        e('; k = %d' % k)
        e('ld   %s, ac' % z('x0'))
        e('sub  %s, ac' % z('d%d0' % k))
        e('bge  %s' % n0)
        e('and  0x7F, ac')
        e('ld   ac, %s' % z('t0'))
        e('ld   %s, ac' % z('x1'))
        e('dec')
        e('bra  %s' % m0)
        label(n0)
        e('ld   ac, %s' % z('t0'))
        e('ld   %s, ac' % z('x1'))
        label(m0)
        e('sub  %s, ac' % z('d%d1' % k))
        e('bge  %s' % n1)
        e('and  0x7F, ac')
        e('ld   ac, %s' % z('t1'))
        e('ld   %s, ac' % z('x2'))
        e('dec')
        e('bra  %s' % m1)
        label(n1)
        e('ld   ac, %s' % z('t1'))
        e('ld   %s, ac' % z('x2'))
        label(m1)
        e('sub  %s, ac' % z('d%d2' % k))
        e('blt  %s' % skip)
        e('ld   ac, %s' % z('x2'))
        e('ld   %s, ac' % z('t1'))
        e('ld   ac, %s' % z('x1'))
        e('ld   %s, ac' % z('t0'))
        e('ld   ac, %s' % z('x0'))
        e('ld   %s, ac' % z('q'))
        e('or   0x%02X, ac' % (1 << k))
        e('ld   ac, %s' % z('q'))
        label(skip)

    g.block('inner')
    label('inner')
    e('; a[i] -> al, ah')
    e('ld   %s, x' % z('px'))
    e('ld   %s, y' % z('py'))
    e('ld   [y,x], ac')
    e('ld   ac, %s' % z('al'))
    e('ld   %s, ac' % z('py'))
    e('add  0x%02X, y' % (AHI_PG - ALO_PG))
    e('ld   [y,x], ac')
    e('ld   ac, %s' % z('ah'))
    e('; 10 * a[i]: x0 = T[10][al].lo, x1 = T[10][al].hi, x2 = T[10][ah].hi, t0 = T[10][ah].lo')
    e('ld   %s, x' % z('al'))
    e('ld   0x%02X, y' % (TLO_PG + 10))
    e('ld   [y,x], ac')
    e('ld   ac, %s' % z('x0'))
    e('ld   0x%02X, y' % (THI_PG + 10))
    e('ld   [y,x], ac')
    e('ld   ac, %s' % z('x1'))
    e('ld   %s, x' % z('ah'))
    e('ld   [y,x], ac')
    e('ld   ac, %s' % z('x2'))
    e('ld   0x%02X, y' % (TLO_PG + 10))
    e('ld   [y,x], ac')
    e('ld   ac, %s' % z('t0'))
    e('; + q * i, low limbs of the table')
    e('ld   %s, ac' % z('q'))
    e('add  0x%02X, y' % TLO_PG)
    e('ld   %s, x' % z('il'))
    e('ld   [y,x], ac')
    e('add  %s, ac' % z('x0'))
    e('bge  qi0')
    e('and  0x7F, ac')
    e('ld   ac, %s' % z('x0'))
    e('ld   %s, ac' % z('x1'))
    e('inc')
    e('ld   ac, %s' % z('x1'))
    e('bra  qi1')
    label('qi0')
    e('ld   ac, %s' % z('x0'))
    label('qi1')
    e('ld   %s, x' % z('ih'))
    e('ld   [y,x], ac')
    e('add  %s, ac' % z('t0'))
    e('bge  qi2')
    e('and  0x7F, ac')
    e('ld   ac, %s' % z('t0'))
    e('ld   %s, ac' % z('x2'))
    e('inc')
    e('ld   ac, %s' % z('x2'))
    e('bra  qi3')
    label('qi2')
    e('ld   ac, %s' % z('t0'))
    label('qi3')
    e('; high limbs of the table')
    e('ld   %s, ac' % z('q'))
    e('add  0x%02X, y' % THI_PG)
    e('ld   %s, x' % z('il'))
    e('ld   [y,x], ac')
    e('add  %s, ac' % z('x1'))
    e('add  %s, ac' % z('t0'))
    e('bge  qi4')
    e('and  0x7F, ac')
    e('ld   ac, %s' % z('x1'))
    e('ld   %s, ac' % z('x2'))
    e('inc')
    e('ld   ac, %s' % z('x2'))
    e('bra  qi5')
    label('qi4')
    e('ld   ac, %s' % z('x1'))
    label('qi5')
    e('ld   %s, x' % z('ih'))
    e('ld   [y,x], ac')
    e('add  %s, ac' % z('x2'))
    e('ld   ac, %s' % z('x2'))
    e('; x div (2i - 1)')
    g.st(0, 'q')
    csub(4)
    g.far('div2')

    g.block('div2')
    label('div2')
    csub(3)
    csub(2)
    csub(1)
    csub(0)
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
    e('; step the pointer, i and the five divisors down')
    e('ld   %s, ac' % z('px'))
    e('bne  pnz')
    e('ld   %s, ac' % z('py'))
    e('dec')
    e('ld   ac, %s' % z('py'))
    e('ld   %s, ac' % z('px'))
    label('pnz')
    e('dec')
    e('ld   ac, %s' % z('px'))
    e('ld   %s, ac' % z('il'))
    e('dec')
    e('bge  inz')
    e('and  0x7F, ac')
    e('ld   ac, %s' % z('il'))
    e('ld   %s, ac' % z('ih'))
    e('dec')
    e('ld   ac, %s' % z('ih'))
    e('bra  idone')
    label('inz')
    e('ld   ac, %s' % z('il'))
    label('idone')
    for k in range(5):
        ok, done = g.uniq('dok'), g.uniq('dd')
        e('ld   %s, ac' % z('d%d0' % k))
        e('sub  0x%02X, ac' % (2 << k))
        e('bge  %s' % ok)
        e('and  0x7F, ac')
        e('ld   ac, %s' % z('d%d0' % k))
        e('ld   %s, ac' % z('d%d1' % k))
        e('dec')
        e('bge  %s' % done)
        e('and  0x7F, ac')
        e('ld   ac, %s' % z('d%d1' % k))
        e('ld   %s, ac' % z('d%d2' % k))
        e('dec')
        e('ld   ac, %s' % z('d%d2' % k))
        e('bra  %s' % g.uniq('dx'))
        dx = 'dx_%d' % g.n
        label(ok)
        e('ld   ac, %s' % z('d%d0' % k))
        e('bra  %s' % dx)
        label(done)
        e('ld   ac, %s' % z('d%d1' % k))
        label(dx)
    e('; loop while i > 1')
    e('ld   %s, ac' % z('ih'))
    e('bne  again')
    e('ld   %s, ac' % z('il'))
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
    e('; digits left (base 128 counter)')
    e('ld   %s, ac' % z('jl'))
    e('dec')
    e('bge  jok')
    e('and  0x7F, ac')
    e('ld   ac, %s' % z('jl'))
    e('ld   %s, ac' % z('jh'))
    e('dec')
    e('ld   ac, %s' % z('jh'))
    e('bra  jtest')
    label('jok')
    e('ld   ac, %s' % z('jl'))
    label('jtest')
    e('ld   %s, ac' % z('jl'))
    e('or   %s, ac' % z('jh'))
    e('beq  finish')
    g.far('outer')
    label('finish')
    e('ld   %s, ac' % z('pre'))
    e('ld   ac, %s' % z('dig'))
    g.call('emit')
    label('done')
    e('bra  done')

    # ------------------------------------------------------------ emit a digit
    g.block('emit')
    label('emit')
    e('; draw glyph [dig] at the cursor, then a "." after the first digit')
    e('ld   %s, ac' % z('dig'))
    e('shl')
    e('shl')
    e('shl')
    e('ld   ac, %s' % z('gx'))
    e('ld   %s, ac' % z('crow'))
    e('ld   ac, %s' % z('sx'))
    for r in range(8):
        e('ld   %s, x' % z('gx'))
        e('ld   0x%02X, y' % FONT_PG)
        e('ld   [y,x], ac')
        e('ld   ac, %s' % z('tmp'))
        e('ld   %s, x' % z('sx'))
        e('ld   %s, y' % z('cpage'))
        e('ld   %s, ac' % z('tmp'))
        e('ld   ac, [y,x]')
        if r < 7:
            e('ld   %s, ac' % z('gx'))
            e('inc')
            e('ld   ac, %s' % z('gx'))
            e('ld   x, ac')
            e('inc')
            e('ld   ac, %s' % z('sx'))
    e('; next character cell')
    e('ld   %s, ac' % z('cpage'))
    e('add  2, ac')
    e('ld   ac, %s' % z('cpage'))
    e('ld   %s, ac' % z('ccol'))
    e('dec')
    e('ld   ac, %s' % z('ccol'))
    e('bne  advd')
    g.st(79, 'ccol')
    e('ld   %s, ac' % z('crow'))
    e('add  8, ac')
    e('ld   ac, %s' % z('crow'))
    e('bne  nlw')
    g.st(1, 'rhi')
    label('nlw')
    e('ld   0x62, ac')
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

    # ------------------------------------------------------------ output
    out = []
    o = out.append
    o('; pi_spigot.asm - generated by gen_pi_spigot.py, do not edit by hand')
    o('; Placard CPU benchmark: Rabinowitz & Wagon spigot, %d digits of pi,' % ndig)
    o('; printed to the screen.  See gen_pi_spigot.py for the method and memory map.')
    o(';')
    o(';     python3 placard_sim.py pi_spigot.asm --run --max-steps 2000000000 --png pi.png')
    o(';')
    o('; Date: 10/15/2026')
    o('')
    o('#include "placard.asm"')
    o('')
    o('#addr 0x0000')
    o('reset:')
    o('    ld   main >> 8, y')
    o('    jmp  main')
    pg = CODE_PG
    for name, lines in g.blocks:
        size = sum(instr_size(l.split(';')[0]) for l in lines if not l.endswith(':'))
        if size > 256:
            raise SystemExit('block %s is %d bytes, more than a page' % (name, size))
        if pg >= FONT_PG:
            raise SystemExit('code runs into the font page')
        o('')
        o('#addr 0x%04X' % (pg << 8))
        if name == 'main':
            o('main:')
        out.extend(lines)
        pg += 1
    o('')
    o('#addr 0x%04X' % (FONT_PG << 8))
    o('font:      ; 0-9 and ".", 8 bytes each, leftmost pixel in bit 0')
    for d in range(11):
        rev = [int('{:08b}'.format(b)[::-1], 2) for b in FONT[d]]
        o('    #d8 ' + ', '.join('0x%02X' % b for b in rev))
    for pgbase, part in ((TLO_PG, 0), (THI_PG, 1)):
        o('')
        o('; product table %s limbs: m * v, page 0x%02X + m' % (('low', 'high')[part], pgbase))
        for m in range(TMAX + 1):
            o('#addr 0x%04X' % ((pgbase + m) << 8))
            for r in range(8):
                vals = [limbs(m * (16 * r + c), 2)[part] for c in range(16)]
                o('    #d8 ' + ', '.join('0x%02X' % v for v in vals))
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'pi_spigot.asm')
    with open(path, 'w') as f:
        f.write('\n'.join(out) + '\n')
    print('wrote %s (%d digits, %d terms)' % (path, ndig, ln))


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--digits', type=int, default=1000)
    build(ap.parse_args().digits)

#!/usr/bin/env python3
"""
gen_mandelbrot.py - generate mandelbrot.asm, a Mandelbrot set benchmark for
the Placard CPU that draws to the video output.

    python3 gen_mandelbrot.py              writes mandelbrot.asm next to this script
    python3 placard_sim.py mandelbrot.asm --run --max-steps 100000000 --png m.png

Then merge mandelbrot.hex into video_ram.mem with gen_video_ram.tcl (set
::ASM_FILE to mandelbrot.hex) to run it on the board.

SCREEN (4 bpp, every row)
    158 x 120 points, each point is a 4 x 4 block of screen pixels (two
    points per video byte), so the image fills the 632 x 480 drawable area.
        real axis       -2.0 .. +0.45      (cx = -2 + px/64)
        imaginary axis  -0.94 .. +0.92     (cy = (py - 60)/64)
    Up to MAXIT iterations per point; points that never escape are black,
    the rest are colored by iteration count.

ARITHMETIC
    The CPU has no carry flag and no multiply, so the program uses:
      - fixed point with 6 fraction bits (1.0 = 64)
      - z = (x, y) kept as magnitude + sign; |x|, |y| < 2 means each
        magnitude fits in 7 bits (0..127)
      - squares from a table:  x*x, y*y and (x+y)^2, then
            x' = x*x - y*y + cx
            y' = (x+y)^2 - x*x - y*y + cy     (= 2xy + cy)
      - wider values in "base 128": value = hi * 128 + lo, lo = 0..127,
        hi signed.  A carry or borrow out of lo shows up as bit 7, which is
        the N flag, so it can be tested with a branch.
    Escape when x*x + y*y >= 4, or when |x'| or |y'| >= 2.

RESULT (placard_sim.py, ideal and --hw-alu give the same image)
    MAXIT = 32: 28,181,498 instructions, 93,381,353 clocks
        3.71 s at 25.175 MHz with no video
        4.08 s with the CPU stalled on every video byte fetch (1 clock in 8
               during active video, 9.1% of all clocks)
    The result image is reference/mandelbrot_sim.png.

MEMORY
    0000-0003   reset: jump to main
    0010-003F   variables (zero page)
    0100        square table, low 7 bits  (index k = 0..255, k*k/64)
    0200        square table, high bits
    0300        color table, indexed by iterations left
    0400-       main loop (column / row walk, pixel packing, video writes)
    0500-       iteration kernel
    6000-FFFF   video RAM (mode bytes set to 4 bpp by the program)

Date: 10/15/2026
"""

import os

MAXIT = 32

SQL_PG, SQH_PG, COL_PG = 0x01, 0x02, 0x03

# zero page variables
ZP = {}
for i, name in enumerate([
        'ax', 'sx', 'ay', 'sy', 'xxl', 'xxh', 'yyl', 'yyh', 'tl', 'th',
        'dl', 'dh', 'nxl', 'nxh', 'pl', 'ph', 'nyl', 'nyh',
        'cxl', 'cxh', 'cyl', 'cyh', 'it', 'ret', 'reth',
        'cxl0', 'cxh0', 'left', 'pix', 'rowx', 'rowy', 'vpage',
        'bcnt', 'pycnt']):
    ZP[name] = 0x10 + i


def z(name):
    return '[0x%02X]' % ZP[name]


# 4 bpp colors: 0-7 = R G B bits at full level, 8-15 = the same at half
# level plus 50% grey.  Indexed by iterations done before escape.
COLOR_BY_N = [4, 12, 6, 14, 2, 10, 3, 11, 1, 9, 5, 13, 7, 15, 8, 4]

out = []
_lbl = [0]


def emit(s):
    out.append(s)


def label(s):
    out.append(s + ':')


def uniq(p):
    _lbl[0] += 1
    return '%s_%d' % (p, _lbl[0])


def add128(r, a, b):
    """r = a + b, all base-128 (lo, hi) pairs in zero page; leaves r hi in AC"""
    nc, done = uniq('nc'), uniq('ad')
    emit('    ld   %s, ac' % z(a + 'l'))
    emit('    add  %s, ac' % z(b + 'l'))
    emit('    bge  %s' % nc)
    emit('    and  0x7F, ac')
    emit('    ld   ac, %s' % z(r + 'l'))
    emit('    ld   %s, ac' % z(a + 'h'))
    emit('    add  %s, ac' % z(b + 'h'))
    emit('    inc')
    emit('    bra  %s' % done)
    label(nc)
    emit('    ld   ac, %s' % z(r + 'l'))
    emit('    ld   %s, ac' % z(a + 'h'))
    emit('    add  %s, ac' % z(b + 'h'))
    label(done)
    emit('    ld   ac, %s' % z(r + 'h'))


def sub128(r, a, b):
    """r = a - b, base 128; leaves r hi in AC"""
    nb, done = uniq('nb'), uniq('sd')
    emit('    ld   %s, ac' % z(a + 'l'))
    emit('    sub  %s, ac' % z(b + 'l'))
    emit('    bge  %s' % nb)
    emit('    and  0x7F, ac')
    emit('    ld   ac, %s' % z(r + 'l'))
    emit('    ld   %s, ac' % z(a + 'h'))
    emit('    sub  %s, ac' % z(b + 'h'))
    emit('    dec')
    emit('    bra  %s' % done)
    label(nb)
    emit('    ld   ac, %s' % z(r + 'l'))
    emit('    ld   %s, ac' % z(a + 'h'))
    emit('    sub  %s, ac' % z(b + 'h'))
    label(done)
    emit('    ld   ac, %s' % z(r + 'h'))


def to_signmag(src, mag, sign, esc):
    """base-128 src -> 7-bit magnitude + sign, or branch to esc if |src| >= 2"""
    pos, done = uniq('pos'), uniq('sm')
    emit('    ld   %s, ac' % z(src + 'h'))
    emit('    beq  %s' % pos)
    emit('    inc                     ; hi must be -1')
    emit('    bne  %s' % esc)
    emit('    ld   %s, ac' % z(src + 'l'))
    emit('    beq  %s              ; -128 = -2.0' % esc)
    emit('    ld   0x80, ac')
    emit('    sub  %s, ac' % z(src + 'l'))
    emit('    ld   ac, %s' % z(mag))
    emit('    ld   1, ac')
    emit('    ld   ac, %s' % z(sign))
    emit('    bra  %s' % done)
    label(pos)
    emit('    ld   %s, ac' % z(src + 'l'))
    emit('    ld   ac, %s' % z(mag))
    emit('    clr  ac')
    emit('    ld   ac, %s' % z(sign))
    label(done)


def store_imm(v, name):
    emit('    ld   0x%02X, ac' % (v & 0xFF))
    emit('    ld   ac, %s' % z(name))


def build():
    here = os.path.dirname(os.path.abspath(__file__))
    emit('; mandelbrot.asm - generated by gen_mandelbrot.py, do not edit by hand')
    emit('; Placard CPU benchmark: Mandelbrot set, 158 x 120 points, %d iterations,' % MAXIT)
    emit('; drawn in 4 bpp.  See gen_mandelbrot.py for the method and memory map.')
    emit(';')
    emit(';     python3 placard_sim.py mandelbrot.asm --run --max-steps 100000000 --png m.png')
    emit(';')
    emit('; Date: 10/15/2026')
    emit('')
    emit('#include "placard.asm"')
    emit('')
    emit('#addr 0x0000')
    label('reset')
    emit('    ld   main >> 8, y')
    emit('    jmp  main')
    emit('')

    # ---------------- tables ----------------
    sq = [(k * k + 32) >> 6 for k in range(256)]
    emit('#addr 0x%04X' % (SQL_PG << 8))
    label('sq_lo')
    for r in range(16):
        emit('    #d8 ' + ', '.join('0x%02X' % (sq[16 * r + i] & 0x7F) for i in range(16)))
    emit('#addr 0x%04X' % (SQH_PG << 8))
    label('sq_hi')
    for r in range(16):
        emit('    #d8 ' + ', '.join('0x%02X' % (sq[16 * r + i] >> 7) for i in range(16)))
    emit('#addr 0x%04X' % (COL_PG << 8))
    label('colors')
    # index = iterations left when the point escaped; 0 = never escaped
    ctab = [0] + [COLOR_BY_N[(MAXIT - it) % len(COLOR_BY_N)] for it in range(1, MAXIT + 1)]
    emit('    #d8 ' + ', '.join('0x%02X' % c for c in ctab))
    emit('')

    # ---------------- main ----------------
    emit('#addr 0x0400')
    label('main')
    emit('    ; mode byte (byte column 0) = 2 (4 bpp) for all 480 rows: 6020-61FF')
    emit('    ld   0x60, y')
    emit('    ld   0x20, x')
    label('mode0')
    emit('    ld   0x02, [y,x]')
    emit('    ld   x, ac')
    emit('    inc')
    emit('    ld   ac, x')
    emit('    bne  mode0')
    emit('    ld   0x61, y')
    label('mode1')
    emit('    ld   0x02, [y,x]')
    emit('    ld   x, ac')
    emit('    inc')
    emit('    ld   ac, x')
    emit('    bne  mode1')
    emit('')
    emit('    ; px = 0: cx = -128 = (hi -1, lo 0)')
    store_imm(0x62, 'vpage')       # byte column 1 starts at 0x6220
    store_imm(0xFF, 'cxh0')
    store_imm(0x00, 'cxl0')
    store_imm(79, 'bcnt')
    label('col')
    emit('    ld   %s, ac' % z('vpage'))
    emit('    ld   ac, %s' % z('rowy'))
    store_imm(0x20, 'rowx')
    emit('    ; py = 0: cy = -60 = (hi -1, lo 68)')
    store_imm(0xFF, 'cyh')
    store_imm(68, 'cyl')
    store_imm(120, 'pycnt')
    label('row')
    emit('    ; left point (low nibble)')
    emit('    ld   %s, ac' % z('cxl0'))
    emit('    ld   ac, %s' % z('cxl'))
    emit('    ld   %s, ac' % z('cxh0'))
    emit('    ld   ac, %s' % z('cxh'))
    store_imm_label('ret_l')
    emit('    ld   kernel >> 8, y')
    emit('    jmp  kernel')
    label('ret_l')
    emit('    ld   ac, %s' % z('left'))
    emit('    ; right point (high nibble): cx + 1, lo is even so no carry')
    emit('    ld   %s, ac' % z('cxl0'))
    emit('    inc')
    emit('    ld   ac, %s' % z('cxl'))
    store_imm_label('ret_r')
    emit('    ld   kernel >> 8, y')
    emit('    jmp  kernel')
    label('ret_r')
    emit('    shl')
    emit('    shl')
    emit('    shl')
    emit('    shl')
    emit('    or   %s, ac' % z('left'))
    emit('    ld   ac, %s' % z('pix'))
    emit('    ; write the byte to 4 screen rows')
    emit('    ld   %s, x' % z('rowx'))
    emit('    ld   %s, y' % z('rowy'))
    for i in range(4):
        if i:
            emit('    ld   %s, ac' % z('pix'))
        emit('    ld   ac, [y,x]')
        emit('    ld   x, ac')
        emit('    inc')
        emit('    ld   ac, x')
    emit('    ld   ac, %s' % z('rowx'))
    emit('    bne  nowrap')
    emit('    ld   %s, ac' % z('rowy'))
    emit('    inc')
    emit('    ld   ac, %s' % z('rowy'))
    label('nowrap')
    emit('    ; cy += 1/64')
    emit('    ld   %s, ac' % z('cyl'))
    emit('    inc')
    emit('    bge  cyok')
    emit('    ld   %s, ac' % z('cyh'))
    emit('    inc')
    emit('    ld   ac, %s' % z('cyh'))
    emit('    clr  ac')
    label('cyok')
    emit('    ld   ac, %s' % z('cyl'))
    emit('    ld   %s, ac' % z('pycnt'))
    emit('    dec')
    emit('    ld   ac, %s' % z('pycnt'))
    emit('    bne  row')
    emit('    ; next byte column: cx0 += 2/64, video page += 2')
    emit('    ld   %s, ac' % z('cxl0'))
    emit('    add  2, ac')
    emit('    bge  cxok')
    emit('    and  0x7F, ac')
    emit('    ld   ac, %s' % z('cxl0'))
    emit('    ld   %s, ac' % z('cxh0'))
    emit('    inc')
    emit('    ld   ac, %s' % z('cxh0'))
    emit('    bra  cxdone')
    label('cxok')
    emit('    ld   ac, %s' % z('cxl0'))
    label('cxdone')
    emit('    ld   %s, ac' % z('vpage'))
    emit('    add  2, ac')
    emit('    ld   ac, %s' % z('vpage'))
    emit('    ld   %s, ac' % z('bcnt'))
    emit('    dec')
    emit('    ld   ac, %s' % z('bcnt'))
    emit('    bne  col')
    label('done')
    emit('    bra  done')
    emit('')

    # ---------------- kernel ----------------
    emit('; iteration kernel: in cx, cy; out AC = color; returns to [reth, ret]')
    emit('#addr 0x0500')
    label('kernel')
    emit('    clr  ac')
    for n in ('ax', 'ay', 'sx', 'sy'):
        emit('    ld   ac, %s' % z(n))
    store_imm(MAXIT, 'it')
    label('iter')
    emit('    ; x*x, y*y from the square table')
    emit('    ld   %s, x' % z('ax'))
    emit('    ld   0x%02X, y' % SQL_PG)
    emit('    ld   [y,x], ac')
    emit('    ld   ac, %s' % z('xxl'))
    emit('    ld   0x%02X, y' % SQH_PG)
    emit('    ld   [y,x], ac')
    emit('    ld   ac, %s' % z('xxh'))
    emit('    ld   %s, x' % z('ay'))
    emit('    ld   [y,x], ac')
    emit('    ld   ac, %s' % z('yyh'))
    emit('    ld   0x%02X, y' % SQL_PG)
    emit('    ld   [y,x], ac')
    emit('    ld   ac, %s' % z('yyl'))
    emit('    ; t = x*x + y*y, escape if t >= 4.0 (hi >= 2)')
    add128('t', 'xx', 'yy')
    emit('    sub  2, ac')
    emit('    bge  escape')
    emit('    ; x\' = x*x - y*y + cx')
    sub128('d', 'xx', 'yy')
    add128('nx', 'd', 'cx')
    emit('    ; s = |x + y|')
    emit('    ld   %s, ac' % z('sx'))
    emit('    xor  %s, ac' % z('sy'))
    emit('    bne  sdiff')
    emit('    ld   %s, ac' % z('ax'))
    emit('    add  %s, ac' % z('ay'))
    emit('    bra  sdone')
    label('sdiff')
    emit('    ld   %s, ac' % z('ax'))
    emit('    sub  %s, ac' % z('ay'))
    emit('    bge  sdone')
    emit('    ld   %s, ac' % z('ay'))
    emit('    sub  %s, ac' % z('ax'))
    label('sdone')
    emit('    ld   ac, x')
    emit('    ld   0x%02X, y' % SQL_PG)
    emit('    ld   [y,x], ac')
    emit('    ld   ac, %s' % z('pl'))
    emit('    ld   0x%02X, y' % SQH_PG)
    emit('    ld   [y,x], ac')
    emit('    ld   ac, %s' % z('ph'))
    emit('    ld   kernel2 >> 8, y')
    emit('    jmp  kernel2')
    emit('    ; done: color from the iterations left (kept in the kernel page,')
    emit('    ; bge escape above is an 8-bit branch)')
    label('escape')
    emit('    ld   %s, x' % z('it'))
    emit('    ld   0x%02X, y' % COL_PG)
    emit('    ld   [y,x], ac')
    emit('    ld   %s, y' % z('reth'))
    emit('    jmp  %s' % z('ret'))
    emit('')
    emit('#addr 0x0600')
    label('kernel2')
    emit('    ; y\' = s*s - t + cy  (= 2xy + cy)')
    sub128('ny', 'p', 't')
    add128('ny', 'ny', 'cy')
    emit('    ; back to magnitude + sign, escape if |x\'| or |y\'| >= 2')
    to_signmag('nx', 'ax', 'sx', 'escape2')
    to_signmag('ny', 'ay', 'sy', 'escape2')
    emit('    ld   %s, ac' % z('it'))
    emit('    dec')
    emit('    ld   ac, %s' % z('it'))
    emit('    beq  escape2             ; never escaped: it = 0 -> black')
    emit('    ld   iter >> 8, y')
    emit('    jmp  iter')
    label('escape2')
    emit('    ld   escape >> 8, y')
    emit('    jmp  escape')

    path = os.path.join(here, 'mandelbrot.asm')
    with open(path, 'w') as f:
        f.write('\n'.join(out) + '\n')
    print('wrote', path)


def store_imm_label(lb):
    emit('    ld   %s, ac' % lb)
    emit('    ld   ac, %s' % z('ret'))
    emit('    ld   %s >> 8, ac' % lb)
    emit('    ld   ac, %s' % z('reth'))


if __name__ == '__main__':
    build()

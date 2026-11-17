#!/usr/bin/env python3
"""
gen_text_demo_tables.py - write text_demo_tables.asm, the generated tables
and unrolled routines that text_demo.asm uses.

    python3 gen_text_demo_tables.py

Font expansion.  A font byte f has pixel i in bit i (bit 0 on the left).
Pixel i of a 2 bpp byte is bits 2i+1:2i, and of a 4 bpp byte bits 4i+3:4i.
Each table turns f into a mask with all the bits of the lit pixels set:

    EXP2_LO + f    pixels 0-3 of f as one 2 bpp byte
    EXP2_HI + f    pixels 4-7
    EXP4_0 + f     pixels 0-1 as one 4 bpp byte
    EXP4_1 + f     pixels 2-3
    EXP4_2 + f     pixels 4-5
    EXP4_3 + f     pixels 6-7

The program then makes a byte with (mask AND (fg XOR bg)) XOR bg.

Pixel scroller.  Two characters side by side, font bytes f0 and f1, are 16
pixels (f0 is pixels 0-7, f1 pixels 8-15).  The 2 bpp byte that shows pixels
p to p+3 of them (p = 0-11) is SL_p[f0] OR SR_p[f1]: SL_p holds the pixels
from f0, SR_p those from f1.  SL_0 is EXP2_LO and SL_4 is EXP2_HI, SR_8-11
are SL_0-3, and SL_8-11 and SR_0-4 are the zero page SZERO.  SC_LPAGE + p
and SC_RPAGE + p give the page of SL_p and SR_p.

256-color ring.  RING_V/RING_X + k are the video page and row offset of
ring pixel k (8 bpp 4x band, rows 352-479), RING_A + k its angle, 0-63
clockwise from the top; HUE + (angle + phase) is its color (a 64-step
rainbow, repeated four times so the index can wrap).

RAM test.  rt_wconst writes AC to all 256 bytes of page rt_page; rt_or
returns AC OR every byte of the page, rt_and AC AND every byte.  They are unrolled
(ld k, x / ld ac, [y,x] is 6 clocks a byte) and are leaf routines (RETURN
through LINK_LO/LINK_HI).

The 160-read screen (H key, rev B boards, docs/video/HIRES.md) has the
same picture at twice the resolution, from these tables:
  SMG      the letters of "16 COLORS" 16 x 16: the font's 8 x 8 letters
           doubled with the Scale2x rule, which fills the steps of the
           diagonals.  32 bytes a letter, two (pixels 0-7, 8-15) per row;
           S16H in text_demo.asm has the letter numbers
  DIGH     "256" 24 x 28: font columns 0-5, rows 0-6 doubled twice.  Three
           bytes per row (pixel 0 is bit 0 of the first), 28 rows a digit
  RINGH_R  the ring 160 across (pixels of 4 x 4 screen pixels): runs of
           ring pixels along a block row, (low byte, first page, count)
           each, ending with 00
  RINGH_A  the angle of every ring pixel, in the order of the runs

Date: 11/17/2026
"""

import colorsys
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import placard_sim as ps  # noqa: E402

EXP_BASE = 0x9000       # EXP2_LO, EXP2_HI, EXP4_0-3
SC_BASE = 0x9800        # scroller tables
SC_PAGES = 0xA200       # SC_LPAGE, SC_RPAGE
HUE = 0xA300
RING = 0xA400           # RING_V, RING_X, RING_A
RT_CODE = 0xA700
HI_BASE = 0xB100        # SMG, DIGH, RINGH_A (2 pages)
HI_RUNS = 0xB040        # RINGH_R, in the page the RAM test code ends in
SMG_CHARS = '16 COLRS'   # the letters of "16 COLORS"

# the ring: centre and radii in screen pixels, relative to the band's top
# left corner (8 bpp pixels are 8 x 4 screen pixels)
RING_CX, RING_CY = 492, 64
RING_RO, RING_RI = 60, 33


def exp(f, first, n, bpp):
    v = 0
    for i in range(n):
        if (f >> (first + i)) & 1:
            v |= ((1 << bpp) - 1) << (i * bpp)
    return v


def sl(p):
    """pixels p..p+3 of f0 f1 that come from f0, as 2 bpp"""
    def fn(f):
        v = 0
        for i in range(4):
            if p + i < 8 and (f >> (p + i)) & 1:
                v |= 3 << (2 * i)
        return v
    return fn


def sr(p):
    def fn(f):
        v = 0
        for i in range(4):
            if 8 <= p + i < 16 and (f >> (p + i - 8)) & 1:
                v |= 3 << (2 * i)
        return v
    return fn


def table(out, name, addr, fn):
    out.append('#addr 0x%04X' % addr)
    out.append('%s:' % name)
    for row in range(16):
        vals = ', '.join('0x%02X' % fn(row * 16 + i) for i in range(16))
        out.append('    #d8 ' + vals)
    out.append('')


def byte_list(out, vals):
    for i in range(0, len(vals), 16):
        out.append('    #d8 ' + ', '.join('0x%02X' % v for v in vals[i:i + 16]))


def rgb332(r, g, b):
    """8 bpp color byte: G3 G2 G1 B3 B2 R3 R2 R1"""
    return (round(g * 7) << 5) | (round(b * 3) << 3) | round(r * 7)


def ring_pixels():
    px = []
    for c in range(80):
        for n in range(32):
            x = 8 * c + 4 - RING_CX
            y = 4 * n + 2 - RING_CY
            d = math.hypot(x, y)
            if RING_RI <= d <= RING_RO:
                ang = math.atan2(x, -y) % (2 * math.pi)
                a = int(ang / (2 * math.pi) * 64) % 64
                # 4x rows 352-479: page x61 + 2 * column, low byte x83 + 4n
                px.append((0x61 + 2 * c, 0x83 + 4 * n, a))
    assert 0 < len(px) <= 255, len(px)
    return px


def font_glyph(rom, ch, cols=8, rows=8):
    """the font's character as rows of 0/1 (bit 0 is the left pixel)"""
    return [[(rom[ps.LIB_FONT + r * 256 + ord(ch)] >> c) & 1 for c in range(cols)]
            for r in range(rows)]


def scale2x(g):
    """the Scale2x (EPX) rule: each pixel becomes 2 x 2, and a corner takes
    the color of its two neighbors when they agree and the others don't"""
    h, w = len(g), len(g[0])

    def at(y, x):
        return g[y][x] if 0 <= y < h and 0 <= x < w else 0
    out = [[0] * (2 * w) for _ in range(2 * h)]
    for y in range(h):
        for x in range(w):
            p, a, b, c, d = at(y, x), at(y - 1, x), at(y, x + 1), at(y, x - 1), at(y + 1, x)
            out[2 * y][2 * x] = a if c == a and c != d and a != b else p
            out[2 * y][2 * x + 1] = b if a == b and a != c and b != d else p
            out[2 * y + 1][2 * x] = c if d == c and d != b and c != a else p
            out[2 * y + 1][2 * x + 1] = d if b == d and b != a and d != c else p
    return out


def pack(row):
    """a row of 0/1 as bytes, pixel 0 in bit 0 of the first"""
    return [sum(v << i for i, v in enumerate(row[k:k + 8])) for k in range(0, len(row), 8)]


def ring_runs():
    """the ring on 160-read rows (8 bpp 4x, rows 352-479: byte column c is
    page x60 + c, block row n low byte x83 + 4n): (runs, angles)"""
    runs, angles = [], []
    for n in range(32):
        run = None
        for c in range(161):
            x = 4 * c + 2 - RING_CX
            y = 4 * n + 2 - RING_CY
            if c < 160 and RING_RI <= math.hypot(x, y) <= RING_RO:
                ang = math.atan2(x, -y) % (2 * math.pi)
                angles.append(int(ang / (2 * math.pi) * 64) % 64)
                if run is None:
                    run = [0x83 + 4 * n, 0x60 + c, 0]
                run[2] += 1
            elif run is not None:
                runs.append(run)
                run = None
    assert len(runs) * 3 < 255 and len(angles) <= 512, (len(runs), len(angles))
    return runs, angles


def unrolled(out, name, body):
    out.append('%s:' % name)
    out.append('    ld   [rt_page], y           ; the page under test')
    for k in range(256):
        out.append('    ld   0x%02X, x' % k)
        out.append('    ' + body)
    out.append('    ld   [LINK_HI], y           ; RETURN')
    out.append('    jmp  [LINK_LO]')
    out.append('')


def main():
    out = ['; text_demo_tables.asm - generated by gen_text_demo_tables.py, do not edit',
           '; Font expansion and scroller tables, the 256-color ring and the',
           '; unrolled RAM test routines for text_demo.asm.  See gen_text_demo_tables.py.',
           ';',
           '; Date: 11/17/2026',
           '']
    exps = [
        ('EXP2_LO', lambda f: exp(f, 0, 4, 2)),
        ('EXP2_HI', lambda f: exp(f, 4, 4, 2)),
        ('EXP4_0', lambda f: exp(f, 0, 2, 4)),
        ('EXP4_1', lambda f: exp(f, 2, 2, 4)),
        ('EXP4_2', lambda f: exp(f, 4, 2, 4)),
        ('EXP4_3', lambda f: exp(f, 6, 2, 4)),
    ]
    for i, (name, fn) in enumerate(exps):
        table(out, name, EXP_BASE + 256 * i, fn)
    # the scroller pages; SL_0 = EXP2_LO and SL_4 = EXP2_HI (the same bytes)
    assert all(sl(0)(f) == exp(f, 0, 4, 2) and sl(4)(f) == exp(f, 4, 4, 2) for f in range(256))
    pages = {}
    a = SC_BASE
    for name, fn in [('SL1', sl(1)), ('SL2', sl(2)), ('SL3', sl(3)), ('SL5', sl(5)),
                     ('SL6', sl(6)), ('SL7', sl(7)), ('SR5', sr(5)), ('SR6', sr(6)),
                     ('SR7', sr(7)), ('SZERO', lambda f: 0)]:
        table(out, name, a, fn)
        pages[name] = a >> 8
        a += 256
    pages['SL0'] = EXP_BASE >> 8
    pages['SL4'] = (EXP_BASE >> 8) + 1
    lpage, rpage = [], []
    for p in range(12):
        lpage.append(pages['SL%d' % p] if p < 8 else pages['SZERO'])
        if p <= 4:
            rpage.append(pages['SZERO'])
        elif p < 8:
            rpage.append(pages['SR%d' % p])
        else:
            rpage.append(pages['SL%d' % (p - 8)])
    # check the page choice against the definitions
    for p in range(12):
        for f in range(256):
            assert p < 8 or sl(p)(f) == 0
            want = sr(p)(f)
            got = 0 if rpage[p] == pages['SZERO'] else (
                sr(p)(f) if 5 <= p < 8 else sl(p - 8)(f))
            assert want == got
    out.append('#addr 0x%04X' % SC_PAGES)
    out.append('SC_LPAGE:                       ; page of SL_p, p = 0-11')
    byte_list(out, lpage)
    out.append('#addr 0x%04X' % (SC_PAGES + 0x10))
    out.append('SC_RPAGE:                       ; page of SR_p')
    byte_list(out, rpage)
    out.append('')

    hue = []
    for i in range(256):
        r, g, b = colorsys.hsv_to_rgb((i % 64) / 64.0, 1.0, 1.0)
        hue.append(rgb332(r, g, b))
    out.append('#addr 0x%04X' % HUE)
    out.append('HUE:                            ; 64-step rainbow, four times')
    byte_list(out, hue)
    out.append('')

    px = ring_pixels()
    out.append('RING_N = %d                    ; ring pixels' % len(px))
    for i, (name, vals) in enumerate([('RING_V', [p[0] for p in px]),
                                      ('RING_X', [p[1] for p in px]),
                                      ('RING_A', [p[2] for p in px])]):
        out.append('#addr 0x%04X' % (RING + 256 * i))
        out.append('%s:' % name)
        byte_list(out, vals)
        out.append('')

    out.append('#addr 0x%04X' % RT_CODE)
    unrolled(out, 'rt_wconst', 'ld   ac, [y,x]')
    unrolled(out, 'rt_or', 'or   [y,x], ac')
    unrolled(out, 'rt_and', 'and  [y,x], ac')

    # the 160-read screen
    lib, _, _ = ps.assemble('#include "placard.asm"\n#include "placard_lib.asm"\n',
                            os.path.dirname(os.path.abspath(__file__)))
    rom = ps.build_rom(lib)
    smg = []
    for ch in SMG_CHARS:
        for row in scale2x(font_glyph(rom, ch)):
            smg += pack(row)
    out.append('#addr 0x%04X' % HI_BASE)
    out.append('SMG:                            ; "%s" 16 x 16, 32 bytes each' % SMG_CHARS)
    byte_list(out, smg)
    out.append('')
    digh = []
    for ch in '256':
        g = scale2x(scale2x(font_glyph(rom, ch, 6, 7)))
        for row in g:
            digh += pack(row)
    assert len(digh) == 252
    out.append('#addr 0x%04X' % (HI_BASE + 0x100))
    out.append('DIGH:                           ; "256" 24 x 28, 3 bytes a row')
    byte_list(out, digh)
    out.append('')
    runs, angles = ring_runs()
    out.append('#addr 0x%04X' % (HI_BASE + 0x200))
    out.append('RINGH_A:                        ; the angle of the %d ring pixels' % len(angles))
    byte_list(out, angles)
    out.append('')
    out.append('#addr 0x%04X' % HI_RUNS)
    out.append('RINGH_R:                        ; %d runs: low byte, first page, count' % len(runs))
    byte_list(out, [v for run in runs for v in run] + [0])
    out.append('')

    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'text_demo_tables.asm')
    open(path, 'w', newline='\n').write('\n'.join(out))
    print('wrote', path, '(%d ring pixels, %d on the 160-read screen in %d runs)'
          % (len(px), len(angles), len(runs)))


if __name__ == '__main__':
    main()

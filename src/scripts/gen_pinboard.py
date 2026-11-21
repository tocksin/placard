#!/usr/bin/env python3
"""
gen_pinboard.py - Pinboard's display drivers' tables, and the build

    python3 gen_pinboard.py             writes the tables and the two color
                                        drivers' sources, runs asm_expand.py
                                        on pinboard.masm and the drivers,
                                        and writes pinboard.asm (the core
                                        and the 2-color driver),
                                        ../../sdcard/PINBOARD.PLC and the
                                        three drivers in ../../sdcard/PINBOARD
    python3 gen_pinboard.py --data      the tables and sources only

Pinboard (docs/software/PINBOARD.md) is the windowed desktop: a program on
the SD card.  Its core (pinboard.masm, pinboard.vm) is the same in every
mode of the screen; a display driver, the bytes x2E00-x3FFF, draws the
characters and the pointer:

    mono  MONO.DRV     640 x 480, 2 colors   pinboard_drv_mono.masm
    c4    COLOR4.DRV   640 x 240, 4 colors   pinboard_drv_color.masm, the
    c16   COLOR16.DRV  320 x 240, 16 colors  lines marked @4 or @16 (rev B)

For each, pinboard_data_<name>.asm has the fixed part: the five entries,
the pens (PENS4, PENS16), the screen's size in cells and the cards' first
places (DRIVERS), the font and the pointer.  The build checks that the
entries are where the core calls them and that the core's bytes are the
same under every driver.

The characters are 8 x 8, from Pinboard's own font:

    codes 20-7E   the library's font (font8x8_basic, public domain)
    codes 01-1F   Pinboard's own pieces: the board's weave, the card
                  edges, the pin, arrows and the file pictures (GLYPHS)
    codes 80-FF   mono: the same in inverse video

Mono: the font is laid out as the library's (lib_font.asm): page PB_FONT
+ k holds pixel row k of every character; bit 0 of a row is the leftmost
pixel.  A lit pixel is white.  Cards are white with black ink, so text on
a card uses the inverse codes.  Color: page PB_FONT + k holds the row as
the two bytes of a 2 bpp row, every bit doubled, the left byte at the
character and the right at + x80; the driver colors them with the pen and
swaps the pen's two colors for the codes from x80.

The pointer is 8 x 12 pixels of the mode.  Mono: its tables hold it
shifted 0-7 pixels to the right, as the two bytes it covers in a pixel
row: PB_PTR + (shift << 4 | row) the left byte and + x80 the right byte of
the mask (1 = the screen shows through), and the same in page PB_PTR +
x100 for the white pixels.  Color: 3 bytes of 2 bpp (shifts 0-3) or 5 of
4 bpp (shifts 0-1), at byte << 6 (or 5) | shift << 4 | row.

Date: 11/21/2026
"""

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen_lib_font  # noqa: E402

# Pinboard's own characters: '#' is a lit (white) pixel
GLYPHS = {
    0x01: ['#.#.#.#.',      # the board: a weave
           '.#.#.#.#',
           '#.#.#.#.',
           '.#.#.#.#',
           '#.#.#.#.',
           '.#.#.#.#',
           '#.#.#.#.',
           '.#.#.#.#'],
    0x02: ['.#######'] * 8,                     # a card's left edge
    0x03: ['#######.'] * 8,                     # right edge
    0x04: ['########'] * 7 + ['........'],      # bottom edge
    0x05: ['.#######'] * 7 + ['........'],      # bottom left corner
    0x06: ['#######.'] * 7 + ['........'],      # bottom right corner
    0x07: ['........',      # the pin (takes a card down), white on the title
           '..####..',
           '.######.',
           '.######.',
           '..####..',
           '...##...',
           '...##...',
           '...#....'],
    0x08: ['........',      # up arrow
           '...##...',
           '..####..',
           '.######.',
           '########',
           '...##...',
           '...##...',
           '........'],
    0x09: ['........',      # down arrow
           '...##...',
           '...##...',
           '########',
           '.######.',
           '..####..',
           '...##...',
           '........'],
    0x0B: ['........',      # a folder
           '.###....',
           '#######.',
           '#.....#.',
           '#.....#.',
           '#.....#.',
           '#######.',
           '........'],
    0x0C: ['........',      # a program: a chip
           '.#.#.#..',
           '#######.',
           '.#####..',
           '#######.',
           '.#####..',
           '#######.',
           '.#.#.#..'],
    0x0D: ['........',      # a file: a sheet with a folded corner
           '.####...',
           '.#..##..',
           '.#...#..',
           '.#...#..',
           '.#...#..',
           '.#####..',
           '........'],
    0x0E: ['........',      # the folder above: an arrow up and left
           '..#.....',
           '.##.....',
           '#######.',
           '.##...#.',
           '..#...#.',
           '......#.',
           '........'],
    0x0F: ['........',      # the scroll bar's track
           '...#....',
           '........',
           '...#....',
           '........',
           '...#....',
           '........',
           '...#....'],
    0x10: ['########'] + ['........'] * 7,      # the rail's top line
    0x11: ['........',      # the scroll bar's thumb
           '.######.',
           '.######.',
           '.######.',
           '.######.',
           '.######.',
           '.######.',
           '........'],
    0x12: ['........',      # a picture: a frame, the sun over a hill
           '#######.',
           '#...#.#.',
           '#.....#.',
           '#..#..#.',
           '#.###.#.',
           '#######.',
           '........'],
}

# the pointer: 'X' black, 'o' white outline, '.' the screen
POINTER = ['X.......',
           'XX......',
           'XoX.....',
           'XooX....',
           'XoooX...',
           'XooooX..',
           'XoooooX.',
           'XooooXXX',
           'XoXoX...',
           'XX.XoX..',
           'X..XoX..',
           '....XX..']


def font_rows():
    """8 lists of 256 bytes: row k of every character"""
    chars = [[0] * 8 for _ in range(128)]
    for i, rows in enumerate(gen_lib_font.FONT):
        chars[0x20 + i] = list(rows)
    for code, pic in GLYPHS.items():
        chars[code] = [sum(1 << b for b in range(8) if row[b] == '#') for row in pic]
    return [[chars[c][k] for c in range(128)] + [chars[c][k] ^ 0xFF for c in range(128)]
            for k in range(8)]


def pointer_tables():
    """(mask page, white page): 256 bytes each"""
    mask = [0xFF] * 256
    white = [0] * 256
    for r, row in enumerate(POINTER):
        cover = sum(1 << b for b in range(8) if row[b] != '.')
        lit = sum(1 << b for b in range(8) if row[b] == 'o')
        for s in range(8):
            m = ~(cover << s) & 0xFFFF
            w = (lit << s) & 0xFFFF
            mask[s << 4 | r] = m & 0xFF
            mask[0x80 | s << 4 | r] = m >> 8
            white[s << 4 | r] = w & 0xFF
            white[0x80 | s << 4 | r] = w >> 8
    return mask, white


def d8(out, data):
    for k in range(0, len(data), 16):
        out.append('    #d8 ' + ', '.join('0x%02X' % b for b in data[k:k + 16]))


# ------------------------------------------------------------
# the three display drivers (pinboard_drv_*.masm): what differs
# ------------------------------------------------------------
# 16 colors (docs/video/COLORS.md)
BLK, DBLU, PUR, BLU, RED, MAG, BRN, DGR, CYN, DGN, WHT, LGR, PNK, ORG, YEL, GRN = range(16)
# 4 colors
K4, B4, G4, W4 = range(4)

# the pens (pinboard.vm: PEN): (the color of a 1 bit, of a 0 bit).  White
# ink on black is drawn 1 = ink; black ink on a card (INK, the characters
# from x80) with the two swapped: 1 = paper.
PEN_NAMES = ['plain', 'the board', 'a title at the back', 'the chosen row', 'the rail',
             "the rail's Pinboard", 'a tab at the back', 'the time',
             'title: Files', 'title: Clock', 'title: Calc', 'title: Editor', 'title: About',
             'title: Display', "Calc's number keys", "Calc's other keys",
             'a folder', 'a program', 'a file', "the Clock's digits", "Calc's display",
             'spare', 'the pin at the back', 'spare']
PENS16 = [(WHT, BLK), (ORG, BRN), (LGR, BLK), (WHT, BLU), (WHT, DBLU),
          (ORG, BLK), (BLK, LGR), (YEL, DBLU),
          (WHT, BLU), (WHT, DGN), (WHT, PUR), (WHT, RED), (WHT, DGR),
          (BLK, CYN), (BLK, LGR), (BLK, ORG),
          (WHT, ORG), (WHT, DGN), (WHT, DGR), (WHT, DGN), (GRN, BLK),
          (WHT, BLK), (LGR, RED), (WHT, BLK)]
PENS4 = [(W4, K4), (K4, B4), (K4, W4), (W4, B4), (W4, K4),
         (G4, K4), (W4, B4), (G4, K4),
         (K4, G4), (K4, G4), (K4, G4), (K4, G4), (K4, G4),
         (K4, G4), (W4, B4), (K4, G4),
         (W4, G4), (W4, B4), (W4, K4), (W4, B4), (G4, K4),
         (W4, K4), (K4, G4), (W4, K4)]

# name: file on the card, columns, rows, the board's rows, the pointer's
# cell shifts (PX 0-639, PY 0-479), the board's character (the weave, or a
# space in the color modes: one color is quick to draw), the cards' first
# places x, y, w, h
# (Files, Clock, Calc, Editor, About, Display)
DRIVERS = {
    'mono': dict(file='MONO.DRV', par=(80, 60, 57, 3, 3, 1),
                 winit=[(2, 1, 40, 30), (46, 3, 31, 11), (52, 20, 23, 15),
                        (20, 10, 44, 30), (18, 16, 44, 13), (27, 24, 26, 9)]),
    'c4': dict(file='COLOR4.DRV', par=(80, 30, 28, 3, 4, 32),
               winit=[(1, 0, 40, 24), (47, 1, 31, 11), (54, 12, 23, 15),
                      (20, 3, 44, 24), (18, 8, 44, 13), (27, 10, 26, 9)]),
    'c16': dict(file='COLOR16.DRV', par=(40, 30, 28, 4, 4, 32),
                winit=[(0, 0, 26, 22), (8, 2, 31, 11), (16, 12, 23, 15),
                       (0, 6, 40, 20), (0, 8, 40, 13), (7, 10, 26, 9)]),
}


def spread(n):
    """a 4-bit font nibble as a 2 bpp byte: every bit doubled"""
    return sum(3 << 2 * i for i in range(4) if n >> i & 1)


def font_rows_color():
    """8 lists of 256 bytes: row k of every character as 2 bpp, the left
    byte at the character, the right at + x80"""
    glyphs = GLYPHS
    chars = [[0] * 8 for _ in range(128)]
    for i, rows in enumerate(gen_lib_font.FONT):
        chars[0x20 + i] = list(rows)
    for code, pic in glyphs.items():
        chars[code] = [sum(1 << b for b in range(8) if row[b] == '#') for row in pic]
    return [[spread(chars[c][k] & 15) for c in range(128)] +
            [spread(chars[c][k] >> 4) for c in range(128)] for k in range(8)]


def pointer_tables_color(bpp):
    """(mask page, picture page): at byte << (6 or 5) | shift << 4 | row.
    The pointer is 8 pixels of the mode wide."""
    nb, shifts, step, white = (3, 4, 6, 3) if bpp == 2 else (5, 2, 5, 10)
    full = (1 << bpp) - 1
    mask = [0xFF] * 256
    pic = [0] * 256
    for r, row in enumerate(POINTER):
        for s in range(shifts):
            m, p = (1 << 8 * nb) - 1, 0
            for b, c in enumerate(row):
                if c == '.':
                    continue
                at = (b + s) * bpp
                m &= ~(full << at)
                if c == 'o':
                    p |= white << at
            for k in range(nb):
                mask[k << step | s << 4 | r] = m >> 8 * k & 0xFF
                pic[k << step | s << 4 | r] = p >> 8 * k & 0xFF
    return mask, pic


def write_data(name):
    drv = DRIVERS[name]
    out = ['; pinboard_data_%s.asm - generated by gen_pinboard.py, do not edit by hand' % name,
           "; The fixed part of Pinboard's display driver %s (%s): its entries, its" % (name, drv['file']),
           '; pens, the screen in cells and the cards\' first places; the pointer',
           '; and the font.',
           ';',
           '; Date: 11/21/2026',
           '',
           '#addr DRV                   ; the entries (pinboard_hdr.masm: DRV_CELLS ...)']
    for label in ('d_cells', 'd_invc', 'd_hide', 'd_show', 'd_init'):
        out += ['    ld   %s >> 8, y' % label, '    jmp  %s' % label]
    out.append('#addr DRV_PENS              ; a pen: FX (its two colors XORed), BG (a 0 bit)')
    if name == 'mono':
        d8(out, [0] * 48)
    else:
        rep = 0x55 if name == 'c4' else 0x11
        for i, (hi, lo) in enumerate(PENS4 if name == 'c4' else PENS16):
            out.append('    #d8 0x%02X, 0x%02X     ; %d %s' % ((hi ^ lo) * rep, lo * rep, i, PEN_NAMES[i]))
    out.append('#addr DRV_PAR               ; columns, rows, the board\'s rows, the cell shifts of PX and PY, the board\'s character')
    d8(out, drv['par'])
    out.append('#addr DRV_WINIT             ; Files, Clock, Calc, Editor, About, Display: x, y, w, h')
    for w in drv['winit']:
        d8(out, w)
    if name == 'mono':
        rows = font_rows()
        mask, pic = pointer_tables()
    else:
        rows = font_rows_color()
        mask, pic = pointer_tables_color(2 if name == 'c4' else 4)
    if name == 'c16':
        out.append('#addr T16L')
        d8(out, [(15 if e & 1 else 0) | (0xF0 if e & 4 else 0) for e in range(256)])
        out.append('#addr T16H')
        d8(out, [(15 if e & 16 else 0) | (0xF0 if e & 64 else 0) for e in range(256)])
    for k, row in enumerate(rows):
        out.append('#addr PB_FONT + 0x%03X     ; row %d' % (k * 256, k))
        d8(out, row)
    out.append('#addr PB_PTR')
    d8(out, mask[:0xC0] if name != 'mono' else mask)
    out.append('#addr PB_PTR + 0x100')
    d8(out, pic)
    with open(os.path.join(HERE, 'pinboard_data_%s.asm' % name), 'w') as f:
        f.write('\n'.join(out) + '\n')


MARK = '; ---DRIVER---'
DRV, DRV_END = 0x2E00, 0x4000
ENTRIES = ('d_cells', 'd_invc', 'd_hide', 'd_show', 'd_init')


def run(cmd):
    r = subprocess.run([sys.executable] + cmd, cwd=HERE)
    if r.returncode:
        sys.exit(r.returncode)


def main(argv):
    import placard_sim as ps
    for name in DRIVERS:
        write_data(name)
    # the two color drivers from their one source
    src = open(os.path.join(HERE, 'pinboard_drv_color.masm')).read().split('\n')
    for name, tag in (('c4', '@4 '), ('c16', '@16 ')):
        lines = ['; pinboard_drv_%s.masm - generated by gen_pinboard.py from' % name,
                 '; pinboard_drv_color.masm, do not edit by hand']
        for l in src:
            if l.startswith('@'):
                if not l.startswith(tag):
                    continue
                l = l[len(tag):]
            lines.append(l)
        open(os.path.join(HERE, 'pinboard_drv_%s.masm' % name), 'w').write('\n'.join(lines))
    if '--data' in argv:
        return 0
    run(['asm_expand.py', 'pinboard.masm'] + ['pinboard_drv_%s.masm' % n for n in DRIVERS])
    core = open(os.path.join(HERE, 'pinboard.asm')).read()
    images = {}
    for name, drv in DRIVERS.items():
        p = os.path.join(HERE, 'pinboard_drv_%s.asm' % name)
        text = open(p).read()
        text = ('; pinboard_drv_%s.asm - the display driver %s, expanded (after the\n'
                '; lines of pinboard.asm)\n' % (name, drv['file'])) + text[text.index(MARK):]
        open(p, 'w').write(text)
        prog, syms, _ = ps.assemble(core + '\n' + text, HERE)
        for i, label in enumerate(ENTRIES):
            a = DRV + 4 * i
            code = bytes(prog[a + k] for k in range(4))
            want_hi, want_lo = syms[label] >> 8, syms[label] & 0xFF
            if want_hi not in code or want_lo not in code:
                sys.exit('driver %s: entry %s is not 4 bytes at x%04X' % (name, label, a))
        over = [a for a in prog if DRV <= a < DRV_END]
        images[name] = (prog, bytes(prog.get(a, 0) for a in range(DRV, DRV_END)))
        print('driver %s: code to x%04X' % (name, max(a for a in over if a < 0x3600) + 1))
    # the core is the same bytes under every driver
    base = images['mono'][0]
    for name, (prog, _) in images.items():
        diff = [a for a in set(base) | set(prog)
                if not DRV <= a < DRV_END and base.get(a) != prog.get(a)]
        if diff:
            sys.exit('driver %s changes the core at x%04X' % (name, min(diff)))
    folder = os.path.join(HERE, '..', '..', 'sdcard', 'PINBOARD')
    os.makedirs(folder, exist_ok=True)
    for name, (_, image) in images.items():
        open(os.path.join(folder, DRIVERS[name]['file']), 'wb').write(image)
    # PINBOARD.PLC: the core with the mono driver
    whole = core + '\n' + open(os.path.join(HERE, 'pinboard_drv_mono.asm')).read()
    open(os.path.join(HERE, 'pinboard.asm'), 'w').write(whole)
    run(['gen_plc.py', 'pinboard.asm', '-o', os.path.join('..', '..', 'sdcard', 'PINBOARD.PLC')])
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

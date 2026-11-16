#!/usr/bin/env python3
"""
gen_pinboard.py - Pinboard's font and pointer tables, and the build

    python3 gen_pinboard.py             writes pinboard_data.asm, runs
                                        asm_expand.py on pinboard.masm
                                        (pinboard.asm) and gen_plc.py
                                        (../../sdcard/PINBOARD.PLC)
    python3 gen_pinboard.py --data      pinboard_data.asm only

Pinboard (docs/software/PINBOARD.md) is the windowed desktop: a program on
the SD card.  It draws its own characters, 8 x 8 in the 80 x 60 cells of
the 1 bpp screen, from its own font:

    codes 20-7E   the library's font (font8x8_basic, public domain)
    codes 01-1F   Pinboard's own pieces: the board's weave, the card
                  edges, the pin, arrows and the file pictures (GLYPHS)
    codes 80-FF   the same in inverse video

The font is laid out as the library's (lib_font.asm): page PB_FONT + k
holds pixel row k of every character; bit 0 of a row is the leftmost
pixel.  A lit pixel is white.  Cards are white with black ink, so text on
a card uses the inverse codes.

The pointer is 8 x 12 pixels.  Its tables hold it shifted 0-7 pixels to
the right, as the two bytes it covers in a pixel row: PB_PTR + (shift
<< 4 | row) the left byte and + x80 the right byte of the mask (1 = the
screen shows through), and the same in page PB_PTR + x100 for the white
pixels.

Date: 11/16/2026
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


def write_data():
    out = ['; pinboard_data.asm - generated by gen_pinboard.py, do not edit by hand',
           "; Pinboard's font (page PB_FONT + k holds row k of every character;",
           '; 01-1F are its own pieces, 20-7E font8x8_basic by Daniel Hepper,',
           '; public domain, 80-FF the same in inverse video) and its pointer',
           '; (PB_PTR: the mask, PB_PTR + x100: the white pixels, at shift << 4 |',
           '; row, the right byte at + x80).',
           ';',
           '; Date: 11/16/2026',
           '']
    for k, row in enumerate(font_rows()):
        out.append('#addr PB_FONT + 0x%03X     ; row %d' % (k * 256, k))
        d8(out, row)
    mask, white = pointer_tables()
    out.append('#addr PB_PTR')
    d8(out, mask)
    out.append('#addr PB_PTR + 0x100')
    d8(out, white)
    with open(os.path.join(HERE, 'pinboard_data.asm'), 'w') as f:
        f.write('\n'.join(out) + '\n')


def main(argv):
    write_data()
    if '--data' in argv:
        return 0
    for cmd in (['asm_expand.py', 'pinboard.masm'],
                ['gen_plc.py', 'pinboard.asm', '-o',
                 os.path.join('..', '..', 'sdcard', 'PINBOARD.PLC')]):
        r = subprocess.run([sys.executable] + cmd, cwd=HERE)
        if r.returncode:
            return r.returncode
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""
gen_skyward.py - generate SKYWARD TOBI for the Placard, a side-scrolling
platform game on the SD card (a library program in the RAM)

    python3 gen_skyward.py                  writes skyward.asm next to this script,
                                            ../../sdcard/SKYWARD.PLC and the course
                                            files ../../sdcard/SKYWARD/CA.LVL - CX.LVL
    python3 gen_skyward.py --preview DIR    also draws every course (whole length)
                                            and a first screen with the Python model
    python3 test_skyward_sim.py             runs it in placard_sim from a card

A port of the two worlds of Skyward Tobi 4 (an NES game by Mark Szlemko,
github.com/Zebshine/skyward-tobi-4) to the Placard: the story, the cast, the
courses' ideas, Tobi and the enemy art are his (skyward_art.py holds the
frames copied later), laid out again for 160 x 112 pixels in 16 colors.  The engine is the Placard's own (gen_scroller.py's: no scroll
registers and no sprite hardware, so the whole playfield is drawn again
every frame, ahead of the beam).

SCREEN
    rows   0-31   1 bpp, 1x   four lines of 80 column text: the course's
                              name, the score line, two lines of story
    rows  32-479  4 bpp, 4x   the playfield: 160 x 112 pixels of 4 x 4,
                              16 colors:
        cells   0-15   the high sky            scrolls at 1/8 speed
        cells  16-31   clouds                  1/2
        cells  32-111  the course: 5 rows of   full speed
                       16 x 16 tiles

FILES ON THE CARD
    SKYWARD.PLC         the program: the sprite blitter and Tobi's frames at
                        x0100, the code from x2000
    SKYWARD/Cx.LVL      one file a course (x = A-X), read when the course
                        starts: 6 sectors of tables to x4000-x4BFF (strip
                        addresses, the tile map, the objects, the sprite
                        routines' addresses, three lines of text), then a
                        straight image of the RAM from x6000: the strips
                        (unrolled code that draws one byte column of a
                        band or of a tile) and the course's own sprites, in
                        the video RAM the screen leaves free (offsets
                        x040-x17F of each 512-byte byte column).
    CA is the title and the story, CM the boat between the worlds and CX
    the ending; the others are played.

THE GAME
    Run right, jump the gaps, land on the Bumblers, Buzzbees and Shellbys
    (touching one from the side is a hit), keep off the Spindles and the
    Snapjaws, collect Mabel's Stunt Medals and reach the windsock.  Crates
    hold a Sky Berry (one hit), an Ember Pepper (a hit, and embers to throw),
    a Glide Feather (a hit, and a glider) or the Tengu Geta (walks on thorns).  With the glider, hold the jump key in the
    air to glide.  Gale Fort ends with Captain Squall and Crow Keep with
    Baron Rook: land on them three times (in Squall Fort and Dust Keep, four).  docs/software/SKYWARD.md has
    the rest.
    Controls: arrow keys or SNES pad 1 Left / Right, Up / Space / pad B
    or A to jump (hold to glide), Down or pad Y to throw an ember, Esc back
    to the DOS.

Date: 11/13/2026
"""

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps  # noqa: E402
from gen_raycast import Asm, row_x  # noqa: E402

MODE_PF = 0x0A          # 4 bpp, 4x
NCOL = 80
NROW = 112
LEVEL_W = 128           # tiles
WRAP = LEVEL_W * 8      # byte columns (1024)
BANDS = [               # name, first cell, last cell + 1, shift (speed = 1 / 2^shift)
    ('C', 0, 16, 3),
    ('H', 16, 32, 1),
]
BAND_W = 64             # repeating picture width (byte columns)
GROUND_G = 32           # first cell of the course
NTROW = 5               # tile rows
GRAV = 0x38
JUMPV = 0x0480
MAXFALL = 0x0500
GLIDE = 0x60            # falling speed with the glider open (cells / 256 a frame)
INV_FRAMES = 90
ROOK_SAFE = 24          # frames of safety after landing on Rook
MAX_SPR = 12
DROWN_G = 100           # player top cell: fallen out of the course
SCREEN_X = 30           # the player's byte column on the screen

# 4 bpp palette (docs/video/COLORS.md): 0 black 1 dark blue 2 purple 3 blue 4 red
# 5 magenta 6 brown 7 dark gray 8 cyan 9 dark green a white b light gray c pink
# d orange e yellow f green

# ---------------------------------------------------------------------------
# sprites.  Tobi's, the enemies' and the bosses' frames are Skyward Tobi 4's
# (three colors a frame there: 1, 2, 3), recolored by PAL.  The glider
# frame, the medal, the windsock, Mabel and the biplane are drawn here.
#
# Skyward Tobi 4 (the frames in SRC and in skyward_art.py, the cast, the
# story and the course names) is used under its license:
#
#   MIT License
#
#   Copyright (c) 2026 Mark Szlemko
#
#   Permission is hereby granted, free of charge, to any person obtaining a copy
#   of this software and associated documentation files (the "Software"), to deal
#   in the Software without restriction, including without limitation the rights
#   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#   copies of the Software, and to permit persons to whom the Software is
#   furnished to do so, subject to the following conditions:
#
#   The above copyright notice and this permission notice shall be included in all
#   copies or substantial portions of the Software.
#
#   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
#   SOFTWARE.
# ---------------------------------------------------------------------------
SRC = {
    'bumbler1': [
        "................",
        "..........1...1.",
        "...........1.1..",
        "....1111.11111..",
        "...122221111111.",
        "..12332131111131",
        ".123322133111331",
        ".123222133313331",
        "1222222133113311",
        "1222222133113311",
        "1222222113111311",
        ".12222211111131.",
        "..11111111111...",
        "...11..11..11...",
        "..11..11..11....",
        ".11..11..11....."],
    'buzz1': [
        "....11....11....",
        "...1331..1331...",
        "...13331.13331..",
        "....13331133331.",
        ".....1333113331.",
        "......11111111..",
        "....1122112211..",
        "...12221122111..",
        "..1222211221131.",
        ".12222211221331.",
        "11222221122111..",
        ".1222221122111..",
        "..12222112211...",
        "...112211221....",
        ".....111111.....",
        "................"],
    'rook1': [
        "...............3.3.3............",
        "...............33333............",
        "...............13331............",
        "..............111111............",
        "............1122222211..........",
        "...........122222222221.........",
        "...........122222222221.........",
        "...........122222111221.........",
        "..........12222222331121111.....",
        "..........122222223112213331....",
        "...........122222222221133331...",
        "...........1222222222211111331..",
        "........1111122222222111...11...",
        "......11222221222222122211......",
        ".....1222222221111112222221.....",
        "...11222222222222222222222211...",
        "...11222222222222222222222211...",
        "..1212222221133333331222222121..",
        ".121222222132222222312222222121.",
        ".121222221322323232231222222121.",
        ".121222221322333332231222222121.",
        "1122122221322233322231222221221.",
        "1212122221322333332231222221221.",
        "122121222213222222231222221221..",
        ".12122222221333333312222222221..",
        "..112222222211111112222222221...",
        "....112222222222222222222211....",
        "......11222222222222222211......",
        "........1113222222223111........",
        "..........131111111131..........",
        "..........3333......3333........",
        "..........3.3........3.3........"],
    'rook2': [
        "...............3.3.3............",
        "...............33333............",
        "...............13331............",
        "..............111111............",
        "............1122222211..........",
        "...........122222222221.........",
        "...........122222222221.........",
        ".1.........122222111221.........",
        ".121......12222222331121111.....",
        ".1221.....122222223112213331....",
        ".12221.....122222222221133331...",
        ".122221....1222222222211111331..",
        "..1222211111122222222111...11...",
        "...12222122221222222122211......",
        "....12222222221111112222221.....",
        "...11222222222222222222222211...",
        "...12222222222222222222222211...",
        "..1222222221133333331222222121..",
        ".122222222132222222312222222121.",
        ".122222221322323232231222222121.",
        ".122222221322333332231222222121.",
        "1122222221322233322231222221221.",
        "1212222221322333332231222221221.",
        "122122222213222222231222221221..",
        ".12122222221333333312222222221..",
        "..112222222211111112222222221...",
        "....112222222222222222222211....",
        "......11222222222222222211......",
        "........1112222222222111........",
        "..........333311113333..........",
        "..........3.3......3.3..........",
        "................................"],
}
SRC['bumbler2'] = SRC['bumbler1'][:13] + ["...11..11..11...", "....11..11..11..", ".....11..11..11."]
SRC['buzz2'] = ["................", "................", "....11....11....", "...1331..1331...",
                "....13331133331."] + SRC['buzz1'][5:]

PAL = {
    'bumbler': {'1': '0', '2': 'd', '3': 'a'},
    'buzz': {'1': '0', '2': 'e', '3': 'a'},
    'rook': {'1': '0', '2': '2', '3': 'e'},
    'tobi': {'1': '0', '2': 'c', '3': '6'},
    'spindle': {'1': '0', '2': '4', '3': 'a'},
    'shellby': {'1': '0', '2': '5', '3': 'e'},
    'snapjaw': {'1': '0', '2': '4', '3': 'a'},
    'squall': {'1': '0', '2': '3', '3': 'e'},
    'geta': {'1': '0', '2': '6', '3': 'd'},
}
GLIDE_ART = [
    "......0000......",
    "...000aaaa000...",
    ".00aabaaaabaa00.",
    "0aabaaaaaaaabaa0",
    "0000000000000000",
    "...0..0000..0...",
    "...0.066aab0.0..",
    "...00660cc0c00..",
    "....060cccc0....",
    ".....044440.....",
    "....06666660....",
    "....06666660....",
    "....0bb00bb0....",
    "...0bb0..0bb0...",
    "...000....000...",
    "................"]


from skyward_art import ART


def recolor(art, pal):
    return [''.join(pal.get(ch, ch) for ch in row) for row in art]


def tobi(name):
    """Tobi as Mark drew him (the small form, 16 x 16)"""
    src = {'stand': 'stand', 'run1': 'walk1', 'run2': 'walk2', 'run3': 'run1', 'jump': 'jump'}[name]
    return recolor(ART['tobi_' + src], PAL['tobi'])


def pieces(art):
    """a 32 x 32 picture as four 16 x 16 frames: top left, top right, bottom left, bottom right"""
    return [[r[x:x + 16] for r in art[y:y + 16]] for y in (0, 16) for x in (0, 16)]


MEDAL = [
    ["..eeee..", ".eeeeee.", "eeeaaeed", "eeeaeedd", "eeeeeedd", "eeeeeddd", ".eedddd.", "..dddd.."],
    ["...ee...", "..eeee..", "..eaed..", "..eaed..", "..eeed..", "..eedd..", "..eddd..", "...dd..."],
    ["...ed...", "...ed...", "...ed...", "...ed...", "...ed...", "...ed...", "...ed...", "...ed..."],
    ["...dd...", "..deed..", "..deae..", "..deae..", "..deee..", "..ddee..", "..ddde..", "...dd..."],
]
WINDSOCK = [
    "..00............",
    "..0b444aa444a...",
    "..0b444aa444aa4.",
    "..0b444aa444aa44",
    "..0b444aa444aa4.",
    "..0b444aa444a...",
    "..0b............",
    "..0b............",
    "..0b............",
    "..0b............",
    "..0b............",
    "..0b............",
    "..0b............",
    "..0b............",
    ".00bb0..........",
    "000bbb0........."]
MABEL = [
    ".....00000......",
    "...006666600....",
    "..0666666aa0....",
    "..a6666a00a0....",
    ".aa60cccc0c0....",
    ".aa0ccc0ccc0....",
    "..a0ccccccc0....",
    "...0aaaaaa0.....",
    "..0a4444440.....",
    ".0c04444440c0...",
    ".0c044444400....",
    "...04444440.....",
    "...0666666......",
    "...0660660......",
    "..00000.0000....",
    "..00000.0000...."]
BIPLANE = [
    "................................",
    "................................",
    "................................",
    "................................",
    "................................",
    "................................",
    "................................",
    "................................",
    "................................",
    "................................",
    "................................",
    "................................",
    "................................",
    "....000000000000000000..........",
    "...0444444444444444444a0........",
    "....000000000000000000..........",
    "......0.....0.....0.............",
    "......0....060....0.....0.......",
    ".00...0...0cc60...0....0b0......",
    "0440.000000cc0000000..0bb0......",
    "04440444444004444444400b0.......",
    "0444444aa4444444444444460.......",
    ".044444aa4444444444444460.......",
    "..000444444444444444444000......",
    "....000000000000000000..0b0.....",
    "...0444444444444444444a0.0b0....",
    "....000000000000000000....0.....",
    "........0.......0...............",
    ".......0.0.....0.0..............",
    "......07770...07770.............",
    "......07770...07770.............",
    ".......000.....000.............."]

PLAYER_FRAMES = ['stand', 'run1', 'run2', 'run3', 'jump', 'glide']
NPF = len(PLAYER_FRAMES)


def common_frames():
    fr = []
    for flip in (False, True):
        for f in PLAYER_FRAMES:
            art = GLIDE_ART if f == 'glide' else tobi(f)
            fr.append((('L_' if flip else 'R_') + f, [r[::-1] for r in art] if flip else art))
    for i, m in enumerate(MEDAL):
        fr.append(('medal%d' % (i + 1), m))
    return fr


COMMON = common_frames()
FID_MEDAL = 2 * NPF
SETS = {    # a course's own frames, by the letter that places them
    'e': [('bumbler1', recolor(SRC['bumbler1'], PAL['bumbler'])),
          ('bumbler2', recolor(SRC['bumbler2'], PAL['bumbler']))],
    'z': [('buzz1', recolor(SRC['buzz1'], PAL['buzz'])), ('buzz2', recolor(SRC['buzz2'], PAL['buzz']))],
    'G': [('sock1', WINDSOCK), ('sock2', WINDSOCK[:1] + [r[:3] + r[4:] + '.' if i % 2 else r
                                                         for i, r in enumerate(WINDSOCK[1:6])] + WINDSOCK[6:])],
    'M': [('mabel1', MABEL), ('mabel2', MABEL)],
    'R': [('rook1_%d' % i, p) for i, p in enumerate(pieces(recolor(SRC['rook1'], PAL['rook'])))]
         + [('rook2_%d' % i, p) for i, p in enumerate(pieces(recolor(SRC['rook2'], PAL['rook'])))],
    'p': [('plane1_%d' % i, p) for i, p in enumerate(pieces(BIPLANE))]
         + [('plane2_%d' % i, p) for i, p in enumerate(pieces(BIPLANE))],
}
SETS['r'] = SETS['R']
SETS['x'] = [('spindle%d' % i, recolor(ART['spindle_walk%d' % i], PAL['spindle'])) for i in (1, 2)]
SETS['k'] = ([('shellby%d' % i, recolor(ART['shellby_walk%d' % i], PAL['shellby'])) for i in (1, 2)]
             + [('shellby3', recolor(ART['shellby_shell'], PAL['shellby']))])
SETS['j'] = [('snapjaw1', recolor(ART['snapjaw_open'], PAL['snapjaw'])),
             ('snapjaw2', recolor(ART['snapjaw_shut'], PAL['snapjaw']))]
SETS['Q'] = ([('squall1_%d' % i, q) for i, q in enumerate(pieces(recolor(ART['squall_run1'], PAL['squall'])))]
             + [('squall2_%d' % i, q) for i, q in enumerate(pieces(recolor(ART['squall_run2'], PAL['squall'])))])
LIFT = ["6666666666666666", "6dddddd66dddddd6", "6dddddd66dddddd6", "6666666666666666",
        ".6............6.", "..6..........6..", "...6666666666..."] + ["................"] * 9
SETS['l'] = [('lift1', LIFT), ('lift2', LIFT)]
SETS['q'] = SETS['Q']
SETS['V'] = SETS['R']
GETA = recolor(ART['geta_idle'], PAL['geta'])
EMBER = ['................'] * 4 + ['.....44.........', '....4dd4........', '...4deed4.......', '...4deed4.......',
         '....4dd4........', '.....44.........'] + ['................'] * 6
EMBER_LIFE = 40         # frames an ember flies (two byte columns a frame)
# kinds: 0 walks and can be landed on, 1 Baron Rook (32 x 32, three hits),
# 2 a picture (16 x 16), 3 a big picture (32 x 32)
# + 4 spiked (hurts from above too, unless Tobi rides the geta), + 8 Snapjaw
# (stays put, up for 64 frames and gone for 64), x10 a lift (carries Tobi),
# x20 Shellby (landed on: a shell; the shell touched: it slides off),
# x40 moves every frame
K_BIG, K_PIC, K_SPIKE, K_SNAP, K_LIFT, K_SHELL, K_FAST = 1, 2, 4, 8, 0x10, 0x20, 0x40
KIND = {'e': 0, 'z': 0, 'R': 1, 'G': 2, 'M': 2, 'p': 3, 'r': 3,
        'x': K_SPIKE, 'k': K_SHELL, 'j': K_SPIKE | K_SNAP, 'Q': K_BIG | K_FAST, 'l': K_LIFT,
        'q': K_BIG | K_FAST, 'V': K_BIG | K_FAST}
HP = {'q': 4, 'V': 4}       # landings a boss takes (the others: 3)
BIG_CH = 'RQqV'

# ---------------------------------------------------------------------------
# tiles (16 x 16, one hex digit a pixel) and band pictures, by theme
# ---------------------------------------------------------------------------
SOIL = ["dddddddddddddddd", "d6dddddddd6ddddd", "ddddddd6dddddddd", "dddddddddddddddd",
        "dddd6dddddddd6dd", "dddddddddddddddd", "dd6ddddddddddddd", "dddddddddd6ddddd",
        "dddddddddddddddd", "dddddd6ddddddddd", "d6dddddddddddddd", "dddddddddddddddd",
        "ddddddd6dddddddd", "ddd6ddddddddd6dd", "dddddddddddddddd", "ddddd6dddddddddd"]
BRICK = ["cccccccccccccccc", "4444444464444444", "4444444464444444", "4444444464444444",
         "6666666666666666", "4446444444444644", "4446444444444644", "4446444444444644",
         "6666666666666666", "4444444464444444", "4444444464444444", "4444444464444444",
         "6666666666666666", "4446444444444644", "4446444444444644", "6666666666666666"]
HARD = ["aaaaaaaaaaaaaaa7"] + ["abbbbbbbbbbbbb77"] * 13 + ["a777777777777777", "7777777777777777"]
STONE = ["bbbbbbb7bbbbbbb7", "bbbbbbb7bbbbbbb7", "bbbbbbb7bbbbbbb7", "7777777777777777",
         "bbb7bbbbbbb7bbbb", "bbb7bbbbbbb7bbbb", "bbb7bbbbbbb7bbbb", "7777777777777777"] * 2
ROCK = ["b7bbbbbb7bbbbbbb", "bb7bbbbbb7bbbb7b", "bbb77bbbbb7bb7bb", "bbbbb7bbbbb77bbb",
        "7bbbbb7bbbbb7bbb", "b7bbbbb7bbbbb7bb", "bb7bbbbb77bbbb7b", "bbb7bbbbbb7bbbb7"] * 2


def on_sky(rows, sky='8'):
    return [r.replace('.', sky) for r in rows]


GRASS_TILES = {
    ' ': ["8" * 16] * 16,
    '#': ["ffffffffffffffff", "f9ff9fff9ff9fff9", "9999999999999999", "ddd9ddd9ddd9ddd9"] + SOIL[:12],
    'D': SOIL,
    'B': BRICK,
    'H': HARD,
    'K': ROCK,
    '=': on_sky(["6666666666666666", "dddddd6ddddddd6d", "dddddd6ddddddd6d", "6666666666666666",
                 ".66..........66.", ".666........666.", ".66.6......6.66.", ".66..6....6..66.",
                 ".66...6..6...66.", ".66....66....66.", ".66....66....66.", ".66...6..6...66.",
                 ".66..6....6..66.", ".66.6......6.66.", ".666........666.", ".66..........66."]),
    'm': on_sky(["................"] * 7 + [
                 ".....ffff.......", "...ffffffff.....", "..ffff9fffff....", ".ffffffffff9f...",
                 ".ff9ffffffffff..", "fffffff9ffff9ff.", "ffffffffffffffff", "9fff9ffffff9fff9",
                 "9999999999999999"]),
    'T': on_sky(["................", ".....ffffff.....", "...ffffffffff...", "..ffff9fffffff..",
                 ".ffffffffff9fff.", ".ff9fffffffffff.", "ffffffff9fffffff", "fffffffffffff9ff",
                 "ff9fffffffffffff", "ffffff9fffff9fff", ".fffffffffffff9.", ".9fff9ffffffff9.",
                 "..99ffffff9f99..", "...9999999999...", "......6666......", "......6d66......"]),
    't': on_sky(["......6d66......"] * 12 + [".....66d666.....", ".....6dd666.....",
                                             "....66dd6666....", "...666666666...."]),
    'f': on_sky(["................"] * 9 + [
                 "....a.....e.....", "...a4a...ece....", "....a.....e.....", "....9.....9.....",
                 "...99....99.....", "....9.....9.....", "....9.....9....."]),
    'c': on_sky(["................", "................", "................", "......aaaa......",
                 "....aaaaaaaa....", "...aaaaaaaaaa...", "..aaaaaaaaaaaa..", ".aaaaaaaaaaaaaa.",
                 ".aabaaaaaaaabaa.", "..bbbaaabbbbbb..", "................", "................",
                 "................", "................", "................", "................"]),
}
WALL = ["1111111711111117", "1111111711111117", "1111111711111117", "7777777777777777",
        "1117111111171111", "1117111111171111", "1117111111171111", "7777777777777777"] * 2
KEEP_TILES = {
    ' ': WALL,
    '#': STONE,
    'W': STONE,
    'H': HARD,
    'K': STONE,
    'B': BRICK,
    'L': ["4e44444e444444e4", "e4e444e4e4444e4e", "444e4e444e44e444", "4444e44444ee4444",
          "dddddddddddddddd", "4d4444d44444d444", "4444444444444444", "444d4444444d4444"]
         + ["4444444444444444", "44444d44444444d4"] * 4,
    'w': ["1111111711111117", "1111111711111117", "1111100000111117", "7777000000077777",
          "1110003330001111", "1110033333001111", "1110033333001111", "7770033333007777",
          "1110033333001117", "1110033333001117", "1110000000001117", "7777777777777777",
          "1117111111171111", "1117111111171111", "1117111111171111", "7777777777777777"],
    'P': ["1116666666671117", "1114444444471117", "1114444e44471117", "77744e4e4e477777",
          "1114eeeee4471111", "11144eee44471111", "1114e4e4e4471111", "7774444444477777",
          "1114444444471117", "1114444444471117", "1111444444111117", "7777744447777777",
          "1117114411171111", "1117111111171111", "1117111111171111", "7777777777777777"],
    '%': ["1111111711111117", "1111111e11111117", "111111e4e1111117", "777777e4e7777777",
          "11171ee4ee171111", "11171e444e171111", "111716666e171111", "7777776677777777",
          "1111116611111117", "1111116611111117", "1111116611111117", "7777776677777777",
          "1117111111171111", "1117111111171111", "1117111111171111", "7777777777777777"],
}
def spikes(bg):
    rows = []
    for r in range(16):
        row = ''
        for x in range(16):
            d = abs((x % 4) - 1.5)
            row += ('a' if r < 3 else '6') if d <= 0.5 + r / 10 else bg
        rows.append(row)
    return rows


def crate(mark):
    rows = ["6666666666666666"] + ["6dddddddddddddd6"] * 14 + ["6666666666666666"]
    rows = [list(r) for r in rows]
    for y, line in enumerate(mark):
        for x, ch in enumerate(line):
            if ch != '.':
                rows[4 + y][4 + x] = ch
    return [''.join(r) for r in rows]


def extra_tiles(bg):
    """the tiles every theme has, on its background color"""
    return {
        '^': spikes(bg),
        'U': ["4444444444444444", "4aaaaaaaaaaaaaa4", "4aaaaaaaaaaaaaa4", "4444444444444444"]
             + ["4e4444e44e4444e4", "44e44e4444e44e44", "444ee444444ee444", "4444444444444444"] * 3,
        '$': [(bg * 16)] * 2 + [bg * 7 + 'aa' + bg * 7, bg * 6 + 'a' + bg * 2 + 'a' + bg * 6] + [bg * 16] * 4
             + [bg * 3 + 'aa' + bg * 11, bg * 2 + 'a' + bg * 2 + 'a' + bg * 10] + [bg * 16] * 2
             + [bg * 11 + 'aa' + bg * 3, bg * 10 + 'a' + bg * 2 + 'a' + bg * 2] + [bg * 16] * 2,
        '1': crate(["..ff....", ".f44444.", ".444a444", "44444444", "44444444", ".444444.", "..4444..", "........"]),
        '2': crate(["....f...", "...f....", "..4444..", ".4e4444.", ".444444.", "..44444.", "...444..", "....4..."]),
        '3': crate([".......a", ".....aab", "...aaab.", "..aaab..", ".aaab...", ".aab....", "ab......", "b......."]),
        '4': crate(["........", "66666666", "6dddddd6", "66666666", ".66..66.", ".66..66.", ".66..66.", "........"]),
        'X': ["7777777777777777"] + ["7dddddddddddddd7"] * 14 + ["7777777777777777"],
        'u': ["..666666666666..", ".66dddddddddd66.", ".6dd666666dd6d6.", ".66dddddddddd66."]
             + [".6666666666666.."[:15] + "."] * 0 + [".666666666666666"[:1] + "66666d6666d666" + "."] * 11
             + ["6666666666666666"],
    }


ATTR = {'#': 1, 'D': 1, 'B': 1, 'H': 1, 'K': 1, '=': 1, 'W': 1, 'X': 1, 'u': 1, 'i': 1, '<': 1, '_': 1, '>': 1,
        '^': 3, 'U': 5, '$': 8, '1': 0x11, '2': 0x31, '3': 0x51, '4': 0x71}
A_SOLID, A_THORN, A_BOUNCE, A_UP, A_CRATE = 1, 2, 4, 8, 0x10
SOLID_TILES = set(k for k, v in ATTR.items() if v & 1)
for _k, _v in extra_tiles('8').items():
    GRASS_TILES[_k] = [r.replace('.', '8') for r in _v]
for _k, _v in extra_tiles('1').items():
    if _k != '$':
        KEEP_TILES[_k] = [r.replace('.', '1') for r in _v]
EXTRA_SKY = {_k: [r.replace('.', '8') for r in _v] for _k, _v in extra_tiles('8').items()}
BOUNCEV = 0x0680
UPV = 0x01C0


def sky_bands():
    """[band][byte column][cell] -> byte: the high sky and the clouds"""
    W = BAND_W * 2
    hi = [['8'] * W for _ in range(16)]
    for g in range(16):
        for x in range(W):
            if g < 3:
                hi[g][x] = '3'
            elif g < 7:
                hi[g][x] = '3' if (x + g) % 2 else '8'
    for cx, cy, cw in ((12, 9, 16), (50, 12, 22), (88, 8, 12), (112, 13, 18)):
        for x in range(cx, cx + cw):
            hi[cy][x % W] = 'a'
        for x in range(cx + 3, cx + cw - 2):
            hi[cy + 1][x % W] = 'b'
    lo = [['8'] * W for _ in range(16)]
    for cx, cy, cw in ((8, 5, 26), (56, 9, 34), (100, 4, 20)):
        for g in range(16):
            for x in range(W):
                dx = (x - cx) % W
                if dx > W // 2:
                    dx -= W
                inside = shade = False
                for ox, oy, rx, ry in ((0, 2, cw // 2, 3), (-cw // 5, 0, cw // 4, 3), (cw // 6, -1, cw // 4, 4)):
                    ex = (dx - ox) / rx
                    ey = (g - cy - oy) / ry
                    if ex * ex + ey * ey <= 1:
                        inside = True
                        if g - cy - oy > ry * 0.35:
                            shade = True
                if inside:
                    lo[g][x] = 'b' if shade else 'a'
    return [hi, lo]


def keep_bands():
    W = BAND_W * 2
    return [[[WALL[g][x % 16] for x in range(W)] for g in range(16)] for _ in range(2)]


CAVE_ROCK = ["7b777777b7777777", "77b777777b7777b7", "777bb77777b77b77", "77777b77777bb777",
             "b77777b77777b777", "7b77777b77777b77", "77b77777bb7777b7", "777b777777b7777b"] * 2
CAVE_TILES = {
    ' ': ["1" * 16] * 16,
    '#': ["bbbbbbbbbbbbbbbb", "b7bb7bbb7bb7bbb7"] + CAVE_ROCK[:14],
    'K': CAVE_ROCK,
    'D': CAVE_ROCK,
    'H': HARD,
    'B': BRICK,
    '=': [r.replace('8', '1') for r in GRASS_TILES['=']],
}
for _k, _v in extra_tiles('1').items():
    CAVE_TILES[_k] = [r.replace('.', '1') for r in _v]


def cave_bands():
    """the cave's roof: rock with stalactites, then the dark"""
    W = BAND_W * 2
    hi = [['7'] * W for _ in range(16)]
    lo = [['1'] * W for _ in range(16)]
    for x in range(W):
        if (x * 7) % 11 == 0:
            hi[(x * 5) % 13 + 1][x] = 'b'
        d = (4, 9, 13, 7, 3, 1, 6, 11, 5, 2, 8, 12, 4, 1, 3, 6)[(x // 4) % 16] - 2 * abs((x % 4) - 1.5)
        for g in range(16):
            if g < d:
                lo[g][x] = '7'
    return [hi, lo]


# Gusty Mesa: sand, sandstone, saguaros; thin high cloud in the low band
SANDSTONE = ["ddddddd6ddddddd6", "dedddddd6ddddd6d", "ddddddd6ddddddd6", "6666666666666666",
             "ddd6ddddddd6dddd", "dd6dddedd6dddddd", "ddd6ddddddd6dddd", "6666666666666666"] * 2
DESERT_TILES = {
    ' ': ["8" * 16] * 16,
    '#': ["eeeeeeeeeeeeeeee", "eedeeeedeeedeeed", "deddeddddeddedde"] + SOIL[:13],
    'D': SOIL,
    'K': SANDSTONE,
    'B': BRICK,
    'H': HARD,
    '=': GRASS_TILES['='],
    'c': GRASS_TILES['c'],
    'i': ["8" * 16] * 16,       # a mirage block: solid, and not to be seen
    'm': on_sky(["................"] * 9 + [
                 "......eeee......", "....eeeeeeee....", "...eeeedeeeee...", "..eeeeeeeeedee..",
                 ".eedeeeeeeeeeee.", "eeeeeedeeeeeedee", "eeeeeeeeeeeeeeee"]),
    'T': on_sky(["......ffff......", ".....ff9fff.....", ".....ffff9f.....", ".....f9ffff..ff.",
                 ".ff..ffff9f.ff9f", "ff9f.ff9fff.ffff", "ffff.ffffff.f9ff", "f9ff.f9ff9f.ffff",
                 "ffff.ffffffffff9", "ff9ffff9ffff9ff.", ".fffffffffffff..", "..fffff9fff.....",
                 ".....ffff9f.....", ".....f9ffff.....", ".....ffff9f.....", ".....ff9fff....."]),
    't': on_sky([".....ffff9f.....", ".....f9ffff.....", ".....ffffff.....", ".....ff9f9f....."] * 4),
    'f': on_sky(["................"] * 10 + [
                 "..6...6.........", "...6.6..6.......", "..6.66.6....bb..", "...666.6...bbbb.",
                 "....66.....b7bb.", "....6.....bbbb7b"]),
}


def desert_bands():
    W = BAND_W * 2
    hi = [['8'] * W for _ in range(16)]
    for g in range(16):
        for x in range(W):
            if g < 2:
                hi[g][x] = '3'
            elif g < 5:
                hi[g][x] = '3' if (x + g) % 2 else '8'
    for x in range(70, 88):
        hi[9][x] = 'a'
    for x in range(73, 86):
        hi[10][x] = 'b'
    lo = [['8'] * W for _ in range(16)]     # thin high cloud
    for cx, cy, cw in ((60, 4, 22), (70, 6, 14), (100, 11, 20), (2, 12, 10), (24, 8, 16), (30, 10, 8)):
        for x in range(cx, cx + cw):
            lo[cy][x % W] = 'a'
    return [hi, lo]


# the boat between the worlds (a picture)
SEA_TILES = dict(GRASS_TILES)
SEA_TILES.update({
    '~': ["8888888888888888", "88aa888888aa8888", "8a33a8888a33a888", "3333333333333333",
          "3333333333333333", "3333388833333333", "3333333333338883", "3333333333333333"] * 2,
    '<': ["8888888888888888", "6666666666666666", "86dddddddddddddd", "886ddddddddddddd", "8886dddddddddddd",
          "88886666dd666666", "33333666dd666666", "33333366dd666666"] + ["3333333666666666"] * 2
         + ["3333333333333333"] * 6,
    '_': ["6666666666666666", "6666666666666666", "dddddddddddddddd", "dddddddddddddddd", "dddddddddddddddd",
          "666dd666dd666dd6", "666dd666dd666dd6", "666dd666dd666dd6"] + ["6666666666666666"] * 2
         + ["3333333333333333"] * 6,
    '>': ["8888888888888888", "6666666666666666", "dddddddddddddd68", "ddddddddddddd688", "dddddddddddd6888",
          "666666dd66668888", "666666dd66633333", "666666dd66333333"] + ["6666666663333333"] * 2
         + ["3333333333333333"] * 6,
    '|': ["8888888668888888"] * 16,
    'A': ["8888888668888888", "8888888a68888888", "888888aa68888888", "88888aaa68888888", "8888aaab68888888",
          "888aaaab68888888", "88aaaaab68888888", "8aaaaabb68888888", "aaaaaabb68888888", "aaaaabbb68888888",
          "aaaabbbb68888888", "8888888668888888", "8888888668888888", "8888888668888888", "8888888668888888",
          "8888888668888888"],
    'a': ["8888888668888888", "8888888648888888", "8888888644888888", "8888888644488888", "8888888644888888",
          "8888888648888888"] + ["8888888668888888"] * 10,
})

DESERT_TILES.update(EXTRA_SKY)


THEMES = {
    'desert': dict(tiles=DESERT_TILES, bands=desert_bands),
    'sea': dict(tiles=SEA_TILES, bands=sky_bands),
    'grass': dict(tiles=GRASS_TILES, bands=sky_bands),
    'cave': dict(tiles=CAVE_TILES, bands=cave_bands),
    'keep': dict(tiles=KEEP_TILES, bands=keep_bands),
}

# ---------------------------------------------------------------------------
# courses.  5 rows of 128 tiles; row 4 is the ground.  Objects stand in the
# map: S start, o medal, e Bumbler, z Buzzbee, G windsock (the goal),
# R Baron Rook, M Mabel, p the biplane, r Rook as a picture.  Tiles 0-1 and
# the last ones are a wall, so the wrap of the 1,024 byte columns never shows.
# ---------------------------------------------------------------------------
def course(name, theme, kind, glider, text, segs):
    rows = [''.join(s[r] for s in segs) for r in range(NTROW)]
    for r in rows:
        assert len(r) == LEVEL_W, (name, len(r))
    assert len(text) == 3 and all(len(t) <= 80 for t in text), name
    return dict(name=name, theme=theme, kind=kind, glider=glider, text=text, rows=rows)


COURSES = [
    course('title', 'grass', 1, 0,
           ["SKYWARD TOBI     BREEZY ISLE AND GUSTY MESA     A PLACARD PORT OF SKYWARD TOBI 4",
            "BARON ROOK'S LIGHTNING BROKE MABEL TAILSPIN'S BIPLANE.  HER STUNT MEDALS FELL",
            "ACROSS THE ISLE AND HIS CROWS CARRIED HER OFF TO CROW KEEP.   PRESS JUMP"],
           [("KK.......r......", "KK....p.........", "KK.......cc....c", "KK...S.....mT...", "################"),
            ("................", "....c...........", "..........c.....", "..f....T.....m..", "################"),
            ] + [("................", "................", "................", "................", "################")] * 5
           + [("............KKKK", "............KKKK", "............KKKK", "............KKKK", "################")]),
    course('meadow', 'grass', 0, 0,
           ["COURSE 1-1   BREEZY MEADOW",
            "ARROWS OR PAD: RUN.  UP, SPACE, B OR A: JUMP.  LAND ON THE BUMBLERS.   ESC: DOS",
            "COLLECT MABEL'S STUNT MEDALS AND REACH THE WINDSOCK.     PRESS JUMP TO START"],
           [("KK..............", "KK........c.....", "KK..............", "KK.S....m...ooo.", "################"),
            ("................", "......ooo.......", "......BBB.......", "..f.......e....T", "################"),
            ("....c...........", "................", "T.......oo......", "t...m........e..", "#######..#######"),
            ("................", "......ooo.......", "................", ".....####...f...", "#####DDDD#######"),
            ("..........c.....", ".........oo.....", "........===.....", "...H.........e..", "################"),
            ("................", "................", ".....o.o.o......", "..m..........m..", "#####...########"),
            ("................", "....oooo........", "....BBBB..T.....", "........e.t.e...", "################"),
            ("....c.......KKKK", "............KKKK", "......H.....KKKK", ".....HH..G..KKKK", "################")]),
    course('bluffs', 'grass', 0, 0,
           ["COURSE 1-2   BRAMBLE BLUFFS",
            "THE BLUFFS ARE TWO BLOCKS HIGH: JUMP FROM A RUN.  BUZZBEES FLY AT HEAD HEIGHT.",
            "A LIFE IS LOST IN THE GAPS.  TOBI COMES BACK WHERE HE LAST STOOD.    PRESS JUMP"],
           [("KK..............", "KK....c.........", "KK..............", "KK.S.....m......", "################"),
            ("................", "........ooo.....", ".......####.....", "....H..DDDD..e..", "################"),
            ("...........c....", "...z............", "......oo........", ".........##...m.", "######..###..###"),
            ("................", "....ooooo.......", "...#######......", "...DDDDDDD...e..", "################"),
            ("......c.........", "..........z.....", "....oo..........", "...===......H...", "###.....########"),
            ("................", ".......oo.......", ".....######.....", "..e..DDDDDD.....", "###########..###"),
            ("...c............", "....z.....oo....", "..........==....", "......==.....T..", "####.........t##"[:13] + "###"),
            ("............KKKK", "............KKKK", ".....HH.....KKKK", "..e..HH..G..KKKK", "################")]),
    course('cliffs', 'grass', 0, 1,
           ["COURSE 1-3   KITE CLIFFS",
            "TOBI STITCHED A GLIDER FROM THE BIPLANE'S WING CLOTH: HOLD JUMP IN THE AIR TO",
            "GLIDE.  JUMP FROM THE HIGH GROUND AND HOLD ON OVER THE WIDE GAPS.    PRESS JUMP"],
           [("KK..............", "KK...c..........", "KK..............", "KK.S......ooo...", "#############..."),
            ("................", "..oo............", "................", ".........####...", "..#####..DDDD..."),
            ("........c.......", "...o.o.o.o......", "................", "................", "............####"),
            ("................", "......ooo.......", ".....####.......", "..e..DDDD.......", "#########......."),
            ("....c...........", "o..o..o.........", "..........z.....", "..........==....", "........####...."),
            ("................", "................", "....ooo.........", "...=====........", "..............##"),
            ("..c.............", "......o.o.o.o...", "....H...........", "...HH...........", "######.........#"),
            ("............KKKK", "............KKKK", "............KKKK", ".....e...G..KKKK", "################")]),
    course('cave', 'cave', 0, 0,
           ["COURSE 1-4   WHISTLING CAVE",
            "THE VENTS BLOW UPWARD: STEP INTO ONE TO RIDE OVER A WALL OR OUT OF A PIT.",
            "SPINDLES ARE ALL NEEDLES: JUMP OVER THEM.  THE CRATE HOLDS A SKY BERRY.   PRESS JUMP"[:80]],
           [("KK..............", "KK..............", "KK..............", "KK.S......oo....", "################"),
            ("......$.........", "......$K........", "..o...$K........", "..o...$K...x....", "################"),
            ("................", ".....ooo........", "....=====.......", "................", "######....######"),
            ("................", "...$$$..o.o.....", "...$$$..........", "...$$$.......e..", "###$$$...#######"),
            ("....$...........", "..1.$K..........", "....$K....oo....", "....$K....HH....", "################"),
            ("................", "................", "........ooo.....", "....j......x....", "####u###########"),
            ("................", "....$$$...z.....", "....$$$.........", "....$$$.........", "####$$$...######"),
            ("............KKKK", "............KKKK", "............KKKK", ".........G..KKKK", "################")]),
    course('fort', 'keep', 0, 0,
           ["GALE FORT",
            "THE FORT IN THE MIDDLE OF THE ISLE.  THORNS, FIRE PITS AND A BOUNCE DRUM.",
            "CAPTAIN SQUALL RUNS THE HALL AT THE END: LAND ON HIM THREE TIMES.    PRESS JUMP"],
           [("WW.....P........", "WW..w......w....", "WW..............", "WW.S...%...oo...", "################"),
            ("....P...........", "..........1...w.", "......oo........", "......HH....x...", "#####LL#########"),
            ("...........P....", "..w.............", ".....oo.........", "....^^^.....e...", "################"),
            ("................", "....w....oo.....", "..............w.", "..%.............", "####U.....######"),
            ("......P.........", "...ooo..........", "............w...", ".x........x...%.", "########LL######"),
            ("................", "..w.....w.....w.", "................", "..%.........%...", "################"),
            ("...P........P...", ".......w........", "..........Q.....", "W.....%.......%.", "################"),
            ("WWWWWWWWWWWWWWWW", "WWWWWWWWWWWWWWWW", "WWWWWWWWWWWWWWWW", "WWWWWWWWWWWWWWWW", "################")]),
    course('shore', 'grass', 0, 0,
           ["COURSE 1-5   SHELLBACK BEACH",
            "SHELLBYS CRAWL THE SAND: LAND ON THEM.  A SNAPJAW COMES UP OUT OF ITS STUMP AND",
            "GOES DOWN AGAIN: PASS WHILE IT IS DOWN, AND NEVER LAND ON ONE.       PRESS JUMP"],
           [("KK..............", "KK......c.......", "KK..............", "KK.S......k.....", "################"),
            ("................", "....ooo.....1...", "....BBB.........", "..........j.....", "##########u#####"),
            ("...c............", "................", "......ooo.......", "...k............", "#######..#######"),
            ("................", ".....o.o.o......", "....j...........", "....u....m......", "################"),
            ("..........c.....", "........oo......", ".......===......", "..k.............", "#####....#######"),
            ("................", "................", "....oooo........", ".j.......k......", "#u##############"),
            ("................", ".....oo.........", "....####........", "....DDDD....m...", "################"),
            ("....c.......KKKK", "............KKKK", "............KKKK", ".........G..KKKK", "################")]),
    course('skyrail', 'grass', 0, 0,
           ["COURSE 1-6   SKYRAIL RISE",
            "LIFTS RUN BACK AND FORTH OVER THE GAPS: WAIT FOR ONE, STEP ON, AND RIDE IT.",
            "JUMP FROM A LIFT'S FAR END TO THE NEXT LEDGE.                        PRESS JUMP"],
           [("KK..............", "KK...c..........", "KK..............", "KK.S......oo....", "############l..."),
            ("................", "....ooo.........", "................", "..........x.....", ".....###########"),
            ("........c.......", "................", "..ooo......ooo..", "................", "##l.......l....."),
            ("................", "......o.o.......", "................", "................", "..######l......."),
            ("....c...........", "..ooo...........", "................", "................", "#######l........"),
            ("................", "....1...........", "................", "................", "################"),
            ("..c.............", "......o.o.o.....", "................", "................", "####l.......####"),
            ("............KKKK", "............KKKK", "............KKKK", ".........G..KKKK", "################")]),
    course('thorn', 'grass', 0, 0,
           ["COURSE 1-7   THORN GARDEN",
            "THE CRATE HOLDS THE TENGU GETA, A SANDAL THAT WALKS ON THORNS AND ON SPINDLES.",
            "WITHOUT IT, TAKE THE BRIDGES.  ONE HIT KNOCKS THE GETA OFF.          PRESS JUMP"],
           [("KK..............", "KK.......4......", "KK..............", "KK.S............", "################"),
            ("................", "....ooo.........", "................", "....^^^.....x...", "################"),
            ("...c............", "................", ".=========......", "...oooooo.......", "##^^^^^^^^######"),
            ("................", "......4.........", "................", "..x.......x.....", "################"),
            ("................", "..oo....oo......", "................", "................", "##^^^^##^^^^####"),
            ("......c.........", "................", "....=======.....", ".....ooooo......", "###^^^^^^^^^####"),
            ("................", "....ooo.........", "................", "...j.......e....", "###u############"),
            ("............KKKK", "............KKKK", "............KKKK", ".........G..KKKK", "################")]),
    course('boughs', 'grass', 0, 0,
           ["COURSE 1-8   BOUNCY BOUGHS",
            "A BOUNCE DRUM THROWS TOBI HIGH AND FAR: OVER THE TALL WALLS AND THE WIDE GAPS.",
            "KEEP RUNNING AS YOU STEP ON ONE.  THE CRATE HOLDS A GLIDE FEATHER.   PRESS JUMP"],
           [("KK..............", "KK....c.........", "KK..............", "KK.S............", "#########U######"),
            ("...ooo..........", "...HHH..........", "...HHH..........", "...HHH......e...", "##U#############"),
            ("...........c....", "................", "....ooo.........", "................", "##U.....########"),
            ("................", "....3...........", "................", ".........k......", "################"),
            ("......oo........", "......KK........", "......KK........", "......KK...x....", "#####U##########"),
            ("................", "................", "....ooo...ooo...", "................", "##U.....##U....."),
            ("................", "....ooo.........", "................", "......j.....e...", "######u#########"),
            ("............KKKK", "............KKKK", "............KKKK", ".........G..KKKK", "################")]),
    course('cellar', 'grass', 0, 0,
           ["BONUS   CLOUD CELLAR",
            "A ROOM FULL OF MABEL'S MEDALS, AND A GLIDE FEATHER IN THE CRATE: HOLD JUMP IN",
            "THE AIR TO GLIDE.  IT GOES ON WITH YOU UNTIL YOU ARE HIT.            PRESS JUMP"],
           [("KK..............", "KK.....3........", "KK..............", "KK.S.......ooo..", "################"),
            ("....ooooo.......", "................", "...=======......", "................", "################"),
            ("................", "..ooooooo.......", "................", ".....======.....", "####.........###"),
            ("..ooo...ooo.....", "................", "..===...===.....", "................", "################"),
            ("................", "...ooooo........", "................", "................", "##U.....########"),
            ("................", "..o.o.o.o.o.....", "................", "................", "################"),
            ("................", "................", "................", "................", "################"),
            ("............KKKK", "............KKKK", "............KKKK", ".........G..KKKK", "################")]),
    course('keep', 'keep', 0, 1,
           ["CROW KEEP",
            "MABEL IS HELD AT THE END OF THE KEEP.  MIND THE FIRE PITS.",
            "BARON ROOK WAITS IN THE LAST HALL: LAND ON HIM THREE TIMES.          PRESS JUMP"],
           [("WW.....P........", "WW..w......w....", "WW..............", "WW.S...%...oo...", "################"),
            ("....P...........", ".........ooo..w.", ".........HHH....", "............e.%.", "#####LL#########"),
            ("...........P....", "..w.............", ".....oo.........", "....####....e...", "####WWWW##LLL###"),
            ("................", "....w....oo.....", ".........HH..w..", "..%...H.........", "#####LLLLLLL####"),
            ("......P.........", "...ooo..........", "...HHH......w...", ".e........e...%.", "########LL######"),
            ("................", "..w.....w.....w.", "................", "..%.........%...", "###LL###########"),
            ("...P........P...", ".......w........", "..........R.....", "W.....%.......%.", "################"),
            ("WWWWWWWWWWWWWWWW", "WWWWWWWWWWWWWWWW", "WWWWWWWWWWWWWWWW", "WWWWWWWWWWWWWWWW", "################")]),
    course('boat', 'sea', 1, 0,
           ["THE HARBOR",
            "CROW KEEP HAS FALLEN, BUT BARON ROOK FLEW OFF WITH MABEL OVER THE WATER TO",
            "GUSTY MESA.  THE HARBOR IS OPEN AGAIN, AND TOBI TAKES THE BOAT.      PRESS JUMP"],
           [("KK..............", "KK....a.........", "KK....A....c....", "KK...S|.........", "##~~<___>~~~~~~~"),
            ("................", "....c...........", "..........c.....", "................", "~~~~~~~~~~~~~~~~"),
            ] + [("................", "................", "................", "................", "~~~~~~~~~~~~~~~~")] * 5
           + [("............KKKK", "............KKKK", "............KKKK", "............KKKK", "~~~~~~~~~~~~####")]),
    course('trail', 'desert', 0, 0,
           ["COURSE 2-1   SANDSTONE TRAIL",
            "GUSTY MESA: SAND, SANDSTONE AND HOT AIR.  THE UPDRAFTS RISE OUT OF THE CHASMS:",
            "STEP INTO ONE AND IT CARRIES TOBI UP AND OVER.                       PRESS JUMP"],
           [("KK..............", "KK...c..........", "KK..............", "KK.S......ooo...", "################"),
            ("................", "...$$$..o.o.....", "...$$$..........", "...$$$.......e..", "###$$$...#######"),
            ("....c...........", "......ooo.......", "..T.............", "..t..####....m..", "#####DDDD#######"),
            ("......$.........", "......$K........", "..o...$K........", "..o...$K...e....", "################"),
            ("................", ".....ooo........", "....=====.......", "................", "######....######"),
            ("................", "....1.....z.....", "................", "..T.........m...", "################"),
            ("................", "....$$$...oo....", "....$$$.........", "....$$$.........", "####$$$...######"),
            ("............KKKK", "............KKKK", "............KKKK", ".........G..KKKK", "################")]),
    course('ridge', 'desert', 0, 0,
           ["COURSE 2-2   THERMAL RIDGE",
            "ONE UPDRAFT AFTER ANOTHER: LEAVE THE FIRST HIGH ENOUGH TO REACH THE NEXT.",
            "A SHELLBY HAS WANDERED UP FROM THE BEACH.                            PRESS JUMP"],
           [("KK..............", "KK...c..........", "KK..............", "KK.S......ooo...", "################"),
            ("................", "...$$$..o.o.....", "...$$$..........", "...$$$......k...", "###$$$...#######"),
            ("........c.......", "....ooo.........", "....HHH.........", "..T.........m...", "################"),
            ("......$.........", "......$K........", "..o...$KK.......", "..o...$KKK..e...", "################"),
            ("................", "...$$$...$$$....", "...$$$...$$$....", "...$$$...$$$....", "###$$$...$$$...#"),
            ("................", "....1...........", "................", "......e......f..", "################"),
            ("................", "....$$$...oo....", "....$$$.........", "....$$$.........", "####$$$...######"),
            ("............KKKK", "............KKKK", "............KKKK", ".........G..KKKK", "################")]),
    course('canyon', 'desert', 0, 0,
           ["COURSE 2-3   UPDRAFT CANYON",
            "THE CANYON IS TOO WIDE TO JUMP: RIDE THE LIFTS AND THE UPDRAFTS ACROSS IT.",
            "THE CRATE NEAR THE END HOLDS A GLIDE FEATHER.                        PRESS JUMP"],
           [("KK..............", "KK...c..........", "KK..............", "KK.S......oo....", "############l..."),
            ("................", "....ooo.........", "................", "..........e.....", ".....###########"),
            ("................", "....$$$..o.o....", "....$$$.........", "....$$$.........", "####$$$...######"),
            ("......$.........", "......$K........", "..o...$K........", "..o...$K...x....", "################"),
            ("........c.......", "................", "..ooo......ooo..", "................", "##l.......l....."),
            ("................", "......o.o.......", "................", "................", "..######l......."),
            ("................", "....3...........", "................", "...........T....", "################"),
            ("............KKKK", "............KKKK", "............KKKK", ".........G..KKKK", "################")]),
    course('drywell', 'cave', 0, 0,
           ["COURSE 2-4   DRYWELL CAVERN",
            "THE OLD WELLS UNDER THE MESA ARE DRY, AND THORNS GROW IN THEM: TAKE THE LIFT",
            "ACROSS, AND THE VENT OVER THE WALL.                                  PRESS JUMP"],
           [("KK..............", "KK..............", "KK..............", "KK.S......oo....", "################"),
            ("................", "................", ".....ooo........", "..........######", "##########DDDDDD"),
            ("................", "...ooo..........", "................", "###l......######", "DDD^^^^^^^DDDDDD"),
            ("..........$.....", "..........$.....", "..........$K....", "#####.....$K....", "DDDDD###########"),
            ("................", "......ooo.......", "................", "................", "######...#######"),
            ("................", "........1.......", "................", "....j......x....", "####u###########"),
            ("................", "....$$$...z.....", "....$$$.........", "....$$$.........", "####$$$...######"),
            ("............KKKK", "............KKKK", "............KKKK", ".........G..KKKK", "################")]),
    course('gulch', 'desert', 0, 0,
           ["COURSE 2-5   SPINDLE GULCH",
            "SPINDLES CANNOT BE LANDED ON.  THE CRATE HOLDS AN EMBER PEPPER: DOWN OR PAD Y",
            "THROWS AN EMBER, AND AN EMBER KNOCKS OUT WHAT IT MEETS.              PRESS JUMP"],
           [("KK..............", "KK.......2......", "KK..............", "KK.S............", "################"),
            ("................", "....ooo.........", "................", "......x.....x...", "################"),
            ("...c............", "................", "......ooo.......", ".....####.......", "#####DDDD..#####"),
            ("................", "......2.........", "................", "..x.......x.....", "################"),
            ("................", "..oo....oo......", "..HH....HH......", "......x.........", "################"),
            ("......c.........", "................", "....ooo.........", "...........x....", "#######..#######"),
            ("................", "....ooo.........", "................", ".T.....x.....m..", "################"),
            ("............KKKK", "............KKKK", "............KKKK", ".........G..KKKK", "################")]),
    course('gorge', 'desert', 0, 0,
           ["COURSE 2-6   GLIDER GORGE",
            "THE CRATE HOLDS A GLIDE FEATHER: RUN, JUMP AND HOLD ON OVER THE GORGES.",
            "THE LIFTS ARE THE SLOW WAY FOR ANYONE WHO HAS LOST IT.               PRESS JUMP"],
           [("KK..............", "KK.......3......", "KK..............", "KK.S............", "################"),
            ("................", "......o.o.o.....", "................", "................", "####l.......####"),
            ("....c...........", "......ooo.......", ".....####.......", "..e..DDDD.......", "#########l......"),
            ("................", "................", "....ooo.........", "..........z.....", "################"),
            ("................", "....o.o.o.o.....", "....H...........", "...HH...........", "######l........."),
            ("................", ".....3..........", "................", "..T......e...m..", "################"),
            ("..c.............", "......o.o.o.o...", "................", "................", "####l.......####"),
            ("............KKKK", "............KKKK", "............KKKK", ".........G..KKKK", "################")]),
    course('skywalk', 'grass', 0, 0,
           ["COURSE 2-7   TENGU SKYWALK",
            "A WALK IN THE SKY ON BRIDGES AND THORNS.  THE CRATES HOLD THE TENGU GETA,",
            "WHICH WALKS ON THORNS AND LANDS ON SPINDLES.                         PRESS JUMP"],
           [("KK..............", "KK.......4......", "KK..............", "KK.S............", "################"),
            ("................", "....ooo.........", "................", "................", "####==^^^^==####"),
            ("...c............", "................", ".=========......", "...oooooo.......", "##^^^^^^^^######"),
            ("................", "......4.........", "................", "..x.......x.....", "====############"),
            ("................", "..oo....oo......", "................", "................", "==^^^^==^^^^===="),
            ("......c.........", "......ooo.......", "................", "................", "======...======="),
            ("................", "....ooo.........", "...........z....", "...x............", "================"),
            ("............KKKK", "............KKKK", "............KKKK", ".........G..KKKK", "################")]),
    course('mirage', 'desert', 0, 0,
           ["COURSE 2-8   MIRAGE MESA",
            "THE HEAT PLAYS TRICKS: SOME BLOCKS HERE CANNOT BE SEEN.  MABEL'S MEDALS LIE",
            "ALONG THEM, SO WALK WHERE THE MEDALS ARE.                            PRESS JUMP"],
           [("KK..............", "KK...c..........", "KK..............", "KK.S......ooo...", "################"),
            ("................", "................", "................", ".....o.o.o.o....", "#####iiiiiii####"),
            ("................", ".......ooo......", ".....o.iii......", "...o.iii.....e..", "################"),
            ("................", "....o.o.o.o.....", "....iiiiiii.....", "..i...x...x.....", "################"),
            ("....c...........", "...........1....", "................", "...o.o.o........", "###iiiii########"),
            ("................", "....o.o.o.......", "....iiiii.......", "..i.......k.....", "####......######"),
            ("................", "................", "....ooo.........", "..T....x.....m..", "################"),
            ("............KKKK", "............KKKK", "............KKKK", ".........G..KKKK", "################")]),
    course('fort2', 'keep', 0, 0,
           ["SQUALL FORT",
            "CAPTAIN SQUALL'S OWN FORT.  THE CRATE HOLDS AN EMBER PEPPER FOR THE SPINDLES.",
            "THE CAPTAIN IS READY THIS TIME: LAND ON HIM FOUR TIMES.              PRESS JUMP"],
           [("WW.....P........", "WW..w......w....", "WW..............", "WW.S...%...oo...", "################"),
            ("....P...........", "..........2...w.", "......oo........", "......HH....x...", "#####LL#########"),
            ("...........P....", "..w.............", ".....oo.........", "....^^^...^^^...", "################"),
            ("................", "....w....oo.....", "..............w.", "..%.............", "####U.....######"),
            ("......P.........", "...ooo..........", "............w...", ".x..........x.%.", "####LL###LL#####"),
            ("................", "..w.....w.....w.", ".....oo.........", "..%..HH.....%...", "###LL###########"),
            ("...P........P...", ".......w........", "..........q.....", "W.....%.......%.", "################"),
            ("WWWWWWWWWWWWWWWW", "WWWWWWWWWWWWWWWW", "WWWWWWWWWWWWWWWW", "WWWWWWWWWWWWWWWW", "################")]),
    course('keep2', 'keep', 0, 1,
           ["DUST KEEP",
            "BARON ROOK'S KEEP ON THE MESA, AND MABEL IS IN IT.  THE GLIDER HELPS OVER THE",
            "FIRE.  HE IS QUICKER HERE: LAND ON HIM FOUR TIMES.                   PRESS JUMP"],
           [("WW.....P........", "WW..w......w....", "WW..............", "WW.S...%...oo...", "################"),
            ("....P...........", ".........ooo..w.", ".........HHH....", "............x.%.", "#####LLL########"),
            ("...........P....", "..w.............", ".....oo.........", "....####....e...", "####WWWW##LLL###"),
            ("................", "....w....oo.....", ".........HH..w..", "..%...H.........", "#####LLLLLLL####"),
            ("......P.........", "...ooo..........", "...HHH......w...", ".e........x...%.", "#####LLL##LL####"),
            ("................", "..w.....w.....w.", "................", "..%.........%...", "###LL####LLL####"),
            ("...P........P...", ".......w........", "..........V.....", "W.....%.......%.", "################"),
            ("WWWWWWWWWWWWWWWW", "WWWWWWWWWWWWWWWW", "WWWWWWWWWWWWWWWW", "WWWWWWWWWWWWWWWW", "################")]),
    course('ending', 'grass', 1, 0,
           ["SKYWARD TOBI     BREEZY ISLE AND GUSTY MESA CLEAR",
            "\"TOOK YOU LONG ENOUGH, KID.  I HAD HIM RIGHT WHERE I WANTED HIM.\"  MABEL IS",
            "FREE, AND THE BIPLANE'S FIRST PIECE IS BACK.  THANK YOU FOR PLAYING. PRESS JUMP"],
           [("KK..............", "KK.....c........", "KK......p.......", "KK...S.M...m..T.", "################"),
            ("....c...........", "..........c.....", "................", "..f....T....m...", "################"),
            ] + [("................", "................", "................", "................", "################")] * 5
           + [("............KKKK", "............KKKK", "............KKKK", "............KKKK", "################")]),
]
OBJ_CH = set('SoezGRMprxkjQlqV')
NCOURSE = len(COURSES)


# ---------------------------------------------------------------------------
# a course, compiled
# ---------------------------------------------------------------------------
def pix_byte(left, right):
    return int(left, 16) | (int(right, 16) << 4)


def tile_bytes(art):
    """[byte 0-7][row 0-15] -> byte"""
    assert len(art) == 16 and all(len(r) == 16 for r in art), art
    return [[pix_byte(art[r][2 * j], art[r][2 * j + 1]) for r in range(16)] for j in range(8)]


class Course:
    def __init__(self, n):
        c = COURSES[n]
        self.n = n
        self.c = c
        th = THEMES[c['theme']]
        self.tiles = th['tiles']
        bands = th['bands']()
        self.bandpix = {}
        for (name, g0, g1, sh), px in zip(BANDS, bands):
            self.bandpix[name] = [[pix_byte(px[g][2 * col], px[g][2 * col + 1]) for g in range(g1 - g0)]
                                  for col in range(BAND_W)]
        self.trows = [[(' ' if ch in OBJ_CH or ch == '.' else ch) for ch in row] for row in c['rows']]
        for row in self.trows:
            for ch in row:
                assert ch in self.tiles, (c['name'], ch)
        # (row, tile) combinations, numbered: the tile map holds number * 8
        self.combos = []
        for r in range(NTROW):
            for ch in sorted(set(self.trows[r])):
                self.combos.append((r, ch))
        assert len(self.combos) <= 32, (c['name'], len(self.combos))
        for r in range(NTROW):      # a taken crate turns into X
            if set(self.trows[r]) & set('1234') and (r, 'X') not in self.combos:
                self.combos.append((r, 'X'))
        assert len(self.combos) <= 32, (c['name'], len(self.combos))
        self.cid = {k: i for i, k in enumerate(self.combos)}
        self.crates = [(r, t) for r in range(NTROW) for t in range(LEVEL_W) if self.trows[r][t] in '1234']
        # objects
        self.start = None
        self.goal = 0xFFFF      # none (Crow Keep: Rook)
        self.medals = []
        self.objs = []          # dict(ch, x, g, lo, hi)
        letters = []
        for r in range(NTROW):
            for t, ch in enumerate(c['rows'][r]):
                top = GROUND_G + 16 * r
                if ch == 'S':
                    self.start = t * 8
                elif ch == 'o':
                    self.medals.append((t * 8 + 2, top + 4))
                elif ch in KIND:
                    if ch not in letters:
                        letters.append(ch)
                    lo = hi = t
                    if ch in 'exk' + BIG_CH:
                        w = 2 if ch in BIG_CH else 1
                        r_feet = r + (1 if ch in BIG_CH else 0)
                        while lo > 0 and self.solid_t(lo - 1, r_feet + 1) and not self.solid_t(lo - 1, r_feet):
                            lo -= 1
                        while (hi + w < LEVEL_W and self.solid_t(hi + w, r_feet + 1)
                               and not self.solid_t(hi + w, r_feet)):
                            hi += 1
                    elif ch == 'z':
                        while lo > t - 3 and not self.solid_t(lo - 1, r):
                            lo -= 1
                        while hi < t + 3 and not self.solid_t(hi + 1, r):
                            hi += 1
                    elif ch == 'l':
                        while hi < t + 5 and not self.solid_t(hi + 2, r):
                            hi += 1
                    if ch == 'G':
                        self.goal = t * 8 - 4
                    self.objs.append(dict(ch=ch, x=t * 8, g=top, lo=lo * 8, hi=hi * 8))
        assert self.start is not None, c['name']
        assert len(self.objs) <= 8, (c['name'], len(self.objs))
        assert len(self.medals) <= 40, (c['name'], len(self.medals))
        # frames: the common ones, then this course's
        self.frames = list(COMMON)
        self.fid0 = {}
        for ch in letters:
            if SETS[ch][0][0] not in [f[0] for f in self.frames]:
                self.fid0[ch] = len(self.frames)
                self.frames += SETS[ch]
            else:
                self.fid0[ch] = [f[0] for f in self.frames].index(SETS[ch][0][0])
        self.geta_fid = 0
        self.geta_fid = len(self.frames)
        self.frames.append(('geta', GETA))
        self.ember_fid = len(self.frames)
        self.frames.append(('ember', EMBER))
        self.frame_id = {nm: i for i, (nm, _) in enumerate(self.frames)}

    def solid_t(self, t, r):
        if r < 0 or r >= NTROW:
            return False
        return self.trows[r][t % LEVEL_W] in SOLID_TILES

    def attr_t(self, t, r):
        return ATTR.get(self.trows[r][t % LEVEL_W], 0)

    def cell_tr(self, x, g):
        """(tile column, tile row) of a cell, as tile_at has it; None below the course"""
        if g >= NROW:
            return None
        return (x >> 3) % LEVEL_W, (max(g, GROUND_G) - GROUND_G) >> 4

    def solid_at(self, x, g):
        if g >= NROW:
            return False
        g = max(g, GROUND_G)        # above the course: as its top row
        return self.solid_t((x >> 3) % LEVEL_W, (g - GROUND_G) >> 4)

    def tb(self, r, t, used=()):
        return tile_bytes(self.tiles['X' if (t, r) in used else self.trows[r][t]])

    def background(self, scroll, used=()):
        """{address: byte} of the playfield for a scroll (byte columns); used:
        {(tile column, tile row)} of the crates taken"""
        out = {}
        for col in range(NCOL):
            page = 0x6100 + col * 512
            for name, g0, g1, sh in BANDS:
                w = ((scroll >> sh) + col) % BAND_W
                for g in range(g0, g1):
                    out[page + row_x(g)] = self.bandpix[name][w][g - g0]
            x = (scroll + col) % WRAP
            t, j = x >> 3, x & 7
            for r in range(NTROW):
                tbj = self.tb(r, t, used)[j]
                for k in range(16):
                    out[page + row_x(GROUND_G + 16 * r + k)] = tbj[k]
        return out

    def obj_page(self):
        obj = [0] * 256
        for i, o in enumerate(self.objs):
            obj[0x00 + i] = o['x'] & 255
            obj[0x08 + i] = o['x'] >> 8
            obj[0x10 + i] = o['g']
            obj[0x18 + i] = 0
            obj[0x20 + i] = o['lo'] & 255
            obj[0x28 + i] = o['lo'] >> 8
            obj[0x30 + i] = o['hi'] & 255
            obj[0x38 + i] = o['hi'] >> 8
            obj[0x40 + i] = 1
            obj[0x48 + i] = KIND[o['ch']]
            obj[0x50 + i] = self.fid0[o['ch']]
            obj[0x58 + i] = HP.get(o['ch'], 3)
        obj[0x60] = len(self.objs)
        obj[0x61] = len(self.medals)
        obj[0x62] = self.goal & 255
        obj[0x63] = self.goal >> 8
        obj[0x64] = self.start & 255
        obj[0x65] = self.c['kind']
        obj[0x66] = self.c['glider']
        obj[0x67] = self.start >> 8
        for r in range(NTROW):
            obj[0x68 + r] = 8 * self.cid.get((r, 'X'), 0)
        obj[0x6D] = self.geta_fid
        obj[0x6E] = self.ember_fid
        for i, (x, g) in enumerate(self.medals):
            obj[0x80 + i] = x & 255
            obj[0xA8 + i] = x >> 8
            obj[0xD0 + i] = g
        return obj


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


def draw_sprites_model(mem, sprites, frames):
    """sprites: [(frame id, SL_C, SL_G)] drawn in order onto mem (a bytearray)"""
    for fid, sc, sg in sprites:
        art = frames[fid][1]
        for r, k, m, v in sprite_masks(art):
            pg = VPG_T[(sc + k) & 255]
            x = ROWX_T[(sg + r) & 255]
            a = pg << 8 | x
            mem[a] = v if m == 0 else (mem[a] & m) | v


def sprite_rows(name, art):
    """the routine that draws a frame, as chunks of lines (one a pixel row,
    then the return): a chunk has no branches, so it may be anywhere"""
    chunks = []
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
                lines += ['    ld   [y,x], ac', '    and  0x%02X, ac' % m, '    or   0x%02X, ac' % v,
                          '    ld   ac, [y,x]']
        chunks.append(lines)
    chunks.append(['    ld   [srh], y', '    jmp  [srl]'])
    return chunks


ZP = '''
; ---------------------------------------------------------------------------
; program variables (zero page x20-x8F)
; ---------------------------------------------------------------------------
colpage    = 0x20       ; video page of the column being drawn (x61 + 2 * col)
rl         = 0x21       ; strip return address
rh         = 0x22
bw         = 0x23       ; band picture column
gt         = 0x24       ; course tile column 0-127
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
facing     = 0x31       ; 0 right, 6 left (frame offset)
anim       = 0x32
inp        = 0x33       ; input: 1 right, 2 left, 4 jump
course     = 0x34       ; 0 title, the courses, then the ending
kind       = 0x35       ; 0 a course to play, 1 a picture (jump: the next course)
glider     = 0x36       ; 1: Tobi has the glider
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
mode       = 0x80       ; 0 playing, 1 waiting for the jump key, 2 course clear (counting down)
clear_t    = 0x81       ;   frames left of mode 2
o_i        = 0x82       ; object loop index
dlo        = 0x83
dhi        = 0x84
inv        = 0x85       ; frames of safety after a lost life
gliding    = 0x86       ; 1: the glider is open this frame
moved      = 0x87
tmp3       = 0x88
n_med      = 0x89       ; medals in this course
n_en       = 0x8A       ; objects in this course
ll_lo      = 0x8B       ; lose_life's return address
ll_hi      = 0x8C
goal_lo    = 0x8D       ; the course is clear at this byte column
goal_hi    = 0x8E
jprev      = 0x8F       ; the jump key last frame (4 = down)
ekind      = 0x1E       ; (T6) this object's kind
jnow       = 0x1F       ; (T7) the jump key this frame
'''

BLOCK = 0x4000          # the course's tables: 12 pages, the first 6 sectors of Cn.LVL
                        # (x4D00-x4FFF is the file system's)
PAGES = {n: BLOCK + 0x100 * i for i, n in enumerate(
    ['BS_LO', 'BS_HI', 'TS_LO', 'TS_HI', 'LVA', 'LVB', 'LVC', 'SOLID', 'OBJ', 'FR', 'TEXT'])}
BLOCK_END = 0x4C00
TEXT_OFF = (0x000, 0x058, 0x0B0)
SD_OVL = 0x6000
SD_FRAG = (0x040, 0x180)
LOW_END = 0x1F00        # LIB_RAM


def sd_frags():
    """the free stretches of video RAM, [start, end): offsets SD_FRAG of each
    byte column but column 0 (where the blitter's off-screen columns write)
    and offset x110 (where its off-playfield rows write)"""
    out = []
    for c in range(1, 80):
        base = SD_OVL + 512 * c
        out += [(base + SD_FRAG[0], base + 0x110), (base + 0x111, base + SD_FRAG[1])]
    return out


def blitter():
    """the low RAM: ROWX, VPG, draw_sprites and as many of the common frames
    as fit below LIB_RAM -> (source, symbols, {addr: byte}, frames placed)"""
    def build(nfr):
        a = Asm()
        a.raw('#include "placard.asm"')
        a.raw(ZP)
        a.raw('LINK_LO = 0x04')
        a.raw('LINK_HI = 0x05')
        a.raw('MAP_SHADOW = 0x07')
        a.raw('MAP_SPR = 0xFF')
        a.org(0x0100, 'ROWX: video offset (low byte) of top cell + 32, 0x10 off the playfield')
        a.raw('ROWX:')
        for i in range(0, 256, 16):
            a.raw('    #d8 ' + ', '.join('0x%02X' % v for v in ROWX_T[i:i + 16]))
        a.org(0x0200, 'VPG: video page of byte column + 8, x60 off the screen')
        a.raw('VPG:')
        for i in range(0, 256, 16):
            a.raw('    #d8 ' + ', '.join('0x%02X' % v for v in VPG_T[i:i + 16]))
        a.org(0x0300, 'draw_sprites: draw the SL_ list (CALL it; maps every section to RAM)')
        a.raw('draw_sprites:')
        a.g('''
    ld   0x50, y                ; map FF: the video RAM readable, the course's
    ld   MAP_SPR, [y,x]         ; sprite routines in it
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
        for name, art in COMMON[:nfr]:
            a.raw('')
            a.raw('spr_%s:' % name)
            for ch in sprite_rows(name, art):
                for ln in ch:
                    a.raw(ln)
        src = '\n'.join(a.out) + '\n'
        mem, syms, _ = ps.assemble(src, HERE)
        return src, syms, mem
    n = len(COMMON)
    while True:
        src, syms, mem = build(n)
        if max(mem) < LOW_END:
            return src, syms, mem, n
        n -= 1


BLIT_SRC, BLIT_SYMS, BLIT_MEM, BLIT_N = blitter()


def course_file(n):
    """-> (bytes of Cn.LVL, info): the tables block, then the RAM from x6000
    (strips, and the sprite routines that are not in the low RAM)"""
    cs = Course(n)
    frags = sd_frags()
    free = [f[0] for f in frags]    # next free address of each stretch (first fit)
    state = [0, 0]                  # the stretch in use, the highest one used
    out = ['#include "placard.asm"', ZP, 'ROWX = 0x0100']

    def fit(size):
        """the first stretch with size bytes free; it becomes the one in use"""
        for i, f in enumerate(frags):
            if f[1] - free[i] >= size:
                state[0] = i
                state[1] = max(state[1], i)
                return
        raise AssertionError('course %d: past the video RAM' % n)

    def take(size):
        ad = free[state[0]]
        free[state[0]] += size
        return ad

    def place(lines, label=None):
        size = Asm.size(lines)
        fit(size)
        out.append('#addr 0x%04X' % take(size))
        if label:
            out.append(label + ':')
        out.extend(lines)

    cache = {}
    nstrip = [0]

    def strip(rows_vals):
        key = tuple(rows_vals)
        if key not in cache:
            lines = ['    ld   [colpage], y']
            for g, v in rows_vals:
                lines.append('    ld   0x%02X, x' % row_x(g))
                lines.append('    ld   0x%02X, [y,x]' % v)
            lines += ['    ld   [rh], y', '    jmp  [rl]']
            cache[key] = 'st_%d' % nstrip[0]
            nstrip[0] += 1
            place(lines, cache[key])
        return cache[key]

    bs = {}
    for name, g0, g1, sh in BANDS:
        for w in range(BAND_W):
            bs[(name, w)] = strip([(g, cs.bandpix[name][w][g - g0]) for g in range(g0, g1)])
    ts = {}
    for i, (r, ch) in enumerate(cs.combos):
        tb = tile_bytes(cs.tiles[ch])
        for j in range(8):
            ts[(i, j)] = strip([(GROUND_G + 16 * r + k, tb[j][k]) for k in range(16)])
    # sprite routines: row chunks chained through the stretches
    nhop = [0]
    for fi, (name, art) in enumerate(cs.frames):
        if fi < BLIT_N:
            continue
        first = True
        for ch in sprite_rows(name, art):
            size = Asm.size(ch)
            if first:
                fit(size + 4)
                out.append('#addr 0x%04X' % take(size))
                out.append('spr_%s:' % name)
                first = False
            else:
                if frags[state[0]][1] - free[state[0]] < size + 4:
                    nhop[0] += 1
                    lb = 'hp_%d' % nhop[0]
                    out.append('#addr 0x%04X' % take(4))
                    out.append('    ld   %s >> 8, y' % lb)
                    out.append('    jmp  %s' % lb)
                    fit(size + 4)
                    out.append('#addr 0x%04X' % free[state[0]])
                    out.append(lb + ':')
                out.append('#addr 0x%04X' % take(size))
            out.extend(ch)
    mem, syms, _ = ps.assemble('\n'.join(out) + '\n', HERE)
    assert min(mem) >= SD_OVL

    def page(vals):
        vals = list(vals)
        assert len(vals) <= 256
        return bytes(vals + [0] * (256 - len(vals)))

    bs_lo, bs_hi = [0] * 256, [0] * 256
    for bi, (name, g0, g1, sh) in enumerate(BANDS):
        for w in range(BAND_W):
            ad = syms[bs[(name, w)]]
            bs_lo[64 * bi + w], bs_hi[64 * bi + w] = ad & 255, ad >> 8
    ts_lo, ts_hi = [0] * 256, [0] * 256
    solid = [0] * 256
    for i, (r, ch) in enumerate(cs.combos):
        solid[8 * i] = ATTR.get(ch, 0)
        for j in range(8):
            ad = syms[ts[(i, j)]]
            ts_lo[8 * i + j], ts_hi[8 * i + j] = ad & 255, ad >> 8
    lv = [[8 * cs.cid[(r, cs.trows[r][t])] for t in range(LEVEL_W)] for r in range(NTROW)]
    fr = [0] * 256
    for fi, (name, art) in enumerate(cs.frames):
        ad = BLIT_SYMS['spr_' + name] if fi < BLIT_N else syms['spr_' + name]
        fr[fi], fr[128 + fi] = ad & 255, ad >> 8
    text = bytearray(512)
    for off, t in zip(TEXT_OFF, cs.c['text']):
        text[off:off + 80] = t.ljust(80).encode('ascii')
    block = (page(bs_lo) + page(bs_hi) + page(ts_lo) + page(ts_hi) + page(lv[0] + lv[1]) + page(lv[2] + lv[3])
             + page(lv[4]) + page(solid) + page(cs.obj_page()) + page(fr) + bytes(text))
    assert len(block) == BLOCK_END - BLOCK
    top = SD_OVL + ((max(mem) - SD_OVL) // 512 + 1) * 512      # whole byte columns (sectors)
    image = bytes(mem.get(a, 0) for a in range(SD_OVL, top))
    info = dict(course=cs, used=sum(1 for a in mem), frags_used=state[1], nfrags=len(frags), strips=nstrip[0],
                image=mem)
    return block + image, info


# ---------------------------------------------------------------------------
# the program (x2000 on)
# ---------------------------------------------------------------------------
SD_CODE = 0x2000
CODE_END = 0x4000       # a .PLC ends below x4000 (the DOS)
ENEMY = 0x5400          # RAM: the objects' state (a copy of the OBJ page's x00-x67)
COIN_GOT = 0x5500       # RAM: 1 when medal n is taken


def gen():
    """-> (skyward.asm source, info)"""
    a = Asm()
    a.raw('; skyward.asm - generated by gen_skyward.py, do not edit')
    a.raw(';')
    for ln in __doc__.strip().split('\n')[1:]:
        a.raw(('; ' + ln).rstrip())
    a.raw('')
    a.raw('#include "placard.asm"')
    a.raw('#include "placard_lib.asm"')
    a.raw(ZP)
    a.raw('%-10s = 0x%04X       ; in RAM (the blitter)' % ('draw_sprites', BLIT_SYMS['draw_sprites']))
    consts = dict(MODE_PF=MODE_PF, GRAV=GRAV, JUMPV_LO=(-JUMPV) & 0xFF, JUMPV_HI=((-JUMPV) >> 8) & 0xFF,
                  MAXFALL_HI=MAXFALL >> 8, INV_FRAMES=INV_FRAMES, MAX_SPR=MAX_SPR, GROUND_G=GROUND_G,
                  NROW=NROW, GLIDE=GLIDE, DROWN_G=DROWN_G, ROOK_SAFE=ROOK_SAFE, NCOURSE=NCOURSE, BLOCK_END=BLOCK_END, FID_MEDAL=FID_MEDAL, NPF=NPF,
                  ENEMY=ENEMY, V_POWER=0x70, V_GETA=0x71, V_EMB=0x72, V_EMXL=0x73, V_EMG=0x75, V_EMD=0x76, V_FPREV=0x77,
                  V_EMXH=0x7B, EMBER_LIFE=EMBER_LIFE, BOUNCEV_LO=(-BOUNCEV) & 0xFF, BOUNCEV_HI=((-BOUNCEV) >> 8) & 0xFF,
                  UPV_LO=(-UPV - GRAV) & 0xFF, UPV_HI=((-UPV - GRAV) >> 8) & 0xFF, COIN_GOT=COIN_GOT, COIN_XL=0x80, COIN_XH=0xA8, COIN_G=0xD0)
    for k, v in consts.items():
        a.raw('%-10s = %d' % (k, v))
    for k, v in PAGES.items():
        a.raw('%-10s = 0x%04X' % (k, v))

    def call(target, ret, comment=''):
        a.call(target, ret, comment)

    PUSH_LINK = '''
    ld   [SP], x                ; PUSH_LINK
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   [SP], ac
    dec
    ld   ac, x
    dec
    ld   ac, [SP]
    ld   [LINK_LO], ac
    ld   ac, [x]'''

    # ------------------------------------------------------------ main
    a.org(SD_CODE, 'main')
    a.raw('main:')
    a.g('''
    ld   STACK_TOP, ac
    ld   ac, [SP]''')
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
    ld   3, ac
    ld   ac, [lives]''')
    call('load_course', 'm_lc')
    call('frame_poll', 'm_fp')
    a.g('''
    ld   [FRAME_LO], ac
    ld   ac, [last_frame]''')
    a.jump('frame')

    # ------------------------------------------------------------ frame
    a.sect('frame: wait for vertical blanking, then draw ahead of the beam')
    a.raw('frame:')
    a.g('''
f_wait:''')
    call('frame_poll', 'f_w1')
    a.g('''
    ld   [FRAME_LO], ac
    sub  [last_frame], ac
    bne  f_new
    ld   f_wait >> 8, y
    jmp  f_wait
f_new:
    ld   [FRAME_LO], ac
    ld   ac, [last_frame]
frame_go:
    ld   0x50, y                ; map FF: the strips are in the video RAM
    ld   0xFF, [y,x]            ; (draw_sprites puts MAP_SHADOW back)''')
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
    a.g('''
    ld   [scl], ac              ; course: tile column = (scroll >> 3) & 127,
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
    lvpage = ['LVA', 'LVA', 'LVB', 'LVB', 'LVC']
    for r in range(NTROW):
        idx = '    ld   [gt], x' if r % 2 == 0 else '    ld   [gt], ac\n    add  128, x'
        a.g('''
{lp}
    ld   g_r{r} & 0xFF, ac      ; tile row {r}
    ld   ac, [rl]
    ld   g_r{r} >> 8, ac
    ld   ac, [rh]
{idx}
    ld   {pg} >> 8, y
    ld   [y,x], ac              ; (row, tile) number * 8
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
g_r{r}:'''.format(r=r, lp='g_lp:' if r == 0 else '', idx=idx, pg=lvpage[r]))
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
    call('menu_poll', 'f_mp', '(Esc: back to the DOS)')
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
i_4:
    ld   [R0], ac               ; Y (bit 1): the Ember Pepper
    and  0x02, ac
    beq  i_5
    ld   [inp], ac
    or   8, ac
    ld   ac, [inp]
i_5:''')
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
k_4:
    ld   [KBD_NOW + 7], ac      ; Down (row 6)
    and  0x40, ac
    bne  k_5
    ld   [inp], ac
    or   8, ac
    ld   ac, [inp]
k_5:''')
    call('game', 'f_game')
    call('hud', 'f_hud')
    a.jump('frame')

    # ------------------------------------------------------------ load_course
    a.sect('load_course: read SKYWARD/Cn.LVL (n = course): 6 sectors to BS_LO on, the rest to x6000 on')
    a.raw('load_course:')
    a.g(PUSH_LINK)
    a.g('''
    ld   0x50, y                ; map 07 (the library)
    ld   [MAP_SHADOW], ac
    ld   ac, [y,x]''')
    call('fs_root', 'lc_0')
    a.g('''
    ld   s_dir & 0xFF, ac
    ld   ac, [R0]
    ld   s_dir >> 8, ac
    ld   ac, [R1]''')
    call('fs_open', 'lc_1')
    a.g('''
    ld   [course], ac           ; "Cx.LVL", x = A for the title on
    add  0x41, ac
    ld   s_file >> 8, y
    ld   (s_file + 1) & 0xFF, x
    ld   ac, [y,x]
    ld   s_file & 0xFF, ac
    ld   ac, [R0]
    ld   s_file >> 8, ac
    ld   ac, [R1]''')
    call('fs_open', 'lc_2')
    a.g('''
    beq  lc_3
    ld   0x80, y                ; no file: back to the DOS (dos_back)
    jmp  0x08
lc_3:
    clr  ac
    ld   ac, [R4]
    ld   BS_LO >> 8, ac
    ld   ac, [R5]''')
    a.raw('lc_rd:')
    call('fs_read', 'lc_4')
    a.g('''
    bne  lc_5
    ld   [R5], ac               ; after the tables: the video RAM
    sub  BLOCK_END >> 8, ac
    bne  lc_4a
    ld   0x60, ac
    ld   ac, [R5]
lc_4a:
    ld   lc_rd >> 8, y
    jmp  lc_rd
lc_5:''')
    call('reset_objs', 'lc_6')
    a.g('''
    ld   OBJ >> 8, y            ; the course's header
    ld   0x60, x
    ld   [y,x], ac
    ld   ac, [n_en]
    ld   0x61, x
    ld   [y,x], ac
    ld   ac, [n_med]
    ld   0x62, x
    ld   [y,x], ac
    ld   ac, [goal_lo]
    ld   0x63, x
    ld   [y,x], ac
    ld   ac, [goal_hi]
    ld   0x64, x
    ld   [y,x], ac
    ld   ac, [chk_lo]
    ld   0x67, x
    ld   [y,x], ac
    ld   ac, [chk_hi]
    ld   0x65, x
    ld   [y,x], ac
    ld   ac, [kind]
    ld   0x66, x
    ld   [y,x], ac
    ld   ac, [glider]
    ld   1, ac
    ld   ac, [mode]
    ld   ac, [hud_dirty]
    clr  ac
    ld   ac, [clear_t]
    ld   ac, [facing]
    ld   ac, [sl_n]             ; (the list's routines were the last course's)''')
    a.g('''
    ld   ENEMY >> 8, y          ; the title: no power-up; the feather is a glider
    ld   [course], ac
    bne  lc_p1
    ld   V_POWER, x
    ld   0, [y,x]
    ld   V_GETA, x
    ld   0, [y,x]
lc_p1:
    ld   V_EMB, x
    ld   0, [y,x]
    ld   V_POWER, x
    ld   [y,x], ac
    sub  3, ac
    bne  lc_p2
    ld   1, ac
    ld   ac, [glider]
lc_p2:''')
    call('respawn', 'lc_7')
    a.g('''
    clr  ac
    ld   ac, [inv]
    ld   [chk_lo], ac           ; the camera, for the first frame
    sub  %d, ac
    ld   ac, [scl]
    ld   [chk_hi], ac
    bcc  lc_8
    sub  1, ac
lc_8:
    and  3, ac
    ld   ac, [sch]''' % SCREEN_X)
    for i, (off, row) in enumerate(zip(TEXT_OFF, (0, 2, 3))):
        a.g('''
    clr  ac
    ld   ac, [CUR_COL]
    ld   %d, ac
    ld   ac, [CUR_ROW]
    ld   0x%02X, ac
    ld   ac, [R0]
    ld   0x%02X, ac
    ld   ac, [R1]''' % (row, (PAGES['TEXT'] + off) & 255, (PAGES['TEXT'] + off) >> 8))
        call('con_puts', 'lc_t%d' % i)
    a.g('''
    clr  ac
    ld   ac, [CUR_COL]
    ld   1, ac
    ld   ac, [CUR_ROW]
    ld   s_score & 0xFF, ac
    ld   ac, [R0]
    ld   s_score >> 8, ac
    ld   ac, [R1]''')
    call('con_puts', 'lc_t9')
    call('frame_poll', 'lc_fp')
    a.g('''
    ld   [FRAME_LO], ac
    ld   ac, [last_frame]''')
    a.jump('lib_leave')

    # ------------------------------------------------------------ tile_at
    a.sect('tile_at: AC = 0 when cell ta_g of world byte column ta_hi:ta_lo is not solid')
    a.raw('tile_at:')
    a.g('''
    ld   [ta_g], ac
    sub  GROUND_G, ac
    bcc  ta_0
    clr  ac                     ; above the course: as its top row (the end
ta_0:                           ; walls go all the way up)
    ld   ac, [tmp3]
    sub  80, ac
    bcc  ta_no                  ; below it
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
    ld   ac, [dlo]
    ld   [tmp3], ac             ; tile row = (g - 32) / 16: page LVA + row / 2,
    shr  ac                     ; + 128 for an odd row
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [tmp3]
    and  1, ac
    beq  ta_1
    ld   [dlo], ac
    or   0x80, ac
    ld   ac, [dlo]
ta_1:
    ld   [tmp3], ac
    shr  ac
    add  LVA >> 8, ac
    ld   ac, [dhi]              ; (dhi:dlo: the tile's place in the map)
    ld   ac, y
    ld   [dlo], x
    ld   [y,x], ac
    ld   ac, x
    ld   SOLID >> 8, y
    ld   [y,x], ac
    ld   ac, [tmp3]             ; tmp3 = its type; AC = 1 when it is solid
    and  1, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
ta_no:
    clr  ac
    ld   ac, [tmp3]
    ld   [LINK_HI], y
    jmp  [LINK_LO]''')

    a.g('''
reset_objs:
    clr  ac                     ; the objects from the course's list (OBJ x00-x67)
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
    sub  0x68, ac
    bne  ro_1
    clr  ac                     ; every medal back
    ld   ac, [tmp]
    ld   COIN_GOT >> 8, y
ro_2:
    ld   [tmp], x
    ld   0, [y,x]
    ld   [tmp], ac
    add  1, ac
    ld   ac, [tmp]
    sub  40, ac
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
    ld   INV_FRAMES, ac
    ld   ac, [inv]
    ld   [LINK_HI], y
    jmp  [LINK_LO]''')

    def screen_col(page_y, idx_lo, idx_hi, skip):
        """dlo = (x - scroll + 8) & 1023 for an object whose x low byte is at
        [Y, idx_lo + o_i] and high byte at [Y, idx_hi + o_i]; jump to skip
        when that is not 0-87 (off the screen)"""
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
    a.sect('game: the mode, then movement, objects, sprite list')
    a.raw('game:')
    a.g(PUSH_LINK)
    a.begin()
    a.g('''
    ld   [inp], ac
    and  4, ac
    ld   ac, [jnow]
    ld   [mode], ac
    bne  gm_m1
    ld   gm_play >> 8, y
    jmp  gm_play
gm_m1:
    sub  1, ac
    bne  gm_clr
    ld   [jnow], ac             ; waiting: the jump key, newly down?
    beq  gm_still
    ld   [jprev], ac
    bne  gm_still
    ld   [kind], ac             ; a picture: the next course
    beq  gm_go
    ld   next_course >> 8, y
    jmp  next_course
gm_go:
    clr  ac                     ; a course: play
    ld   ac, [mode]
    ld   76, ac''')
    call('snd_beep', 'gm_gb')
    a.g('''
gm_still:
    clr  ac
    ld   ac, [inp]
    ld   gm_play >> 8, y
    jmp  gm_play
gm_clr:
    ld   [clear_t], ac          ; course clear: count down, then the next one
    sub  1, ac
    ld   ac, [clear_t]
    bne  gm_still
    ld   next_course >> 8, y
    jmp  next_course''')
    a.end()

    a.sect('next_course: course + 1 (after the ending: a new game), load it; leaves game')
    a.g('''
next_course:
    ld   [course], ac
    add  1, ac
    sub  NCOURSE, ac
    bcs  nc_1
    clr  ac                     ; a new game
    ld   ac, [score_lo]
    ld   ac, [score_hi]
    ld   ac, [coins]
    ld   3, ac
    ld   ac, [lives]
    ld   0 - NCOURSE, ac
nc_1:
    add  NCOURSE, ac
    ld   ac, [course]
    ld   4, ac                  ; (the key that got here is still down)
    ld   ac, [jprev]''')
    call('load_course', 'nc_2')
    a.jump('lib_leave')

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
    ld   NPF, ac
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
    ld   [moved], ac            ; free: move one byte column
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
    bra  gm_vert_j
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

    a.sect('game: jumping, gliding and falling')
    a.raw('gm_vert:')
    a.begin()
    a.g('''
    ld   [pyh], ac              ; in an updraft (the cell at Tobi's middle)?
    add  8, ac
    ld   ac, [ta_g]
    ld   [pxl], ac
    add  4, ac
    ld   ac, [ta_lo]
    ld   [pxh], ac
    bcc  gm_u1
    add  1, ac
gm_u1:
    ld   ac, [ta_hi]''')
    call('tile_at', 'gm_u2')
    a.g('''
    ld   [tmp3], ac
    and  8, ac
    beq  gm_u3
    ld   UPV_LO, ac             ; it carries him up
    ld   ac, [vyl]
    ld   UPV_HI, ac
    ld   ac, [vyh]
gm_u3:
    ld   gm_vert2 >> 8, y
    jmp  gm_vert2''')
    a.end()
    a.raw('gm_vert2:')
    a.begin()
    a.g('''
    clr  ac
    ld   ac, [gliding]
    ld   [jnow], ac             ; jump from the ground, on a new key press
    beq  gm_g0
    ld   [jprev], ac
    bne  gm_g0
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
    ld   [glider], ac           ; falling with the glider and the key held:
    beq  gm_ng                  ; no faster than GLIDE
    ld   [jnow], ac
    beq  gm_ng
    ld   [onground], ac
    bne  gm_ng
    ld   1, ac
    ld   ac, [gliding]
    ld   [vyh], ac
    bne  gm_gl
    ld   [vyl], ac
    sub  GLIDE, ac
    bcs  gm_ng
gm_gl:
    clr  ac
    ld   ac, [vyh]
    ld   GLIDE, ac
    ld   ac, [vyl]
gm_ng:
    ld   [vyh], ac
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
    ld   [pyh], ac              ; (vy < 0: the high bytes and the carry)
    bcc  gm_g4
    add  1, ac
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
    ld   ac, [ta_lo]
    bcc  gm_h3c
    ld   [ta_hi], ac
    add  1, ac
    ld   ac, [ta_hi]
gm_h3c:''')
    call('tile_at', 'gm_h3')
    a.g('''
    beq  gm_h4
gm_bump:
    ld   [tmp3], ac             ; a crate?
    and  0x10, ac
    beq  gm_bp0
    ld   gm_crate >> 8, y
    jmp  gm_crate
gm_bp0:
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
    ld   [pyh], ac              ; out of the course: a life
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
    call('tile_at', 'gm_f2')
    a.g('''
    bne  gm_land
    ld   [ta_lo], ac
    add  5, ac
    ld   ac, [ta_lo]
    bcc  gm_f3c
    ld   [ta_hi], ac
    add  1, ac
    ld   ac, [ta_hi]
gm_f3c:''')
    call('tile_at', 'gm_f3')
    a.g('''
    bne  gm_land
    ld   gm_lift >> 8, y
    jmp  gm_lift
gm_land:
    ld   [tmp3], ac             ; thorns or a bounce drum?
    and  6, ac
    beq  gm_ld0
    ld   gm_special >> 8, y
    jmp  gm_special
gm_ld0:
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

    a.sect('game: thorns, bounce drums, crates, lifts, a hit')
    a.begin()
    a.g('''
gm_special:
    ld   [tmp3], ac
    and  4, ac
    bne  gm_bnc
    ld   ENEMY >> 8, y          ; thorns: safe on the geta, and just after a hit
    ld   V_GETA, x
    ld   [y,x], ac
    bne  gm_sp1
    ld   [inv], ac
    bne  gm_sp1
    ld   LINK_LO, x
    ld   gm_obj & 0xFF, [x]
    ld   LINK_HI, x
    ld   gm_obj >> 8, [x]
    ld   hurt >> 8, y
    jmp  hurt
gm_sp1:
    ld   gm_ld0 >> 8, y
    jmp  gm_ld0
gm_bnc:
    ld   [pyh], ac              ; a bounce drum: up from its top
    add  16 - GROUND_G, ac
    and  0xF0, ac
    add  GROUND_G - 16, ac
    ld   ac, [pyh]
    clr  ac
    ld   ac, [pyl]
    ld   ac, [onground]
    ld   BOUNCEV_LO, ac
    ld   ac, [vyl]
    ld   BOUNCEV_HI, ac
    ld   ac, [vyh]
    ld   LINK_LO, x
    ld   gm_obj & 0xFF, [x]
    ld   LINK_HI, x
    ld   gm_obj >> 8, [x]
    ld   80, ac
    ld   snd_beep >> 8, y
    jmp  snd_beep''')
    a.end()
    a.begin()
    a.g('''
gm_crate:
    ld   [ta_g], ac             ; the crate becomes a used one (X of this tile
    sub  GROUND_G, ac           ; row, from the course's header)
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    add  0x68, x
    ld   OBJ >> 8, y
    ld   [y,x], ac
    ld   [dhi], y
    ld   [dlo], x
    ld   ac, [y,x]
    ld   1, ac
    ld   ac, [hud_dirty]
    ld   ENEMY >> 8, y
    ld   [tmp3], ac             ; what was in it: type / 32
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    sub  3, ac
    bne  gm_cr1
    ld   V_GETA, x              ; the Tengu Geta
    ld   1, [y,x]
    bra  gm_cr3
gm_cr1:
    add  4, ac                  ; 1 Sky Berry, 2 Ember Pepper, 3 Glide Feather
    ld   V_POWER, x
    ld   ac, [y,x]
    ld   ac, [tmp]
    ld   0x66, x                ; the glider: the course's, or the feather's
    ld   [y,x], ac
    ld   ac, [glider]
    ld   [tmp], ac
    sub  3, ac
    bne  gm_cr3
    ld   1, ac
    ld   ac, [glider]
gm_cr3:
    ld   LINK_LO, x
    ld   gm_bp0 & 0xFF, [x]
    ld   LINK_HI, x
    ld   gm_bp0 >> 8, [x]
    ld   92, ac
    ld   snd_beep >> 8, y
    jmp  snd_beep''')
    a.end()
    a.begin()
    a.g('''
hurt:
    ld   ENEMY >> 8, y          ; the geta takes a hit, or the power-up does,
    ld   V_GETA, x              ; or a life is lost; returns via LINK
    ld   [y,x], ac
    beq  hr_1
    ld   0, [y,x]
    bra  hr_2
hr_1:
    ld   V_POWER, x
    ld   [y,x], ac
    bne  hr_p
    ld   lose_life >> 8, y
    jmp  lose_life
hr_p:
    ld   0, [y,x]
    ld   0x66, x
    ld   [y,x], ac
    ld   ac, [glider]
hr_2:
    ld   INV_FRAMES, ac
    ld   ac, [inv]
    ld   1, ac
    ld   ac, [hud_dirty]
    ld   40, ac
    ld   snd_beep >> 8, y
    jmp  snd_beep''')
    a.end()
    a.begin()
    a.g('''
gm_lift:
    clr  ac                     ; not on a tile: on a lift?
    ld   ac, [onground]
    ld   ac, [o_i]
gl_1:
    ld   [o_i], ac
    sub  [n_en], ac
    bne  gl_2
    ld   gm_obj >> 8, y
    jmp  gm_obj
gl_2:
    ld   ENEMY >> 8, y
    ld   [o_i], ac
    add  0x48, x
    ld   [y,x], ac
    and  0x10, ac
    beq  gl_n
    ld   [o_i], ac              ; its x + 6 - px in 0..12
    add  8, x
    ld   [y,x], ac
    ld   ac, [tmp2]
    ld   [o_i], x
    ld   [y,x], ac
    add  6, ac
    ld   ac, [tmp]
    ld   [tmp2], ac
    bcc  gl_3
    add  1, ac
gl_3:
    ld   ac, [tmp2]
    ld   [tmp], ac
    sub  [pxl], ac
    ld   ac, [tmp]
    ld   [tmp2], ac
    bcc  gl_4
    sub  1, ac
gl_4:
    sub  [pxh], ac
    and  3, ac
    bne  gl_n
    ld   [tmp], ac
    sub  13, ac
    bcc  gl_n
    ld   [o_i], ac              ; feet in its top 8 cells
    add  0x10, x
    ld   [y,x], ac
    ld   ac, [tmp2]
    ld   [pyh], ac
    add  16, ac
    sub  [tmp2], ac
    sub  8, ac
    bcc  gl_n
    ld   gl_on >> 8, y
    jmp  gl_on
gl_n:
    ld   [o_i], ac
    add  1, ac
    ld   ac, [o_i]
    bra  gl_1''')
    a.end()
    a.begin()
    a.g('''
gl_on:
    ld   [tmp2], ac             ; stand on it, and ride along when it moves
    sub  16, ac
    ld   ac, [pyh]
    clr  ac
    ld   ac, [pyl]
    ld   ac, [vyl]
    ld   ac, [vyh]
    ld   1, ac
    ld   ac, [onground]
    ld   [FRAME_LO], ac
    and  1, ac
    beq  gl_d
    ld   ENEMY >> 8, y
    ld   [o_i], ac
    add  0x18, x
    ld   [y,x], ac
    bne  gl_l
    ld   [pxl], ac
    add  1, ac
    ld   ac, [pxl]
    bne  gl_d
    ld   [pxh], ac
    add  1, ac
    and  3, ac
    ld   ac, [pxh]
    bra  gl_d
gl_l:
    ld   [pxl], ac
    sub  1, ac
    ld   ac, [pxl]
    xor  0xFF, ac
    bne  gl_d
    ld   [pxh], ac
    sub  1, ac
    and  3, ac
    ld   ac, [pxh]
gl_d:
    ld   gm_obj >> 8, y
    jmp  gm_obj''')
    a.end()

    a.sect('lose_life: a life (none left: the title again), noise, respawn; returns via LINK')
    a.g('''
lose_life:
    ld   [LINK_LO], ac          ; keep the return address over snd_noise
    ld   ac, [ll_lo]
    ld   [LINK_HI], ac
    ld   ac, [ll_hi]
    ld   1, ac
    ld   ac, [hud_dirty]
    ld   8, ac                  ; noise: rumble, 30 frames, fading
    ld   ac, [R0]
    ld   30, ac
    ld   ac, [R2]
    ld   3, ac
    ld   ac, [R3]
    ld   90, ac''')
    call('snd_noise', 'll_2')
    a.g('''
    ld   ENEMY >> 8, y          ; the power-up and the geta go with it
    ld   V_POWER, x
    ld   0, [y,x]
    ld   V_GETA, x
    ld   0, [y,x]
    ld   0x66, x
    ld   [y,x], ac
    ld   ac, [glider]
    ld   [lives], ac
    sub  1, ac
    ld   ac, [lives]
    bne  ll_1
    ld   NCOURSE - 1, ac        ; game over: the title, a new game
    ld   ac, [course]
    ld   next_course >> 8, y
    jmp  next_course
ll_1:
    ld   [ll_lo], ac
    ld   ac, [LINK_LO]
    ld   [ll_hi], ac
    ld   ac, [LINK_HI]
    ld   respawn >> 8, y
    jmp  respawn''')

    # sprite list append: tmp = frame id, dlo = SL_C, tmp3 = SL_G (all kept)
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
    ld   FR >> 8, y
    ld   [y,x], ac
    ld   ac, [tmp2]
    ld   [sl_n], ac
    add  SL_LO, x
    ld   [tmp2], ac
    ld   ac, [x]
    ld   [tmp], ac
    add  128, x
    ld   FR >> 8, y
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

    a.sect('game: camera, the goal, medals')
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
    ld   [pxl], ac              ; camera: scroll = px - %d (the player at
    sub  %d, ac                 ; that screen byte column)
    ld   ac, [scl]
    ld   [pxh], ac
    bcc  go_a3
    sub  1, ac
go_a3:
    and  3, ac
    ld   ac, [sch]
    clr  ac
    ld   ac, [sl_n]
    ld   ac, [o_i]''' % (SCREEN_X, SCREEN_X))
    a.g('''
    ld   [mode], ac             ; playing, and at the goal: course clear
    bne  go_ng
    ld   [pxh], ac
    sub  [goal_hi], ac
    bcs  go_ng
    bne  go_goal
    ld   [pxl], ac
    sub  [goal_lo], ac
    bcs  go_ng
    bra  go_goal
go_ng:
    ld   go_c >> 8, y
    jmp  go_c
go_goal:
    ld   2, ac
    ld   ac, [mode]
    ld   90, ac
    ld   ac, [clear_t]
    ld   LINK_LO, x
    ld   go_c & 0xFF, [x]
    ld   LINK_HI, x
    ld   go_c >> 8, [x]
    ld   84, ac
    ld   snd_beep >> 8, y
    jmp  snd_beep''')
    a.g('''
go_c:
    ld   [o_i], ac              ; medal o_i (none left: the objects)
    sub  [n_med], ac
    bne  go_c00
    ld   go_cd >> 8, y
    jmp  go_cd
go_c00:
    ld   [o_i], x               ; taken?
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
    ld   [FRAME_LO], ac         ; frame: medal 1-4, a step every 8 frames
    shr  ac
    shr  ac
    shr  ac
    and  3, ac
    add  FID_MEDAL, ac
    ld   ac, [tmp]''')
    call('sl_add', 'go_ca1')
    a.g('''
go_cn:
    ld   [o_i], ac
    add  1, ac
    ld   ac, [o_i]
    ld   go_c >> 8, y
    jmp  go_c
go_cd:
    ld   gm_emb >> 8, y
    jmp  gm_emb''')

    a.sect('game: the Ember Pepper (Down or pad Y throws an ember; one at a time)')
    a.begin()
    a.g('''
gm_emb:
    ld   ENEMY >> 8, y
    ld   [inp], ac
    and  8, ac
    ld   ac, [tmp]
    ld   V_FPREV, x
    ld   [y,x], ac
    ld   ac, [tmp2]
    ld   [tmp], ac
    ld   ac, [y,x]
    beq  ge_mv                  ; the key newly down, playing, with the pepper,
    ld   [tmp2], ac             ; and no ember in the air
    bne  ge_mv
    ld   [mode], ac
    bne  ge_mv
    ld   V_POWER, x
    ld   [y,x], ac
    sub  2, ac
    bne  ge_mv
    ld   V_EMB, x
    ld   [y,x], ac
    bne  ge_mv
    ld   EMBER_LIFE, [y,x]
    ld   V_EMXL, x
    ld   [pxl], ac
    ld   ac, [y,x]
    ld   V_EMXH, x
    ld   [pxh], ac
    ld   ac, [y,x]
    ld   V_EMG, x
    ld   [pyh], ac
    ld   ac, [y,x]
    ld   V_EMD, x
    ld   [facing], ac
    ld   ac, [y,x]
    ld   96, ac''')
    call('snd_beep', 'ge_b')
    a.g('''
ge_mv:
    ld   ENEMY >> 8, y
    ld   V_EMB, x
    ld   [y,x], ac
    bne  ge_1
ge_out:
    ld   ge_x >> 8, y
    jmp  ge_x
ge_1:
    sub  1, ac
    ld   ac, [y,x]
    ld   V_EMD, x
    ld   [y,x], ac
    bne  ge_l
    ld   V_EMXL, x              ; right: two byte columns
    ld   [y,x], ac
    add  2, ac
    ld   ac, [y,x]
    bcc  ge_d
    ld   V_EMXH, x
    ld   [y,x], ac
    add  1, ac
    and  3, ac
    ld   ac, [y,x]
    bra  ge_d
ge_l:
    ld   V_EMXL, x
    ld   [y,x], ac
    sub  2, ac
    ld   ac, [y,x]
    bcc  ge_d
    ld   V_EMXH, x
    ld   [y,x], ac
    sub  1, ac
    and  3, ac
    ld   ac, [y,x]
ge_d:
    ld   ge_w >> 8, y
    jmp  ge_w''')
    a.end()
    a.begin()
    a.g('''
ge_w:
    ld   ENEMY >> 8, y          ; a wall puts it out
    ld   V_EMG, x
    ld   [y,x], ac
    add  8, ac
    ld   ac, [ta_g]
    ld   V_EMXH, x
    ld   [y,x], ac
    ld   ac, [ta_hi]
    ld   V_EMXL, x
    ld   [y,x], ac
    add  4, ac
    ld   ac, [ta_lo]
    bcc  ge_w1
    ld   [ta_hi], ac
    add  1, ac
    ld   ac, [ta_hi]
ge_w1:''')
    call('tile_at', 'ge_w2')
    a.g('''
    beq  ge_dr
    ld   ENEMY >> 8, y
    ld   V_EMB, x
    ld   0, [y,x]
    ld   ge_x >> 8, y
    jmp  ge_x
ge_dr:
    ld   V_EMXL, ac
    ld   ac, [o_i]''')
    a.g(screen_col('ENEMY', '0', '8', 'ge_x'))
    a.g('''
    ld   ENEMY >> 8, y
    ld   V_EMG, x
    ld   [y,x], ac
    add  32, ac
    ld   ac, [tmp3]
    ld   OBJ >> 8, y
    ld   0x6E, x
    ld   [y,x], ac
    ld   ac, [tmp]''')
    call('sl_add', 'ge_s')
    a.g('''
    ld   ge_x >> 8, y
    jmp  ge_x''')
    a.end()
    a.g('''
ge_x:
    clr  ac
    ld   ac, [o_i]
    ld   go_e >> 8, y
    jmp  go_e''')

    a.begin()
    a.g('''
go_emb:
    ld   ENEMY >> 8, y          ; an ember in the air, and this one can be
    ld   V_EMB, x               ; knocked out: its x - the ember's in -6..6,
    ld   [y,x], ac              ; its top cell - the ember's in -12..12
    beq  gb_no
    ld   [ekind], ac
    and  0x13, ac
    bne  gb_no
    ld   V_EMXL, x
    ld   [y,x], ac
    ld   ac, [tmp]
    ld   [o_i], x
    ld   [y,x], ac
    sub  [tmp], ac
    add  6, ac
    sub  13, ac
    bcc  gb_no
    ld   V_EMG, x
    ld   [y,x], ac
    ld   ac, [tmp]
    ld   [tmp3], ac
    sub  20, ac
    sub  [tmp], ac
    sub  25, ac
    bcc  gb_no
    ld   V_EMB, x
    ld   0, [y,x]
    ld   [o_i], ac
    add  0x40, x
    ld   0, [y,x]
    ld   1, ac
    ld   ac, [hud_dirty]
    ld   [score_lo], ac
    add  100, ac
    ld   ac, [score_lo]
    bcc  gb_s
    ld   [score_hi], ac
    add  1, ac
    ld   ac, [score_hi]
gb_s:
    ld   go_h1 >> 8, y
    jmp  go_h1
gb_no:
    ld   go_ect >> 8, y
    jmp  go_ect''')
    a.end()

    a.sect('game: the objects (Bumblers, Buzzbees, Baron Rook, pictures)')
    a.raw('go_e:')
    a.g('''
    ld   [o_i], ac
    sub  [n_en], ac
    bne  go_e00
    ld   go_pl >> 8, y
    jmp  go_pl
go_e00:
    ld   ENEMY >> 8, y          ; alive?
    ld   [o_i], ac
    add  0x40, x
    ld   [y,x], ac
    bne  go_e1
    ld   go_en >> 8, y
    jmp  go_en
go_e1:
    ld   [o_i], ac
    add  0x48, x
    ld   [y,x], ac
    ld   ac, [ekind]
    and  0x20, ac               ; a Shellby: walking, or a shell
    beq  go_e1n
    ld   go_shl >> 8, y
    jmp  go_shl
go_e1n:
    ld   ENEMY >> 8, y
    ld   [ekind], ac
    and  0x0A, ac               ; a picture and a Snapjaw stay where they are
    bne  go_e5
    ld   [ekind], ac            ; a byte every other frame (x40: every frame)
    and  0x40, ac
    bne  go_emv
    ld   [FRAME_LO], ac
    and  1, ac
    beq  go_e5
go_emv:
    ld   ENEMY >> 8, y
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
    a.g('''
    ld   [ekind], ac            ; a Snapjaw is down in its stump half the time
    and  8, ac
    beq  go_e6
    ld   [FRAME_LO], ac
    and  0x40, ac
    bne  go_e6
    ld   go_en >> 8, y
    jmp  go_en
go_e6:''')
    a.end()
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
    ld   go_emb >> 8, y
    jmp  go_emb
go_ect:
    ld   [mode], ac             ; only while playing, not just after a lost
    bne  go_eaj                ; life, and not a picture
    ld   [inv], ac
    bne  go_eaj
    ld   [ekind], ac            ; (nor a lift)
    and  0x12, ac
    bne  go_eaj
    ld   [ekind], ac
    and  1, ac
    bne  go_ebig
    ld   [dlo], ac              ; touching the player?  ex - px in -6..6
    sub  32, ac
    sub  13, ac
    bcc  go_eaj
    ld   [tmp2], ac             ; eg - pyh in -14..14
    add  14, ac
    sub  29, ac
    bcc  go_eaj
    ld   go_hit >> 8, y
    jmp  go_hit
go_ebig:
    ld   [dlo], ac              ; Rook, 32 x 32: ex - px in -14..5
    sub  24, ac
    sub  20, ac
    bcc  go_eaj
    ld   [tmp2], ac             ; eg - pyh in -30..14
    add  30, ac
    sub  45, ac
    bcc  go_eaj
    ld   go_hit >> 8, y
    jmp  go_hit
go_eaj:
    ld   go_eadd >> 8, y
    jmp  go_eadd''')
    a.end()
    a.begin()
    a.g('''
go_eadd:
    ld   ENEMY >> 8, y          ; frame: the object's first, + 1 every 16 frames
    ld   [o_i], ac
    add  0x50, x
    ld   [y,x], ac
    ld   ac, [tmp]
    ld   [FRAME_LO], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    and  1, ac
    ld   ac, [tmp2]
    ld   [ekind], ac            ; a Shellby in its shell: its third frame
    and  0x20, ac
    beq  go_ea0
    ld   [o_i], ac
    add  0x58, x
    ld   [y,x], ac
    sub  3, ac
    beq  go_ea0
    ld   2, ac
    ld   ac, [tmp2]
go_ea0:
    ld   [ekind], ac
    and  1, ac
    bne  go_e4p
    ld   [tmp], ac
    add  [tmp2], ac
    ld   ac, [tmp]''')
    call('sl_add', 'go_ea1')
    a.g('''
    ld   go_en >> 8, y
    jmp  go_en
go_e4p:
    ld   [tmp2], ac             ; 32 x 32: four pieces, + 4 for the other frame
    shl
    shl
    add  [tmp], ac
    ld   ac, [tmp]''')
    call('sl_add', 'go_eb1')
    a.g('''
    ld   [tmp], ac
    add  1, ac
    ld   ac, [tmp]
    ld   [dlo], ac
    add  8, ac
    ld   ac, [dlo]''')
    call('sl_add', 'go_eb2')
    a.g('''
    ld   [tmp], ac
    add  1, ac
    ld   ac, [tmp]
    ld   [dlo], ac
    sub  8, ac
    ld   ac, [dlo]
    ld   [tmp3], ac
    add  16, ac
    ld   ac, [tmp3]''')
    call('sl_add', 'go_eb3')
    a.g('''
    ld   [tmp], ac
    add  1, ac
    ld   ac, [tmp]
    ld   [dlo], ac
    add  8, ac
    ld   ac, [dlo]''')
    call('sl_add', 'go_eb4')
    a.g('''
    ld   go_en >> 8, y
    jmp  go_en''')
    a.end()
    a.g('''
go_en:
    ld   [o_i], ac
    add  1, ac
    ld   ac, [o_i]
    ld   go_e >> 8, y
    jmp  go_e''')

    a.sect('game: Shellby (x58 + n: 3 walking, 2 a shell at rest, 1 a shell sliding)')
    a.begin()
    a.g('''
go_shl:
    ld   ENEMY >> 8, y
    ld   [o_i], ac
    add  0x58, x
    ld   [y,x], ac
    sub  2, ac
    bne  gs_1
    ld   go_e5 >> 8, y          ; at rest
    jmp  go_e5
gs_1:
    sub  1, ac
    bne  gs_2
    ld   go_e1n >> 8, y         ; walking, as a Bumbler does
    jmp  go_e1n
gs_2:
    ld   [o_i], x               ; sliding: at either end of its run it is gone
    ld   [y,x], ac
    ld   ac, [tmp]
    ld   [o_i], ac
    add  8, x
    ld   [y,x], ac
    ld   ac, [tmp2]
    ld   [o_i], ac
    add  0x20, x
    ld   [y,x], ac
    sub  [tmp], ac
    bne  gs_3
    ld   [o_i], ac
    add  0x28, x
    ld   [y,x], ac
    sub  [tmp2], ac
    beq  gs_die
gs_3:
    ld   [o_i], ac
    add  0x30, x
    ld   [y,x], ac
    sub  [tmp], ac
    bne  gs_4
    ld   [o_i], ac
    add  0x38, x
    ld   [y,x], ac
    sub  [tmp2], ac
    beq  gs_die
gs_4:
    ld   [o_i], ac
    add  0x10, x
    ld   [y,x], ac
    ld   ac, [sy]
    clr  ac
    ld   ac, [sc]
    ld   gk_1 >> 8, y
    jmp  gk_1
gs_die:
    ld   [o_i], ac
    add  0x40, x
    ld   0, [y,x]
    ld   go_en >> 8, y
    jmp  go_en''')
    a.end()
    a.begin()
    a.g('''
gk_1:
    ld   [sc], ac               ; it knocks out what it runs into: object sc,
    sub  [n_en], ac             ; on its level, x + 6 - its x in 0..12
    bne  gk_2
    ld   go_emv >> 8, y
    jmp  go_emv
gk_2:
    ld   ENEMY >> 8, y
    ld   [sc], ac
    sub  [o_i], ac
    beq  gk_n
    ld   [sc], ac
    add  0x40, x
    ld   [y,x], ac
    beq  gk_n
    ld   [sc], ac
    add  0x48, x
    ld   [y,x], ac
    and  0x13, ac
    bne  gk_n
    ld   [sc], ac
    add  0x10, x
    ld   [y,x], ac
    sub  [sy], ac
    bne  gk_n
    ld   [sc], ac
    add  8, x
    ld   [y,x], ac
    ld   ac, [dhi]
    ld   [sc], x
    ld   [y,x], ac
    add  6, ac
    ld   ac, [dlo]
    ld   [dhi], ac
    bcc  gk_3
    add  1, ac
gk_3:
    ld   ac, [dhi]
    ld   [dlo], ac
    sub  [tmp], ac
    ld   ac, [dlo]
    ld   [dhi], ac
    bcc  gk_4
    sub  1, ac
gk_4:
    sub  [tmp2], ac
    and  3, ac
    bne  gk_n
    ld   [dlo], ac
    sub  13, ac
    bcc  gk_n
    ld   [sc], ac
    add  0x40, x
    ld   0, [y,x]
    ld   1, ac
    ld   ac, [hud_dirty]
    ld   [score_lo], ac
    add  100, ac
    ld   ac, [score_lo]
    bcc  gk_n
    ld   [score_hi], ac
    add  1, ac
    ld   ac, [score_hi]
gk_n:
    ld   [sc], ac
    add  1, ac
    ld   ac, [sc]
    bra  gk_1''')
    a.end()
    a.begin()
    a.g('''
go_shit:
    ld   ENEMY >> 8, y          ; Shellby and the player touch
    ld   [o_i], ac
    add  0x58, x
    ld   [y,x], ac
    sub  2, ac
    bne  gh_1
    ld   1, [y,x]               ; a shell at rest: it slides away from him
    ld   [o_i], ac
    add  0x18, x
    ld   0, [y,x]
    ld   [dlo], ac
    sub  38, ac
    bcc  gh_k
    ld   1, [y,x]
gh_k:
    ld   ROOK_SAFE, ac
    ld   ac, [inv]
    ld   66, ac
    bra  gh_b
gh_1:
    ld   [vyh], ac              ; walking or sliding: landed on, it stops as a
    blt  gh_hurt                ; shell; any other way it is a hit
    ld   [tmp2], ac
    sub  8, ac
    blt  gh_hurt
    ld   [o_i], ac
    add  0x58, x
    ld   2, [y,x]
    ld   0xFD, ac
    ld   ac, [vyh]
    clr  ac
    ld   ac, [vyl]
    ld   60, ac
gh_b:
    ld   LINK_LO, x
    ld   go_eadd & 0xFF, [x]
    ld   LINK_HI, x
    ld   go_eadd >> 8, [x]
    ld   snd_beep >> 8, y
    jmp  snd_beep
gh_hurt:
    ld   LINK_LO, x
    ld   go_eadd & 0xFF, [x]
    ld   LINK_HI, x
    ld   go_eadd >> 8, [x]
    ld   hurt >> 8, y
    jmp  hurt''')
    a.end()

    a.sect('game: an object touches the player; the player into the list')
    a.begin()
    a.g('''
go_hit:
    ld   [ekind], ac
    and  0x20, ac
    beq  go_h0
    ld   go_shit >> 8, y
    jmp  go_shit
go_h0:
    ld   [ekind], ac            ; spiked: only the geta can land on it
    and  4, ac
    beq  go_hs
    ld   ENEMY >> 8, y
    ld   V_GETA, x
    ld   [y,x], ac
    beq  go_hurt
go_hs:
    ld   [vyh], ac              ; falling and feet in its top half: landed on it
    blt  go_hurt
    ld   [tmp2], ac             ; eg - pyh >= 8
    sub  8, ac
    blt  go_hurt
    ld   0xFD, ac               ; bounce up
    ld   ac, [vyh]
    clr  ac
    ld   ac, [vyl]
    ld   1, ac
    ld   ac, [hud_dirty]
    ld   ENEMY >> 8, y
    ld   [ekind], ac
    and  1, ac
    beq  go_dead
    ld   [o_i], ac              ; Rook and Captain Squall: three times
    add  0x58, x
    ld   [y,x], ac
    sub  1, ac
    ld   ac, [y,x]
    beq  go_rook
    ld   ROOK_SAFE, ac          ; (safe while bouncing off him)
    ld   ac, [inv]
    ld   LINK_LO, x
    ld   go_eadd & 0xFF, [x]
    ld   LINK_HI, x
    ld   go_eadd >> 8, [x]
    ld   48, ac
    ld   snd_beep >> 8, y
    jmp  snd_beep
go_rook:
    ld   2, ac                  ; beaten: + 1000, the course is clear
    ld   ac, [mode]
    ld   150, ac
    ld   ac, [clear_t]
    ld   [score_lo], ac
    add  132, ac                ; (1000 - 100 = x384)
    ld   ac, [score_lo]
    ld   [score_hi], ac
    bcc  go_rk1
    add  1, ac
go_rk1:
    add  3, ac
    ld   ac, [score_hi]
    ld   ENEMY >> 8, y
go_dead:
    ld   [o_i], ac
    add  0x40, x
    ld   0, [y,x]
    ld   [score_lo], ac         ; +100
    add  100, ac
    ld   ac, [score_lo]
    bcc  go_h1
    ld   [score_hi], ac
    add  1, ac
    ld   ac, [score_hi]
go_h1:
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
    ld   hurt >> 8, y
    jmp  hurt''')
    a.end()
    a.begin()
    a.g('''
go_pl:
    ld   [inv], ac              ; the player last (blinks while safe)
    and  4, ac
    bne  go_done
    ld   %d, ac                 ; the screen byte column + 8
    ld   ac, [dlo]
    ld   [pyh], ac
    add  32, ac
    ld   ac, [tmp3]
    ld   [onground], ac         ; frame: glide, jump, run 1-3, stand
    bne  go_p1
    ld   4, ac
    ld   ac, [tmp]
    ld   [gliding], ac
    beq  go_p2
    ld   5, ac
    bra  go_p3
go_p2:
    ld   [tmp], ac
    bra  go_p3
go_p1:
    ld   [moved], ac
    beq  go_p3
    ld   [anim], ac             ; run: 1, 2, 3, 2 a step every 4 frames
    shr  ac
    shr  ac
    and  3, ac
    add  RUNSEQ & 0xFF, x
    ld   RUNSEQ >> 8, y
    ld   [y,x], ac
go_p3:
    add  [facing], ac
    ld   ac, [tmp]''' % (SCREEN_X + 8))
    call('sl_add', 'go_p4')
    a.g('''
    ld   ENEMY >> 8, y          ; the geta under his feet
    ld   V_GETA, x
    ld   [y,x], ac
    beq  go_done
    ld   OBJ >> 8, y
    ld   0x6D, x
    ld   [y,x], ac
    ld   ac, [tmp]''')
    call('sl_add', 'go_p5')
    a.g('''
go_done:
    ld   [jnow], ac
    ld   ac, [jprev]
    ld   lib_leave >> 8, y
    jmp  lib_leave''')
    a.end()

    # ------------------------------------------------------------ hud
    a.sect('hud: the score line when it changed')
    a.raw('hud:')
    a.g(PUSH_LINK)
    a.g('''
    ld   [hud_dirty], ac
    bne  hu_s
    ld   lib_leave >> 8, y
    jmp  lib_leave
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
    ld   s_sp & 0xFF, ac
    ld   ac, [R0]''')
    call('con_puts', 'hu_2')
    a.g('''
    ld   22, ac                 ; medals at column 22
    ld   ac, [CUR_COL]
    ld   [coins], ac''')
    call('con_dec8', 'hu_3')
    a.g('''
    ld   s_sp >> 8, ac
    ld   ac, [R1]
    ld   s_sp & 0xFF, ac
    ld   ac, [R0]''')
    call('con_puts', 'hu_4')
    a.g('''
    ld   37, ac                 ; lives at column 37
    ld   ac, [CUR_COL]
    ld   [lives], ac''')
    call('con_dec8', 'hu_5')
    a.g('''
    ld   45, ac                 ; the power-up at column 45, the geta at 54
    ld   ac, [CUR_COL]
    ld   ENEMY >> 8, y
    ld   V_POWER, x
    ld   [y,x], ac
    shl
    shl
    shl
    add  s_pow & 0xFF, ac
    ld   ac, [R0]
    ld   s_pow >> 8, ac
    ld   ac, [R1]''')
    call('con_puts', 'hu_6')
    a.g('''
    ld   54, ac
    ld   ac, [CUR_COL]
    ld   ENEMY >> 8, y
    ld   V_GETA, x
    ld   [y,x], ac
    shl
    shl
    shl
    add  s_get & 0xFF, ac
    ld   ac, [R0]
    ld   s_get >> 8, ac
    ld   ac, [R1]''')
    call('con_puts', 'hu_7')
    a.jump('lib_leave')

    # ------------------------------------------------------------ text
    def txt(label, text):
        a.raw('%-8s #d "%s", 0x00' % (label + ':', text))
        a.addr += len(text) + 1

    a.sect('text and tables', align=True)
    txt('s_score', "SCORE 0        MEDALS 0        TOBI  3")
    txt('s_sp', "  ")
    txt('s_dir', "SKYWARD")
    txt('s_file', "CA.LVL")
    for i, t in enumerate(("       ", "BERRY  ", "PEPPER ", "FEATHER")):
        txt('s_pow' if i == 0 else 's_pow%d' % i, t)
    for i, t in enumerate(("       ", "GETA   ")):
        txt('s_get' if i == 0 else 's_get%d' % i, t)
    a.raw('RUNSEQ:  #d8 1, 2, 3, 2')
    a.addr += 4
    assert a.addr <= CODE_END, 'program past x%04X: %04X' % (CODE_END, a.addr)
    return '\n'.join(a.out) + '\n', dict(end=a.addr)


def sd_files():
    """-> (SKYWARD.PLC, {'SKYWARD/Cn.LVL': bytes}, symbols, info)"""
    import gen_plc
    src, info = gen()
    mem, syms, _ = ps.assemble(src, HERE)
    lib, _, _ = ps.assemble(open(os.path.join(HERE, 'rom_lib.asm')).read(), HERE)
    own = gen_plc.own_bytes(mem, lib)
    body = dict(BLIT_MEM)
    for ad, v in own.items():
        assert SD_CODE <= ad < CODE_END, 'SKYWARD.PLC: a byte at x%04X' % ad
        body[ad] = v
    top = max(body) + 1
    data = bytes(body.get(ad, 0) for ad in range(0x0100, top))
    plc = gen_plc.header(0, 0x0100, len(data), syms['main']) + data
    files = {}
    infos = []
    for n in range(NCOURSE):
        files['SKYWARD/C%s.LVL' % chr(65 + n)], ci = course_file(n)
        infos.append(ci)
    info['courses'] = infos
    info['src'] = src
    return plc, files, syms, info


def preview(outdir):
    from PIL import Image
    os.makedirs(outdir, exist_ok=True)
    for n in range(NCOURSE):
        cs = Course(n)
        shots = []
        for scroll in range(0, WRAP, NCOL):
            mem = bytearray(65536)
            for ad, v in cs.background(scroll).items():
                mem[ad] = v
            for g in range(NROW):
                mem[0x5A20 + 32 + 4 * g: 0x5A20 + 36 + 4 * g] = bytes([MODE_PF] * 4)
            spr = []
            for o in cs.objs:
                c = (o['x'] - scroll) % WRAP + 8
                if c < 88:
                    base = cs.fid0[o['ch']]
                    if KIND[o['ch']] in (1, 3):
                        spr += [(base + i, c + dx, o['g'] + 32 + dy)
                                for i, (dx, dy) in enumerate(((0, 0), (8, 0), (0, 16), (8, 16)))]
                    else:
                        spr.append((base, c, o['g'] + 32))
            for x, g in cs.medals:
                c = (x - scroll) % WRAP + 8
                if c < 88:
                    spr.append((FID_MEDAL, c, g + 32))
            if scroll <= cs.start < scroll + NCOL - 8:
                spr.append((0, cs.start - scroll + 8, 32 + GROUND_G + 48))
            draw_sprites_model(mem, spr, cs.frames)
            path = os.path.join(outdir, '_t.png')
            ps.render(mem, path)
            shots.append(Image.open(path).convert('RGB').crop((0, 32, 640, 480)))
            os.remove(path)
        strip = Image.new('RGB', (640 * len(shots), 448))
        for i, im in enumerate(shots):
            strip.paste(im, (640 * i, 0))
        strip = strip.resize((strip.width // 2, strip.height // 2), Image.NEAREST)
        half = strip.width // 2 + 160
        out = Image.new('RGB', (half, strip.height * 2 + 8), (40, 40, 40))
        out.paste(strip.crop((0, 0, half, strip.height)), (0, 0))
        out.paste(strip.crop((strip.width - half, 0, strip.width, strip.height)), (0, strip.height + 8))
        out.save(os.path.join(outdir, 'course%d_%s.png' % (n, cs.c['name'])))


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('-o', default=os.path.join(HERE, 'skyward.asm'))
    ap.add_argument('--sdcard', default=os.path.join(HERE, '..', '..', 'sdcard'))
    ap.add_argument('--preview', help='a folder for pictures of every course')
    args = ap.parse_args(argv)
    plc, files, syms, info = sd_files()
    open(args.o, 'w', newline='\n').write(info['src'])
    open(os.path.join(args.sdcard, 'SKYWARD.PLC'), 'wb').write(plc)
    for name, data in files.items():
        path = os.path.join(args.sdcard, *name.split('/'))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, 'wb').write(data)
    print('wrote %s, SKYWARD.PLC (%d bytes: %d of %d frames in the low RAM to x%04X, code to x%04X)'
          % (args.o, len(plc), BLIT_N, len(COMMON), max(BLIT_MEM), info['end']))
    for n, ci in enumerate(info['courses']):
        print('  SKYWARD/C%s.LVL %-7s %d bytes of strips and sprites in %d of %d stretches'
              % (chr(65 + n), ci['course'].c['name'], ci['used'], ci['frags_used'] + 1, ci['nfrags']))
    if args.preview:
        preview(args.preview)
        print('wrote the course pictures to', args.preview)


if __name__ == '__main__':
    main(sys.argv[1:])

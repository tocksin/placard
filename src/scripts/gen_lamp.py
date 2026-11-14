#!/usr/bin/env python3
"""
gen_lamp.py - generate LAMPLIGHTER for the Placard, an exploration
platform game on the SD card (a library program in the RAM)

    python3 gen_lamp.py                 writes lamp.asm next to this script,
                                        ../../sdcard/LAMP.PLC and the files of
                                        ../../sdcard/LAMP/ (An.TS, Rnn.RM)
    python3 gen_lamp.py --preview DIR   also draws every room with the Python
                                        model
    python3 test_lamp_sim.py            plays it in placard_sim from a card

Wick, a beacon keeper, lands on the hollow moon Cairn after its great lamp
goes dark and climbs down through it.  The world is rooms of up to 32 x 16
tiles that scroll both ways, joined at their edges and by doors that a
shot opens; a central shaft (the Wellshaft) branches into the areas.
docs/software/LAMPLIGHTER.md has the game and the engine.

SCREEN
    rows   0-31   1 bpp, 1x   four lines of 80 column text: the room's name,
                              the energy line
    rows  32-479  4 bpp, 4x   the playfield: 160 x 112 pixels of 4 x 4,
                              16 colors: 10 x 7 tiles of 16 x 16

FILES ON THE CARD
    LAMP.PLC        the program (x0100-x3FFF)
    LAMP/An.TS      area n's tile set and sprites: 6 pages of tables to
                    x4000 (tile routine addresses, tile attributes, sprite
                    routine addresses, the area's creatures), then a
                    straight image of the RAM
                    from x6000: the tile routines and the sprite routines,
                    in the video RAM the screen leaves free
    LAMP/Rnn.RM     room nn (hex): the tile map (32 x 16, 512 bytes) to
                    x4600, then its header (size, exits, objects, name) to
                    x4800

Controls: arrow keys or SNES pad Left / Right to walk, Z, Space or pad
B / A to jump (hold for a higher jump), X or pad Y / X to fire (hold Up to
fire up), Down to crawl (with the Burrow Rig), Esc back to the DOS.

A room has up to 6 things (creatures, their bolts, items, embers); what a
kind of thing does, its frames, hits, harm and size are in its area's
table.  Model.obj_step has the rules.

Date: 11/13/2026
"""

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps  # noqa: E402
import asm_expand  # noqa: E402
from gen_raycast import Asm, row_x  # noqa: E402

MODE_PF = 0x0A          # 4 bpp, 4x
NCOL = 80               # byte columns on the screen (2 pixels each)
NROW = 112              # pixel rows (cells)
MAP_W, MAP_H = 32, 16   # the largest room, tiles
LINE_GO = 235           # frame_poll's line value where the drawing starts
                        # (screen row 396, 20 lines above the last tile row: a
                        # tile row takes about 16 lines' time to draw, so the
                        # beam has left each row when the drawing gets to it)
GRAV = 0x28             # cells / 256 a frame a frame
JUMPV = 0x0400
JUMP_CUT = 0x0100       # the rise left when the jump key is let go
MAXFALL = 0x0400
WETV = 0x0300           # the jump from under water without the Ballast Boots
SAILV = 0x0060          # the fall with the Ash Sail open (the jump key held)
SHOT_FRAMES = 30
DOOR_FRAMES = 150
CAM_X, CAM_Y = 36, 48   # the hero's place on the screen
START_ROOM, START_X, START_Y = 0, 24, 80
START_ENERGY = 30
START_EMAX = 50
FLASK = 25              # an Oil Flask: that much more energy
EMBER = 5               # an ember: that much energy back
AIRV = 0x0380           # the Updraft Bellows' jump in the air
HURTV = 0x0200          # the hop when Wick is hurt
INV_FRAMES = 60         # no harm for that long after a hit
PUFF_FRAMES = 12
BOLT_FRAMES = 90        # what a creature spits lasts that long
CHG_FULL = 45           # frames of the fire key held that fill the Kiln Charge
BLAST_PW = 4            # a blast is that many sparks
HOP_REST = 24           # frames a hopper sits between hops
HOPDY = [-4, -4, -3, -3, -2, -2, -1, -1, 1, 1, 2, 2, 3, 3, 4, 4]
DROP_NEAR = 12          # a dropper falls when Wick is that many byte columns from under it
EMBER_FRAMES = 250
MSG_FRAMES = 240
MAXOBJ = 6              # things in a room: creatures, items, embers

# input bits
IN_RIGHT, IN_LEFT, IN_JUMP, IN_FIRE, IN_UP, IN_DOWN = 1, 2, 4, 8, 16, 32
# pad buttons (bit n = button n: B Y Select Start Up Down Left Right A X L R)
PAD_B, PAD_Y, PAD_UP, PAD_DOWN, PAD_LEFT, PAD_RIGHT, PAD_A, PAD_X = 1, 2, 0x10, 0x20, 0x40, 0x80, 0x100, 0x200
# tile attributes
A_TOP, A_BOT, A_DOOR, A_DBOT = 1, 2, 4, 64      # solid upper half, lower half; a door; its lower tile
A_SOOT = 8                                      # a sooted block: a blast breaks it
A_WATER = 16                                    # water: without the Ballast Boots Wick is slow in it
A_SEAL = 32                                     # a seal: opens when the room's keepers are beaten
A_SOLID = A_TOP | A_BOT
# exits
EX_L, EX_R, EX_U, EX_D = 1, 2, 3, 4

# RAM
# the area block (8 sectors of An.TS): the song, player code, the area's tables
AREA_BLK, AREA_END = 0x3300, 0x4300
SONG = 0x3300           # 8 pages: the area's song (.SNG); its pages 3-4 (instruments
SONG_GAP = 0x3600       #   10-1F, custom waves) are not used: player code there
SONG_END = 0x3B00
PCODE_A = 0x3B00        # 3 pages: music player code (read with every area)
TS_LO, TS_HI, ATTR, FR = 0x4000, 0x4100, 0x4200, 0x3E00
SPEC = 0x3F00           # the area's kinds of things: what they do, frame, hits, harm
PCODE_B = 0x5800        # 2 pages: music player code, the An.TS sector after the block
MUS_TABLES = 0x2900     # the music player's 10 pages of tables (in LAMP.PLC)
MUS_RAM = 0x4300        # its 10 pages of RAM: wave pages x4300-x47FF, voice state
                        # x4800-x4CFF (x76-x9F of each; the game has the rest)
PROG2_END = 0x2700      # the program's second part: x2000 up to here
PCODE_C = 0x2700        # music player code in LAMP.PLC, up to MUS_TABLES
ZSAVE = 0x5C00          # x60-x8F of the zero page: the other side's copy (game / player)
SFX_NOISE, SFX_BEEP = 0x0E, 0x0F    # every song's instruments E-F: the sound effects
SPEC_BEH, SPEC_FRAME, SPEC_HP, SPEC_DMG, SPEC_ANIM = 0x00, 0x10, 0x20, 0x30, 0x40
SPEC_DIRM, SPEC_W, SPEC_H, SPEC_SPIT, SPEC_WIDE, SPEC_AIM = 0x50, 0x60, 0x70, 0x80, 0x90, 0xA0
MAP = 0x5400            # 2 pages: tile number * 8 of tile (tx, ty) at (ty << 5) | tx
HDR = 0x5600            # the room's header (then a spare page: Rnn.RM's second sector)
OBJ = 0x4A00            # the room's things (x00-x37)
O_KIND, O_X, O_Y, O_D, O_T, O_HP, O_P = 0x00, 0x08, 0x10, 0x18, 0x20, 0x28, 0x30
GOT = 0x4B00            # item n is found (x00-x3F; x76-x9F are the music player's)
V_MSG, V_MSG_T, V_MSG_D = 0xA0, 0xA1, 0xA2      # variables in that page: the message line
V_MODE = 0xA3           # 0 playing, 1 the title, 2 the ending
V_SAVED, V_SROOM, V_SX, V_SY, V_SITEMS, V_SEMAX = 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9   # the last save lamp
V_FR, V_SEC, V_MIN = 0xAA, 0xAB, 0xAC          # the time played
V_HASSAVE = 0xAD        # (the title) the card has a saved game
M_PLAY, M_TITLE, M_END = 0, 1, 2
SL = 0x4900             # the sprite list (x00-x3F)
SL_LO, SL_HI, SL_C, SL_G = 0x00, 0x10, 0x20, 0x30
MAX_SPR = 16
SD_OVL = 0x6000
# the header page
H_W, H_H, H_AREA, H_NOBJ, H_RW, H_RCY, H_RWX, H_RHY, H_FLAGS = range(9)
HF_HOT = 1              # a hot room: energy drains without the Cinder Coat
H_SEALN, H_SEAL, H_MSG = 0x09, 0x0A, 0x0E     # the room's seal: how many keepers, their item numbers; its message
G_BEAT = 32             # GOT + 32 + n: the keeper of item n is beaten
HX_SIDE, HX_LO, HX_HI, HX_DEST, HX_DELTA = 0x10, 0x18, 0x20, 0x28, 0x30
HO_KIND, HO_X, HO_Y, HO_P = 0x40, 0x48, 0x50, 0x58
# what a thing does
# (B_WALK and above: a shot hurts it)
B_ITEM, B_EMBER, B_PUFF, B_BOLT, B_LAMP, B_WALK, B_FLY, B_SIT, B_DROP, B_HOP, B_HOVER = range(11)
# the kinds every area has
S_NONE, S_ITEM, S_EMBER, S_PUFF, S_BOLT, S_LAMP = range(6)
# items: the type is the upper 3 bits of a thing's parameter, the item's
# number (its GOT flag) the lower 5
I_FLASK, I_RIG, I_BELLOWS, I_SAIL, I_KILN, I_WIDE, I_COAT, I_BOOTS = range(8)
IT_RIG, IT_BELLOWS, IT_SAIL, IT_KILN, IT_WIDE, IT_COAT, IT_BOOTS = 1, 2, 4, 8, 16, 32, 64   # bits of 'items'
H_NAME = 0x80
NAME_W = 40

# 4 bpp palette (docs/video/COLORS.md): 0 black 1 dark blue 2 purple 3 blue 4 red
# 5 magenta 6 brown 7 dark gray 8 cyan 9 dark green a white b light gray c pink
# d orange e yellow f green

# ---------------------------------------------------------------------------
# sprites (16 wide, '.' = see through)
# ---------------------------------------------------------------------------
HERO_TOP = [
    "................",
    ".....bbbbbb.....",
    "....baaaaaab....",
    "....baaeeeeb....",
    "....baaeeeeb....",
    ".....baaaab.....",
    "......3333......",
    ".....333333.d...",
    "....33333333ed..",
    "....31333313d...",
    "....31333313....",
]
HERO_LEGS = {
    'stand': [".....333333.....",
              ".....33..33.....",
              ".....33..33.....",
              ".....11..11.....",
              "....777..777...."],
    'run1': [".....333333.....",
             "....333..333....",
             "...333....33....",
             "..777.....11....",
             "..........777..."],
    'run2': [".....333333.....",
             "......3333......",
             ".....33333......",
             ".....11.33......",
             "....777..777...."],
    'jump': [".....3333333....",
             "....333...3377..",
             "...3377.........",
             "................",
             "................"],
}
HERO_CRAWL = ["................"] * 9 + [
    ".........bbbbbb.",
    "........baaeeeeb",
    "........baaeeeeb",
    "..33333333baab.d",
    ".7333333333333de",
    ".71333333331...d",
    ".77..33....33...",
]
SHOT = [".ee.",
        "eaae",
        ".ee."]
BLAST = ["..8888..",
         ".8aaaa8.",
         "8aaeeaa8",
         "8aaeeaa8",
         ".8aaaa8.",
         "..8888.."]
HERO_FRAMES = ['stand', 'run1', 'run2', 'jump', 'crawl']
NPF = len(HERO_FRAMES)
F_STAND, F_RUN1, F_RUN2, F_JUMP, F_CRAWL = range(NPF)
F_SHOT = 2 * NPF


def tall(rows, above):
    art = ["................"] * above + rows
    art += ["................"] * (16 - len(art))
    assert len(art) == 16 and all(len(r) == 16 for r in art), rows
    return art


ITEM_ART = [
    tall(["......bbbb......",        # an Oil Flask
          "......b77b......",
          ".......bb.......",
          "......b88b......",
          ".....b8dd8b.....",
          "....b8dddd8b....",
          "....b8dedd8b....",
          "....b8dddd8b....",
          "....b8dddd8b....",
          ".....b8dd8b.....",
          "......bbbb......"], 5),
    tall(["....bbbbbbbb....",        # the Burrow Rig
          "...b33333333b...",
          "...b3a3333a3b...",
          "...b33333333b...",
          "....bbbbbbbb....",
          "..777777777777..",
          ".7e7e7e7e7e7e7e.",
          "..777777777777.."], 8),
    tall(["......e.........",        # the Updraft Bellows
          ".....eae........",
          "......e.........",
          "..66666666......",
          ".6dddddddd6.....",
          ".6dddddddd6bbbb.",
          ".6d6d6d6dd6b....",
          ".6dddddddd6bbbb.",
          ".6dddddddd6.....",
          "..66666666......"], 6),
    tall(["....bbbbbbbb....",        # the Ash Sail
          "...baaaaaaaab...",
          "..baaaaaaaaaab..",
          "..baabaabaabab..",
          "..b..b..b..b.b..",
          "...7...77...7...",
          "....7..77..7....",
          ".....7.77.7.....",
          "......7777......",
          ".......dd......."], 5),
    tall(["......bbbb......",        # the Kiln Charge
          ".....b7777b.....",
          "....b744447b....",
          "...b74dddd47b...",
          "...b74deed47b...",
          "...b74deed47b...",
          "...b74dddd47b...",
          "....b744447b....",
          ".....b7777b.....",
          "......bbbb......"], 5),
    tall(["..e.....e.....e.",        # the Wide Flame
          "...e....e....e..",
          "....d...d...d...",
          ".....d..d..d....",
          "......d.d.d.....",
          ".......ddd......",
          "......bbbbb.....",
          "......b777b.....",
          "......bbbbb....."], 6),
    tall([".....bbbbbb.....",        # the Cinder Coat
          "..bbb444444bbb..",
          ".b444444444444b.",
          ".b44b444444b44b.",
          ".b44b444d44b44b.",
          "..bbb444444bbb..",
          "....b444d44b....",
          "....b444444b....",
          "....b444d44b....",
          "....bbbbbbbb...."], 5),
    tall(["...bbbb..bbbb...",        # the Ballast Boots
          "...b33b..b33b...",
          "...b33b..b33b...",
          "...b33b..b33b...",
          "...b33bb.b33bb..",
          "...b333b.b333b..",
          "..7777777777777.",
          "..7777777777777."], 8),
]
ITEM_MSG = ["OIL FLASK: THE LANTERN HOLDS MORE", "BURROW RIG: HOLD DOWN TO CRAWL",
            "UPDRAFT BELLOWS: JUMP AGAIN IN THE AIR", "ASH SAIL: HOLD JUMP TO FALL SLOWLY",
            "KILN CHARGE: HOLD FIRE, LET GO: A BLAST", "WIDE FLAME: THREE SPARKS AT A TIME",
            "CINDER COAT: HALF THE HARM, NO HEAT", "BALLAST BOOTS: NO DRAG UNDER WATER"]
MSG_DEAD = "THE LANTERN WENT OUT"
MSG_SAVE = "SAVED AT THE LAMP: THE LANTERN IS FULL"
ROOM_MSG = ["THREE KEEPERS DOWN: THE SEAL IS OPEN", "THE GREAT LAMP BURNS AGAIN"]
EMBER_ART = [
    tall(["......dd........",
          ".....deed.......",
          ".....deed.......",
          "......dd........"], 6),
    tall(["......e.........",
          ".....ede........",
          "....edade.......",
          ".....ede........",
          "......e........."], 5),
]
PUFF_ART = [
    tall([".....b..b.......",
          "...b......b.....",
          "......aa........",
          "..b..a..a..b....",
          "......aa........",
          "...b......b.....",
          ".....b..b......."], 4),
    tall(["....b....b......",
          "................",
          ".b..........b...",
          "................",
          "......7..7......",
          "................",
          ".b..........b...",
          "................",
          "....b....b......"], 2),
]
BOLT_ART = [
    tall(["..dddd..........",
          ".deeeed.........",
          "deeaaeed........",
          "deeaaeed........",
          ".deeeed.........",
          "..dddd.........."], 1),
    tall(["...dd...........",
          "..deed..........",
          ".deaaed.........",
          ".deaaed.........",
          "..deed..........",
          "...dd..........."], 1),
]
MITE_ART = [
    tall(["....22222222....",
          "...2555555552...",
          "..255c55555552..",
          ".25c5555555a152.",
          ".2555555555a152.",
          "2555555555555552",
          "2222222222222222",
          ".6..6..6..6..6..",
          ".6..6..6..6..6..",
          "66.66.66.66.66.."], 6),
    tall(["....22222222....",
          "...2555555552...",
          "..255c55555552..",
          ".25c5555555a152.",
          ".2555555555a152.",
          "2555555555555552",
          "2222222222222222",
          "..6..6..6..6..6.",
          "..6..6..6..6..6.",
          "..66.66.66.66.66"], 6),
]
DRIP_ART = [
    tall(["......7777......",
          ".....799997.....",
          ".....799997.....",
          "....79999997....",
          "....79f99997....",
          "....79999997....",
          ".....799997.....",
          ".....799997.....",
          "......7997......",
          ".......77......."], 0),
    tall(["......7777......",
          ".....799997.....",
          ".....799997.....",
          "....79999997....",
          "....79f99997....",
          "....79999997....",
          "....79999997....",
          ".....799997.....",
          ".....799997.....",
          "......7997......",
          "......7997......",
          ".......77......."], 0),
]
SPORECAP_ART = [
    ["................",
     "................",
     "................",
     "................",
     ".....444444.....",
     "...4444e44444...",
     "..44e444444e44..",
     ".4444444e444444.",
     ".44e44444444e44.",
     ".44444444444444.",
     "..bbbbbbbbbbbb..",
     ".....baaab......",
     ".....ba1ab......",
     ".....baaab......",
     "....bbaaabb.....",
     "...bbbbbbbbb...."],
    ["................",
     "................",
     "................",
     "......4444......",
     "....44444444....",
     "...44e4444e44...",
     "..444444e44444..",
     ".44e444444444e4.",
     ".444444e4444444.",
     ".44444444444444.",
     "..bbbbbbbbbbbb..",
     ".....baaab......",
     ".....ba1ab......",
     ".....baaab......",
     "....bbaaabb.....",
     "...bbbbbbbbb...."],
]
# Bramblejaw: its left half; the right half is the mirror of it
JAW_HALF = [
    "................",
    "..........f.....",
    ".....f...9f9....",
    "....9f9..999...9",
    "....999.99999.99",
    ".....9999999999f",
    "....99ffffffffff",
    "...99fff99999999",
    "..99ff9999999999",
    ".99ff99aaaa99999",
    ".9ff999a44a99999",
    "99f9999aaaa99999",
    "9ff9999999999999",
    "9f99999999999999",
    "9f999eeeeeeeeeee",
    "9f99e4e4e4e4e4e4",
    "9f99444444444444",
    "9f99e4e4e4e4e4e4",
    "9ff99eeeeeeeeeee",
    ".9f9999999999999",
    ".99ff99999999999",
    "..99fff999999999",
    "...999ffffffffff",
    ".....99999999999",
    "......6699996666",
    ".....66.6996..66",
    "....66..666...66",
    "...66...66....66",
    "..66....66...66.",
    "..6.....6....6..",
    ".66....66...66..",
    "666...666..666..",
]
JAW_SHUT = {15: "9f99eeeeeeeeeeee", 16: "9f99e9e9e9e9e9e9", 17: "9f99eeeeeeeeeeee",
            28: "...66...66....66", 29: "...6....6.....6.", 30: "..66...66....66.", 31: ".666..666...666."}


def boss(half, other, alt):
    """a boss 32 x 32 from its left half (the right is its mirror); alt:
    its second frame, with the rows of 'other'"""
    rows = [other.get(i, r) if alt else r for i, r in enumerate(half)]
    assert len(rows) == 32 and all(len(r) == 16 for r in rows), [len(r) for r in rows]
    return [r + r[::-1] for r in rows]


def jaw(shut):
    return boss(JAW_HALF, JAW_SHUT, shut)


# Clinker, the Slagworks' boss: a furnace that floats
CLINKER_HALF = [
    "................",
    "..........777777",
    "........77bbbbbb",
    "......77bb777777",
    ".....7bb77777777",
    "....7b7777777777",
    "...7b77777444477",
    "...7b7777444e447",
    "..7b77777444e447",
    "..7b777777444477",
    "..7b777777777777",
    ".7b7777777777777",
    ".7b77dd777777777",
    ".7b77dd777777777",
    ".7b7777777777777",
    ".7b77777bbbbbbbb",
    ".7b7777b4d4d4d4d",
    ".7b7777b4d4d4d4d",
    ".7b7777bbbbbbbbb",
    "..7b777777777777",
    "..7b777777777777",
    "..7b7777dd7777dd",
    "...7b77777777777",
    "...7b77777777777",
    "....7b7777777777",
    ".....7bb77777777",
    "......77bb777777",
    "........77bbbbbb",
    "..........777777",
    ".............ded",
    "..............e.",
    "................",
]
CLINKER_ALT = {16: ".7b7777bd4d4d4d4", 17: ".7b7777bd4d4d4d4", 29: "..............d.", 30: "................"}
HOP_ART = [
    tall(["....44444444....",
          "...4dddddddd4...",
          "..4ddeddddedd4..",
          "..4dd0dddd0dd4..",
          "..4dddddddddd4..",
          "...4dddddddd4...",
          "....44444444....",
          "...44......44...",
          "..444......444..",
          ".4444......4444."], 6),
    tall(["....44444444....",
          "...4dddddddd4...",
          "..4ddeddddedd4..",
          "..4dd0dddd0dd4..",
          "..4dddddddddd4..",
          "...4dddddddd4...",
          "....44444444....",
          "....44....44....",
          "....44....44....",
          "...444....444...",
          "..4444....4444.."], 5),
]
FLUE_ART = [
    tall(["....bbbbbbbb....",
          "....b444444b....",
          "....b4dddd4b....",
          "....bbbbbbbb....",
          ".....777777.....",
          ".....7b77b7.....",
          ".....777777.....",
          ".....7b77b7.....",
          ".....777777.....",
          ".....7b77b7.....",
          "....77777777....",
          "...7777777777..."], 4),
    tall(["....bbbbbbbb....",
          "....b4dddd4b....",
          "....b4deed4b....",
          "....bbbbbbbb....",
          ".....777777.....",
          ".....7b77b7.....",
          ".....777777.....",
          ".....7b77b7.....",
          ".....777777.....",
          ".....7b77b7.....",
          "....77777777....",
          "...7777777777..."], 4),
]


FIN_ART = [
    tall(["................",
          "......3333......",
          "....33888833..3.",
          "..3388888888333.",
          ".38a088888888833",
          ".388888888888833",
          "..3388888888333.",
          "....33888833..3.",
          "......3333......"], 3),
    tall(["................",
          "......3333......",
          "....33888833....",
          "..33888888883.3.",
          ".38a08888888833.",
          ".38888888888833.",
          "..33888888883.3.",
          "....33888833....",
          "......3333......"], 3),
]
# Old Gulper, the Brine Vaults' boss: its left half
GULP_HALF = [
    "...............e",
    "..............e8",
    "...............8",
    "...............8",
    ".........3333338",
    ".......333888888",
    ".....33388888888",
    "....338888888888",
    "...3388aaaa88888",
    "..3388aa00aa8888",
    "..388aa0000a8888",
    ".3388aa00aa88888",
    ".33888aaaa888888",
    ".388888888888888",
    "3388888888888888",
    "3388111111111111",
    "33811aaaaaaaaaaa",
    "3381a1a1a1a1a1a1",
    "3381444444444444",
    "3381444444444444",
    "3381a1a1a1a1a1a1",
    "33811aaaaaaaaaaa",
    "3388111111111111",
    "3338888888888888",
    ".338888888888888",
    ".333888888883333",
    "..33388888833333",
    "...3333333333333",
    "....33333333..33",
    ".....33..33.....",
    "....333.333.....",
    "...333..333.....",
]
GULP_SHUT = {18: "3381a1a1a1a1a1a1", 19: "3381a1a1a1a1a1a1", 0: "..............e.", 1: "...............8"}


# the Snuffer, the Orrery's keeper: a great snuffer's cap with eyes in it
SNUFF_HALF = [
    "..............bb",
    "..............b7",
    "..............b7",
    "..............b7",
    ".............b77",
    "............b777",
    "...........b7777",
    "..........b77777",
    ".........b777777",
    "........b7777777",
    ".......b77777777",
    "......b777777777",
    ".....b7777777777",
    ".....b7777777777",
    "....b77777dd7777",
    "....b7777dddd777",
    "...b77777dddd777",
    "...b777777dd7777",
    "..b7777777777777",
    "..b7777777777777",
    ".b77777777777777",
    ".b77777777777777",
    "b777777777777777",
    "bbbbbbbbbbbbbbbb",
    "1111111111111111",
    ".1.1.1.1.1.1.1.1",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
]
SNUFF_ALT = {14: "....b77777ee7777", 15: "....b7777eeee777", 16: "...b77777eeee777", 17: "...b777777ee7777",
             25: "1.1.1.1.1.1.1.1.", 26: ".1...1...1...1..", 27: "..1.....1.....1."}


# a save lamp: a post with a lantern on it
SAVE_ART = [
    ["......bbbb......", ".....b0000b.....", ".....beeeeb.....", ".....bedceb.....", ".....bedceb.....",
     ".....beeeeb.....", "......bbbb......", ".......bb.......", ".......66.......", ".......66.......",
     ".......66.......", ".......66.......", ".......66.......", ".......66.......", "......6666......",
     ".....bbbbbb....."],
    ["......bbbb......", ".....b0000b.....", ".....beeeeb.....", ".....beddeb.....", ".....bedceb.....",
     ".....beeeeb.....", "......bbbb......", ".......bb.......", ".......66.......", ".......66.......",
     ".......66.......", ".......66.......", ".......66.......", ".......66.......", "......6666......",
     ".....bbbbbb....."],
]


def recolor(art, old, new):
    return [[r.translate(str.maketrans(old, new)) for r in a] for a in art]


MOTH_ART = [
    tall(["..b..........b..",
          ".bab........bab.",
          ".baab......baab.",
          ".baaab....baaab.",
          "..baaab22baaab..",
          "...baa2552aab...",
          "....bb2ee2bb....",
          ".....225522.....",
          "......2552......",
          "......2222......",
          ".......22......."], 1),
    tall(["......2222......",
          "..bbbb2552bbbb..",
          ".baaaa2ee2aaaab.",
          ".baaab2552baaab.",
          ".baab.2552.baab.",
          ".bab..2222..bab.",
          "..b....22....b.."], 5),
]


def hero(name):
    art = HERO_CRAWL if name == 'crawl' else HERO_TOP + HERO_LEGS[name]
    assert len(art) == 16 and all(len(r) == 16 for r in art), name
    return art


def common_frames():
    fr = []
    for flip in (False, True):
        for f in HERO_FRAMES:
            art = hero(f)
            fr.append((('L_' if flip else 'R_') + f, [r[::-1] for r in art] if flip else art))
    fr.append(('shot', SHOT))
    fr.append(('blast', BLAST))
    for i, art in enumerate(ITEM_ART):
        fr.append(('item%d' % i, art))
    fr += [('ember0', EMBER_ART[0]), ('ember1', EMBER_ART[1]), ('puff0', PUFF_ART[0]), ('puff1', PUFF_ART[1]),
           ('bolt0', BOLT_ART[0]), ('bolt1', BOLT_ART[1]), ('lamp0', SAVE_ART[0]), ('lamp1', SAVE_ART[1])]
    return fr


COMMON = common_frames()
F_BLAST = F_SHOT + 1
F_ITEM = F_BLAST + 1
F_EMBER = F_ITEM + len(ITEM_ART)
F_PUFF = F_EMBER + 2
F_BOLT = F_PUFF + 2
F_LAMP = F_BOLT + 2
# a kind of thing: (name, what it does, frame, hits, harm, animated, the bits
# of its direction that pick a frame, width in byte columns, height in
# cells, spits when its timer & this is 0 (0: never), frame offset of its
# right half (0: 16 pixels wide), 1: it spits down, not sideways)
K_NAME, K_BEH, K_FRAME, K_HP, K_DMG, K_ANIM, K_DIRM, K_W, K_H, K_SPIT, K_WIDE, K_AIM = range(12)
# the kinds every area has
COMMON_SPEC = [('none', B_ITEM, 0, 0, 0, 0, 0, 8, 16, 0, 0, 0), ('item', B_ITEM, F_ITEM, 0, 0, 0, 7, 8, 16, 0, 0, 0),
               ('ember', B_EMBER, F_EMBER, 0, 0, 1, 0, 8, 16, 0, 0, 0),
               ('puff', B_PUFF, F_PUFF, 0, 0, 1, 0, 8, 16, 0, 0, 0),
               ('bolt', B_BOLT, F_BOLT, 0, 6, 1, 0, 4, 8, 0, 0, 0),
               ('lamp', B_LAMP, F_LAMP, 0, 0, 1, 0, 8, 16, 0, 0, 0)]

# ---------------------------------------------------------------------------
# tiles (16 x 16, one hex digit a pixel).  Tiles 0-4 are the same in every
# area: 0 empty, 1 / 2 a door's upper and lower tile, shut, 3 / 4 open.
# ---------------------------------------------------------------------------
def grid(fill='0'):
    return [[fill] * 16 for _ in range(16)]


def done(g):
    return [''.join(r) for r in g]


def block(face, hi, lo, specks=()):
    g = grid(face)
    for i in range(16):
        g[0][i] = hi
        g[i][0] = hi
    for i in range(16):
        g[15][i] = lo
        g[i][15] = lo
    for x, y, c in specks:
        g[y][x] = c
    return done(g)


def specks(pts):
    g = grid()
    for x, y, c in pts:
        g[y][x] = c
    return done(g)


def half(top, face, hi, lo):
    """a tile solid in its upper (top) or lower half only"""
    g = grid()
    r0 = 0 if top else 8
    for y in range(r0, r0 + 8):
        for x in range(16):
            g[y][x] = face
    for x in range(16):
        g[r0][x] = hi
        g[r0 + 7][x] = lo
    for x in range(16):
        g[r0 + 4][x] = lo
    return done(g)


def door(lower, shut):
    g = grid()
    for y in range(16):
        edge = (y < 3) if not lower else (y > 12)
        for x in range(16):
            if x in (2, 3, 12, 13) and (shut or edge):
                g[y][x] = 'b'
            if shut and 4 <= x <= 11:
                g[y][x] = '8' if x in (5, 6) else '3'
            if edge and 2 <= x <= 13:
                g[y][x] = 'b' if shut or x < 5 or x > 10 else '7'
    return done(g)


COMMON_TILES = [(' ', done(grid()), 0),
                ('D', door(False, True), A_SOLID | A_DOOR),
                ('E', door(True, True), A_SOLID | A_DOOR | A_DBOT),
                ('d', door(False, False), 0),
                ('e', door(True, False), 0)]
T_DT, T_DB, T_DOT, T_DOB = 8, 16, 24, 32        # tile number * 8

# a sooted block: a blast of the Kiln Charge breaks it
SOOT_TILE = block('1', '7', '0', [(4, 4, '7'), (10, 9, '7'), (7, 12, '7'), (12, 3, '7'), (3, 10, '0'),
                                  (9, 5, '0')])


# a seal: a brass grate that opens when the room's keepers are beaten
SEAL_TILE = done([("6ee6" * 4) if y in (0, 15) else ("6" + "e" * 14 + "6") if y in (5, 10) else
                  ".6e..e6..6e..e6.".replace(".", "0") for y in range(16)])


def rock(kind, face='7', hi='b', lo='1', fleck='6'):
    """a rock tile: 'in' the inside, 'top' with a lit upper edge (open
    above), 'under' with a dark lower edge (open below)"""
    g = grid(face)
    for x, y in ((2, 3), (9, 2), (13, 6), (5, 8), (11, 11), (3, 13), (8, 14), (14, 12)):
        g[y][x] = lo
        g[y][x + 1] = lo
    for x, y in ((6, 5), (12, 9), (1, 10)):
        g[y][x] = fleck
    if kind == 'top':
        g[0] = list(hi * 16)
        g[1] = list((hi + hi + face + hi) * 4)
        g[2] = list((face * 3 + hi + face * 4) * 2)
    if kind == 'under':
        g[15] = list(lo * 16)
        g[14] = list((lo + face + lo + lo) * 4)
        g[13] = list((face * 5 + lo + face * 2) * 2)
    return done(g)


# a rock letter in a room's rows becomes one of the area's three rock
# tiles by what is above and below it
ROCK = {'#': ('#', 'T', 'U')}       # letter: inside, open above, open below

AREAS = [
    dict(name='THE WELLSHAFT', tiles=[
        (',', specks([(3, 2, '1'), (11, 6, '1'), (6, 12, '2'), (13, 13, '1')]), 0),
        ('#', rock('in'), A_SOLID),
        ('T', rock('top'), A_SOLID),
        ('U', rock('under'), A_SOLID),
        ('_', half(False, '7', 'b', '1'), A_BOT),
        ('=', half(True, '7', 'b', '1'), A_TOP),
        ('S', SOOT_TILE, A_SOLID | A_SOOT),
        ('X', SEAL_TILE, A_SOLID | A_SEAL),
    ], creatures=[
        dict(name='mite', beh=B_WALK, hp=2, dmg=8, art=MITE_ART),
        dict(name='moth', beh=B_FLY, hp=1, dmg=5, art=MOTH_ART),
        dict(name='drip', beh=B_DROP, hp=1, dmg=6, art=DRIP_ART),
    ]),
]


def plant(kind):
    """scenery of the Gardens: 'g' a glasswort, 'v' a hanging vine"""
    g = grid()
    if kind == 'g':
        for y in range(4, 16):
            g[y][7], g[y][8] = ('a' if y % 4 == 0 else '8'), '3'
        for x, y in ((6, 7), (5, 6), (4, 5), (4, 4), (9, 10), (10, 9), (11, 8), (11, 7), (11, 6)):
            g[y][x] = '8'
        g[3][4] = g[5][11] = g[3][7] = 'a'
    else:
        for y in range(0, 12):
            g[y][4] = 'f' if y % 3 == 0 else '9'
        for y in range(0, 7):
            g[y][11] = 'f' if y % 3 == 1 else '9'
        g[12][4] = g[7][11] = 'e'
    return done(g)


GARDEN_TILES = [
    (',', specks([(3, 2, '9'), (11, 6, '1'), (6, 12, '9'), (13, 13, '8')]), 0),
    ('#', rock('in', '6', 'f', '1', '9'), A_SOLID),
    ('T', rock('top', '6', 'f', '1', '9'), A_SOLID),
    ('U', rock('under', '6', 'f', '1', '9'), A_SOLID),
    ('_', half(False, '6', 'f', '1'), A_BOT),
    ('=', half(True, '6', 'f', '1'), A_TOP),
    ('g', plant('g'), 0),
    ('v', plant('v'), 0),
]
AREAS += [
    dict(name='THE GLASSWORT GARDENS', tiles=GARDEN_TILES, creatures=[
        dict(name='mossback', beh=B_WALK, hp=3, dmg=8, art=recolor(MITE_ART, '25c', '9fe')),
        dict(name='gnat', beh=B_FLY, hp=1, dmg=5, art=recolor(MOTH_ART, 'ba25', 'de6d')),
        dict(name='sporecap', beh=B_SIT, hp=2, dmg=6, art=recolor(SPORECAP_ART, '4', '2'), spit=127),
        dict(name='drip', beh=B_DROP, hp=1, dmg=6, art=DRIP_ART),
    ]),
    # (a boss's room has its own set: its frames take the room of the others)
    dict(name="BRAMBLEJAW'S DEN", tiles=GARDEN_TILES, creatures=[
        dict(name='bramblejaw', beh=B_WALK, hp=32, dmg=12, art=[jaw(False), jaw(True)], spit=31),
    ]),
]
SLAG_TILES = [
    (',', specks([(3, 2, '4'), (11, 6, '6'), (6, 12, '6'), (13, 13, '4')]), 0),
    ('#', rock('in', '7', 'd', '0', '4'), A_SOLID),
    ('T', rock('top', '7', 'd', '0', '4'), A_SOLID),
    ('U', rock('under', '7', 'd', '0', '4'), A_SOLID),
    ('_', half(False, '7', 'd', '0'), A_BOT),
    ('=', half(True, '7', 'd', '0'), A_TOP),
    ('S', SOOT_TILE, A_SOLID | A_SOOT),
]
AREAS += [
    dict(name='THE SLAGWORKS', tiles=SLAG_TILES, creatures=[
        dict(name='cinderhop', beh=B_HOP, hp=2, dmg=8, art=HOP_ART),
        dict(name='emberwing', beh=B_FLY, hp=1, dmg=6, art=recolor(MOTH_ART, 'ba25', '4d7e')),
        dict(name='flue', beh=B_SIT, hp=3, dmg=6, art=FLUE_ART, spit=63),
        dict(name='slagback', beh=B_WALK, hp=4, dmg=10, art=recolor(MITE_ART, '25c', '74d')),
    ]),
    dict(name="CLINKER'S FORGE", tiles=SLAG_TILES, creatures=[
        dict(name='clinker', beh=B_HOVER, hp=40, dmg=12, spit=15, aim=1,
             art=[boss(CLINKER_HALF, CLINKER_ALT, False), boss(CLINKER_HALF, CLINKER_ALT, True)]),
    ]),
]

def water(top):
    g = grid('1')
    for x, y in ((2, 5), (3, 5), (10, 9), (11, 9), (6, 13), (7, 13), (13, 3)):
        g[y][x] = '3'
    if top:
        for y in range(4):
            g[y] = list('0' * 16)
        g[4] = list('8838' * 4)
        g[5] = list('3313' * 4)
    return done(g)


def over(back, art):
    """art with the tile 'back' where it is empty"""
    return [''.join(b if a == '0' else a for a, b in zip(ra, rb)) for ra, rb in zip(art, back)]




def lamp(part):
    """the great lamp, 2 tiles wide and 3 high: 'l' 'm' its globe, 'p' 'q'
    'P' 'Q' its column"""
    pic = [['0'] * 32 for _ in range(48)]
    for y in range(1, 16):
        for x in range(32):
            if (x - 15.5) ** 2 / 196 + (y - 9) ** 2 / 64 < 1:
                pic[y][x] = 'e'
            if (x - 15.5) ** 2 / 36 + (y - 9.5) ** 2 / 36 < 1:
                pic[y][x] = 'd'
            if (x - 15.5) ** 2 / 6 + (y - 10.5) ** 2 / 6 < 1:
                pic[y][x] = 'a'
    for x in range(6, 26):
        pic[15][x] = pic[16][x] = 'b'
    for y in range(17, 48):
        for x in range(11, 21):
            pic[y][x] = 'b' if x in (11, 20) or y % 8 == 0 else '6'
    for y in (46, 47):
        for x in range(6, 26):
            pic[y][x] = 'b'
    tx, ty = {'l': (0, 0), 'm': (1, 0), 'p': (0, 1), 'q': (1, 1), 'P': (0, 2), 'Q': (1, 2)}[part]
    return [''.join(pic[16 * ty + y][16 * tx:16 * tx + 16]) for y in range(16)]


def planet():
    """scenery of the Orrery: a small ringed planet"""
    g = grid()
    for y in range(5, 11):
        for x in range(5, 11):
            if (x - 7.5) ** 2 + (y - 7.5) ** 2 < 9:
                g[y][x] = '3' if x + y < 15 else '1'
    for x in range(2, 14):
        g[8 if x < 8 else 7][x] = 'e' if g[8 if x < 8 else 7][x] == '0' or x in (2, 3, 12, 13) else g[8 if x < 8 else 7][x]
    return done(g)


BRINE_TILES = [
    (',', specks([(3, 2, '2'), (11, 6, '1'), (6, 12, '2'), (13, 13, '5')]), 0),
    ('#', rock('in', '2', 'c', '1', '5'), A_SOLID),
    ('T', rock('top', '2', 'c', '1', '5'), A_SOLID),
    ('U', rock('under', '2', 'c', '1', '5'), A_SOLID),
    ('_', half(False, '2', 'c', '1'), A_BOT),
    ('=', half(True, '2', 'c', '1'), A_TOP),
    ('w', water(False), A_WATER),
    ('~', water(True), A_WATER),
    ('-', over(water(False), half(False, '2', 'c', '1')), A_BOT),    # a ledge under water
    ('^', over(water(True), half(False, '2', 'c', '1')), A_BOT),     # ... at its top
]
AREAS += [
    dict(name='THE BRINE VAULTS', tiles=BRINE_TILES, creatures=[
        dict(name='brinefin', beh=B_FLY, hp=2, dmg=8, art=FIN_ART),
        dict(name='limpet', beh=B_SIT, hp=3, dmg=6, art=recolor(SPORECAP_ART, '4', '5'), spit=63),
        dict(name='shellback', beh=B_WALK, hp=4, dmg=10, art=recolor(MITE_ART, '25c', '38a')),
        dict(name='drip', beh=B_DROP, hp=1, dmg=6, art=DRIP_ART),
    ]),
    dict(name="OLD GULPER'S CISTERN", tiles=BRINE_TILES, creatures=[
        dict(name='gulper', beh=B_WALK, hp=48, dmg=14, spit=31,
             art=[boss(GULP_HALF, GULP_SHUT, False), boss(GULP_HALF, GULP_SHUT, True)]),
    ]),
]

ORRERY_TILES = [
    (',', specks([(3, 2, '8'), (11, 6, 'a'), (6, 12, 'e'), (13, 13, '8')]), 0),
    ('#', rock('in', '1', '8', '0', 'e'), A_SOLID),
    ('T', rock('top', '1', '8', '0', 'e'), A_SOLID),
    ('U', rock('under', '1', '8', '0', 'e'), A_SOLID),
    ('_', half(False, '6', 'e', '1'), A_BOT),
    ('=', half(True, '6', 'e', '1'), A_TOP),
    ('o', planet(), 0),
    ('l', lamp('l'), 0),
    ('m', lamp('m'), 0),
    ('p', lamp('p'), 0),
    ('q', lamp('q'), 0),
    ('P', lamp('P'), 0),
    ('Q', lamp('Q'), 0),
    ('X', SEAL_TILE, A_SOLID | A_SEAL),
]
AREAS += [
    dict(name='THE ORRERY', tiles=ORRERY_TILES, creatures=[
        dict(name='cogmite', beh=B_WALK, hp=4, dmg=10, art=recolor(MITE_ART, '25c', '6ed')),
        dict(name='wisp', beh=B_FLY, hp=2, dmg=8, art=recolor(MOTH_ART, 'ba25', '8a3e')),
        dict(name='lens', beh=B_SIT, hp=3, dmg=8, art=recolor(FLUE_ART, 'b4de7', 'e3a81'), spit=63),
        dict(name='orbit', beh=B_HOP, hp=3, dmg=8, art=recolor(HOP_ART, '4de0', '38a1')),
    ]),
    dict(name="THE SNUFFER'S VAULT", tiles=ORRERY_TILES, creatures=[
        dict(name='snuffer', beh=B_HOVER, hp=120, dmg=14, spit=15, aim=3,
             art=[boss(SNUFF_HALF, SNUFF_ALT, False), boss(SNUFF_HALF, SNUFF_ALT, True)]),
    ]),
]

# ---------------------------------------------------------------------------
# rooms.  Rows of tile letters, up to 32 x 16.  An exit is (side, lo, hi,
# room, delta): leaving by that side between tiles lo and hi (rows for L
# and R, columns for U and D) leads to the room, delta tiles along the edge.
# The edge column of an L / R exit is open; its door stands one tile in.
# objs: (creature, tx, ty), (creature, tx, ty, item type, number) when it
# leaves that item, or ('item', tx, ty, type, number): the thing's box
# starts at that tile.  Item numbers are 1-31.
# ---------------------------------------------------------------------------
ROOMS = [
    dict(name='LANDING LEDGE', area=0, exits=[('R', 4, 5, 1, -2)], objs=[('mite', 12, 5), ('drip', 8, 1)], rows=[
        "########################",
        "#,        ,           ##",
        "#     ,         ,     ##",
        "#  ,        ###       ##",
        "#        ,         _  D ",
        "#   ##         __     E ",
        "########################"]),
    dict(name='THE WELLSHAFT, UPPER', area=0,
         exits=[('L', 2, 3, 0, 2), ('R', 8, 9, 2, -4), ('D', 4, 5, 3, 0)], objs=[('moth', 4, 11)], rows=[
        "##########",
        "##   ,  ##",
        " D      ##",
        " E      ##",
        "####    ##",
        "##     _##",
        "##  __  ##",
        "## ,    ##",
        "##_     D ",
        "##      E ",
        "##   #####",
        "##      ##",
        "##__  , ##",
        "##     _##",
        "##      ##",
        "####  ####"]),
    dict(name="KEEPER'S DUCT", area=0, exits=[('L', 4, 5, 1, 4)],
         objs=[('item', 26, 5, I_FLASK, 1), ('mite', 6, 5), ('moth', 27, 3)], rows=[
        "#" * 32,
        "#######" + " " * 10 + "#" * 15,
        "#######" + "   ,      " + "#######" + "  ,   " + "##",
        "#" + " " * 16 + "#######" + "      " + "##",
        " D" + " " * 8 + "#" * 13 + "       " + "##",
        " E" + " " * 8 + "=" * 13 + "   ,   " + "##",
        "#" * 32]),
    dict(name='THE WELLSHAFT, LOWER', area=0,
         exits=[('U', 4, 5, 1, 0), ('L', 13, 14, 4, -4), ('R', 13, 14, 5, -7), ('D', 4, 5, 14, 0)],
         objs=[('moth', 4, 7), ('lamp', 2, 14)], rows=[
        "####  ####",
        "##      ##",
        "##  ##  ##",
        "##      ##",
        "## ,  _ ##",
        "##      ##",
        "## _    ##",
        "##    , ##",
        "##   __ ##",
        "##      ##",
        "## _    ##",
        "## ,    ##",
        "##    _ ##",
        " D      D ",
        " E      E ",
        "####  ####"]),
    dict(name='WEST GALLERY', area=0, exits=[('R', 9, 10, 3, 4), ('L', 10, 10, 6, -5), ('L', 1, 2, 6, 0)],
         objs=[('item', 3, 5, I_RIG, 3), ('mite', 10, 10), ('mite', 20, 10), ('moth', 20, 5)], rows=[
        "################################",
        "         ####          ,       #",
        "   ,                ,          #",
        "###        ,    __             #",
        "#                     ####     #",
        "#     __ ,                     #",
        "#  __         ####         ,   #",
        "#                          __  #",
        "#       ###          ,         #",
        "# ,              ##           D ",
        "==    __     ,          ###   E ",
        "################################"]),
    dict(name='EAST GATE', area=0, exits=[('L', 6, 7, 3, 7), ('R', 6, 7, 15, 0)],
         objs=[('mite', 8, 7), ('drip', 16, 1)], rows=[
        "######################",
        "#                    #",
        "#   ,          ,     #",
        "#                    #",
        "#        ,  ##       #",
        "#           ##       #",
        " D     __   ##  __  D ",
        " E  ##      ##   ,  E ",
        "######################"]),
    # ---- the Glasswort Gardens
    dict(name='GLASSWORT GATE', area=1, exits=[('R', 5, 5, 4, 5), ('L', 4, 5, 7, -2), ('R', 1, 2, 4, 0)],
         objs=[('mossback', 12, 5), ('gnat', 8, 2), ('lamp', 3, 5)], rows=[
        "########################",
        "#v    v    ,     v      ",
        "#        ,              ",
        "#   ,        ##  __  ###",
        " D        g       g  ###",
        " E   g   ##   g   ##  ==",
        "########################"]),
    dict(name='THE CONSERVATORY', area=1,
         exits=[('R', 2, 3, 6, 2), ('L', 7, 8, 8, -2), ('R', 11, 12, 9, -2), ('D', 4, 5, 11, 0)],
         objs=[('gnat', 4, 5), ('drip', 3, 1)], rows=[
        "##########",
        "##  v   ##",
        "##      D ",
        "##      E ",
        "##   #####",
        "##     ,##",
        "##__    ##",
        " D      ##",
        " E    __##",
        "####    ##",
        "## g    ##",
        "##  __  D ",
        "##      E ",
        "##   #####",
        "##    ####",
        "####  ####"]),
    dict(name='FROND WALK', area=1, exits=[('R', 5, 6, 7, 2)],
         objs=[('item', 3, 3, I_FLASK, 4), ('mossback', 15, 6), ('gnat', 20, 2), ('drip', 10, 1),
               ('sporecap', 5, 6)], rows=[
        "################################",
        "#   v      v        ####   v   #",
        "#                              #",
        "#     ,       __        ,      #",
        "#  __              ###         #",
        "#        ###   g          __  D ",
        "#  g    #####      g   ##     E ",
        "################################"]),
    dict(name='SPORE HALL', area=1, exits=[('L', 9, 10, 7, 2), ('R', 5, 6, 10, -1)],
         objs=[('sporecap', 17, 10), ('mossback', 22, 10), ('sporecap', 19, 5), ('gnat', 10, 2),
               ('drip', 5, 5)], rows=[
        "################################",
        "#    v        v         v      #",
        "#                              #",
        "#           ,        __        #",
        "#   ###          ,        ###  #",
        "#          __                 D ",
        "#                 ####        E ",
        "#      ,                  ######",
        "#  __       ###     ,     ######",
        " D                  __       ###",
        " E     g    ##            g  ###",
        "################################"]),
    dict(name='BELLOWS NOOK', area=1, exits=[('L', 4, 5, 9, 1)],
         objs=[('item', 8, 5, I_BELLOWS, 2)], rows=[
        "############",
        "#  v    v ##",
        "#         ##",
        "#     ,   ##",
        " D        ##",
        " E   g    ##",
        "############"]),
    dict(name='ROOT CELLAR', area=1, exits=[('U', 4, 5, 7, 0), ('L', 13, 14, 12, -8)],
         objs=[('gnat', 4, 7), ('drip', 6, 1)], rows=[
        "####  ####",
        "##      ##",
        "##  ##  ##",
        "##      ##",
        "## ,  _ ##",
        "##      ##",
        "## _    ##",
        "##    , ##",
        "##   __ ##",
        "##      ##",
        "## _    ##",
        "## ,    ##",
        "##    _ ##",
        " D      ##",
        " E      ##",
        "##########"]),
    dict(name='THORN GATE', area=1, exits=[('R', 5, 6, 11, 8), ('L', 5, 6, 13, -1)],
         objs=[('sporecap', 10, 2), ('mossback', 16, 6)], rows=[
        "########################",
        "#   v       v      v   #",
        "#                      #",
        "#         ##           #",
        "#         ##     ,     #",
        " D   __   ##   __     D ",
        " E   g    ##      g   E ",
        "########################"]),
    dict(name="BRAMBLEJAW'S DEN", area=2, exits=[('R', 4, 5, 12, 1)],
         objs=[('bramblejaw', 4, 4, I_SAIL, 5)], rows=[
        "####################",
        "#   v     v     v  #",
        "#                  #",
        "#                  #",
        "#                 D ",
        "#                 E ",
        "############ #######"]),
    # ---- the deep Wellshaft
    dict(name='THE WELLSHAFT, DEEP', area=0, exits=[('U', 4, 5, 3, 0), ('R', 13, 14, 22, -9), ('D', 4, 5, 28, 0)],
         seal=[5, 9, 12], msg=0,
         objs=[('item', 1, 14, I_FLASK, 6), ('moth', 5, 9)], rows=[
        "####  ####",
        "##      ##",
        "##  ##  ##",
        "##      ##",
        "## ,  _ ##",
        "##      ##",
        "## _    ##",
        "##    , ##",
        "##   __ ##",
        "##      ##",
        "## _    ##",
        "## ,    ##",
        "##    _ ##",
        "#  S    D ",
        "#  S    E ",
        "####XX####"]),
    # ---- the Slagworks
    dict(name='SLAG STAIR', area=3, exits=[('L', 6, 7, 5, 0), ('R', 3, 4, 16, -1)],
         objs=[('cinderhop', 10, 7), ('flue', 20, 4), ('emberwing', 8, 2), ('lamp', 4, 7)], rows=[
        "########################",
        "#     ,          ,     #",
        "#                      #",
        "#               __    D ",
        "#          __         E ",
        "#      __          #####",
        " D                ######",
        " E      ,   ##   #######",
        "########################"]),
    dict(name='FLUE HALL', area=3,
         exits=[('L', 2, 3, 15, 1), ('R', 7, 8, 17, -3), ('L', 11, 12, 18, -7), ('D', 4, 5, 19, 0)],
         objs=[('emberwing', 4, 5), ('cinderhop', 6, 12)], rows=[
        "##########",
        "##   ,  ##",
        " D      ##",
        " E      ##",
        "#####   ##",
        "##,     ##",
        "##    __##",
        "##      D ",
        "##__    E ",
        "##    ####",
        "##    , ##",
        " D  __  ##",
        " E      ##",
        "#####   ##",
        "####    ##",
        "####  ####"]),
    dict(name='KILN LOFT', area=3, exits=[('L', 4, 5, 16, 3)],
         objs=[('item', 16, 5, I_KILN, 7), ('flue', 11, 2), ('cinderhop', 9, 5)], rows=[
        "####################",
        "#   ,          ,   #",
        "#                  #",
        "#         ###      #",
        " D                 #",
        " E    ##       ,   #",
        "####################"]),
    dict(name='CINDER RUN', area=3, hot=True, exits=[('R', 4, 5, 16, 7)],
         objs=[('item', 2, 5, I_FLASK, 8), ('emberwing', 12, 2), ('cinderhop', 20, 5)], rows=[
        "################################",
        "#                              #",
        "#   ,        ,        ,        #",
        "#        __         __         #",
        "#                             D ",
        "#  ,   ##      ##       ##    E ",
        "################################"]),
    dict(name='SLAG LAKE', area=3, exits=[('U', 4, 5, 16, 0), ('R', 4, 5, 20, 3)],
         objs=[('emberwing', 14, 3), ('slagback', 24, 5), ('cinderhop', 13, 8)], rows=[
        "####  ##########################",
        "#                              #",
        "#   ##                         #",
        "#                              #",
        "# _                           D ",
        "#                             E ",
        "########            ############",
        "########            ############",
        "######## __      __ ############",
        "################################"]),
    dict(name='SOOT LOCK', area=3, exits=[('L', 7, 8, 19, -3), ('R', 7, 8, 21, -3)],
         objs=[('slagback', 3, 8), ('flue', 7, 3), ('slagback', 12, 8)], rows=[
        "################",
        "#   ,      ,   #",
        "#              #",
        "#              #",
        "#      ##      #",
        "#      ##      #",
        "#  __  ##  __  #",
        " D     SS     D ",
        " E     SS     E ",
        "################"]),
    dict(name="CLINKER'S FORGE", area=4, exits=[('L', 4, 5, 20, 3)],
         objs=[('clinker', 9, 1, I_COAT, 9)], rows=[
        "####################",
        "#                  #",
        "#                  #",
        "#                  #",
        " D                 #",
        " E                 #",
        "####################"]),
    # ---- the Brine Vaults
    dict(name='BRINE GATE', area=5, exits=[('L', 4, 5, 14, 9), ('R', 4, 5, 23, -2)],
         objs=[('shellback', 14, 5), ('drip', 9, 1), ('lamp', 3, 5)], rows=[
        "####################",
        "#   ,          ,   #",
        "#                  #",
        "#                  #",
        " D                D ",
        " E    ##~~~~##    E ",
        "####################"]),
    dict(name='SUMP STAIR', area=5,
         exits=[('L', 2, 3, 22, 2), ('R', 7, 8, 25, -3), ('R', 12, 13, 24, -7)],
         objs=[('brinefin', 6, 12), ('limpet', 3, 3)], rows=[
        "##########",
        "##   ,  ##",
        " D      ##",
        " E      ##",
        "#####   ##",
        "##,     ##",
        "##    __##",
        "##      D ",
        "##__    E ",
        "##    ####",
        "##      ##",
        "##  __  ##",
        "##~~^~~~D ",
        "##wwwwwwE ",
        "##########",
        "##########"]),
    dict(name='THE DROWNED HALL', area=5, exits=[('L', 5, 6, 23, 7), ('R', 5, 6, 26, -1)],
         objs=[('item', 16, 2, I_FLASK, 10), ('brinefin', 6, 5), ('brinefin', 24, 5), ('limpet', 10, 4)], rows=[
        "################################",
        "#   ,        ,        ,        #",
        "#                              #",
        "#     __        __        __   #",
        "#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#",
        " Dwwwwwwww##wwwwwwww##wwwwwwwwD ",
        " Ewwww-www##www-wwww##wwww-wwwE ",
        "################################"]),
    dict(name='BOOT LOCKER', area=5, exits=[('L', 4, 5, 23, 3)],
         objs=[('item', 17, 5, I_BOOTS, 11), ('shellback', 10, 5), ('limpet', 15, 4)], rows=[
        "####################",
        "#   ,          ,   #",
        "#                  #",
        "#            __    #",
        " D       __        #",
        " E    ##       ##  #",
        "####################"]),
    dict(name='TIDE LOCK', area=5, exits=[('L', 4, 5, 24, 1), ('R', 4, 5, 27, 0)],
         objs=[('brinefin', 5, 4), ('brinefin', 10, 5)], rows=[
        "################",
        "#   ,      ,   #",
        "#              #",
        "#      __      #",
        " D~~~~~~~~~~~~D ",
        " EwwwwwwwwwwwwE ",
        "################"]),
    dict(name="OLD GULPER'S CISTERN", area=6, exits=[('L', 4, 5, 26, 0)],
         objs=[('gulper', 13, 4, I_WIDE, 12)], rows=[
        "####################",
        "#                  #",
        "#                  #",
        "#                  #",
        " D                 #",
        " E~~~~~~~~~~~~~~~~~#",
        "###### #############"]),
    # ---- the Orrery
    dict(name='ORRERY STAIR', area=7, exits=[('U', 4, 5, 14, 0), ('R', 13, 14, 29, -9)],
         objs=[('wisp', 4, 7)], rows=[
        "####  ####",
        "##      ##",
        "##  ##  ##",
        "##      ##",
        "## o  _ ##",
        "##      ##",
        "## _    ##",
        "##    , ##",
        "##   __ ##",
        "##      ##",
        "## _    ##",
        "## ,    ##",
        "##    _ ##",
        "##      D ",
        "##      E ",
        "##########"]),
    dict(name='GEAR HALL', area=7, exits=[('L', 4, 5, 28, 9), ('R', 4, 5, 30, -2)],
         objs=[('cogmite', 12, 5), ('wisp', 20, 2), ('orbit', 26, 5), ('lamp', 3, 5)], rows=[
        "################################",
        "#   o        ,        o        #",
        "#                              #",
        "#        __         __         #",
        " D                            D ",
        " E    ##      ##       ##     E ",
        "################################"]),
    dict(name='PENDULUM WELL', area=7, exits=[('L', 2, 3, 29, 2), ('D', 4, 5, 31, 0)],
         objs=[('wisp', 4, 5), ('orbit', 6, 12)], rows=[
        "##########",
        "##   o  ##",
        " D      ##",
        " E      ##",
        "#####   ##",
        "##,     ##",
        "##    __##",
        "##      ##",
        "##__    ##",
        "##    ####",
        "##    , ##",
        "##  __  ##",
        "##      ##",
        "#####   ##",
        "####    ##",
        "####  ####"]),
    dict(name='LENS GALLERY', area=7, exits=[('U', 4, 5, 30, 0), ('R', 4, 5, 32, 0)],
         objs=[('item', 8, 2, I_FLASK, 14), ('lens', 16, 5), ('cogmite', 11, 5)], rows=[
        "####  ##################",
        "#                 ,    #",
        "#   __                 #",
        "#       __     o       #",
        "#                     D ",
        "#  ,  ##              E ",
        "########################"]),
    dict(name="THE SNUFFER'S VAULT", area=8, exits=[('L', 4, 5, 31, 0), ('R', 4, 5, 33, 0)],
         seal=[13], objs=[('snuffer', 9, 1, I_FLASK, 13)], rows=[
        "####################",
        "#                  #",
        "#                  #",
        "#                  #",
        " D                 X",
        " E                 X",
        "####################"]),
    dict(name='THE GREAT LAMP', area=7, exits=[('L', 4, 5, 32, 0)], msg=1, rows=[
        "##########",
        "#  o   o #",
        "#        #",
        "#   lm   #",
        "    pq   #",
        "    PQ   #",
        "##########"]),
]
END_ROOM = next(i for i, r in enumerate(ROOMS) if r['name'] == 'THE GREAT LAMP')
N_ITEMS = sum(1 for r in ROOMS for o in r.get('objs', []) if len(o) == 5)
SIDES = {'L': EX_L, 'R': EX_R, 'U': EX_U, 'D': EX_D}


def pix_byte(left, right):
    return int(left, 16) | (int(right, 16) << 4)


def tile_bytes(art):
    """[byte 0-7][row 0-15] -> byte"""
    assert len(art) == 16 and all(len(r) == 16 for r in art), art
    return [[pix_byte(art[r][2 * j], art[r][2 * j + 1]) for r in range(16)] for j in range(8)]


class Area:
    def __init__(self, n):
        self.n = n
        self.tiles = COMMON_TILES + AREAS[n]['tiles']
        assert len(self.tiles) <= 32
        self.num = {ch: 8 * i for i, (ch, _, _) in enumerate(self.tiles)}
        self.bytes = {8 * i: tile_bytes(art) for i, (_, art, _) in enumerate(self.tiles)}
        self.attr = [0] * 256
        for i, (_, _, at) in enumerate(self.tiles):
            self.attr[8 * i] = at
        self.frames = list(COMMON)
        self.spec = list(COMMON_SPEC)
        for c in AREAS[n].get('creatures', []):
            name, art = c['name'], c['art']
            assert len(art) == 2
            w = len(art[0][0]) // 2
            assert w in (8, 16) and all(len(r) == 2 * w for a in art for r in a), name
            wide = w == 16
            self.spec.append((name, c['beh'], len(self.frames), c['hp'], c['dmg'], 1, 0 if wide else 2, w,
                              len(art[0]), c.get('spit', 0), 2 if wide else 0, c.get('aim', 0)))
            if wide:        # (it looks the same both ways) the left halves, then the right
                for half in (0, 1):
                    for k, a in enumerate(art):
                        self.frames.append(('%s_%d%d' % (name, half, k), [r[16 * half:16 * half + 16] for r in a]))
                continue
            for flip in (False, True):
                for k, a in enumerate(art):
                    self.frames.append(('%s_%s%d' % (name, 'LR'[not flip], k), [r[::-1] for r in a] if flip else a))
        assert len(self.spec) <= 16 and len(self.frames) <= 128
        self.kind = {sp[0]: i for i, sp in enumerate(self.spec)}
        self.frame_id = {nm: i for i, (nm, _) in enumerate(self.frames)}

    def spec_page(self):
        pg = bytearray(256)
        for i, sp in enumerate(self.spec):
            for off, k in ((SPEC_BEH, K_BEH), (SPEC_FRAME, K_FRAME), (SPEC_HP, K_HP), (SPEC_DMG, K_DMG),
                           (SPEC_ANIM, K_ANIM), (SPEC_DIRM, K_DIRM), (SPEC_W, K_W), (SPEC_H, K_H),
                           (SPEC_SPIT, K_SPIT), (SPEC_WIDE, K_WIDE), (SPEC_AIM, K_AIM)):
                pg[off + i] = sp[k]
        return bytes(pg)


class Room:
    def __init__(self, n):
        r = ROOMS[n]
        self.n = n
        self.r = r
        self.name = r['name']
        self.area = Area(r['area'])
        rows = r['rows']
        self.h = len(rows)
        self.w = len(rows[0])
        assert 10 <= self.w <= MAP_W and 7 <= self.h <= MAP_H, r['name']
        assert all(len(row) == self.w for row in rows), (r['name'], [len(row) for row in rows])
        self.map = bytearray([self.area.num['#']] * (MAP_W * MAP_H))
        for ty, row in enumerate(rows):
            for tx, ch in enumerate(row):
                if ch in ROCK:
                    inside, top, under = ROCK[ch]
                    if ty > 0 and rows[ty - 1][tx] not in ROCK:
                        ch = top
                    elif ty < self.h - 1 and rows[ty + 1][tx] not in ROCK:
                        ch = under
                    else:
                        ch = inside
                self.map[ty * MAP_W + tx] = self.area.num[ch]
        self.exits = [(SIDES[s], lo, hi, dest, delta) for s, lo, hi, dest, delta in r['exits']]
        assert len(self.exits) <= 8
        self.objs = []          # (kind, byte column, cell, parameter)
        for o in r.get('objs', []):
            tx, ty = o[1], o[2]
            assert not self.area.attr[self.map[ty * MAP_W + tx]] & A_SOLID, (r['name'], o)
            prm = 0
            if len(o) > 3:
                assert o[3] < len(ITEM_ART) and 0 < o[4] < 32, o
                prm = o[3] << 5 | o[4]
            if o[0] == 'item':
                self.objs.append((S_ITEM, tx * 8, ty * 16, prm))
            else:
                k = self.area.kind[o[0]]
                sp = self.area.spec[k]
                if sp[K_BEH] in (B_WALK, B_SIT):
                    below = self.map[(ty + sp[K_H] // 16) * MAP_W + tx]
                    assert self.area.attr[below] & A_TOP, (r['name'], o)
                self.objs.append((k, tx * 8, ty * 16, prm))
        assert len(self.objs) <= MAXOBJ, r['name']
        self.rw = self.w * 8 - NCOL
        self.rcy = self.h * 16 - NROW
        self.rwx = self.w * 8 - 8
        self.rhy = self.h * 16 - 16

    def header(self):
        h = bytearray(256)
        h[H_W], h[H_H], h[H_AREA] = self.w, self.h, self.r['area']
        h[H_RW], h[H_RCY], h[H_RWX], h[H_RHY] = self.rw, self.rcy, self.rwx, self.rhy
        h[H_FLAGS] = HF_HOT if self.r.get('hot') else 0
        seal = self.r.get('seal', [])
        assert len(seal) <= 4
        h[H_SEALN] = len(seal)
        h[H_SEAL:H_SEAL + len(seal)] = bytes(seal)
        h[H_MSG] = len(ITEM_MSG) + 2 + self.r['msg'] if 'msg' in self.r else 0
        for i, (side, lo, hi, dest, delta) in enumerate(self.exits):
            h[HX_SIDE + i], h[HX_LO + i], h[HX_HI + i] = side, lo, hi
            h[HX_DEST + i], h[HX_DELTA + i] = dest, delta & 255
        h[H_NOBJ] = len(self.objs)
        for i, (k, x, y, p) in enumerate(self.objs):
            h[HO_KIND + i], h[HO_X + i], h[HO_Y + i], h[HO_P + i] = k, x, y, p
        assert len(self.name) <= NAME_W
        h[H_NAME:H_NAME + NAME_W] = self.name.ljust(NAME_W).encode('ascii')
        return bytes(h)

    def file(self):
        return bytes(self.map) + self.header() + bytes(256)


def check_rooms():
    """every exit's edge tiles are open, lead to an exit back, and land in the open"""
    rooms = [Room(n) for n in range(len(ROOMS))]
    opp = {EX_L: EX_R, EX_R: EX_L, EX_U: EX_D, EX_D: EX_U}
    ids = [o[3] & 31 for rm in rooms for o in rm.objs if o[3]]
    assert len(ids) == len(set(ids)), 'two items with one number'
    for rm in rooms:
        ar = rm.area
        assert not any(ar.attr[t] & A_SOOT for t in rm.map[:MAP_W]), rm.name   # (a blast clears the block over)
        for side, lo, hi, dest, delta in rm.exits:
            d = rooms[dest]
            for p in range(lo, hi + 1):
                tx, ty = {EX_L: (0, p), EX_R: (rm.w - 1, p), EX_U: (p, 0), EX_D: (p, rm.h - 1)}[side]
                assert ar.attr[rm.map[ty * MAP_W + tx]] & (A_SOLID | A_SEAL) != A_SOLID, (rm.name, side, p)
                q = p + delta
                tx, ty = {EX_L: (d.w - 1, q), EX_R: (0, q), EX_U: (q, d.h - 1), EX_D: (q, 0)}[side]
                assert d.area.attr[d.map[ty * MAP_W + tx]] & (A_SOLID | A_SEAL) != A_SOLID, (rm.name, side, p, d.name)
                back = [e for e in d.exits if e[0] == opp[side] and e[1] <= q <= e[2] and e[3] == rm.n
                        and e[4] == -delta]
                assert back, (rm.name, side, p, d.name)
    return rooms


# ---------------------------------------------------------------------------
# the screen: tables, sprite routines, the model of the drawing
# ---------------------------------------------------------------------------
def rowx_table():
    return [row_x(i - 32) if 0 <= i - 32 < NROW else 0x10 for i in range(256)]


def vpg_table():
    return [0x61 + 2 * (i - 8) if 0 <= i - 8 < NCOL else 0x60 for i in range(256)]


ROWX_T = rowx_table()
VPG_T = vpg_table()


def background(area, tmap, sx, sy):
    """{address: byte} of the playfield for the camera (sx byte columns, sy cells)"""
    out = {}
    for col in range(NCOL):
        page = 0x6100 + col * 512
        x = sx + col
        for g in range(NROW):
            y = sy + g
            t = tmap[(y >> 4) * MAP_W + (x >> 3)]
            out[page + row_x(g)] = area.bytes[t][x & 7][y & 15]
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
        lines = ['    ld   [spy], ac              ; row %d' % r,
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
rl         = 0x21       ; where a tile routine returns
rh         = 0x22
tmp        = 0x23
tmp2       = 0x24
tmp3       = 0x25
sx         = 0x26       ; the camera: byte column and cell of the screen's corner
sy         = 0x27
px         = 0x28       ; the hero: left byte column (the box is px + 1 to px + 6)
py         = 0x29       ;   top cell
pyf        = 0x2A       ;   and 1/256 cell
vyl        = 0x2B       ; vertical speed, cells / 256 a frame, signed
vyh        = 0x2C
onground   = 0x2D
facing     = 0x2E       ; 0 right, 1 left
moving     = 0x2F       ; a walk key is down
inp        = 0x30       ; 1 right, 2 left, 4 jump, 8 fire, 16 up, 32 down
inp_prev   = 0x31
room       = 0x32
area       = 0x33       ; the area whose tiles are loaded (FF: none)
rw         = 0x34       ; the camera's largest sx, sy
rcy        = 0x35
rwx        = 0x36       ; px here: the right edge;  py here: the bottom edge
rhy        = 0x37
crawl      = 0x38
energy     = 0x39
emax       = 0x3A
hud_dirty  = 0x3B
ta_x       = 0x3C       ; tile_at: byte column, cell
ta_y       = 0x3D
ta_a       = 0x3E       ;   the tile's attributes
ta_pg      = 0x3F       ;   its place in the map
ta_i       = 0x40
sl_n       = 0x41       ; sprites in the list
s_i        = 0x42
sc         = 0x43       ; this sprite: byte column + 8, top cell + 32
spy        = 0x44
srl        = 0x45       ; where a sprite routine returns
srh        = 0x46
fcnt       = 0x47       ; frames
vpg        = 0x48       ; x48-x4F: video page of each of the sprite's 8 columns
ROWT       = 0x50       ; x50-x5F: video offset of each of the tile row's 16 cells
rowb       = 0x60       ; ROWX index of the tile row's first cell
mrow       = 0x61       ; the tile row's first map byte
mpg        = 0x62
mx         = 0x63
j0         = 0x64       ; the first tile's first byte column
o_i        = 0x65
SH_T       = 0x66       ; shots (3): frames left, byte column, cell, speeds
SH_X       = 0x69
SH_Y       = 0x6C
SH_DX      = 0x6F
SH_DY      = 0x72
door_t     = 0x75       ; frames the open door stays open (0: none)
door_pg    = 0x76       ;   its upper tile in the map
door_i     = 0x77
door_x     = 0x78       ;   its byte column
ex_side    = 0x79
ex_pos     = 0x7A
ex_i       = 0x7B
ex_d       = 0x7C
sv_lo      = 0x7D       ; side_free's return address
sv_hi      = 0x7E
items      = 0x7F       ; the power-ups found: 1 Burrow Rig, 2 Updraft Bellows, 4 Ash Sail
tcnt       = 0x80       ; byte columns left of the tile being drawn
ob_i       = 0x81       ; the thing being moved, and a copy of it:
ob_k       = 0x82       ;   its kind (0: none)
ob_x       = 0x83       ;   byte column, cell
ob_y       = 0x84
ob_d       = 0x85       ;   0 right, 2 left (an item: its type)
ob_t       = 0x86       ;   its timer
ob_hp      = 0x87       ;   hits left
ob_p       = 0x88       ;   an item: type << 5 | number
ob_b       = 0x89       ;   what it does (B_...)
inv        = 0x8A       ; frames Wick cannot be hurt
ajump      = 0x8B       ; the jump in the air is used
chg        = 0x8C       ; the Kiln Charge: frames the fire key is held
blast_i    = 0x8D       ; 1 + the shot that is a blast (0: none)
wet        = 0x8E
touchf     = 0x8F       ; the thing touches Wick
'''


def sd_frags():
    """the free stretches of video RAM, [start, end): offsets x040-x17F of
    each byte column but column 0 (where the blitter's off-screen columns
    write) and offset x110 (where off-playfield rows write)"""
    out = []
    for c in range(1, 80):
        base = SD_OVL + 512 * c
        out += [(base + 0x40, base + 0x110), (base + 0x111, base + 0x180)]
    return out


def strip_lines(vals, nxt, loop=None):
    """a tile's byte column: 16 stores through ROWT, the next column's
    page, then the next byte column of the tile (nxt) or back to the row
    loop (after the tile's last, or with the carry: past column 79).
    loop: a label; the routine draws tcnt columns (a tile whose byte
    columns are all the same)"""
    lines = ['    ld   [colpage], y']
    ac = None
    i = 0
    while i < 16:
        v = vals[i]
        run = 1
        while i + run < 16 and vals[i + run] == v:
            run += 1
        if ac == v:
            lines += ['    ld   [ROWT + %d], x' % i, '    ld   ac, [y,x]']
            i += 1
        elif run >= 3:
            lines.append('    ld   0x%02X, ac' % v)
            ac = v
        else:
            lines += ['    ld   [ROWT + %d], x' % i, '    ld   0x%02X, [y,x]' % v]
            i += 1
    lines += ['    ld   [colpage], ac', '    add  2, ac', '    ld   ac, [colpage]']
    if loop:
        lines += ['    bcs  %s_x' % loop, '    ld   [tcnt], ac', '    dec', '    ld   ac, [tcnt]',
                  '    bne  %s' % loop, '%s_x:' % loop]
    elif nxt:
        lines += ['    bcs  %s_x' % nxt, '    ld   %s >> 8, y' % nxt, '    jmp  %s' % nxt, '%s_x:' % nxt]
    lines += ['    ld   [rh], y', '    jmp  [rl]']
    return lines


# ---------------------------------------------------------------------------
# the music player (placard_mus.masm), assembled apart: its code in
# LAMP.PLC (x2500-x28FF), in every area file (the area block's x3B00-x3DFF,
# x5800-x59FF and the last N_RESERVE stretches of the video RAM), its
# tables in LAMP.PLC.  It runs in map FF with its own x60-x8F (lamp_code.masm,
# "music").
# ---------------------------------------------------------------------------
N_RESERVE = 17
MUS_SYMS = ('mus_init', 'mus_play', 'mus_frame', 'mus_stop', 'mus_sfx')
_MUS = []


def player_regions():
    vid = []                # (the 16 bytes of a stretch past a page end are left: one
    for a, b in sd_frags()[-N_RESERVE:]:    # window a page for asm_expand)
        vid.append((a, min(b, (a & 0xFF00) + 0x100)))
    return ([(PCODE_C, MUS_TABLES), (SONG_GAP, SONG_GAP + 0x200), (PCODE_A, FR), (PCODE_B, PCODE_B + 0x200)] + vid
            + [(FR + 0xB0, FR + 0x100), (SPEC + 0xB0, SPEC + 0x100)])   # (FR: 48 frames; SPEC to xAF)


def music_module():
    """the music player, assembled for this memory map -> ({addr: byte}, symbols)"""
    if not _MUS:
        src = '''#include "placard.asm"
#include "zeropage.asm"
MUS_TABLES = 0x%04X
MUS_RAM    = 0x%04X
.prefix lmu
.region 0x%04X, 0x%04X, 1, ram, pack
.include "placard_mus.masm"
''' % (MUS_TABLES, MUS_RAM, PCODE_C, MUS_TABLES)
        name = os.path.join(HERE, 'lamp_mus.masm')
        head, chunks = asm_expand.expand(src, name)
        regs = [(a, b, 1, 0) for a, b in player_regions()]
        for c in chunks:
            if c.fixed is None:
                c.regions, c.region = regs, regs[0]
        asm_expand.place(chunks, name)
        mem, syms, _ = ps.assemble(asm_expand.render(head, chunks, name), HERE)
        own = dict(mem)             # (assembled without the library: every byte is the player's)
        for ad in own:
            assert any(a <= ad < b for a, b in player_regions()) or MUS_TABLES <= ad < MUS_TABLES + 0xA00, \
                'player byte at x%04X' % ad
        _MUS.append((own, {k: syms[k] for k in MUS_SYMS}))
    return _MUS[0]


def area_file(n):
    """-> (bytes of An.TS, info): the area block (song, player code, the
    tables), x5800-x59FF (player code), then the RAM from x6000 (the tile
    routines and the sprite routines, and the player's code in the last
    stretches)"""
    import lamp_music
    ar = Area(n)
    frags = sd_frags()[:-N_RESERVE]
    free = [f[0] for f in frags]
    state = [0, 0]
    out = ['#include "placard.asm"', ZP, 'ROWX = 0x0100']

    def fit(size, span=None):
        """the first stretch with size bytes free (it becomes the one in
        use) -> the address; span (from, to): those bytes of the routine
        hold a branch and its target, so they must be in one page"""
        for i, f in enumerate(frags):
            a = free[i]
            if span:
                while (a + span[0]) >> 8 != (a + span[1]) >> 8:
                    a += 1
            if f[1] - a >= size:
                free[i] = a
                state[0] = i
                state[1] = max(state[1], i)
                return a
        raise AssertionError('area %d: past the video RAM' % n)

    def take(size):
        ad = free[state[0]]
        free[state[0]] += size
        return ad

    nstrip = 0
    for i, (ch, art, at) in enumerate(ar.tiles):
        tb = ar.bytes[8 * i]
        if all(tb[j] == tb[0] for j in range(8)):
            # every byte column the same: one routine that draws tcnt columns
            lines = ['t%d_%d:' % (i, j) for j in range(8)] + strip_lines(tb[0], None, loop='t%d_0' % i)
            size = Asm.size(lines)
            fit(size, span=(0, size - 1))
            out.append('#addr 0x%04X' % take(size))
            out.extend(lines)
            nstrip += 1
            continue
        for j in range(8):
            lines = strip_lines(tb[j], 't%d_%d' % (i, j + 1) if j < 7 else None)
            size = Asm.size(lines)
            fit(size, span=(size - 10, size - 4) if j < 7 else None)
            out.append('#addr 0x%04X' % take(size))
            out.append('t%d_%d:' % (i, j))
            out.extend(lines)
            nstrip += 1
    nhop = 0
    same = {}
    alias = {}
    for fi, (name, art) in enumerate(ar.frames):
        if tuple(art) in same:      # (a creature that looks the same both ways)
            alias[name] = same[tuple(art)]
            continue
        same[tuple(art)] = name
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
                    nhop += 1
                    lb = 'hp_%d' % nhop
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
    ts_lo, ts_hi = [0] * 256, [0] * 256
    for i in range(len(ar.tiles)):
        for j in range(8):
            ad = syms['t%d_%d' % (i, j)]
            ts_lo[8 * i + j], ts_hi[8 * i + j] = ad & 255, ad >> 8
    fr = [0] * 256
    for fi, (name, art) in enumerate(ar.frames):
        ad = syms['spr_' + alias.get(name, name)]
        fr[fi], fr[128 + fi] = ad & 255, ad >> 8
    blk = bytearray(AREA_END - AREA_BLK)
    for ad, b in ((FR, fr), (SPEC, ar.spec_page()), (TS_LO, ts_lo), (TS_HI, ts_hi), (ATTR, ar.attr)):
        blk[ad - AREA_BLK:ad - AREA_BLK + 256] = bytes(b)
    song = lamp_music.area_song(n)
    assert len(song) <= SONG_END - SONG, 'area %d: the song is %d bytes' % (n, len(song))
    assert not any(song[SONG_GAP - SONG:SONG_GAP - SONG + 0x200]), 'area %d: instruments past F or custom waves' % n
    blk[SONG - AREA_BLK:SONG - AREA_BLK + len(song)] = song
    pl = music_module()[0]
    for ad, b in pl.items():
        if AREA_BLK <= ad < AREA_END:
            blk[ad - AREA_BLK] = b
    pb = bytes(pl.get(a, 0) for a in range(PCODE_B, PCODE_B + 0x200))
    block = bytes(blk) + pb
    whole = dict(mem)
    whole.update((ad, b) for ad, b in pl.items() if ad >= SD_OVL)
    top = SD_OVL + ((max(whole) - SD_OVL) // 512 + 1) * 512
    image = bytes(whole.get(a, 0) for a in range(SD_OVL, top))
    info = dict(area=ar, used=len(mem), frags_used=state[1] + 1, nfrags=len(frags), strips=nstrip,
                image=mem, syms=syms, fr=fr)
    return block + image, info


# ---------------------------------------------------------------------------
# the rules, in Python: the bot plans with them and the test compares the
# program with them on every frame
# ---------------------------------------------------------------------------
class Model:
    def __init__(self, rooms, title=False):
        self.rooms = rooms
        self.mode = M_TITLE if title else M_PLAY
        self.saved = self.card = None     # the last save lamp (room, x, y); what the card holds
        self.room = START_ROOM
        self.px, self.py, self.pyf, self.vy = START_X, START_Y, 0, 0
        self.onground = self.facing = self.moving = self.crawl = 0
        self.inp = self.fcnt = 0
        self.energy, self.emax = START_ENERGY, START_EMAX
        self.items = self.inv = self.ajump = self.msg = self.msg_t = self.chg = self.blast = self.wet = 0
        self.got = bytearray(64)
        self.shots = [[0, 0, 0, 0, 0] for _ in range(3)]    # t, x, y, dx, dy
        self.door_t = self.door_c = self.door_x = 0
        self.sx = self.sy = 0
        self.enter(self.room)
        self.camera()

    def clone(self):
        m = Model.__new__(Model)
        m.__dict__.update(self.__dict__)
        m.map = bytearray(self.map)
        m.shots = [list(s) for s in self.shots]
        m.objs = [list(o) for o in self.objs]
        m.got = bytearray(self.got)
        return m

    def enter(self, n):
        self.room = n
        self.rm = self.rooms[n]
        self.map = bytearray(self.rm.map)
        self.attr = self.rm.area.attr
        self.shots = [[0, 0, 0, 0, 0] for _ in range(3)]
        self.door_t = self.blast = 0
        self.spec = self.rm.area.spec
        if n == END_ROOM:
            self.mode = M_END
        if self.seal_check() and 'msg' in self.rm.r:
            self.msg, self.msg_t = len(ITEM_MSG) + 2 + self.rm.r['msg'], MSG_FRAMES
        self.objs = [[0] * 7 for _ in range(MAXOBJ)]    # kind, x, y, d, t, hp, p
        for o, (k, x, y, p) in zip(self.objs, self.rm.objs):
            if p and self.got[p & 31]:
                continue
            o[:] = [k, x, y, p >> 5 if k == S_ITEM else 0, 0, self.spec[k][K_HP], p]

    def seal_check(self):
        """the room's seal opens when its keepers are beaten"""
        seal = self.rm.r.get('seal')
        if not seal:
            return True
        if not all(self.got[G_BEAT + n] for n in seal):
            return False
        for i in range(MAP_W * MAP_H):
            if self.attr[self.map[i]] & A_SEAL:
                self.map[i] = 0
        return True

    def beh(self, o):
        return self.spec[o[0]][K_BEH]

    def touch(self, o):
        sp = self.spec[o[0]]
        return (((self.px - o[1] + 5) & 255) < sp[K_W] + 3
                and ((self.py - o[2] + 13) & 255) < sp[K_H] + (5 if self.crawl else 13))

    def spawn(self, blast):
        """a spark (or a blast) from the lantern, in the first free place"""
        for i, s in enumerate(self.shots):
            if not s[0]:
                s[0] = SHOT_FRAMES
                if self.inp & IN_UP:
                    s[1:] = [(self.px + 3) & 255, (self.py - 4) & 255, 0, 0xFC]
                elif self.facing:
                    s[1:] = [self.px, (self.py + 6) & 255, 0xFE, 0]
                else:
                    s[1:] = [(self.px + 7) & 255, (self.py + 6) & 255, 2, 0]
                if blast:
                    self.blast = i + 1
                    break
                if self.blast == i + 1:
                    self.blast = 0
                if self.items & IT_WIDE:        # the Wide Flame: one each side of it, where there is room
                    spread = 0xFF
                    for j, q in enumerate(self.shots):
                        if not q[0]:
                            q[:] = s
                            q[3 if not s[3] else 4] = spread
                            spread = 1
                            if self.blast == j + 1:
                                self.blast = 0
                break

    def hurt(self, o):
        if not self.inv:
            dmg = self.spec[o[0]][K_DMG]
            if self.items & IT_COAT:
                dmg = (dmg + 1) >> 1
            self.energy = max(self.energy - dmg, 0)
            self.inv = INV_FRAMES
            if not self.crawl:
                self.vy = -HURTV

    def front(self, o, row):
        """the thing cannot step the way it faces -> (blocked?, the byte column in front)"""
        if o[3] == 0:
            if o[1] >= self.rm.rwx:
                return True, 0
            fx = o[1] + self.spec[o[0]][K_W]
        else:
            if o[1] < 2:
                return True, 0
            fx = o[1] - 1
        return bool(self.solid(fx, o[2] + row)), fx

    def restart(self):
        room, self.px, self.py = self.saved or (START_ROOM, START_X, START_Y)
        self.pyf = self.vy = 0
        self.crawl = self.inv = 0
        self.energy = START_ENERGY
        self.msg, self.msg_t = len(ITEM_MSG) + 1, MSG_FRAMES
        self.enter(room)
        self.camera()

    def again(self, title):
        """a new game, or the title (the card stays as it is)"""
        card, inp = self.card, self.inp
        self.__init__(self.rooms, title)
        self.card, self.inp = card, inp

    def go_on(self):
        """the game saved on the card"""
        self.again(False)
        room, self.px, self.py, self.items, self.emax, got = self.card
        self.got = bytearray(got)
        self.saved = (room, self.px, self.py)
        self.energy = self.emax
        self.enter(room)
        self.camera()

    def obj_step(self, o):
        b = self.beh(o)
        touch = self.touch(o)
        if b == B_ITEM:
            if touch:
                self.got[o[6] & 31] = 1
                if o[3] == I_FLASK:
                    self.emax += FLASK
                else:
                    self.items |= 1 << (o[3] - 1)
                self.energy = self.emax
                self.msg, self.msg_t = o[3] + 1, MSG_FRAMES
                o[0] = 0
            return
        if b == B_LAMP:
            if touch and not o[4]:          # saved, once a visit
                o[4] = 1
                self.saved = (self.room, self.px, self.py)
                self.energy = self.emax
                self.msg, self.msg_t = len(ITEM_MSG) + 2 + len(ROOM_MSG), MSG_FRAMES
                self.card = (self.room, self.px, self.py, self.items, self.emax, bytes(self.got))
            return
        if b == B_EMBER:
            o[4] -= 1
            if not o[4]:
                o[0] = 0
            elif touch:
                self.energy = min(self.energy + EMBER, self.emax)
                o[0] = 0
            return
        if b == B_PUFF:
            o[4] -= 1
            if not o[4]:
                if o[6]:                    # what it guarded; its keeper is beaten
                    o[0], o[3] = S_ITEM, o[6] >> 5
                    self.got[G_BEAT + (o[6] & 31)] = 1
                    self.seal_check()
                elif self.fcnt & 1:
                    o[0], o[4] = S_EMBER, EMBER_FRAMES
                else:
                    o[0] = 0
            return
        sp = self.spec[o[0]]
        if b == B_BOLT:
            o[4] -= 1
            if not o[4]:
                o[0] = 0
                return
            if o[3] == 4:                   # down
                if self.solid(o[1] + 2, o[2] + 8):
                    o[0] = 0
                    return
                o[2] = (o[2] + 2) & 255
            elif self.front(o, 4)[0]:
                o[0] = 0
                return
            else:
                o[1] += -2 if o[3] else 2
            if touch:
                self.hurt(o)
                o[0] = 0
            return
        if b == B_WALK:
            if self.fcnt & 1:
                blocked, fx = self.front(o, sp[K_H] - 4)
                if blocked or not self.solid(fx, o[2] + sp[K_H]):
                    o[3] ^= 2
                else:
                    o[1] += -1 if o[3] else 1
        elif b == B_FLY:
            o[4] = (o[4] + 1) & 63
            if o[4] & 1:
                if self.front(o, 8)[0]:
                    o[3] ^= 2
                else:
                    o[1] += -1 if o[3] else 1
            elif o[4] & 32:                 # down for 16 frames, up for 16
                if not self.solid(o[1] + 4, o[2] + 16):
                    o[2] = (o[2] + 1) & 255
            elif not self.solid(o[1] + 4, o[2] - 1):
                o[2] = (o[2] - 1) & 255
        elif b == B_SIT:
            o[3] = 2 if self.px < o[1] else 0
        elif b == B_DROP:
            if not o[4]:
                if (self.px - o[1] + DROP_NEAR) & 255 < 2 * DROP_NEAR + 1:
                    o[4] = 1
            elif self.solid(o[1] + 4, o[2] + 16):
                o[0], o[3], o[4] = S_PUFF, 0, PUFF_FRAMES
                return
            else:
                o[2] = (o[2] + 3) & 255
        elif b == B_HOP:
            t = o[4]
            if t < HOP_REST:
                o[4] = t + 1
                if o[4] == HOP_REST:
                    o[3] = 2 if self.px < o[1] else 0
            else:
                if t < HOP_REST + 16:
                    dy = HOPDY[t - HOP_REST]
                    o[4] = t + 1
                    if not self.front(o, 8)[0]:
                        o[1] += -1 if o[3] else 1
                else:
                    dy = 4
                if dy < 0:
                    if not self.solid(o[1] + 4, o[2] + dy):
                        o[2] = (o[2] + dy) & 255
                else:
                    o[2] = (o[2] + dy) & 255
                    if self.solid(o[1] + 4, o[2] + 16):
                        o[2] = (((o[2] + 16) & 0xF8) - 16) & 255
                        o[4] = 0
        elif b == B_HOVER:
            if self.fcnt & 1 or (sp[K_AIM] & 2 and o[5] < sp[K_HP] >> 1):    # (wounded: every frame)
                a = (o[1] + sp[K_W] // 2 - 4) & 255
                if self.px != a:
                    o[3] = 2 if self.px < a else 0
                    if not self.front(o, 8)[0]:
                        o[1] += -1 if o[3] else 1
        if sp[K_SPIT]:
            o[4] = (o[4] + 1) & 255
            mask = sp[K_SPIT]
            if sp[K_AIM] & 2 and o[5] < sp[K_HP] >> 1:     # (wounded: twice as often)
                mask >>= 1
            if not o[4] & mask:
                for q in self.objs:
                    if not q[0]:
                        left = self.px < o[1]
                        if sp[K_AIM]:
                            q[:] = [S_BOLT, (o[1] + sp[K_W] // 2 - 2) & 255, (o[2] + sp[K_H]) & 255, 4,
                                    BOLT_FRAMES, 0, 0]
                        else:
                            q[:] = [S_BOLT, (o[1] - 4 if left else o[1] + sp[K_W]) & 255,
                                    (o[2] + 4 + ((o[4] >> 2) & (sp[K_H] - 16))) & 255, 2 if left else 0,
                                    BOLT_FRAMES, 0, 0]
                        break
        if touch:
            self.hurt(o)

    def at(self, x, y):
        """(solid?, attributes, map index) of byte column x, cell y"""
        i = ((y & 255) >> 4) * MAP_W + ((x & 255) >> 3)
        a = self.attr[self.map[i]]
        return (a & A_BOT) if y & 8 else (a & A_TOP), a, i

    def solid(self, x, y):
        return self.at(x, y)[0]

    def side_free(self, x):
        ys = (8, 15) if self.crawl else (0, 8, 15)
        return not any(self.solid(x, self.py + d) for d in ys)

    def find_exit(self, side, pos):
        for e in self.rm.exits:
            if e[0] == side and e[1] <= pos <= e[2]:
                return e
        return None

    def close_door(self):
        self.map[self.door_c] = T_DT
        self.map[self.door_c + MAP_W] = T_DB
        self.door_t = 0

    def open_door(self, a, i):
        if self.door_t:
            self.close_door()
        if a & A_DBOT:
            i -= MAP_W
        self.door_c = i
        self.map[i] = T_DOT
        self.map[i + MAP_W] = T_DOB
        self.door_t = DOOR_FRAMES
        self.door_x = (i & 31) * 8

    def do_exit(self, e):
        side, lo, hi, dest, delta = e
        self.enter(dest)
        if side == EX_L:
            self.px = self.rm.rwx - 1
            self.py = (self.py + 16 * delta) & 255
        elif side == EX_R:
            self.px = 1
            self.py = (self.py + 16 * delta) & 255
        elif side == EX_U:
            self.py, self.pyf = self.rm.rhy - 1, 0
            self.px = (self.px + 8 * delta) & 255
        else:
            self.py, self.pyf = 0, 0
            self.px = (self.px + 8 * delta) & 255
        if side in (EX_L, EX_R):
            _, a, i = self.at(8 if side == EX_R else self.rm.rwx - 8, self.py + 8)
            if a & A_DOOR:
                self.open_door(a, i)
        self.camera()

    def camera(self):
        self.sx = min(max(self.px - CAM_X, 0), self.rm.rw)
        self.sy = min(max(self.py - CAM_Y, 0), self.rm.rcy)

    def step(self, inp):
        """one frame with the input bits inp"""
        prev, self.inp = self.inp, inp
        if self.mode:                       # the title, the ending: wait for a key
            if inp & IN_JUMP and not prev & IN_JUMP:
                self.again(self.mode == M_END)
            elif self.mode == M_TITLE and inp & IN_FIRE and not prev & IN_FIRE and self.card:
                self.go_on()
            return
        self.fcnt = (self.fcnt + 1) & 255
        # crawling
        if inp & IN_DOWN and self.onground and self.items & IT_RIG:
            self.crawl = 1
        elif self.crawl and not (self.solid(self.px + 1, self.py) or self.solid(self.px + 6, self.py)):
            self.crawl = 0
        # under water (the tile at his middle), without the Ballast Boots
        self.wet = 0 if self.items & IT_BOOTS else self.at(self.px + 4, self.py + 8)[1] & A_WATER
        # sideways
        d = 1 if inp & IN_RIGHT else (-1 if inp & IN_LEFT else 0)
        self.moving = 1 if d else 0
        if d:
            self.facing = 0 if d > 0 else 1
        go = (self.fcnt & 1) if self.crawl or self.wet else (self.fcnt & 3) != 3
        if d > 0 and go:
            if self.side_free(self.px + 7):
                self.px += 1
                if self.px >= self.rm.rwx:
                    e = self.find_exit(EX_R, (self.py + 8) >> 4)
                    if e:
                        return self.do_exit(e)
                    self.px -= 1
        elif d < 0 and go:
            if self.px == 0:
                e = self.find_exit(EX_L, (self.py + 8) >> 4)
                if e:
                    return self.do_exit(e)
            elif self.side_free(self.px):
                self.px -= 1
        # jumping, gravity
        if inp & IN_JUMP:
            if not prev & IN_JUMP and not self.crawl:
                if self.onground:
                    self.vy = -(WETV if self.wet else JUMPV)
                elif self.items & IT_BELLOWS and not self.ajump:
                    self.vy = -AIRV
                    self.ajump = 1
        elif self.vy < -JUMP_CUT:
            self.vy = -JUMP_CUT
        self.vy += GRAV
        cap = SAILV if self.items & IT_SAIL and inp & IN_JUMP else MAXFALL
        if self.vy >= cap:
            self.vy = cap
        old = self.py
        y = ((self.py << 8 | self.pyf) + self.vy) & 0xFFFF
        self.py, self.pyf = y >> 8, y & 255
        if self.vy < 0:
            self.onground = 0
            if self.py > old:
                e = self.find_exit(EX_U, (self.px + 4) >> 3)
                if e:
                    return self.do_exit(e)
                self.py = self.pyf = self.vy = 0
            else:
                top = self.py + 8 * self.crawl
                if self.solid(self.px + 1, top) or self.solid(self.px + 6, top):
                    self.py = (top & 0xF8) + 8 - 8 * self.crawl
                    self.pyf = self.vy = 0
        else:
            land = False
            if self.py >= self.rm.rhy:
                e = self.find_exit(EX_D, (self.px + 4) >> 3)
                if e:
                    return self.do_exit(e)
                self.py = self.rm.rhy
                land = True
            elif self.solid(self.px + 1, self.py + 16) or self.solid(self.px + 6, self.py + 16):
                self.py = ((self.py + 16) & 0xF8) - 16
                land = True
            if land:
                self.pyf = self.vy = 0
                self.onground = 1
                self.ajump = 0
            else:
                self.onground = 0
        self.camera()
        # shots
        for n, s in enumerate(self.shots):
            if not s[0]:
                continue
            s[0] -= 1
            if not s[0]:
                continue
            s[1] = (s[1] + s[3]) & 255
            s[2] = (s[2] + s[4]) & 255
            if (s[1] - self.sx) & 255 >= NCOL or (s[2] - self.sy) & 255 >= NROW:
                s[0] = 0
                continue
            hit, a, i = self.at(s[1], s[2])
            blast = self.blast == n + 1
            if hit:
                if a & A_DOOR:
                    self.open_door(a, i)
                elif a & A_SOOT and blast:       # (and a sooted block right over it)
                    self.map[i] = 0
                    if self.attr[self.map[i - MAP_W]] & A_SOOT:
                        self.map[i - MAP_W] = 0
                s[0] = 0
                continue
            for o in self.objs:
                sp = self.spec[o[0]]
                if (o[0] and sp[K_BEH] >= B_WALK and (s[1] - o[1]) & 255 < sp[K_W]
                        and (s[2] - o[2]) & 255 < sp[K_H]):
                    s[0] = 0
                    o[5] = max(o[5] - (BLAST_PW if blast else 1), 0)
                    if not o[5]:
                        o[0], o[3], o[4] = S_PUFF, 0, PUFF_FRAMES
                    break
        if inp & IN_FIRE and not prev & IN_FIRE and not self.crawl:
            self.spawn(False)
        elif self.items & IT_KILN:          # the fire key held fills the charge; let go when full: a blast
            if inp & IN_FIRE:
                if self.chg != CHG_FULL:
                    self.chg += 1
            else:
                full = self.chg == CHG_FULL
                self.chg = 0
                if full and not self.crawl:
                    self.spawn(True)
        # the door shuts again
        if self.door_t:
            self.door_t -= 1
            if not self.door_t:
                if (self.px - self.door_x + 6) & 255 < 13:
                    self.door_t = 1
                else:
                    self.close_door()
        # the room's things
        for o in self.objs:
            if o[0]:
                self.obj_step(o)
        if self.inv:
            self.inv -= 1
        if self.rm.r.get('hot') and not self.items & IT_COAT and not self.fcnt & 15 and self.energy:
            self.energy -= 1
        if not self.energy:
            self.restart()
        # the message line
        if self.msg_t:
            self.msg_t -= 1
            if not self.msg_t:
                self.msg = 0

    def sprites(self):
        """the sprite list: [(frame id, SL_C, SL_G)]"""
        if self.mode == M_TITLE:
            return []
        if self.crawl:
            f = F_CRAWL
        elif not self.onground:
            f = F_JUMP
        elif self.moving:
            f = F_RUN1 + ((self.fcnt >> 3) & 1)
        else:
            f = F_STAND
        out = []
        if not self.inv & 2:
            out.append((f + NPF * self.facing, (self.px - self.sx + 8) & 255, (self.py - self.sy + 32) & 255))
        for n, s in enumerate(self.shots):
            if s[0]:
                out.append((F_BLAST if self.blast == n + 1 else F_SHOT, (s[1] - self.sx + 8) & 255,
                            (s[2] - self.sy + 32) & 255))
        for o in self.objs:
            c, g = (o[1] - self.sx + 8) & 255, (o[2] - self.sy + 32) & 255
            if o[0] and c < 88 and g < 144:
                sp = self.spec[o[0]]
                f = sp[K_FRAME] + ((self.fcnt >> 3) & sp[K_ANIM]) + (o[3] & sp[K_DIRM])
                out.append((f, c, g))
                if sp[K_WIDE] and c + 8 < 88:
                    out.append((f + sp[K_WIDE], c + 8, g))
        return out


def pad_to_inp(btn):
    inp = 0
    for b, i in ((PAD_RIGHT, IN_RIGHT), (PAD_LEFT, IN_LEFT), (PAD_UP, IN_UP), (PAD_DOWN, IN_DOWN),
                 (PAD_B | PAD_A, IN_JUMP), (PAD_Y | PAD_X, IN_FIRE)):
        if btn & b:
            inp |= i
    return inp


# ---------------------------------------------------------------------------
# the program
# ---------------------------------------------------------------------------
def data_lines(vals):
    return ['    #d8 ' + ', '.join('0x%02X' % v for v in vals[i:i + 16]) for i in range(0, len(vals), 16)]


def input_tests():
    out = []
    n = [0]

    def test(src, mask, bit, down_is_zero=False, also=None):
        n[0] += 1
        lb = 'in_%d' % n[0]
        out.append('    ld   [%s], ac' % src)
        out.append('    and  0x%02X, ac' % mask)
        if also:
            out.append('    bne  %s_s' % lb)
            out.append('    ld   [%s], ac' % also[0])
            out.append('    and  0x%02X, ac' % also[1])
        out.append('    %s  %s' % ('bne' if down_is_zero else 'beq', lb))
        if also:
            out.append('%s_s:' % lb)
        out.extend(['    ld   [inp], ac', '    or   %d, ac' % bit, '    ld   ac, [inp]', '%s:' % lb])

    test('R0', 0x80, IN_RIGHT)
    test('R0', 0x40, IN_LEFT)
    test('R0', 0x10, IN_UP)
    test('R0', 0x20, IN_DOWN)
    test('R0', 0x01, IN_JUMP, also=('R1', 0x01))
    test('R0', 0x02, IN_FIRE, also=('R1', 0x02))
    test('KBD_NOW + 7', 0x80, IN_RIGHT, True)
    test('KBD_NOW + 7', 0x20, IN_LEFT, True)
    test('KBD_NOW + 6', 0x20, IN_UP, True)
    test('KBD_NOW + 7', 0x40, IN_DOWN, True)
    test('KBD_NOW + 7', 0x04, IN_JUMP, True)     # Space
    test('KBD_NOW + 5', 0x04, IN_JUMP, True)     # Z
    test('KBD_NOW + 5', 0x08, IN_FIRE, True)     # X
    return '\n'.join(out)


def masm():
    """the program's source, for asm_expand"""
    here = os.path.join(HERE, 'lamp_code.masm')
    src = open(here).read()
    consts = dict(MODE_PF=MODE_PF, LINE_GO=LINE_GO, GRAV=GRAV, JUMPV_LO=(-JUMPV) & 255,
                  JUMPV_HI=((-JUMPV) >> 8) & 255, MAXFALL_HI=MAXFALL >> 8, SHOT_FRAMES=SHOT_FRAMES,
                  DOOR_FRAMES=DOOR_FRAMES, CAM_X=CAM_X, CAM_Y=CAM_Y, START_ROOM=START_ROOM, START_X=START_X,
                  START_Y=START_Y, START_ENERGY=START_ENERGY, IN_RIGHT=IN_RIGHT, IN_LEFT=IN_LEFT,
                  IN_JUMP=IN_JUMP, IN_FIRE=IN_FIRE, IN_UP=IN_UP, IN_DOWN=IN_DOWN, A_DOOR=A_DOOR,
                  A_DBOT=A_DBOT, EX_L=EX_L, EX_R=EX_R, EX_U=EX_U, EX_D=EX_D, TS_LO=TS_LO, TS_HI=TS_HI,
                  ATTR=ATTR, FR=FR, AREA_BLK=AREA_BLK, AREA_END=AREA_END, PCODE_B=PCODE_B, PROG2_END=PROG2_END, MAP=MAP, HDR=HDR, SL=SL, SL_LO=SL_LO, SL_HI=SL_HI,
                  SL_C=SL_C, SL_G=SL_G, H_AREA=H_AREA, H_RW=H_RW, H_RCY=H_RCY, H_RWX=H_RWX, H_RHY=H_RHY,
                  HX_SIDE=HX_SIDE, HX_LO=HX_LO, HX_HI=HX_HI, HX_DEST=HX_DEST, HX_DELTA=HX_DELTA,
                  H_NAME=H_NAME, T_DT=T_DT, T_DB=T_DB, T_DOT=T_DOT, T_DOB=T_DOB, NPF=NPF, F_RUN1=F_RUN1,
                  F_JUMP=F_JUMP, F_CRAWL=F_CRAWL, F_SHOT=F_SHOT, START_EMAX=START_EMAX, FLASK=FLASK,
                  EMBER=EMBER, AIRV_LO=(-AIRV) & 255, AIRV_HI=((-AIRV) >> 8) & 255,
                  HURTV_HI=((-HURTV) >> 8) & 255, INV_FRAMES=INV_FRAMES, PUFF_FRAMES=PUFF_FRAMES,
                  EMBER_FRAMES=EMBER_FRAMES, MSG_FRAMES=MSG_FRAMES, MAXOBJ=MAXOBJ, SPEC=SPEC,
                  SPEC_BEH=SPEC_BEH, SPEC_FRAME=SPEC_FRAME, SPEC_HP=SPEC_HP, SPEC_DMG=SPEC_DMG,
                  SPEC_ANIM=SPEC_ANIM, SPEC_DIRM=SPEC_DIRM, SPEC_W=SPEC_W, SPEC_H=SPEC_H,
                  SPEC_SPIT=SPEC_SPIT, SPEC_WIDE=SPEC_WIDE, S_BOLT=S_BOLT, BOLT_FRAMES=BOLT_FRAMES,
                  DROP_NEAR=DROP_NEAR, SPEC_AIM=SPEC_AIM, CHG_FULL=CHG_FULL, BLAST_PW=BLAST_PW,
                  HOP_REST=HOP_REST, A_SOOT=A_SOOT, IT_KILN=IT_KILN, IT_WIDE=IT_WIDE, IT_COAT=IT_COAT,
                  IT_BOOTS=IT_BOOTS, F_BLAST=F_BLAST, H_FLAGS=H_FLAGS, HF_HOT=HF_HOT, V_MSG=V_MSG,
                  V_MSG_T=V_MSG_T, V_MSG_D=V_MSG_D, OBJ=OBJ, O_KIND=O_KIND, O_X=O_X, O_Y=O_Y, O_D=O_D, O_T=O_T, O_HP=O_HP,
                  O_P=O_P, GOT=GOT, HO_KIND=HO_KIND, HO_X=HO_X, HO_Y=HO_Y, HO_P=HO_P, B_WALK=B_WALK,
                  S_ITEM=S_ITEM, S_EMBER=S_EMBER, S_PUFF=S_PUFF, IT_SAIL=IT_SAIL, SAILV=SAILV, IT_RIG=IT_RIG, IT_BELLOWS=IT_BELLOWS,
                  M_DEAD=len(ITEM_MSG) + 1, A_WATER=A_WATER, A_SEAL=A_SEAL, H_SEALN=H_SEALN, H_SEAL=H_SEAL,
                  H_MSG=H_MSG, G_BEAT=G_BEAT, V_MODE=V_MODE, V_SAVED=V_SAVED, V_SROOM=V_SROOM, V_SX=V_SX, V_SY=V_SY,
                  V_SITEMS=V_SITEMS, V_SEMAX=V_SEMAX, V_FR=V_FR, V_SEC=V_SEC, V_MIN=V_MIN, V_HASSAVE=V_HASSAVE,
                  M_SAVE=len(ITEM_MSG) + 2 + len(ROOM_MSG), END_ROOM=END_ROOM, N_ITEMS=N_ITEMS, M_TITLE=M_TITLE, M_END=M_END, WETV_LO=(-WETV) & 255, WETV_HI=((-WETV) >> 8) & 255,
                  SONG=SONG, ZSAVE=ZSAVE, SFX_BEEP=SFX_BEEP, SFX_NOISE=SFX_NOISE)
    assert HURTV & 255 == 0
    msgs = [''] + ITEM_MSG + [MSG_DEAD] + ROOM_MSG + [MSG_SAVE]
    assert all(len(m) <= NAME_W for m in msgs)
    mtext = '\n'.join(('.chunk\n' if i and i % 5 == 0 else '') + 's_m%d: #d "%s", 0x00' % (i, m.ljust(NAME_W))
                      for i, m in enumerate(msgs))
    mtab = ('m_lo: #d8 ' + ', '.join('s_m%d & 0xFF' % i for i in range(len(msgs)))
            + '\nm_hi: #d8 ' + ', '.join('s_m%d >> 8' % i for i in range(len(msgs))))
    head = ['; lamp.asm - LAMPLIGHTER, made by gen_lamp.py from lamp_code.masm: do not edit', ';']
    for ln in __doc__.strip().split('\n')[1:]:
        head.append(('; ' + ln).rstrip())
    head += ['', '#include "placard.asm"', '#include "placard_lib.asm"', 'dos_back = 0x8008', 'fs_save = 0x8020', ZP]
    head += ['%-10s = 0x%04X       ; the music player' % (k, v) for k, v in music_module()[1].items()]
    head += ['%-11s = %d' % kv for kv in consts.items()]
    rowt = '\n'.join(('    ld   [rowb], x' if k == 0 else '    ld   [rowb], ac\n    add  %d, x' % k)
                     + '\n    ld   [y,x], ac\n    ld   ac, [ROWT + %d]' % k for k in range(16))
    vpgs = '\n'.join('    ld   [sc], ac\n    add  %d, x\n    ld   [y,x], ac\n    ld   ac, [vpg + %d]' % (k, k)
                     for k in range(8))
    src = (src.replace('@@ROWX@@', '\n'.join(data_lines(ROWX_T)))
           .replace('@@VPG@@', '\n'.join(data_lines(VPG_T)))
           .replace('@@ROWT@@', rowt).replace('@@VPGS@@', vpgs).replace('@@INPUT@@', input_tests())
           .replace('@@MSGS@@', mtext).replace('@@MTAB@@', mtab)
           .replace('@@NITEMS@@', str(N_ITEMS)).replace('@@HOPDY@@', ', '.join('0x%02X' % (v & 255) for v in HOPDY)))
    assert '@@' not in src
    return '\n'.join(head) + '\n' + src


def program():
    """-> (lamp.asm source, memory, symbols)"""
    head, chunks = asm_expand.expand(masm(), os.path.join(HERE, 'lamp.masm'))
    asm_expand.place(chunks, 'lamp.masm')
    text = asm_expand.render(head, chunks, 'lamp.masm')
    mem, syms, _ = ps.assemble(text, HERE)
    top = {}
    for c in chunks:
        if c.region:
            top[c.region[0]] = max(top.get(c.region[0], 0), c.addr + c.size)
    return text, mem, syms, top


def sd_files():
    """-> (LAMP.PLC, {'LAMP/...': bytes}, symbols, info)"""
    import gen_plc
    rooms = check_rooms()
    text, mem, syms, top = program()
    lib, _, _ = ps.assemble(open(os.path.join(HERE, 'rom_lib.asm')).read(), HERE)
    own = gen_plc.own_bytes(mem, lib)
    for ad in own:
        assert 0x0100 <= ad < PCODE_C and not 0x1F00 <= ad < 0x2000, 'LAMP.PLC: a byte at x%04X' % ad
    own.update((ad, b) for ad, b in music_module()[0].items() if ad < AREA_BLK)
    data = bytes(own.get(ad, 0) for ad in range(0x0100, max(own) + 1))
    plc = gen_plc.header(0, 0x0100, len(data), syms['main']) + data
    files = {}
    areas = []
    for n in range(len(AREAS)):
        files['LAMP/A%d.TS' % n], ai = area_file(n)
        areas.append(ai)
    for rm in rooms:
        files['LAMP/R%02X.RM' % rm.n] = rm.file()
    files['LAMP/SAVE.DAT'] = bytes(256)     # a blank save: the card's writer never grows a folder
    return plc, files, syms, dict(src=text, top=top, areas=areas, rooms=rooms)


def render_room(rm, path, scale=2):
    """the whole room as a picture"""
    from PIL import Image
    im = Image.new('RGB', (rm.w * 16, rm.h * 16))
    mem = bytearray(65536)
    for g in range(NROW):
        mem[0x5A20 + 32 + 4 * g: 0x5A20 + 36 + 4 * g] = bytes([MODE_PF] * 4)
    tmp = path + '.tmp.png'
    for sy in range(0, rm.h * 16, NROW):
        sy = min(sy, rm.rcy)
        for sx in range(0, rm.w * 8, NCOL):
            sx = min(sx, rm.rw)
            for ad, v in background(rm.area, rm.map, sx, sy).items():
                mem[ad] = v
            ps.render(mem, tmp)
            shot = Image.open(tmp).convert('RGB').crop((0, 32, 640, 480)).resize((160, 112), Image.NEAREST)
            im.paste(shot, (sx * 2, sy))
    os.remove(tmp)
    im.resize((im.width * scale, im.height * scale), Image.NEAREST).save(path)


def preview(outdir, rooms):
    os.makedirs(outdir, exist_ok=True)
    for rm in rooms:
        render_room(rm, os.path.join(outdir, 'room%02X.png' % rm.n))


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('-o', default=os.path.join(HERE, 'lamp.asm'))
    ap.add_argument('--sdcard', default=os.path.join(HERE, '..', '..', 'sdcard'))
    ap.add_argument('--preview', help='a folder for pictures of every room')
    args = ap.parse_args(argv)
    plc, files, syms, info = sd_files()
    open(args.o, 'w', newline='\n').write(info['src'])
    open(os.path.join(args.sdcard, 'LAMP.PLC'), 'wb').write(plc)
    for name, data in files.items():
        path = os.path.join(args.sdcard, *name.split('/'))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, 'wb').write(data)
    print('wrote %s, LAMP.PLC (%d bytes; code to %s)'
          % (args.o, len(plc), ', '.join('x%04X' % v for v in sorted(info['top'].values()))))
    for n, ai in enumerate(info['areas']):
        print('  LAMP/A%d.TS %d bytes: %d tile columns and %d sprite frames, %d bytes in %d of %d stretches'
              % (n, len(files['LAMP/A%d.TS' % n]), ai['strips'], len(ai['area'].frames), ai['used'],
                 ai['frags_used'], ai['nfrags']))
    print('  %d rooms' % len(info['rooms']))
    if args.preview:
        preview(args.preview, info['rooms'])
        print('wrote the room pictures to', args.preview)


if __name__ == '__main__':
    main(sys.argv[1:])

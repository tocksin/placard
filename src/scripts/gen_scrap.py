#!/usr/bin/env python3
"""
gen_scrap.py - the data of SCRAPWRIGHT (scrap.masm, SCRAP.PLC): cell art,
the cell types' names, info lines and actions, and the hand-made wreck

    python3 gen_scrap.py        writes scrap_types.asm, scrap_data.masm
                                and scrap_map.bin (the map pages; gen_plc.py
                                puts them in ../../sdcard/SCRAP.OVL)

SCRAPWRIGHT is a top-down salvage game (design: the SCRAPWRIGHT proposal
doc; docs/software/SCRAP.md).  Phase 2 is a wreck to walk through: the
tug docked to a derelict, doors, the item panel and the mouse.  Phase 3
adds parts to cut free and carry, the tug's worth and air, and rooms
with air (rooms(): the room of every cell, the doors between rooms, the
rooms a breach drains; encode(): the room and bolted bits in the map).

THE SCREEN
    lines 0-383    4 bpp, 2x: 20 x 12 cells, a cell is 8 x 16 pixels
                   (4 bytes across, 16 line pairs: 64 bytes)
    lines 384-479  1 bpp, 2x: the panel, 6 text rows of 80 (text rows
                   24-29 of the tracker's layout)

THE MAP
    96 x 64 cells in 16 x 16-cell chunks, 6 across and 4 down.  Chunk k
    (k = 6 * (y >> 4) + (x >> 4)) is two even video pages: x60 + 4k holds
    the cells' types, x62 + 4k their flags (bits 3:0 damage in 16ths,
    6.25 % a step; an item stops working at step 8 = 50 %; the room and
    bolted bits: encode()).  A cell is at
    index 16 * (y & 15) + (x & 15) of both pages.  SCRAP.OVL is the even
    pages x60, x62 ... xBE in order (48 pages, 12 KB), then the code pages
    from xC0 (gen_plc.py --overlay); scrap.masm reads it
    into place (a sector holds two pages).  The chunk layout is the one the
    card paging of a later phase will use.

THE ART
    Cell type t: 64 bytes at ART + 64 t, column-major: byte 16 c + r is
    pixels 2c (low nibble, shown first) and 2c + 1 (high nibble) of line
    pair r.  Colors are the 4 bpp palette (docs/video/COLORS.md).

Date: 2026-11-04
"""

import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SDCARD = os.path.join(HERE, '..', '..', 'sdcard')

MAP_W, MAP_H = 96, 64
CHUNKS_X = 6
MAP_PAGE = 0x60
VIEW_W, VIEW_H = 20, 12
TUG_DX = 10                         # the tug's cells, x from its plan
TUG_LOCK = (19 + TUG_DX, 32)        # docked: the airlocks side by side,
WRECK_LOCK = (30, 32)               # always aligned
START = (7 + TUG_DX, 32)            # the player, in the tug's corridor

# ------------------------------------------------------------------
# the cell art: 8 x 16 pixels, one hex digit (palette index) per pixel
# ------------------------------------------------------------------
ART = {
    'space': ['11111111'] * 16,
    'star': ['11111111'] * 5 + ['111A1111'] + ['11111111'] * 6 + ['11111131'] + ['11111111'] * 3,
    'floor': ['77777770', '7B777770', '77777770', '77777770', '77777770',
              '77777770', '77777770', '77777770', '77777770', '77777770',
              '77777770', '77777770', '77777770', '77777B70', '77777770',
              '00000000'],
    'wall': ['ABBBBBBB', 'ABBBBBBB', 'BB7BBBB7', 'BBBBBBBB', 'BBBBBBBB',
             'BBBBBBBB', 'BBBBBBBB', '77777777', 'ABBBBBBB', 'BBBBBBBB',
             'BBBB7BBB', 'BBBBBBBB', 'BBBBBBBB', 'BBBBBBBB', 'BBBBBBBB',
             '77777777'],
    'door': ['BBBBBBBB', 'B666666B', 'B666666B', 'B6D66D6B', 'B666666B',
             'B666666B', 'BE0E0E0B', 'B0E0E0EB', 'BE0E0E0B', 'B666666B',
             'B666666B', 'B6D66D6B', 'B666666B', 'B666666B', 'B666666B',
             'BBBBBBBB'],
    'dooro': ['BBBBBBBB', 'B677776B', 'B677776B', 'B677776B', 'B677776B',
              'B677776B', 'B677776B', 'B677776B', 'B677776B', 'B677776B',
              'B677776B', 'B677776B', 'B677776B', 'B677776B', 'B677776B',
              'BBBBBBBB'],
    'o2': ['777BB777', '77BAAB77', '78888887', '8A888888', '8A888888',
           '8A888838', '8A888838', '8A888838', '8A888838', '8A888838',
           '8A888838', '88888838', '88888888', '78888887', '77777777',
           '77777777'],
    'react': ['BBBBBBBB', 'B777777B', 'B79FF97B', '79FEEF97', '9FEAAEF9',
              '9FEAAEF9', '9FEAAEF9', '9FEAAEF9', '9FEAAEF9', '9FEAAEF9',
              '79FEEF97', 'B79FF97B', 'B777777B', 'B7E7E77B', 'B777777B',
              'BBBBBBBB'],
    'batt': ['77777777', '77B77B77', '7BBBBBB7', '7B0000B7', '7B0EE0B7',
             '7B0EE0B7', '7B0000B7', '7B0EE0B7', '7B0EE0B7', '7B0000B7',
             '7B0EE0B7', '7B0EE0B7', '7B0000B7', '7BBBBBB7', '77777777',
             '77777777'],
    'crate': ['66666666', '6D6666D6', '66D66D66', '666DD666', '666DD666',
              '66D66D66', '6D6666D6', '66666666', 'DDDDDDDD', '66666666',
              '6D6666D6', '66D66D66', '666DD666', '66D66D66', '6D6666D6',
              '66666666'],
    'bunk': ['77777777', '7BBBBBB7', '7BAAAAB7', '7BAAAAB7', '7B2222B7',
             '7B2222B7', '7B2222B7', '7B2222B7', '7B2222B7', '7B2222B7',
             '7B2222B7', '7B2222B7', '7B2222B7', '7BBBBBB7', '77777777',
             '77777777'],
    'helm': ['77777777', 'BBBBBBBB', 'B333333B', 'B388883B', 'B383383B',
             'B388883B', 'B333333B', 'BBBBBBBB', '7B4E9FB7', '7BBBBBB7',
             '77777777', '777BB777', '77BBBB77', '77B22B77', '77B22B77',
             '77777777'],
    'locker': ['BBBBBBBB', 'B777777B', 'B7BBBB7B', 'B7B77B7B', 'B7BBBB7B',
               'B777777B', 'B777777B', 'B77E777B', 'B777777B', 'B777777B',
               'B7BBBB7B', 'B7B77B7B', 'B7BBBB7B', 'B777777B', 'BBBBBBBB',
               '77777777'],
    'turret': ['BBBBBBBB', 'BB7777BB', 'B777777B', 'B744447B', '74444447',
               '744DD447', '74DAAD47', '74DAAD47', '744DD447', '74444447',
               'B744447B', 'B777777B', 'BBB44BBB', 'BBB44BBB', 'BBB44BBB',
               'BBB77BBB'],
    'pipe': ['77777770', '7B777770', '77777770', '77777770', '77777770',
             '77777770', '77777770', 'EEEEEEEE', '6666666E', '77777770',
             '77777770', '77777770', '77777770', '77777B70', '77777770',
             '00000000'],
    'vent': ['00000007', '07000007', '00000007', '00000007', '00000007',
             '00000007', '00000007', '00000007', '00000007', '00000007',
             '00000007', '00000007', '00000007', '00000700', '00000007',
             '77777777'],
    'lock': ['BBBBBBBB', 'B888888B', 'B8BBBB8B', 'B8B77B8B', 'B8B77B8B',
             'B8B77B8B', 'B8B77B8B', 'B8B77B8B', 'B8B77B8B', 'B8B77B8B',
             'B8B77B8B', 'B8B77B8B', 'B8B77B8B', 'B8BBBB8B', 'B888888B',
             'BBBBBBBB'],
    'player_ns': ['77766777', '77666677', '776CC677', '77CCCC77', '77CCCC77',
                  '777CC777', '73333337', '33333333', '3333E333', 'C333333C',
                  'C333333C', '77333377', '77377377', '77377377', '77677677',
                  '77777777'],   # the player without the suit (PL_NOSUIT, not a type)
    'suit': ['77777777', '77AAAA77', '7AA11AA7', '7A1111A7', '7AA11AA7',
             '77AAAA77', '7BAAAAB7', 'BAAAAAAB', 'BAA88AAB', 'BAAAAAAB',
             '7BAAAAB7', '77AAAA77', '7AA77AA7', '7AA77AA7', '7BB77BB7',
             '77777777'],
    'thrust': ['11BBBB11', '1BB77BB1', '1B7777B1', '1B7777B1', '1B7777B1',
               '1BB77BB1', '11BBBB11', '11B77B11', '1BB77BB1', '1B7777B1',
               '1DDDDDD1', '11DEED11', '11DEED11', '111DD111', '1111D111',
               '11111111'],
    'fuel': ['77666677', '76DDDD67', '6DDDDDD6', '6D6666D6',
             '6DDDDDD6', '6DDDDDD6', '6DDDDDD6', '6D6666D6', '6DDDDDD6',
             '6DDDDDD6', '6DDDDDD6', '6D6666D6', '6DDDDDD6', '76DDDD67',
             '77666677', '77777777'],
    'scrub': ['77777777', 'BBBBBBBB', 'B898989B', 'B989898B', 'B898989B',
              'B989898B', 'B898989B', 'B989898B', 'B898989B', 'B989898B',
              'B898989B', 'B989898B', 'BBBBBBBB', '7B7777B7', '7B7777B7',
              '77777777'],
    'o2e': ['777BB777', '77BAAB77', '7BBBBBB7', 'B7BBBBBB', 'B7BBBBBB',
            'B7BBBB0B', 'B7BBBB0B', 'B7BBBB0B', 'B7BBBB0B', 'B7BBBB0B',
            'B7BBBB0B', 'BBBBBB0B', 'BBBBBBBB', '7BBBBBB7', '77777777',
            '77777777'],
    'cutter': ['77777770', '777E7770', '777E7770', '77BEB770', '77BBB770',
               '77BAB770', '77BBB770', '77BBB770', '77B4B770', '77BBB770',
               '7B666B70', '7B666B70', '7B666B70', '77BBB770', '77777770',
               '00000000'],
    'panel': ['77777770', '7BBBBBB0', '7BABBBB0', '7BBBBBB0', '7BBBB7B0',
              '7BBBBBB0', '7BBBBBB0', '7777777B', '7BABBBB0', '7BBBBBB0',
              '7BBBBBB0', '7BBB7BB0', '7BBBBBB0', '7BBBBBB0', '77777770',
              '00000000'],
    'doork': ['77777770', '7BBBBBB0', '7B6666B0', '7B6D6DB0', '7B6666B0',
              '7BE0E0B0', '7B0E0EB0', '7BE0E0B0', '7B6666B0', '7B6D6DB0',
              '7B6666B0', '7B6666B0', '7BBBBBB0', '77777770', '77777770',
              '00000000'],
    'plate': ['11111111', '1777777B', '17B77B7B', '1777777B', '1777777B',
              '1777777B', '1777777B', '1777777B', '1777777B', '1777777B',
              '1777777B', '1777777B', '17B77B7B', '1777777B', '1BBBBBBB',
              '11111111'],
    'player': ['77777777', '77AAAA77', '7AA88AA7', '7A8888A7', '7AA88AA7',
               '77AAAA77', '7BAAAAB7', 'BAAAAAAB', 'BAAEEAAB', 'BAAAAAAB',
               '7BAAAAB7', '77AAAA77', '7AA77AA7', '7AA77AA7', '7BB77BB7',
               '77777777'],
    'breach': ['11111111', '11111111', '1111A111', '11111111', '11111111',
               '11111111', '11111111', '1A111111', '11111111', '11111111',
               '11111111', '11111111', '11111111', '111111A1', '11111111',
               '11111111'],
}

# a broken part, wall or deck (damage from 50 %): its art with this crack
# in black ('#'), so it looks broken (scrap.masm crack_cell; the inventory's
# ip_art)
CRACK = ['.....#..', '.....#..', '....#...', '....#...', '...##...', '...#....',
         '..#.....', '..##....', '...#....', '...#....', '....#...', '...##...',
         '..#..#..', '..#...#.', '.#......', '.#......']
BROKEN_STEP = 8


def crack_bytes():
    """the crack as 64 AND masks in the art's order (byte 16 c + r)"""
    out = bytearray(64)
    for c in range(4):
        for r in range(16):
            lo = 0x0 if CRACK[r][2 * c] == '#' else 0xF
            hi = 0x0 if CRACK[r][2 * c + 1] == '#' else 0xF
            out[16 * c + r] = lo | hi << 4
    return bytes(out)


def broken_art(art):
    """the art bytes of a broken one"""
    return bytes(a & m for a, m in zip(art, crack_bytes()))


# the inventory's mouse pointer: art pixels from its tip (0 black, A white)
POINTER = ['0....', '00...', '0A0..', '0AA0.', '0AAA0', '0A000', '00...', '0....']


# ------------------------------------------------------------------
# the cell types: art, name, flags, info lines (\x02 = sealed or leaking
# for a wall or door: seal(); \x01 = "works at" the
# damage allows), menu actions, the inspect line
# ------------------------------------------------------------------
F_WALK = 0x01       # the player can stand on it (open space too: a spacewalk)
F_DMG = 0x02        # it has a damage score worth showing
F_ITEM = 0x04       # a part or tool that can be cut free and carried
F_INST = 0x08       # a part that can be installed in the tug (a ship system)
F_STRUCT = 0x10     # the ship itself: a wall, deck or door (UNINSTALL / CUT FREE)
F_SOLID = 0x20      # not air: the rooms end at it
F_VAC = 0x40        # vacuum: a room next to it leaks

A_OPEN, A_CLOSE, A_INSPECT, A_WALK = 1, 2, 3, 4
A_PICK, A_CUT, A_PUTL, A_PUTR, A_PUTB, A_REFILL = 5, 6, 7, 8, 9, 10
A_HOLD, A_INSTALL, A_UNINST, A_LAY = 11, 12, 13, 14
A_REPAIR, A_SKILLS, A_SUITOFF, A_SUITON = 15, 16, 17, 18
A_INV = 19
ACTIONS = {A_OPEN: 'OPEN', A_CLOSE: 'CLOSE', A_INSPECT: 'INSPECT', A_WALK: 'WALK HERE',
           A_PICK: 'PICK UP', A_CUT: 'CUT FREE', A_PUTL: 'PUT DOWN LEFT',
           A_PUTR: 'PUT DOWN RIGHT', A_PUTB: 'PUT DOWN BACK',
           A_REFILL: 'REFILL SUIT', A_HOLD: 'HOLD OPEN', A_INSTALL: 'INSTALL',
           A_UNINST: 'UNINSTALL', A_LAY: 'LAY DECK PLATE', A_REPAIR: 'REPAIR',
           A_SKILLS: 'SKILLS', A_SUITOFF: 'TAKE OFF SUIT', A_SUITON: 'PUT ON SUIT',
           A_INV: 'INVENTORY'}

TYPES = [
    # key, art, name, flags, info lines, actions, inspect
    ('SPACE', 'space', 'OPEN SPACE', F_WALK | F_SOLID | F_VAC,
     ['VACUUM.  NO AIR, NO FLOOR.', 'LAY A DECK PLATE HERE TO BUILD ON IT',
      'SPACEWALK: YOUR SUIT AIR ONLY'], [A_WALK, A_INSPECT],
     'NOTHING OUT THERE BUT DEBRIS AND COLD.'),
    ('STAR', 'star', 'OPEN SPACE', F_WALK | F_SOLID | F_VAC,
     ['VACUUM.  NO AIR, NO FLOOR.', 'LAY A DECK PLATE HERE TO BUILD ON IT',
      'SPACEWALK: YOUR SUIT AIR ONLY'], [A_WALK, A_INSPECT],
     'A DISTANT STAR.  NOT FOR SALE.'),
    ('FLOOR', 'floor', 'DECK PLATE', F_WALK | F_DMG | F_STRUCT,
     ['STEEL DECK PLATE', 'WALKABLE', 'TAKEN UP, IT LEAVES OPEN SPACE',
      'SKILL: MECHANICAL'], [A_WALK, A_INSPECT],
     'SCUFFED DECK PLATE.  SOMEONE WALKED HERE A LOT.'),
    ('WALL', 'wall', 'BULKHEAD', F_DMG | F_STRUCT | F_SOLID,
     ['STEEL BULKHEAD, LEAKS FROM 50% DAMAGE', '\x02',
      'UNINSTALL IT (IN A WRECK: A CUTTER)', 'SKILL: MECHANICAL'], [A_INSPECT],
     'A SOLID BULKHEAD.  THE PAINT SAYS DECK 2.'),
    ('DOOR', 'door', 'DOOR (CLOSED)', F_DMG | F_STRUCT | F_SOLID,
     ['PRESSURE DOOR, LEAKS FROM 50% DAMAGE', '\x02',
      'CLOSES BEHIND YOU UNLESS HELD OPEN', 'SKILLS: MECHANICAL, HYDRAULICS'],
     [A_OPEN, A_HOLD, A_INSPECT],
     'A PRESSURE DOOR.  THE HAZARD STRIPES ARE FADED.'),
    ('DOORO', 'dooro', 'DOOR (OPEN)', F_WALK | F_DMG | F_STRUCT | F_SOLID,
     ['PRESSURE DOOR, OPEN', '\x02', 'CLOSES BEHIND YOU UNLESS HELD OPEN',
      'SKILLS: MECHANICAL, HYDRAULICS'], [A_CLOSE, A_HOLD, A_INSPECT],
     'AN OPEN PRESSURE DOOR.'),
    ('O2', 'o2', 'O2 TANK', F_DMG | F_ITEM | F_INST,
     ['CAPACITY 120 L, FULL', '\x01', 'HEAVY.  SKILL: HYDRAULICS',
      'REFILLS A SUIT ONCE (LESS IF DAMAGED)'], [A_INSPECT],
     'AN OXYGEN TANK.  THE GAUGE STILL MOVES.'),
    ('REACT', 'react', 'REACTOR CORE', F_DMG,
     ['FUSION CORE, 40 KW', '\x01', 'TOO HEAVY TO CARRY WHOLE',
      'SKILLS: NUCLEAR, ELECTRICAL'], [A_INSPECT],
     'A REACTOR CORE.  IT IS HUMMING VERY QUIETLY.'),
    ('BATT', 'batt', 'BATTERY', F_DMG | F_ITEM | F_INST,
     ['STORAGE CELL, 8 KWH', '\x01', 'HEAVY.  SKILL: ELECTRICAL',
      'INSTALLED ON THE TUG: CHARGES YOUR SUIT'], [A_INSPECT],
     'A SHIP BATTERY.  STILL WARM.'),
    ('CRATE', 'crate', 'CARGO CRATE', F_DMG | F_ITEM,
     ['SEALED CARGO CRATE', 'CONTENTS UNKNOWN', 'OPEN IT TO SEE (LATER PHASE)',
      'SKILL: MECHANICAL'], [A_INSPECT],
     'THE LABEL READS "MINING CHARGES - DO NOT DROP".'),
    ('BUNK', 'bunk', 'BUNK', F_DMG | F_ITEM | F_INST,
     ['CREW BUNK', '\x01', 'LIGHT SCRAP', 'SKILL: MECHANICAL'], [A_INSPECT],
     'A CREW BUNK.  THE BLANKET IS FOLDED NEATLY.'),
    ('HELM', 'helm', 'HELM CONSOLE', F_DMG | F_ITEM | F_INST,
     ['FLIGHT CONSOLE', '\x01', 'HOLDS THE SHIP LOG (LATER PHASE)',
      'SKILLS: COMPUTERS, ELECTRICAL'], [A_INSPECT],
     'THE HELM.  THE LAST LOG ENTRY IS 212 DAYS OLD.'),
    ('LOCKER', 'locker', 'LOCKER', F_DMG | F_ITEM | F_INST,
     ['STEEL LOCKER, 4 SLOTS', '\x01', 'MAY HOLD GEAR (LATER PHASE)', 'SKILL: MECHANICAL'], [A_INSPECT],
     'A LOCKER.  THE LOCK IS RUSTED SHUT.'),
    ('TURRET', 'turret', 'SECURITY TURRET', F_DMG | F_SOLID,
     ['WALL TURRET, ARC TYPE', '\x01', 'DORMANT - NO POWER', 'SKILLS: COMPUTERS, MECHANICAL'], [A_INSPECT],
     'A SECURITY TURRET.  ITS LIGHT IS DARK, FOR NOW.'),
    ('PIPE', 'pipe', 'POWER CONDUIT', F_WALK | F_DMG,
     ['CONDUIT UNDER THE DECK', '\x01', 'CARRIES POWER BETWEEN PARTS', 'SKILL: ELECTRICAL'], [A_WALK, A_INSPECT],
     'A POWER CONDUIT RUNS UNDER THE DECK HERE.'),
    ('VENT', 'vent', 'DECK (NO AIR)', F_WALK | F_DMG,
     ['DECK PLATE IN VACUUM', 'THIS ROOM HAS LOST ITS AIR', 'YOUR SUIT AIR ONLY', 'SKILL: MECHANICAL'], [A_WALK, A_INSPECT],
     'FROST ON THE DECK.  THE AIR IS GONE.'),
    ('LOCK', 'lock', 'AIRLOCK', F_WALK | F_DMG | F_SOLID,
     ['DOCKING AIRLOCK', '\x01', 'JOINS THE TUG TO THE WRECK',
      'SKILLS: MECHANICAL, HYDRAULICS'], [A_WALK, A_INSPECT],
     'A DOCKING AIRLOCK.  THE SEAL IS HOLDING.'),
    ('SUIT', 'suit', 'WORK SUIT', F_DMG | F_ITEM,
     ['MK1 WORK SUIT, 90 L OF O2', '\x01', 'PUT IT ON: HOVER YOURSELF, PUT ON SUIT',
      'SKILL: MECHANICAL'], [A_INSPECT],
     'YOUR WORK SUIT.  IT SMELLS OF HARD WORK.'),
    ('THRUST', 'thrust', 'THRUSTER', F_DMG | F_SOLID | F_ITEM,
     ['MAIN THRUSTER, 2 KN', '\x01', 'GOES ON OPEN SPACE BY THE HULL',
      'SKILLS: MECHANICAL, HYDRAULICS'], [A_INSPECT],
     'A THRUSTER NOZZLE, BLACK WITH SOOT.'),
    ('FUEL', 'fuel', 'FUEL TANK', F_DMG | F_ITEM | F_INST,
     ['FUEL TANK, 400 L', '\x01', 'HEAVY: TAKES ONE CARRY SLOT', 'SKILL: HYDRAULICS'], [A_INSPECT],
     'A FUEL TANK.  IT SLOSHES WHEN YOU KNOCK.'),
    ('SCRUB', 'scrub', 'AIR SCRUBBER', F_DMG | F_ITEM | F_INST,
     ['CO2 SCRUBBER', '\x01', 'WITH AN O2 TANK INSTALLED: AIR',
      'SKILLS: HYDRAULICS, ELECTRICAL'], [A_INSPECT],
     'AN AIR SCRUBBER.  THE FILTERS NEED CHANGING.'),
    ('BREACH', 'breach', 'HULL BREACH', F_WALK | F_SOLID | F_VAC,
     ['A HOLE IN THE HULL', 'AIR ESCAPES THROUGH HERE', 'YOU CAN CLIMB OUT THROUGH IT'],
     [A_WALK, A_INSPECT],
     'SOMETHING PUNCHED RIGHT THROUGH THE HULL.'),
    ('O2E', 'o2e', 'EMPTY O2 TANK', F_DMG | F_ITEM | F_INST,
     ['CAPACITY 120 L, EMPTY', '\x01', 'HEAVY.  SKILL: HYDRAULICS',
      'A STATION REFILLS IT (LATER PHASE)'], [A_INSPECT],
     'AN EMPTY OXYGEN TANK.  THE GAUGE READS ZERO.'),
    ('CUTTER', 'cutter', 'PLASMA CUTTER', F_DMG | F_ITEM,
     ['HAND TOOL: UNINSTALLS IN A WRECK', '\x01', 'WORKS FROM A HAND.  SKILL: ELECTRICAL',
      'EACH CUT USES 5% OF THE SUIT BATTERY'], [A_INSPECT],
     'A PLASMA CUTTER.  KEEP YOUR FINGERS CLEAR.'),
    ('PANEL', 'panel', 'WALL PANEL', F_DMG | F_ITEM | F_INST,
     ['A BULKHEAD SECTION, TAKEN OUT', '\x02', 'HEAVY.  SKILL: MECHANICAL',
      'INSTALLED, IT IS A WALL'], [A_INSPECT],
     'A SECTION OF BULKHEAD.  THE BOLT HOLES ARE CLEAN.'),
    ('DOORK', 'doork', 'PRESSURE DOOR', F_DMG | F_ITEM | F_INST,
     ['A DOOR AND ITS FRAME, TAKEN OUT', '\x02', 'HEAVY.  SKILLS: MECH., HYDRAULICS',
      'INSTALLED, IT IS A CLOSED DOOR'], [A_INSPECT],
     'A PRESSURE DOOR IN ITS FRAME, READY TO FIT.'),
    ('PLATE', 'plate', 'SPARE PLATE', F_DMG | F_ITEM,
     ['A DECK PLATE, TAKEN UP', '\x01', 'LAY IT ON OPEN SPACE NEXT TO YOU',
      'SKILL: MECHANICAL'], [A_INSPECT],
     'A STEEL DECK PLATE.  IT RINGS WHEN YOU TAP IT.'),
    ('PLAYER', 'player', 'YOU', 0, [], [], ''),
]
TYPE = {t[0]: i for i, t in enumerate(TYPES)}
# the player's skills: the ones a part needs set how long a job on it takes
# (uninstall, install, repair); a job done raises them (job_start, sk_gain)
SKILLS = ['MECHANICAL', 'ELECTRICAL', 'NUCLEAR', 'COMPUTERS', 'HYDRAULICS', 'SUIT']
SK_M, SK_E, SK_N, SK_C, SK_H, SK_SUIT = 1, 2, 4, 8, 16, 32
SKILL_START = 10                    # every skill at the start (0-99)
SKILL_MAX = 99
SK_LV, SK_PR = 0x36E0, 0x36E8       # in RAM (ACT_PAGE): the levels, their progress
NEEDS = {'FLOOR': SK_M, 'WALL': SK_M, 'DOOR': SK_M | SK_H, 'DOORO': SK_M | SK_H,
         'O2': SK_H, 'O2E': SK_H, 'REACT': SK_N | SK_E, 'BATT': SK_E, 'CRATE': SK_M,
         'BUNK': SK_M, 'HELM': SK_C | SK_E, 'LOCKER': SK_M, 'TURRET': SK_C | SK_M,
         'PIPE': SK_E, 'VENT': SK_M, 'LOCK': SK_M | SK_H, 'SUIT': SK_M,
         'THRUST': SK_M | SK_H, 'FUEL': SK_H, 'SCRUB': SK_H | SK_E, 'CUTTER': SK_E,
         'PANEL': SK_M, 'DOORK': SK_M | SK_H, 'PLATE': SK_M}
# where a carried part installs from the inventory (bits 7:6 of TB_SKILL):
# 1 open space, 2 a bare deck, 3 either; 0 it does not install
WHERE = {'PLATE': 1, 'THRUST': 1, 'PANEL': 3, 'DOORK': 3}
WHERE.update({t[0]: 2 for t in TYPES if t[3] & F_INST and t[0] not in WHERE})
O2_SECS = 7                         # the suit uses 1 L every 7 s (scrap.masm O2_SECS): 10.5 min
REPAIR_FRAMES = 15                  # a damage step, at full speed (scrap.masm: 16 s - s)
CRATE_COL = 6                       # a loose part's frame: brown


def skill_msg():
    """the SKILLS message (the levels at SK_POS) and where each level goes"""
    s, pos = '', []
    for name in SKILLS:
        s += ('  ' if s else '') + name + ' '
        pos.append(len(s))
        s += '00'
    return s, pos


def crate_art(b):
    """cell art b with a loose part's frame (scrap.masm crate_mark)"""
    out = bytearray(b)
    for c in range(4):
        out[16 * c] = out[16 * c + 15] = CRATE_COL * 0x11
    for r in range(1, 15):
        out[r] = (out[r] & 0xF0) | CRATE_COL
        out[48 + r] = (out[48 + r] & 0x0F) | CRATE_COL << 4
    return bytes(out)


def skill_names(mask):
    return [SKILLS[k] for k in range(5) if mask >> k & 1]


def job_rate(lv, mask, suit_on):
    """work a frame (scrap.masm job_start): 2 + the average of the needed
    skills' quarters; in the suit half that + the suit skill / 8 (not over
    the rate)"""
    ks = [k for k in range(5) if mask >> k & 1]
    q = sum(lv[k] >> 2 for k in ks) // len(ks) if ks else SKILL_MAX >> 2
    r = 2 + q
    if suit_on:
        r = min(r, (r >> 1) + (lv[5] >> 3))
    return max(r, 1)


def job_frames(base, lv, mask, suit_on):
    """frames a job of base frames takes: 16 base work at job_rate a frame"""
    r = job_rate(lv, mask, suit_on)
    return -(-16 * base // r)


def skill_gain(lv, pr, mask, suit_on):
    """a job done: each needed skill (and the suit's, in it) gains
    2 (120 - level) of 256 toward its next level"""
    lv, pr = list(lv), list(pr)
    for k in range(6):
        if (mask | (SK_SUIT if suit_on else 0)) >> k & 1 and lv[k] < SKILL_MAX:
            n = pr[k] + 2 * (120 - lv[k])
            if n > 255:
                lv[k] += 1
            pr[k] = n & 255
    return lv, pr
# what a part is worth undamaged, in $10 (the tug's value: less with damage)
VALUE = {'O2': 20, 'O2E': 8, 'REACT': 250, 'BATT': 30, 'CRATE': 15, 'BUNK': 5,
         'HELM': 60, 'LOCKER': 6, 'TURRET': 40, 'THRUST': 50, 'FUEL': 25,
         'SCRUB': 35, 'CUTTER': 12, 'PANEL': 3, 'DOORK': 8, 'PLATE': 2}
TUG = (0, 18, TUG_LOCK[0], 46)      # the tug's cells, x0, y0, x1, y1 (its value, its systems,
                                    # room to build on round its hull)
AIR_FULL = 100                      # a room's pressure: 100 = 1 atmosphere
assert len(TYPES) <= 32
assert all(len(line) <= 40 for t in TYPES for line in t[4])   # the menu is from column 42
assert all(len(name) <= 14 for name in ACTIONS.values())       # " 1: " + 14 = a menu column

PLAYER_INFO = []                    # drawn by scrap.masm (draw_player)
PLAYER_ACTIONS = [A_INSPECT]
PLAYER_INSPECT = 'THAT IS YOU, IN A WORK SUIT THAT HAS SEEN BETTER DAYS.'
WELCOME = 'DOCKED TO THE KESTREL 9.  ARROWS OR WASD WALK, MOUSE SHOWS AND CLICKS.'
TOO_FAR = 'TOO FAR AWAY - WALK NEXT TO IT FIRST.'
IN_WAY = 'SOMETHING IS IN THE WAY.'
BLOCKED = 'THE WAY IS BLOCKED.'
MESSAGES = [   # (label, text): the strings scrap.masm prints
    ('s_full', 'YOUR HANDS AND BACK ARE FULL - PUT SOMETHING DOWN.'),
    ('s_nocut', 'IN A WRECK IT TAKES A WORKING CUTTER IN A HAND.'),
    ('s_nobatt', 'THE SUIT BATTERY IS TOO LOW FOR THE CUTTER.'),
    ('s_cutting', 'UNINSTALLING WITH THE CUTTER...'),
    ('s_cutdone', 'UNINSTALLED.  IT CAN BE PICKED UP NOW.'),
    ('s_cutstop', 'STOPPED - YOU WALKED AWAY.'),
    ('s_inst', 'INSTALLING...'),
    ('s_instdone', 'INSTALLED.'),
    ('s_inv', 'YOUR GEAR.  I OR TAB: BACK TO THE SHIP'),
    ('s_place', 'CLICK WHERE IT GOES, NEXT TO YOU.  RIGHT CLICK: CANCEL'),
    ('s_wspace', 'IT GOES ON OPEN SPACE.'),
    ('s_wdeck', 'IT GOES ON A BARE DECK.'),
    ('s_wboth', 'IT GOES ON A BARE DECK OR OPEN SPACE.'),
    ('s_uninst', 'UNINSTALLING...'),
    ('s_uninstdone', 'UNINSTALLED.  IT CAN BE PICKED UP NOW.'),
    ('s_installed', 'INSTALLED'),
    ('s_held', 'HELD OPEN'),
    ('s_plate', 'THE DECK PLATE IS YOURS - OPEN SPACE UNDER IT NOW.'),
    ('s_laid', 'DECK PLATE LAID.'),
    ('s_refill', 'SUIT REFILLED.  THE TANK IS EMPTY NOW.'),
    ('s_broken', 'IT IS BROKEN - IT DOES NOT WORK.'),
    ('s_repair', 'REPAIRING...'),
    ('s_repdone', 'REPAIRED.  GOOD AS NEW.'),
    ('s_suitoff', 'SUIT OFF: QUICKER WORK, BUT YOU BREATHE THE ROOM AIR - MIND THE VACUUM.'),
    ('s_suiton', 'SUIT ON.'),
    ('s_pl_nosuit', 'SUIT   NONE: YOU BREATHE THE ROOM AIR'),
    ('s_pl_suit', 'SUIT   MK1 WORK SUIT     O2 '),
    ('s_pl_of', ' OF 90 L'),
    ('s_pl_batt', 'BATT   SMALL CELL        CHARGE '),
    ('s_pl_hands', 'HANDS  '),
    ('s_pl_back', 'BACK   '),
    ('s_slash', ' / '),
    ('s_empty', 'EMPTY'),
    ('s_tug', 'TUG $'),
    ('s_airon', '0, AIR ON'),
    ('s_airoff', '0, NO AIR'),
    ('s_air', 'AIR '),
    ('s_loose', 'LOOSE'),
    ('s_w1', 'CAUTION: SUIT O2 BELOW HALF.'),
    ('s_w2', 'WARNING: SUIT O2 LOW - GET BACK TO THE TUG OR FIND AN O2 TANK.'),
    ('s_w3', 'CRITICAL: SUIT O2 ALMOST GONE!'),
    ('s_w4', 'YOU ARE BLACKING OUT - GET AIR NOW!'),
    ('s_w5', 'YOU SUFFOCATED.  PRESS ENTER TO TRY AGAIN.'),
]


def dmg_pct(step):
    return '%d%%' % int(step * 6.25 + 0.5)


def job_bar(n):
    """the message row's bar while a job runs, n 16ths done (scrap.masm job_bar)"""
    return '[%s%s] %d%%' % ('#' * n, '-' * (16 - n), n * 100 // 16)


def seal(step):
    """a wall's or door's \x02 line: it holds its air fully up to 50 % damage"""
    return 'LEAKS AIR - NEEDS REPAIR' if step >= 8 else 'SEALED - NO LEAKS'


def works(step):
    return 'BROKEN - NEEDS REPAIR' if step >= 8 else 'WORKS AT %d%%' % int(100 - step * 12.5 + 0.5)


def bar(step):
    n = (step * 10 + 8) // 16
    return '[' + '#' * n + '-' * (10 - n) + ']'


# ------------------------------------------------------------------
# the map
# ------------------------------------------------------------------
def build_map(seed=9):
    rnd = random.Random(seed)
    t = [[TYPE['STAR'] if rnd.random() < 0.05 else TYPE['SPACE'] for _ in range(MAP_W)]
         for _ in range(MAP_H)]

    def put(x, y, key):
        t[y][x] = TYPE[key]

    def fill(x0, y0, x1, y1, key):
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                put(x, y, key)

    # the tug: hull x14-29, y26-38; docked, its airlock (29, 32) is next
    # to the wreck's (30, 32)
    X = TUG_DX

    def tput(x, y, key):
        put(x + X, y, key)

    def tfill(x0, y0, x1, y1, key):
        fill(x0 + X, y0, x1 + X, y1, key)

    tfill(4, 26, 19, 38, 'WALL')
    tfill(5, 27, 9, 30, 'FLOOR')        # cockpit
    tfill(11, 27, 18, 30, 'FLOOR')      # engine bay
    tfill(5, 32, 18, 32, 'FLOOR')       # corridor
    tfill(5, 34, 9, 37, 'FLOOR')        # quarters
    tfill(11, 34, 18, 37, 'FLOOR')      # hold
    for d in ((7, 31), (14, 31), (7, 33), (14, 33)):
        tput(d[0], d[1], 'DOORO')
    tput(6, 27, 'HELM'); tput(7, 27, 'HELM')
    tput(12, 27, 'REACT'); tput(13, 27, 'BATT'); tput(17, 27, 'FUEL'); tput(18, 27, 'FUEL')
    tfill(12, 28, 16, 28, 'PIPE')
    tput(5, 36, 'BUNK'); tput(5, 37, 'BUNK'); tput(9, 37, 'LOCKER'); tput(5, 34, 'O2'); tput(6, 34, 'SCRUB')
    tput(17, 37, 'LOCKER'); tput(18, 37, 'LOCKER'); tput(18, 36, 'LOCKER')
    tput(3, 28, 'THRUST'); tput(3, 36, 'THRUST')
    tput(19, 32, 'LOCK')                # docked: right next to the wreck's
    assert (TUG_LOCK[0] + 1, TUG_LOCK[1]) == WRECK_LOCK

    # the wreck: hull x30-90, y6-58
    for y in range(6, 59):
        for x in range(30, 91):
            if (x, y) != WRECK_LOCK:
                put(x, y, 'WALL')
    put(*WRECK_LOCK, 'LOCK')
    rooms = {
        'bridge': (31, 7, 44, 17), 'crew': (46, 7, 57, 17),
        'mess': (31, 19, 44, 29), 'med': (46, 19, 57, 29),
        'armory': (63, 7, 75, 17), 'cargo_a': (77, 7, 89, 29), 'lab': (63, 19, 75, 29),
        'engine': (31, 35, 46, 57), 'life': (48, 35, 57, 45), 'fuelrm': (48, 47, 57, 57),
        'cargo_b': (63, 35, 89, 45), 'vented': (63, 47, 89, 57),
    }
    for name, r in rooms.items():
        fill(*r, 'FLOOR')               # the vented room: no air (rooms())
    fill(31, 31, 89, 33, 'FLOOR')       # the corridors
    fill(59, 7, 61, 57, 'FLOOR')
    for d in ((45, 12), (58, 12), (38, 30), (52, 30), (58, 24), (62, 12), (76, 10),
              (83, 30), (62, 24), (69, 30), (38, 34), (52, 34), (47, 40), (58, 52),
              (52, 46), (62, 40), (76, 34)):
        put(d[0], d[1], 'DOOR')
    put(62, 52, 'DOOR')                 # the vented section stays shut
    put(76, 46, 'DOOR')
    # the hull breach: two broken hull wall segments (damage 15: they leak)
    # bridge
    for x in range(35, 41):
        put(x, 7, 'HELM')
    put(31, 7, 'LOCKER'); put(44, 7, 'LOCKER')
    # crew quarters
    for x in range(47, 57, 2):
        put(x, 7, 'BUNK'); put(x, 8, 'BUNK')
    put(57, 16, 'LOCKER'); put(57, 17, 'LOCKER'); put(46, 17, 'LOCKER')
    # mess and med
    put(31, 29, 'CRATE'); put(32, 29, 'CRATE'); put(44, 19, 'LOCKER')
    put(46, 19, 'BUNK'); put(47, 19, 'BUNK'); put(57, 19, 'LOCKER'); put(57, 20, 'O2')
    # armory: turret on the wall, lockers
    put(69, 6, 'TURRET')
    for x in range(63, 76, 2):
        put(x, 17, 'LOCKER')
    # cargo hold A
    for y in range(8, 29, 3):
        for x in range(79, 88, 2):
            if (x + y) % 5:
                put(x, y, 'CRATE')
    # lab
    put(63, 19, 'O2'); put(64, 19, 'O2'); put(75, 29, 'SCRUB'); put(70, 19, 'HELM')
    # engine room: reactor block, batteries, conduit
    put(36, 42, 'REACT'); put(37, 42, 'REACT'); put(36, 43, 'REACT'); put(37, 43, 'REACT')
    for y in range(37, 56, 3):
        put(31, y, 'BATT')
    fill(38, 42, 45, 42, 'PIPE')
    fill(35, 44, 35, 52, 'PIPE')
    for x in (33, 40):
        put(x, 58, 'WALL')
    put(33, 59, 'THRUST'); put(40, 59, 'THRUST')
    # life support
    put(49, 35, 'SCRUB'); put(50, 35, 'SCRUB'); put(51, 35, 'SCRUB')
    for x in range(53, 58):
        put(x, 35, 'O2')
    # fuel room
    for x in range(49, 57, 2):
        put(x, 50, 'FUEL'); put(x, 54, 'FUEL')
    # cargo hold B
    for x in range(65, 89, 3):
        put(x, 37, 'CRATE'); put(x, 43, 'CRATE')
    # vented section: debris
    put(70, 50, 'CRATE'); put(84, 54, 'O2'); put(78, 48, 'LOCKER')
    # damage
    d = [[0] * MAP_W for _ in range(MAP_H)]
    for y in range(MAP_H):
        for x in range(MAP_W):
            k = TYPES[t[y][x]][0]
            if k in ('SPACE', 'STAR', 'BREACH') or (x, y) in ((90, 51), (90, 52)):
                continue                # (the breach: set below)
            if k in ('FLOOR',):
                d[y][x] = rnd.choice((0, 0, 0, 1, 1, 2))
            elif k in ('WALL',):
                d[y][x] = rnd.choice((0, 1, 1, 2, 3))
            elif x <= TUG_LOCK[0]:      # the tug is looked after
                d[y][x] = rnd.choice((0, 1, 2))
            else:
                d[y][x] = rnd.randint(1, 12)
    d[50][70] = 9                       # a few worth reading about
    d[46][76] = 5                       # the vented section's doors hold
    d[52][62] = 3
    d[49][90] = 10                      # a cracked hull wall: it leaks
    d[51][90] = d[52][90] = 15          # the hull breach: broken wall segments
    d[42][36] = 3
    return t, d


DOORS = ('DOOR', 'DOORO', 'LOCK')   # a lock is a door that is always open


def solid(k):
    return bool(TYPES[TYPE[k]][3] & F_SOLID)


def vac(k):
    return bool(TYPES[TYPE[k]][3] & F_VAC)


def rooms(t, d=None):
    """the rooms, as scrap.masm's rooms_build works them out (at the start
    and after the ship is changed): (room id of every cell, the links
    [(x, y, room a, room b)], the rooms that leak, the start pressures, the
    tug's rooms).  A room is the air cells joined side by side (63 at most).
    A link is a door or airlock, or a wall from 50 % damage, with a room or
    vacuum (0) on two opposite sides (past an airlock next to it: the
    tug's and the wreck's are side by side); it gets the room of a side.  A room
    leaks when an air cell of it is next to vacuum
    or the map's edge."""
    rid = [[0] * MAP_W for _ in range(MAP_H)]
    leaks = set()
    n = 0
    for y in range(MAP_H):
        for x in range(MAP_W):
            if rid[y][x] or solid(TYPES[t[y][x]][0]):
                continue
            n = min(n + 1, 63)
            todo = [(x, y)]
            rid[y][x] = n
            while todo:
                cx, cy = todo.pop()
                for nx, ny in ((cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)):
                    if not (0 <= nx < MAP_W and 0 <= ny < MAP_H):
                        leaks.add(n)
                        continue
                    k = TYPES[t[ny][nx]][0]
                    if vac(k):
                        leaks.add(n)
                    if not rid[ny][nx] and not solid(k):
                        rid[ny][nx] = n
                        todo.append((nx, ny))

    def side(x, y, dx, dy):
        if 0 <= x < MAP_W and 0 <= y < MAP_H and TYPES[t[y][x]][0] == 'LOCK':
            x, y = x + dx, y + dy       # two airlocks side by side: past it
        if not (0 <= x < MAP_W and 0 <= y < MAP_H) or vac(TYPES[t[y][x]][0]):
            return 0
        if solid(TYPES[t[y][x]][0]):
            return None
        return rid[y][x]

    doors = []
    for y in range(MAP_H):
        for x in range(MAP_W):
            k = TYPES[t[y][x]][0]
            if not (k in DOORS or (k == 'WALL' and d is not None and d[y][x] >= 8)):
                continue
            for a, b in (((x - 1, y, -1, 0), (x + 1, y, 1, 0)), ((x, y - 1, 0, -1), (x, y + 1, 0, 1))):
                ra, rb = side(*a), side(*b)
                if ra is not None and rb is not None and ra != rb and len(doors) < 64:
                    doors.append((x, y, ra, rb))
                    rid[y][x] = ra or rb
    vented = rid[50][70]
    press = [0] + [0 if r == vented else AIR_FULL for r in range(1, n + 1)]
    tug = set(rid[y][x] for y in range(TUG[1], TUG[3] + 1) for x in range(TUG[0], TUG[2] + 1)
              if rid[y][x] and not solid(TYPES[t[y][x]][0]))
    return rid, doors, sorted(leaks), press, tug


def encode(t, d):
    """the map bytes: type byte = type (bits 4:0) | room bits 5:4 at 6:5 |
    bit 7 (a part: bolted, in the tug installed; an open door: held open);
    flag byte =
    damage (3:0) | room bits 3:0 at 7:4"""
    rid = rooms(t, d)[0]
    ty = [[0] * MAP_W for _ in range(MAP_H)]
    fl = [[0] * MAP_W for _ in range(MAP_H)]
    for y in range(MAP_H):
        for x in range(MAP_W):
            r = rid[y][x]
            # every part starts bolted (in the tug: installed); a door
            # that starts open is held open
            bolted = TYPES[t[y][x]][3] & F_ITEM or TYPES[t[y][x]][0] == 'DOORO'
            ty[y][x] = t[y][x] | (r >> 4) << 5 | (0x80 if bolted else 0)
            fl[y][x] = d[y][x] | (r & 15) << 4
    return ty, fl


def map_pages(t, d):
    """the 48 even video pages (x60, x62 ... xBE) of SCRAP.OVL, in order"""
    ty, fl = encode(t, d)
    pages = []
    for k in range(24):
        cy, cx = divmod(k, CHUNKS_X)
        tp = bytearray(256)
        fp = bytearray(256)
        for i in range(256):
            y, x = cy * 16 + i // 16, cx * 16 + i % 16
            tp[i] = ty[y][x]
            fp[i] = fl[y][x]
        pages += [bytes(tp), bytes(fp)]
    return pages


def art_bytes(name):
    rows = ART[name]
    assert len(rows) == 16 and all(len(r) == 8 for r in rows), name
    out = bytearray(64)
    for c in range(4):
        for r in range(16):
            lo, hi = int(rows[r][2 * c], 16), int(rows[r][2 * c + 1], 16)
            out[16 * c + r] = lo | (hi << 4)
    return bytes(out)


# ------------------------------------------------------------------
# scrap_types.asm, scrap_data.masm
# ------------------------------------------------------------------
ART_PAGE = 0x39          # x3900: art, 4 cells a page (7 pages: x3900-x3FFF)
TAB_PAGE = 0x38          # x3800: info pointers (t * 4 + i), lo then hi
TAB2_PAGE = 0x37         # x3700: the small tables
ACT_PAGE = 0x36          # x3600: actions per type, action strings
ROOM_PAGE = 0x35         # x3500: damage bars, the rooms
DOOR_PAGE = 0x34         # x3400: the doors


def asm_string(s):
    out, plain = [], ''
    for ch in s:
        if ' ' <= ch <= '~' and ch != '"' and ch != '\\':
            plain += ch
        else:
            if plain:
                out.append('"%s"' % plain)
                plain = ''
            out.append('0x%02X' % ord(ch))
    if plain:
        out.append('"%s"' % plain)
    out.append('0x00')
    return ', '.join(out)


def write_sources():
    n = len(TYPES)
    lines = ['; scrap_types.asm - generated by gen_scrap.py, do not edit by hand',
             '; the cell types and table addresses of scrap.masm', '']
    for i, ty in enumerate(TYPES):
        lines.append('T_%-8s = %d' % (ty[0], i))
    t, dm = build_map()
    rid, doors, leaks, press, tug = rooms(t, dm)
    lines += ['NTYPES     = %d' % n,
              'F_WALK     = 0x%02X' % F_WALK, 'F_DMG      = 0x%02X' % F_DMG,
              'F_ITEM     = 0x%02X' % F_ITEM, 'F_INST     = 0x%02X' % F_INST,
              'F_STRUCT   = 0x%02X' % F_STRUCT, 'F_SOLID    = 0x%02X' % F_SOLID,
              'F_VAC      = 0x%02X' % F_VAC]
    lines += ['A_%-8s = %d' % (k, v) for k, v in (
        ('OPEN', A_OPEN), ('CLOSE', A_CLOSE), ('INSPECT', A_INSPECT), ('WALK', A_WALK),
        ('PICK', A_PICK), ('CUT', A_CUT), ('PUTL', A_PUTL), ('PUTR', A_PUTR),
        ('PUTB', A_PUTB), ('REFILL', A_REFILL), ('HOLD', A_HOLD), ('INSTALL', A_INSTALL),
        ('UNINST', A_UNINST), ('LAY', A_LAY), ('REPAIR', A_REPAIR), ('SKILLS', A_SKILLS),
        ('SUITOFF', A_SUITOFF), ('SUITON', A_SUITON), ('INV', A_INV))]
    lines += ['SK_M       = %d' % SK_M, 'SK_SUIT    = %d' % SK_SUIT,
              'SKILL_START = %d' % SKILL_START, 'SKILL_MAX  = %d' % SKILL_MAX,
              'REPAIR_FRAMES = %d' % REPAIR_FRAMES, 'CRATE_COL  = %d' % CRATE_COL,
              'TB_SKILL   = 0xC0          ; ACT_PG + t: the skills a part needs (bit k skill k)',
              'SK_LV      = 0x%04X        ; the skill levels (6), then SK_PR: their progress' % SK_LV,
              'SK_PR      = 0x%04X' % SK_PR]
    lines += ['ART_PG     = 0x%02X' % ART_PAGE,
              'INFO_PG    = 0x%02X        ; x%02X00 + 4t + i: info line i, low bytes; + x80 high' % (TAB_PAGE, TAB_PAGE),
              'TAB_PG     = 0x%02X' % TAB2_PAGE,
              'TB_FLAGS   = 0x00          ; + t', 'TB_NAMEL   = 0x20', 'TB_NAMEH   = 0x40',
              'TB_INSPL   = 0x60', 'TB_INSPH   = 0x80',
              'TB_DMGL    = 0xA0          ; + damage step', 'TB_DMGH    = 0xB0',
              'TB_WRKL    = 0xC0', 'TB_WRKH    = 0xD0',
              'TB_VAL     = 0xE0          ; + t: worth undamaged, in $10',
              'ACT_PG     = 0x%02X          ; + 4t + i: action i of type t (0 none)' % ACT_PAGE,
              'TB_ASTRL   = 0x80          ; + action code', 'TB_ASTRH   = 0xA0',
              'BAR_PG     = 0x%02X          ; + step: bar string low; + x10 high' % ROOM_PAGE,
              'ROOM_PG    = 0x%02X' % ROOM_PAGE,
              'RM_P0      = 0x40          ; + room: the pressure at the start',
              'RM_FL      = 0x80          ; + room: bit 0 a room of the tug',
              'RM_LEAK    = 0xC0          ; the rooms that leak through a breach, 0 ends',
              'DOOR_PG    = 0x%02X          ; + i: the door\'s type page; + x40 index; + x80, + xC0 its rooms' % DOOR_PAGE,
              'NDOORS     = %d' % len(doors),
              'NROOMS     = %d          ; rooms 1 to NROOMS - 1' % len(press),
              'AIR_FULL   = %d' % AIR_FULL,
              'TUG_X0     = %d' % TUG[0], 'TUG_Y0     = %d' % TUG[1],
              'TUG_X1     = %d' % TUG[2], 'TUG_Y1     = %d' % TUG[3],
              'MAP_PAGE   = 0x%02X' % MAP_PAGE,
              'MAP_W      = %d' % MAP_W, 'MAP_H      = %d' % MAP_H,
              'START_X    = %d' % START[0], 'START_Y    = %d' % START[1],
              'OVL_PAGES  = 48', '']
    open(os.path.join(HERE, 'scrap_types.asm'), 'w').write('\n'.join(lines))

    d = ['; scrap_data.masm - generated by gen_scrap.py, do not edit by hand',
         '; the art, tables and strings of scrap.masm (included at its end)', '']
    strings = []

    def sref(label, text):
        strings.append((label, text))
        return label

    # art pages
    arts = [art_bytes(ty[1]) for ty in TYPES]
    for p in range((len(arts) + 3) // 4):
        d.append('.fixed 0x%02X00' % (ART_PAGE + p))
        if p == 0:
            d.append('ART:')
        for k in range(4):
            i = 4 * p + k
            if i < len(arts):
                d.append('; %s' % TYPES[i][0])
                b = arts[i]
                for o in range(0, 64, 16):
                    d.append('    #d8 ' + ', '.join('0x%02X' % v for v in b[o:o + 16]))
        d.append('')
    # info pointers
    info_lo, info_hi = ['0'] * 128, ['0'] * 128
    for i, ty in enumerate(TYPES):
        for k, line in enumerate(ty[4][:4]):
            lab = sref('zi_%d_%d' % (i, k), line)
            info_lo[4 * i + k] = lab + ' & 0xFF'
            info_hi[4 * i + k] = lab + ' >> 8'
    for i, line in enumerate(PLAYER_INFO):
        lab = sref('zi_pl_%d' % i, line)
        info_lo[4 * TYPE['PLAYER'] + i] = lab + ' & 0xFF'
        info_hi[4 * TYPE['PLAYER'] + i] = lab + ' >> 8'
    d.append('.fixed 0x%02X00' % TAB_PAGE)
    d.append('INFO_TAB:')
    for o in range(0, 128, 8):
        d.append('    #d8 ' + ', '.join(info_lo[o:o + 8]))
    for o in range(0, 128, 8):
        d.append('    #d8 ' + ', '.join(info_hi[o:o + 8]))
    d.append('')
    # the small tables
    tab = ['0'] * 256

    def setp(base, idx, lab):
        tab[base + idx] = lab + ' & 0xFF'
        tab[base + 0x20 + idx] = lab + ' >> 8'

    for i, ty in enumerate(TYPES):
        tab[i] = str(ty[3])
        setp(0x20, i, sref('zn_%d' % i, ty[2]))
        setp(0x60, i, sref('zx_%d' % i, ty[6] if ty[0] != 'PLAYER' else PLAYER_INSPECT))
    for st in range(16):
        lab = sref('zd_%d' % st, dmg_pct(st))
        tab[0xA0 + st] = lab + ' & 0xFF'
        tab[0xB0 + st] = lab + ' >> 8'
        lab = sref('zw_%d' % st, works(st))
        tab[0xC0 + st] = lab + ' & 0xFF'
        tab[0xD0 + st] = lab + ' >> 8'
    for i, ty in enumerate(TYPES):
        tab[0xE0 + i] = str(VALUE.get(ty[0], 0))
    d.append('.fixed 0x%02X00' % TAB2_PAGE)
    d.append('TAB:')
    for o in range(0, 256, 8):
        d.append('    #d8 ' + ', '.join(tab[o:o + 8]))
    d.append('')
    # actions per type, the action strings
    act = ['0'] * 256
    for i, ty in enumerate(TYPES):
        acts = ty[5] if ty[0] != 'PLAYER' else PLAYER_ACTIONS
        for k, a in enumerate(acts[:4]):
            act[4 * i + k] = str(a)
    assert SK_LV >> 8 == ACT_PAGE and SK_LV & 0xFF >= 0xC0 + len(TYPES)
    for i, ty in enumerate(TYPES):
        act[0xC0 + i] = str(NEEDS.get(ty[0], 0) | WHERE.get(ty[0], 0) << 6)
    for a, txt in ACTIONS.items():
        lab = sref('za_%d' % a, txt)
        act[0x80 + a] = lab + ' & 0xFF'
        act[0xA0 + a] = lab + ' >> 8'
    d.append('.fixed 0x%02X00' % ACT_PAGE)
    d.append('ACT_TAB:')
    for o in range(0, 256, 8):
        d.append('    #d8 ' + ', '.join(act[o:o + 8]))
    d.append('')
    # damage bars and the rooms
    t, dm = build_map()
    rid, doors, leaks, press, tug = rooms(t, dm)
    rm = ['0'] * 256
    for st in range(16):
        lab = sref('zb_%d' % st, bar(st))
        rm[st] = lab + ' & 0xFF'
        rm[16 + st] = lab + ' >> 8'
    for st in range(16):                # \x02: a wall's or door's seal
        lab = sref('zs_%d' % st, seal(st))
        rm[0x20 + st] = lab + ' & 0xFF'
        rm[0x30 + st] = lab + ' >> 8'
    for r, pr in enumerate(press):
        rm[0x40 + r] = str(pr)
        rm[0x80 + r] = '1' if r in tug else '0'
    for k, r in enumerate(leaks):
        rm[0xC0 + k] = str(r)
    d.append('.fixed 0x%02X00' % ROOM_PAGE)
    d.append('ROOM_TAB:')
    for o in range(0, 256, 8):
        d.append('    #d8 ' + ', '.join(rm[o:o + 8]))
    d.append('')
    dr = ['0'] * 256
    for k, (x, y, ra, rb) in enumerate(doors):
        ck = CHUNKS_X * (y >> 4) + (x >> 4)
        dr[k] = '0x%02X' % (MAP_PAGE + 4 * ck)
        dr[0x40 + k] = str(16 * (y & 15) + (x & 15))
        dr[0x80 + k] = str(ra)
        dr[0xC0 + k] = str(rb)
    d.append('.fixed 0x%02X00' % DOOR_PAGE)
    d.append('DOOR_TAB:')
    for o in range(0, 256, 8):
        d.append('    #d8 ' + ', '.join(dr[o:o + 8]))
    d.append('')
    # messages
    for lab, txt in [('s_welcome', WELCOME), ('s_toofar', TOO_FAR), ('s_inway', IN_WAY),
                     ('s_blocked', BLOCKED)] + MESSAGES:
        sref(lab, txt)
    # the strings, packed into chunks of up to 240 bytes
    cur, size = [], 0
    for lab, s in strings:
        n = len(s) + 1
        if size + n > 240:
            d.append('.chunk')
            d += cur
            d.append('')
            cur, size = [], 0
        cur.append('%s:' % lab)
        cur.append('    #d ' + asm_string(s))
        size += n
    if cur:
        d.append('.chunk')
        d += cur
        d.append('')
    d += ['.chunk', 'JB_PCT:', '    #d8 ' + ', '.join(str(n * 100 // 16) for n in range(17)), '']
    d += ['.chunk', 'CRACK:'] + ['    #d8 ' + ', '.join('0x%02X' % v for v in crack_bytes()[o:o + 16])
                                 for o in range(0, 64, 16)] + ['']
    b = art_bytes('player_ns')        # the player without the suit
    d += ['.chunk', 'PL_NOSUIT:'] + ['    #d8 ' + ', '.join('0x%02X' % v for v in b[o:o + 16])
                                      for o in range(0, 64, 16)] + ['']
    msg, pos = skill_msg()            # the SKILLS message: written into
    d += ['.chunk', 'SK_MSG:', '    #d ' + asm_string(msg), 'SK_POS:',
          '    #d8 ' + ', '.join('(SK_MSG & 0xFF) + %d' % p for p in pos), '']
    open(os.path.join(HERE, 'scrap_data.masm'), 'w').write('\n'.join(d))


# ------------------------------------------------------------------
# the inventory screen (SCRAP.INV: scrap_inv.masm, scrap_inv_data.masm)
# ------------------------------------------------------------------
# a 3 x 5 font, rows top down, pixels left to right
F35 = {
    'A': '010101111101101', 'B': '110101110101110', 'C': '011100100100011',
    'D': '110101101101110', 'E': '111100110100111', 'F': '111100110100100',
    'G': '011100101101011', 'H': '101101111101101', 'I': '111010010010111',
    'J': '001001001101010', 'K': '101101110101101', 'L': '100100100100111',
    'M': '101111111101101', 'N': '110101101101101', 'O': '010101101101010',
    'P': '110101110100100', 'Q': '010101101110011', 'R': '110101110101101',
    'S': '011100010001110', 'T': '111010010010010', 'U': '101101101101111',
    'V': '101101101101010', 'W': '101101111111101', 'X': '101101010101101',
    'Y': '101101010010010', 'Z': '111001010100111',
    '0': '111101101101111', '1': '010110010010111', '2': '111001111100111',
    '3': '111001011001111', '4': '101101111001001', '5': '111100111001111',
    '6': '111100111101111', '7': '111001001010010', '8': '111101111101111',
    '9': '111101111001111', '.': '000000000000010', ',': '000000000010100',
    ' ': '000000000000000', '?': '110001010000010', '-': '000000111000000',
    '%': '101001010100101', '/': '001001010100100', ':': '000010000010000',
    "'": '010010000000000', '(': '010100100100010', ')': '010001001001010',
    '>': '100010001010100',
}
INV_BG, INV_BAR = 1, 3                  # colors: the screen, the title bar
INV_LABELS = [  # (byte column, line pair, color, background, text)
    (1, 3, 0xA, INV_BAR, 'INVENTORY'), (60, 3, 0xA, INV_BAR, 'I - CLOSE'),
    (2, 14, 0xE, INV_BG, 'GEAR'), (35, 14, 0xE, INV_BG, 'CARRYING')] + [
    (9, 25 + 32 * i, 0xB, INV_BG, t) for i, t in enumerate(['SUIT', 'BATTERY', 'O2', 'UTILITY'])] + [
    (42, 25 + 32 * i, 0xB, INV_BG, t) for i, t in enumerate(['LEFT HAND', 'RIGHT HAND', 'BACK'])]
# the slots' art (byte column, line pair): 0-2 carrying, 3-6 the gear.
# Below CARRYING (line pairs 118 on) stays free for an open bag (later).
INV_SLOTS = [(36, 22 + 32 * i) for i in range(3)] + [(3, 22 + 32 * i) for i in range(4)]
INV_STR = [('s_iempty', 'EMPTY'), ('s_isuit', 'MK1 WORK SUIT'), ('s_ioff', 'TAKEN OFF'),
           ('s_icell', 'CELL '), ('s_il', ' L'), ('s_inone', 'NONE')]


def f35_code(ch, r):
    """row r of ch: the left pixel pair's (a + 2b) and the third pixel << 2"""
    g = F35.get(ch, F35[' '])[3 * r:3 * r + 3]
    a, b, c = (int(v) for v in g)
    return a + 2 * b + 4 * c


def inventory_screen(carry, suit_on, batt, o2, hot, dmg=(0, 0, 0), mouse=None):
    """the inventory's 192 line pairs of 80 bytes, as scrap_inv.masm draws
    them: carry = the three carry slots' types (0 empty), dmg their damage
    steps (a broken one cracked), hot = inv_k, mouse = the pointer's art
    pixel (x, y), None: not on the screen"""
    scr = [bytearray([INV_BG * 0x11]) * 80 for _ in range(192)]
    for p in range(10):
        scr[p][:] = bytes([INV_BAR * 0x11]) * 80

    def px(x, y, c):
        b = scr[y][x >> 1]
        scr[y][x >> 1] = (b & 0xF0) | c if x & 1 == 0 else (b & 0x0F) | c << 4

    def text(bc, p, s, fg, bg):
        for ch in s:
            for r in range(5):
                g = F35.get(ch, F35[' '])[3 * r:3 * r + 3]
                for k in range(4):
                    px(2 * bc + k, p + r, fg if k < 3 and g[k] == '1' else bg)
            bc += 2
        return bc

    for bc, p, fg, bg, t in INV_LABELS:
        text(bc, p, t, fg, bg)
    names = [t[2] for t in TYPES]
    for k, (bc, p) in enumerate(INV_SLOTS):
        fc = 0xE if k == hot else 0xB
        for x in range(2 * bc - 1, 2 * bc + 9):
            px(x, p - 1, fc)
            px(x, p + 16, fc)
        for y in range(p, p + 16):
            px(2 * bc - 1, y, fc)
            px(2 * bc + 8, y, fc)
        t = carry[k] if k < 3 else {3: TYPE['SUIT'] if suit_on else 0, 4: TYPE['BATT'],
                                    5: TYPE['O2'], 6: 0}[k]
        art = art_bytes(TYPES[t][1]) if t else bytes(64)
        if k < 3 and t and dmg[k] >= BROKEN_STEP:
            art = broken_art(art)
        for c in range(4):
            for y in range(16):
                scr[p + y][bc + c] = art[16 * c + y]
        w = 38 if k < 3 else 26
        for y in range(p + 10, p + 15):
            scr[y][bc + 6:bc + 6 + w] = bytes([INV_BG * 0x11]) * w
        if k < 3:
            v = names[t] if t else 'EMPTY'
        else:
            v = {3: 'MK1 WORK SUIT' if suit_on else 'TAKEN OFF', 4: 'CELL %d%%' % batt,
                 5: '%d L' % o2, 6: 'NONE'}[k]
        text(bc + 6, p + 10, v, 0xA, INV_BG)
    if mouse is not None and mouse[1] < 192:
        draw_pointer(scr, *mouse)
    return scr


def pointer_bytes(sh, c):
    """byte column c (0-2) of the pointer drawn from art pixel 2 b + sh:
    its 8 AND masks and 8 colors, line pairs 0-7"""
    m, k = [], []
    for row in POINTER:
        mm, kk = 0xFF, 0
        for n in range(2):
            i = 2 * c + n - sh
            if 0 <= i < len(row) and row[i] != '.':
                mm &= ~(0xF << 4 * n) & 0xFF
                kk |= int(row[i], 16) << 4 * n
        m.append(mm)
        k.append(kk)
    return m, k


def draw_pointer(scr, x, y):
    """the pointer onto inventory_screen's lines, its tip at art pixel x, y"""
    for r, row in enumerate(POINTER):
        for i, ch in enumerate(row):
            if ch != '.' and x + i < 160 and y + r < 192:
                b = scr[y + r][(x + i) >> 1]
                c = int(ch, 16)
                scr[y + r][(x + i) >> 1] = (b & 0xF0) | c if (x + i) & 1 == 0 else (b & 0x0F) | c << 4


def write_inv_data():
    """scrap_inv_data.masm: the font, the labels and the slots (SCRAP.INV)"""
    d = ['; scrap_inv_data.masm - made by gen_scrap.py: the inventory\'s font,', '; labels and slots', '']
    d += ['.page', 'FNT_A:']                 # rows 0-3: + 64 r + char - x20
    for r in range(4):
        for o in range(0, 64, 16):
            d.append('    #d8 ' + ', '.join(str(f35_code(chr(0x20 + o + i), r)) for i in range(16)))
    d += ['', '.chunk', 'FNT_B:']           # row 4
    for o in range(0, 64, 16):
        d.append('    #d8 ' + ', '.join(str(f35_code(chr(0x20 + o + i), 4)) for i in range(16)))
    d += ['', '.chunk', 'LBL:']
    for k, (bc, p, fg, bg, t) in enumerate(INV_LABELS):
        d.append('    #d8 %d, %d, %d, %d, zl_%d & 0xFF' % (bc, p, fg, bg, k))
    d.append('    #d8 0xFF')
    for k, (bc, p, fg, bg, t) in enumerate(INV_LABELS):
        assert all(ch in F35 for ch in t), t
        d += ['zl_%d:' % k, '    #d "%s", 0x00' % t]
    d += ['', '.chunk', 'PT_TAB:']           # 48 s + 16 c + r: AND mask, + 8 color
    for sh in range(2):
        for c in range(3):
            m, k = pointer_bytes(sh, c)
            d.append('    #d8 ' + ', '.join('0x%02X' % v for v in m + k))
    d += ['', '.chunk', 'SPOS:', '    #d8 ' + ', '.join('%d, %d' % bp for bp in INV_SLOTS), '']
    d += ['.chunk']
    for lab, t in INV_STR:
        d += ['%s:' % lab, '    #d "%s", 0x00' % t]
    d.append('')
    for t in TYPES:
        assert all(ch in F35 for ch in t[2]), t[2]
    open(os.path.join(HERE, 'scrap_inv_data.masm'), 'w').write('\n'.join(d))


def write_ovl(path=None):
    t, dmg = build_map()
    data = b''.join(map_pages(t, dmg))
    path = path or os.path.join(HERE, 'scrap_map.bin')
    open(path, 'wb').write(data)
    return data


def main():
    write_sources()
    write_inv_data()
    data = write_ovl()
    print('scrap_types.asm, scrap_data.masm, scrap_inv_data.masm, scrap_map.bin (%d bytes)' % len(data))


if __name__ == '__main__':
    sys.exit(main())

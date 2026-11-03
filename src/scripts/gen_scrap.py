#!/usr/bin/env python3
"""
gen_scrap.py - the data of SCRAPWRIGHT (scrap.masm, SCRAP.PLC): cell art,
the cell types' names, info lines and actions, and the hand-made wreck

    python3 gen_scrap.py        writes scrap_types.asm, scrap_data.masm
                                and ../../sdcard/SCRAP.OVL

SCRAPWRIGHT is a top-down salvage game (design: the SCRAPWRIGHT proposal
doc; docs/software/SCRAP.md).  Phase 2 is a wreck to walk through: the
tug docked to a derelict, doors, the item panel and the mouse.

THE SCREEN
    lines 0-383    4 bpp, 2x: 20 x 12 cells, a cell is 8 x 16 pixels
                   (4 bytes across, 16 line pairs: 64 bytes)
    lines 384-479  1 bpp, 2x: the panel, 6 text rows of 80 (text rows
                   24-29 of the tracker's layout)

THE MAP
    96 x 64 cells in 16 x 16-cell chunks, 6 across and 4 down.  Chunk k
    (k = 6 * (y >> 4) + (x >> 4)) is two even video pages: x60 + 4k holds
    the cells' types, x62 + 4k their flags (bits 3:0 damage in 16ths,
    6.25 % a step; an item stops working at step 8 = 50 %).  A cell is at
    index 16 * (y & 15) + (x & 15) of both pages.  SCRAP.OVL is the even
    pages x60, x62 ... xBE in order (48 pages, 12 KB); scrap.masm reads it
    into place (a sector holds two pages).  The chunk layout is the one the
    card paging of a later phase will use.

THE ART
    Cell type t: 64 bytes at ART + 64 t, column-major: byte 16 c + r is
    pixels 2c (low nibble, shown first) and 2c + 1 (high nibble) of line
    pair r.  Colors are the 4 bpp palette (docs/video/COLORS.md).

Date: 2026-11-03
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
START = (7, 32)                     # the player, in the tug's corridor

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
    'tube': ['BBBBBBBB', 'B7B7B7B7', '77777777', '77777777', '77777777',
             '77777777', '77777777', '77777777', '77777777', '77777777',
             '77777777', '77777777', '77777777', '77777777', 'B7B7B7B7',
             'BBBBBBBB'],
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
    'player': ['77777777', '77AAAA77', '7AA88AA7', '7A8888A7', '7AA88AA7',
               '77AAAA77', '7BAAAAB7', 'BAAAAAAB', 'BAAEEAAB', 'BAAAAAAB',
               '7BAAAAB7', '77AAAA77', '7AA77AA7', '7AA77AA7', '7BB77BB7',
               '77777777'],
    'breach': ['11111111', '11111111', '1111A111', '11111111', '11111111',
               '11111111', '11111111', '1A111111', '11111111', '11111111',
               '11111111', '11111111', '11111111', '111111A1', '11111111',
               '11111111'],
}

# ------------------------------------------------------------------
# the cell types: art, name, flags, info lines (\x01 = "works at" the
# damage allows), menu actions, the inspect line
# ------------------------------------------------------------------
F_WALK = 0x01       # the player can stand on it
F_DMG = 0x02        # it has a damage score worth showing

A_OPEN, A_CLOSE, A_INSPECT, A_WALK = 1, 2, 3, 4
ACTIONS = {A_OPEN: 'OPEN', A_CLOSE: 'CLOSE', A_INSPECT: 'INSPECT', A_WALK: 'WALK HERE'}

TYPES = [
    # key, art, name, flags, info lines, actions, inspect
    ('SPACE', 'space', 'OPEN SPACE', 0,
     ['VACUUM.  NO AIR, NO FLOOR.'], [A_INSPECT],
     'NOTHING OUT THERE BUT DEBRIS AND COLD.'),
    ('STAR', 'star', 'OPEN SPACE', 0,
     ['VACUUM.  NO AIR, NO FLOOR.'], [A_INSPECT],
     'A DISTANT STAR.  NOT FOR SALE.'),
    ('FLOOR', 'floor', 'DECK PLATE', F_WALK | F_DMG,
     ['STEEL DECK PLATE', 'WALKABLE'], [A_WALK, A_INSPECT],
     'SCUFFED DECK PLATE.  SOMEONE WALKED HERE A LOT.'),
    ('WALL', 'wall', 'BULKHEAD', F_DMG,
     ['STEEL BULKHEAD, AIRTIGHT', 'HOLDS AIR WHILE UNDER 50% DAMAGE',
      'CUT FREE WITH A CUTTER (LATER PHASE)'], [A_INSPECT],
     'A SOLID BULKHEAD.  THE PAINT SAYS DECK 2.'),
    ('DOOR', 'door', 'DOOR (CLOSED)', F_DMG,
     ['PRESSURE DOOR, SEALS WHEN CLOSED', '\x01',
      'WALK INTO IT OR CLICK OPEN'], [A_OPEN, A_INSPECT],
     'A PRESSURE DOOR.  THE HAZARD STRIPES ARE FADED.'),
    ('DOORO', 'dooro', 'DOOR (OPEN)', F_WALK | F_DMG,
     ['PRESSURE DOOR, OPEN', '\x01', 'AIR FLOWS THROUGH IT'], [A_CLOSE, A_WALK, A_INSPECT],
     'AN OPEN PRESSURE DOOR.'),
    ('O2', 'o2', 'O2 TANK', F_DMG,
     ['CAPACITY 120 L', '\x01', 'HEAVY: TAKES ONE CARRY SLOT',
      'WORTH ABOUT $200 UNDAMAGED'], [A_INSPECT],
     'AN OXYGEN TANK.  THE GAUGE STILL MOVES.'),
    ('REACT', 'react', 'REACTOR CORE', F_DMG,
     ['FUSION CORE, 40 KW', '\x01', 'TOO HEAVY TO CARRY WHOLE',
      'WORTH ABOUT $2,500 UNDAMAGED'], [A_INSPECT],
     'A REACTOR CORE.  IT IS HUMMING VERY QUIETLY.'),
    ('BATT', 'batt', 'BATTERY', F_DMG,
     ['STORAGE CELL, 8 KWH', '\x01', 'HEAVY: TAKES ONE CARRY SLOT',
      'WORTH ABOUT $300 UNDAMAGED'], [A_INSPECT],
     'A SHIP BATTERY.  STILL WARM.'),
    ('CRATE', 'crate', 'CARGO CRATE', F_DMG,
     ['SEALED CARGO CRATE', 'CONTENTS UNKNOWN', 'OPEN IT TO SEE (LATER PHASE)'], [A_INSPECT],
     'THE LABEL READS "MINING CHARGES - DO NOT DROP".'),
    ('BUNK', 'bunk', 'BUNK', F_DMG,
     ['CREW BUNK', '\x01', 'LIGHT SCRAP'], [A_INSPECT],
     'A CREW BUNK.  THE BLANKET IS FOLDED NEATLY.'),
    ('HELM', 'helm', 'HELM CONSOLE', F_DMG,
     ['FLIGHT CONSOLE', '\x01', 'HOLDS THE SHIP LOG (LATER PHASE)'], [A_INSPECT],
     'THE HELM.  THE LAST LOG ENTRY IS 212 DAYS OLD.'),
    ('LOCKER', 'locker', 'LOCKER', F_DMG,
     ['STEEL LOCKER, 4 SLOTS', '\x01', 'MAY HOLD GEAR (LATER PHASE)'], [A_INSPECT],
     'A LOCKER.  THE LOCK IS RUSTED SHUT.'),
    ('TURRET', 'turret', 'SECURITY TURRET', F_DMG,
     ['WALL TURRET, ARC TYPE', '\x01', 'DORMANT - NO POWER'], [A_INSPECT],
     'A SECURITY TURRET.  ITS LIGHT IS DARK, FOR NOW.'),
    ('PIPE', 'pipe', 'POWER CONDUIT', F_WALK | F_DMG,
     ['CONDUIT UNDER THE DECK', '\x01', 'CARRIES POWER BETWEEN PARTS'], [A_WALK, A_INSPECT],
     'A POWER CONDUIT RUNS UNDER THE DECK HERE.'),
    ('VENT', 'vent', 'DECK (NO AIR)', F_WALK | F_DMG,
     ['DECK PLATE IN VACUUM', 'THIS ROOM HAS LOST ITS AIR', 'YOUR SUIT AIR ONLY'], [A_WALK, A_INSPECT],
     'FROST ON THE DECK.  THE AIR IS GONE.'),
    ('LOCK', 'lock', 'AIRLOCK', F_WALK | F_DMG,
     ['DOCKING AIRLOCK', '\x01', 'JOINS THE TUG TO THE WRECK'], [A_WALK, A_INSPECT],
     'A DOCKING AIRLOCK.  THE SEAL IS HOLDING.'),
    ('TUBE', 'tube', 'DOCKING TUBE', F_WALK | F_DMG,
     ['FLEXIBLE DOCKING TUBE', 'PRESSURIZED'], [A_WALK, A_INSPECT],
     'THE DOCKING TUBE FLEXES UNDER YOUR BOOTS.'),
    ('THRUST', 'thrust', 'THRUSTER', F_DMG,
     ['MAIN THRUSTER, 2 KN', '\x01', 'BOLTED TO THE HULL'], [A_INSPECT],
     'A THRUSTER NOZZLE, BLACK WITH SOOT.'),
    ('FUEL', 'fuel', 'FUEL TANK', F_DMG,
     ['FUEL TANK, 400 L', '\x01', 'HEAVY: TAKES ONE CARRY SLOT'], [A_INSPECT],
     'A FUEL TANK.  IT SLOSHES WHEN YOU KNOCK.'),
    ('SCRUB', 'scrub', 'AIR SCRUBBER', F_DMG,
     ['CO2 SCRUBBER', '\x01', 'KEEPS A ROOM BREATHABLE'], [A_INSPECT],
     'AN AIR SCRUBBER.  THE FILTERS NEED CHANGING.'),
    ('BREACH', 'breach', 'HULL BREACH', 0,
     ['A HOLE IN THE HULL', 'AIR ESCAPES THROUGH HERE'], [A_INSPECT],
     'SOMETHING PUNCHED RIGHT THROUGH THE HULL.'),
    ('PLAYER', 'player', 'YOU', 0, [], [], ''),
]
TYPE = {t[0]: i for i, t in enumerate(TYPES)}
assert len(TYPES) <= 32

PLAYER_INFO = ['SUIT   MK1 WORK SUIT     O2 90 OF 90 L',
               'BATT   SMALL CELL        CHARGE 100%',
               'HANDS  CUTTER / EMPTY    BACK  SMALL PACK 0/4',
               'NO WARNINGS']
PLAYER_ACTIONS = [A_INSPECT]
PLAYER_INSPECT = 'THAT IS YOU, IN A WORK SUIT THAT HAS SEEN BETTER DAYS.'
WELCOME = 'DOCKED TO THE KESTREL 9.  ARROWS OR WASD WALK, MOUSE SHOWS AND CLICKS.'
TOO_FAR = 'TOO FAR AWAY - WALK NEXT TO IT FIRST.'
IN_WAY = 'SOMETHING IS IN THE WAY.'
BLOCKED = 'THE WAY IS BLOCKED.'


def dmg_pct(step):
    return '%d%%' % int(step * 6.25 + 0.5)


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

    # the tug: hull x4-19, y26-38
    fill(4, 26, 19, 38, 'WALL')
    fill(5, 27, 9, 30, 'FLOOR')         # cockpit
    fill(11, 27, 18, 30, 'FLOOR')       # engine bay
    fill(5, 32, 18, 32, 'FLOOR')        # corridor
    fill(5, 34, 9, 37, 'FLOOR')         # quarters
    fill(11, 34, 18, 37, 'FLOOR')       # hold
    for d in ((7, 31), (14, 31), (7, 33), (14, 33)):
        put(d[0], d[1], 'DOORO')
    put(6, 27, 'HELM'); put(7, 27, 'HELM')
    put(12, 27, 'REACT'); put(13, 27, 'BATT'); put(17, 27, 'FUEL'); put(18, 27, 'FUEL')
    fill(12, 28, 16, 28, 'PIPE')
    put(5, 36, 'BUNK'); put(5, 37, 'BUNK'); put(9, 37, 'LOCKER'); put(5, 34, 'O2'); put(6, 34, 'SCRUB')
    put(17, 37, 'LOCKER'); put(18, 37, 'LOCKER'); put(18, 36, 'LOCKER')
    put(3, 28, 'THRUST'); put(3, 36, 'THRUST')
    # the docking tube and the airlocks
    put(19, 32, 'LOCK')
    fill(20, 32, 29, 32, 'TUBE')
    put(30, 32, 'LOCK')

    # the wreck: hull x30-90, y6-58
    for y in range(6, 59):
        for x in range(30, 91):
            if not (x == 30 and y == 32):
                put(x, y, 'WALL')
    rooms = {
        'bridge': (31, 7, 44, 17), 'crew': (46, 7, 57, 17),
        'mess': (31, 19, 44, 29), 'med': (46, 19, 57, 29),
        'armory': (63, 7, 75, 17), 'cargo_a': (77, 7, 89, 29), 'lab': (63, 19, 75, 29),
        'engine': (31, 35, 46, 57), 'life': (48, 35, 57, 45), 'fuelrm': (48, 47, 57, 57),
        'cargo_b': (63, 35, 89, 45), 'vented': (63, 47, 89, 57),
    }
    for name, r in rooms.items():
        fill(*r, 'VENT' if name == 'vented' else 'FLOOR')
    fill(31, 31, 89, 33, 'FLOOR')       # the corridors
    fill(59, 7, 61, 57, 'FLOOR')
    for d in ((45, 12), (58, 12), (38, 30), (52, 30), (58, 24), (62, 12), (76, 10),
              (83, 30), (62, 24), (69, 30), (38, 34), (52, 34), (47, 40), (58, 52),
              (52, 46), (62, 40), (76, 34)):
        put(d[0], d[1], 'DOOR')
    put(62, 52, 'DOOR')                 # the vented section stays shut
    put(76, 46, 'DOOR')
    put(90, 51, 'BREACH'); put(90, 52, 'BREACH')
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
            if k in ('SPACE', 'STAR', 'BREACH'):
                continue
            if k in ('FLOOR', 'TUBE'):
                d[y][x] = rnd.choice((0, 0, 0, 1, 1, 2))
            elif k in ('WALL',):
                d[y][x] = rnd.choice((0, 1, 1, 2, 3))
            elif x < 20:                # the tug is looked after
                d[y][x] = rnd.choice((0, 1, 2))
            else:
                d[y][x] = rnd.randint(1, 12)
    d[50][70] = 9                       # a few worth reading about
    d[42][36] = 3
    return t, d


def map_pages(t, d):
    """the 48 even video pages (x60, x62 ... xBE) of SCRAP.OVL, in order"""
    pages = []
    for k in range(24):
        cy, cx = divmod(k, CHUNKS_X)
        ty = bytearray(256)
        fl = bytearray(256)
        for i in range(256):
            y, x = cy * 16 + i // 16, cx * 16 + i % 16
            ty[i] = t[y][x]
            fl[i] = d[y][x]
        pages += [bytes(ty), bytes(fl)]
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
ART_PAGE = 0x3A          # x3A00: art, 4 cells a page (6 pages: x3A00-x3FFF)
TAB_PAGE = 0x38          # x3800: info pointers (t * 4 + i), lo then hi
TAB2_PAGE = 0x39         # x3900: the small tables


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
    lines += ['NTYPES     = %d' % n,
              'F_WALK     = 0x%02X' % F_WALK, 'F_DMG      = 0x%02X' % F_DMG,
              'A_OPEN     = %d' % A_OPEN, 'A_CLOSE    = %d' % A_CLOSE,
              'A_INSPECT  = %d' % A_INSPECT, 'A_WALK     = %d' % A_WALK,
              'ART_PG     = 0x%02X' % ART_PAGE,
              'INFO_PG    = 0x%02X        ; x%02X00 + 4t + i: info line i, low bytes; + x80 high' % (TAB_PAGE, TAB_PAGE),
              'TAB_PG     = 0x%02X' % TAB2_PAGE,
              'TB_FLAGS   = 0x00          ; + t', 'TB_NAMEL   = 0x20', 'TB_NAMEH   = 0x40',
              'TB_INSPL   = 0x60', 'TB_INSPH   = 0x80',
              'ACT_PG     = 0x37          ; x3700 + 4t + i: action i of type t (0 none)',
              'TB_ASTRL   = 0xA0          ; + action code', 'TB_ASTRH   = 0xA8',
              'TB_DMGL    = 0xB0          ; + damage step', 'TB_DMGH    = 0xC0',
              'TB_WRKL    = 0xD0', 'TB_WRKH    = 0xE0',
              'BAR_PG     = 0x36          ; x3600 + step: bar string low; + x10 high',
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
    for a, s in ACTIONS.items():
        lab = sref('za_%d' % a, s)
        tab[0xA0 + a] = lab + ' & 0xFF'
        tab[0xA8 + a] = lab + ' >> 8'
    for st in range(16):
        lab = sref('zd_%d' % st, dmg_pct(st))
        tab[0xB0 + st] = lab + ' & 0xFF'
        tab[0xC0 + st] = lab + ' >> 8'
        lab = sref('zw_%d' % st, works(st))
        tab[0xD0 + st] = lab + ' & 0xFF'
        tab[0xE0 + st] = lab + ' >> 8'
    d.append('.fixed 0x%02X00' % TAB2_PAGE)
    d.append('TAB:')
    for o in range(0, 256, 8):
        d.append('    #d8 ' + ', '.join(tab[o:o + 8]))
    d.append('')
    # actions per type
    act = ['0'] * 128
    for i, ty in enumerate(TYPES):
        acts = ty[5] if ty[0] != 'PLAYER' else PLAYER_ACTIONS
        for k, a in enumerate(acts[:4]):
            act[4 * i + k] = str(a)
    bars = ['0'] * 32
    for st in range(16):
        lab = sref('zb_%d' % st, bar(st))
        bars[st] = lab + ' & 0xFF'
        bars[16 + st] = lab + ' >> 8'
    d.append('.fixed 0x3700')
    d.append('ACT_TAB:')
    for o in range(0, 128, 8):
        d.append('    #d8 ' + ', '.join(act[o:o + 8]))
    d.append('')
    d.append('.fixed 0x3600')
    d.append('BAR_TAB:')
    for o in range(0, 32, 8):
        d.append('    #d8 ' + ', '.join(bars[o:o + 8]))
    d.append('')
    # messages
    for lab, s in (('s_welcome', WELCOME), ('s_toofar', TOO_FAR), ('s_inway', IN_WAY),
                   ('s_blocked', BLOCKED)):
        sref(lab, s)
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
    open(os.path.join(HERE, 'scrap_data.masm'), 'w').write('\n'.join(d))


def write_ovl(path=None):
    t, dmg = build_map()
    data = b''.join(map_pages(t, dmg))
    path = path or os.path.join(SDCARD, 'SCRAP.OVL')
    open(path, 'wb').write(data)
    return data


def main():
    write_sources()
    data = write_ovl()
    print('scrap_types.asm, scrap_data.masm, SCRAP.OVL (%d bytes)' % len(data))


if __name__ == '__main__':
    sys.exit(main())

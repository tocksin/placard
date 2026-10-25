#!/usr/bin/env python3
"""
gen_kicad_pcb.py - lay out the main board's outline, dimensions, connectors,
expansion slots, cartridge slot and mounting holes in kicad/placard.kicad_pcb,
and draw the layout drawing docs/placard_board_layout.png.

    python3.12 gen_kicad_pcb.py          # update the board file
    python3.12 gen_kicad_pcb.py --png    # and export the drawing

Needs KiCad 7's Python module (apt-get install kicad kicad-footprints; on
Ubuntu 24.04 it is built for python3.12) and, for --png, kicad-cli and
cairosvg (pip install cairosvg).

Board: 4 layers, 290 x 290 mm: the width of the keyboard (Justin,
2026-10-22), and since 2026-10-23 twice the first 140 mm depth, so kit
builders have room around every part (Justin).  The drawing has the back edge at the top and the keyboard
side (front) at the bottom.  The keyboard lies over the front 65 mm of the
board, so everything a user plugs in sits in the back 75 mm, under the flat
part of the case top:

- back edge: USB-C power J13, audio line out J6, VGA J7, stacked PS/2 J5
- left side: power switch SW1, reset button SW2, SD card J4
- right side: the two SNES pad ports J2, J3 (toward the back; not settled,
  the other choice is the front, which the keyboard blocks)
- top loading, standing up through the case top: the cartridge slot J8
  behind the keyboard, and the four expansion slots J9-J12 (cartridge-style
  card shells) in a bay at the back left

Since 2026-10-22 it also places every other part on the schematic as a fit
test (no routing): chips in rows grouped by schematic sheet, each socketed
(placard:DIP-nn_..._Socket_Puller footprints) with PULL mm of chip-puller room kept
clear past both socket ends, decoupling capacitor Cn beside Un, passives in
blocks near what they serve.  It then checks courtyard overlaps (its own
check and KiCad's DRC), puller room and parts off the board, prints the
share of the board covered, and --png also draws docs/placard_placement.png.

The script owns the board outline (Edge.Cuts), everything on Dwgs.User and
Cmts.User, the mounting holes H1-H8 and the footprints it places (the table
below); rerunning it puts those back where the table says and leaves every
other footprint and track alone.  Each placed footprint is linked to its
schematic symbol (same path as "Update PCB from Schematic" would give), so
updating from the schematic fills in the nets without moving them.

Footprints: KiCad's own where it has the part, and the PRELIMINARY ones from
gen_kicad_connectors.py otherwise (cartridge slot, expansion slots, PS/2,
SNES, switches), whose hole patterns must be checked against the datasheets.

Date: 2026-10-25
"""

import glob
import math
import os
import re
import subprocess
import sys

import pcbnew

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
KDIR = os.path.join(ROOT, "kicad")
PCB = os.path.join(KDIR, "placard.kicad_pcb")
PNG = os.path.join(ROOT, "docs", "placard_board_layout.png")
PLACE_PNG = os.path.join(ROOT, "docs", "placard_placement.png")
STOCK = os.environ.get("KICAD7_FOOTPRINT_DIR", "/usr/share/kicad/footprints")
LIBS = {"placard": os.path.join(KDIR, "lib", "placard.pretty")}

W, D = 290.0, 290.0          # board width (left-right) and depth (back-front), mm (290 deep since 2026-10-23)
X0, Y0 = 50.0, 50.0          # back left corner on the KiCad page
KB_LINE = D - 65.0           # keyboard's back edge, mm from the back edge (it covers the front 65 mm)
TOP = "Dwgs.User"            # dimensions and notes
NOTE = "Cmts.User"           # zones and labels
PULL_LAYER = "Eco1.User"     # chip puller room past the socket ends

FP_DSUB = "placard:DSUB-15-HD_Female_Horizontal_P2.29x1.98mm_EdgePinOffset3.03mm_Housed_MountingHolesOffset4.94mm"
FP_AUDIO = "placard:Jack_3.5mm_Tensility_54-00174_Horizontal"
FP_USBC = "placard:USB_C_Receptacle_GCT_USB4125_6P_HandSolder"
FP_SD = "placard:SD_Kyocera_145638009511859+"
FP_KBD = "Connector_IDC:IDC-Header_2x10_P2.54mm_Vertical"
FP_CART = "placard:Molex_87715-9106_PCIe_x4_Vertical"
FP_EXP = "placard:CardEdge_2x20_P2.54mm_Vertical"
FP_PS2 = "placard:PS2_Kycon_KMDGX-6S-6S-S4N"
FP_SNES = "placard:SNES_Pad_Socket_Horizontal"
FP_SW1 = "placard:SW_Toggle_CIT_ANT11TFHQE"
FP_SW2 = "placard:SW_Tactile_SPST_Angled_PTS645Vx58-2LFS"
FP_HOLE = "MountingHole:MountingHole_3.2mm_M3_Pad_Via"

# Each footprint's anchor, in its own coordinates: for an edge connector the
# middle of its face on the board edge line, for the rest the point the
# table positions.  The edge connectors from KiCad's library open toward +y,
# the project ones toward -y (gen_kicad_connectors.py).
ANCHOR = {
    FP_DSUB: (-4.315, 6.99),      # shell centre, 4.94 mm from the mounting holes to the edge
    FP_AUDIO: (0.0, 0.0),
    FP_USBC: (0.0, 3.4),          # the footprint's "PCB Edge" line
    FP_SD: (0.55, 17.5),          # socket front, card goes in from +y
    FP_KBD: (1.27, 11.43),        # middle of the 2 x 10 pins
    FP_CART: (16.5, 0.0),         # middle of the contacts
    FP_EXP: (24.13, 0.0),
    FP_PS2: (0.0, 0.0), FP_SNES: (0.0, 0.0), FP_SW1: (0.0, 0.0), FP_SW2: (2.25, -2.59),     # body face; the plunger reaches 3.3 mm past the edge
    FP_HOLE: (0.0, 0.0),
}
OPENS_UP = {FP_PS2, FP_SNES, FP_SW1, FP_SW2, FP_AUDIO}
# rotation that turns a connector's opening toward each edge
EDGE_ROT = {"back": (180, 0), "left": (270, 90), "right": (90, 270)}   # (stock, project)

SLOT_PITCH = 26.67           # 1.05" between expansion slots: the card shells' keepout is 25.8 mm across
SLOT_X = [42.0 + i * SLOT_PITCH for i in range(4)]
SLOT_Y = 39.0                # middle of each slot, from the back edge
BAY_END = 76.5               # front end of the expansion bay
# (the keyboard header J1 went with the matrix keyboard, 2026-10-25)

# ref, footprint, edge (or None), position along that edge or (x, y), rotation for None
PLACE = [
    ("J13", FP_USBC, "back", 16.0),
    ("J6", FP_AUDIO, "back", 135.0),
    ("J7", FP_DSUB, "back", 165.0),
    ("J5", FP_PS2, "back", 205.0),
    ("SW1", FP_SW1, "left", 18.0),
    ("SW2", FP_SW2, "left", 34.0),
    ("J4", FP_SD, "left", 60.0),
    ("J2", FP_SNES, "right", 22.0),
    ("J3", FP_SNES, "right", 50.0),
    ("J8", FP_CART, None, (175.0, 55.0), 0),
] + [("J%d" % (9 + i), FP_EXP, None, (x, SLOT_Y), 90) for i, x in enumerate(SLOT_X)]

HOLES = [(5.0, 5.0), (W - 5.0, 5.0), (5.0, D - 5.0), (W - 5.0, D - 5.0), (145.0, D - 5.0), (240.0, 5.0),
         (5.0, D / 2), (W - 5.0, D / 2)]


# ---- component placement (a fit test: every part placed, nothing routed) ----
#
# Every other part on the schematic is placed by the tables below, grouped
# by schematic sheet.  The chips sit in rows across the board with pin 1 at
# the lower left (toward the front); every chip is socketed, so it uses
# kit socket footprint (KiCad's "_Socket" one plus puller room and part number) and
# keeps PULL mm clear past both ends of the socket body for a chip puller.
# Each chip's decoupling capacitor Cn sits along the long side of Un, in the
# channel between rows.  Passives are packed in blocks near what they serve.

PULL = 2.5                   # puller room past each socket end, mm
ROW_GAP = 6.0                # socket courtyard to socket courtyard along a row: room for a kit builder's iron
CELL_GAP = 1.5               # courtyard to courtyard inside a passive block
ROW_Y = [96.0, 131.0, 166.0, 201.0, 236.0, 271.0]   # chip rows, 35 mm apart (the last two under the keyboard)
X_END = 280.0                # rows spread from x = 10 to here

# Rows of chips: (centre y, decap side "below"/"above", items).  An item is a
# reference (chip, with its decap), ("at", x) to move to x (("at", x0, x1)
# first spreads the row evenly from x0 to x1), or
# ("block", width, [refs], angle=90) for a block of passives centred on the row.
# Back to front: video, clock + memory, control + data bus, ALU, PC + address
# mux, shared port (port PLD and PS/2 receiver PLD).
ROWS = [
    (ROW_Y[0], "below", [("at", 10.0, X_END), "U16", "U22", "U23", "U36", "U13", "U14", "U15"]),
    (ROW_Y[1], "below", [("at", 10.0, X_END), "U35", "U29", "X1", "U31", "U32", "U11", "U25"]),
    (ROW_Y[2], "below", [("at", 10.0, X_END), "U12", "U1", "U2", "U17", "U18", "U26",
                         ("block", 45.0, ["R5", "R6", "R7", "R8", "R9", "R10", "R11", "R12"])]),
    (ROW_Y[3], "below", [("at", 10.0, X_END), "U5", "U6", "U19", "U20", "U21", "U27",
                         ("block", 50.0, ["R3", "R4", "JP1", "JP2", "R13", "R51", "R52", "R53", "R54"])]),
    (ROW_Y[4], "below", [("at", 10.0, X_END), "U3", "U4", "U7", "U8", "U9", "U10",
                         ("block", 30.0, ["RN1"], 0)]),
    (ROW_Y[5], "below", [("at", 10.0, 132.0), ("block", 22.0, ["U40", "C40", "C47"]), "U38", "U42"]),
]

# Blocks of passives: (x0, y0, x1, y1, angle, refs), filled in columns left to right
BLOCKS = [
    # video out: DAC ladders, sync and audio, along the back edge behind the VGA and audio jacks
    (111.0, 15.0, 272.0, 46.5, 90,
     ["R14", "R15", "R16", "R17", "R18", "R19", "R20", "R21", "R22", "R23", "R24", "R25", "R26", "R27",
      "R28", "R29", "R30", "R31", "R32", "R33", "R34", "R35", "R36", "R37", "R38", "R39", "R56", "R57",
      "R58", "R61", "R62", "D9", "D10", "D11", "D12", "D13", "D14", "D15", "D16", "D17",
      "C45", "C46", "C44"]),
    # shared port: the PS/2 diodes beside the cartridge slot, pull-ups under it
    (111.0, 49.0, 154.5, 61.0, 90, ["D1", "D2", "D3", "D4", "D5", "D6", "D19"]),
    (111.0, 63.0, 272.0, 77.0, 90, ["R40", "R41", "R42", "R43", "R44", "R45", "R46", "R47", "R48", "R49", "R50",
                                   "R55", "R60"]),
]

# Single parts: (ref, centre x, centre y, angle).  Power, at the back left
# between the power switch and the expansion bay (the relay and the bulk
# capacitor are the tallest parts, so they stay out from under the keyboard).
FIXED = [
    ("R1", 28.5, 3.2, 0), ("R2", 28.5, 6.6, 0),
    ("K1", 24.75, 18.0, 90),
    ("C41", 17.9, 31.8, 0), ("F1", 24.4, 31.8, 90), ("D7", 33.4, 34.8, 90),
    ("D8", 18.4, 39.2, 0), ("NT1", 28.0, 40.0, 0),
]

DECAP = {"U%d" % n: "C%d" % n for n in list(range(1, 24)) + [25, 26, 27, 29, 31, 32, 35, 36, 38, 42]}
DECAP["X1"] = "C43"


def mm(v):
    return pcbnew.FromMM(v)


def pt(x, y):
    """Board coordinates (mm from the back left corner) to a KiCad point."""
    return pcbnew.VECTOR2I(mm(X0 + x), mm(Y0 + y))


def rot(x, y, deg):
    a = math.radians(deg)
    return x * math.cos(a) + y * math.sin(a), -x * math.sin(a) + y * math.cos(a)


def symbols():
    """Reference -> (path, sheet name, sheet file) from the schematic, for linking footprints."""
    root = open(os.path.join(KDIR, "placard.kicad_sch")).read()
    names = {}
    for m in re.finditer(r'\(sheet .*?\(uuid ([0-9a-f-]+)\).*?\(property "Sheetname" "([^"]*)".*?'
                         r'\(property "Sheetfile" "([^"]*)"', root, re.S):
        names[m.group(1)] = (m.group(2), m.group(3))
    out = {}
    for fn in glob.glob(os.path.join(KDIR, "*.kicad_sch")):
        s = open(fn).read()
        for m in re.finditer(r'\(symbol \(lib_id "[^"]+"\).*?\(uuid ([0-9a-f-]+)\) \(property "Reference" "([^"]+)"'
                             r'.*?\(path "/[0-9a-f-]+/([0-9a-f-]+)"', s):
            sheet = m.group(3)
            out[m.group(2)] = ("/%s/%s" % (sheet, m.group(1)),) + names.get(sheet, ("", os.path.basename(fn)))
    return out


_PRELOAD = {}


def preload():
    """Load every footprint before the board: in KiCad 7's Python, FootprintLoad stops
    working once a board has been loaded."""
    for p in PLACE:
        _PRELOAD.setdefault(p[1], []).append(_load(p[1]))
    _PRELOAD[FP_HOLE] = [_load(FP_HOLE) for _ in HOLES]
    fps = sch_footprints()
    for ref in placed_refs():
        if ref not in fps:
            sys.exit("not on the schematic: " + ref)
        _PRELOAD.setdefault(socketed(fps[ref]), []).append(_load(socketed(fps[ref])))
        FPID[ref] = socketed(fps[ref])


def load_fp(fpid):
    return _PRELOAD[fpid].pop()


def _load(fpid):
    lib, name = fpid.split(":")
    path = LIBS.get(lib, os.path.join(STOCK, lib + ".pretty"))
    fp = pcbnew.FootprintLoad(path, name)
    if fp is None:
        sys.exit("footprint not found: " + fpid)
    fp.SetFPID(pcbnew.LIB_ID(lib, name))
    return fp


def place(board, syms, ref, fpid, edge, where, angle=0):
    fp = load_fp(fpid)
    fp.SetReference(ref)
    if ref in syms:
        path, sname, sfile = syms[ref]
        fp.SetPath(pcbnew.KIID_PATH(path))
        fp.SetProperty("Sheetname", sname)
        fp.SetProperty("Sheetfile", sfile)
        fp.SetValue(VALUES.get(ref, fp.GetValue()))
    if edge:
        angle = EDGE_ROT[edge][1 if fpid in OPENS_UP else 0]
        x, y = {"back": (where, 0.0), "left": (0.0, where), "right": (W, where)}[edge]
    else:
        x, y = where
    ax, ay = rot(*ANCHOR[fpid], angle)
    fp.SetOrientationDegrees(angle)
    fp.SetPosition(pt(x - ax, y - ay))
    fp.Reference().SetTextSize(pcbnew.VECTOR2I(mm(2.0), mm(2.0)))
    fp.Reference().SetTextThickness(mm(0.3))
    board.Add(fp)
    return fp


# ---- placement engine

FPID = {}                    # ref -> footprint, for the placed parts
PULL_ZONES = []              # (ref, x0, y0, x1, y1): puller room past each socket end
SOCKETS = []                 # refs of the socketed chips
PROBLEMS = []                # placement problems found while placing
LABELS = []                  # (text, x, y, angle, just) on the notes layer


def sch_footprints():
    out = {}
    for fn in glob.glob(os.path.join(KDIR, "*.kicad_sch")):
        for m in re.finditer(r'\(property "Reference" "([A-Z]+[0-9]+)".*?\(property "Footprint" "([^"]*)"',
                             open(fn).read()):
            out.setdefault(m.group(1), m.group(2))
    return out


def socketed(fpid):
    """Every DIP chip is socketed.  Since 2026-10-23 the schematic names the kit socket
    footprints (placard:DIP-nn_..._Socket_Puller, puller room on User.Eco1); a plain
    stock DIP is mapped to one."""
    if fpid.startswith("Package_DIP:DIP-"):
        return "placard:" + fpid.split(":")[1].replace("_Socket", "") + "_Socket_Puller"
    return fpid


def placed_refs():
    refs = []
    for _, _, items in ROWS:
        for it in items:
            if isinstance(it, str):
                refs.append(it)
                if it in DECAP:
                    refs.append(DECAP[it])
            elif it[0] == "block":
                refs += it[2]
    for b in BLOCKS:
        refs += b[5]
    refs += [f[0] for f in FIXED]
    dup = {r for r in refs if refs.count(r) > 1}
    if dup:
        sys.exit("placed twice: " + " ".join(sorted(dup)))
    return refs


def box(fp, layer):
    """Bounding box (x0, y0, x1, y1) of a footprint's graphics on one layer, board mm."""
    xs, ys = [], []
    for g in fp.GraphicalItems():
        if g.GetLayer() == layer:
            b = g.GetBoundingBox()
            xs += [b.GetLeft(), b.GetRight()]
            ys += [b.GetTop(), b.GetBottom()]
    if not xs:
        for p in fp.Pads():
            b = p.GetBoundingBox()
            xs += [b.GetLeft(), b.GetRight()]
            ys += [b.GetTop(), b.GetBottom()]
    return (min(xs) / 1e6 - X0, min(ys) / 1e6 - Y0, max(xs) / 1e6 - X0, max(ys) / 1e6 - Y0)


def crt(fp):
    return box(fp, pcbnew.F_CrtYd)


def put(board, syms, ref, angle, cy, left=None, cx=None):
    """Place a part by its courtyard: left edge at left (or centre at cx), centre at cy."""
    fp = load_fp(FPID[ref])
    fp.SetReference(ref)
    if ref in syms:
        path, sname, sfile = syms[ref]
        fp.SetPath(pcbnew.KIID_PATH(path))
        fp.SetProperty("Sheetname", sname)
        fp.SetProperty("Sheetfile", sfile)
    fp.SetValue(VALUES.get(ref, fp.GetValue()))
    fp.SetOrientationDegrees(angle)
    fp.SetPosition(pt(0, 0))
    x0, y0, x1, y1 = crt(fp)
    tx = left - x0 if left is not None else cx - (x0 + x1) / 2
    fp.SetPosition(pt(tx, cy - (y0 + y1) / 2))
    fp.Reference().SetTextSize(pcbnew.VECTOR2I(mm(1.0), mm(1.0)))
    fp.Reference().SetTextThickness(mm(0.15))
    board.Add(fp)
    return fp


def block(board, syms, x0, y0, x1, y1, angle, refs):
    """Pack parts in columns, left to right, inside the rectangle; each column is as
    wide as its widest part."""
    sizes = {}
    for ref in refs:
        fp = load_fp(FPID[ref])
        fp.SetOrientationDegrees(angle)
        b = crt(fp)
        sizes[ref] = (b[2] - b[0], b[3] - b[1])
        _PRELOAD[FPID[ref]].append(fp)
    cols, col = [], []
    for ref in refs:
        if col and sum(sizes[r][1] + CELL_GAP for r in col + [ref]) - CELL_GAP > y1 - y0 + 0.01:
            cols.append(col)
            col = []
        col.append(ref)
    cols.append(col)
    x = x0
    for col in cols:
        cw = max(sizes[r][0] for r in col)
        hh = sum(sizes[r][1] + CELL_GAP for r in col) - CELL_GAP
        y = (y0 + y1) / 2 - hh / 2
        for r in col:
            put(board, syms, r, angle, y + sizes[r][1] / 2, cx=x + cw / 2)
            y += sizes[r][1] + CELL_GAP
        x += cw + CELL_GAP
    if x - CELL_GAP > x1 + 0.01:
        PROBLEMS.append("block at (%g, %g) too small: %d parts need %.1f mm, have %.1f"
                        % (x0, y0, len(refs), x - CELL_GAP - x0, x1 - x0))
    return x - CELL_GAP


def item_width(it):
    if isinstance(it, tuple):
        return it[1]
    probe = load_fp(FPID[it])
    probe.SetOrientationDegrees(0 if it == "X1" else 90)
    b = crt(probe)
    _PRELOAD[FPID[it]].append(probe)
    return b[2] - b[0]


def place_parts(board, syms):
    for y, side, items in ROWS:
        x = None
        gap = ROW_GAP
        if items and items[0][0] == "at" and len(items[0]) > 2:
            # spread the row evenly from its start to its end
            parts = [it for it in items[1:] if not (isinstance(it, tuple) and it[0] == "at")]
            room = items[0][2] - items[0][1] - sum(item_width(it) for it in parts)
            gap = max(ROW_GAP, room / max(1, len(parts) - 1))
        for it in items:
            if isinstance(it, tuple) and it[0] == "at":
                x = it[1]
                continue
            if isinstance(it, tuple) and it[0] == "block":
                angle = it[3] if len(it) > 3 else 90
                block(board, syms, x, y - 6.0, x + it[1], y + 6.0, angle, it[2])
                x += it[1] + gap
                continue
            fp = put(board, syms, it, 0 if it == "X1" else 90, y, left=x)
            c = crt(fp)
            x = c[2] + gap
            if FPID[it].endswith("_Socket_Puller"):
                SOCKETS.append(it)
                f = box(fp, pcbnew.F_Fab)
                PULL_ZONES.append((it, f[0] - PULL, f[1], f[0], f[3]))
                PULL_ZONES.append((it, f[2], f[1], f[2] + PULL, f[3]))
            if it in DECAP:
                cap = DECAP[it]
                probe = load_fp(FPID[cap])
                cb = crt(probe)
                _PRELOAD[FPID[cap]].append(probe)
                h = cb[3] - cb[1]
                cy = c[3] + h / 2 + 1.0 if side == "below" else c[1] - h / 2 - 1.0
                put(board, syms, cap, 0, cy, cx=c[2] - (cb[2] - cb[0]) / 2 - 1.0)
    for x0, y0, x1, y1, angle, refs in BLOCKS:
        block(board, syms, x0, y0, x1, y1, angle, refs)
    for ref, x, y, angle in FIXED:
        put(board, syms, ref, angle, y, cx=x)
    # (the puller room is drawn on User.Eco1 by the socket footprints themselves)


def check(board):
    """Courtyard overlaps, puller room, parts off the board; returns report lines."""
    out = list(PROBLEMS)
    fps = {fp.GetReference(): fp for fp in board.GetFootprints()}
    boxes = {r: crt(fp) for r, fp in fps.items()}
    placed = set(placed_refs())

    def hit(a, b):
        return a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]

    for ref, *z in PULL_ZONES:
        for r, b in boxes.items():
            if r != ref and hit(z, b):
                out.append("puller room of %s blocked by %s" % (ref, r))
    refs = sorted(boxes)
    for i, a in enumerate(refs):
        for b in refs[i + 1:]:
            if (a in placed or b in placed) and hit(boxes[a], boxes[b]):
                out.append("courtyard boxes overlap: %s / %s" % (a, b))
    for r in sorted(placed):
        x0, y0, x1, y1 = boxes[r]
        if x0 < 0 or y0 < 0 or x1 > W or y1 > D:
            out.append("%s courtyard off the board" % r)
    # KiCad's own DRC (courtyard overlap, holes, edge clearance)
    rpt = os.path.join(KDIR, "_drc.rpt")
    board = pcbnew.LoadBoard(PCB)          # fresh copy, so the courtyard caches match the placement
    pcbnew.WriteDRCReport(board, rpt, pcbnew.EDA_UNITS_MILLIMETRES, False)
    text_ = open(rpt).read()
    os.remove(rpt)
    kinds = re.findall(r"^\[(\w+)\]", text_, re.M)
    for k in sorted(set(kinds)):
        out.append("DRC %s: %d" % (k, kinds.count(k)))
    for m in re.finditer(r"^\[courtyards_overlap\].*?\n(.*?)\n(.*?)\n", text_, re.M | re.S):
        out.append("  overlap: %s / %s" % (m.group(1).strip()[:70], m.group(2).strip()[:70]))
    return out


def density(board):
    """Share of the board covered by courtyards and puller room, on a 0.5 mm grid."""
    step = 0.5
    nx, ny = int(W / step), int(D / step)
    used = bytearray(nx * ny)
    rects = [crt(fp) for fp in board.GetFootprints()] + [z[1:] for z in PULL_ZONES]
    for x0, y0, x1, y1 in rects:
        for j in range(max(0, int(y0 / step)), min(ny, int(math.ceil(y1 / step)))):
            for i in range(max(0, int(x0 / step)), min(nx, int(math.ceil(x1 / step)))):
                used[j * nx + i] = 1
    def share(ya, yb):
        n = t = 0
        for j in range(int(ya / step), int(yb / step)):
            n += sum(used[j * nx:(j + 1) * nx])
            t += nx
        return n / t
    return share(0, D), share(0, KB_LINE), share(KB_LINE, D)


VALUES = {}


def schematic_values():
    for fn in glob.glob(os.path.join(KDIR, "*.kicad_sch")):
        for m in re.finditer(r'\(property "Reference" "([^"]+)".*?\(property "Value" "([^"]*)"', open(fn).read()):
            VALUES.setdefault(m.group(1), m.group(2))


def seg(board, layer, x1, y1, x2, y2, w=0.15):
    s = pcbnew.PCB_SHAPE(board)
    s.SetShape(pcbnew.SHAPE_T_SEGMENT)
    s.SetStart(pt(x1, y1))
    s.SetEnd(pt(x2, y2))
    s.SetLayer(board.GetLayerID(layer))
    s.SetWidth(mm(w))
    board.Add(s)


def dashed(board, layer, x1, y1, x2, y2, dash=3.0, gap=2.0):
    n = math.hypot(x2 - x1, y2 - y1)
    t = 0.0
    while t < n:
        e = min(t + dash, n)
        seg(board, layer, x1 + (x2 - x1) * t / n, y1 + (y2 - y1) * t / n,
            x1 + (x2 - x1) * e / n, y1 + (y2 - y1) * e / n)
        t = e + gap


def text(board, layer, s, x, y, size=2.0, angle=0, just=0):
    t = pcbnew.PCB_TEXT(board)
    t.SetText(s)
    t.SetPosition(pt(x, y))
    t.SetLayer(board.GetLayerID(layer))
    t.SetTextSize(pcbnew.VECTOR2I(mm(size), mm(size)))
    t.SetTextThickness(mm(size * 0.15))
    t.SetTextAngleDegrees(angle)
    t.SetHorizJustify({-1: pcbnew.GR_TEXT_H_ALIGN_LEFT, 0: pcbnew.GR_TEXT_H_ALIGN_CENTER,
                       1: pcbnew.GR_TEXT_H_ALIGN_RIGHT}[just])
    board.Add(t)


def dim(board, x1, y1, x2, y2, height, size=1.5):
    d = pcbnew.PCB_DIM_ALIGNED(board, pcbnew.PCB_DIM_ALIGNED_T)
    d.SetLayer(board.GetLayerID(TOP))
    d.SetStart(pt(x1, y1))
    d.SetEnd(pt(x2, y2))
    d.SetHeight(mm(height))
    d.SetUnitsMode(pcbnew.DIM_UNITS_MODE_MILLIMETRES)
    d.SetPrecision(pcbnew.DIM_PRECISION_X_X)
    d.SetSuppressZeroes(True)
    d.SetTextSize(pcbnew.VECTOR2I(mm(size), mm(size)))
    d.SetTextThickness(mm(size * 0.15))
    d.SetLineThickness(mm(0.12))
    d.SetArrowLength(mm(1.5))
    d.SetExtensionOffset(mm(0.5))
    d.SetKeepTextAligned(True)
    d.Update()
    board.Add(d)


def clear(board, refs):
    owned = {board.GetLayerID(l) for l in ("Edge.Cuts", TOP, NOTE, PULL_LAYER)}
    for item in list(board.GetDrawings()):
        item = item.Cast()
        if item.GetLayer() in owned:
            board.Delete(item)
    # (looked up by reference: iterating an empty footprint list fails in KiCad 7's Python)
    for ref in sorted(refs) + ["H%d" % i for i in range(1, 21)]:
        fp = board.FindFootprintByReference(ref)
        if fp is not None:
            board.Delete(fp)


def build():
    preload()
    board = pcbnew.LoadBoard(PCB)
    syms = symbols()
    schematic_values()
    clear(board, {p[0] for p in PLACE} | set(placed_refs()))

    # outline, 3 mm corner radius
    r = 3.0
    for x1, y1, x2, y2 in [(r, 0, W - r, 0), (W, r, W, D - r), (W - r, D, r, D), (0, D - r, 0, r)]:
        seg(board, "Edge.Cuts", x1, y1, x2, y2, 0.1)
    for cx, cy, a0 in [(r, r, 180), (W - r, r, 270), (W - r, D - r, 0), (r, D - r, 90)]:
        a = pcbnew.PCB_SHAPE(board)
        a.SetShape(pcbnew.SHAPE_T_ARC)
        a.SetCenter(pt(cx, cy))
        a.SetStart(pt(cx + r * math.cos(math.radians(a0)), cy + r * math.sin(math.radians(a0))))
        a.SetArcAngleAndEnd(pcbnew.EDA_ANGLE(90, pcbnew.DEGREES_T))
        a.SetLayer(board.GetLayerID("Edge.Cuts"))
        a.SetWidth(mm(0.1))
        board.Add(a)

    for p in PLACE:
        place(board, syms, *p)
    place_parts(board, syms)
    for i, (x, y) in enumerate(HOLES):
        h = load_fp(FP_HOLE)
        h.SetReference("H%d" % (i + 1))
        h.SetValue("M3")
        h.SetAttributes(h.GetAttributes() | pcbnew.FP_BOARD_ONLY | pcbnew.FP_EXCLUDE_FROM_BOM
                        | pcbnew.FP_EXCLUDE_FROM_POS_FILES)
        h.SetPosition(pt(x, y))
        h.Reference().SetVisible(False)
        board.Add(h)

    # ---- zones and labels
    dashed(board, NOTE, 0, KB_LINE, W, KB_LINE)
    cx, cy = 175.0, 55.0
    for x1, y1, x2, y2 in [(cx - 41, cy - 5, cx + 41, cy - 5), (cx + 41, cy - 5, cx + 41, cy + 5),
                           (cx + 41, cy + 5, cx - 41, cy + 5), (cx - 41, cy + 5, cx - 41, cy - 5)]:
        dashed(board, NOTE, x1, y1, x2, y2, 2.0, 1.5)
    bx0, bx1 = SLOT_X[0] - 7.0, SLOT_X[-1] + 7.0
    for x1, y1, x2, y2 in [(bx0, 1.5, bx1, 1.5), (bx1, 1.5, bx1, BAY_END),
                           (bx1, BAY_END, bx0, BAY_END), (bx0, BAY_END, bx0, 1.5)]:
        dashed(board, NOTE, x1, y1, x2, y2, 2.0, 1.5)
    text(board, NOTE, "BACK", W / 2, -44.0, 3.0)
    text(board, NOTE, "FRONT (keyboard side)", W / 2, D + 32.0, 3.0)
    text(board, NOTE, "LEFT SIDE", -40.0, D / 2, 3.0, angle=90)
    text(board, NOTE, "RIGHT SIDE", W + 46.0, D / 2, 3.0, angle=90)
    notes = [
        "PLACARD main board: 4 layers (In1 GND, In2 +5V), 1.6 mm, %g x %g mm, 3 mm corner radius" % (W, D),
        "Dimensions in mm from the back left corner to connector centre lines (edge connectors: middle of the face on the edge)",
        "H1-H%d: M3 mounting holes, 3.2 mm, 5 mm in from the edges: %s" % (len(HOLES), " ".join("(%g,%g)" % h for h in HOLES)),
        "SNES ports on the right side toward the back: not settled (the front is under the keyboard)",
        "PRELIMINARY footprints (check datasheets): J2 J3 J5 J8 J9-J12 SW1 SW2, see src/scripts/gen_kicad_connectors.py",
        "Dashed line: keyboard's back edge; the keyboard lies over the front %g mm (low parts only); the back %g mm is "
        "under the flat case top (user connectors, cartridge, cards)" % (D - KB_LINE, KB_LINE),
        "Dashed boxes: expansion bay (cards stand up through the case top) and the cartridge shell around J8",
        "Placement test (no routing): every chip socketed (kit socket footprints); hatched boxes at the socket ends "
        "= %g mm chip-puller room, kept clear" % PULL,
        "Chip rows, back to front: video | audio slot, oscillator, memory | I/O decode, control, data bus | ALU, data bus | "
        "PC + address mux | shared port",
        "Back: video/audio passives along the back edge, shared-port protection and pull-ups around J8, power at the back left",
    ]
    for i, s in enumerate(notes):
        text(board, NOTE, s, 0, D + 40.0 + i * 4.0, 2.0, just=-1)

    # ---- dimensions
    dim(board, 0, D, W, D, 22.0, 2.0)                  # overall width, below the board
    dim(board, 0, 0, 0, D, 30.0, 2.0)                  # overall depth, left of the board
    tops = [("J13", 16.0)] + [("J%d" % (9 + i), x) for i, x in enumerate(SLOT_X)] + \
           [("J6", 135.0), ("J7", 165.0), ("J8", 175.0), ("J5", 205.0)]
    for i, (ref, x) in enumerate(sorted(tops, key=lambda t: t[1])):
        dim(board, 0, 0, x, 0, -(6.0 + 3.5 * i))
    # left side, from the back edge
    for i, y in enumerate([18.0, 34.0, 60.0]):
        dim(board, 0, 0, 0, y, 8.0 + 4.0 * i)
    # right side, from the back edge
    rights = [22.0, 50.0, 55.0, SLOT_Y, KB_LINE]
    for i, y in enumerate(sorted(rights)):
        dim(board, W, 0, W, y, -(8.0 + 4.0 * i))
    # slot pitch and length
    dim(board, SLOT_X[0], BAY_END + 4.0, SLOT_X[1], BAY_END + 4.0, -0.01, 1.2)
    text(board, TOP, "J9-J12 at 26.67 (1.05\") pitch", SLOT_X[0], BAY_END + 8.0, 1.2, just=-1)

    board.Save(PCB)
    print("wrote", PCB)
    tidy(PCB)
    for line in check(board):
        print(line)
    print("covered by courtyards + puller room: board %.0f %%, back %.0f %%, under the keyboard %.0f %%"
          % tuple(100 * v for v in density(board)))


def tidy(path):
    """Keep the file as KiCad 7 writes it with the project's title block date."""
    s = open(path).read()
    s = re.sub(r'\(date "[^"]*"\)', '(date "2026-10-23")', s, count=1)
    open(path, "w", newline="\n").write(s)


def png():
    import cairosvg
    out = os.path.join(os.path.dirname(PNG), "_layout.svg")
    layers = "Edge.Cuts,F.Fab,F.SilkS,F.Cu,Dwgs.User,Cmts.User"
    subprocess.run(["kicad-cli", "pcb", "export", "svg", "--layers", layers, "--exclude-drawing-sheet",
                    "--page-size-mode", "2", "-o", out, PCB], check=True, capture_output=True)
    cairosvg.svg2png(url=out, write_to=PNG, output_width=4000, background_color="white")
    os.remove(out)
    print("wrote", PNG)


def png_placement():
    import cairosvg
    out = os.path.join(os.path.dirname(PNG), "_place.svg")
    layers = "Edge.Cuts,F.Fab,F.CrtYd,F.Cu,%s,%s" % (PULL_LAYER, NOTE)
    subprocess.run(["kicad-cli", "pcb", "export", "svg", "--layers", layers, "--exclude-drawing-sheet",
                    "--page-size-mode", "2", "-o", out, PCB], check=True, capture_output=True)
    cairosvg.svg2png(url=out, write_to=PLACE_PNG, output_width=5000, background_color="white")
    os.remove(out)
    print("wrote", PLACE_PNG)


if __name__ == "__main__":
    build()
    if "--png" in sys.argv:
        png()
        png_placement()

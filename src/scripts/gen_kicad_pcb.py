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

Board: 4 layers, 290 x 140 mm, the width of the keyboard (Justin,
2026-10-22).  The drawing has the back edge at the top and the keyboard
side (front) at the bottom.  The keyboard lies over the front 65 mm of the
board, so everything a user plugs in sits in the back 75 mm, under the flat
part of the case top:

- back edge: USB-C power J13, headphones J6, VGA J7, stacked PS/2 J5
- left side: power switch SW1, reset button SW2, SD card J4
- right side: the two SNES pad ports J2, J3 (toward the back; not settled,
  the other choice is the front, which the keyboard blocks)
- top loading, standing up through the case top: the cartridge slot J8
  behind the keyboard, and the four expansion slots J9-J12 (cartridge-style
  card shells) in a bay at the back left
- keyboard header J1 just under the keyboard's back edge

The script owns the board outline (Edge.Cuts), everything on Dwgs.User and
Cmts.User, the mounting holes H1-H6 and the footprints it places (the table
below); rerunning it puts those back where the table says and leaves every
other footprint and track alone.  Each placed footprint is linked to its
schematic symbol (same path as "Update PCB from Schematic" would give), so
updating from the schematic fills in the nets without moving them.

Footprints: KiCad's own where it has the part, and the PRELIMINARY ones from
gen_kicad_connectors.py otherwise (cartridge slot, expansion slots, PS/2,
SNES, switches), whose hole patterns must be checked against the datasheets.

Date: 2026-10-22
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
STOCK = os.environ.get("KICAD7_FOOTPRINT_DIR", "/usr/share/kicad/footprints")
LIBS = {"placard": os.path.join(KDIR, "lib", "placard.pretty")}

W, D = 290.0, 140.0          # board width (left-right) and depth (back-front), mm
X0, Y0 = 50.0, 50.0          # back left corner on the KiCad page
KB_LINE = 75.0               # keyboard's back edge, mm from the back edge
TOP = "Dwgs.User"            # dimensions and notes
NOTE = "Cmts.User"           # zones and labels

FP_DSUB = "Connector_Dsub:DSUB-15-HD_Female_Horizontal_P2.29x1.98mm_EdgePinOffset3.03mm_Housed_MountingHolesOffset4.94mm"
FP_AUDIO = "placard:Jack_3.5mm_Tensility_54-00174_Horizontal"
FP_USBC = "Connector_USB:USB_C_Receptacle_GCT_USB4125-xx-x_6P_TopMnt_Horizontal"
FP_SD = "Connector_Card:SD_Kyocera_145638009511859+"
FP_KBD = "Connector_IDC:IDC-Header_2x10_P2.54mm_Vertical"
FP_CART = "placard:Molex_87715-9106_PCIe_x4_Vertical"
FP_EXP = "placard:CardEdge_2x20_P2.54mm_Vertical"
FP_PS2 = "placard:PS2_Kycon_KMDGX-6S-6S-S4N"
FP_SNES = "placard:SNES_Pad_Socket_Horizontal"
FP_SW1 = "placard:SW_Toggle_CIT_ANT11TFHQE"
FP_SW2 = "placard:SW_Push_CK_E112SD1A3QE"
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
    FP_PS2: (0.0, 0.0), FP_SNES: (0.0, 0.0), FP_SW1: (0.0, 0.0), FP_SW2: (0.0, 0.0),
    FP_HOLE: (0.0, 0.0),
}
OPENS_UP = {FP_PS2, FP_SNES, FP_SW1, FP_SW2, FP_AUDIO}
# rotation that turns a connector's opening toward each edge
EDGE_ROT = {"back": (180, 0), "left": (270, 90), "right": (90, 270)}   # (stock, project)

SLOT_PITCH = 20.32           # 0.8" between expansion slots
SLOT_X = [42.0 + i * SLOT_PITCH for i in range(4)]
SLOT_Y = 39.0                # middle of each slot, from the back edge

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
    ("J1", FP_KBD, None, (145.0, 82.0), 90),
] + [("J%d" % (9 + i), FP_EXP, None, (x, SLOT_Y), 90) for i, x in enumerate(SLOT_X)]

HOLES = [(5.0, 5.0), (W - 5.0, 5.0), (5.0, D - 5.0), (W - 5.0, D - 5.0), (145.0, D - 5.0), (240.0, 5.0)]


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
    owned = {board.GetLayerID(l) for l in ("Edge.Cuts", TOP, NOTE)}
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
    clear(board, {p[0] for p in PLACE})

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
    text(board, NOTE, "KEYBOARD ABOVE (front %g mm): low parts only" % (D - KB_LINE), 225.0, KB_LINE + 4.0, 2.0)
    text(board, NOTE, "Flat case top: user connectors, cartridge and cards in the back %g mm" % KB_LINE,
         W / 2 + 40, KB_LINE - 4.0, 2.0)
    cx, cy = 175.0, 55.0
    for x1, y1, x2, y2 in [(cx - 41, cy - 5, cx + 41, cy - 5), (cx + 41, cy - 5, cx + 41, cy + 5),
                           (cx + 41, cy + 5, cx - 41, cy + 5), (cx - 41, cy + 5, cx - 41, cy - 5)]:
        dashed(board, NOTE, x1, y1, x2, y2, 2.0, 1.5)
    text(board, NOTE, "cartridge shell", cx, cy + 8.5, 1.5)
    bx0, bx1 = SLOT_X[0] - 7.0, SLOT_X[-1] + 7.0
    for x1, y1, x2, y2 in [(bx0, 1.5, bx1, 1.5), (bx1, 1.5, bx1, KB_LINE - 1.5),
                           (bx1, KB_LINE - 1.5, bx0, KB_LINE - 1.5), (bx0, KB_LINE - 1.5, bx0, 1.5)]:
        dashed(board, NOTE, x1, y1, x2, y2, 2.0, 1.5)
    text(board, NOTE, "EXPANSION BAY: cards stand up through the case top", (bx0 + bx1) / 2, KB_LINE + 4.0, 1.5)
    text(board, NOTE, "BACK", W / 2, -44.0, 3.0)
    text(board, NOTE, "FRONT (keyboard side)", W / 2, D + 32.0, 3.0)
    text(board, NOTE, "LEFT SIDE", -40.0, D / 2, 3.0, angle=90)
    text(board, NOTE, "RIGHT SIDE", W + 46.0, D / 2, 3.0, angle=90)
    notes = [
        "PLACARD main board: 4 layers (In1 GND, In2 +5V), 1.6 mm, 290 x 140 mm, 3 mm corner radius",
        "Dimensions in mm from the back left corner to connector centre lines (edge connectors: middle of the face on the edge)",
        "H1-H6: M3 mounting holes, 3.2 mm, 5 mm in from the edges: (5,5) (285,5) (5,135) (285,135) (145,135) (240,5)",
        "SNES ports on the right side toward the back: not settled (the front is under the keyboard)",
        "PRELIMINARY footprints (check datasheets): J2 J3 J5 J8 J9-J12 SW1 SW2, see src/scripts/gen_kicad_connectors.py",
    ]
    for i, s in enumerate(notes):
        text(board, NOTE, s, 0, D + 40.0 + i * 4.0, 2.0, just=-1)

    # ---- dimensions
    dim(board, 0, D, W, D, 22.0, 2.0)                  # overall width, below the board
    dim(board, 0, 0, 0, D, 30.0, 2.0)                  # overall depth, left of the board
    tops = [("J13", 16.0)] + [("J%d" % (9 + i), x) for i, x in enumerate(SLOT_X)] + \
           [("J6", 135.0), ("J7", 165.0), ("J1", 145.0), ("J8", 175.0), ("J5", 205.0)]
    for i, (ref, x) in enumerate(sorted(tops, key=lambda t: t[1])):
        dim(board, 0, 0, x, 0, -(6.0 + 3.5 * i))
    # left side, from the back edge
    for i, y in enumerate([18.0, 34.0, 60.0]):
        dim(board, 0, 0, 0, y, 8.0 + 4.0 * i)
    # right side, from the back edge
    rights = [22.0, 50.0, 55.0, SLOT_Y, KB_LINE, 82.0]
    for i, y in enumerate(sorted(rights)):
        dim(board, W, 0, W, y, -(8.0 + 4.0 * i))
    # slot pitch and length
    dim(board, SLOT_X[0], KB_LINE + 9.0, SLOT_X[1], KB_LINE + 9.0, -0.01, 1.2)
    text(board, TOP, "J9-J12 at 20.32 (0.8\") pitch", SLOT_X[0], KB_LINE + 14.0, 1.2, just=-1)

    board.Save(PCB)
    print("wrote", PCB)
    tidy(PCB)


def tidy(path):
    """Keep the file as KiCad 7 writes it with the project's title block date."""
    s = open(path).read()
    s = re.sub(r'\(date "[^"]*"\)', '(date "2026-10-22")', s, count=1)
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


if __name__ == "__main__":
    build()
    if "--png" in sys.argv:
        png()

#!/usr/bin/env python3
"""
gen_case.py - the PLACARD case concept: a split brushed, anodized aluminium
shell with a clear acrylic top over the main board, a keyboard bay in front of
the board (Cherry MX plate, or an acrylic blank for builds without the
keyboard), and one removable acrylic cover per expansion slot (J9-J12) and for
the cartridge slot (J8), held by magnets, with two garages inside to keep the
covers that are out.  See docs/CASE.md.

    pip install cadquery
    python3 gen_case.py [--pcb path/to/placard.kicad_pcb] [--out case] [--mesh dir]

The connector cut-outs are placed from the board file: each footprint's
position and rotation, and the face of its 3D model (kicad/lib/placard.3dshapes)
where it meets the wall.  The board file is only read, never written.  Rerun
after connectors move.

The keyboard is set by ergonomics first: the home row is no more than
HOME_ROW_MAX (30 mm, HFES 100) above the desk, and KB_TILT is the steepest
slope, in 0.5 degree steps, that keeps it there.  The keyboard does not
overlap the main board: even at the back of the bay its PCB is below the main
board's top face.

Parts (STEP in case/, DXF cutting files for the flat parts in case/dxf/):

| File | Part | Material |
|---|---|---|
| lower_shell | floor, keyboard bay walls and ledges, board section walls up to the split line | 2.0 mm 5052 aluminium, bent, brushed, clear or black anodized |
| upper_shell | board section walls from the split line, the riser behind the keyboard, top flange | 2.0 mm 5052 aluminium, bent, brushed, anodized |
| keyboard_rail | Z rail under the plate's back edge | 1.5 mm 5052, anodized |
| acrylic_top | over the board, slot and cartridge openings, magnets | 4 mm clear cast acrylic, laser cut |
| keyboard_plate | Cherry MX switch plate (63 keys, stabilizer cut-outs) | 1.5 mm 5052, anodized |
| keyboard_blank | fills the bay when no keyboard is fitted | 3 mm clear cast acrylic |
| slot_cover | one per expansion slot (4 alike), plug + cap with two magnets | 4 mm + 3 mm acrylic, solvent welded |
| cart_cover | cartridge slot cover, plug + cap with two magnets | 4 mm + 3 mm acrylic |
| garage_1, garage_2 | trays behind the riser for the covers that are out | 1.5 mm 5052 |

Coordinates (mm): x from the case's left outside face, y from the front
outside face toward the back, z up from the main board's top face.  The
keyboard frame is tilted KB_TILT about x (see kb()).

Date: 2026-10-24
"""

import argparse
import json
import math
import os
import re

import cadquery as cq
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.patches import Circle, FancyBboxPatch, Polygon, Rectangle

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
MODELS = os.path.join(REPO, "kicad", "lib", "placard.3dshapes")

# ---------------------------------------------------------------- stack-up
T = 2.0                # aluminium sheet
GAP = 0.5              # board edge to inside face of a wall
OFF = GAP + T          # board's left edge in case x, and its back edge from the back face
PCB_T = 1.6
STANDOFF = 6.0         # floor to the board's underside (VGA J7's pins reach 3.8 mm below it)
FEET = 2.0             # thin rubber feet
Z_FLOOR = -PCB_T - STANDOFF - T     # underside of the floor (z = 0 is the main board's top face)
Z_DESK = Z_FLOOR - FEET
Z_SPLIT = 4.0          # where the lower and upper shells meet, away from the connectors
Z_TOP = 27.0           # underside of the top flange (stacked PS/2 J5 is 25 mm tall)
ACRYLIC = 4.0          # top
CAP = 3.0              # cover caps
FLANGE = 10.0          # top flange width round the board window

# keyboard: Cherry MX on a 1.5 mm plate, in its own bay in front of the main board
U = 19.05              # key pitch
KEY_ROWS = [           # 63-key layout, docs/IO.md "Planned layout: 63 keys", front row first
    [1.25, 1.25, 1.25, 6.25, 1, 1, 1, 1, 1],
    [2.25] + [1] * 10 + [1.75, 1],
    [1.75] + [1] * 11 + [2.25],
    [1.5] + [1] * 12 + [1.5],
    [1] * 13 + [2],
]
HOME_ROW = 2           # row C (A S D F) is the third row from the front
HOME_ROW_MAX = 30.0    # HFES 100: home row 30 mm or less above the desk (35 mm at most)
KEYCAP = 15.0          # plate top to the top of a Cherry-profile home-row keycap
PLATE = 1.5            # MX plate
BLANK = 3.0            # acrylic blank, flush with the bay's rim
RIM = BLANK - PLATE    # bay walls stand this far above the plate's top face
MX_PCB = 5.0           # plate top to keyboard PCB top (Cherry MX)
KB_LEADS = 1.7         # switch pins and leads under the keyboard PCB
MARGIN_F = 6.0         # plate in front of the keys (front ledge, screws)
MARGIN_B = 6.0         # plate behind the keys (rear rail, screws)
PLATE_LEN = MARGIN_F + len(KEY_ROWS) * U + MARGIN_B   # along the slope
LEDGE_S = 3.5          # side ledges under the plate (switch cut-outs start 5.1 mm in)
KB_PCB = (15 * U - 3.0, 7.0, PLATE_LEN - MARGIN_B - 1.5)   # width, front and back edge along the slope


def kb_pt0(theta):
    """Plate top at the front of the bay (z) for tilt theta: the keyboard PCB's
    front edge, with its leads, clears the floor by 0.5 mm."""
    th = math.radians(theta)
    return Z_FLOOR + T + 0.5 + (MX_PCB + PCB_T + KB_LEADS) * math.cos(th) - KB_PCB[1] * math.sin(th)


def home_row_height(theta):
    """Top of the home-row keycaps above the desk."""
    th = math.radians(theta)
    s = MARGIN_F + (HOME_ROW + 0.5) * U
    return kb_pt0(theta) + s * math.sin(th) + KEYCAP * math.cos(th) - Z_DESK


# the steepest tilt (0.5 degree steps) that keeps the home row at HOME_ROW_MAX
KB_TILT = max(t / 2 for t in range(0, 31) if home_row_height(t / 2) <= HOME_ROW_MAX)
TH = math.radians(KB_TILT)
PT0 = kb_pt0(KB_TILT)


def kb(x, s, n):
    """Keyboard frame (x across, s up the slope from the bay's front inside face,
    n out of the plate's top face) -> case coordinates."""
    return (x, T + s * math.cos(TH) - n * math.sin(TH), PT0 + s * math.sin(TH) + n * math.cos(TH))


def kb_solid(wp):
    """A solid drawn in the keyboard frame, placed in the case."""
    return wp.rotate((0, 0, 0), (1, 0, 0), KB_TILT).translate((0, T, PT0))


BOARD_W = 290.0
W = BOARD_W + 2 * OFF
Y_R = T + PLATE_LEN * math.cos(TH) + 0.5       # front face of the riser (upper shell's front wall)
Y_BF = Y_R + T + GAP                            # main board's front edge
BOARD_D = 215.0        # set from the board file by read_board()
D = Y_BF + BOARD_D + GAP + T

# connectors in the walls: side, cut-out profile (plug clearance) and what it is
WALL_PARTS = {
    "J13": ("back", ("slot", 13.0, 7.0), "USB-C power (plug overmould 12.4 x 6.5)"),
    "J6": ("back", ("circle", 8.0), "audio line out"),
    "J7": ("back", ("dsub",), "VGA, 4-40 jackscrews through the wall"),
    "J5": ("back", ("rrect", 15.5, 26.0, 2.0), "stacked PS/2"),
    "SW1": ("left", ("circle", 7.0), "power toggle bushing"),
    "SW2": ("left", ("circle", 4.5), "reset button"),
    "J4": ("left", ("sd",), "SD card slot with thumb notch"),
    "J2": ("right", ("rrect", 27.0, 14.0, 2.0), "SNES port 1"),
    "J3": ("right", ("rrect", 27.0, 14.0, 2.0), "SNES port 2"),
}
STEP_MARGIN = 5.0      # the split line steps this far either side of a cut-out
SNAP = 1.0             # a connector centre this close to Z_SPLIT uses Z_SPLIT

SLOTS = ["J9", "J10", "J11", "J12"]
CART = "J8"
FRONT_HOLES = ("H3", "H5", "H4")               # board holes along the front edge (garage brackets)
LIP = 8.0              # cover cap overlap on the acrylic (room for the magnets)
MAG_D, MAG_T = 6.0, 3.0     # N52 disc magnets, in 6.1 mm holes
GARAGE_Z = 11.0        # underside of the cover garages (socketed DIPs are 9.1 mm)


# ---------------------------------------------------------------- board file
def sexpr_blocks(s, head):
    """Every top-level-ish (head ...) block in s, as text."""
    out = []
    for m in re.finditer(r"\(" + head + r"[\s\"]", s):
        st, d, j = m.start(), 0, m.start()
        while True:
            c = s[j]
            if c == "(":
                d += 1
            elif c == ")":
                d -= 1
                if d == 0:
                    break
            elif c == '"':
                j = s.index('"', j + 1)
            j += 1
        out.append(s[st:j + 1])
    return out


def read_board(path):
    """Footprints by reference: board-local position (mm from the back-left corner,
    y toward the front), rotation, courtyard box and 3D model file name."""
    s = open(path, encoding="utf-8").read()
    edge = []
    for g in sexpr_blocks(s, "gr_line") + sexpr_blocks(s, "gr_arc") + sexpr_blocks(s, "gr_rect"):
        if '"Edge.Cuts"' in g:
            edge += [tuple(map(float, p.split())) for p in
                     re.findall(r"\((?:start|end|mid) ([\d.\-]+ [\d.\-]+)\)", g)]
    ox, oy = min(p[0] for p in edge), min(p[1] for p in edge)
    size = (max(p[0] for p in edge) - ox, max(p[1] for p in edge) - oy)
    assert abs(size[0] - BOARD_W) < 0.1, size
    global BOARD_D, D
    BOARD_D = size[1]
    D = Y_BF + BOARD_D + GAP + T
    parts = {}
    for f in sexpr_blocks(s, "footprint"):
        ref = re.search(r'\(property "Reference" "([^"]+)"', f) or re.search(r'reference "([^"]+)"', f)
        head = f[:f.find("(pad") if "(pad" in f else len(f)]
        at = re.search(r"\n\s*\(at ([\d.\- ]+)\)", head)
        a = list(map(float, at.group(1).split()))
        x, y, r = a[0] - ox, a[1] - oy, (a[2] if len(a) > 2 else 0.0)
        pts = []
        for g in (sexpr_blocks(f, "fp_line") + sexpr_blocks(f, "fp_rect") +
                  sexpr_blocks(f, "fp_poly") + sexpr_blocks(f, "fp_circle")):
            if "CrtYd" in g:
                pts += [tuple(map(float, p.split())) for p in
                        re.findall(r"\((?:start|end|xy|center) ([\d.\-]+ [\d.\-]+)\)", g)]
        th = math.radians(-r)
        wp = [(x + px * math.cos(th) - py * math.sin(th), y + px * math.sin(th) + py * math.cos(th))
              for px, py in pts]
        crt = ([min(p[0] for p in wp), min(p[1] for p in wp), max(p[0] for p in wp), max(p[1] for p in wp)]
               if wp else None)
        model = re.search(r'\(model "([^"]+)"', f)
        parts[ref.group(1)] = dict(fp=re.match(r'\(footprint "([^"]+)"', f).group(1), x=x, y=y, rot=r,
                                   crt=crt, model=os.path.basename(model.group(1)) if model else None)
    return parts


def cx(bx):
    """Board x -> case x."""
    return bx + OFF


def cy(by):
    """Board y (from the back edge, toward the front) -> case y (from the front)."""
    return D - OFF - by


def model_solid(p):
    """A footprint's 3D model placed in case coordinates, or None."""
    if not p["model"]:
        return None
    f = os.path.join(MODELS, p["model"])
    if not os.path.exists(f):
        return None
    sh = cq.importers.importStep(f).val()
    # KiCad 3D: x = board x, y = -board y, z up from the top face
    sh = sh.rotate((0, 0, 0), (0, 0, 1), p["rot"]).translate((p["x"], -p["y"], 0))
    return sh.translate((OFF, D - OFF, 0))


def wall_face(solid, side):
    """Centre (u along the wall, z) of the model where it meets the wall: the part
    that sticks out past the board edge, or else its face at the edge."""
    t = 0.3
    for d in (1.0, -0.4):
        if side == "back":
            box = cq.Solid.makeBox(W, t, 80, cq.Vector(0, D - OFF + d - t / 2, -20))
        elif side == "left":
            box = cq.Solid.makeBox(t, D, 80, cq.Vector(OFF - d - t / 2, 0, -20))
        else:
            box = cq.Solid.makeBox(t, D, 80, cq.Vector(W - OFF + d - t / 2, 0, -20))
        i = solid.intersect(box)
        if i.Volume() > 1e-6:
            b = i.BoundingBox()
            u = (b.xmin + b.xmax) / 2 if side == "back" else (b.ymin + b.ymax) / 2
            return u, (b.zmin + b.zmax) / 2, b
    raise ValueError("model does not reach the %s edge" % side)


# ---------------------------------------------------------------- cut-outs
def cutter(side, u, z, prof, depth=10.0):
    """A solid that cuts prof through the wall on side at (u, z)."""
    kind = prof[0]
    if side == "back":
        plane = cq.Plane(origin=(u, D - T / 2 - depth / 2, z), xDir=(1, 0, 0), normal=(0, 1, 0))
    elif side == "left":
        plane = cq.Plane(origin=(T / 2 + depth / 2, u, z), xDir=(0, -1, 0), normal=(-1, 0, 0))
    else:
        plane = cq.Plane(origin=(W - T / 2 - depth / 2, u, z), xDir=(0, 1, 0), normal=(1, 0, 0))
    wp = cq.Workplane(plane)
    if kind == "circle":
        s = wp.circle(prof[1] / 2).extrude(depth)
    elif kind in ("slot", "rrect"):
        w, h = prof[1], prof[2]
        r = h / 2 - 0.01 if kind == "slot" else prof[3]
        s = wp.rect(w, h).extrude(depth).edges("|" + {"back": "Y", "left": "X", "right": "X"}[side]).fillet(r)
    elif kind == "dsub":
        s = wp.polyline([(-8.5, 4.5), (8.5, 4.5), (7.5, -4.5), (-7.5, -4.5)]).close().extrude(depth)
        for sx in (-12.495, 12.495):
            s = s.union(wp.center(sx, 0).circle(1.6).extrude(depth))
    elif kind == "sd":
        s = wp.rect(27.0, 3.6).extrude(depth)
        s = s.union(wp.center(0, 1.0).rect(14.0, 7.0).extrude(depth).edges(
            "|" + ("Y" if side == "back" else "X")).fillet(3.0))
    return s


def cut_width(prof):
    return {"circle": lambda p: p[1], "slot": lambda p: p[1], "rrect": lambda p: p[1],
            "dsub": lambda p: 24.99 + 3.2, "sd": lambda p: 27.0}[prof[0]](prof)


def step_box(side, u, half, z0, z1):
    """Wall-thick box over u +- half, z0..z1 on side (the split line's step at a connector)."""
    if side == "back":
        return cq.Workplane("XY").box(2 * half, T, z1 - z0, centered=(True, False, False)).translate(
            (u, D - T, z0))
    x = 0 if side == "left" else W - T
    return cq.Workplane("XY").box(T, 2 * half, z1 - z0, centered=(False, True, False)).translate((x, u, z0))


def wall_cutouts(parts):
    """[(ref, side, u, z_centre, z_joint, prof, note)] for every wall connector on the board."""
    out = []
    for ref, (side, prof, note) in WALL_PARTS.items():
        if ref not in parts:
            continue
        solid = model_solid(parts[ref])
        u, z, _ = wall_face(solid, side)
        zj = Z_SPLIT if abs(z - Z_SPLIT) < SNAP else z
        out.append((ref, side, u, z, zj, prof, note))
    return out


# ---------------------------------------------------------------- parts
def rounded_plate(x0, x1, y0, y1, z0, t, r=0.0):
    p = cq.Workplane("XY").box(x1 - x0, y1 - y0, t, centered=False).translate((x0, y0, z0))
    if r > 0:
        p = p.edges("|Z").fillet(r)
    return p


def kb_box(x0, x1, s0, s1, n0, n1):
    """A box in the keyboard frame."""
    return kb_solid(cq.Workplane("XY").box(x1 - x0, s1 - s0, n1 - n0, centered=False).translate((x0, s0, n0)))


def hole(x, y, d, z0, h=20.0):
    return cq.Workplane("XY").center(x, y).circle(d / 2).extrude(h).translate((0, 0, z0))


def openings(parts):
    """Openings in the acrylic top: the expansion bay (one opening over J9-J12's shell
    keepouts, out to the back wall's inside face) and the cartridge (J8's keepout)."""
    xs = [parts[s]["crt"] for s in SLOTS]
    bay = (cx(min(c[0] for c in xs)), cx(max(c[2] for c in xs)),
           cy(max(c[3] for c in xs)), D - T)
    c = parts[CART]["crt"]
    cart = (cx(c[0]), cx(c[2]), cy(c[3]), cy(c[1]))
    slot_x = [(cx(parts[s]["crt"][0]), cx(parts[s]["crt"][2])) for s in SLOTS]
    return bay, cart, slot_x


def window():
    """The board window in the top flange (x0, x1, y0, y1)."""
    return (FLANGE, W - FLANGE, Y_R + FLANGE, D - FLANGE)


def hole_xy(parts, ref):
    return cx(parts[ref]["x"]), cy(parts[ref]["y"])


def board_holes(parts):
    return sorted(k for k in parts if re.fullmatch(r"H\d+", k))


def bay_screws():
    """Keyboard plate / blank screws, keyboard frame (x, s): three into the front
    ledge, three into the rear rail."""
    xs = (15.0, W / 2, W - 15.0)
    return [(x, MARGIN_F / 2) for x in xs] + [(x, PLATE_LEN - MARGIN_B / 2) for x in xs]


def lower_shell(parts, cuts):
    s = rounded_plate(0, W, 0, D, Z_FLOOR, 40, 3.0)
    s = s.cut(rounded_plate(T, W - T, T, D - T, Z_FLOOR + T, 100, 1.0))
    # board section: walls up to the split line; keyboard bay: walls up to the rim
    s = s.cut(rounded_plate(-1, W + 1, Y_R, D + 1, Z_SPLIT, 100))
    above = kb_box(-1, W + 1, -40, PLATE_LEN + 40, RIM, RIM + 100).intersect(
        rounded_plate(-1, W + 1, -1, Y_R, -50, 200))
    s = s.cut(above)
    # ledges under the plate: front, and both sides the length of the bay
    s = s.union(kb_box(T - 0.01, W - T + 0.01, -0.01, MARGIN_F, -PLATE - T, -PLATE))
    s = s.union(kb_box(T - 0.01, T + LEDGE_S, 0, PLATE_LEN, -PLATE - T, -PLATE))
    s = s.union(kb_box(W - T - LEDGE_S, W - T + 0.01, 0, PLATE_LEN, -PLATE - T, -PLATE))
    for x, sl in bay_screws()[:3]:
        s = s.cut(kb_solid(cq.Workplane("XY").center(x, sl).circle(1.25).extrude(10).translate((0, 0, -8))))
    for ref, side, u, z, zj, prof, note in cuts:
        half = cut_width(prof) / 2 + STEP_MARGIN
        if zj > Z_SPLIT:
            s = s.union(step_box(side, u, half, Z_SPLIT - 0.01, zj))
        elif zj < Z_SPLIT:
            s = s.cut(step_box(side, u, half, zj, Z_SPLIT + 1))
        s = s.cut(cutter(side, u, z, prof))
    # floor: standoff holes, vent slots under the board's middle
    for ref in board_holes(parts):
        x, y = hole_xy(parts, ref)
        s = s.cut(hole(x, y, 4.2, Z_FLOOR - 1))
    n = int((BOARD_D - 60) // 12)
    for i in range(n):
        y = Y_BF + 30 + i * 12.0
        s = s.cut(cq.Workplane("XY").center(W / 2, y).slot2D(150, 5).extrude(10).translate((0, 0, Z_FLOOR - 1)))
    return s


def keyboard_rail():
    """Z-shaped rail under the plate's back edge: top flange carries the plate's
    three back screws (PEM nuts), web down to the floor, foot riveted or screwed
    to the floor behind it.  A slot in the web lets the keyboard ribbon through."""
    t = 1.5
    top = kb_box(T + 0.5, W - T - 0.5, PLATE_LEN - MARGIN_B, PLATE_LEN - 0.3, -PLATE - t, -PLATE)
    yw = kb(0, PLATE_LEN - MARGIN_B, -PLATE - t)[1]
    zt = kb(0, PLATE_LEN - MARGIN_B, -PLATE - t)[2]
    web = rounded_plate(T + 0.5, W - T - 0.5, yw, yw + t, Z_FLOOR + T, zt - (Z_FLOOR + T))
    foot = rounded_plate(T + 0.5, W - T - 0.5, yw, yw + 10, Z_FLOOR + T, t)
    r = top.union(web).union(foot)
    r = r.cut(rounded_plate(W / 2 - 20, W / 2 + 20, yw - 1, yw + 3, Z_FLOOR + T + t + 0.5, 4))
    for x, sl in bay_screws()[3:]:
        r = r.cut(kb_solid(cq.Workplane("XY").center(x, sl).circle(1.25).extrude(10).translate((0, 0, -8))))
    return r


def garages(parts):
    """Cover garages: two open trays above the chips behind the riser, reached
    through slots in the riser.  Left one holds the four slot covers side by side,
    right one the cartridge cover.  Each hangs on the front standoffs (H3/H5 and
    H5/H4) by ears at its front corners.  Returns [(x0, x1, y0, y1, holds)]."""
    hx = [hole_xy(parts, h)[0] for h in FRONT_HOLES]
    sc = slot_cover_size(parts)
    cc = cart_cover_size(parts)
    y0 = Y_R + T + 0.5
    out = []
    w = 4 * (sc[0] + 0.5) + 1.0
    xm = (hx[0] + hx[1]) / 2
    out.append((xm - w / 2, xm + w / 2, y0, y0 + sc[1] + 3, "4 slot covers"))
    xm = (hx[1] + hx[2]) / 2
    out.append((xm - cc[0] / 2 - 1.5, xm + cc[0] / 2 + 1.5, y0, y0 + cc[1] + 3, "cartridge cover"))
    return out


def garage_trays(parts):
    t = 1.5
    h = CAP + ACRYLIC + 2.0
    hxy = [hole_xy(parts, h) for h in FRONT_HOLES]
    trays = []
    for i, (x0, x1, y0, y1, what) in enumerate(garages(parts)):
        tr = rounded_plate(x0 - t, x1 + t, y0, y1 + t, GARAGE_Z, t + h)
        tr = tr.cut(rounded_plate(x0, x1, y0 - 1, y1, GARAGE_Z + t, h + 1))
        for hx, hy in (hxy[i], hxy[i + 1]):      # ears to the standoffs either side
            ex0, ex1 = (hx - 4.5, x0) if hx < x0 else (x1, hx + 4.5)
            ear = rounded_plate(ex0, ex1, hy - 4.5, hy + 4.5, GARAGE_Z, t)
            tr = tr.union(ear).cut(hole(hx, hy, 3.4, GARAGE_Z - 1))
        trays.append(tr)
    return trays


def upper_shell(parts, cuts):
    bay, cart, slot_x = openings(parts)
    win = window()
    s = rounded_plate(0, W, Y_R, D, Z_SPLIT, Z_TOP + T - Z_SPLIT, 3.0)
    s = s.cut(rounded_plate(T, W - T, Y_R + T, D - T, Z_SPLIT - 1, Z_TOP - Z_SPLIT + 1, 1.0))
    s = s.cut(rounded_plate(win[0], win[1], win[2], win[3], Z_TOP - 1, 10, 2.0))
    # the card shells pass the back flange: open it to the back wall's inside face
    s = s.cut(rounded_plate(bay[0], bay[1], win[3] - 5, D - T, Z_TOP - 1, 10))
    # slots in the riser into the cover garages
    for x0, x1, y0, y1, what in garages(parts):
        s = s.cut(rounded_plate(x0, x1, Y_R - 1, Y_R + T + 1, GARAGE_Z + 1.5, CAP + ACRYLIC + 1.5, 0))
    for ref, side, u, z, zj, prof, note in cuts:
        half = cut_width(prof) / 2 + STEP_MARGIN
        if zj < Z_SPLIT:
            s = s.union(step_box(side, u, half, zj, Z_SPLIT + 0.01))
        elif zj > Z_SPLIT:
            s = s.cut(step_box(side, u, half, Z_SPLIT - 1, zj))
        s = s.cut(cutter(side, u, z, prof))
    for ref in board_holes(parts):
        x, y = hole_xy(parts, ref)
        s = s.cut(hole(x, y, 3.2, Z_TOP - 1))
    return s


def slot_magnets(parts):
    """(x, y) of the magnet pairs: two per slot cover in the cap's front lap, two
    per side of the cartridge cover; the acrylic top has the mates."""
    bay, cart, slot_x = openings(parts)
    n = len(slot_x)
    pitch = (bay[1] - bay[0]) / n
    pts = []
    for i in range(n):
        x0 = bay[0] + i * pitch
        pts += [(x0 + pitch * 0.25, bay[2] - LIP / 2), (x0 + pitch * 0.75, bay[2] - LIP / 2)]
    ym = (cart[2] + cart[3]) / 2
    pts += [(cart[0] - LIP / 2, ym), (cart[1] + LIP / 2, ym)]
    return pts


def acrylic_top(parts):
    bay, cart, slot_x = openings(parts)
    z0 = Z_TOP + T
    s = rounded_plate(0, W, Y_R, D, z0, ACRYLIC, 3.0)
    s = s.cut(rounded_plate(bay[0], bay[1], bay[2], D + 1, z0 - 1, ACRYLIC + 2))
    s = s.cut(rounded_plate(cart[0], cart[1], cart[2], cart[3], z0 - 1, ACRYLIC + 2, 1.0))
    for ref in board_holes(parts):
        x, y = hole_xy(parts, ref)
        s = s.cut(hole(x, y, 3.4, z0 - 1))
    for x, y in slot_magnets(parts):
        s = s.cut(hole(x, y, MAG_D + 0.1, z0 - 1))
    return s


def key_positions():
    """(x centre, s centre along the slope, width) of each key, front row first."""
    keys = []
    x_left = (W - 15 * U) / 2
    for r, row in enumerate(KEY_ROWS):
        sl = MARGIN_F + (r + 0.5) * U
        x = x_left
        for w in row:
            keys.append((x + w * U / 2, sl, w))
            x += w * U
    return keys


def bay_panel(thick, keys):
    """Keyboard plate (keys=True) or blank, flat in the keyboard frame (place it
    with kb_solid); it sits on the ledges and the rear rail."""
    p = (cq.Workplane("XY").box(W - 2 * T - 0.5, PLATE_LEN - 0.25, thick, centered=False)
         .translate((T + 0.25, 0.25, -PLATE)).edges("|Z").fillet(1.0))
    cut = None
    if keys:
        for x, sl, w in key_positions():
            c = cq.Workplane("XY").center(x, sl).rect(14.0, 14.0).extrude(20).translate((0, 0, -10))
            if w >= 2:      # stabilizer housings pass through (2u-2.75u at 23.876, 6.25u at 100 mm)
                d = 50.0 if w > 6 else 11.938
                for sx in (-d, d):
                    c = c.union(cq.Workplane("XY").center(x + sx, sl).rect(6.75, 14.0).extrude(20)
                                .translate((0, 0, -10)))
            cut = c if cut is None else cut.union(c)
    for x, sl in bay_screws():
        c = cq.Workplane("XY").center(x, sl).circle(1.6).extrude(20).translate((0, 0, -10))
        cut = c if cut is None else cut.union(c)
    return p.cut(cut)


def slot_cover_size(parts):
    bay, cart, slot_x = openings(parts)
    pitch = (bay[1] - bay[0]) / len(slot_x)
    return pitch - 0.4, D - bay[2] + LIP


def cart_cover_size(parts):
    bay, cart, slot_x = openings(parts)
    return cart[1] - cart[0] + 2 * LIP, cart[3] - cart[2] + 2 * LIP


def slot_covers(parts):
    """One cover per expansion slot: a 4 mm plug filling its share of the opening
    (it rests on the back wall's top edge) and a 3 mm cap that laps LIP onto the
    acrylic in front, where two magnets meet two in the acrylic top; neighbours
    butt with a 0.4 mm gap."""
    bay, cart, slot_x = openings(parts)
    n = len(slot_x)
    pitch = (bay[1] - bay[0]) / n
    z0 = Z_TOP + T
    mags = slot_magnets(parts)
    out = []
    for i in range(n):
        x0, x1 = bay[0] + i * pitch + 0.2, bay[0] + (i + 1) * pitch - 0.2
        plug = rounded_plate(x0, x1, bay[2] + 0.2, D, z0, ACRYLIC)
        cap = rounded_plate(x0, x1, bay[2] - LIP, D, z0 + ACRYLIC, CAP)
        cap = cap.cut(hole((x0 + x1) / 2, bay[2] - LIP, 8.0, z0))
        for x, y in mags[2 * i:2 * i + 2]:
            cap = cap.cut(hole(x, y, MAG_D + 0.1, z0))
        out.append(plug.union(cap))
    return out


def cart_cover(parts):
    bay, cart, slot_x = openings(parts)
    z0 = Z_TOP + T
    plug = rounded_plate(cart[0] + 0.2, cart[1] - 0.2, cart[2] + 0.2, cart[3] - 0.2, z0, ACRYLIC, 0.8)
    cap = rounded_plate(cart[0] - LIP, cart[1] + LIP, cart[2] - LIP, cart[3] + LIP, z0 + ACRYLIC, CAP, 3.0)
    cap = cap.cut(hole((cart[0] + cart[1]) / 2, cart[2] - LIP, 8.0, z0))
    for x, y in slot_magnets(parts)[-2:]:
        cap = cap.cut(hole(x, y, MAG_D + 0.1, z0))
    return plug.union(cap)


def standoffs(parts):
    """M3 standoffs at every board hole: floor PEM standoff under the board,
    male-female hex standoff from the board's top to the top flange."""
    out = []
    for ref in board_holes(parts):
        x, y = hole_xy(parts, ref)
        lo = cq.Workplane("XY").center(x, y).polygon(6, 5.5 / math.cos(math.pi / 6)).extrude(
            -PCB_T - (Z_FLOOR + T)).translate((0, 0, Z_FLOOR + T))
        hi = cq.Workplane("XY").center(x, y).polygon(6, 5.5 / math.cos(math.pi / 6)).extrude(Z_TOP)
        out += [lo, hi]
    return out


def magnets(parts):
    out = []
    z0 = Z_TOP + T
    for x, y in slot_magnets(parts):
        out.append(hole(x, y, MAG_D, z0 + ACRYLIC - MAG_T, MAG_T))
        out.append(hole(x, y, MAG_D, z0 + ACRYLIC, MAG_T))
    return out


# ---------------------------------------------------------------- drawings
ALU_C, ACR_C, KEY_C = "#b9bec5", "#cfe8f7", "#7b8189"


def dim(ax, p0, p1, text, off=(0, 0), fs=9):
    ax.annotate("", p0, p1, arrowprops=dict(arrowstyle="<->", lw=0.8, color="#333"))
    ax.text((p0[0] + p1[0]) / 2 + off[0], (p0[1] + p1[1]) / 2 + off[1], text, ha="center", va="center",
            fontsize=fs, color="#222", bbox=dict(fc="white", ec="none", pad=0.6))


def draw_top(info, path):
    """Top view: keyboard bay, upper shell flange, acrylic top, covers, magnets,
    garages, screws."""
    Wd, Dd, yr = info["W"], info["D"], info["Y_R"]
    c = math.cos(math.radians(info["KB_TILT"]))
    fig, ax = plt.subplots(figsize=(13, 15))
    ax.add_patch(FancyBboxPatch((0, 0), Wd, Dd, boxstyle="round,pad=0,rounding_size=3", fc=ALU_C, ec="#555",
                                lw=1.2))
    # keyboard bay
    ax.add_patch(Rectangle((T, T), Wd - 2 * T, yr - 0.5 - T, fc="#9aa0a8", ec="#555", lw=0.8))
    for x, sl, w in info["keys"]:
        y = T + sl * c
        ax.add_patch(Rectangle((x - w * U / 2 + 0.6, y - U * c / 2 + 0.6), w * U - 1.2, U * c - 1.2,
                               fc="#e9ebee", ec=KEY_C, lw=0.6))
    # board section: flange, window, acrylic
    win = info["window"]
    ax.add_patch(Rectangle((0, yr), Wd, Dd - yr, fc=ACR_C, ec="#2b7bb9", lw=1.2, alpha=0.5))
    ax.add_patch(Rectangle((win[0], win[2]), win[1] - win[0], win[3] - win[2], fc="#eef6fb", ec="#555", lw=0.8))
    bay, cart = info["bay"], info["cart"]
    for x0, x1, y0, y1, what in info["garages"]:
        ax.add_patch(Rectangle((x0, y0), x1 - x0, y1 - y0, fc="none", ec="#8a6d1f", lw=1.0, ls="--"))
        ax.text((x0 + x1) / 2, (y0 + y1) / 2, "cover garage:\n" + what, ha="center", va="center", fontsize=8,
                color="#8a6d1f")
    n = len(info["slot_x"])
    pitch = (bay[1] - bay[0]) / n
    for i in range(n):
        x0 = bay[0] + i * pitch + 0.2
        ax.add_patch(Rectangle((x0, bay[2] - LIP), pitch - 0.4, Dd - bay[2] + LIP, fc="#9fd0ef", ec="#1f6fa8",
                               lw=1.0, alpha=0.7))
        ax.add_patch(Circle((x0 + pitch / 2 - 0.2, bay[2] - LIP), 4, fc="white", ec="#1f6fa8", lw=0.8))
        ax.text(x0 + pitch / 2, (bay[2] + Dd) / 2, "J%d cover" % (9 + i), rotation=90, ha="center", va="center",
                fontsize=9)
    ax.add_patch(Rectangle((cart[0] - LIP, cart[2] - LIP), cart[1] - cart[0] + 2 * LIP, cart[3] - cart[2] + 2 * LIP,
                           fc="#9fd0ef", ec="#1f6fa8", lw=1.0, alpha=0.7))
    ax.add_patch(Rectangle((cart[0], cart[2]), cart[1] - cart[0], cart[3] - cart[2], fc="none", ec="#1f6fa8",
                           lw=0.8, ls=":"))
    ax.text((cart[0] + cart[1]) / 2, (cart[2] + cart[3]) / 2, "J8 cover", ha="center", va="center", fontsize=9)
    for x, y in info["magnets"]:
        ax.add_patch(Circle((x, y), MAG_D / 2, fc="#b03a2e", ec="none"))
    for x, y in info["holes"].values():
        ax.add_patch(Circle((x, y), 2.8, fc="#333", ec="none"))
    for x, sl in info["bay_screws"]:
        ax.add_patch(Circle((x, T + sl * c), 2.4, fc="#333", ec="none"))
    for cu in info["cuts"]:
        u = cu["u"]
        if cu["side"] == "back":
            ax.plot([u, u], [Dd, Dd + 6], color="#c33", lw=1)
            ax.text(u, Dd + 8, cu["ref"], ha="center", va="bottom", fontsize=9, color="#c33")
        elif cu["side"] == "left":
            ax.plot([0, -6], [u, u], color="#c33", lw=1)
            ax.text(-8, u, cu["ref"], ha="right", va="center", fontsize=9, color="#c33")
        else:
            ax.plot([Wd, Wd + 6], [u, u], color="#c33", lw=1)
            ax.text(Wd + 8, u, cu["ref"], ha="left", va="center", fontsize=9, color="#c33")
    dim(ax, (0, -14), (Wd, -14), "%.0f" % Wd)
    dim(ax, (Wd + 30, 0), (Wd + 30, Dd), "%.0f" % Dd)
    dim(ax, (-30, 0), (-30, yr), "keyboard bay %.0f" % yr)
    dim(ax, (-30, yr), (-30, Dd), "board section %.0f" % (Dd - yr))
    ax.text(Wd / 2, (win[2] + bay[2]) / 2 + 30, "4 mm clear acrylic top over the board window,\n"
            "8 screws into the board standoffs", ha="center", va="center", fontsize=10)
    ax.text(Wd / 2, Dd + 22, "BACK", ha="center", fontsize=11, weight="bold")
    ax.text(Wd / 2, -26, "FRONT", ha="center", fontsize=11, weight="bold")
    ax.set_xlim(-80, Wd + 55)
    ax.set_ylim(-35, Dd + 30)
    ax.set_aspect("equal")
    ax.axis("off")
    ax.set_title("PLACARD case - top view (mm).  Grey = aluminium, blue = acrylic, black dots = M3 screws, "
                 "red dots = magnets,\nred ticks = wall connectors, dashed = cover garages.  Keyboard bay: 63-key "
                 "MX plate (drawn) or 3 mm acrylic blank, tilted %.1f deg" % info["KB_TILT"], fontsize=11)
    fig.tight_layout()
    fig.savefig(path, dpi=100)
    plt.close(fig)


def cut_outline(prof, u, z, flip):
    """Outline patches of a cut-out in a wall elevation (u, z)."""
    k = prof[0]
    s = -1 if flip else 1
    if k == "circle":
        return [Circle((s * u, z), prof[1] / 2)]
    if k in ("slot", "rrect"):
        w, h = prof[1], prof[2]
        r = h / 2 if k == "slot" else prof[3]
        return [FancyBboxPatch((s * u - w / 2, z - h / 2), w, h, boxstyle="round,pad=0,rounding_size=%g" % r)]
    if k == "dsub":
        return [Polygon([(s * u - 8.5, z + 4.5), (s * u + 8.5, z + 4.5), (s * u + 7.5, z - 4.5),
                         (s * u - 7.5, z - 4.5)]), Circle((s * u - 12.5, z), 1.6), Circle((s * u + 12.5, z), 1.6)]
    if k == "sd":
        return [Rectangle((s * u - 13.5, z - 1.8), 27, 3.6),
                FancyBboxPatch((s * u - 7, z - 2.5), 14, 7, boxstyle="round,pad=0,rounding_size=3")]
    return []


def split_profile(info, side, u0, u1):
    """The split line along a wall between u0 and u1: [(u, z)], steps merged."""
    zs = info["Z_SPLIT"]
    pts = []
    for cu in info["cuts"]:
        if cu["side"] == side:
            half = cut_width(cu["prof"]) / 2 + STEP_MARGIN
            pts.append((cu["u"] - half, cu["u"] + half, cu["zj"]))
    us = sorted(set([u0, u1] + [p for a, b, z in pts for p in (a, b) if u0 < p < u1]))
    prof = []
    for a0, a1 in zip(us[:-1], us[1:]):
        m = (a0 + a1) / 2
        zz = [z for a, b, z in pts if a <= m <= b]
        z = max(zz) if zz and max(zz) > zs else (min(zz) if zz else zs)
        prof += [(a0, z), (a1, z)]
    return prof


def draw_walls(info, path):
    """Back, left and right walls seen from outside: the stepped split line and the
    cut-outs, plus a section through the keyboard and the board section."""
    Wd, Dd, yr = info["W"], info["D"], info["Y_R"]
    zf, zs, zt = info["Z_FLOOR"], info["Z_SPLIT"], info["Z_TOP"]
    za = zt + T + ACRYLIC
    th = math.radians(info["KB_TILT"])
    rim = lambda y: info["PT0"] + (y - T) * math.tan(th) + RIM
    fig, axs = plt.subplots(4, 1, figsize=(15, 17), gridspec_kw=dict(height_ratios=[1, 1, 1, 1.4]))
    views = (("back", "Back wall, seen from behind", True, Wd),
             ("left", "Left wall, seen from the left (front at the right)", True, Dd),
             ("right", "Right wall, seen from the right (front at the left)", False, Dd))
    for ax, (side, title, flip, L) in zip(axs, views):
        s = -1 if flip else 1
        if side == "back":
            prof = split_profile(info, side, 0, Wd)
            lower = [(s * u, z) for u, z in prof] + [(s * Wd, zf), (0, zf)]
            upper = [(s * u, z) for u, z in prof] + [(s * Wd, zt + T), (0, zt + T)]
            acr = (0, Wd)
        else:
            prof = split_profile(info, side, yr, Dd)
            lower = ([(0, zf), (0, rim(0)), (s * yr, rim(yr)), (s * yr, zs)] +
                     [(s * u, z) for u, z in prof] + [(s * Dd, zf)])
            upper = [(s * u, z) for u, z in prof] + [(s * Dd, zt + T), (s * yr, zt + T)]
            acr = (yr, Dd)
        ax.add_patch(Polygon(lower, fc="#c9cdd3", ec="#444", lw=1))
        ax.add_patch(Polygon(upper, fc="#dfe2e6", ec="#444", lw=1))
        ax.add_patch(Rectangle((min(s * acr[0], s * acr[1]), zt + T), acr[1] - acr[0], ACRYLIC, fc=ACR_C,
                               ec="#2b7bb9", lw=0.8))
        ax.plot([s * u for u, z in prof], [z for u, z in prof], color="#c33", lw=1.6)
        for cu in info["cuts"]:
            if cu["side"] != side:
                continue
            for patch in cut_outline(cu["prof"], cu["u"], cu["z"], flip):
                patch.set_facecolor("white")
                patch.set_edgecolor("#222")
                patch.set_linewidth(0.9)
                ax.add_patch(patch)
            ax.text(s * cu["u"], za + 4, cu["ref"], ha="center", va="bottom", fontsize=9)
            ax.text(s * cu["u"], zf - 3, "z %.1f" % cu["zj"], ha="center", va="top", fontsize=7, color="#c33")
        mid = s * (acr[0] + acr[1]) / 2
        ax.text(mid, (zs + zt) / 2 + 3, "upper shell", ha="center", fontsize=9, color="#555")
        ax.text(mid, (zf + zs) / 2 - 2, "lower shell", ha="center", fontsize=9, color="#555")
        if side != "back":
            ax.text(s * yr / 2, zf + 3, "keyboard bay", ha="center", fontsize=9, color="#555")
        ax.set_xlim(min(0, s * L) - 22, max(0, s * L) + 22)
        ax.set_ylim(zf - 12, za + 12)
        ax.set_aspect("equal")
        ax.set_yticks([zf, 0, zs, zt + T, za])
        ax.set_yticklabels(["%.1f floor" % zf, "0 board top", "%.0f split" % zs, "%.0f flange" % (zt + T),
                            "%.0f top" % za], fontsize=8)
        ax.set_xticks([])
        for sp in ("top", "right", "bottom"):
            ax.spines[sp].set_visible(False)
        ax.set_title(title + " (red = split line; it steps to each connector's centre)", fontsize=10, loc="left")
    # section front to back at x = middle
    ax = axs[3]
    desk = info["Z_DESK"]
    ax.plot([-10, Dd + 10], [desk, desk], color="#8a6d1f", lw=1.2)
    ax.text(Dd + 8, desk - 1, "desk", ha="right", va="top", fontsize=8, color="#8a6d1f")
    ax.add_patch(Rectangle((0, zf), Dd, T, fc="#c9cdd3", ec="#444"))
    ax.add_patch(Polygon([(0, zf), (T, zf), (T, rim(T)), (0, rim(0))], fc="#c9cdd3", ec="#444"))
    ax.add_patch(Rectangle((Dd - T, zf), T, zt + T - zf, fc="#dfe2e6", ec="#444"))
    ax.add_patch(Rectangle((yr, zs), T, zt + T - zs, fc="#dfe2e6", ec="#444"))
    ax.add_patch(Rectangle((yr, zt), FLANGE, T, fc="#dfe2e6", ec="#444"))
    ax.add_patch(Rectangle((Dd - FLANGE, zt), FLANGE, T, fc="#dfe2e6", ec="#444"))
    ax.add_patch(Rectangle((yr, zt + T), Dd - yr, ACRYLIC, fc=ACR_C, ec="#2b7bb9"))
    ybf = info["Y_BF"]
    ax.add_patch(Rectangle((ybf, -PCB_T), Dd - ybf - OFF, PCB_T, fc="#2e7d4f", ec="#1b4d30"))
    for y in (ybf + 5, Dd - OFF - 5):
        ax.add_patch(Rectangle((y - 2.75, zf + T), 5.5, -PCB_T - zf - T, fc="#d4c08a", ec="#8a7a4a", lw=0.6))
        ax.add_patch(Rectangle((y - 2.75, 0), 5.5, zt, fc="#d4c08a", ec="#8a7a4a", lw=0.6))
    for y in np.arange(ybf + 20, Dd - 40, 35):
        ax.add_patch(Rectangle((y, 0), 12, 9.1, fc="#222", ec="none"))
    ax.add_patch(Rectangle((Dd - OFF - 13.5, 0), 13.5, 25, fc="#5a5f66", ec="#333"))
    ax.text(Dd - OFF - 16, 14, "J5\nPS/2\n25 mm", ha="right", va="center", fontsize=8)
    for x0, x1, y0, y1, what in info["garages"][:1]:
        ax.add_patch(Rectangle((y0, GARAGE_Z), y1 - y0, 1.5, fc="#b9bec5", ec="#444"))
        ax.add_patch(Rectangle((y0 + 1, GARAGE_Z + 1.5), y1 - y0 - 2, ACRYLIC + CAP, fc=ACR_C, ec="#2b7bb9",
                               alpha=0.8))
        ax.text((y0 + y1) / 2, GARAGE_Z + 9.5, "cover garage", ha="center", va="bottom", fontsize=8)

    def kbpoly(pts, **kw):
        ax.add_patch(Polygon([kb(0, sl, n)[1:] for sl, n in pts], **kw))
    kbpoly([(0.25, 0), (PLATE_LEN, 0), (PLATE_LEN, -PLATE), (0.25, -PLATE)], fc="#9aa0a8", ec="#444")
    kbpoly([(0, -PLATE), (MARGIN_F, -PLATE), (MARGIN_F, -PLATE - T), (0, -PLATE - T)], fc="#c9cdd3", ec="#444")
    kbpoly([(KB_PCB[1], -MX_PCB), (KB_PCB[2], -MX_PCB), (KB_PCB[2], -MX_PCB - PCB_T), (KB_PCB[1], -MX_PCB - PCB_T)],
           fc="#111", ec="#000")
    for r in range(len(KEY_ROWS)):
        sl = MARGIN_F + r * U
        kbpoly([(sl + 2.5, -MX_PCB), (sl + 16.5, -MX_PCB), (sl + 16.5, 6.6), (sl + 2.5, 6.6)], fc="#333", ec="none")
        kbpoly([(sl + 0.6, 7.0), (sl + 18.4, 7.0), (sl + 16.6, KEYCAP), (sl + 2.4, KEYCAP)], fc="#666", ec="#333")
    yw = kb(0, PLATE_LEN - MARGIN_B, 0)[1]
    ax.add_patch(Rectangle((yw, zf + T), 1.5, kb(0, PLATE_LEN - MARGIN_B, -PLATE - 1.5)[2] - zf - T,
                           fc="#b9bec5", ec="#444"))
    hy, hz = kb(0, MARGIN_F + (HOME_ROW + 0.5) * U, KEYCAP)[1:]
    ax.plot([hy, hy], [desk, hz], color="#c33", lw=1)
    ax.text(hy + 2, hz + 3, "home row %.1f mm above the desk" % (hz - desk), color="#c33", fontsize=9,
            va="bottom")
    ax.text(kb(0, PLATE_LEN * 0.75, 0)[1], kb(0, PLATE_LEN * 0.75, 0)[2] + 22, "tilt %.1f deg" % info["KB_TILT"],
            fontsize=9, ha="center")
    ax.set_xlim(-10, Dd + 10)
    ax.set_ylim(desk - 4, za + 8)
    ax.set_aspect("equal")
    ax.set_yticks([desk, zf, 0, zs, zt + T, za])
    ax.set_yticklabels(["%.1f" % v for v in [desk, zf, 0, zs, zt + T, za]], fontsize=8)
    ax.set_xticks([0, round(yr, 1), round(Dd, 1)])
    ax.set_xlabel("y from the front (mm); z from the main board's top face (mm)", fontsize=9)
    ax.set_title("Section front to back: keyboard bay (plate on ledges and the rear rail) in front, riser, "
                 "board section with %.0f mm standoffs to the flange, acrylic top" % zt, fontsize=10, loc="left")
    fig.tight_layout()
    fig.savefig(path, dpi=95)
    plt.close(fig)


# ---------------------------------------------------------------- exports
def export_dxf(shape, z, path):
    """Laser-cutting outline: the section of shape at height z, as a DXF."""
    sec = shape.section(z)
    cq.exporters.export(sec, path, exportType="DXF")


def build(pcb, out, mesh=None, drawings=None):
    parts = read_board(pcb)
    cuts = wall_cutouts(parts)
    bay, cart, slot_x = openings(parts)
    plate_flat = bay_panel(PLATE, True)
    blank_flat = bay_panel(BLANK, False)
    solids = {
        "lower_shell": lower_shell(parts, cuts),
        "upper_shell": upper_shell(parts, cuts),
        "keyboard_rail": keyboard_rail(),
        "acrylic_top": acrylic_top(parts),
        "keyboard_blank": kb_solid(blank_flat),
        "keyboard_plate": kb_solid(plate_flat),
        "cart_cover": cart_cover(parts),
    }
    for i, tr in enumerate(garage_trays(parts)):
        solids["garage_%d" % (i + 1)] = tr
    covers = slot_covers(parts)
    for i, c in enumerate(covers):
        solids["slot_cover_%d" % (i + 1)] = c
    os.makedirs(os.path.join(out, "dxf"), exist_ok=True)
    for name, sol in solids.items():
        if name.startswith("slot_cover_") and name != "slot_cover_1":
            continue
        fn = "slot_cover" if name.startswith("slot_cover") else name
        cq.exporters.export(sol, os.path.join(out, fn + ".step"))
    z0 = Z_TOP + T
    export_dxf(solids["acrylic_top"], z0 + ACRYLIC / 2, os.path.join(out, "dxf", "acrylic_top_4mm.dxf"))
    export_dxf(blank_flat, -PLATE + BLANK / 2, os.path.join(out, "dxf", "keyboard_blank_3mm.dxf"))
    export_dxf(plate_flat, -PLATE / 2, os.path.join(out, "dxf", "keyboard_plate_1.5mm.dxf"))
    export_dxf(covers[0], z0 + ACRYLIC / 2, os.path.join(out, "dxf", "slot_cover_plug_4mm.dxf"))
    export_dxf(covers[0], z0 + ACRYLIC + CAP / 2, os.path.join(out, "dxf", "slot_cover_cap_3mm.dxf"))
    export_dxf(solids["cart_cover"], z0 + ACRYLIC / 2, os.path.join(out, "dxf", "cart_cover_plug_4mm.dxf"))
    export_dxf(solids["cart_cover"], z0 + ACRYLIC + CAP / 2, os.path.join(out, "dxf", "cart_cover_cap_3mm.dxf"))
    for f in ("keyboard_blank_4mm.dxf",):
        if os.path.exists(os.path.join(out, "dxf", f)):
            os.remove(os.path.join(out, "dxf", f))

    stow = {}
    sc = slot_cover_size(parts)
    g = garages(parts)
    for i in range(len(slot_x)):
        x0 = bay[0] + i * (bay[1] - bay[0]) / len(slot_x) + 0.2
        stow["slot_cover_%d" % (i + 1)] = (g[0][0] + 0.5 + i * (sc[0] + 0.5) - x0, g[0][2] + 1.0 - (bay[2] - LIP),
                                           GARAGE_Z + 1.5 - (Z_TOP + T))
    stow["cart_cover"] = (g[1][0] + 1.5 - (cart[0] - LIP), g[1][2] + 1.0 - (cart[2] - LIP),
                          GARAGE_Z + 1.5 - (Z_TOP + T))
    info = dict(W=W, D=D, LIP=LIP, stow=stow, T=T, OFF=OFF, BOARD_D=BOARD_D, Y_R=Y_R, Y_BF=Y_BF, Z_FLOOR=Z_FLOOR, Z_DESK=Z_DESK,
                Z_SPLIT=Z_SPLIT, Z_TOP=Z_TOP, ACRYLIC=ACRYLIC, CAP=CAP, PLATE=PLATE, RIM=RIM,
                KB_TILT=KB_TILT, PT0=PT0, PLATE_LEN=PLATE_LEN, MX_PCB=MX_PCB, KEYCAP=KEYCAP, KB_PCB=KB_PCB,
                home_row=home_row_height(KB_TILT), window=window(), bay=bay, cart=cart, slot_x=slot_x,
                keys=key_positions(), bay_screws=bay_screws(), magnets=slot_magnets(parts),
                garages=garages(parts), slot_cover=slot_cover_size(parts), cart_cover=cart_cover_size(parts),
                cuts=[dict(ref=r, side=sd, u=u, z=z, zj=zj, prof=list(p), note=n)
                      for r, sd, u, z, zj, p, n in cuts],
                holes={k: hole_xy(parts, k) for k in board_holes(parts)})
    with open(os.path.join(out, "case_layout.json"), "w") as f:
        json.dump(info, f, indent=1)

    if drawings:
        draw_top(info, os.path.join(drawings, "case_top_view.png"))
        draw_walls(info, os.path.join(drawings, "case_walls.png"))
    if mesh:
        os.makedirs(mesh, exist_ok=True)
        for name, sol in solids.items():
            cq.exporters.export(sol, os.path.join(mesh, name + ".stl"), tolerance=0.05, angularTolerance=0.2)
        for name, group in (("standoffs", standoffs(parts)), ("magnets", magnets(parts))):
            cq.exporters.export(cq.Workplane().add([x.val() for x in group]).combine(),
                                os.path.join(mesh, name + ".stl"))
        for ref, p in parts.items():
            m = model_solid(p)
            if m is not None:
                cq.exporters.export(cq.Workplane().add(m), os.path.join(mesh, "model_%s.stl" % ref),
                                    tolerance=0.05, angularTolerance=0.3)
        board = dict(parts={k: dict(x=cx(v["x"]), y=cy(v["y"]), rot=v["rot"],
                                    crt=[cx(v["crt"][0]), cy(v["crt"][3]), cx(v["crt"][2]), cy(v["crt"][1])]
                                    if v["crt"] else None, fp=v["fp"]) for k, v in parts.items()})
        with open(os.path.join(mesh, "board.json"), "w") as f:
            json.dump(dict(board, **info), f)
    return info


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--pcb", default=os.path.join(REPO, "kicad", "placard.kicad_pcb"))
    ap.add_argument("--out", default=os.path.join(REPO, "case"))
    ap.add_argument("--drawings", default=os.path.join(REPO, "docs"), help="where the PNG drawings go")
    ap.add_argument("--mesh", help="also write STL meshes + board.json here (for renders)")
    a = ap.parse_args()
    info = build(a.pcb, a.out, a.mesh, a.drawings)
    for c in info["cuts"]:
        print("%-4s %-5s u %6.1f  centre z %5.2f  joint z %5.2f  %s" % (c["ref"], c["side"], c["u"], c["z"],
                                                                        c["zj"], c["note"]))
    print("case %.1f x %.1f mm, %.1f mm tall at the back and %.1f mm at the front (desk to top); "
          "keyboard tilt %.1f deg, home row %.1f mm above the desk" %
          (W, info["D"], Z_TOP + T + ACRYLIC - Z_DESK, PT0 + RIM - Z_DESK, KB_TILT, info["home_row"]))

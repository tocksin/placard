#!/usr/bin/env python3
"""
gen_case.py - the PLACARD case concept: a brushed, anodized aluminium tray
(floor, front and right walls) with flat plates for the back and left walls,
which carry the connectors that reach through them, a clear acrylic top over
the whole case, and one removable acrylic
cover per expansion slot (J9-J12) and for the cartridge slot (J8), held on by
magnets.  A cover that is out parks under the case: its magnets cling to steel
discs set flush in the floor, right under where it fits on the top, and the
case stands on feet tall enough to clear it.  See docs/CASE.md.

    pip install cadquery
    python3 gen_case.py [--pcb path/to/placard.kicad_pcb] [--out case] [--mesh dir]

The connector cut-outs are placed from the board file: each footprint's
position and rotation, and the face of its 3D model (kicad/lib/placard.3dshapes)
where it meets the wall.  The board file is only read, never written.  Rerun
after connectors move.

Parts (STEP in case/, DXF cutting files for the flat parts in case/dxf/):

| File | Part | Material |
|---|---|---|
| tray | floor, front wall, right wall (SNES cut-outs), steel parking discs | 2.0 mm 5052 aluminium, bent, brushed, clear or black anodized |
| back_plate | back wall: USB-C, audio, VGA, PS/2 cut-outs; bottom flange | 2.0 mm 5052, one bend, anodized |
| left_plate | left wall: power, reset, SD cut-outs; bottom flange | 2.0 mm 5052, one bend, anodized |
| acrylic_top | over the board, slot and cartridge openings, magnets | 4 mm clear cast acrylic, laser cut |
| slot_cover | one per expansion slot (4 alike), plug + cap with two magnets | 4 mm + 3 mm acrylic, solvent welded |
| cart_cover | cartridge slot cover, plug + cap with two magnets | 4 mm + 3 mm acrylic |

Coordinates (mm): x from the case's left outside face, y from the front
outside face toward the back, z up from the main board's top face.

Date: 2026-10-27
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
OFF = GAP + T          # board's left edge in case x, its front edge in case y, its back edge from the back face
PCB_T = 1.6
STANDOFF = 6.0         # floor to the board's underside (VGA J7's pins reach 3.8 mm below it)
Z_FLOOR = -PCB_T - STANDOFF - T     # underside of the floor (z = 0 is the main board's top face)
Z_TOP = 27.0           # top of the walls = underside of the acrylic top (stacked PS/2 J5 is 25 mm tall)
ACRYLIC = 4.0          # top
CAP = 3.0              # cover caps
PLATE_FLANGE = 6.0     # the plates' bottom flanges, lying on the floor

# parking under the floor: a parked cover hangs ACRYLIC + CAP below the floor
PARK_CLEAR = 3.0       # parked cover's plug to the desk
FEET = ACRYLIC + CAP + PARK_CLEAR   # rubber feet, 10 mm
FOOT_D = 16.0          # foot diameter
FOOT_IN = 24.0         # foot centre from the outside faces (clear of the corner standoffs and the covers)
Z_DESK = Z_FLOOR - FEET
DISC_D, DISC_T = 6.0, 2.0   # steel parking discs, flush in the floor (same diameter as the magnets)

BOARD_W = 290.0
W = BOARD_W + 2 * OFF
Y_BF = OFF             # main board's front edge
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
FALLBACK_Z = {"J4": 1.45}   # J4 is being changed to a Hirose DM1AA (2026-10-25); the board still has the old one

SLOTS = ["J9", "J10", "J11", "J12"]
CART = "J8"
LIP = 8.0              # cover cap overlap on the acrylic (room for the magnets)
MAG_D, MAG_T = 6.0, 3.0     # N52 disc magnets, in 6.1 mm holes; the caps' go through, flush both faces


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
        plane = cq.Plane(origin=(u, D - T / 2 - depth / 2, z), xDir=(-1, 0, 0), normal=(0, 1, 0))
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


def wall_cutouts(parts):
    """[(ref, side, u, z_centre, prof, note)] for every wall connector on the board."""
    out = []
    for ref, (side, prof, note) in WALL_PARTS.items():
        if ref not in parts:
            continue
        solid = model_solid(parts[ref])
        if solid is None:
            # the board names a model the library no longer has: the courtyard's
            # centre along the wall, and the last height measured
            c = parts[ref]["crt"]
            u = (cx(c[0]) + cx(c[2])) / 2 if side == "back" else (cy(c[1]) + cy(c[3])) / 2
            z = FALLBACK_Z[ref]
            note += " (model missing: placed from the courtyard, check)"
        else:
            u, z, _ = wall_face(solid, side)
        out.append((ref, side, u, z, prof, note))
    return out


# ---------------------------------------------------------------- parts
def rounded_plate(x0, x1, y0, y1, z0, t, r=0.0):
    p = cq.Workplane("XY").box(x1 - x0, y1 - y0, t, centered=False).translate((x0, y0, z0))
    if r > 0:
        p = p.edges("|Z").fillet(r)
    return p


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


def hole_xy(parts, ref):
    return cx(parts[ref]["x"]), cy(parts[ref]["y"])


def board_holes(parts):
    return sorted(k for k in parts if re.fullmatch(r"H\d+", k))


def feet():
    """(x, y) of the four rubber feet, clear of the parked covers."""
    return [(x, y) for y in (FOOT_IN, D - FOOT_IN) for x in (FOOT_IN, W - FOOT_IN)]


def vents(parts):
    """Vent slots in the floor (x centre, y centre, length): across the middle of
    the floor, in front of the parked covers."""
    y1 = min(b[2] for b in parked_boxes(parts).values()) - 10.0
    n = int((y1 - 30.0) // 12) + 1
    return [(W / 2, 30.0 + i * 12.0, 150.0) for i in range(n)]


def tray(parts, cuts):
    """Floor with the front and right walls bent up to Z_TOP.  The floor stops at
    the plates' inside faces (x = T, y = D - T); the plates' flanges lie on it."""
    s = rounded_plate(T, W, 0, D - T, Z_FLOOR, T)
    s = s.union(rounded_plate(0, W, 0, T, Z_FLOOR, Z_TOP - Z_FLOOR))          # front wall
    s = s.union(rounded_plate(W - T, W, 0, D, Z_FLOOR, Z_TOP - Z_FLOOR))      # right wall
    s = s.edges("|Z").edges(">X and <Y").fillet(3.0)
    for ref, side, u, z, prof, note in cuts:
        if side == "right":
            s = s.cut(cutter(side, u, z, prof))
    # floor: standoff holes, vent slots, holes for the steel parking discs and
    # the plate screws
    for ref in board_holes(parts):
        x, y = hole_xy(parts, ref)
        s = s.cut(hole(x, y, 4.2, Z_FLOOR - 1))
    for x, y, l in vents(parts):
        s = s.cut(cq.Workplane("XY").center(x, y).slot2D(l, 5).extrude(10).translate((0, 0, Z_FLOOR - 1)))
    for x, y in slot_magnets(parts):
        s = s.cut(hole(x, y, DISC_D, Z_FLOOR - 1, T + 2))
    for x, y in plate_screws():
        s = s.cut(hole(x, y, 3.4, Z_FLOOR - 1))
    return s


def plate_screws():
    """(x, y) of the M3 countersunk screws up through the floor into PEM nuts in
    the plates' flanges: three along the back, clear of the parked slot covers
    (x 38-145) and J7's notch, and three along the left, clear of the standoffs."""
    yb = D - T - PLATE_FLANGE / 2
    xl = T + PLATE_FLANGE / 2
    return ([(x, yb) for x in (20.0, 160.0, W - 20.0)] +
            [(xl, y) for y in (40.0, 75.0, D - 40.0)])         # clear of H7 at mid-depth


def flange_notches(parts):
    """Boxes (x0, x1, y0, y1) cut from the plates' flanges where a part reaches
    down near them under the board (J7's pins and board locks, 0.2 mm above the
    flange), with 1.5 mm to spare, so the plate slides in clear."""
    top = Z_FLOOR + 2 * T
    out = []
    for ref, p in parts.items():
        m = model_solid(p)
        if m is None:
            continue
        b = m.BoundingBox()
        if b.zmin < top + 1.0:
            out.append((b.xmin - 1.5, b.xmax + 1.5, b.ymin - 1.5, b.ymax + 1.5))
    return out


def plate(parts, cuts, side):
    """The back or left plate: a wall from the floor's underside to Z_TOP with a
    flange bent in along the bottom, lying on the floor (screwed from below).
    The back plate fits between the left plate and the right wall; the left
    plate runs from behind the front wall to the back corner."""
    z0 = Z_FLOOR
    if side == "back":
        s = rounded_plate(T, W - T, D - T, D, z0, Z_TOP - z0)
        s = s.union(rounded_plate(T, W - T, D - T - PLATE_FLANGE, D - T, z0 + T, T))
    else:
        s = rounded_plate(0, T, T, D, z0, Z_TOP - z0)
        s = s.union(rounded_plate(T, T + PLATE_FLANGE, T, D - T - PLATE_FLANGE, z0 + T, T))
    for ref, sd, u, z, prof, note in cuts:
        if sd == side:
            s = s.cut(cutter(sd, u, z, prof))
    for x0, x1, y0, y1 in flange_notches(parts):
        s = s.cut(rounded_plate(x0, x1, y0, y1, z0 + T - 0.01, T + 0.02))
    for x, y in plate_screws():
        s = s.cut(hole(x, y, 2.5, z0))
    return s


def parking_discs(parts):
    return [hole(x, y, DISC_D, Z_FLOOR, DISC_T) for x, y in slot_magnets(parts)]


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


def parked(solid):
    """A cover that is out, parked under the floor right below where it fits on
    the top: cap up against the floor, its magnets on the steel discs."""
    return solid.translate((0, 0, Z_FLOOR - (Z_TOP + ACRYLIC + CAP)))


def parked_boxes(parts):
    """name -> (x0, x1, y0, y1) of each parked cover (its cap)."""
    bay, cart, slot_x = openings(parts)
    n = len(slot_x)
    pitch = (bay[1] - bay[0]) / n
    out = {"slot_cover_%d" % (i + 1): (bay[0] + i * pitch + 0.2, bay[0] + (i + 1) * pitch - 0.2, bay[2] - LIP, D)
           for i in range(n)}
    out["cart_cover"] = (cart[0] - LIP, cart[1] + LIP, cart[2] - LIP, cart[3] + LIP)
    return out


def acrylic_top(parts):
    bay, cart, slot_x = openings(parts)
    z0 = Z_TOP
    s = rounded_plate(0, W, 0, D, z0, ACRYLIC, 3.0)
    s = s.cut(rounded_plate(bay[0], bay[1], bay[2], D + 1, z0 - 1, ACRYLIC + 2))
    s = s.cut(rounded_plate(cart[0], cart[1], cart[2], cart[3], z0 - 1, ACRYLIC + 2, 1.0))
    for ref in board_holes(parts):
        x, y = hole_xy(parts, ref)
        s = s.cut(hole(x, y, 3.4, z0 - 1))
    for x, y in slot_magnets(parts):
        s = s.cut(hole(x, y, MAG_D + 0.1, z0 - 1))
    return s


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
    z0 = Z_TOP
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
    z0 = Z_TOP
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
    """Magnet discs: "top" in the acrylic top (flush with its top face), then one
    pair per cover in its cap (cover name -> pair), in place on the top."""
    z0 = Z_TOP
    m = slot_magnets(parts)
    out = {"top": [hole(x, y, MAG_D, z0 + ACRYLIC - MAG_T, MAG_T) for x, y in m]}
    for i in range(len(SLOTS)):
        out["slot_cover_%d" % (i + 1)] = [hole(x, y, MAG_D, z0 + ACRYLIC, MAG_T) for x, y in m[2 * i:2 * i + 2]]
    out["cart_cover"] = [hole(x, y, MAG_D, z0 + ACRYLIC, MAG_T) for x, y in m[-2:]]
    return out


# ---------------------------------------------------------------- drawings
ALU_C, ACR_C, PLATE_C = "#b9bec5", "#cfe8f7", "#4a4f56"


def dim(ax, p0, p1, text, off=(0, 0), fs=9):
    ax.annotate("", p0, p1, arrowprops=dict(arrowstyle="<->", lw=0.8, color="#333"))
    ax.text((p0[0] + p1[0]) / 2 + off[0], (p0[1] + p1[1]) / 2 + off[1], text, ha="center", va="center",
            fontsize=fs, color="#222", bbox=dict(fc="white", ec="none", pad=0.6))


def _cover_patches(ax, info, alpha=0.7, label=""):
    bay, cart = info["bay"], info["cart"]
    n = len(info["slot_x"])
    pitch = (bay[1] - bay[0]) / n
    Dd = info["D"]
    for i in range(n):
        x0 = bay[0] + i * pitch + 0.2
        ax.add_patch(Rectangle((x0, bay[2] - LIP), pitch - 0.4, Dd - bay[2] + LIP, fc="#9fd0ef", ec="#1f6fa8",
                               lw=1.0, alpha=alpha))
        ax.add_patch(Circle((x0 + pitch / 2 - 0.2, bay[2] - LIP), 4, fc="white", ec="#1f6fa8", lw=0.8))
        ax.text(x0 + pitch / 2, (bay[2] + Dd) / 2, "J%d cover%s" % (9 + i, label), rotation=90, ha="center",
                va="center", fontsize=9)
    ax.add_patch(Rectangle((cart[0] - LIP, cart[2] - LIP), cart[1] - cart[0] + 2 * LIP, cart[3] - cart[2] + 2 * LIP,
                           fc="#9fd0ef", ec="#1f6fa8", lw=1.0, alpha=alpha))
    ax.add_patch(Rectangle((cart[0], cart[2]), cart[1] - cart[0], cart[3] - cart[2], fc="none", ec="#1f6fa8",
                           lw=0.8, ls=":"))
    ax.text((cart[0] + cart[1]) / 2, (cart[2] + cart[3]) / 2, "J8 cover" + label, ha="center", va="center",
            fontsize=9)


def _frame(ax, info, title):
    Wd, Dd = info["W"], info["D"]
    dim(ax, (0, -14), (Wd, -14), "%.0f" % Wd)
    dim(ax, (Wd + 30, 0), (Wd + 30, Dd), "%.1f" % Dd)
    ax.text(Wd / 2, Dd + 22, "BACK", ha="center", fontsize=11, weight="bold")
    ax.text(Wd / 2, -30, "FRONT", ha="center", fontsize=11, weight="bold")
    ax.set_xlim(-45, Wd + 45)
    ax.set_ylim(-38, Dd + 32)
    ax.set_aspect("equal")
    ax.axis("off")
    ax.set_title(title, fontsize=11)


def draw_top(info, path):
    """Top view (acrylic top, covers, magnets, screws, wall connectors) and
    the underside (feet, vents, steel discs, the covers parked there)."""
    Wd, Dd = info["W"], info["D"]
    fig, (ax, bx) = plt.subplots(1, 2, figsize=(20, 9.5))
    # top
    ax.add_patch(FancyBboxPatch((0, 0), Wd, Dd, boxstyle="round,pad=0,rounding_size=3", fc=ALU_C, ec="#555",
                                lw=1.2))
    ax.add_patch(Rectangle((T, Dd - T), Wd - 2 * T, T, fc=PLATE_C, ec="#333", lw=0.6))
    ax.add_patch(Rectangle((0, T), T, Dd - T, fc=PLATE_C, ec="#333", lw=0.6))
    ax.add_patch(FancyBboxPatch((0, 0), Wd, Dd, boxstyle="round,pad=0,rounding_size=3", fc=ACR_C, ec="#2b7bb9",
                                lw=1.2, alpha=0.5))
    _cover_patches(ax, info)
    for x, y in info["magnets"]:
        ax.add_patch(Circle((x, y), MAG_D / 2, fc="#b03a2e", ec="none"))
    for x, y in info["holes"].values():
        ax.add_patch(Circle((x, y), 2.8, fc="#333", ec="none"))
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
    ax.text(Wd / 2, 40, "4 mm clear acrylic top over the whole case,\n"
            "8 screws into the board standoffs", ha="center", va="center", fontsize=10)
    _frame(ax, info, "Top (mm).  Blue = acrylic over the walls (dark edges = the back and left plates),\n"
           "black dots = M3 screws, red dots = magnets, red ticks = wall connectors")
    # underside, drawn as seen through the case from above (left is left)
    bx.add_patch(FancyBboxPatch((0, 0), Wd, Dd, boxstyle="round,pad=0,rounding_size=3", fc=ALU_C, ec="#555",
                                lw=1.2))
    for x, y, l in info["vents"]:
        bx.add_patch(FancyBboxPatch((x - l / 2, y - 2.5), l, 5, boxstyle="round,pad=0,rounding_size=2.5",
                                    fc="white", ec="#555", lw=0.6))
    _cover_patches(bx, info, 0.8, "\nparked")
    for x, y in info["magnets"]:
        bx.add_patch(Circle((x, y), DISC_D / 2, fc="#555", ec="#222", lw=0.6))
    for x, y in info["holes"].values():
        bx.add_patch(Circle((x, y), 2.8, fc="#d4c08a", ec="#8a7a4a"))
    for x, y in info["plate_screws"]:
        bx.add_patch(Circle((x, y), 2.6, fc="#333", ec="none"))
    for x, y in info["feet"]:
        bx.add_patch(Circle((x, y), FOOT_D / 2, fc="#333", ec="none"))
    bx.text(Wd / 2, info["vents"][0][1] - 12, "vent slots", ha="center", va="center", fontsize=9)
    bx.text(FOOT_IN + 12, FOOT_IN, "%.0f mm foot" % FEET, va="center", fontsize=9)
    _frame(bx, info, "Underside, seen through the case from above (left is left).  Dark dots = steel discs\n"
           "flush in the floor, black = %.0f mm rubber feet and the plate screws, tan = floor standoffs" % FEET)
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


def draw_walls(info, path):
    """Back, left and right walls seen from outside with their cut-outs (which part
    each wall belongs to), plus a section front to back with a cover parked under
    the floor."""
    Wd, Dd = info["W"], info["D"]
    zf, zt, desk = info["Z_FLOOR"], info["Z_TOP"], info["Z_DESK"]
    za = zt + ACRYLIC
    fig, axs = plt.subplots(4, 1, figsize=(13, 16), gridspec_kw=dict(height_ratios=[1, 1, 1, 1.25]))
    views = (("back", "Back plate, seen from behind (flat, one bend: the bottom flange)", True, Wd, (T, Wd - T)),
             ("left", "Left plate, seen from the left, front at the right (flat, one bend)", True, Dd, (T, Dd)),
             ("right", "Right wall of the tray, seen from the right, front at the left", False, Dd, (0, Dd)))
    for ax, (side, title, flip, L, (p0, p1)) in zip(axs, views):
        s = -1 if flip else 1
        tray = side == "right"
        ax.add_patch(Rectangle((min(0, s * L), zf), L, zt - zf, fc=ALU_C, ec="#444", lw=1))
        ax.add_patch(Rectangle((min(s * p0, s * p1), zf), p1 - p0, zt - zf, fc=ALU_C if tray else PLATE_C,
                               ec="#222", lw=1))
        ax.add_patch(Rectangle((min(0, s * L), zt), L, ACRYLIC, fc=ACR_C, ec="#2b7bb9", lw=0.8))
        for u in (FOOT_IN, L - FOOT_IN):
            ax.add_patch(Rectangle((s * u - FOOT_D / 2, desk), FOOT_D, FEET, fc="#333", ec="none"))
        ax.plot([min(0, s * L) - 15, max(0, s * L) + 15], [desk, desk], color="#8a6d1f", lw=1)
        for cu in info["cuts"]:
            if cu["side"] != side:
                continue
            for patch in cut_outline(cu["prof"], cu["u"], cu["z"], flip):
                patch.set_facecolor("white")
                patch.set_edgecolor("#222")
                patch.set_linewidth(0.9)
                ax.add_patch(patch)
            ax.text(s * cu["u"], za + 4, cu["ref"], ha="center", va="bottom", fontsize=9)
            ax.text(s * cu["u"], desk - 2, "z %.1f" % cu["z"], ha="center", va="top", fontsize=7, color="#c33")
        ax.text(s * (p0 + p1) / 2, zf + 3, "tray" if tray else side + " plate", ha="center", fontsize=9,
                color="#222" if tray else "white")
        ax.set_xlim(min(0, s * L) - 22, max(0, s * L) + 22)
        ax.set_ylim(desk - 9, za + 12)
        ax.set_aspect("equal")
        ax.set_yticks([desk, zf, 0, zt, za])
        ax.set_yticklabels(["%.1f desk" % desk, "%.1f floor" % zf, "0 board top", "%.0f wall top" % zt,
                            "%.0f top" % za], fontsize=8)
        ax.set_xticks([])
        for sp in ("top", "right", "bottom"):
            ax.spines[sp].set_visible(False)
        ax.set_title(title, fontsize=10, loc="left")
    # section front to back through the expansion slot covers
    ax = axs[3]
    ax.plot([-10, Dd + 10], [desk, desk], color="#8a6d1f", lw=1.2)
    ax.text(Dd + 8, desk - 1, "desk", ha="right", va="top", fontsize=8, color="#8a6d1f")
    ax.add_patch(Rectangle((0, zf), Dd - T, T, fc=ALU_C, ec="#444"))
    ax.add_patch(Rectangle((0, zf), T, zt - zf, fc=ALU_C, ec="#444"))
    ax.add_patch(Rectangle((Dd - T, zf), T, zt - zf, fc=PLATE_C, ec="#222"))
    ax.add_patch(Rectangle((Dd - T - PLATE_FLANGE, zf + T), PLATE_FLANGE, T, fc=PLATE_C, ec="#222"))
    bay = info["bay"]
    ax.add_patch(Rectangle((0, zt), bay[2], ACRYLIC, fc=ACR_C, ec="#2b7bb9"))
    ybf = info["Y_BF"]
    ax.add_patch(Rectangle((ybf, -PCB_T), Dd - ybf - OFF, PCB_T, fc="#2e7d4f", ec="#1b4d30"))
    for y in (ybf + 5, Dd - OFF - 5):
        ax.add_patch(Rectangle((y - 2.75, zf + T), 5.5, -PCB_T - zf - T, fc="#d4c08a", ec="#8a7a4a", lw=0.6))
        ax.add_patch(Rectangle((y - 2.75, 0), 5.5, zt, fc="#d4c08a", ec="#8a7a4a", lw=0.6))
    for y in np.arange(ybf + 15, bay[2] - 20, 35):
        ax.add_patch(Rectangle((y, 0), 12, 9.1, fc="#222", ec="none"))
    for u in (FOOT_IN, Dd - FOOT_IN):
        ax.add_patch(Rectangle((u - FOOT_D / 2, desk), FOOT_D, FEET, fc="#333", ec="none", alpha=0.3))
    ax.text(FOOT_IN, desk + FEET / 2, "feet (near the\nside walls)", ha="center", va="center", fontsize=7)
    # the cover in its slot opening, and the same cover parked under the floor
    x0, x1, y0, y1 = info["parked"]["slot_cover_1"]
    for z, label, lz in ((zt, "J9 cover in place", za + 5), (zf - ACRYLIC - CAP, "J9 cover parked: magnets on steel "
                                                                "discs in the floor", desk + 1.5)):
        plug, cap = (y0 + LIP + 0.2, z), (y0, z + ACRYLIC)
        ax.add_patch(Rectangle(plug, y1 - y0 - LIP - 0.2, ACRYLIC, fc="#9fd0ef", ec="#1f6fa8", alpha=0.9))
        ax.add_patch(Rectangle(cap, y1 - y0, CAP, fc="#9fd0ef", ec="#1f6fa8", alpha=0.9))
        ax.add_patch(Rectangle((y0 + LIP / 2 - MAG_D / 2, cap[1]), MAG_D, MAG_T, fc="#b03a2e", ec="none"))
        ax.text(y0 - 3, lz, label, ha="right", va="center", fontsize=8, color="#1f6fa8")
    ax.add_patch(Rectangle((y0 + LIP / 2 - DISC_D / 2, zf), DISC_D, DISC_T, fc="#555", ec="none"))
    ax.add_patch(Rectangle((y0 + LIP / 2 - MAG_D / 2, zt + ACRYLIC - MAG_T), MAG_D, MAG_T, fc="#b03a2e",
                           ec="none"))
    ax.set_xlim(-10, Dd + 10)
    ax.set_ylim(desk - 4, za + 12)
    ax.set_aspect("equal")
    ax.set_yticks([desk, zf, 0, zt, za])
    ax.set_yticklabels(["%.1f" % v for v in [desk, zf, 0, zt, za]], fontsize=8)
    ax.set_xticks([0, round(bay[2] - LIP, 1), round(Dd, 1)])
    ax.set_xlabel("y from the front (mm); z from the main board's top face (mm)", fontsize=9)
    ax.set_title("Section front to back through J9: tray, back plate (dark) with its flange on the floor, %.0f mm "
                 "standoffs to the acrylic top, the J9 cover in place and parked, %.0f mm feet" % (zt, FEET),
                 fontsize=10, loc="left")
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
    solids = {
        "tray": tray(parts, cuts),
        "back_plate": plate(parts, cuts, "back"),
        "left_plate": plate(parts, cuts, "left"),
        "acrylic_top": acrylic_top(parts),
        "cart_cover": cart_cover(parts),
    }
    covers = slot_covers(parts)
    for i, c in enumerate(covers):
        solids["slot_cover_%d" % (i + 1)] = c
    os.makedirs(os.path.join(out, "dxf"), exist_ok=True)
    for name, sol in solids.items():
        if name.startswith("slot_cover_") and name != "slot_cover_1":
            continue
        fn = "slot_cover" if name.startswith("slot_cover") else name
        cq.exporters.export(sol, os.path.join(out, fn + ".step"))
    z0 = Z_TOP
    export_dxf(solids["acrylic_top"], z0 + ACRYLIC / 2, os.path.join(out, "dxf", "acrylic_top_4mm.dxf"))
    export_dxf(covers[0], z0 + ACRYLIC / 2, os.path.join(out, "dxf", "slot_cover_plug_4mm.dxf"))
    export_dxf(covers[0], z0 + ACRYLIC + CAP / 2, os.path.join(out, "dxf", "slot_cover_cap_3mm.dxf"))
    export_dxf(solids["cart_cover"], z0 + ACRYLIC / 2, os.path.join(out, "dxf", "cart_cover_plug_4mm.dxf"))
    export_dxf(solids["cart_cover"], z0 + ACRYLIC + CAP / 2, os.path.join(out, "dxf", "cart_cover_cap_3mm.dxf"))
    # the keyboard bay went with the keyboard (2026-10-25), the split shells with the plates (2026-10-27)
    for f in ("keyboard_rail.step", "keyboard_plate.step", "keyboard_blank.step", "dxf/keyboard_blank_3mm.dxf",
              "dxf/keyboard_plate_1.5mm.dxf",
              "lower_shell.step", "upper_shell.step"):
        if os.path.exists(os.path.join(out, f)):
            os.remove(os.path.join(out, f))

    covers_all = ["slot_cover_%d" % (i + 1) for i in range(len(slot_x))] + ["cart_cover"]
    parked_solids = {n: parked(solids[n]) for n in covers_all}
    info = dict(W=W, D=D, LIP=LIP, T=T, OFF=OFF, BOARD_D=BOARD_D, Y_BF=Y_BF, Z_FLOOR=Z_FLOOR, Z_DESK=Z_DESK,
                Z_TOP=Z_TOP, PLATE_FLANGE=PLATE_FLANGE, plate_screws=plate_screws(), ACRYLIC=ACRYLIC, CAP=CAP, FEET=FEET, FOOT_D=FOOT_D,
                bay=bay, cart=cart, slot_x=slot_x, magnets=slot_magnets(parts),
                parked=parked_boxes(parts), feet=feet(), vents=vents(parts),
                slot_cover=slot_cover_size(parts), cart_cover=cart_cover_size(parts),
                cuts=[dict(ref=r, side=sd, u=u, z=z, prof=list(p), note=n)
                      for r, sd, u, z, p, n in cuts],
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
        for name, sol in parked_solids.items():
            cq.exporters.export(sol, os.path.join(mesh, name + "_parked.stl"), tolerance=0.05, angularTolerance=0.2)
        groups = {"standoffs": standoffs(parts), "parking_discs": parking_discs(parts),
                  "feet": [cq.Workplane("XY").center(x, y).circle(FOOT_D / 2).extrude(FEET).translate((0, 0, Z_DESK))
                           for x, y in feet()]}
        for name, group in magnets(parts).items():
            groups["magnets_" + name] = group
            if name in parked_solids:
                groups["magnets_%s_parked" % name] = [parked(m) for m in group]
        for name, group in groups.items():
            cq.exporters.export(cq.Workplane().add([x.val() for x in group]).combine(),
                                os.path.join(mesh, name + ".stl"))
        models = []
        for ref, p in parts.items():
            m = model_solid(p)
            if m is not None:
                models.append(ref)
                cq.exporters.export(cq.Workplane().add(m), os.path.join(mesh, "model_%s.stl" % ref),
                                    tolerance=0.05, angularTolerance=0.3)
        board = dict(parts={k: dict(x=cx(v["x"]), y=cy(v["y"]), rot=v["rot"],
                                    crt=[cx(v["crt"][0]), cy(v["crt"][3]), cx(v["crt"][2]), cy(v["crt"][1])]
                                    if v["crt"] else None, fp=v["fp"]) for k, v in parts.items()})
        with open(os.path.join(mesh, "board.json"), "w") as f:
            json.dump(dict(board, models=models, **info), f)
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
        print("%-4s %-5s u %6.1f  centre z %5.2f  %s" % (c["ref"], c["side"], c["u"], c["z"], c["note"]))
    print("case %.1f x %.1f mm, %.1f mm tall desk to top (%.1f mm without the %.0f mm feet)" %
          (W, info["D"], Z_TOP + ACRYLIC - Z_DESK, Z_TOP + ACRYLIC - Z_FLOOR, FEET))

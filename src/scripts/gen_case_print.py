#!/usr/bin/env python3
"""
gen_case_print.py - the 3D-printed PLACARD case for a 220 x 220 mm bed
(Creality Ender 3), printed without supports and held together with M3 screws
and nuts only (no glue, no heat-set inserts, no threads cut in plastic).

It has the same outside size, connector cut-outs, top openings and covers as
the aluminium case (gen_case.py), but every part is designed to print flat:

- floor: four flat pieces with the board's standoff bosses, joined by five
  straps screwed on under the seams;
- walls: four flat panels (front, back, left, right), each in two pieces,
  printed outside face down.  Each has a flange along the bottom with open
  nut seats (screwed up through the floor) and nut lugs along the top (the
  top's screws);
- top: four pieces that overlap in half laps along the seams, screwed
  through the laps;
- covers: the printed snap covers of gen_case.py, cap face down.

    pip install cadquery
    python3 gen_case_print.py [--pcb path/to/placard.kicad_pcb] [--out case/print]
                              [--mesh dir] [--no-fit]

Writes STL files, already turned into print orientation, to case/print/ and
docs/case/case_print_pieces.png, and runs the fit check (no printed part
may cut into the board, a part on it, a standoff or another printed part,
and no nut seat or screw head may sit under a through-hole pad).  Then run
case_print_check.py on the STL files.  See docs/case/CASE.md, "3D-printed
version".  The board file is only read.

Coordinates (mm) are gen_case.py's: x from the case's left outside face, y
from the front outside face toward the back, z up from the board's top face.

Date: 2026-11-16
"""

import argparse
import glob
import json
import math
import os
import re

import cadquery as cq
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Circle, Polygon, Rectangle

import gen_case as g

BED = 220.0            # Ender 3 printable area, square
BED_MARGIN = 5.0       # each piece's footprint must fit BED - BED_MARGIN
SEAM_GAP = 0.1         # each piece stops this far short of its seam

T = g.T                # walls and floor, 2 mm (5 perimeters)
M3 = 3.4               # clearance hole
NUT_AF = 5.7           # M3 nut pocket, across flats
NUT_H = 2.4            # ISO 4032 M3 nut
TEAR = 1.6             # a sideways hole's roof peaks this many radii above its axis (39 deg from vertical)

# side wall vent slots end below the top's nut lugs
g.SIDE_VENT = (5.0, 14.0, 11.0, 20.0)
g.SIDE_VENT_SKIP = {}

# ---------------------------------------------------------------- floor
FLOOR_X, FLOOR_Y = 160.0, 114.0   # seams: between the parked slot covers and the parked cartridge cover,
                                  # and between the board holes H7/H8 and the cartridge cover's parking slots
BOSS_D = 8.0                      # boss under each board hole, floor to the board's underside
CSK_D, CSK_H = 6.4, 1.5           # 90 degree countersink for an M3 flat head, on the bed face: a 45 degree cone,
                                  # so there is no ceiling to bridge.  Only where a head must be flush.
VENT_ROWS = [30.0 + 12.0 * i for i in range(6)]            # floor vent slots, y centres
VENT_SPANS = [(72.5, 146.0), (174.0, 222.5)]               # two groups, a land under the seam for the straps
# straps under the floor seams: (x, y, long axis); one over the middle joins all four pieces
STRAP_W, STRAP_L = 24.0, 36.0
STRAP_T = NUT_H + 0.2 + 1.6       # nut pocket + 1.6 mm under it
STRAP_DX, STRAP_DY = 7.0, 12.0    # its four screws, from its centre (across, along)
STRAPS = [(FLOOR_X, FLOOR_Y, "y"), (FLOOR_X, 60.0, "y"), (FLOOR_X, 180.0, "y"),
          (85.0, FLOOR_Y, "x"), (262.0, FLOOR_Y, "x")]

# ---------------------------------------------------------------- walls
SIDES = ("front", "back", "left", "right")
WALL_SEAM = {"front": 125.0, "back": 190.0, "left": 130.0, "right": 90.0}   # clear of every cut-out and vent
FL_D = 9.0             # bottom flange, inside face to free edge (it lies on the floor, under the board's edge)
FL_T = 2.0
FL_END = 12.3          # the flanges stop short of the corner bosses
SEAT_V = 5.5           # nut seat / floor screw from the wall's inside face: 7.5 mm from the outside, in line with the board holes
SEAT_RIB = 2.0         # ribs either side of the nut, as tall as the nut
BOSS_NOTCH = BOSS_D / 2 + 0.6     # flange notch half width round a boss
PIN_NOTCH = 2.0        # flange notch this far round the pads of a part whose pins reach down to the flange
PAD_CLEAR = 1.5        # a nut seat stays this far from every through-hole pad
# u (x or y in case coordinates) of each wall's floor screws (nut seats on the flange)
SEATS = {"front": [18.0, 70.0, 118.0, 133.0, 205.0, 277.0],
         "back": [50.0, 135.0, 184.0, 196.0, 237.0],
         "left": [22.0, 75.0, 145.0, 162.0],
         "right": [22.0, 70.0, 96.0, 160.0, 198.0]}
# and of the top's screws (nut lugs under the top)
LUGS = {"front": [22.0, 70.0, 116.0, 134.0, 205.0, 273.0],
        "back": [28.0, 176.0, 197.0, 245.0, 277.0],
        "left": [30.0, 90.0, 122.0, 138.0, 198.0],
        "right": [30.0, 82.0, 97.0, 160.0, 198.0]}
LUG_W, LUG_D = 11.0, 10.0          # lug along the wall, and inward from the inside face
LUG_V = 6.0                        # its screw from the inside face (8 mm from the outside)
LUG_WEB, LUG_SLOT, LUG_BASE = 1.6, NUT_H + 0.3, 1.8    # top web (under the top), nut slot, under the nut
CORNER_CHAMFER = 1.5               # front and back walls' outside corners

# ---------------------------------------------------------------- top
TOP_X, TOP_Y = 160.0, 100.0        # seams, between the expansion bay and the cartridge cover's lap
LAP = 6.0                          # half laps reach this far each side of a seam
LAP_SCREWS = ([(TOP_X, y) for y in (25.0, 65.0, TOP_Y, 130.0, 170.0, 205.0)] +
              [(x, TOP_Y) for x in (30.0, 85.0, 135.0, 190.0, 235.0, 272.0)])

NAMES4 = ("front_left", "front_right", "back_left", "back_right")


# ---------------------------------------------------------------- helpers
def box(x0, x1, y0, y1, z0, z1):
    return cq.Workplane("XY").box(x1 - x0, y1 - y0, z1 - z0, centered=False).translate((x0, y0, z0))


def pt(side, u, v):
    """Wall coordinates (u along the wall = case x or y, v inward from the wall's
    inside face) -> case (x, y)."""
    return {"front": (u, T + v), "back": (u, g.D - T - v), "left": (T + v, u), "right": (g.W - T - v, u)}[side]


def wbox(side, u0, u1, v0, v1, z0, z1):
    (xa, ya), (xb, yb) = pt(side, u0, v0), pt(side, u1, v1)
    return box(min(xa, xb), max(xa, xb), min(ya, yb), max(ya, yb), z0, z1)


def teardrop(r, n=40):
    """A hole's outline for printing on its side: a circle with a peaked roof
    toward +b, so nothing overhangs more than 39 degrees."""
    phi = math.asin(1.0 / TEAR)
    a0, a1 = math.pi - phi, 2 * math.pi + phi
    pts = [(r * math.cos(a0 + (a1 - a0) * i / n), r * math.sin(a0 + (a1 - a0) * i / n)) for i in range(n + 1)]
    return pts + [(0.0, TEAR * r)]


def tear_hole(side, u, v, z0, z1):
    """A vertical (in the case) M3 hole through a wall's flange or lug, which
    prints on its side: teardrop peak toward the inside (up on the bed)."""
    pts = [pt(side, u + a, v + b) for a, b in teardrop(M3 / 2)]
    return cq.Workplane("XY").polyline(pts).close().extrude(z1 - z0).translate((0, 0, z0))


def hexagon(x, y, af, z0, h):
    return cq.Workplane("XY").center(x, y).polygon(6, af / math.cos(math.pi / 6)).extrude(h).translate((0, 0, z0))


def read_pads(pcb, parts):
    """Every through-hole pad on the board: (ref, case x, case y)."""
    s = open(pcb, encoding="utf-8").read()
    pads = []
    for f in g.sexpr_blocks(s, "footprint"):
        ref = (re.search(r'\(property "Reference" "([^"]+)"', f) or re.search(r'reference "([^"]+)"', f)).group(1)
        p = parts[ref]
        th = math.radians(-p["rot"])
        for pd in g.sexpr_blocks(f, "pad"):
            if not re.match(r'\(pad "[^"]*" (thru_hole|np_thru_hole) ', pd):
                continue
            a = list(map(float, re.search(r"\(at ([\d.\- ]+)\)", pd).group(1).split()))
            x = p["x"] + a[0] * math.cos(th) - a[1] * math.sin(th)
            y = p["y"] + a[0] * math.sin(th) + a[1] * math.cos(th)
            pads.append((ref, g.cx(x), g.cy(y)))
    return pads


def wall_len(side):
    return g.W if side in ("front", "back") else g.D


def wall_span(side):
    """A wall's ends: the front and back walls run the full width, and the side
    walls fit between them."""
    return (0.0, g.W) if side in ("front", "back") else (T + SEAM_GAP, g.D - T - SEAM_GAP)


def seat_xy(side, u):
    return pt(side, u, SEAT_V)


def lug_xy(side, u):
    return pt(side, u, LUG_V)


def flush_seat(parts, side, u):
    """True where a floor screw's head has to be flush: under a parked cover, which
    lies against the floor's underside.  Everywhere else the heads are plain
    button heads, well inside the feet's height."""
    x, y = seat_xy(side, u)
    return any(x0 - 3 < x < x1 + 3 and y0 - 3 < y < y1 + 3 for x0, x1, y0, y1 in g.parked_boxes(parts).values())


def strap_screws(x, y, axis):
    dx, dy = (STRAP_DX, STRAP_DY) if axis == "y" else (STRAP_DY, STRAP_DX)
    return [(x + sx * dx, y + sy * dy) for sx in (-1, 1) for sy in (-1, 1)]


# ---------------------------------------------------------------- the parts
def floor(parts):
    zf = g.Z_FLOOR
    s = g.rounded_plate(0, g.W, 0, g.D, zf, T, 3.0)
    for ref in g.board_holes(parts):
        x, y = g.hole_xy(parts, ref)
        s = s.union(cq.Workplane("XY").center(x, y).circle(BOSS_D / 2).extrude(-g.PCB_T - zf).translate((0, 0, zf)))
        s = s.cut(g.hole(x, y, M3, zf - 1))
    for y in VENT_ROWS:
        for x0, x1 in VENT_SPANS:
            s = s.cut(cq.Workplane("XY").center((x0 + x1) / 2, y).slot2D(x1 - x0, 5).extrude(10).translate((0, 0, zf - 1)))
    for x0, x1, y0, y1 in g.floor_slots(parts):
        s = s.cut(box(x0, x1, y0, y1, zf - 1, zf + T + 1))
    for x, y in g.feet():
        s = s.cut(g.hole(x, y, g.FOOT_HOLE, zf - 1))
    for side in SIDES:
        for u in SEATS[side]:
            x, y = seat_xy(side, u)
            s = s.cut(g.hole(x, y, M3, zf - 1))
            if flush_seat(parts, side, u):
                cone = cq.Solid.makeCone(CSK_D / 2, M3 / 2, CSK_H, cq.Vector(x, y, zf), cq.Vector(0, 0, 1))
                s = s.cut(cq.Workplane().add(cone))
    for st in STRAPS:
        for x, y in strap_screws(*st):
            s = s.cut(g.hole(x, y, M3, zf - 1))
    return s


def strap():
    """A strap, as printed: nut pockets up.  It goes under the floor the same way
    up, so each nut is shut in between the strap and the floor."""
    s = g.rounded_plate(-STRAP_W / 2, STRAP_W / 2, -STRAP_L / 2, STRAP_L / 2, 0, STRAP_T, 2.0)
    for x, y in strap_screws(0, 0, "y"):
        s = s.cut(g.hole(x, y, M3, -1))
        s = s.cut(hexagon(x, y, NUT_AF, STRAP_T - NUT_H - 0.2, 5))
    return s


def strap_placed(x, y, axis):
    s = strap().translate((0, 0, g.Z_FLOOR - STRAP_T))
    if axis == "x":
        s = s.rotate((0, 0, 0), (0, 0, 1), 90)
    return s.translate((x, y, 0))


def flange_notches(side, parts, pads, models):
    """(u0, u1) bands cut out of a wall's flange: round the floor bosses, and round
    the pads of any part whose pins reach down to the flange (VGA J7)."""
    out = []
    for hx, hy in g.board_hole_xys(parts):
        u, d = (hx, hy) if side in ("front", "back") else (hy, hx)
        edge = {"front": d, "back": g.D - d, "left": d, "right": g.W - d}[side]
        if edge < T + FL_D + BOSS_NOTCH:
            out.append((u - BOSS_NOTCH, u + BOSS_NOTCH))
    top = g.Z_FLOOR + T + FL_T
    low = {ref for ref, b in models.items() if b.zmin < top + 0.3}
    for ref in low:
        us = []
        for r, x, y in pads:
            if r != ref:
                continue
            u, d = (x, y) if side in ("front", "back") else (y, x)
            edge = {"front": d, "back": g.D - d, "left": d, "right": g.W - d}[side]
            if edge < T + FL_D + PIN_NOTCH:
                us.append(u)
        if us:
            out.append((min(us) - PIN_NOTCH, max(us) + PIN_NOTCH))
    return out


def wall(side, parts, cuts, pads, models):
    """A whole wall panel in case coordinates (before it is cut in two)."""
    zb = g.Z_FLOOR + T
    u0, u1 = wall_span(side)
    L = wall_len(side)
    s = wbox(side, u0, u1, -T, 0, zb, g.Z_TOP)
    # bottom flange, lying on the floor under the board's edge
    fl = wbox(side, FL_END, L - FL_END, 0, FL_D, zb, zb + FL_T)
    for a, b in flange_notches(side, parts, pads, models):
        fl = fl.cut(wbox(side, a, b, -0.01, FL_D + 1, zb - 1, zb + FL_T + 1))
    s = s.union(fl)
    half = NUT_AF / 2
    for u in SEATS[side]:
        # an open nut seat on the flange: a rib each side of the nut and a stop behind it
        for sg in (-1, 1):
            a, b = sorted((u + sg * half, u + sg * (half + SEAT_RIB)))
            s = s.union(wbox(side, a, b, 0, FL_D, zb, zb + FL_T + NUT_H))
        s = s.union(wbox(side, u - half, u + half, 0, SEAT_V - NUT_AF / math.cos(math.pi / 6) / 2 - 0.1,
                         zb, zb + FL_T + NUT_H))
        s = s.cut(tear_hole(side, u, SEAT_V, zb - 1, zb + FL_T + 0.01))
    zl = g.Z_TOP - LUG_WEB - LUG_SLOT - LUG_BASE
    for u in LUGS[side]:
        # a nut lug under the top: the nut slides into a slot from the inside
        s = s.union(wbox(side, u - LUG_W / 2, u + LUG_W / 2, 0, LUG_D, zl, g.Z_TOP))
        s = s.cut(wbox(side, u - half, u + half, LUG_V - NUT_AF / math.cos(math.pi / 6) / 2 - 0.1, LUG_D + 1,
                       zl + LUG_BASE, zl + LUG_BASE + LUG_SLOT))
        s = s.cut(tear_hole(side, u, LUG_V, zl - 1, g.Z_TOP + 1))
    for ref, sd, u, z, prof, note in cuts:
        if sd == side:
            s = s.cut(g.cutter(sd, u, z, prof))
    if side in ("left", "right"):
        for u in g.side_vents(cuts, side):
            s = s.cut(g.vent_cutter(side, u))
    if side == "back":
        for x, z in g.card_screws(parts):
            for zz in (z, g.PARK_HOLE_Z):      # card screw, and the parked slot cover's dome under it
                s = s.cut(cq.Workplane("XZ").center(x, zz).circle(M3 / 2).extrude(-10).translate((0, g.D - T - 1, 0)))
    if side in ("front", "back"):
        c = CORNER_CHAMFER
        yo, yi = (0.0, c) if side == "front" else (g.D, g.D - c)
        for xo, xi in ((0.0, c), (g.W, g.W - c)):
            s = s.cut(cq.Workplane("XY").polyline([(xo, yo), (xi, yo), (xo, yi)]).close().extrude(60)
                      .translate((0, 0, zb - 1)))
    return s


def wall_pieces(side, solid):
    """A wall cut at its seam: (name, solid) of its two pieces."""
    at = WALL_SEAM[side]
    ends = ("left", "right") if side in ("front", "back") else ("front", "back")
    out = []
    for nm, (a, b) in zip(ends, ((-50, at - SEAM_GAP), (at + SEAM_GAP, 400))):
        cut = box(a, b, -50, 400, -100, 100) if side in ("front", "back") else box(-50, 400, a, b, -100, 100)
        out.append(("wall_%s_%s" % (side, nm), solid.intersect(cut)))
    return out


def top(parts):
    s = g.acrylic_top(parts)
    for side in SIDES:
        for u in LUGS[side]:
            x, y = lug_xy(side, u)
            s = s.cut(g.hole(x, y, M3, g.Z_TOP - 1))
    for x, y in LAP_SCREWS:
        s = s.cut(g.hole(x, y, M3, g.Z_TOP - 1))
    return s


def top_pieces(solid):
    """The top in four pieces with half laps: along every seam one piece's upper
    half lies on its neighbour's lower half.  front_left and back_right carry
    the upper laps (printed top face down), the other two the lower laps."""
    X, Y, h, c, far = TOP_X, TOP_Y, LAP, SEAM_GAP, 1000.0
    zm = g.Z_TOP + g.ACRYLIC / 2
    lower = {"front_right": [(X - h + c, far, -far, Y + h - c)],
             "front_left": [(-far, X - h - c, -far, Y - h - c)],
             "back_right": [(X + h + c, far, Y + h + c, far)],
             "back_left": [(-far, X - h - c, Y - h + c, far), (-far, X + h - c, Y + h + c, far)]}
    upper = {"front_left": [(-far, X + h - c, -far, Y + h - c)],
             "front_right": [(X + h + c, far, -far, Y - h - c)],
             "back_left": [(-far, X - h - c, Y + h + c, far)],
             "back_right": [(X + h + c, far, Y - h + c, far), (X - h + c, far, Y + h + c, far)]}
    out = {}
    for name in NAMES4:
        m = None
        for regs, z0, z1 in ((lower[name], g.Z_TOP - 1, zm), (upper[name], zm, g.Z_TOP + g.ACRYLIC + 1)):
            for x0, x1, y0, y1 in regs:
                b = box(x0, x1, y0, y1, z0, z1)
                m = b if m is None else m.union(b)
        out["top_" + name] = solid.intersect(m)
    return out


TOP_FLIPPED = ("top_front_left", "top_back_right")


def floor_pieces(solid):
    X, Y, c = FLOOR_X, FLOOR_Y, SEAM_GAP
    boxes = [(-50, X - c, -50, Y - c), (X + c, 400, -50, Y - c), (-50, X - c, Y + c, 400), (X + c, 400, Y + c, 400)]
    return {"floor_" + n: solid.intersect(box(*b, -100, 100)) for n, b in zip(NAMES4, boxes)}


# ---------------------------------------------------------------- print orientation
def to_bed(solid):
    b = solid.val().BoundingBox()
    return solid.translate((-b.xmin, -b.ymin, -b.zmin))


def print_pose(name, solid):
    """A part turned into the way it prints, flat side on the bed at z = 0."""
    if name.startswith("wall_front"):
        solid = solid.rotate((0, 0, 0), (1, 0, 0), 90)      # outside face (-y) down
    elif name.startswith("wall_back"):
        solid = solid.rotate((0, 0, 0), (1, 0, 0), -90)
    elif name.startswith("wall_left"):
        solid = solid.rotate((0, 0, 0), (0, 1, 0), -90)
    elif name.startswith("wall_right"):
        solid = solid.rotate((0, 0, 0), (0, 1, 0), 90)
    elif name in TOP_FLIPPED:
        solid = solid.rotate((0, 0, 0), (1, 0, 0), 180)     # top face down
    return to_bed(solid)


ORIENT = {"floor": "underside down, bosses up", "wall": "outside face down, flange and lugs up",
          "top_front_left": "top face down", "top_back_right": "top face down",
          "top_front_right": "underside down", "top_back_left": "underside down",
          "floor_strap": "flat, nut pockets up", "slot_cover": "cap face down", "cart_cover": "cap face down"}


def orientation(name):
    for k in (name, name.split("_")[0]):
        if k in ORIENT:
            return ORIENT[k]
    return ""


# ---------------------------------------------------------------- fit check
def overlap(a, b):
    """Volume two solids share (0 when their boxes are apart)."""
    ba, bb = a.val().BoundingBox(), b.val().BoundingBox()
    if (ba.xmin > bb.xmax - 1e-6 or bb.xmin > ba.xmax - 1e-6 or ba.ymin > bb.ymax - 1e-6 or
            bb.ymin > ba.ymax - 1e-6 or ba.zmin > bb.zmax - 1e-6 or bb.zmin > ba.zmax - 1e-6):
        return 0.0
    i = a.intersect(b)
    return sum(x.Volume() for x in i.vals()) if i.vals() else 0.0


def fit_check(parts, pads, placed, model_solids):
    """Problems found with the assembled case, as text lines; [] when it fits."""
    bad = []
    names = sorted(placed)
    # printed parts against each other
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            v = overlap(placed[a], placed[b])
            if v > 0.05:
                bad.append("%s cuts into %s (%.2f mm3)" % (a, b, v))
    # against the board, its parts and the 27 mm standoffs
    hard = {"board": box(g.OFF, g.W - g.OFF, g.OFF, g.D - g.OFF, -g.PCB_T, 0)}
    for ref, m in model_solids.items():
        hard["part " + ref] = cq.Workplane().add(m)
    for ref in g.board_holes(parts):
        x, y = g.hole_xy(parts, ref)
        hard["standoff " + ref] = hexagon(x, y, 5.5, 0, g.Z_TOP)
    board_fixed = [n for n in names if not n.startswith(("slot_cover", "cart_cover"))]
    for a in board_fixed:
        for hn, h in hard.items():
            v = overlap(placed[a], h)
            if v > 0.05:
                bad.append("%s cuts into %s (%.2f mm3)" % (a, hn, v))
    # nut seats (4.4 mm above the floor, 1.6 mm under the board) against through-hole pads
    half = NUT_AF / 2 + SEAT_RIB + PAD_CLEAR
    holes = set(g.board_holes(parts))
    for side in SIDES:
        for u in SEATS[side]:
            for ref, x, y in pads:
                pu, d = (x, y) if side in ("front", "back") else (y, x)
                edge = {"front": d, "back": g.D - d, "left": d, "right": g.W - d}[side]
                if ref not in holes and abs(pu - u) < half and edge < T + FL_D + PAD_CLEAR:
                    bad.append("%s nut seat at %.0f is under %s's pad" % (side, u, ref))
    # the straps' screw heads on the floor (1.65 mm tall), and the lap nuts under the top
    for st in STRAPS:
        for x, y in strap_screws(*st):
            for ref, px, py in pads:
                if math.hypot(px - x, py - y) < 2.85 + PAD_CLEAR and ref in {r for r, b in MODEL_BOXES.items()
                                                                           if b.zmin < g.Z_FLOOR + T + 2.7}:
                    bad.append("strap screw at %.0f, %.0f is under %s's long pin" % (x, y, ref))
    for x, y in LAP_SCREWS:
        for ref, b in MODEL_BOXES.items():
            if b.zmax > g.Z_TOP - NUT_H - 2.5 and b.xmin - 4 < x < b.xmax + 4 and b.ymin - 4 < y < b.ymax + 4:
                bad.append("lap screw at %.0f, %.0f is over %s" % (x, y, ref))
    return bad


MODEL_BOXES = {}


# ---------------------------------------------------------------- hardware
def hardware(parts):
    seats = sum(len(v) for v in SEATS.values())
    flush = sum(flush_seat(parts, sd, u) for sd in SIDES for u in SEATS[sd])
    lugs = sum(len(v) for v in LUGS.values())
    nh = len(g.board_holes(parts))
    return [
        ("M3 x 6 button head screw", seats - flush + 4 * len(STRAPS),
         "%d up through the floor into the walls' nut seats, %d down through the floor into the straps"
         % (seats - flush, 4 * len(STRAPS))),
        ("M3 x 6 countersunk screw", flush, "the floor screws under the parked slot covers (back wall), flush"),
        ("M3 x 8 button head screw", lugs + len(LAP_SCREWS) + nh,
         "top: %d into the walls' nut lugs, %d through the half laps, %d into the standoffs" % (lugs, len(LAP_SCREWS), nh)),
        ("M3 x 12 button head screw", nh, "up through the floor bosses and the board into the standoffs"),
        ("M3 hex nut, ISO 4032", seats + 4 * len(STRAPS) + lugs + len(LAP_SCREWS), "one per screw above, except the standoffs'"),
        ("M3 female-female hex standoff, 27 mm", nh, "board to the top"),
    ]


# ---------------------------------------------------------------- drawing
def draw_pieces(path, parts, cuts):
    W, D = g.W, g.D
    fig = plt.figure(figsize=(17, 12.5))
    gs = fig.add_gridspec(4, 2, height_ratios=[4.2, 1, 1, 0.05], hspace=0.28, wspace=0.08)
    ax = fig.add_subplot(gs[0, 0])
    bx = fig.add_subplot(gs[0, 1])
    seam, strapc, scr, lugc = "#c0392b", "#f2c14e", "#222222", "#1f6fa8"
    # floor and walls from above
    ax.add_patch(Rectangle((0, 0), W, D, fc="#e4e6ea", ec="#333", lw=1))
    ax.plot([FLOOR_X, FLOOR_X], [0, D], color=seam, lw=1.6)
    ax.plot([0, W], [FLOOR_Y, FLOOR_Y], color=seam, lw=1.6)
    for x, y, axis in STRAPS:
        w, l = (STRAP_W, STRAP_L) if axis == "y" else (STRAP_L, STRAP_W)
        ax.add_patch(Rectangle((x - w / 2, y - l / 2), w, l, fc=strapc, ec="#8a6d1f", lw=0.8, alpha=0.85))
        for sx, sy in strap_screws(x, y, axis):
            ax.add_patch(Circle((sx, sy), 1.8, fc=scr, ec="none"))
    for hx, hy in g.board_hole_xys(parts):
        ax.add_patch(Circle((hx, hy), BOSS_D / 2, fc="#d4c08a", ec="#8a7a4a"))
    for side in SIDES:
        (xa, ya), (xb, yb) = pt(side, *([wall_span(side)[0], -T])), pt(side, wall_span(side)[1], 0)
        ax.add_patch(Rectangle((min(xa, xb), min(ya, yb)), abs(xb - xa), abs(yb - ya), fc="#4a4f56", ec="none"))
        sx, sy = pt(side, WALL_SEAM[side], -T - 5)
        ex, ey = pt(side, WALL_SEAM[side], 6)
        ax.plot([sx, ex], [sy, ey], color=lugc, lw=2.5)
        for u in SEATS[side]:
            ax.add_patch(Circle(seat_xy(side, u), 2.2, fc=scr, ec="none"))
    for y in VENT_ROWS:
        for x0, x1 in VENT_SPANS:
            ax.add_patch(Rectangle((x0, y - 2.5), x1 - x0, 5, fc="white", ec="#777", lw=0.5))
    for (cx_, cy_), n in zip(((40, 100), (255, 60), (70, 170), (235, 185)),
                             NAMES4):
        ax.text(cx_, cy_, "floor\n" + n.replace("_", " "), ha="center", va="center", fontsize=10)
    ax.set_title("Floor and walls from above.  Red = floor seams, yellow = straps under them (4 screws each),\n"
                 "black dots = screws up into the walls' nut seats, blue ticks = wall seams, tan = board bosses",
                 fontsize=10, loc="left")
    # top
    bx.add_patch(Rectangle((0, 0), W, D, fc="#dfeef8", ec="#333", lw=1))
    bay, cart, slot_x = g.openings(parts)
    bx.add_patch(Rectangle((bay[0], bay[2]), bay[1] - bay[0], D - bay[2], fc="white", ec="#333", lw=0.8))
    bx.add_patch(Rectangle((cart[0], cart[2]), cart[1] - cart[0], cart[3] - cart[2], fc="white", ec="#333", lw=0.8))
    bx.add_patch(Rectangle((TOP_X - LAP, 0), 2 * LAP, D, fc=strapc, ec="none", alpha=0.6))
    bx.add_patch(Rectangle((0, TOP_Y - LAP), W, 2 * LAP, fc=strapc, ec="none", alpha=0.6))
    bx.plot([TOP_X, TOP_X], [0, D], color=seam, lw=1.2)
    bx.plot([0, W], [TOP_Y, TOP_Y], color=seam, lw=1.2)
    for x, y in LAP_SCREWS:
        bx.add_patch(Circle((x, y), 2.2, fc=scr, ec="none"))
    for side in SIDES:
        for u in LUGS[side]:
            bx.add_patch(Circle(lug_xy(side, u), 2.2, fc=lugc, ec="none"))
    for hx, hy in g.board_hole_xys(parts):
        bx.add_patch(Circle((hx, hy), 2.6, fc="#b8860b", ec="none"))
    for (cx_, cy_), n in zip(((70, 45), (230, 45), (20, 175), (235, 185)), NAMES4):
        bx.text(cx_, cy_, "top\n" + n.replace("_", " ") + ("\n(printed top face down)" if "top_" + n in TOP_FLIPPED else ""),
                ha="center", va="center", fontsize=10)
    bx.set_title("Top from above.  Yellow = half laps (one piece's upper half on its neighbour's lower half),\n"
                 "black = lap screws, blue = screws into the walls' nut lugs, gold = screws into the standoffs",
                 fontsize=10, loc="left")
    for a in (ax, bx):
        a.set_xlim(-12, W + 12)
        a.set_ylim(-12, D + 12)
        a.set_aspect("equal")
        a.set_xticks([0, FLOOR_X, W])
        a.set_yticks([0, FLOOR_Y if a is ax else TOP_Y, D])
        a.text(W / 2, -9, "FRONT", ha="center", fontsize=9, weight="bold")
    # walls, seen from inside
    zb, zt = g.Z_FLOOR + T, g.Z_TOP
    zl = zt - LUG_WEB - LUG_SLOT - LUG_BASE
    for k, side in enumerate(SIDES):
        wx = fig.add_subplot(gs[1 + k // 2, k % 2])
        u0, u1 = wall_span(side)
        wx.add_patch(Rectangle((u0, zb), u1 - u0, zt - zb, fc="#c9ccd1", ec="#333", lw=1))
        for ref, sd, u, z, prof, note in cuts:
            if sd == side:
                for patch in g.cut_outline(prof, u, z, False):
                    patch.set_facecolor("white")
                    patch.set_edgecolor("#222")
                    wx.add_patch(patch)
                wx.text(u, zt + 2, ref, ha="center", fontsize=8)
        if side in ("left", "right"):
            vw, vh, vz, _ = g.SIDE_VENT
            for u in g.side_vents(cuts, side):
                wx.add_patch(Rectangle((u - vw / 2, vz - vh / 2), vw, vh, fc="white", ec="#222", lw=0.6))
        wx.add_patch(Rectangle((FL_END, zb), wall_len(side) - 2 * FL_END, FL_T, fc="#8d939b", ec="none"))
        for u in SEATS[side]:
            wx.add_patch(Rectangle((u - NUT_AF / 2 - SEAT_RIB, zb), NUT_AF + 2 * SEAT_RIB, FL_T + NUT_H, fc=scr, ec="none"))
        for u in LUGS[side]:
            wx.add_patch(Rectangle((u - LUG_W / 2, zl), LUG_W, zt - zl, fc=lugc, ec="none"))
        wx.plot([WALL_SEAM[side]] * 2, [zb - 3, zt + 3], color=seam, lw=1.6)
        wx.set_xlim(-5, 300)
        wx.set_ylim(zb - 5, zt + 8)
        wx.set_aspect("equal")
        wx.set_yticks([])
        wx.set_xticks([0, WALL_SEAM[side], wall_len(side)])
        wx.set_title("%s wall (mm along %s)" % (side.capitalize(), "x" if side in ("front", "back") else "y"),
                     fontsize=10, loc="left")
    fig.suptitle("3D-printed case: every piece prints flat without supports and fits a 220 x 220 mm bed; "
                 "M3 screws and nuts only, no glue\nWalls: black = nut seats on the bottom flange (floor screws), "
                 "blue = nut lugs under the top (top screws), red = seam", fontsize=12, y=0.975)
    fig.savefig(path, dpi=100, bbox_inches="tight")
    plt.close(fig)


# ---------------------------------------------------------------- build
def build(pcb, out, drawings, mesh=None, fit=True):
    parts = g.read_board(pcb)
    cuts = g.wall_cutouts(parts)
    pads = read_pads(pcb, parts)
    model_solids = {}
    for ref, p in parts.items():
        m = g.model_solid(p)
        if m is not None:
            model_solids[ref] = m
            MODEL_BOXES[ref] = m.BoundingBox()

    placed = {}                                   # every printed part where it sits in the case
    placed.update(floor_pieces(floor(parts)))
    for i, st in enumerate(STRAPS):
        placed["floor_strap_%d" % (i + 1)] = strap_placed(*st)
    for side in SIDES:
        placed.update(dict(wall_pieces(side, wall(side, parts, cuts, pads, MODEL_BOXES))))
    placed.update(top_pieces(top(parts)))
    covers = g.slot_covers(parts)
    for i, c in enumerate(covers):
        placed["slot_cover_%d" % (i + 1)] = c
    placed["cart_cover"] = g.cart_cover(parts)

    problems = fit_check(parts, pads, placed, model_solids) if fit else None

    # what gets printed, in print orientation
    printed = {}
    for name, sol in placed.items():
        if name.startswith("floor_strap"):
            continue
        if name.startswith("slot_cover"):
            if name == "slot_cover_1":
                printed["slot_cover"] = to_bed(g.print_pose(sol))
            continue
        printed[name] = to_bed(g.print_pose(sol)) if name == "cart_cover" else print_pose(name, sol)
    printed["floor_strap"] = strap()

    os.makedirs(out, exist_ok=True)
    for f in glob.glob(os.path.join(out, "*.stl")):
        os.remove(f)                              # the glued, keyed pieces of the first version
    rows = []
    for name, sol in printed.items():
        b = sol.val().BoundingBox()
        if max(b.xlen, b.ylen) > BED - BED_MARGIN:
            raise SystemExit("%s does not fit the bed: %.1f x %.1f" % (name, b.xlen, b.ylen))
        cq.exporters.export(sol, os.path.join(out, name + ".stl"), tolerance=0.02, angularTolerance=0.1)
        qty = {"slot_cover": len(covers), "floor_strap": len(STRAPS)}.get(name, 1)
        rows.append(dict(name=name, qty=qty, size=[round(b.xlen, 1), round(b.ylen, 1), round(b.zlen, 1)],
                         orientation=orientation(name), volume_cm3=round(sol.val().Volume() / 1000, 1)))
    info = dict(pieces=rows, hardware=hardware(parts), floor_seams=[FLOOR_X, FLOOR_Y], top_seams=[TOP_X, TOP_Y],
                wall_seams=WALL_SEAM, seats=SEATS, lugs=LUGS, straps=STRAPS, lap_screws=LAP_SCREWS)
    with open(os.path.join(out, "print_layout.json"), "w") as f:
        json.dump(info, f, indent=1)
    if drawings:
        draw_pieces(os.path.join(drawings, "case_print_pieces.png"), parts, cuts)
    if mesh:
        os.makedirs(mesh, exist_ok=True)
        for name, sol in placed.items():
            cq.exporters.export(sol, os.path.join(mesh, "print_" + name + ".stl"), tolerance=0.05, angularTolerance=0.2)
    return info, problems


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--pcb", default=os.path.join(g.REPO, "kicad", "placard.kicad_pcb"))
    ap.add_argument("--out", default=os.path.join(g.REPO, "case", "print"))
    ap.add_argument("--drawings", default=os.path.join(g.REPO, "docs", "case"))
    ap.add_argument("--mesh", help="also write every part where it sits in the case (for renders)")
    ap.add_argument("--no-fit", action="store_true", help="skip the fit check")
    a = ap.parse_args()
    info, problems = build(a.pcb, a.out, a.drawings, a.mesh, not a.no_fit)
    for r in info["pieces"]:
        print("%-18s x%d  %6.1f x %6.1f x %5.1f mm  %5.1f cm3  %s" % (r["name"], r["qty"], *r["size"], r["volume_cm3"],
                                                                 r["orientation"]))
    for name, n, note in info["hardware"]:
        print("%3d  %-38s %s" % (n, name, note))
    if problems is not None:
        print("fit check: %s" % ("OK, nothing cuts into anything" if not problems else "%d problems" % len(problems)))
        for p in problems:
            print("  " + p)
        if problems:
            raise SystemExit(1)

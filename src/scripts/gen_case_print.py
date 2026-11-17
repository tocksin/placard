#!/usr/bin/env python3
"""
gen_case_print.py - the 3D-printed PLACARD case for a 220 x 220 mm bed
(Creality Ender 3), printed without supports and held together with M3 screws
and nuts only (no glue, no heat-set inserts, no threads cut in plastic).

It has the same outside size, connector cut-outs, top openings and covers as
the aluminium case (gen_case.py), but every part is designed to print flat:

- floor: four flat pieces with the board's standoff bosses, locked together
  by dovetail tabs along the seams (they drop into each other from above);
- walls: four flat panels (front, back, left, right), each in two pieces,
  printed outside face down.  Each has a flange along the bottom with open
  nut seats (screwed up through the floor) and a nut lug or two along the top
  (the top's screws); tabs on the side walls' ends key into the front and
  back walls at the corners;
- top: four pieces locked together by dovetail tabs, like the floor;
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

Date: 2026-11-17
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
VENT_SPANS = [(72.5, 146.0), (174.0, 222.5)]               # two groups, a land along the seam for its dovetails

# dovetail seams: flared tabs on one piece drop into sockets in its neighbour, so the pieces
# cannot pull apart in the plane.  The flare is in plan, so a tab prints flat with no overhang.
DOVE = {"floor": (8.0, 12.0, 6.0), "top": (8.0, 13.0, 7.0)}    # tab neck width, tip width, length
DOVE_CLEAR = 0.2                  # gap all round a tab (case/print/dovetail_test.stl tries it on your printer)
# where the tabs are: along the x seam (y of each; they belong to the left pieces and reach right)
# and along the y seam (x of each).  The floor's y seam tabs belong to the back pieces and reach
# forward, away from the cartridge cover's parking slots; the top's belong to the front pieces.
FLOOR_TABS_X = [15.0, 50.0, 85.0, 135.0, 170.0, 205.0]
FLOOR_TABS_Y, FLOOR_Y_DIR = [30.0, 75.0, 120.0, 200.0, 240.0, 272.0], -1
TOP_TABS_X = [20.0, 60.0, 125.0, 165.0, 205.0]
TOP_TABS_Y, TOP_Y_DIR = [25.0, 75.0, 125.0, 195.0, 240.0, 270.0], 1

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
SEATS = {"front": [18.0, 118.0, 133.0, 277.0],       # two per wall piece, one near each end
         "back": [50.0, 184.0, 196.0, 237.0],
         "left": [22.0, 75.0, 145.0, 162.0],
         "right": [22.0, 70.0, 96.0, 198.0]}
# and of the top's screws (nut lugs under the top): one per wall piece, two on the long back left piece
LUGS = {"front": [70.0, 205.0],
        "back": [28.0, 176.0, 245.0],
        "left": [90.0, 175.0],
        "right": [45.0, 160.0]}
LUG_W, LUG_D = 11.0, 10.0          # lug along the wall, and inward from the inside face
LUG_V = 6.0                        # its screw from the inside face (8 mm from the outside)
LUG_WEB, LUG_SLOT, LUG_BASE = 1.6, NUT_H + 0.3, 1.8    # top web (under the top), nut slot, under the nut
CORNER_CHAMFER = 1.5               # the case's outside corners
CORNER_TAB_Z = (8.0, 18.0)         # a tab on each end of the side walls keys into a notch in the front or back wall
CORNER_TAB_CLEAR = 0.2

# ---------------------------------------------------------------- top
TOP_X, TOP_Y = 160.0, 100.0        # seams, between the expansion bay and the cartridge cover's lap

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


def dove_poly(kind, at, pos, axis, sign, grow=0.0):
    """Outline of a dovetail tab on the seam at `at`: axis "x" = the seam x = at, the
    tab at y = pos reaching sign * x; axis "y" likewise.  grow widens it into its socket."""
    n, t, L = DOVE[kind]
    n, t, L = n + 2 * grow, t + 2 * grow, L + grow
    loc = [(-1.0, -n / 2), (0.0, -n / 2), (L, -t / 2), (L, t / 2), (0.0, n / 2), (-1.0, n / 2)]   # (along the tab, across)
    if axis == "x":
        return [(at + sign * a, pos + b) for a, b in loc]
    return [(pos + b, at + sign * a) for a, b in loc]


def dovetail_seams(kind, full, pieces, prefix, X, Y, tabs_x, tabs_y, y_dir):
    """Adds the dovetail tabs to the four pieces of the floor or top (cut square at
    the seams x = X, y = Y) and cuts their sockets.  Tab material is taken from the
    uncut part, so holes that cross a tab stay."""
    joints = [("x", X, y, 1, "front_left" if y < Y else "back_left", "front_right" if y < Y else "back_right")
              for y in tabs_x]
    for x in tabs_y:
        lr = "left" if x < X else "right"
        own, oth = ("front_", "back_") if y_dir > 0 else ("back_", "front_")
        joints.append(("y", Y, x, y_dir, own + lr, oth + lr))
    for axis, at, pos, sign, own, oth in joints:
        prism = lambda grow: (cq.Workplane("XY").polyline(dove_poly(kind, at, pos, axis, sign, grow)).close()
                              .extrude(200).translate((0, 0, -100)))
        pieces[prefix + own] = pieces[prefix + own].union(full.intersect(prism(0.0)))
        pieces[prefix + oth] = pieces[prefix + oth].cut(prism(DOVE_CLEAR))
    return pieces


def dovetail_test():
    """A small pair of plates with one floor-size dovetail, to try the fit before
    printing the big pieces."""
    full = box(0, 30, 0, 22, 0, T)
    pieces = {"a": full.intersect(box(-1, 15 - SEAM_GAP, -1, 30, -1, 10)),
              "b": full.intersect(box(15 + SEAM_GAP, 40, -1, 30, -1, 10))}
    tab = lambda grow: (cq.Workplane("XY").polyline(dove_poly("floor", 15.0, 11.0, "x", 1, grow)).close()
                        .extrude(20).translate((0, 0, -5)))
    a = pieces["a"].union(full.intersect(tab(0.0)))
    b = pieces["b"].cut(tab(DOVE_CLEAR)).translate((12, 0, 0))
    return cq.Workplane().add(cq.Compound.makeCompound(a.vals() + b.vals()))


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
    return s


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
    # corners: a tab on each end of a side wall reaches through a notch in the end of the
    # front or back wall, so the two walls line up and the side wall's end can't lean in
    z0, z1 = CORNER_TAB_Z
    k = CORNER_TAB_CLEAR
    if side in ("left", "right"):
        xa, xb = (0.0, T) if side == "left" else (g.W - T, g.W)
        s = s.union(box(xa, xb, 0.0, T + SEAM_GAP + 0.5, z0, z1)).union(box(xa, xb, g.D - T - SEAM_GAP - 0.5, g.D, z0, z1))
    else:
        ya, yb = (-1.0, T + 1.0) if side == "front" else (g.D - T - 1.0, g.D + 1.0)
        s = s.cut(box(-1.0, T + k, ya, yb, z0 - k, z1 + k)).cut(box(g.W - T - k, g.W + 1.0, ya, yb, z0 - k, z1 + k))
    c = CORNER_CHAMFER
    for yo, yi in ((0.0, c), (g.D, g.D - c)):
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
    return s


def quarters(solid, prefix, X, Y):
    c = SEAM_GAP
    boxes = [(-50, X - c, -50, Y - c), (X + c, 400, -50, Y - c), (-50, X - c, Y + c, 400), (X + c, 400, Y + c, 400)]
    return {prefix + n: solid.intersect(box(*b, -100, 100)) for n, b in zip(NAMES4, boxes)}


def top_pieces(solid):
    """The top in four pieces, locked together by dovetail tabs along the seams."""
    return dovetail_seams("top", solid, quarters(solid, "top_", TOP_X, TOP_Y), "top_", TOP_X, TOP_Y,
                          TOP_TABS_X, TOP_TABS_Y, TOP_Y_DIR)


def floor_pieces(solid):
    return dovetail_seams("floor", solid, quarters(solid, "floor_", FLOOR_X, FLOOR_Y), "floor_", FLOOR_X, FLOOR_Y,
                          FLOOR_TABS_X, FLOOR_TABS_Y, FLOOR_Y_DIR)


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
    return to_bed(solid)


ORIENT = {"floor": "underside down, bosses up", "wall": "outside face down, flange and lugs up",
          "top": "underside down", "dovetail": "flat (optional fit test)",
          "slot_cover": "cap face down", "cart_cover": "cap face down"}


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
    return bad


MODEL_BOXES = {}


# ---------------------------------------------------------------- hardware
def hardware(parts):
    seats = sum(len(v) for v in SEATS.values())
    flush = sum(flush_seat(parts, sd, u) for sd in SIDES for u in SEATS[sd])
    lugs = sum(len(v) for v in LUGS.values())
    nh = len(g.board_holes(parts))
    return [
        ("M3 x 6 button head screw", seats - flush, "up through the floor into the walls' nut seats"),
        ("M3 x 6 countersunk screw", flush, "the floor screw under the parked slot covers (back wall), flush"),
        ("M3 x 8 button head screw", lugs + nh, "top: %d into the walls' nut lugs, %d into the standoffs" % (lugs, nh)),
        ("M3 x 12 button head screw", nh, "up through the floor bosses and the board into the standoffs"),
        ("M3 hex nut, ISO 4032", seats + lugs, "one in each nut seat and nut lug"),
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
    for y in FLOOR_TABS_X:
        ax.add_patch(Polygon(dove_poly("floor", FLOOR_X, y, "x", 1), fc=strapc, ec="#8a6d1f", lw=0.8))
    for x in FLOOR_TABS_Y:
        ax.add_patch(Polygon(dove_poly("floor", FLOOR_Y, x, "y", FLOOR_Y_DIR), fc=strapc, ec="#8a6d1f", lw=0.8))
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
    ax.set_title("Floor and walls from above.  Red = floor seams, yellow = dovetail tabs across them,\n"
                 "black dots = screws up into the walls' nut seats, blue ticks = wall seams, tan = board bosses",
                 fontsize=10, loc="left")
    # top
    bx.add_patch(Rectangle((0, 0), W, D, fc="#dfeef8", ec="#333", lw=1))
    bay, cart, slot_x = g.openings(parts)
    bx.add_patch(Rectangle((bay[0], bay[2]), bay[1] - bay[0], D - bay[2], fc="white", ec="#333", lw=0.8))
    bx.add_patch(Rectangle((cart[0], cart[2]), cart[1] - cart[0], cart[3] - cart[2], fc="white", ec="#333", lw=0.8))
    bx.plot([TOP_X, TOP_X], [0, D], color=seam, lw=1.2)
    bx.plot([0, W], [TOP_Y, TOP_Y], color=seam, lw=1.2)
    for y in TOP_TABS_X:
        bx.add_patch(Polygon(dove_poly("top", TOP_X, y, "x", 1), fc=strapc, ec="#8a6d1f", lw=0.8))
    for x in TOP_TABS_Y:
        bx.add_patch(Polygon(dove_poly("top", TOP_Y, x, "y", TOP_Y_DIR), fc=strapc, ec="#8a6d1f", lw=0.8))
    for side in SIDES:
        for u in LUGS[side]:
            bx.add_patch(Circle(lug_xy(side, u), 2.2, fc=lugc, ec="none"))
    for hx, hy in g.board_hole_xys(parts):
        bx.add_patch(Circle((hx, hy), 2.6, fc="#b8860b", ec="none"))
    for (cx_, cy_), n in zip(((70, 45), (230, 45), (20, 175), (235, 185)), NAMES4):
        bx.text(cx_, cy_, "top\n" + n.replace("_", " "), ha="center", va="center", fontsize=10)
    bx.set_title("Top from above.  Red = seams, yellow = dovetail tabs across them,\n"
                 "blue = screws into the walls' nut lugs, gold = screws into the standoffs",
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
        for ue in (u0, u1):       # corner tabs (side walls) and their notches (front and back walls)
            wx.add_patch(Rectangle((ue - 2.5, CORNER_TAB_Z[0]), 5, CORNER_TAB_Z[1] - CORNER_TAB_Z[0], fc=strapc,
                                   ec="#8a6d1f", lw=0.6))
        wx.set_xlim(-5, 300)
        wx.set_ylim(zb - 5, zt + 8)
        wx.set_aspect("equal")
        wx.set_yticks([])
        wx.set_xticks([0, WALL_SEAM[side], wall_len(side)])
        wx.set_title("%s wall (mm along %s)" % (side.capitalize(), "x" if side in ("front", "back") else "y"),
                     fontsize=10, loc="left")
    fig.suptitle("3D-printed case: every piece prints flat without supports and fits a 220 x 220 mm bed; "
                 "M3 screws and nuts only, no glue\nWalls: black = nut seats on the bottom flange (floor screws), "
                 "blue = nut lugs under the top (top screws), red = seam, yellow = corner tabs and notches", fontsize=12, y=0.975)
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
        if name.startswith("slot_cover"):
            if name == "slot_cover_1":
                printed["slot_cover"] = to_bed(g.print_pose(sol))
            continue
        printed[name] = to_bed(g.print_pose(sol)) if name == "cart_cover" else print_pose(name, sol)
    printed["dovetail_test"] = dovetail_test()

    os.makedirs(out, exist_ok=True)
    for f in glob.glob(os.path.join(out, "*.stl")):
        os.remove(f)                              # the glued, keyed pieces of the first version
    rows = []
    for name, sol in printed.items():
        b = sol.val().BoundingBox()
        if max(b.xlen, b.ylen) > BED - BED_MARGIN:
            raise SystemExit("%s does not fit the bed: %.1f x %.1f" % (name, b.xlen, b.ylen))
        cq.exporters.export(sol, os.path.join(out, name + ".stl"), tolerance=0.02, angularTolerance=0.1)
        qty = {"slot_cover": len(covers)}.get(name, 1)
        rows.append(dict(name=name, qty=qty, size=[round(b.xlen, 1), round(b.ylen, 1), round(b.zlen, 1)],
                         orientation=orientation(name), volume_cm3=round(sol.val().Volume() / 1000, 1)))
    info = dict(pieces=rows, hardware=hardware(parts), floor_seams=[FLOOR_X, FLOOR_Y], top_seams=[TOP_X, TOP_Y],
                wall_seams=WALL_SEAM, seats=SEATS, lugs=LUGS,
                floor_tabs=dict(x_seam=FLOOR_TABS_X, y_seam=FLOOR_TABS_Y), top_tabs=dict(x_seam=TOP_TABS_X, y_seam=TOP_TABS_Y),
                dovetail=dict(DOVE, clearance=DOVE_CLEAR))
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

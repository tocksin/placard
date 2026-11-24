#!/usr/bin/env python3
"""
gen_case_print.py - the 3D-printed PLACARD case for a 256 x 256 mm bed
(Bambu Lab A1), printed without supports.  The walls are held by printed
joints, so the only fasteners are the 16 M3 screws of the board's standoffs
(no nuts, no glue, no heat-set inserts, no threads cut in plastic).

It has the same outside size, connector cut-outs, top openings and covers as
the aluminium case (gen_case.py), but every part is designed to print flat:

- floor: two flat pieces with the board's standoff bosses, locked together
  by dovetail tabs along the seam (they drop into each other from above).
  Near each wall it has spring fingers with a catch, and stop blocks;
- walls: four flat panels (front, back, left, right), each one piece, printed
  outside face down (the front and back walls lie on the bed's diagonal).
  Each has a flange along the bottom with a window for every floor catch: the
  panel slides in from outside over its connectors until the catches click
  into the windows.  Sockets in lugs along its top edge take the top's pegs;
  tabs on the side walls' ends key into the front and back walls at the corners;
- top: two pieces locked together by dovetail tabs, like the floor, printed
  top face down so the pegs under it print upward.  The pegs drop into the
  walls' sockets, and the top's eight screws into the standoffs clamp the
  walls between the top and the floor;
- covers: the printed snap covers of gen_case.py, cap face down.

    pip install cadquery
    python3 gen_case_print.py [--pcb path/to/placard.kicad_pcb] [--out case/print]
                              [--mesh dir] [--no-fit]

Writes STL files, already turned into print orientation, to case/print/ and
docs/case/case_print_pieces.png, and runs the fit check (no printed part
may cut into the board, a part on it, a standoff or another printed part,
every catch has its window in a whole stretch of flange, and every spring
finger is cut from a plain stretch of floor that no parked cover lies on).
Then run case_print_check.py on the STL files.  See docs/case/CASE.md,
"3D-printed version".  The board file is only read.

Coordinates (mm) are gen_case.py's: x from the case's left outside face, y
from the front outside face toward the back, z up from the board's top face.

Date: 2026-11-24
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

BED = 256.0            # Bambu Lab A1 printable area, square
BED_MARGIN = 5.0       # each piece's footprint must fit BED - BED_MARGIN
SEAM_GAP = 0.1         # each piece stops this far short of its seam

T = g.T                # walls and floor, 2 mm (5 perimeters)
M3 = 3.4               # clearance hole
ROOF = math.radians(40.0)   # a sideways opening's roof: two flats this far from vertical, meeting in a peak

# side wall vent slots end below the top's nut lugs
g.SIDE_VENT = (5.0, 14.0, 11.0, 20.0)
g.SIDE_VENT_SKIP = {}

# ---------------------------------------------------------------- floor
FLOOR_X = 160.0                   # the seam: between the parked slot covers and the parked cartridge cover
BOSS_D = 8.0                      # boss under each board hole, floor to the board's underside
VENT_ROWS = [30.0 + 12.0 * i for i in range(6)]            # floor vent slots, y centres
VENT_SPANS = [(72.5, 146.0), (174.0, 222.5)]               # two groups, a land along the seam for its dovetails

# dovetail seams: flared tabs on one piece drop into sockets in its neighbour, so the pieces
# cannot pull apart in the plane.  The flare is in plan, so a tab prints flat with no overhang.
DOVE = {"floor": (8.0, 12.0, 6.0), "top": (8.0, 13.0, 7.0)}    # tab neck width, tip width, length
DOVE_CLEAR = 0.2                  # gap all round a tab (case/print/dovetail_test.stl tries it on your printer)
# where the tabs are along the seam (y of each; they belong to the left piece and reach right)
FLOOR_TABS = [15.0, 50.0, 85.0, 135.0, 170.0, 205.0]
TOP_TABS = [20.0, 60.0, 125.0, 165.0, 205.0]

# ---------------------------------------------------------------- walls
SIDES = ("front", "back", "left", "right")
FL_D = 9.0             # bottom flange, inside face to free edge (it lies on the floor, under the board's edge)
FL_T = 2.0
FL_END = 12.3          # the flanges stop short of the corner bosses
BOSS_NOTCH = BOSS_D / 2 + 0.6     # flange notch half width round a boss
PIN_NOTCH = 2.0        # flange notch this far round the pads of a part whose pins reach down to the flange

# Floor catches.  A spring finger cut in the floor carries a catch that clicks up into a window in
# the wall's flange once the wall has slid in; a stop block behind the flange's free edge stops the
# wall there.  Window and catch are pointed toward the inside of the case: in the wall's print
# orientation that point is the window's peaked roof, so nothing bridges, and the wall pulls
# against two upright faces of the catch, not against a ramp.  Pressing the finger down from under
# the case lets the wall slide out again.
# (u of the catch along the wall, direction +1/-1 in which the finger runs from the catch to its root)
SNAPS = {"front": [(18.0, 1), (118.0, -1), (196.0, 1), (277.0, -1)],
         "back": [(18.0, 1), (92.0, 1), (178.0, 1), (238.0, 1), (277.0, -1)],
         "left": [(22.0, 1), (90.0, -1), (126.0, 1), (198.0, -1)],
         "right": [(22.0, 1), (90.0, -1), (126.0, 1), (198.0, -1)]}
# The back wall's long stretch behind the expansion slots needs a catch too, and the parked slot
# covers lie under the floor there.  A parked cover only stops that finger from moving, which
# holds the catch shut; the back wall goes in, and comes out, with the covers off the floor.
UNDER_COVER = {("back", 92.0)}
WIN_HW, WIN_V0, WIN_V1 = 2.5, 2.6, 4.0     # window: half width, and v (from the wall's inside face) of its straight part
SNAP_CLEAR = 0.2                  # catch to window on the faces that hold, peg to socket all round
CATCH_H = 1.2                     # catch height above the floor (the flange is 2 mm thick)
CATCH_RAMP = 1.6                  # the catch's ramp, on the side the flange arrives from
FING_V = (2.4, 7.0)               # spring finger across (v), cut free by 0.8 mm slits on three sides
FING_L, FING_TIP, SLIT = 19.0, 3.4, 0.8    # catch to root, catch to free end, slit width
STOP_V, STOP_H = 2.0, 2.0         # stop block: across and tall (its top is 4 mm under the board)
STOP_U = (5.0, 15.0)              # along the wall from the catch, toward the finger's root

# Top pegs.  A pointed peg under the top drops into a pointed socket in a lug on the wall's inside
# face, so the wall's top edge can move neither in nor out.  u of each along the wall.
LUGS = {"front": [70.0, 205.0],
        "back": [28.0, 176.0, 245.0],
        "left": [90.0, 175.0],
        "right": [45.0, 160.0]}
LUG_W, LUG_D, LUG_H = 11.0, 10.0, 6.0     # lug along the wall, inward from the inside face, and down from the top
SOCK_HW, SOCK_V0, SOCK_V1 = 3.2, 2.0, 3.6  # socket: half width, and v of its straight part
PEG_L = 4.0                        # peg length under the top (the socket is 0.5 mm deeper)
CORNER_CHAMFER = 1.5               # the case's outside corners
CORNER_TAB_Z = (8.0, 18.0)         # a tab on each end of the side walls keys into a notch in the front or back wall
CORNER_TAB_CLEAR = 0.2

# ---------------------------------------------------------------- top
TOP_X = 160.0                      # the seam, between the expansion bay and the cartridge cover

NAMES2 = ("left", "right")
TEST_WALL, TEST_U = "right", (13.0, 58.0)     # snap_test_*: this stretch of wall, floor and top, to try the joints


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


def gable(hw, v0, v1, grow=0.0, blunt=0.0):
    """Outline (a along the wall, b inward) of an opening with a peaked roof toward the
    inside of the case: straight from v0 to v1, half width hw, then two flats at ROOF
    from the b axis.  grow < 0 shrinks it (a catch or peg inside its opening); blunt
    cuts the point off this far below the peak."""
    t = math.tan(ROOF)
    peak = v1 + hw / t + grow / math.sin(ROOF)
    hw, v0 = hw + grow, v0 - grow
    eave = peak - hw / t
    if blunt:
        return [(-hw, v0), (hw, v0), (hw, eave), (blunt * t, peak - blunt), (-blunt * t, peak - blunt), (-hw, eave)]
    return [(-hw, v0), (hw, v0), (hw, eave), (0.0, peak), (-hw, eave)]


def prism(side, u, outline, z0, z1):
    """An outline in wall coordinates (a from u, b inward) extruded from z0 to z1."""
    pts = [pt(side, u + a, b) for a, b in outline]
    return cq.Workplane("XY").polyline(pts).close().extrude(z1 - z0).translate((0, 0, z0))


def hexagon(x, y, af, z0, h):
    return cq.Workplane("XY").center(x, y).polygon(6, af / math.cos(math.pi / 6)).extrude(h).translate((0, 0, z0))


def vol(w):
    return sum(x.Volume() for x in w.vals()) if w.vals() else 0.0


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


def finger_boxes(side, u, d):
    """A spring finger's slits and the stretch of floor it is cut from, as
    (u0, u1, v0, v1) in wall coordinates: (three slits, the whole patch)."""
    tip, root = u - d * FING_TIP, u + d * FING_L
    a, b = sorted((tip - d * SLIT, root))
    v0, v1 = FING_V
    slits = [(a, b, v0 - SLIT, v0), (a, b, v1, v1 + SLIT), tuple(sorted((tip - d * SLIT, tip))) + (v0 - SLIT, v1 + SLIT)]
    return slits, (a, b, v0 - SLIT, v1 + SLIT)


def stop_box(side, u, d):
    a, b = sorted((u + d * STOP_U[0], u + d * STOP_U[1]))
    return a, b, FL_D + SNAP_CLEAR, FL_D + SNAP_CLEAR + STOP_V


def place(side, u, local):
    """A solid drawn in a wall's own frame (x along the wall from u, y inward from the
    inside face, z = case z) -> where it sits.  Only for shapes that are the same
    left and right, since the back and left walls run the other way."""
    x, y = pt(side, u, 0)
    return local.rotate((0, 0, 0), (0, 0, 1), {"front": 0, "back": 180, "left": -90, "right": 90}[side]).translate((x, y, 0))


def catch(side, u):
    """The catch on a spring finger: pointed like its window, upright on the faces
    the wall pulls against, with a ramp on the side the flange slides in from."""
    zb = g.Z_FLOOR + T
    b0 = WIN_V0 + SNAP_CLEAR
    c = cq.Workplane("XY").polyline(gable(WIN_HW, WIN_V0, WIN_V1, -SNAP_CLEAR, 0.5)).close().extrude(CATCH_H)
    ramp = (cq.Workplane("YZ").polyline([(b0, -0.01), (b0 + CATCH_RAMP, CATCH_H), (20, CATCH_H), (20, -0.01)]).close()
            .extrude(10, both=True))
    return place(side, u, c.intersect(ramp).translate((0, 0, zb)))


def peg(side, u):
    """A peg under the top, a little smaller than its socket, with a chamfered end."""
    c = (cq.Workplane("XY").polyline(gable(SOCK_HW, SOCK_V0, SOCK_V1, -SNAP_CLEAR, 0.5)).close().extrude(PEG_L)
         .faces("<Z").chamfer(0.5))
    return place(side, u, c.translate((0, 0, g.Z_TOP - PEG_L)))


def dove_poly(kind, at, pos, axis, sign, grow=0.0):
    """Outline of a dovetail tab on the seam at `at`: axis "x" = the seam x = at, the
    tab at y = pos reaching sign * x; axis "y" likewise.  grow widens it into its socket."""
    n, t, L = DOVE[kind]
    n, t, L = n + 2 * grow, t + 2 * grow, L + grow
    loc = [(-1.0, -n / 2), (0.0, -n / 2), (L, -t / 2), (L, t / 2), (0.0, n / 2), (-1.0, n / 2)]   # (along the tab, across)
    if axis == "x":
        return [(at + sign * a, pos + b) for a, b in loc]
    return [(pos + b, at + sign * a) for a, b in loc]


def halves(kind, full, prefix, X, tabs):
    """The floor or top cut in two at the seam x = X, with dovetail tabs on the left
    piece and their sockets in the right one.  Tab material is taken from the uncut
    part, so holes that cross a tab stay."""
    c = SEAM_GAP
    left = full.intersect(box(-50, X - c, -50, 400, -100, 100))
    right = full.intersect(box(X + c, 400, -50, 400, -100, 100))
    for y in tabs:
        tab = lambda grow: (cq.Workplane("XY").polyline(dove_poly(kind, X, y, "x", 1, grow)).close()
                            .extrude(200).translate((0, 0, -100)))
        left = left.union(full.intersect(tab(0.0)))
        right = right.cut(tab(DOVE_CLEAR))
    return {prefix + "left": left, prefix + "right": right}


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
    zt = zf + T
    for side in SIDES:
        for u, d in SNAPS[side]:
            slits, patch = finger_boxes(side, u, d)
            for b in slits:
                s = s.cut(wbox(side, *b, zf - 1, zt + 1))
            s = s.union(catch(side, u))
            s = s.union(wbox(side, *stop_box(side, u, d), zt, zt + STOP_H))
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
    """A wall panel in case coordinates."""
    zb = g.Z_FLOOR + T
    u0, u1 = wall_span(side)
    L = wall_len(side)
    s = wbox(side, u0, u1, -T, 0, zb, g.Z_TOP)
    # bottom flange, lying on the floor under the board's edge
    fl = wbox(side, FL_END, L - FL_END, 0, FL_D, zb, zb + FL_T)
    for a, b in flange_notches(side, parts, pads, models):
        fl = fl.cut(wbox(side, a, b, -0.01, FL_D + 1, zb - 1, zb + FL_T + 1))
    s = s.union(fl)
    for u, d in SNAPS[side]:
        # a window in the flange for the floor's catch
        s = s.cut(prism(side, u, gable(WIN_HW, WIN_V0, WIN_V1), zb - 1, zb + FL_T + 1))
    for u in LUGS[side]:
        # a lug under the top with a socket for one of the top's pegs
        s = s.union(wbox(side, u - LUG_W / 2, u + LUG_W / 2, 0, LUG_D, g.Z_TOP - LUG_H, g.Z_TOP))
        s = s.cut(prism(side, u, gable(SOCK_HW, SOCK_V0, SOCK_V1), g.Z_TOP - PEG_L - 0.5, g.Z_TOP + 1))
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


def flange_gaps(side, parts, pads, models):
    """Stretches (u0, u1) along a wall with no flange."""
    L = wall_len(side)
    return [(-1.0, FL_END), (L - FL_END, L + 1.0)] + flange_notches(side, parts, pads, models)


def top(parts):
    s = g.acrylic_top(parts)
    for side in SIDES:
        for u in LUGS[side]:
            s = s.union(peg(side, u))
    return s


def top_pieces(solid):
    """The top in two pieces, locked together by dovetail tabs along the seam."""
    return halves("top", solid, "top_", TOP_X, TOP_TABS)


def floor_pieces(solid):
    return halves("floor", solid, "floor_", FLOOR_X, FLOOR_TABS)


def snap_test(placed):
    """A short stretch of one wall with the floor and top next to it: one catch and
    window, one stop, one peg and socket, to try before the long prints."""
    a, b = TEST_U
    cutter = wbox(TEST_WALL, a, b, -T - 1, 16, -100, 100)
    out = {}
    for name, key in (("wall", "wall_" + TEST_WALL), ("floor", "floor_right"), ("top", "top_right")):
        out["snap_test_" + name] = placed[key].intersect(cutter)
    return out


# ---------------------------------------------------------------- print orientation
def to_bed(solid):
    b = solid.val().BoundingBox()
    return solid.translate((-b.xmin, -b.ymin, -b.zmin))


def print_pose(name, solid):
    """A part turned into the way it prints, flat side on the bed at z = 0."""
    side = name.split("_")[-1] if name.startswith("wall_") else TEST_WALL if name == "snap_test_wall" else None
    if side == "front":
        solid = solid.rotate((0, 0, 0), (1, 0, 0), 90)      # outside face (-y) down
    elif side == "back":
        solid = solid.rotate((0, 0, 0), (1, 0, 0), -90)
    elif side == "left":
        solid = solid.rotate((0, 0, 0), (0, 1, 0), -90)
    elif side == "right":
        solid = solid.rotate((0, 0, 0), (0, 1, 0), 90)
    if name in ("wall_front", "wall_back"):
        solid = solid.rotate((0, 0, 0), (0, 0, 1), 45)      # too long for the bed's side: along its diagonal
    if name.startswith("top_") or name == "snap_test_top":
        solid = solid.rotate((0, 0, 0), (1, 0, 0), 180)     # top face down, pegs up
    return to_bed(solid)


ORIENT = {"floor": "underside down, bosses up", "wall": "outside face down, flange and lugs up",
          "wall_front": "outside face down, flange and lugs up, along the bed's diagonal",
          "wall_back": "outside face down, flange and lugs up, along the bed's diagonal",
          "top": "top face down, pegs up", "dovetail": "flat (optional fit test)",
          "snap_test_wall": "outside face down (fit test)", "snap_test_floor": "underside down (fit test)",
          "snap_test_top": "top face down (fit test)",
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
    # each wall slides in from outside with the board in place: nothing may be in its way
    out = {"front": (0, -1), "back": (0, 1), "left": (-1, 0), "right": (1, 0)}
    floor_all = placed["floor_left"].union(placed["floor_right"])
    for side in SIDES:
        for step in (3.0, 6.0, 10.0):
            w = placed["wall_" + side].translate((out[side][0] * step, out[side][1] * step, 0))
            for hn, h in hard.items():
                v = overlap(w, h)
                if v > 0.05:
                    bad.append("wall_%s, %.0f mm out on its way in, cuts into %s (%.2f mm3)" % (side, step, hn, v))
            v = overlap(w, floor_all)
            if v > 12.0 * len(SNAPS[side]):          # the catches themselves spring down out of the way
                bad.append("wall_%s, %.0f mm out on its way in, cuts into the floor (%.2f mm3)" % (side, step, v))
    return bad


def joint_check(parts, pads, floor_solid):
    """Problems with the catches: [] when every window is in a whole stretch of flange
    and every spring finger is cut from plain floor that no parked cover lies on."""
    bad = []
    plain = g.rounded_plate(0, g.W, 0, g.D, g.Z_FLOOR, T, 3.0)
    for ref in g.board_holes(parts):
        x, y = g.hole_xy(parts, ref)
        plain = plain.cut(g.hole(x, y, BOSS_D + 1.0, g.Z_FLOOR - 1))
    for y in VENT_ROWS:
        for x0, x1 in VENT_SPANS:
            plain = plain.cut(box(x0 - 2.5, x1 + 2.5, y - 2.5, y + 2.5, g.Z_FLOOR - 1, g.Z_FLOOR + T + 1))
    for x0, x1, y0, y1 in g.floor_slots(parts):
        plain = plain.cut(box(x0, x1, y0, y1, g.Z_FLOOR - 1, g.Z_FLOOR + T + 1))
    for x, y in g.feet():
        plain = plain.cut(g.hole(x, y, g.FOOT_D, g.Z_FLOOR - 1))
    for y in FLOOR_TABS:
        plain = plain.cut(box(FLOOR_X - 2, FLOOR_X + DOVE["floor"][2] + 2, y - 8, y + 8, g.Z_FLOOR - 1, g.Z_FLOOR + T + 1))
    plain = plain.cut(box(FLOOR_X - 2, FLOOR_X + 2, -1, g.D + 1, g.Z_FLOOR - 1, g.Z_FLOOR + T + 1))
    for side in SIDES:
        gaps = flange_gaps(side, parts, pads, MODEL_BOXES)
        for u, d in SNAPS[side]:
            for a, b in gaps:
                if u + WIN_HW + 2.0 > a and u - WIN_HW - 2.0 < b:
                    bad.append("%s catch at %.0f: its window is in a gap of the flange (%.1f..%.1f)" % (side, u, a, b))
            slits, patch = finger_boxes(side, u, d)
            sa, sb, _, sv = stop_box(side, u, d)
            for what, bx in (("finger", (patch[0] - 1, patch[1] + 1, patch[2] - 1, patch[3] + 1)),
                             ("stop", (sa, sb, FL_D, sv))):
                b3 = wbox(side, *bx, g.Z_FLOOR, g.Z_FLOOR + T)
                if abs(vol(b3.intersect(plain)) - vol(b3)) > 0.01:
                    bad.append("%s %s at %.0f is not on plain floor (boss, vent, slot, foot or seam)" % (side, what, u))
            (xa, ya), (xb, yb) = pt(side, patch[0], patch[2]), pt(side, patch[1], patch[3])
            for nm, (x0, x1, y0, y1) in g.parked_boxes(parts).items():
                if ((side, u) not in UNDER_COVER and
                        min(xa, xb) < x1 and max(xa, xb) > x0 and min(ya, yb) < y1 and max(ya, yb) > y0):
                    bad.append("%s finger at %.0f is under the parked %s" % (side, u, nm))
    return bad


MODEL_BOXES = {}


# ---------------------------------------------------------------- hardware
def hardware(parts):
    nh = len(g.board_holes(parts))
    return [
        ("M3 x 8 button head screw", nh, "down through the top into the standoffs"),
        ("M3 x 12 button head screw", nh, "up through the floor bosses and the board into the standoffs"),
        ("M3 female-female hex standoff, 27 mm", nh, "board to the top"),
    ]


# ---------------------------------------------------------------- drawing
def draw_pieces(path, parts, cuts, pads):
    W, D = g.W, g.D
    fig = plt.figure(figsize=(17, 12.5))
    gs = fig.add_gridspec(4, 2, height_ratios=[4.2, 1, 1, 0.05], hspace=0.28, wspace=0.08)
    ax = fig.add_subplot(gs[0, 0])
    bx = fig.add_subplot(gs[0, 1])
    seam, tabc, catchc, pegc, stopc = "#c0392b", "#f2c14e", "#222222", "#1f6fa8", "#7a7f87"
    # floor and walls from above
    ax.add_patch(Rectangle((0, 0), W, D, fc="#e4e6ea", ec="#333", lw=1))
    ax.plot([FLOOR_X, FLOOR_X], [0, D], color=seam, lw=1.6)
    for y in FLOOR_TABS:
        ax.add_patch(Polygon(dove_poly("floor", FLOOR_X, y, "x", 1), fc=tabc, ec="#8a6d1f", lw=0.8))
    for hx, hy in g.board_hole_xys(parts):
        ax.add_patch(Circle((hx, hy), BOSS_D / 2, fc="#d4c08a", ec="#8a7a4a"))

    def rect(a_, side, bx_, **kw):
        (xa, ya), (xb, yb) = pt(side, bx_[0], bx_[2]), pt(side, bx_[1], bx_[3])
        a_.add_patch(Rectangle((min(xa, xb), min(ya, yb)), abs(xb - xa), abs(yb - ya), **kw))

    for side in SIDES:
        rect(ax, side, wall_span(side) + (-T, 0), fc="#4a4f56", ec="none")
        for u, d in SNAPS[side]:
            slits, patch = finger_boxes(side, u, d)
            rect(ax, side, patch, fc="white", ec="#555", lw=0.6)
            rect(ax, side, (min(u - d * FING_TIP, u + d * FING_L), max(u - d * FING_TIP, u + d * FING_L)) + FING_V,
                 fc="#e4e6ea", ec="none")
            ax.add_patch(Polygon([pt(side, u + a, b) for a, b in gable(WIN_HW, WIN_V0, WIN_V1, -SNAP_CLEAR, 0.5)],
                                 fc=catchc, ec="none"))
            rect(ax, side, stop_box(side, u, d), fc=stopc, ec="none")
    for y in VENT_ROWS:
        for x0, x1 in VENT_SPANS:
            ax.add_patch(Rectangle((x0, y - 2.5), x1 - x0, 5, fc="white", ec="#777", lw=0.5))
    for (cx_, cy_), n in zip(((40, 110), (255, 110)), NAMES2):
        ax.text(cx_, cy_, "floor\n" + n, ha="center", va="center", fontsize=10)
    ax.set_title("Floor and walls from above.  Red = floor seam, yellow = dovetail tabs across it,\n"
                 "black = catches on spring fingers (white slits round each), gray = stop blocks, tan = board bosses",
                 fontsize=10, loc="left")
    # top
    bx.add_patch(Rectangle((0, 0), W, D, fc="#dfeef8", ec="#333", lw=1))
    bay, cart, slot_x = g.openings(parts)
    bx.add_patch(Rectangle((bay[0], bay[2]), bay[1] - bay[0], D - bay[2], fc="white", ec="#333", lw=0.8))
    bx.add_patch(Rectangle((cart[0], cart[2]), cart[1] - cart[0], cart[3] - cart[2], fc="white", ec="#333", lw=0.8))
    bx.plot([TOP_X, TOP_X], [0, D], color=seam, lw=1.2)
    for y in TOP_TABS:
        bx.add_patch(Polygon(dove_poly("top", TOP_X, y, "x", 1), fc=tabc, ec="#8a6d1f", lw=0.8))
    for side in SIDES:
        for u in LUGS[side]:
            bx.add_patch(Polygon([pt(side, u + a, b) for a, b in gable(SOCK_HW, SOCK_V0, SOCK_V1, -SNAP_CLEAR, 0.5)],
                                 fc=pegc, ec="none"))
    for hx, hy in g.board_hole_xys(parts):
        bx.add_patch(Circle((hx, hy), 2.6, fc="#b8860b", ec="none"))
    for (cx_, cy_), n in zip(((60, 60), (235, 60)), NAMES2):
        bx.text(cx_, cy_, "top\n" + n, ha="center", va="center", fontsize=10)
    bx.set_title("Top from above.  Red = seam, yellow = dovetail tabs across it,\n"
                 "blue = pegs under the top (into the walls' sockets), gold = the 8 screws into the standoffs",
                 fontsize=10, loc="left")
    for a in (ax, bx):
        a.set_xlim(-12, W + 12)
        a.set_ylim(-12, D + 12)
        a.set_aspect("equal")
        a.set_xticks([0, FLOOR_X, W])
        a.set_yticks([0, D])
        a.text(W / 2, -9, "FRONT", ha="center", fontsize=9, weight="bold")
    # walls, seen from inside
    zb, zt = g.Z_FLOOR + T, g.Z_TOP
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
        edges = sorted(flange_gaps(side, parts, pads, MODEL_BOXES))
        for (a0, a1), (b0, b1) in zip(edges, edges[1:]):
            if b0 > a1:
                wx.add_patch(Rectangle((a1, zb), b0 - a1, FL_T, fc="#8d939b", ec="none"))
        for u, d in SNAPS[side]:
            wx.add_patch(Rectangle((u - WIN_HW, zb), 2 * WIN_HW, FL_T, fc=catchc, ec="none"))
        for u in LUGS[side]:
            wx.add_patch(Rectangle((u - LUG_W / 2, zt - LUG_H), LUG_W, LUG_H, fc=pegc, ec="none"))
        for ue in (u0, u1):       # corner tabs (side walls) and their notches (front and back walls)
            wx.add_patch(Rectangle((ue - 2.5, CORNER_TAB_Z[0]), 5, CORNER_TAB_Z[1] - CORNER_TAB_Z[0], fc=tabc,
                                   ec="#8a6d1f", lw=0.6))
        wx.set_xlim(-5, 300)
        wx.set_ylim(zb - 5, zt + 8)
        wx.set_aspect("equal")
        wx.set_yticks([])
        wx.set_xticks([0, wall_len(side)])
        wx.set_title("%s wall, one piece (mm along %s)" % (side.capitalize(), "x" if side in ("front", "back") else "y"),
                     fontsize=10, loc="left")
    fig.suptitle("3D-printed case for a 256 x 256 mm bed: 8 main pieces, every one prints flat without supports; "
                 "16 M3 screws, no nuts, no glue\nWalls: black = windows in the bottom flange for the floor's catches, "
                 "blue = lugs with a socket for a top peg, yellow = corner tabs and notches", fontsize=12, y=0.975)
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
    floor_solid = floor(parts)
    placed.update(floor_pieces(floor_solid))
    for side in SIDES:
        placed["wall_" + side] = wall(side, parts, cuts, pads, MODEL_BOXES)
    placed.update(top_pieces(top(parts)))
    covers = g.slot_covers(parts)
    for i, c in enumerate(covers):
        placed["slot_cover_%d" % (i + 1)] = c
    placed["cart_cover"] = g.cart_cover(parts)

    problems = joint_check(parts, pads, floor_solid)
    if fit:
        problems += fit_check(parts, pads, placed, model_solids)

    # what gets printed, in print orientation
    printed = {}
    for name, sol in placed.items():
        if name.startswith("slot_cover"):
            if name == "slot_cover_1":
                printed["slot_cover"] = to_bed(g.print_pose(sol))
            continue
        printed[name] = to_bed(g.print_pose(sol)) if name == "cart_cover" else print_pose(name, sol)
    printed["dovetail_test"] = dovetail_test()
    for name, sol in snap_test(placed).items():
        printed[name] = print_pose(name, sol)

    os.makedirs(out, exist_ok=True)
    for f in glob.glob(os.path.join(out, "*.stl")):
        os.remove(f)                              # the pieces of an earlier version
    rows = []
    for name, sol in printed.items():
        b = sol.val().BoundingBox()
        if max(b.xlen, b.ylen) > BED - BED_MARGIN:
            raise SystemExit("%s does not fit the bed: %.1f x %.1f" % (name, b.xlen, b.ylen))
        cq.exporters.export(sol, os.path.join(out, name + ".stl"), tolerance=0.02, angularTolerance=0.1)
        qty = {"slot_cover": len(covers)}.get(name, 1)
        rows.append(dict(name=name, qty=qty, size=[round(b.xlen, 1), round(b.ylen, 1), round(b.zlen, 1)],
                         orientation=orientation(name), volume_cm3=round(sol.val().Volume() / 1000, 1)))
    info = dict(bed=BED, pieces=rows, hardware=hardware(parts), floor_seam=FLOOR_X, top_seam=TOP_X,
                catches={sd: [u for u, d in SNAPS[sd]] for sd in SIDES}, pegs=LUGS,
                floor_tabs=FLOOR_TABS, top_tabs=TOP_TABS,
                dovetail=dict(DOVE, clearance=DOVE_CLEAR))
    with open(os.path.join(out, "print_layout.json"), "w") as f:
        json.dump(info, f, indent=1)
    if drawings:
        draw_pieces(os.path.join(drawings, "case_print_pieces.png"), parts, cuts, pads)
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
    if True:
        print("%s: %s" % ("fit check" if not a.no_fit else "joint check only (fit check skipped)",
                          "OK" if not problems else "%d problems" % len(problems)))
        for p in problems:
            print("  " + p)
        if problems:
            raise SystemExit(1)

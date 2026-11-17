#!/usr/bin/env python3
"""
gen_memcard_shell.py - the 512K memory card's printed shell (CadQuery):
case/memcard_shell_front.step/.stl and case/memcard_shell_back.step/.stl.

    python3 gen_memcard_shell.py

Two halves round the card and the slot's body, 77 x 22.6 mm outside
(EXPANSION.md, "Shell keepouts"), split at the card's side B face:

- front (side A, the parts side): a box with the long face closed.  Two
  bosses reach the card at H1 and H2, each with an M3 nut in a hex pocket
  that the card closes.  A block in the back end holds the M3 heat-set
  insert for the case's card screw, with a pad standing 1 mm proud.
- back (side B): a shallow lid with two pads and counterbored holes.

Two M3 x 8 pan head screws go through the back half and the card into the
nuts, so the screws hold the halves and the card together.

Print (Ender 3, no supports): each half with its big outside face on the
bed.  The STLs are written in that pose.  The screw-head counterbores on
the back half's bed face use a slot layer and a square layer under the
round hole; the insert hole, which lies sideways, is a flat-topped teardrop.

Frame used here, the card's: x along the fingers from the card's left edge
(side A view; x = 72 is the case's back), y up from the finger edge, z
across the card from its mid-plane, +z = side A.

Date: 2026-11-17
"""

import os

import cadquery as cq

import gen_kicad_connectors as gc

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "..", "case"))

CARD_W = gc.EXP_W            # 72
CARD_H = 42.7                # finger edge to the card's top edge (gen_kicad_memcard_pcb.py)
CARD_T = 1.6
EDGE_UP = 3.0                # finger edge above the main board when seated
WALL = gc.SHELL_WALL         # 2.0
AIR = gc.SHELL_AIR           # 0.5
SKIRT_GAP = 0.5              # shell's bottom edge above the main board
HOLES = ((11.0, 16.5), (61.0, 16.5))   # H1, H2 on the card
BOSS_R = 4.75
M3 = 3.4                     # clearance hole
NUT_AF, NUT_H = 5.7, 2.6     # hex pocket across flats, depth (nut 2.4)
HEAD_D, HEAD_H = 6.5, 2.8    # pan head counterbore
LAYER = 0.2
INSERT_Z = gc.CARD_PCB / 2 + gc.EXP_PARTS + 2 * AIR + WALL + gc.MARGIN - (17.35 - 5.05)   # 5.05 from the card's plane
INSERT_Y = 15.0 - EDGE_UP    # 15 mm above the main board
INSERT_D, PROUD = 4.0, 1.0   # hole for an M3 x 5.7 heat-set insert; pad proud of the end wall
BLOCK = 5.0                  # insert block, in from the end wall
BLOCK_HALF = 4.0             # its half height along y

ZA = CARD_T / 2 + gc.EXP_PARTS + 2 * AIR + WALL                       # 16.35, outside face, side A
ZB = -(3.75 + AIR + WALL)                                             # -6.25, outside face, side B
ZS = -CARD_T / 2                                                      # split plane
X0, X1 = -AIR - WALL, CARD_W + AIR + WALL                             # -2.5, 74.5
Y0, Y1 = -EDGE_UP + SKIRT_GAP, CARD_H + 2 * AIR + WALL                # -2.5, top outside


def box(x0, x1, y0, y1, z0, z1):
    return cq.Workplane("XY").box(x1 - x0, y1 - y0, z1 - z0, centered=False).translate((x0, y0, z0))


def cyl(x, y, r, z0, z1):
    return cq.Workplane("XY").circle(r).extrude(z1 - z0).translate((x, y, z0))


def hexprism(x, y, af, z0, z1):
    return cq.Workplane("XY").polygon(6, af / 0.8660254).extrude(z1 - z0).translate((x, y, z0))


def half(z_out, z_in):
    """An open box: the plate at z_out, walls left, right and top to z_in; the bottom is open."""
    lo, hi = min(z_out, z_in), max(z_out, z_in)
    s = box(X0, X1, Y0, Y1, lo, hi)
    plate = WALL if z_out < z_in else -WALL
    c0, c1 = sorted((z_out + plate, z_in))
    return s.cut(box(X0 + WALL, X1 - WALL, Y0 - 1, Y1 - WALL, c0, c1 + 0.01 if z_out < z_in else c1)
                 if z_out < z_in else box(X0 + WALL, X1 - WALL, Y0 - 1, Y1 - WALL, c0 - 0.01, c1))


def front():
    s = half(ZA, ZS)
    top = CARD_T / 2
    for x, y in HOLES:
        s = s.union(cyl(x, y, BOSS_R, top, ZA - WALL + 0.01))
        s = s.cut(hexprism(x, y, NUT_AF, top, top + NUT_H + 0.01).translate((0, 0, -0.01)))
        s = s.cut(cyl(x, y, M3 / 2, top, 7.0))
    # insert block and proud pad at the back end, both standing on the side A plate
    zb = 1.2
    s = s.union(box(X1 - WALL - BLOCK, X1 - WALL + 0.01, INSERT_Y - BLOCK_HALF, INSERT_Y + BLOCK_HALF, zb, ZA - WALL + 0.01))
    s = s.union(box(X1 - 0.01, X1 + PROUD, INSERT_Y - BLOCK_HALF, INSERT_Y + BLOCK_HALF, zb, ZA))
    # flat-topped teardrop along x (the print's up is -z)
    r = INSERT_D / 2
    prof = (cq.Workplane("YZ").moveTo(INSERT_Y, INSERT_Z).circle(r).extrude(BLOCK + WALL + PROUD + 2)
            .union(cq.Workplane("YZ").polyline([(INSERT_Y - r * 0.7071, INSERT_Z - r * 0.7071),
                                                (INSERT_Y + r * 0.7071, INSERT_Z - r * 0.7071),
                                                (INSERT_Y + 0.8, INSERT_Z - r - 0.4),
                                                (INSERT_Y - 0.8, INSERT_Z - r - 0.4)]).close()
                   .extrude(BLOCK + WALL + PROUD + 2)))
    s = s.cut(prof.translate((X1 - WALL - BLOCK - 1, 0, 0)))
    return s


def back():
    s = half(ZB, ZS)
    for x, y in HOLES:
        s = s.union(cyl(x, y, BOSS_R, ZB + WALL - 0.01, ZS))
        s = s.cut(cyl(x, y, HEAD_D / 2, ZB - 0.01, ZB + HEAD_H))
        # bridge helpers above the counterbore: a slot layer, a square layer, then the round hole
        z = ZB + HEAD_H
        slot = box(x - HEAD_D / 2, x + HEAD_D / 2, y - M3 / 2, y + M3 / 2, z - 0.01, z + LAYER).intersect(
            cyl(x, y, HEAD_D / 2, z - 0.01, z + LAYER))
        s = s.cut(slot)
        s = s.cut(box(x - M3 / 2, x + M3 / 2, y - M3 / 2, y + M3 / 2, z + LAYER - 0.01, z + 2 * LAYER))
        s = s.cut(cyl(x, y, M3 / 2, z + 2 * LAYER - 0.01, ZS + 0.01))
    return s


def print_pose(s, name):
    """Big outside face on the bed at z = 0."""
    if name == "front":
        return s.mirror("XY").translate((0, 0, ZA))      # z' = ZA - z
    return s.translate((0, 0, -ZB))


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, s in (("front", front()), ("back", back())):
        base = os.path.join(OUT, "memcard_shell_" + name)
        cq.exporters.export(s, base + ".step")
        p = print_pose(s, name)
        cq.exporters.export(p, base + ".stl", tolerance=0.01, angularTolerance=0.1)
        bb = p.val().BoundingBox()
        print("%s: %.1f x %.1f x %.1f mm in print pose, %d solid(s), volume %.1f cm3" % (
            base, bb.xlen, bb.ylen, bb.zlen, len(s.solids().vals()), s.val().Volume() / 1000))


if __name__ == "__main__":
    print("outside %.1f x %.1f x %.1f mm, insert %.2f from the card plane" % (X1 - X0, ZA - ZB, Y1 - Y0, INSERT_Z))
    main()

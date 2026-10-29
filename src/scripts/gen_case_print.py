#!/usr/bin/env python3
"""
gen_case_print.py - a 3D-printable version of the PLACARD case for a
220 x 220 mm bed (Creality Ender 3).  It takes the aluminium case's parts from
gen_case.py, unchanged in shape and fit, and:

- cuts the tray, the back and left plates and the top into pieces that fit
  the bed, along seams clear of the holes, vents and cut-outs;
- keys every seam with bowtie (butterfly) keys that go right through the
  part, so the glued pieces lock flat and in line;
- replaces the tray's PEM standoffs with printed bosses for M3 heat-set
  inserts, and opens the plates' flange holes for M3 nuts (no PEM nuts);
- prints each cover as one piece (plug and cap together).

    pip install cadquery
    python3 gen_case_print.py [--pcb path/to/placard.kicad_pcb] [--out case/print]

Writes STL files to case/print/ and docs/case_print_pieces.png.  See
docs/CASE.md, "3D-printed version".  The board file is only read.

Date: 2026-10-29
"""

import argparse
import math
import os

import cadquery as cq
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Polygon, Rectangle

import gen_case as g

BED = 220.0            # Ender 3 printable area, square
BED_MARGIN = 5.0       # each piece's footprint must fit BED - BED_MARGIN

# seams (case coordinates, mm), chosen clear of holes, vents and cut-outs
TRAY_X, TRAY_Y = 132.0, 120.0     # tray: four pieces
BACK_X = 140.0                    # back plate: two pieces (clear of the J12 card screw at 132)
LEFT_Y = 120.0                    # left plate: two pieces
TOP_X, TOP_Y = 160.0, 100.0       # top: four pieces (between the expansion bay and the cartridge lap)

# bowtie keys: length across the seam, width at the ends and at the seam
KEY_L, KEY_WB, KEY_WN = 16.0, 10.0, 5.0
KEY_CLEAR = 0.15       # per side, so a printed key drops in

# the side walls' vent slots stay off the seams and their keys (a key reaches
# KEY_L / 2 each side of its seam), so the right wall and the left plate each
# lose the two slots next to their seam at y 120
SEAM_VENT_CLEAR = 2.0
g.SIDE_VENT_SKIP = {
    "right": [(TRAY_Y - KEY_L / 2 - SEAM_VENT_CLEAR, TRAY_Y + KEY_L / 2 + SEAM_VENT_CLEAR)],
    "left": [(LEFT_Y - KEY_L / 2 - SEAM_VENT_CLEAR, LEFT_Y + KEY_L / 2 + SEAM_VENT_CLEAR)],
}

BOSS_D = 8.0           # printed standoff boss under each board hole
INSERT_D = 4.0         # hole for an M3 heat-set insert (M3 x 5.7)


def bowtie(L, wb, wn):
    return [(-L / 2, -wb / 2), (0, -wn / 2), (L / 2, -wb / 2), (L / 2, wb / 2), (0, wn / 2), (-L / 2, wb / 2)]


def key_cutter(origin, across, normal, thick):
    """A bowtie through a part of thickness thick: origin is the seam point on
    the part's near face, across the seam normal, normal the thickness direction."""
    n = cq.Vector(*normal)
    o = cq.Vector(*origin) - n
    plane = cq.Plane(origin=o.toTuple(), xDir=across, normal=normal)
    return cq.Workplane(plane).polyline(bowtie(KEY_L, KEY_WB, KEY_WN)).close().extrude(thick + 2)


def key_solid(thick):
    c = 2 * KEY_CLEAR
    return cq.Workplane("XY").polyline(bowtie(KEY_L - c, KEY_WB - c, KEY_WN - c)).close().extrude(thick)


def big_box(x0, x1, y0, y1):
    return cq.Workplane("XY").box(x1 - x0, y1 - y0, 200, centered=False).translate((x0, y0, -100))


def split4(solid, xs, ys, names):
    """Cut solid into four pieces at x = xs and y = ys: front left, front right,
    back left, back right."""
    out = {}
    boxes = [(-50, xs, -50, ys), (xs, 400, -50, ys), (-50, xs, ys, 400), (xs, 400, ys, 400)]
    for name, b in zip(names, boxes):
        out[name] = solid.intersect(big_box(*b))
    return out


def split2(solid, axis, at, names):
    if axis == "x":
        boxes = [(-50, at, -50, 400), (at, 400, -50, 400)]
    else:
        boxes = [(-50, 400, -50, at), (-50, 400, at, 400)]
    return {n: solid.intersect(big_box(*b)) for n, b in zip(names, boxes)}


# ---------------------------------------------------------------- the parts
def tray_print(parts, cuts):
    s = g.tray(parts, cuts)
    zf, zb = g.Z_FLOOR, -g.PCB_T          # floor underside, board underside
    for ref in g.board_holes(parts):
        x, y = g.hole_xy(parts, ref)
        s = s.union(cq.Workplane("XY").center(x, y).circle(BOSS_D / 2).extrude(zb - zf).translate((0, 0, zf)))
        s = s.cut(cq.Workplane("XY").center(x, y).circle(INSERT_D / 2).extrude(7.0).translate((0, 0, zb - 7.0)))
    return s


def plate_print(parts, cuts, side):
    s = g.plate(parts, cuts, side)
    for x, y in g.plate_screws():
        s = s.cut(g.hole(x, y, 3.4, g.Z_FLOOR - 1))
    return s


def tray_keys():
    """(origin, across, normal, thick) of every key in the tray."""
    T, zf = g.T, g.Z_FLOOR
    ks = [((TRAY_X, y, zf), (1, 0, 0), (0, 0, 1), T) for y in (12.0, 112.0, 160.0, 195.0)]
    ks += [((x, TRAY_Y, zf), (0, 1, 0), (0, 0, 1), T) for x in (30.0, 75.0, 110.0, 170.0, 215.0, 260.0)]
    ks += [((TRAY_X, 0.0, z), (1, 0, 0), (0, 1, 0), T) for z in (0.0, 18.0)]           # front wall
    ks += [((g.W - T, TRAY_Y, z), (0, 1, 0), (1, 0, 0), T) for z in (0.0, 18.0)]       # right wall
    return ks


def plate_keys(side):
    T = g.T
    if side == "back":
        return [((BACK_X, g.D - T, z), (1, 0, 0), (0, 1, 0), T) for z in (0.0, 8.0)]
    return [((0.0, LEFT_Y, z), (0, 1, 0), (1, 0, 0), T) for z in (0.0, 10.0)]


def top_keys():
    A, zt = g.ACRYLIC, g.Z_TOP
    ks = [((TOP_X, y, zt), (1, 0, 0), (0, 0, 1), A) for y in (40.0, 75.0, 160.0, 200.0)]
    ks += [((x, TOP_Y, zt), (0, 1, 0), (0, 0, 1), A) for x in (25.0, 80.0, 125.0, 205.0, 260.0)]
    return ks


def keyed(solid, keys):
    for k in keys:
        solid = solid.cut(key_cutter(*k))
    return solid


def footprint_fits(solid):
    """True if the piece, laid on its largest flat side, fits the bed."""
    b = solid.val().BoundingBox()
    dims = sorted([b.xlen, b.ylen, b.zlen])
    return dims[1] <= BED - BED_MARGIN and dims[2] <= BED - BED_MARGIN, dims


# ---------------------------------------------------------------- drawing
def draw_pieces(path):
    W, D = g.W, g.D
    fig, axs = plt.subplots(1, 2, figsize=(15, 6.2))
    for ax, title, xs, ys, keys in (
            (axs[0], "Tray (floor, front and right walls) and plates, from above", TRAY_X, TRAY_Y, tray_keys()),
            (axs[1], "Top, from above", TOP_X, TOP_Y, top_keys())):
        ax.add_patch(Rectangle((0, 0), W, D, fc="#e4e6ea", ec="#333", lw=1))
        ax.plot([xs, xs], [0, D], color="#c33", lw=1.5)
        ax.plot([0, W], [ys, ys], color="#c33", lw=1.5)
        if ax is axs[0]:
            ax.plot([BACK_X, BACK_X], [D - 8, D + 4], color="#1f6fa8", lw=2.5)
            ax.plot([-4, 8], [LEFT_Y, LEFT_Y], color="#1f6fa8", lw=2.5)
            ax.text(BACK_X + 3, D + 2, "back plate seam", fontsize=9, color="#1f6fa8", va="bottom")
            ax.text(-6, LEFT_Y + 3, "left plate\nseam", fontsize=9, color="#1f6fa8", ha="right")
        for o, across, normal, t in keys:
            if normal != (0, 0, 1):
                continue
            pts = bowtie(KEY_L, KEY_WB, KEY_WN)
            if across == (1, 0, 0):
                xy = [(o[0] + a, o[1] + b) for a, b in pts]
            else:
                xy = [(o[0] + b, o[1] + a) for a, b in pts]
            ax.add_patch(Polygon(xy, fc="#f2c14e", ec="#8a6d1f", lw=0.8))
        for i, (cx_, cy_) in enumerate(((xs / 2, ys / 2), ((xs + W) / 2, ys / 2), (xs / 2, (ys + D) / 2),
                                        ((xs + W) / 2, (ys + D) / 2))):
            ax.text(cx_, cy_, ("front left", "front right", "back left", "back right")[i], ha="center",
                    va="center", fontsize=11)
        ax.set_xlim(-50, W + 15)
        ax.set_ylim(-15, D + 20)
        ax.set_aspect("equal")
        ax.set_title(title, fontsize=11, loc="left")
        ax.set_xticks([0, xs, W])
        ax.set_yticks([0, ys, D])
    fig.suptitle("3D-printed case: red = seams, yellow = bowtie keys in the floor/top "
                 "(two more in each wall seam), every piece fits a 220 x 220 mm bed", fontsize=11)
    fig.tight_layout()
    fig.savefig(path, dpi=100)
    plt.close(fig)


def build(pcb, out, drawings):
    parts = g.read_board(pcb)
    cuts = g.wall_cutouts(parts)
    pieces = {}
    tray = keyed(tray_print(parts, cuts), tray_keys())
    pieces.update(split4(tray, TRAY_X, TRAY_Y, ["tray_front_left", "tray_front_right", "tray_back_left",
                                                 "tray_back_right"]))
    back = keyed(plate_print(parts, cuts, "back"), plate_keys("back"))
    pieces.update(split2(back, "x", BACK_X, ["back_plate_left", "back_plate_right"]))
    left = keyed(plate_print(parts, cuts, "left"), plate_keys("left"))
    pieces.update(split2(left, "y", LEFT_Y, ["left_plate_front", "left_plate_back"]))
    top = keyed(g.acrylic_top(parts), top_keys())
    pieces.update(split4(top, TOP_X, TOP_Y, ["top_front_left", "top_front_right", "top_back_left",
                                             "top_back_right"]))
    pieces["slot_cover"] = g.slot_covers(parts)[0]
    pieces["cart_cover"] = g.cart_cover(parts)
    pieces["key_2mm"] = key_solid(g.T)
    pieces["key_4mm"] = key_solid(g.ACRYLIC)

    os.makedirs(out, exist_ok=True)
    rows = []
    for name, sol in pieces.items():
        ok, dims = footprint_fits(sol)
        if not ok:
            raise SystemExit("%s does not fit the bed: %s" % (name, dims))
        cq.exporters.export(sol, os.path.join(out, name + ".stl"), tolerance=0.05, angularTolerance=0.2)
        rows.append((name, dims))
    n_tray = len(tray_keys()) + len(plate_keys("back")) + len(plate_keys("left"))
    if drawings:
        draw_pieces(os.path.join(drawings, "case_print_pieces.png"))
    return rows, n_tray, len(top_keys())


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--pcb", default=os.path.join(g.REPO, "kicad", "placard.kicad_pcb"))
    ap.add_argument("--out", default=os.path.join(g.REPO, "case", "print"))
    ap.add_argument("--drawings", default=os.path.join(g.REPO, "docs"))
    a = ap.parse_args()
    rows, k2, k4 = build(a.pcb, a.out, a.drawings)
    for name, dims in rows:
        print("%-18s %6.1f x %6.1f x %5.1f mm" % (name, dims[2], dims[1], dims[0]))
    for sd in ("left", "right"):
        print("%-5s wall: %d vent slots" % (sd, len(g.side_vents(g.wall_cutouts(g.read_board(a.pcb)), sd))))
    print("keys: %d x 2 mm (tray, plates), %d x 4 mm (top)" % (k2, k4))

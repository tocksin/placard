#!/usr/bin/env python3
"""
gen_case.py - the PLACARD case concept: a split brushed, anodized aluminium
shell, a clear acrylic top, an acrylic blank for builds without the Cherry MX
keyboard, and one removable acrylic cover per expansion slot (J9-J12) and for
the cartridge slot (J8).  See docs/CASE.md.

    pip install cadquery
    python3 gen_case.py [--pcb path/to/placard.kicad_pcb] [--out case] [--mesh dir]

The connector cut-outs are placed from the board file: each footprint's
position and rotation, and the face of its 3D model (kicad/lib/placard.3dshapes)
where it meets the wall.  The board file is only read, never written.  Rerun
after connectors move.

Parts (STEP in case/, DXF cutting files for the acrylic in case/dxf/):

| File | Part | Material |
|---|---|---|
| lower_shell | floor and lower walls, up to the split line | 2.0 mm 5052 aluminium, bent, brushed, clear or black anodized |
| upper_shell | upper walls and top flange with the two windows | 2.0 mm 5052 aluminium, bent, brushed, anodized |
| acrylic_top | window over the board, slot and cartridge openings | 4 mm clear cast acrylic, laser cut |
| keyboard_blank | covers the keyboard bay when no keyboard is fitted | 4 mm clear cast acrylic |
| keyboard_plate | Cherry MX switch plate (63 keys, stabilizer cut-outs), fills the bay instead | 1.5 mm 5052 aluminium, anodized |
| slot_cover | one per expansion slot (4 alike), plug + cap | 4 mm + 3 mm acrylic, solvent welded |
| cart_cover | cartridge slot cover, plug + cap | 4 mm + 3 mm acrylic |

Coordinates (mm): x from the case's left outside face, y from the front
outside face toward the back, z up from the main board's top face.

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
from matplotlib.patches import Circle, FancyBboxPatch, Polygon, Rectangle

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
MODELS = os.path.join(REPO, "kicad", "lib", "placard.3dshapes")

# ---------------------------------------------------------------- stack-up
BOARD = 290.0          # main board is BOARD x BOARD
T = 2.0                # aluminium sheet
GAP = 0.5              # board edge to inside face of a wall
W = BOARD + 2 * (GAP + T)       # 295 outside, square
OFF = GAP + T          # board's back-left corner in case x, from the back face in y
PCB_T = 1.6
Z_FLOOR = -PCB_T - 8.0 - T      # underside of the floor: 8 mm standoffs under the board
Z_SPLIT = 4.0          # where the lower and upper shells meet, away from the connectors
Z_TOP = 27.0           # underside of the top flange (stacked PS/2 J5 is 25 mm tall)
ACRYLIC = 4.0          # top and keyboard blank
CAP = 3.0              # cover caps
PLATE = 1.5            # MX plate
MX_PLATE_TO_PCB = 5.0  # plate top to keyboard PCB top (Cherry MX)

# top flange openings (x0, x1, y0, y1)
BAY = (5.0, W - 5.0, 11.0, 111.0)              # keyboard bay (plate or blank sits over it)
SEAM = 121.0                                   # blank/plate meets the acrylic top here
MAIN = (10.0, W - 10.0, 131.0, W - 10.0)       # board window under the acrylic top

U = 19.05              # key pitch
KEY_ROWS = [           # 63-key layout, docs/IO.md "Planned layout: 63 keys"
    [1] * 13 + [2],
    [1.5] + [1] * 12 + [1.5],
    [1.75] + [1] * 11 + [2.25],
    [2.25] + [1] * 10 + [1.75, 1],
    [1.25, 1.25, 1.25, 6.25, 1, 1, 1, 1, 1],
]
KB_W, KB_D = 15 * U, 5 * U
KB_X0 = (W - KB_W) / 2
KB_Y0 = (BAY[2] + BAY[3] - KB_D) / 2

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
TOP_HOLES = ["H1", "H6", "H2", "H7", "H8"]     # acrylic top screws into standoffs here
BAY_HOLES = ["H3", "H5", "H4"]                 # front of the bay
LIP = 4.0              # cover cap overlap on the acrylic


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
    assert abs(size[0] - BOARD) < 0.1 and abs(size[1] - BOARD) < 0.1, size
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
    return W - OFF - by


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
    return sh.translate((OFF, W - OFF, 0))


def wall_face(solid, side):
    """Centre (u along the wall, z) of the model where it meets the wall: the part
    that sticks out past the board edge, or else its face at the edge."""
    t = 0.3
    for d in (1.0, -0.4):
        if side == "back":
            box = cq.Solid.makeBox(W, t, 80, cq.Vector(0, W - OFF + d - t / 2, -20))
        elif side == "left":
            box = cq.Solid.makeBox(t, W, 80, cq.Vector(OFF - d - t / 2, 0, -20))
        else:
            box = cq.Solid.makeBox(t, W, 80, cq.Vector(W - OFF + d - t / 2, 0, -20))
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
        plane = cq.Plane(origin=(u, W - T / 2 - depth / 2, z), xDir=(1, 0, 0), normal=(0, 1, 0))
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
            (u, W - T, z0))
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


def openings(parts):
    """Openings in the acrylic top: the expansion bay (one opening over J9-J12's shell
    keepouts, out to the back wall's inside face) and the cartridge (J8's keepout)."""
    xs = [parts[s]["crt"] for s in SLOTS]
    bay = (cx(min(c[0] for c in xs)), cx(max(c[2] for c in xs)),
           cy(max(c[3] for c in xs)), W - T)
    c = parts[CART]["crt"]
    cart = (cx(c[0]), cx(c[2]), cy(c[3]), cy(c[1]))
    slot_x = [(cx(parts[s]["crt"][0]), cx(parts[s]["crt"][2])) for s in SLOTS]
    return bay, cart, slot_x


def hole_xy(parts, ref):
    return cx(parts[ref]["x"]), cy(parts[ref]["y"])


def lower_shell(parts, cuts):
    s = rounded_plate(0, W, 0, W, Z_FLOOR, Z_SPLIT - Z_FLOOR, 3.0)
    s = s.cut(rounded_plate(T, W - T, T, W - T, Z_FLOOR + T, 100, 1.0))
    for ref, side, u, z, zj, prof, note in cuts:
        half = cut_width(prof) / 2 + STEP_MARGIN
        if zj > Z_SPLIT:
            s = s.union(step_box(side, u, half, Z_SPLIT - 0.01, zj))
        elif zj < Z_SPLIT:
            s = s.cut(step_box(side, u, half, zj, Z_SPLIT + 1))
        s = s.cut(cutter(side, u, z, prof))
    # floor: standoff holes, vent slots under the board's middle, feet stay solid
    for ref in sorted(k for k in parts if re.fullmatch(r"H\d+", k)):
        x, y = hole_xy(parts, ref)
        s = s.cut(cq.Workplane("XY").center(x, y).circle(2.1).extrude(10).translate((0, 0, Z_FLOOR - 1)))
    for i in range(9):
        y = 150 + i * 12.0
        s = s.cut(cq.Workplane("XY").center(W / 2, y).slot2D(150, 5).extrude(10).translate((0, 0, Z_FLOOR - 1)))
    return s


def upper_shell(parts, cuts):
    bay, cart, slot_x = openings(parts)
    s = rounded_plate(0, W, 0, W, Z_SPLIT, Z_TOP + T - Z_SPLIT, 3.0)
    s = s.cut(rounded_plate(T, W - T, T, W - T, Z_SPLIT - 1, Z_TOP - Z_SPLIT + 1, 1.0))
    s = s.cut(rounded_plate(BAY[0], BAY[1], BAY[2], BAY[3], Z_TOP - 1, 10, 2.0))
    s = s.cut(rounded_plate(MAIN[0], MAIN[1], MAIN[2], MAIN[3], Z_TOP - 1, 10, 2.0))
    # the card shells pass the back flange: open it to the back wall's inside face
    s = s.cut(rounded_plate(bay[0], bay[1], MAIN[3] - 5, W - T, Z_TOP - 1, 10))
    for ref, side, u, z, zj, prof, note in cuts:
        half = cut_width(prof) / 2 + STEP_MARGIN
        if zj < Z_SPLIT:
            s = s.union(step_box(side, u, half, zj, Z_SPLIT + 0.01))
        elif zj > Z_SPLIT:
            s = s.cut(step_box(side, u, half, Z_SPLIT - 1, zj))
        s = s.cut(cutter(side, u, z, prof))
    for x, y in top_screws(parts) + bay_screws(parts):
        s = s.cut(cq.Workplane("XY").center(x, y).circle(1.6).extrude(10).translate((0, 0, Z_TOP - 1)))
    return s


def top_screws(parts):
    """Acrylic top: into standoffs at H1, H6, H2, H7, H8, and PEM nuts along the cross bar."""
    pts = [hole_xy(parts, h) for h in TOP_HOLES if h in parts]
    return pts + [(15.0, (SEAM + MAIN[2]) / 2), (W / 2, (SEAM + MAIN[2]) / 2), (W - 15.0, (SEAM + MAIN[2]) / 2)]


def bay_screws(parts):
    """Keyboard blank / plate: into standoffs at H3, H5, H4 (under the front flange) and
    PEM nuts along the cross bar."""
    pts = [hole_xy(parts, h) for h in BAY_HOLES if h in parts]
    return pts + [(15.0, (SEAM + BAY[3]) / 2), (W / 2, (SEAM + BAY[3]) / 2), (W - 15.0, (SEAM + BAY[3]) / 2)]


def acrylic_top(parts):
    bay, cart, slot_x = openings(parts)
    z0 = Z_TOP + T
    s = rounded_plate(0, W, SEAM, W, z0, ACRYLIC)
    s = s.edges("|Z and >Y").fillet(3.0)
    s = s.cut(rounded_plate(bay[0], bay[1], bay[2], W + 1, z0 - 1, ACRYLIC + 2))
    s = s.cut(rounded_plate(cart[0], cart[1], cart[2], cart[3], z0 - 1, ACRYLIC + 2, 1.0))
    for x, y in top_screws(parts):
        s = s.cut(cq.Workplane("XY").center(x, y).circle(1.7).extrude(10).translate((0, 0, z0 - 1)))
    return s


def keyboard_blank(parts):
    z0 = Z_TOP + T
    s = rounded_plate(0, W, 0, SEAM, z0, ACRYLIC).edges("|Z and <Y").fillet(3.0)
    for x, y in bay_screws(parts):
        s = s.cut(cq.Workplane("XY").center(x, y).circle(1.7).extrude(10).translate((0, 0, z0 - 1)))
    return s


def key_positions():
    """(x centre, y centre, width) of each key, front row first."""
    keys = []
    for r, row in enumerate(KEY_ROWS):
        y = KB_Y0 + KB_D - (r + 0.5) * U
        x = KB_X0
        for w in row:
            keys.append((x + w * U / 2, y, w))
            x += w * U
    return keys


def keyboard_plate(parts):
    z0 = Z_TOP + T
    s = rounded_plate(0, W, 0, SEAM, z0, PLATE).edges("|Z and <Y").fillet(3.0)
    for x, y, w in key_positions():
        s = s.cut(cq.Workplane("XY").center(x, y).rect(14.0, 14.0).extrude(10).translate((0, 0, z0 - 1)))
        if w >= 2:      # stabilizer housings pass through the plate (2u-2.75u at 23.876, 6.25u at 100 mm)
            d = 50.0 if w > 6 else 11.938
            for sx in (-d, d):
                s = s.cut(cq.Workplane("XY").center(x + sx, y).rect(6.75, 14.0).extrude(10).translate((0, 0, z0 - 1)))
    for x, y in bay_screws(parts):
        s = s.cut(cq.Workplane("XY").center(x, y).circle(1.7).extrude(10).translate((0, 0, z0 - 1)))
    return s


def slot_covers(parts):
    """One cover per expansion slot: a 4 mm plug filling its share of the opening
    (it rests on the back wall's top edge) and a 3 mm cap that laps LIP onto the
    acrylic in front; neighbours butt with a 0.4 mm gap."""
    bay, cart, slot_x = openings(parts)
    n = len(slot_x)
    pitch = (bay[1] - bay[0]) / n
    z0 = Z_TOP + T
    out = []
    for i in range(n):
        x0, x1 = bay[0] + i * pitch + 0.2, bay[0] + (i + 1) * pitch - 0.2
        plug = rounded_plate(x0, x1, bay[2] + 0.2, W, z0, ACRYLIC)
        cap = rounded_plate(x0, x1, bay[2] - LIP, W, z0 + ACRYLIC, CAP)
        cap = cap.cut(cq.Workplane("XY").center((x0 + x1) / 2, bay[2] - LIP).circle(5.0).extrude(10)
                      .translate((0, 0, z0)))
        out.append(plug.union(cap))
    return out


def cart_cover(parts):
    bay, cart, slot_x = openings(parts)
    z0 = Z_TOP + T
    plug = rounded_plate(cart[0] + 0.2, cart[1] - 0.2, cart[2] + 0.2, cart[3] - 0.2, z0, ACRYLIC, 0.8)
    cap = rounded_plate(cart[0] - LIP, cart[1] + LIP, cart[2] - LIP, cart[3] + LIP, z0 + ACRYLIC, CAP, 3.0)
    cap = cap.cut(cq.Workplane("XY").center((cart[0] + cart[1]) / 2, cart[2] - LIP).circle(5.0).extrude(10)
                  .translate((0, 0, z0)))
    return plug.union(cap)


def standoffs(parts):
    """M3 standoffs at every board hole: floor PEM standoff under the board,
    male-female hex standoff from the board's top to the top flange."""
    out = []
    for ref in sorted(k for k in parts if re.fullmatch(r"H\d+", k)):
        x, y = hole_xy(parts, ref)
        lo = cq.Workplane("XY").center(x, y).polygon(6, 5.5 / math.cos(math.pi / 6)).extrude(
            -PCB_T - (Z_FLOOR + T)).translate((0, 0, Z_FLOOR + T))
        hi = cq.Workplane("XY").center(x, y).polygon(6, 5.5 / math.cos(math.pi / 6)).extrude(Z_TOP)
        out += [lo, hi]
    return out


# ---------------------------------------------------------------- drawings
ALU_C, ACR_C, KEY_C = "#b9bec5", "#cfe8f7", "#7b8189"


def dim(ax, p0, p1, text, off=(0, 0), fs=9):
    ax.annotate("", p0, p1, arrowprops=dict(arrowstyle="<->", lw=0.8, color="#333"))
    ax.text((p0[0] + p1[0]) / 2 + off[0], (p0[1] + p1[1]) / 2 + off[1], text, ha="center", va="center",
            fontsize=fs, color="#222", bbox=dict(fc="white", ec="none", pad=0.6))


def draw_top(info, path):
    """Top view: upper shell flange, acrylic top and blank, covers, screws."""
    fig, ax = plt.subplots(figsize=(13, 13.6))
    Wd = info["W"]
    ax.add_patch(FancyBboxPatch((0, 0), Wd, Wd, boxstyle="round,pad=0,rounding_size=3", fc=ALU_C, ec="#555", lw=1.2))
    for (x0, x1, y0, y1), lab in ((info["BAY"], "keyboard bay"), (info["MAIN"], "board window")):
        ax.add_patch(Rectangle((x0, y0), x1 - x0, y1 - y0, fc="#eef3ee", ec="#555", lw=0.8))
    bay, cart = info["bay"], info["cart"]
    ax.add_patch(Rectangle((bay[0], info["MAIN"][3] - 5), bay[1] - bay[0], Wd - info["T"] - info["MAIN"][3] + 5,
                           fc="#eef3ee", ec="#555", lw=0.8))
    # acrylic top + blank, outlines
    ax.add_patch(Rectangle((0, info["SEAM"]), Wd, Wd - info["SEAM"], fc=ACR_C, ec="#2b7bb9", lw=1.2, alpha=0.45))
    ax.add_patch(Rectangle((0, 0), Wd, info["SEAM"], fc=ACR_C, ec="#2b7bb9", lw=1.2, alpha=0.30, ls="--"))
    for x, y, w in info["keys"]:
        ax.add_patch(Rectangle((x - w * 19.05 / 2 + 0.6, y - 19.05 / 2 + 0.6), w * 19.05 - 1.2, 19.05 - 1.2,
                               fc="none", ec=KEY_C, lw=0.5))
        ax.add_patch(Rectangle((x - 7, y - 7), 14, 14, fc="none", ec="#9aa", lw=0.4))
    # expansion bay covers and cartridge cover
    n = len(info["slot_x"])
    pitch = (bay[1] - bay[0]) / n
    for i in range(n):
        x0 = bay[0] + i * pitch + 0.2
        ax.add_patch(Rectangle((x0, bay[2] - 4), pitch - 0.4, Wd - bay[2] + 4, fc="#9fd0ef", ec="#1f6fa8", lw=1.0,
                               alpha=0.6))
        ax.add_patch(Circle((x0 + pitch / 2 - 0.2, bay[2] - 4), 5, fc="white", ec="#1f6fa8", lw=0.8))
        ax.text(x0 + pitch / 2, (bay[2] + Wd) / 2, "J%d cover" % (9 + i), rotation=90, ha="center", va="center",
                fontsize=9)
    ax.add_patch(Rectangle((cart[0] - 4, cart[2] - 4), cart[1] - cart[0] + 8, cart[3] - cart[2] + 8, fc="#9fd0ef",
                           ec="#1f6fa8", lw=1.0, alpha=0.6))
    ax.add_patch(Rectangle((cart[0], cart[2]), cart[1] - cart[0], cart[3] - cart[2], fc="none", ec="#1f6fa8",
                           lw=0.8, ls=":"))
    ax.text((cart[0] + cart[1]) / 2, (cart[2] + cart[3]) / 2, "J8 cover", ha="center", va="center", fontsize=9)
    for x, y in info["top_screws"]:
        ax.add_patch(Circle((x, y), 2.8, fc="#333", ec="none"))
    for x, y in info["bay_screws"]:
        ax.add_patch(Circle((x, y), 2.8, fc="#333", ec="none"))
    for c in info["cuts"]:
        u = c["u"]
        if c["side"] == "back":
            ax.plot([u, u], [Wd, Wd + 6], color="#c33", lw=1)
            ax.text(u, Wd + 8, c["ref"], ha="center", va="bottom", fontsize=9, color="#c33")
        elif c["side"] == "left":
            ax.plot([0, -6], [u, u], color="#c33", lw=1)
            ax.text(-8, u, c["ref"], ha="right", va="center", fontsize=9, color="#c33")
        else:
            ax.plot([Wd, Wd + 6], [u, u], color="#c33", lw=1)
            ax.text(Wd + 8, u, c["ref"], ha="left", va="center", fontsize=9, color="#c33")
    dim(ax, (0, -14), (Wd, -14), "%.0f" % Wd)
    dim(ax, (Wd + 30, 0), (Wd + 30, Wd), "%.0f" % Wd, fs=9)
    dim(ax, (-30, info["BAY"][2]), (-30, info["BAY"][3]), "bay %.0f" % (info["BAY"][3] - info["BAY"][2]))
    dim(ax, (-30, 0), (-30, info["SEAM"]), "", fs=8)
    ax.text(-36, info["SEAM"], "seam %.0f" % info["SEAM"], ha="right", va="center", fontsize=8)
    ax.text(Wd / 2, info["MAIN"][2] + 4, "4 mm clear acrylic top over the board window, 8 screws",
            ha="center", va="bottom", fontsize=10)
    ax.text(Wd / 2, Wd + 22, "BACK", ha="center", fontsize=11, weight="bold")
    ax.text(Wd / 2, -26, "FRONT", ha="center", fontsize=11, weight="bold")
    ax.set_xlim(-75, Wd + 55)
    ax.set_ylim(-35, Wd + 30)
    ax.set_aspect("equal")
    ax.axis("off")
    ax.set_title("PLACARD case - top view (mm).  Grey = upper aluminium flange, blue = acrylic, "
                 "dots = M3 screws, red = wall connectors.\nFront bay: Cherry MX plate (63 keys, drawn) or a 4 mm "
                 "acrylic blank, 6 screws each", fontsize=11)
    fig.tight_layout()
    fig.savefig(path, dpi=110)
    plt.close(fig)


def cut_outline(prof, u, z, flip):
    """2D outline points of a cut-out in a wall elevation (u, z)."""
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
    """Back, left and right walls seen from outside: the stepped split line and
    the cut-outs, plus a section through the case."""
    Wd, zf, zs, zt, T = info["W"], info["Z_FLOOR"], info["Z_SPLIT"], info["Z_TOP"], info["T"]
    za = zt + T + info["ACRYLIC"]
    fig, axs = plt.subplots(4, 1, figsize=(15, 15), gridspec_kw=dict(height_ratios=[1, 1, 1, 1.3]))
    views = (("back", "Back wall, seen from behind", True), ("left", "Left wall, seen from the left", True),
             ("right", "Right wall, seen from the right", False))
    for ax, (side, title, flip) in zip(axs, views):
        s = -1 if flip else 1
        cuts = sorted([c for c in info["cuts"] if c["side"] == side], key=lambda c: c["u"])
        # split line: steps at each connector
        pts = []
        for c in cuts:
            half = cut_width(c["prof"]) / 2 + STEP_MARGIN
            pts.append((c["u"] - half, c["u"] + half, c["zj"]))
        # the split line, with overlapping steps merged
        us = sorted(set([0, Wd] + [p for a, b, z in pts for p in (a, b)]))
        prof = []
        for u0, u1 in zip(us[:-1], us[1:]):
            m = (u0 + u1) / 2
            zz = [z for a, b, z in pts if a <= m <= b]
            z = max(zz) if zz and max(zz) > zs else (min(zz) if zz else zs)
            prof += [(u0, z), (u1, z)]
        lower = [(s * u, z) for u, z in prof] + [(s * Wd, zf), (0, zf)]
        upper = [(s * u, z) for u, z in prof] + [(s * Wd, zt + T), (0, zt + T)]
        ax.add_patch(Polygon(lower, fc="#c9cdd3", ec="#444", lw=1))
        ax.add_patch(Polygon(upper, fc="#dfe2e6", ec="#444", lw=1))
        ax.add_patch(Rectangle((min(0, s * Wd), zt + T), Wd, info["ACRYLIC"], fc=ACR_C, ec="#2b7bb9", lw=0.8))
        ax.plot([s * u for u, z in prof], [z for u, z in prof], color="#c33", lw=1.6)
        for c in cuts:
            for patch in cut_outline(c["prof"], c["u"], c["z"], flip):
                patch.set_facecolor("white")
                patch.set_edgecolor("#222")
                patch.set_linewidth(0.9)
                ax.add_patch(patch)
            ax.text(s * c["u"], za + 4, c["ref"], ha="center", va="bottom", fontsize=9)
            ax.text(s * c["u"], zf - 3, "z %.1f" % c["zj"], ha="center", va="top", fontsize=7, color="#c33")
        ax.text(s * Wd / 2 if not flip else -Wd / 2, (zs + zt) / 2 + 3, "upper shell", ha="center", fontsize=9,
                color="#555")
        ax.text(s * Wd / 2 if not flip else -Wd / 2, (zf + zs) / 2 - 2, "lower shell", ha="center", fontsize=9,
                color="#555")
        ax.set_xlim(min(0, s * Wd) - 22, max(0, s * Wd) + 22)
        ax.set_ylim(zf - 12, za + 12)
        ax.set_aspect("equal")
        ax.set_yticks([zf, 0, zs, zt + T, za])
        ax.set_yticklabels(["%.1f floor" % zf, "0 board top", "%.0f split" % zs, "%.0f flange" % (zt + T),
                            "%.0f top" % za], fontsize=8)
        ax.set_xticks([])
        for sp in ("top", "right", "bottom"):
            ax.spines[sp].set_visible(False)
        ax.set_title(title + " (red = split line; it steps to each connector's centre)", fontsize=10, loc="left")
    # section through the keyboard bay and the board window, at x = middle
    ax = axs[3]
    ax.add_patch(Rectangle((0, zf), Wd, T, fc="#c9cdd3", ec="#444"))
    ax.add_patch(Rectangle((0, zf), T, zs - zf, fc="#c9cdd3", ec="#444"))
    ax.add_patch(Rectangle((Wd - T, zf), T, zs - zf, fc="#c9cdd3", ec="#444"))
    ax.add_patch(Rectangle((0, zs), T, zt + T - zs, fc="#dfe2e6", ec="#444"))
    ax.add_patch(Rectangle((Wd - T, zs), T, zt + T - zs, fc="#dfe2e6", ec="#444"))
    for y0, y1 in ((0, info["BAY"][2]), (info["BAY"][3], info["MAIN"][2]), (info["MAIN"][3], Wd)):
        ax.add_patch(Rectangle((y0, zt), y1 - y0, T, fc="#dfe2e6", ec="#444"))
    ax.add_patch(Rectangle((OFF, -1.6), 290, 1.6, fc="#2e7d4f", ec="#1b4d30"))
    for y in (OFF + 5, Wd / 2, Wd - OFF - 5):
        ax.add_patch(Rectangle((y - 2.75, zf + T), 5.5, -1.6 - zf - T, fc="#d4c08a", ec="#8a7a4a", lw=0.6))
    for y in (OFF + 5, Wd - OFF - 5):
        ax.add_patch(Rectangle((y - 2.75, 0), 5.5, zt, fc="#d4c08a", ec="#8a7a4a", lw=0.6))
    for y in range(40, 260, 35):
        ax.add_patch(Rectangle((y, 0), 12, 8.3, fc="#222", ec="none"))
    ax.add_patch(Rectangle((Wd - OFF - 13.5, 0), 13.5, 25, fc="#5a5f66", ec="#333"))
    ax.text(Wd - OFF - 16, 14, "J5\nPS/2\n25 mm", ha="right", va="center", fontsize=8)
    pt = zt + T + info["PLATE"]
    ax.add_patch(Rectangle((0, zt + T), info["SEAM"], info["PLATE"], fc="#9aa0a8", ec="#444"))
    ax.add_patch(Rectangle((info["BAY"][2] + 0.5, pt - MX_PLATE_TO_PCB - PCB_T), info["BAY"][3] - info["BAY"][2] - 1,
                           PCB_T, fc="#111", ec="#000"))
    for k in range(5):
        y = info["BAY"][2] + 2.4 + k * 19.05
        ax.add_patch(Rectangle((y + 2.5, pt - 5), 14, 5 + 6.6, fc="#333", ec="none"))
        ax.add_patch(Polygon([(y + 0.6, pt + 6), (y + 18.4, pt + 6), (y + 16.4, pt + 14), (y + 2.6, pt + 14)],
                             fc="#666", ec="#333"))
    ax.add_patch(Rectangle((info["SEAM"], zt + T), Wd - info["SEAM"], info["ACRYLIC"], fc=ACR_C, ec="#2b7bb9"))
    ax.set_xlim(-10, Wd + 10)
    ax.set_ylim(zf - 6, pt + 20)
    ax.set_aspect("equal")
    ax.set_yticks([zf, 0, zs, zt + T, za, pt + 14])
    ax.set_yticklabels(["%.1f" % v for v in [zf, 0, zs, zt + T, za, pt + 14]], fontsize=8)
    ax.set_xticks([0, info["BAY"][2], info["BAY"][3], info["SEAM"], info["MAIN"][2], Wd])
    ax.set_xlabel("y from the front (mm); z from the board's top face (mm)", fontsize=9)
    ax.set_title("Section front to back: floor, 8 mm PEM standoffs, board, %.0f mm M3 standoffs to the top flange, "
                 "keyboard (plate on the flange) in front, acrylic top behind" % zt, fontsize=10, loc="left")
    fig.tight_layout()
    fig.savefig(path, dpi=100)
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
        "lower_shell": lower_shell(parts, cuts),
        "upper_shell": upper_shell(parts, cuts),
        "acrylic_top": acrylic_top(parts),
        "keyboard_blank": keyboard_blank(parts),
        "keyboard_plate": keyboard_plate(parts),
        "cart_cover": cart_cover(parts),
    }
    covers = slot_covers(parts)
    for i, c in enumerate(covers):
        solids["slot_cover_%d" % (i + 1)] = c
    os.makedirs(os.path.join(out, "dxf"), exist_ok=True)
    for name, s in solids.items():
        if name.startswith("slot_cover_") and name != "slot_cover_1":
            continue
        fn = "slot_cover" if name.startswith("slot_cover") else name
        cq.exporters.export(s, os.path.join(out, fn + ".step"))
    z0 = Z_TOP + T
    export_dxf(solids["acrylic_top"], z0 + ACRYLIC / 2, os.path.join(out, "dxf", "acrylic_top_4mm.dxf"))
    export_dxf(solids["keyboard_blank"], z0 + ACRYLIC / 2, os.path.join(out, "dxf", "keyboard_blank_4mm.dxf"))
    export_dxf(solids["keyboard_plate"], z0 + PLATE / 2, os.path.join(out, "dxf", "keyboard_plate_1.5mm.dxf"))
    export_dxf(covers[0], z0 + ACRYLIC / 2, os.path.join(out, "dxf", "slot_cover_plug_4mm.dxf"))
    export_dxf(covers[0], z0 + ACRYLIC + CAP / 2, os.path.join(out, "dxf", "slot_cover_cap_3mm.dxf"))
    export_dxf(solids["cart_cover"], z0 + ACRYLIC / 2, os.path.join(out, "dxf", "cart_cover_plug_4mm.dxf"))
    export_dxf(solids["cart_cover"], z0 + ACRYLIC + CAP / 2, os.path.join(out, "dxf", "cart_cover_cap_3mm.dxf"))

    info = dict(W=W, T=T, OFF=OFF, Z_FLOOR=Z_FLOOR, Z_SPLIT=Z_SPLIT, Z_TOP=Z_TOP, ACRYLIC=ACRYLIC, CAP=CAP,
                PLATE=PLATE, BAY=BAY, SEAM=SEAM, MAIN=MAIN, bay=bay, cart=cart, slot_x=slot_x,
                keys=key_positions(), top_screws=top_screws(parts), bay_screws=bay_screws(parts),
                cuts=[dict(ref=r, side=sd, u=u, z=z, zj=zj, prof=list(p), note=n)
                      for r, sd, u, z, zj, p, n in cuts],
                holes={k: hole_xy(parts, k) for k in parts if re.fullmatch(r"H\d+", k)})
    with open(os.path.join(out, "case_layout.json"), "w") as f:
        json.dump(info, f, indent=1)

    if drawings:
        draw_top(info, os.path.join(drawings, "case_top_view.png"))
        draw_walls(info, os.path.join(drawings, "case_walls.png"))
    if mesh:
        os.makedirs(mesh, exist_ok=True)
        for name, s in solids.items():
            cq.exporters.export(s, os.path.join(mesh, name + ".stl"), tolerance=0.05, angularTolerance=0.2)
        so = standoffs(parts)
        cq.exporters.export(cq.Workplane().add([x.val() for x in so]).combine(),
                            os.path.join(mesh, "standoffs.stl"))
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
    print("case %.1f x %.1f x %.1f mm (floor to acrylic top, feet extra)" %
          (W, W, Z_TOP + T + ACRYLIC - Z_FLOOR))

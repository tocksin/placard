#!/usr/bin/env python3
"""
Concept only (2026-10-30, not the case design): 3D-printed covers that clip to
the case with no magnets, for comparison with the magnet covers in gen_case.py.

Slot cover: the plug and cap as now, plus
  - a back lip down the outside of the back plate with a peg that goes into the
    slot's card screw hole (the hinge: hook the peg in first, then swing the
    front down), and
  - a snap finger on the plug's front face whose barb clicks under the front
    edge of the acrylic opening.
Cartridge cover: a snap finger on each side, barbs under the acrylic's side edges.

Writes STL meshes (covers + a top without magnet holes) for render_case.html
(V.snap) and a section drawing.  Run from the repo root after gen_case.py --mesh:
    python3 src/scripts/gen_cover_snap_concept.py
"""
import os
import cadquery as cq
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Polygon, Rectangle

import gen_case as g

FINGER_T = 1.6        # snap finger thickness (flexes in y or x)
FINGER_W = 12.0       # snap finger width
FINGER_L = 6.0        # below the acrylic's underside
BARB = 1.0            # barb reach under the acrylic
BARB_H = 2.0          # barb height (45-degree lead-in below its catch face)
CATCH = 0.2           # catch face below the acrylic's underside (acrylic 4.0 nominal, 3.6-4.4 cast)
LIP_T = 2.0           # back lip thickness
LIP_GAP = 0.2         # back lip to the back plate's outside face
PEG_D = 3.0           # into the 3.4 mm card screw hole
OUT = os.path.join(g.REPO, "src", "scripts", "case_render", "mesh_snap")


def box(x0, x1, y0, y1, z0, z1):
    return cq.Workplane("XY").box(x1 - x0, y1 - y0, z1 - z0, centered=False).translate((x0, y0, z0))


def barb_y(xc, y_face, sign):
    """A barb on a finger whose outer face is at y_face, reaching BARB in the
    direction sign (-1: toward -y), catch face at Z_TOP - CATCH, ramp below."""
    zc = g.Z_TOP - CATCH
    pts = [(y_face, zc), (y_face + sign * BARB, zc), (y_face, zc - BARB_H)]
    return (cq.Workplane("YZ").polyline(pts).close().extrude(FINGER_W)
            .translate((xc - FINGER_W / 2, 0, 0)))


def barb_x(yc, x_face, sign):
    zc = g.Z_TOP - CATCH
    pts = [(x_face, zc), (x_face + sign * BARB, zc), (x_face, zc - BARB_H)]
    return (cq.Workplane("XZ").polyline(pts).close().extrude(-FINGER_W)
            .translate((0, yc - FINGER_W / 2, 0)))


def snap_slot_covers(parts):
    bay, cart, slot_x = g.openings(parts)
    n = len(slot_x)
    pitch = (bay[1] - bay[0]) / n
    z0 = g.Z_TOP
    screws = g.card_screws(parts)
    out = []
    for i in range(n):
        x0, x1 = bay[0] + i * pitch + 0.2, bay[0] + (i + 1) * pitch - 0.2
        xc = (x0 + x1) / 2
        plug = g.rounded_plate(x0, x1, bay[2] + 0.2, g.D, z0, g.ACRYLIC)
        cap = g.rounded_plate(x0, x1, bay[2] - g.LIP, g.D + LIP_GAP + LIP_T, z0 + g.ACRYLIC, g.CAP)
        cap = cap.cut(g.hole(xc, bay[2] - g.LIP, 8.0, z0))
        s = plug.union(cap)
        # front snap finger, flexing back into the opening
        yf = bay[2] + 0.2
        s = s.union(box(xc - FINGER_W / 2, xc + FINGER_W / 2, yf, yf + FINGER_T, z0 - FINGER_L, z0))
        s = s.union(barb_y(xc, yf, -1))
        # back lip down the back plate's outside face, peg into the card screw hole
        sx, sz = screws[i]
        yl = g.D + LIP_GAP
        s = s.union(box(x0, x1, yl, yl + LIP_T, sz - 4.0, z0 + g.ACRYLIC))
        s = s.union(cq.Workplane("XZ").center(sx, sz).circle(PEG_D / 2).extrude(g.T + LIP_GAP)
                    .translate((0, yl, 0)))
        out.append(s)
    return out


def snap_cart_cover(parts):
    bay, cart, slot_x = g.openings(parts)
    z0 = g.Z_TOP
    plug = g.rounded_plate(cart[0] + 0.2, cart[1] - 0.2, cart[2] + 0.2, cart[3] - 0.2, z0, g.ACRYLIC, 0.8)
    cap = g.rounded_plate(cart[0] - g.LIP, cart[1] + g.LIP, cart[2] - g.LIP, cart[3] + g.LIP,
                          z0 + g.ACRYLIC, g.CAP, 3.0)
    cap = cap.cut(g.hole((cart[0] + cart[1]) / 2, cart[2] - g.LIP, 8.0, z0))
    s = plug.union(cap)
    yc = (cart[2] + cart[3]) / 2
    for xf, sign in ((cart[0] + 0.2, -1), (cart[1] - 0.2, 1)):
        xa = xf if sign < 0 else xf - FINGER_T
        s = s.union(box(xa, xa + FINGER_T, yc - FINGER_W / 2, yc + FINGER_W / 2, z0 - FINGER_L, z0))
        s = s.union(barb_x(yc, xf, sign))
    return s


def plain_top(parts):
    """The acrylic top with no magnet holes."""
    bay, cart, slot_x = g.openings(parts)
    z0 = g.Z_TOP
    s = g.rounded_plate(0, g.W, 0, g.D, z0, g.ACRYLIC, 3.0)
    s = s.cut(g.rounded_plate(bay[0], bay[1], bay[2], g.D + 1, z0 - 1, g.ACRYLIC + 2))
    s = s.cut(g.rounded_plate(cart[0], cart[1], cart[2], cart[3], z0 - 1, g.ACRYLIC + 2, 1.0))
    for ref in g.board_holes(parts):
        x, y = g.hole_xy(parts, ref)
        s = s.cut(g.hole(x, y, 3.4, z0 - 1))
    return s


def draw_section(parts, path):
    """Side sections: a slot cover through its peg (y-z) and the cartridge cover
    through its fingers (x-z)."""
    bay, cart, slot_x = g.openings(parts)
    zt, a, c = g.Z_TOP, g.ACRYLIC, g.CAP
    zc = zt - CATCH
    acr = dict(fc="#cfe6f7", ec="#4a86b0", lw=1.2)
    cov = dict(fc="#3a3d42", ec="black", lw=1.2)
    alu = dict(fc="#8a9099", ec="black", lw=1.2)
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(16, 5.2), gridspec_kw=dict(width_ratios=[1.75, 1]))

    # slot cover, section at its peg (looking from the right)
    yf, D, T = bay[2], g.D, g.T
    ax1.add_patch(Rectangle((yf - 30, zt), 30, a, **acr))
    ax1.add_patch(Rectangle((D - T, zt - 25), T, 25, **alu))
    sz = g.CARD_SCREW_Z
    ax1.add_patch(Rectangle((D - T - 0.01, sz - 1.7), T + 0.02, 3.4, fc="white", ec="none"))
    yl = D + LIP_GAP
    outline = [
        (yf - g.LIP, zt + a + c), (yl + LIP_T, zt + a + c), (yl + LIP_T, sz - 4), (yl, sz - 4),
        (yl, sz - PEG_D / 2), (D - T, sz - PEG_D / 2), (D - T, sz + PEG_D / 2), (yl, sz + PEG_D / 2),
        (yl, zt), (D, zt), (D, zt), (D - T, zt), (D - T, zt),
        (yf + 0.2 + FINGER_T, zt), (yf + 0.2 + FINGER_T, zt - FINGER_L), (yf + 0.2, zt - FINGER_L),
        (yf + 0.2, zc - BARB_H), (yf + 0.2 - BARB, zc), (yf + 0.2, zc), (yf + 0.2, zt + a),
        (yf - g.LIP, zt + a)]
    ax1.add_patch(Polygon(outline, **cov))
    ax1.annotate("barb clicks under the\nacrylic's front edge", (yf - 0.6, zc - 0.3), (yf - 26, zt - 12),
                 arrowprops=dict(arrowstyle="->"), fontsize=11)
    ax1.annotate("finger flexes back\nto let it in and out", (yf + 1.5, zt - 4), (yf + 12, zt - 14),
                 arrowprops=dict(arrowstyle="->"), fontsize=11)
    ax1.annotate("peg in the card\nscrew hole (hinge)", (D - 0.5, sz), (D - 36, sz - 4),
                 arrowprops=dict(arrowstyle="->"), fontsize=11)
    ax1.annotate("lip down the back plate", (yl + LIP_T, zt - 3), (D - 40, zt + a + c + 6),
                 arrowprops=dict(arrowstyle="->"), fontsize=11)
    ax1.text(yf - 22, zt + a / 2, "acrylic top", va="center", fontsize=11)
    ax1.text(D - T - 1, zt - 22, "back\nplate", ha="right", fontsize=11)
    ax1.text((yf + D) / 2, zt + a + c + 1.2, "slot cover (printed, one piece)", ha="center", fontsize=11)
    ax1.set_xlim(yf - 32, D + 10)
    ax1.set_ylim(sz - 8, zt + a + c + 10)
    ax1.set_title("Slot cover, section through the peg (front at left)", fontsize=13)

    # cartridge cover, section across its fingers (looking from the front)
    x0, x1 = cart[0], cart[1]
    ax2.add_patch(Rectangle((x0 - 18, zt), 18, a, **acr))
    ax2.add_patch(Rectangle((x1, zt), 18, a, **acr))
    out = [(x0 - g.LIP, zt + a + c), (x1 + g.LIP, zt + a + c), (x1 + g.LIP, zt + a), (x1 - 0.2, zt + a),
           (x1 - 0.2, zc), (x1 - 0.2 + BARB, zc), (x1 - 0.2, zc - BARB_H), (x1 - 0.2, zt - FINGER_L),
           (x1 - 0.2 - FINGER_T, zt - FINGER_L), (x1 - 0.2 - FINGER_T, zt),
           (x0 + 0.2 + FINGER_T, zt), (x0 + 0.2 + FINGER_T, zt - FINGER_L), (x0 + 0.2, zt - FINGER_L),
           (x0 + 0.2, zc - BARB_H), (x0 + 0.2 - BARB, zc), (x0 + 0.2, zc), (x0 + 0.2, zt + a),
           (x0 - g.LIP, zt + a)]
    ax2.add_patch(Polygon(out, **cov))
    ax2.text((x0 + x1) / 2, zt + a + c + 1.2, "cartridge cover", ha="center", fontsize=11)
    ax2.annotate("a snap finger\neach side", (x0 + 1.5, zt - 4), ((x0 + x1) / 2 - 9, zt - 14),
                 arrowprops=dict(arrowstyle="->"), fontsize=11)
    ax2.set_xlim(x0 - 18, x1 + 18)
    ax2.set_ylim(sz - 8, zt + a + c + 10)
    ax2.set_title("Cartridge cover, section across (front view)", fontsize=13)
    for ax in (ax1, ax2):
        ax.set_aspect("equal")
        ax.set_xlabel("mm")
        ax.grid(alpha=0.25)
    fig.suptitle("CONCEPT: printed snap covers, no magnets (barb catch 0.2 mm below 4 mm acrylic)", fontsize=14)
    fig.tight_layout()
    fig.savefig(path, dpi=110, bbox_inches="tight")


def main():
    parts = g.read_board(os.path.join(g.REPO, "kicad", "placard.kicad_pcb"))
    os.makedirs(OUT, exist_ok=True)
    solids = {"acrylic_top": plain_top(parts), "cart_cover": snap_cart_cover(parts)}
    for i, s in enumerate(snap_slot_covers(parts)):
        solids["slot_cover_%d" % (i + 1)] = s
    for name, s in solids.items():
        cq.exporters.export(s, os.path.join(OUT, name + ".stl"), tolerance=0.05, angularTolerance=0.2)
    # lifted copies, for the views that show how a cover goes on
    for name in ("slot_cover_3", "cart_cover"):
        cq.exporters.export(solids[name].translate((0, 0, 30)), os.path.join(OUT, name + "_lifted.stl"),
                            tolerance=0.05, angularTolerance=0.2)
    draw_section(parts, os.path.join(g.REPO, "src", "scripts", "case_render", "out", "snap_section.png"))
    print("wrote", OUT)


if __name__ == "__main__":
    main()

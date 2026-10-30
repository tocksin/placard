#!/usr/bin/env python3
"""
Screws, standoffs, PEM inserts and feet of the case (docs/CASE.md parts list),
as STL meshes for render_case.html (V.hardware), at their assembled positions.
The page moves each group with the part it belongs to for exploded views.
Also draws docs/case_hardware_stacks.png (each fastener stack, exploded).
Run after gen_case.py --mesh (same mesh folder):
    python3 src/scripts/case_render/gen_case_hardware.py
"""
import math
import os
import sys

import cadquery as cq

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import gen_case as g  # noqa: E402

MESH = os.path.join(HERE, "mesh")


def hex_prism(x, y, z0, h, af=5.5):
    return cq.Workplane("XY").center(x, y).polygon(6, af / math.cos(math.pi / 6)).extrude(h).translate((0, 0, z0))


def cyl(x, y, z0, h, d):
    return cq.Workplane("XY").center(x, y).circle(d / 2).extrude(h).translate((0, 0, z0))


def button_screw(x, y, z, length):
    """ISO 7380 M3 button head (head 5.7 x 1.65) on a surface at z, shank down."""
    head = cyl(x, y, z, 1.65, 5.7).edges(">Z").fillet(1.0)
    return head.union(cyl(x, y, z - length, length, 3.0))


def csk_screw(x, y, z, length):
    """ISO 10642 M3 countersunk (head 6.0, 90 degrees) flush on z, shank up."""
    head = (cq.Workplane("XY").center(x, y).circle(3.0).workplane(offset=1.5).circle(1.5).loft()
            .translate((0, 0, z)))
    return head.union(cyl(x, y, z, length, 3.0))


def card_screw(x, z):
    """M3 x 6 button head, through the back plate into a card shell (pointing -y)."""
    s = button_screw(0, 0, 0, 6.0)                      # head up, shank down
    return s.rotate((0, 0, 0), (1, 0, 0), -90).translate((x, g.D, z))     # head out the back


def combine(solids):
    return cq.Workplane().add([s.val() for s in solids]).combine()


def main():
    parts = g.read_board(os.path.join(g.REPO, "kicad", "placard.kicad_pcb"))
    holes = g.board_hole_xys(parts)
    zf, T = g.Z_FLOOR, g.T
    flange_top = zf + 2 * T
    groups = {
        # PEM SO-M3-6 pressed into the floor: 6 mm from the floor's top to the board's underside
        "hw_pem_standoffs": [cyl(x, y, zf + T, g.STANDOFF, 5.4).union(cyl(x, y, zf, T, 4.2)) for x, y in holes],
        # M3 male-female hex standoff, 27 mm: board top to the acrylic, its thread down into the PEM standoff
        "hw_hex_standoffs": [hex_prism(x, y, 0, g.Z_TOP).union(cyl(x, y, -g.PCB_T - 4.0, g.PCB_T + 4.0, 3.0))
                             for x, y in holes],
        # M3 x 8 button head through the acrylic into the hex standoffs
        "hw_top_screws": [button_screw(x, y, g.Z_TOP + g.ACRYLIC, 8.0) for x, y in holes],
        # rubber feet
        "hw_feet": [cyl(x, y, g.Z_DESK, g.FEET, g.FOOT_D) for x, y in g.feet()],
    }
    screws = g.plate_screws()
    for side, pts in (("back", screws[:3]), ("left", screws[3:])):
        # M3 x 6 countersunk up through the floor; PEM CLS-M3-1 nut in the flange
        groups["hw_csk_" + side] = [csk_screw(x, y, zf, 6.0) for x, y in pts]
        groups["hw_nuts_" + side] = [cyl(x, y, flange_top, 1.5, 6.35).cut(cyl(x, y, flange_top - 1, 3, 3.0))
                                     for x, y in pts]
    groups["hw_card_screws"] = [card_screw(x, z) for x, z in g.card_screws(parts)]
    for name, sol in groups.items():
        cq.exporters.export(combine(sol), os.path.join(MESH, name + ".stl"), tolerance=0.02, angularTolerance=0.2)
    print("wrote", ", ".join(groups))
    draw_stacks(os.path.join(g.REPO, "docs", "case_hardware_stacks.png"))



def draw_stacks(path):
    """The three fastener stacks, exploded along their axes, side views to scale."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import Polygon, Rectangle
    alu = dict(fc="#2c2e33", ec="black", lw=1)
    acr = dict(fc="#cfe6f7", ec="#4a86b0", lw=1)
    pcb = dict(fc="#2f7a4a", ec="black", lw=1)
    steel = dict(fc="#b8bcc2", ec="black", lw=1)
    brass = dict(fc="#d4b25a", ec="black", lw=1)
    blk = dict(fc="#3a3a3c", ec="black", lw=1)
    fig, axs = plt.subplots(1, 3, figsize=(16, 8.5), gridspec_kw=dict(width_ratios=[1.2, 1, 1]))
    kw = dict(fontsize=11, va="center")

    def rect(ax, x0, z0, w, h, st):
        ax.add_patch(Rectangle((x0, z0), w, h, **st))

    def label(ax, x, z, t):
        ax.text(x, z, t, **kw)

    def screw_button(ax, z, length, st=blk):          # head on z, shank down
        rect(ax, -1.5, z - length, 3, length, st)
        ax.add_patch(Polygon([(-2.85, z), (2.85, z), (2.2, z + 1.4), (-2.2, z + 1.4)], **st))

    # A: the board stack at H1-H8 (gaps are the explode)
    ax = axs[0]
    z = 0.0
    rect(ax, -14, z, 28, 2, alu); rect(ax, -2.1, z - 0.01, 4.2, 2.02, steel)
    rect(ax, -2.7, z + 2, 5.4, 6, steel); rect(ax, -0.9, z + 3, 1.8, 5, dict(fc="white", ec="none"))
    label(ax, 16, z + 0.5, "Tray floor, 2 mm")
    label(ax, 16, z + 8, "PEM SO-M3-6 standoff (8),\npressed in by the sheet-metal shop")
    z = 14.0
    rect(ax, -14, z, 28, 1.6, pcb); rect(ax, -1.6, z - 0.01, 3.2, 1.62, dict(fc="white", ec="none"))
    label(ax, 16, z + 0.8, "Main board, 1.6 mm (H1-H8)")
    z = 22.0
    rect(ax, -1.5, z, 3, 6, brass); rect(ax, -2.75, z + 6, 5.5, 27, brass)
    label(ax, 16, z + 18, "M3 x 27 male-female hex standoff (8):\nits stud goes through the board\ninto the PEM standoff")
    z = 62.0
    rect(ax, -14, z, 28, 4, acr); rect(ax, -1.7, z - 0.01, 3.4, 4.02, dict(fc="white", ec="none"))
    label(ax, 16, z + 2, "Acrylic top, 4 mm")
    screw_button(ax, 78.0, 8.0)
    label(ax, 16, 75, "M3 x 8 button head screw (8)")
    ax.plot([0, 0], [-3, 82], ls="--", lw=0.8, color="#888")
    ax.set_xlim(-16, 62); ax.set_ylim(-4, 84)
    ax.set_title("At each board hole (8 places)", fontsize=13)

    # B: plate flange screws, from below
    ax = axs[1]
    rect(ax, -12, 30, 24, 2, alu); rect(ax, -2.1, 29.99, 4.2, 2.02, steel)
    ax.add_patch(Rectangle((-3.2, 32), 6.4, 1.5, **steel)); rect(ax, -1.5, 30, 3, 3.5, dict(fc="white", ec="none"))
    label(ax, 14, 31.8, "Plate flange, 2 mm, with a\nPEM CLS-M3-1 nut pressed in (6)")
    rect(ax, -12, 18, 24, 2, alu)
    ax.add_patch(Polygon([(-3.6, 18), (3.6, 18), (1.6, 20), (-1.6, 20)], fc="white", ec="black", lw=0.8))
    label(ax, 14, 19, "Tray floor, 2 mm, countersunk")
    ax.add_patch(Polygon([(-3, 4), (3, 4), (1.5, 5.5), (-1.5, 5.5)], **steel)); rect(ax, -1.5, 5.5, 3, 4.5, steel)
    label(ax, 14, 7, "M3 x 6 countersunk screw (6),\nup from under the case")
    ax.plot([0, 0], [2, 36], ls="--", lw=0.8, color="#888")
    ax.set_xlim(-14, 60); ax.set_ylim(-4, 84)
    ax.set_title("Plates to the floor (6 places)", fontsize=13)

    # C: expansion card screws, through the back plate (drawn turned up)
    ax = axs[2]
    rect(ax, -12, 40, 24, 8, dict(fc="#3a4048", ec="black", lw=1)); rect(ax, -2.0, 40, 4.0, 5, brass)
    label(ax, 14, 44, "Expansion card shell, with an\nM3 heat-set insert in its back end")
    rect(ax, -12, 28, 24, 2, alu); rect(ax, -1.7, 27.99, 3.4, 2.02, dict(fc="white", ec="none"))
    label(ax, 14, 29, "Back plate, 2 mm")
    rect(ax, -1.5, 14, 3, 6, blk)
    ax.add_patch(Polygon([(-2.85, 14), (2.85, 14), (2.2, 12.6), (-2.2, 12.6)], **blk))
    label(ax, 14, 16, "M3 x 6 button head screw (4),\none per card fitted")
    ax.plot([0, 0], [10, 50], ls="--", lw=0.8, color="#888")
    ax.text(0, 56, "(seen from above: the screw\npoints forward into the card)", ha="center", fontsize=10, color="#555")
    ax.set_xlim(-14, 60); ax.set_ylim(-4, 84)
    ax.set_title("Card screws (up to 4)", fontsize=13)

    for ax in axs:
        ax.set_aspect("equal"); ax.axis("off")
    fig.text(0.5, 0.1, "Also: 4 rubber feet (16 mm across, 10 mm tall, self-adhesive), 24 mm in from the corners. "
             "VGA J7's own 4-40 jackscrews hold the back plate too.", ha="center", fontsize=11)
    fig.suptitle("Case fasteners, exploded along each axis (to scale, mm)", fontsize=15)
    fig.savefig(path, dpi=110, bbox_inches="tight")


if __name__ == "__main__":
    main()

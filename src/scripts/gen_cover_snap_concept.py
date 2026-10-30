#!/usr/bin/env python3
"""
Concept only (2026-10-30, not the case design): 3D-printed covers held by
pull-off detents, no magnets, for comparison with the magnet covers in gen_case.py.

Justin's idea: a small rectangular slot in the acrylic under each cover's cap,
and a tab on the cap that drops into it with a rounded bump that clicks just
past the acrylic's underside.  It holds the cover, and a little pull lifts it
straight off (the bump's round top pushes the tab aside), all from above.
Slot cover: two tabs in its front lap (where the magnets were); at the back,
where there's no acrylic, a lip down the back plate with a dome that clicks
into the slot's card screw hole.
Cartridge cover: two tabs in its front lap and two in its back lap.

Writes STL meshes (covers + the top with the detent slots instead of magnet
holes) for render_case.html (V.snap) and a section drawing.  Run from the repo
root after gen_case.py --mesh:
    python3 src/scripts/gen_cover_snap_concept.py
"""
import math
import os
import cadquery as cq
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Circle, Polygon, Rectangle

import gen_case as g

TAB_W = 6.0           # detent tab width
TAB_T = 1.8           # detent tab thickness (flexes to let the bump by)
TAB_BELOW = 2.2       # tab end below the acrylic's underside
SLOT_CLR = 0.2        # tab to slot wall, each side: slot 6.4 x 2.2 in the acrylic
BUMP_R = 1.0          # bump: a rounded rib across the tab, its top level with the acrylic's underside
BUMP = 0.6            # bump height off the tab face (0.4 under the acrylic past the slot clearance)
LIP_T = 2.0           # slot cover's back lip
LIP_GAP = 0.2         # back lip to the back plate's outside face
DOME_R = 2.5          # back lip's dome; it sits on the 3.4 mm card screw hole's rim
CART_TAB_DX = 12.0    # cartridge cover tabs, either side of its centre (clear of the finger notch)
OUT = os.path.join(g.REPO, "src", "scripts", "case_render", "mesh_snap")


def box(x0, x1, y0, y1, z0, z1):
    return cq.Workplane("XY").box(x1 - x0, y1 - y0, z1 - z0, centered=False).translate((x0, y0, z0))


def detent_spots(parts):
    """(x, y, sign) of every tab: its slot centre, and which way (+-y) its bump faces."""
    bay, cart, slot_x = g.openings(parts)
    n = len(slot_x)
    spots = [(x, y, -1) for x, y in g.slot_magnets(parts)[:2 * n]]
    xc = (cart[0] + cart[1]) / 2
    for dx in (-CART_TAB_DX, CART_TAB_DX):
        spots += [(xc + dx, cart[2] - g.LIP / 2, -1), (xc + dx, cart[3] + g.LIP / 2, 1)]
    return spots


def tab(x, y, sign):
    """A tab hanging from the cap's underside through its slot, with a rounded
    rib across its outer face (sign: +-y) just below the acrylic."""
    zt = g.Z_TOP
    s = box(x - TAB_W / 2, x + TAB_W / 2, y - TAB_T / 2, y + TAB_T / 2, zt - TAB_BELOW, zt + g.ACRYLIC)
    yb = y + sign * (TAB_T / 2 + BUMP - BUMP_R)
    rib = (cq.Workplane("YZ").center(yb, zt - BUMP_R).circle(BUMP_R).extrude(TAB_W)
           .translate((x - TAB_W / 2, 0, 0)))
    return s.union(rib.intersect(box(x - TAB_W / 2, x + TAB_W / 2, y - 5, y + 5, zt - TAB_BELOW, zt)))


def dome_y():
    """y of the back lip dome's centre: its sphere meets the card screw hole's rim."""
    return g.D + math.sqrt(DOME_R ** 2 - 1.7 ** 2)


def snap_slot_covers(parts):
    bay, cart, slot_x = g.openings(parts)
    n = len(slot_x)
    pitch = (bay[1] - bay[0]) / n
    z0 = g.Z_TOP
    screws = g.card_screws(parts)
    spots = detent_spots(parts)
    out = []
    for i in range(n):
        x0, x1 = bay[0] + i * pitch + 0.2, bay[0] + (i + 1) * pitch - 0.2
        xc = (x0 + x1) / 2
        plug = g.rounded_plate(x0, x1, bay[2] + 0.2, g.D, z0, g.ACRYLIC)
        cap = g.rounded_plate(x0, x1, bay[2] - g.LIP, g.D + LIP_GAP + LIP_T, z0 + g.ACRYLIC, g.CAP)
        cap = cap.cut(g.hole(xc, bay[2] - g.LIP, 8.0, z0))
        s = plug.union(cap)
        for x, y, sign in spots[2 * i:2 * i + 2]:
            s = s.union(tab(x, y, sign))
        # back lip down the back plate's outside face, its dome clicks into the card screw hole
        sx, sz = screws[i]
        yl = g.D + LIP_GAP
        s = s.union(box(x0, x1, yl, yl + LIP_T, sz - 4.0, z0 + g.ACRYLIC))
        dome = cq.Workplane("XY").sphere(DOME_R).translate((sx, dome_y(), sz))
        s = s.union(dome.intersect(box(sx - 3, sx + 3, g.D - 2, yl + 0.01, sz - 3, sz + 3)))
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
    for x, y, sign in detent_spots(parts)[-4:]:
        s = s.union(tab(x, y, sign))
    return s


def plain_top(parts):
    """The acrylic top with a detent slot at each tab instead of the magnet holes."""
    bay, cart, slot_x = g.openings(parts)
    z0 = g.Z_TOP
    s = g.rounded_plate(0, g.W, 0, g.D, z0, g.ACRYLIC, 3.0)
    s = s.cut(g.rounded_plate(bay[0], bay[1], bay[2], g.D + 1, z0 - 1, g.ACRYLIC + 2))
    s = s.cut(g.rounded_plate(cart[0], cart[1], cart[2], cart[3], z0 - 1, g.ACRYLIC + 2, 1.0))
    for ref in g.board_holes(parts):
        x, y = g.hole_xy(parts, ref)
        s = s.cut(g.hole(x, y, 3.4, z0 - 1))
    for x, y, sign in detent_spots(parts):
        w, t = TAB_W / 2 + SLOT_CLR, TAB_T / 2 + SLOT_CLR
        s = s.cut(box(x - w, x + w, y - t, y + t, z0 - 1, z0 + g.ACRYLIC + 1))
    return s


def _tab_patches(ax, y, sign, style):
    zt = g.Z_TOP
    ax.add_patch(Rectangle((y - TAB_T / 2, zt - TAB_BELOW), TAB_T, TAB_BELOW + g.ACRYLIC + 0.05, **style))
    ax.add_patch(Circle((y + sign * (TAB_T / 2 + BUMP - BUMP_R), zt - BUMP_R), BUMP_R, **style))


def _acrylic_with_slot(ax, y0, y1, ys, style):
    """Acrylic from y0 to y1 with a detent slot centred on ys."""
    t = TAB_T / 2 + SLOT_CLR
    ax.add_patch(Rectangle((y0, g.Z_TOP), ys - t - y0, g.ACRYLIC, **style))
    ax.add_patch(Rectangle((ys + t, g.Z_TOP), y1 - ys - t, g.ACRYLIC, **style))


def draw_section(parts, path):
    """Side sections (front at left): a slot cover through a front tab, with its
    back lip dome, and the cartridge cover through its front and back tabs."""
    bay, cart, slot_x = g.openings(parts)
    zt, a, c = g.Z_TOP, g.ACRYLIC, g.CAP
    acr = dict(fc="#cfe6f7", ec="#4a86b0", lw=1.0)
    cov = dict(fc="#5f6874", ec="none")
    alu = dict(fc="#2c2e33", ec="black", lw=1.0)
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(16, 5.6), gridspec_kw=dict(width_ratios=[1.75, 1]))
    kw = dict(arrowprops=dict(arrowstyle="->"), fontsize=11)

    # slot cover
    yf, D, T, sz = bay[2], g.D, g.T, g.CARD_SCREW_Z
    ys = yf - g.LIP / 2
    _acrylic_with_slot(ax1, yf - 30, yf, ys, acr)
    ax1.add_patch(Rectangle((D - T, sz + 1.7), T, zt - sz - 1.7, **alu))
    ax1.add_patch(Rectangle((D - T, sz - 10), T, 10 - 1.7, **alu))
    yl = D + LIP_GAP
    ax1.add_patch(Rectangle((yf - g.LIP, zt + a), D + LIP_GAP + LIP_T - (yf - g.LIP), c, **cov))
    ax1.add_patch(Rectangle((yf + 0.2, zt), D - yf - 0.2, a + 0.05, **cov))
    ax1.add_patch(Rectangle((yl, sz - 4), LIP_T, zt + a - sz + 4.05, **cov))
    yd = dome_y()
    th = [math.pi / 2 + k * math.pi / 40 for k in range(41)]
    dome = [(yd + DOME_R * math.cos(t), sz + DOME_R * math.sin(t)) for t in th]
    ax1.add_patch(Polygon([(min(y, yl + 0.05), z) for y, z in dome], **cov))
    _tab_patches(ax1, ys, -1, cov)
    ax1.annotate("tab through a small slot;\nits round bump clicks past\nthe acrylic's underside", (ys - 1.2, zt - 1.0),
                 (yf - 30, zt - 15), **kw)
    ax1.annotate("dome clicks into the\ncard screw hole", (D - 0.3, sz), (D - 38, sz - 2), **kw)
    ax1.annotate("lip down the back plate", (yl + LIP_T, zt - 3), (D - 40, zt + a + c + 6), **kw)
    ax1.annotate("pull up here (finger notch)", (yf - g.LIP + 0.5, zt + a + c), (yf - 31, zt + a + c + 6), **kw)
    ax1.text(yf - 26, zt + a / 2, "acrylic top", va="center", fontsize=11)
    ax1.text(D - T - 1, sz - 9, "back\nplate", ha="right", fontsize=11)
    ax1.text((yf + D) / 2, zt + a + c + 1.2, "slot cover (printed, one piece)", ha="center", fontsize=11)
    # close-up of the tab
    ins = ax1.inset_axes([0.30, 0.04, 0.30, 0.50])
    _acrylic_with_slot(ins, yf - 12, yf, ys, acr)
    ins.add_patch(Rectangle((yf - g.LIP, zt + a), 12, c, **cov))
    ins.add_patch(Rectangle((yf + 0.2, zt), 4, a + 0.05, **cov))
    _tab_patches(ins, ys, -1, cov)
    ins.set_xlim(ys - 5, ys + 5)
    ins.set_ylim(zt - 3.5, zt + a + c + 0.8)
    ins.set_aspect("equal")
    ins.set_xticks([])
    ins.set_yticks([])
    ins.set_title("tab, 5x", fontsize=10)
    ax1.set_xlim(yf - 32, D + 10)
    ax1.set_ylim(sz - 10, zt + a + c + 10)
    ax1.set_title("Slot cover, section through a tab (front at left)", fontsize=13)

    # cartridge cover
    y0, y1 = cart[2], cart[3]
    yfront, yback = y0 - g.LIP / 2, y1 + g.LIP / 2
    _acrylic_with_slot(ax2, y0 - 16, y0, yfront, acr)
    _acrylic_with_slot(ax2, y1, y1 + 16, yback, acr)
    ax2.add_patch(Rectangle((y0 - g.LIP, zt + a), y1 - y0 + 2 * g.LIP, c, **cov))
    ax2.add_patch(Rectangle((y0 + 0.2, zt), y1 - y0 - 0.4, a + 0.05, **cov))
    _tab_patches(ax2, yfront, -1, cov)
    _tab_patches(ax2, yback, 1, cov)
    ax2.text((y0 + y1) / 2, zt + a + c + 1.2, "cartridge cover", ha="center", fontsize=11)
    ax2.annotate("two tabs front,\ntwo back", (yback + 1.2, zt - 1.5), ((y0 + y1) / 2 - 6, zt - 13), **kw)
    ax2.set_xlim(y0 - 16, y1 + 16)
    ax2.set_ylim(sz - 10, zt + a + c + 10)
    ax2.set_title("Cartridge cover, section through its tabs (front at left)", fontsize=13)
    for ax in (ax1, ax2):
        ax.set_aspect("equal")
        ax.set_xlabel("mm")
        ax.grid(alpha=0.25)
    fig.suptitle("CONCEPT: printed covers with pull-off detents, no magnets "
                 "(bump 0.4 mm under 4 mm acrylic; slots 6.4 x 2.2 mm)", fontsize=14)
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

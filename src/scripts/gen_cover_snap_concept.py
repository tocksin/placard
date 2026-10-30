#!/usr/bin/env python3
"""
Concept only (2026-10-30, not the case design): 3D-printed covers held by
pull-off detents, no magnets, for comparison with the magnet covers in gen_case.py.

Justin's idea: a small rectangular slot in the acrylic under each cover's cap,
and a tab on the cap that drops into it with a rounded bump that clicks just
past the acrylic's underside.  It holds the cover, and a little pull lifts it
straight off (the bump's round top pushes the tab aside), all from above.
Slot cover: two tabs in its front lap (where the magnets were); at the back,
where there's no acrylic, a lip down the back plate's outside face with a dome
that clicks into the slot's card screw hole.
Cartridge cover: two tabs in its front lap and two in its back lap.

Parking (Justin): the covers click into slots in the floor from below, upside
down, plug against the floor.  The floor is 2 mm, not 4, so each tab has a
second bump 2 mm further down, on its other face: on the top it hangs free
below the acrylic; parked it catches on the floor's top face, and the floor
slot is wider on the first bump's side so that one passes through.  Upside
down the slot cover's lip points up the back plate, and its dome clicks into a
second hole near the plate's bottom (PARK_HOLE_Z), so the back end can't sag.

Writes STL meshes (covers in place and parked, the top with the detent slots
instead of magnet holes, the tray with the parking slots instead of the steel
discs, the back plate with the parking holes; all the metal with its bends,
from gen_case_quote.py) for render_case.html (V.snap) and a section drawing.  Run from the repo
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
import gen_case_quote as q

TAB_W = 6.0           # detent tab width
TAB_T = 1.8           # detent tab thickness (flexes to let a bump by)
SLOT_CLR = 0.2        # tab to slot wall, each side: slot 6.4 x 2.2 in the acrylic
BUMP_R = 1.0          # bumps: rounded ribs across the tab
BUMP = 0.6            # bump height off the tab face (0.4 past the slot clearance)
PARK_DROP = g.ACRYLIC - g.T    # second bump this much below the first (4 mm acrylic vs 2 mm floor)
TAB_BELOW = PARK_DROP + 2 * BUMP_R + 0.2   # tab end below the acrylic's underside
LIP_T = 2.0           # slot cover's back lip
LIP_GAP = 0.2         # back lip to the back plate's outside face
DOME_R = 2.5          # back lip's dome; it sits on a 3.4 mm hole's rim
CART_TAB_DX = 12.0    # cartridge cover tabs, either side of its centre (clear of the finger notch)
OUT = os.path.join(g.REPO, "src", "scripts", "case_render", "mesh_snap")


def box(x0, x1, y0, y1, z0, z1):
    return cq.Workplane("XY").box(x1 - x0, y1 - y0, z1 - z0, centered=False).translate((x0, y0, z0))


def detent_spots(parts):
    """(x, y, sign) of every tab: its slot centre, and which way (+-y) its upper bump faces."""
    bay, cart, slot_x = g.openings(parts)
    n = len(slot_x)
    spots = [(x, y, -1) for x, y in g.slot_magnets(parts)[:2 * n]]
    xc = (cart[0] + cart[1]) / 2
    for dx in (-CART_TAB_DX, CART_TAB_DX):
        spots += [(xc + dx, cart[2] - g.LIP / 2, -1), (xc + dx, cart[3] + g.LIP / 2, 1)]
    return spots


def bumps(y, sign):
    """(y centre, z top) of a tab's two bumps, as on the top: the upper one on
    its sign face just below the acrylic, the lower one on the other face."""
    zt = g.Z_TOP
    return [(y + sd * (TAB_T / 2 + BUMP - BUMP_R), ztop)
            for sd, ztop in ((sign, zt), (-sign, zt - PARK_DROP))]


def tab(x, y, sign):
    """A tab hanging from the cap's underside through its slot, with its two bumps."""
    zt = g.Z_TOP
    s = box(x - TAB_W / 2, x + TAB_W / 2, y - TAB_T / 2, y + TAB_T / 2, zt - TAB_BELOW, zt + g.ACRYLIC)
    for yb, ztop in bumps(y, sign):
        s = s.union(cq.Workplane("YZ").center(yb, ztop - BUMP_R).circle(BUMP_R).extrude(TAB_W)
                    .translate((x - TAB_W / 2, 0, 0)))
    return s.intersect(box(x - TAB_W / 2, x + TAB_W / 2, y - 5, y + 5, zt - TAB_BELOW, zt + g.ACRYLIC))


def floor_slot(y, sign):
    """(y0, y1) of a parking slot in the floor: the upper bump (sign side) passes
    through, the lower one catches on the far wall's top edge."""
    a = y + sign * (TAB_T / 2 + BUMP + SLOT_CLR)
    b = y - sign * (TAB_T / 2 + SLOT_CLR)
    return min(a, b), max(a, b)


def dome_y():
    """y of the back lip dome's centre: its sphere meets a 3.4 mm hole's rim."""
    return g.D + math.sqrt(DOME_R ** 2 - 1.7 ** 2)


def snap_slot_covers(parts):
    bay, cart, slot_x = g.openings(parts)
    n = len(slot_x)
    pitch = (bay[1] - bay[0]) / n
    z0 = g.Z_TOP
    spots = detent_spots(parts)
    screws = g.card_screws(parts)
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


def park_z(z):
    """z on the top -> z parked: upside down, the plug's face (Z_TOP) on the floor's underside."""
    return g.Z_FLOOR + g.Z_TOP - z


def parked(solid):
    return solid.mirror("XY").translate((0, 0, park_z(0)))


PARK_HOLE_Z = park_z(g.CARD_SCREW_Z)   # the parking hole in the back plate, 2.4 above the board's top


def snap_back_plate(parts):
    """The back plate with a parking hole under each card screw hole, for the
    parked slot covers' domes."""
    s = q.plate_parts(parts, g.wall_cutouts(parts), "back")[1]     # bent, R2 inside
    for x, z in g.card_screws(parts):
        s = s.cut(cq.Workplane("XZ").center(x, PARK_HOLE_Z).circle(1.7).extrude(-10)
                  .translate((0, g.D - g.T - 1, 0)))
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


def snap_tray(parts):
    """The tray with a parking slot at each tab instead of the steel disc holes."""
    keep = g.slot_magnets
    g.slot_magnets = lambda p: []
    try:
        s = q.tray_parts(parts, g.wall_cutouts(parts))[1]     # bent, R2 inside
    finally:
        g.slot_magnets = keep
    w = TAB_W / 2 + SLOT_CLR
    for x, y, sign in detent_spots(parts):
        y0, y1 = floor_slot(y, sign)
        s = s.cut(box(x - w, x + w, y0, y1, g.Z_FLOOR - 1, g.Z_FLOOR + g.T + 1))
    return s


def _tab_patches(ax, y, sign, style, flip=False, dz=0.0):
    """A tab in section; flip: parked upside down."""
    zt = g.Z_TOP
    f = (lambda z: park_z(z) + dz) if flip else (lambda z: z + dz)
    z0, z1 = sorted((f(zt - TAB_BELOW), f(zt + g.ACRYLIC + 0.05)))
    ax.add_patch(Rectangle((y - TAB_T / 2, z0), TAB_T, z1 - z0, **style))
    for yb, ztop in bumps(y, sign):
        ax.add_patch(Circle((yb, f(ztop - BUMP_R)), BUMP_R, **style))


def _back_patches(ax, cov, alu, flip, ztop_plate):
    """The back plate (from the floor's top to ztop_plate) with its two holes,
    and the slot cover's back lip and dome, on the top or parked (flip)."""
    D, T, sz = g.D, g.T, g.CARD_SCREW_Z
    f = park_z if flip else (lambda z: z)
    edges = [g.Z_FLOOR + T, PARK_HOLE_Z - 1.7, PARK_HOLE_Z + 1.7, sz - 1.7, sz + 1.7, ztop_plate]
    for z0, z1 in zip(edges[::2], edges[1::2]):
        ax.add_patch(Rectangle((D - T, z0), T, z1 - z0, **alu))
    yl = D + LIP_GAP
    z0, z1 = sorted((f(sz - 4.0), f(g.Z_TOP + g.ACRYLIC)))
    ax.add_patch(Rectangle((yl, z0), LIP_T, z1 - z0, **cov))
    zc = f(sz)
    th = [math.pi / 2 + k * math.pi / 40 for k in range(41)]
    ax.add_patch(Polygon([(min(dome_y() + DOME_R * math.cos(a), yl + 0.05), zc + DOME_R * math.sin(a))
                          for a in th], **cov))


def _sheet_with_slots(ax, y0, y1, z, t, slots, style):
    """A sheet from y0 to y1 (z .. z + t) with slots [(a, b)]."""
    edges = [y0] + [v for ab in sorted(slots) for v in ab] + [y1]
    for a, b in zip(edges[::2], edges[1::2]):
        ax.add_patch(Rectangle((a, z), b - a, t, **style))


def draw_section(parts, path):
    """Side sections (front at left): a slot cover through a tab, the cartridge
    cover through its tabs, a slot cover parked under the floor, and close-ups."""
    bay, cart, slot_x = g.openings(parts)
    zt, a, c, zf = g.Z_TOP, g.ACRYLIC, g.CAP, g.Z_FLOOR
    acr = dict(fc="#cfe6f7", ec="#4a86b0", lw=1.0)
    cov = dict(fc="#5f6874", ec="none")
    alu = dict(fc="#2c2e33", ec="black", lw=1.0)
    fig, axs = plt.subplots(2, 2, figsize=(16, 9.5), gridspec_kw=dict(width_ratios=[1.75, 1]))
    (ax1, ax2), (ax3, ax4) = axs
    kw = dict(arrowprops=dict(arrowstyle="->"), fontsize=11)
    t = TAB_T / 2 + SLOT_CLR

    # slot cover on the top
    yf, D, T = bay[2], g.D, g.T
    ys = yf - g.LIP / 2
    _sheet_with_slots(ax1, yf - 30, yf, zt, a, [(ys - t, ys + t)], acr)
    _back_patches(ax1, cov, alu, False, zt)
    ax1.add_patch(Rectangle((yf - g.LIP, zt + a), D + LIP_GAP + LIP_T - (yf - g.LIP), c, **cov))
    ax1.add_patch(Rectangle((yf + 0.2, zt), D - yf - 0.2, a + 0.05, **cov))
    _tab_patches(ax1, ys, -1, cov)
    ax1.annotate("tab through a small slot; its upper\nbump clicks past the acrylic's underside",
                 (ys - 1.2, zt - 1.0), (yf - 31, zt - 12), **kw)
    ax1.annotate("pull up here (finger notch)", (yf - g.LIP + 0.5, zt + a + c), (yf - 31, zt + a + c + 5), **kw)
    ax1.annotate("lip's dome clicks into\nthe card screw hole", (D - 0.3, g.CARD_SCREW_Z), (D - 45, zt - 14), **kw)
    ax1.text(yf - 26, zt + a / 2, "acrylic top", va="center", fontsize=11)
    ax1.text((yf + D) / 2, zt + a + c + 1.2, "slot cover (printed, one piece)", ha="center", fontsize=11)
    ax1.set_xlim(yf - 32, D + 6)
    ax1.set_ylim(zt - 20, zt + a + c + 9)
    ax1.set_title("Slot cover on the top, section through a tab (front at left)", fontsize=13)

    # cartridge cover on the top
    y0, y1 = cart[2], cart[3]
    yfront, yback = y0 - g.LIP / 2, y1 + g.LIP / 2
    _sheet_with_slots(ax2, y0 - 16, y0, zt, a, [(yfront - t, yfront + t)], acr)
    _sheet_with_slots(ax2, y1, y1 + 16, zt, a, [(yback - t, yback + t)], acr)
    ax2.add_patch(Rectangle((y0 - g.LIP, zt + a), y1 - y0 + 2 * g.LIP, c, **cov))
    ax2.add_patch(Rectangle((y0 + 0.2, zt), y1 - y0 - 0.4, a + 0.05, **cov))
    _tab_patches(ax2, yfront, -1, cov)
    _tab_patches(ax2, yback, 1, cov)
    ax2.text((y0 + y1) / 2, zt + a + c + 1.2, "cartridge cover", ha="center", fontsize=11)
    ax2.annotate("two tabs front,\ntwo back", (yback + 1.2, zt - 1.5), ((y0 + y1) / 2 - 6, zt - 11), **kw)
    ax2.set_xlim(y0 - 16, y1 + 16)
    ax2.set_ylim(zt - 20, zt + a + c + 9)
    ax2.set_title("Cartridge cover on the top (front at left)", fontsize=13)

    # slot cover parked
    fa, fb = floor_slot(ys, -1)
    _sheet_with_slots(ax3, yf - 30, D, zf, T, [(fa, fb)], alu)
    ax3.add_patch(Rectangle((yf - g.LIP, zf - a - c), D + LIP_GAP + LIP_T - (yf - g.LIP), c, **cov))
    _back_patches(ax3, cov, alu, True, zf + 18)
    ax3.annotate("lip's dome clicks into a second\nhole near the plate's bottom", (D - 0.3, PARK_HOLE_Z),
                 (D - 52, zf + 13), **kw)
    ax3.add_patch(Rectangle((yf + 0.2, zf - a - 0.05), D - yf - 0.2, a + 0.05, **cov))
    _tab_patches(ax3, ys, -1, cov, flip=True)
    ax3.add_patch(Rectangle((yf - 30, g.Z_DESK - 3), D - yf + 36, 3, fc="#c9b28f", ec="none"))
    ax3.annotate("tab up through a floor slot", (ys, zf + T + 1.5), (yf - 31, zf + 9), **kw)
    ax3.text(yf + 12, zf + T / 2, "floor", va="center", fontsize=11, color="white")
    ax3.text((yf + D) / 2, zf - a - c / 2, "slot cover, upside down", ha="center", va="center", fontsize=11,
             color="white")
    ax3.text(yf - 26, g.Z_DESK - 1.5, "desk", va="center", fontsize=10)
    ax3.set_xlim(yf - 32, D + 6)
    ax3.set_ylim(g.Z_DESK - 4, zf + 19)
    ax3.set_title("Slot cover parked under the floor (front at left)", fontsize=13)

    # close-ups: on the top (left) and parked (right, raised to the same height)
    off = 9.0
    yp = ys + off
    dz = zt - zf
    _sheet_with_slots(ax4, ys - 4, ys + 4, zt, a, [(ys - t, ys + t)], acr)
    ax4.add_patch(Rectangle((ys - 4, zt + a), 8, c, **cov))
    _tab_patches(ax4, ys, -1, cov)
    _sheet_with_slots(ax4, yp - 4, yp + 4, zf + dz, T, [(fa + off, fb + off)], alu)
    ax4.add_patch(Rectangle((yp - 4, zf + dz - a - c), 8, c, **cov))
    _tab_patches(ax4, yp, -1, cov, flip=True, dz=dz)
    ax4.text(ys, zt - TAB_BELOW - 1.2, "on the top: upper bump\nunder the acrylic", ha="center", va="top",
             fontsize=10)
    ax4.text(yp, zf + dz - a - c - 0.6, "parked: lower bump on the\nfloor; slot wide for the other",
             ha="center", va="top", fontsize=10)
    ax4.set_xlim(ys - 5, yp + 5)
    ax4.set_ylim(zt - a - c - 4, zt + a + c + 1)
    ax4.set_xticks([])
    ax4.set_yticks([])
    ax4.set_title("Tab close-ups", fontsize=13)
    for ax in (ax1, ax2, ax3, ax4):
        ax.set_aspect("equal")
        ax.grid(alpha=0.25)
    for ax in (ax1, ax2, ax3):
        ax.set_xlabel("mm")
    fig.suptitle("CONCEPT: printed covers with pull-off detents, no magnets; parked in floor slots "
                 "(bumps 0.4 mm past the slot wall; acrylic slots 6.4 x 2.2 mm)", fontsize=14)
    fig.tight_layout()
    fig.savefig(path, dpi=110, bbox_inches="tight")


def main():
    parts = g.read_board(os.path.join(g.REPO, "kicad", "placard.kicad_pcb"))
    os.makedirs(OUT, exist_ok=True)
    solids = {"acrylic_top": plain_top(parts), "tray": snap_tray(parts), "back_plate": snap_back_plate(parts),
              "left_plate": q.plate_parts(parts, g.wall_cutouts(parts), "left")[1], "cart_cover": snap_cart_cover(parts)}
    for i, s in enumerate(snap_slot_covers(parts)):
        solids["slot_cover_%d" % (i + 1)] = s
    for n in [n for n in solids if "cover" in n]:
        solids[n + "_parked"] = parked(solids[n])
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

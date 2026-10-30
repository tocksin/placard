#!/usr/bin/env python3
"""
Section drawing of the 3D-printed covers' pull-off detents (Justin,
2026-10-30; the geometry is in gen_case.py): a slot cover and the cartridge
cover on the top, a slot cover parked upside down under the floor, and
close-ups of a tab.  Writes docs/case_cover_detents.png:
    python3 src/scripts/gen_case_covers.py

Date: 2026-10-30
"""
import math
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Circle, Polygon, Rectangle

import gen_case as g


def _tab_patches(ax, y, sign, style, flip=False, dz=0.0):
    """A tab in section; flip: parked upside down."""
    zt = g.Z_TOP
    f = (lambda z: g.park_z(z) + dz) if flip else (lambda z: z + dz)
    z0, z1 = sorted((f(zt - g.TAB_BELOW), f(zt + g.ACRYLIC + 0.05)))
    ax.add_patch(Rectangle((y - g.TAB_T / 2, z0), g.TAB_T, z1 - z0, **style))
    for yb, ztop in g.bumps(y, sign):
        ax.add_patch(Circle((yb, f(ztop - g.BUMP_R)), g.BUMP_R, **style))


def _back_patches(ax, cov, alu, flip, ztop_plate):
    """The back plate (from the floor's top to ztop_plate) with its two holes,
    and the slot cover's back lip and dome, on the top or parked (flip)."""
    D, T, sz = g.D, g.T, g.CARD_SCREW_Z
    f = g.park_z if flip else (lambda z: z)
    edges = [g.Z_FLOOR + T, g.PARK_HOLE_Z - 1.7, g.PARK_HOLE_Z + 1.7, sz - 1.7, sz + 1.7, ztop_plate]
    for z0, z1 in zip(edges[::2], edges[1::2]):
        ax.add_patch(Rectangle((D - T, z0), T, z1 - z0, **alu))
    yl = D + g.LIP_GAP
    z0, z1 = sorted((f(sz - 4.0), f(g.Z_TOP + g.ACRYLIC)))
    ax.add_patch(Rectangle((yl, z0), g.LIP_T, z1 - z0, **cov))
    zc = f(sz)
    th = [math.pi / 2 + k * math.pi / 40 for k in range(41)]
    ax.add_patch(Polygon([(min(g.dome_y() + g.DOME_R * math.cos(a), yl + 0.05), zc + g.DOME_R * math.sin(a))
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
    t = g.TAB_T / 2 + g.SLOT_CLR

    # slot cover on the top
    yf, D, T = bay[2], g.D, g.T
    ys = yf - g.LIP / 2
    _sheet_with_slots(ax1, yf - 30, yf, zt, a, [(ys - t, ys + t)], acr)
    _back_patches(ax1, cov, alu, False, zt)
    ax1.add_patch(Rectangle((yf - g.LIP, zt + a), D + g.LIP_GAP + g.LIP_T - (yf - g.LIP), c, **cov))
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
    fa, fb = g.floor_slot(ys, -1)
    _sheet_with_slots(ax3, yf - 30, D, zf, T, [(fa, fb)], alu)
    ax3.add_patch(Rectangle((yf - g.LIP, zf - a - c), D + g.LIP_GAP + g.LIP_T - (yf - g.LIP), c, **cov))
    _back_patches(ax3, cov, alu, True, zf + 18)
    ax3.annotate("lip's dome clicks into a second\nhole near the plate's bottom", (D - 0.3, g.PARK_HOLE_Z),
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
    ax4.text(ys, zt - g.TAB_BELOW - 1.2, "on the top: upper bump\nunder the acrylic", ha="center", va="top",
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
    fig.suptitle("Printed covers with pull-off detents, parked in floor slots "
                 "(bumps 0.4 mm past the slot wall; acrylic slots 6.4 x 2.2 mm)", fontsize=14)
    fig.tight_layout()
    fig.savefig(path, dpi=110, bbox_inches="tight")


def main():
    parts = g.read_board(os.path.join(g.REPO, "kicad", "placard.kicad_pcb"))
    path = os.path.join(g.REPO, "docs", "case_cover_detents.png")
    draw_section(parts, path)
    print("wrote", path)


if __name__ == "__main__":
    main()
